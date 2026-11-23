import XCTest
import AppKit
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

/// RG-15: Modern Terminal Protocols (OSC 52, DEC 2026, OSC 133 Navigation) (`TC-V24-01 ~ TC-V24-06`).
final class ModernTerminalProtocolTests: XCTestCase {

    // MARK: - TC-V24-01: OSC 52 Base64 decode & 100 KB cap + unclosed 160 KB cap
    func testTC_V24_01_OSC52DecodeAndSizeCaps() {
        let helloB64 = Data("hello world\n你好".utf8).base64EncodedString()
        let parsed = OSC52Parser.parse(payload: "c;\(helloB64)")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.selection, "c")
        XCTAssertEqual(parsed?.text, "hello world\n你好")
        XCTAssertEqual(parsed?.byteCount, Data("hello world\n你好".utf8).count)

        // Exact 100 KB succeeds; 100 KB + 1 byte is rejected
        let exact100KB = Data(repeating: UInt8(ascii: "A"), count: 100 * 1024).base64EncodedString()
        XCTAssertNotNil(OSC52Parser.parse(payload: "c;\(exact100KB)"))

        let over100KB = Data(repeating: UInt8(ascii: "A"), count: 100 * 1024 + 1).base64EncodedString()
        XCTAssertNil(OSC52Parser.parse(payload: "c;\(over100KB)"))

        // Invalid Base64 rejected
        XCTAssertNil(OSC52Parser.parse(payload: "c;%%%invalid%%%"))

        // Unclosed OSC stream exceeding 160 KB is dropped so normal output continues cleanly
        let buffer = TerminalRingBuffer(maxLines: 100)
        let giantUnclosed = "\u{1B}]52;c;" + String(repeating: "A", count: 170_000)
        buffer.appendStream(giantUnclosed)
        buffer.appendStream("\nrecovered line\n")
        XCTAssertTrue(buffer.allLines().contains("recovered line"))
    }

    // MARK: - TC-V24-02: OSC 52 clipboard read queries (`?`) are strictly rejected
    func testTC_V24_02_OSC52ReadQueryStrictlyRejected() {
        XCTAssertNil(OSC52Parser.parse(payload: "c;?"))
        XCTAssertNil(OSC52Parser.parse(payload: "p; ? "))
        XCTAssertNil(OSC52Parser.parse(payload: "c;"))

        let buffer = TerminalRingBuffer(maxLines: 50)
        let delivered = LockBox<[OSC52WriteRequest]>([])
        buffer.onOSC52WriteRequest = { req in
            delivered.withValue { $0.append(req) }
        }
        buffer.appendStream("\u{1B}]52;c;?\u{07}\u{1B}]52;c;?\u{1B}\\")
        XCTAssertTrue(delivered.withValue { $0.isEmpty })
    }

    // MARK: - TC-V24-03: OSC 52 deny/ask/allow & per-session allow routing
    @MainActor
    func testTC_V24_03_OSC52PolicyRouting() {
        let session = Session(name: "prod-web", host: "10.0.1.5", username: "ops", authMethod: .agent)
        let pane = TerminalPaneItem(session: session, sshClient: NativeSSHSession(session: session), title: session.name)
        var clipboardWrites: [String] = []
        pane.onWriteClipboard = { clipboardWrites.append($0) }

        let req1 = OSC52WriteRequest(selection: "c", text: "secret-1", byteCount: 8)
        pane.handleOSC52WriteRequest(req1, policy: .deny)
        XCTAssertNil(pane.pendingOSC52Request)
        XCTAssertTrue(clipboardWrites.isEmpty)

        // Ask policy prompts once; "allow once" writes without persisting session allowance
        pane.handleOSC52WriteRequest(req1, policy: .ask)
        XCTAssertEqual(pane.pendingOSC52Request, req1)
        XCTAssertTrue(clipboardWrites.isEmpty)
        pane.allowPendingOSC52Once()
        XCTAssertNil(pane.pendingOSC52Request)
        XCTAssertEqual(clipboardWrites, ["secret-1"])

        // Deny dismisses prompt
        let req2 = OSC52WriteRequest(selection: "c", text: "secret-2", byteCount: 8)
        pane.handleOSC52WriteRequest(req2, policy: .ask)
        pane.denyPendingOSC52()
        XCTAssertNil(pane.pendingOSC52Request)
        XCTAssertEqual(clipboardWrites, ["secret-1"])

        // "Allow for session" writes immediately and auto-approves subsequent requests in this pane
        pane.handleOSC52WriteRequest(req2, policy: .ask)
        pane.allowPendingOSC52ForSession()
        XCTAssertEqual(clipboardWrites, ["secret-1", "secret-2"])
        let req3 = OSC52WriteRequest(selection: "c", text: "secret-3", byteCount: 8)
        pane.handleOSC52WriteRequest(req3, policy: .ask)
        XCTAssertNil(pane.pendingOSC52Request)
        XCTAssertEqual(clipboardWrites, ["secret-1", "secret-2", "secret-3"])

        // Allow policy writes directly without prompt
        let paneAllow = TerminalPaneItem(session: session, sshClient: NativeSSHSession(session: session), title: session.name)
        var directWrites: [String] = []
        paneAllow.onWriteClipboard = { directWrites.append($0) }
        paneAllow.handleOSC52WriteRequest(req1, policy: .allow)
        XCTAssertNil(paneAllow.pendingOSC52Request)
        XCTAssertEqual(directWrites, ["secret-1"])
        pane.tearDown()
        paneAllow.tearDown()
    }

    // MARK: - TC-V24-04: DEC 2026 synchronized output frame suppression & 120ms watchdog release
    @MainActor
    func testTC_V24_04_DEC2026SyncSuppressionAndWatchdog() {
        let buffer = TerminalRingBuffer(maxLines: 100)
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let terminalView = scrollView.terminalView
        terminalView.ringBuffer = buffer

        let t0 = ContinuousClock.now
        buffer.appendStream("\u{1B}[?2026hframe-one\n")
        XCTAssertTrue(buffer.isSynchronizedOutputActive(now: t0, timeout: .milliseconds(120)))
        terminalView.refresh()
        XCTAssertEqual(terminalView.string, "", "Display update must wait while DEC 2026 sync frame is active")

        // Ending sync frame flushes accumulated content
        buffer.appendStream("frame-two\n\u{1B}[?2026l")
        XCTAssertFalse(buffer.isSynchronizedOutputActive)
        terminalView.refresh()
        XCTAssertTrue(terminalView.string.contains("frame-one"))
        XCTAssertTrue(terminalView.string.contains("frame-two"))

        // Watchdog automatically resets after >= 120ms if remote drops 2026l
        buffer.appendStream("\u{1B}[?2026hstalled-frame\n")
        let tStart = ContinuousClock.now
        XCTAssertTrue(buffer.isSynchronizedOutputActive(now: tStart, timeout: .milliseconds(120)))
        let tExpired = tStart.advanced(by: .milliseconds(125))
        XCTAssertFalse(buffer.isSynchronizedOutputActive(now: tExpired, timeout: .milliseconds(120)))

        scrollView.tearDown()
    }

    // MARK: - TC-V24-05: Packet-fragmented OSC 52 & DEC 2026 sequences reassemble losslessly
    func testTC_V24_05_FragmentedOSC52AndDEC2026() {
        let buffer = TerminalRingBuffer(maxLines: 100)
        let captured = LockBox<[OSC52WriteRequest]>([])
        buffer.onOSC52WriteRequest = { req in
            captured.withValue { $0.append(req) }
        }

        let payload = Data("chunked-clipboard-payload".utf8).base64EncodedString()
        let fullOsc = "\u{1B}]52;c;\(payload)\u{1B}\\"
        // Split every 3 characters including across ST (`\e` and `\`)
        var idx = fullOsc.startIndex
        while idx < fullOsc.endIndex {
            let next = fullOsc.index(idx, offsetBy: 3, limitedBy: fullOsc.endIndex) ?? fullOsc.endIndex
            buffer.appendStream(String(fullOsc[idx..<next]))
            idx = next
        }

        XCTAssertEqual(captured.withValue { $0.map(\.text) }, ["chunked-clipboard-payload"])

        // Fragmented DEC 2026h / 2026l
        buffer.appendStream("\u{1B}[?20")
        buffer.appendStream("26h")
        XCTAssertTrue(buffer.isSynchronizedOutputActive)
        buffer.appendStream("\u{1B}[?2026")
        buffer.appendStream("l")
        XCTAssertFalse(buffer.isSynchronizedOutputActive)
    }

    // MARK: - TC-V24-06: OSC 133 prompt navigation (Cmd+Up / Cmd+Down) & exit code extraction
    @MainActor
    func testTC_V24_06_OSC133PromptNavigationAndExitCode() {
        let buffer = TerminalRingBuffer(maxLines: 200)
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))
        let terminalView = scrollView.terminalView
        terminalView.ringBuffer = buffer

        // Command 1 (exit 0) at line 0
        buffer.appendStream("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}echo one\u{1B}]133;C\u{07}\n")
        for i in 1...12 { buffer.appendStream("out1-\(i)\n") }
        buffer.appendStream("\u{1B}]133;D;0\u{07}")

        // Command 2 (exit 2) at line 13
        buffer.appendStream("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}false_cmd\u{1B}]133;C\u{07}\n")
        for i in 1...12 { buffer.appendStream("err2-\(i)\n") }
        buffer.appendStream("\u{1B}]133;D;2\u{07}")

        // Idle prompt at bottom
        buffer.appendStream("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
        terminalView.refresh()

        let prompts = buffer.shellIntegration.allPromptLines()
        XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(buffer.shellIntegration.lastCompletedRecord?.exitCode, 2)
        XCTAssertTrue(buffer.extractLastOSC133CommandOutput()?.contains("err2-12") == true)

        XCTAssertTrue(terminalView.jumpToPreviousPrompt())
        XCTAssertEqual(terminalView.currentTopVisibleLineIndex(), prompts[1])

        XCTAssertTrue(terminalView.jumpToPreviousPrompt())
        XCTAssertEqual(terminalView.currentTopVisibleLineIndex(), prompts[0])

        XCTAssertTrue(terminalView.jumpToNextPrompt())
        XCTAssertEqual(terminalView.currentTopVisibleLineIndex(), prompts[1])

        // Alternate screen skips prompt navigation so Vim/htop keybindings stay intact
        buffer.appendStream("\u{1B}[?1049h")
        XCTAssertFalse(terminalView.jumpToPreviousPrompt())

        scrollView.tearDown()
    }
}

private final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
