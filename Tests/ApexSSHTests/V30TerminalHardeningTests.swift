import XCTest
import AppKit
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class V30TerminalHardeningTests: XCTestCase {

    // MARK: - TC-V30-08: Unterminated OSC / trailing ESC no-crash & HPA/DECRQM ECMA-48 parsing
    func testTC_V30_08_UnterminatedOSCAndECMA48SequencesDoNotCrashOrLeak() {
        let parser = VTParser()

        // Must never crash on unterminated OSC, OSC ending in ESC, or lone trailing ESC
        let malformedInputs = [
            "\u{1B}",
            "prefix\u{1B}",
            "\u{1B}]0;title",
            "abc\u{1B}]0;title",
            "\u{1B}]0;title\u{1B}",
            "\u{1B}[",
            "\u{1B}[31",
            "\u{1B}("
        ]
        for raw in malformedInputs {
            let spans = parser.parseANSI(raw)
            let joined = spans.map(\.text).joined()
            XCTAssertFalse(joined.contains("\u{1B}"), "ESC must not leak for \(raw.debugDescription)")
        }
        XCTAssertEqual(parser.parseANSI("abc\u{1B}]0;title").map(\.text).joined(), "abc")
        XCTAssertEqual(parser.parseANSI("prefix\u{1B}").map(\.text).joined(), "prefix")

        // HPA (`\e[10\``), DECRQM (`\e[?2026$p`), and DECSTR (`\e[!p`) must not leak raw bytes
        let ecma48 = "A\u{1B}[10`B\u{1B}[?2026$pC\u{1B}[!pD\u{1B}[6 qE"
        XCTAssertEqual(parser.parseANSI(ecma48).map(\.text).joined(), "ABCDE")

        let buffer = TerminalRingBuffer(maxLines: 50)
        buffer.appendStream(ecma48 + "\n")
        XCTAssertEqual(buffer.allLines(), ["ABCDE"])
    }

    // MARK: - TC-V30-09: Private CSI >/</= prefixes never pollute SGR & 0x7F DEL is filtered
    func testTC_V30_09_PrivateCSIModifyOtherKeysAndDELFilter() {
        let parser = VTParser()
        let ring = TerminalRingBuffer(maxLines: 50)

        // modifyOtherKeys (`\e[>4;1m`), reset (`\e[>0m`), Kitty keyboard (`\e[<u`, `\e[=1;1u`)
        let stream = "\u{1B}[32mgreen\u{1B}[>4;1m_still_green\u{1B}[>0m\u{1B}[<u\u{1B}[=1;1u_end\n"
        let spans = parser.parseANSI(stream)
        XCTAssertEqual(spans.map(\.text).joined(), "green_still_green_end\n")
        XCTAssertEqual(spans.count, 3)
        XCTAssertTrue(spans.allSatisfy { !$0.isBold && $0.ansiColorIndex == 2 }, "CSI >4;1m must never enable bold or reset color")

        ring.appendStream(stream)
        let line = ring.allLines().first ?? ""
        let ringSpans = parser.parseANSI(line)
        XCTAssertEqual(ringSpans.map(\.text).joined(), "green_still_green_end")
        XCTAssertFalse(ringSpans.contains(where: \.isBold), "RingBuffer must ignore CSI >4;1m without setting bold")
        XCTAssertEqual(ringSpans.first?.ansiColorIndex, 2)

        // Direct SGRStyle guard rejects non-numeric private prefixes
        var style = SGRStyle(foreground: nil, index: 2, bold: false)
        style.apply(param: ">4;1")
        XCTAssertFalse(style.bold)
        XCTAssertEqual(style.index, 2)
        style.apply(param: ">0")
        XCTAssertEqual(style.index, 2)

        // 0x7F (DEL) must never enter normal or alternate screen buffer as a printable cell
        let delBuffer = TerminalRingBuffer(maxLines: 50)
        delBuffer.appendStream("ab\u{7F}cd\n")
        XCTAssertEqual(delBuffer.allLines(), ["abcd"])
        delBuffer.appendStream("\u{1B}[?1049hxy\u{7F}zw")
        XCTAssertEqual(delBuffer.screenLines?.first, "xyzw")
    }

    // MARK: - TC-V30-10: ?1049h/l saves/restores currentStyle & redundant ?1049l avoids clear-pending
    func testTC_V30_10_AlternateScreenStyleIsolationAndRedundantExitNoClearPending() {
        let buffer = TerminalRingBuffer(maxLines: 50)

        // Redundant ?1049l while already in normal mode must NOT set clear pending
        buffer.appendStream("line1\r\n")
        _ = buffer.consumeClearFlag()
        buffer.appendStream("\u{1B}[?1049l")
        XCTAssertFalse(buffer.consumeClearFlag(), "Exiting when not in alternate screen must not trigger full re-render")

        // Normal mode sets green foreground before launching TUI
        buffer.appendStream("\u{1B}[32mnormal_green\r\n")
        // Enter alternate screen, set bold + inverse + red, then exit WITHOUT \e[0m
        buffer.appendStream("\u{1B}[?1049h\u{1B}[1;7;31mtui_content")
        XCTAssertTrue(buffer.isInAlternateScreen)
        buffer.appendStream("\u{1B}[?1049l")
        XCTAssertFalse(buffer.isInAlternateScreen)
        XCTAssertTrue(buffer.consumeClearFlag(), "Real exit from alternate screen must trigger clear pending")

        // Subsequent normal-mode text must inherit saved normal-mode green, NOT leaked inverse/bold/red
        buffer.appendStream("after_tui\r\n")
        let lastLine = buffer.allLines().last ?? ""
        let spans = VTParser().parseANSI(lastLine)
        XCTAssertEqual(spans.map(\.text).joined(), "after_tui")
        XCTAssertFalse(spans[0].isBold)
        XCTAssertFalse(spans[0].isInverse)
        XCTAssertEqual(spans[0].ansiColorIndex, 2)
    }

    // MARK: - TC-V30-11: Find bounds safety after eviction/clear & Cmd+G/Cmd+F focus + Clear notification
    @MainActor
    func testTC_V30_11_FindBoundsSafetyShortcutsAndClearNotification() throws {
        _ = NSApplication.shared
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer {
            scroll.tearDown()
            window.orderOut(nil)
        }

        let terminal = scroll.terminalView
        let buffer = TerminalRingBuffer(maxLines: 3)
        terminal.ringBuffer = buffer

        buffer.appendStream("needle-0\r\nneedle-1\r\nneedle-2\r\n")
        terminal.refresh()

        let foundCount = terminal.performFind(query: "needle")
        XCTAssertEqual(foundCount, 3)

        // 1. Scrollback eviction invalidates stale match ranges safely
        buffer.appendStream("other-3\r\nother-4\r\nother-5\r\n")
        terminal.refresh()
        XCTAssertTrue(terminal.currentMatches.isEmpty, "Eviction must invalidate stale Find matches")
        XCTAssertNil(terminal.findNext())
        XCTAssertNil(terminal.findPrevious())

        // 2. Truncated storage behind stale ranges is still bounds-safe
        buffer.clear()
        buffer.appendStream("match-a\r\nmatch-b\r\n")
        terminal.refresh()
        XCTAssertEqual(terminal.performFind(query: "match"), 2)
        terminal.textStorage?.setAttributedString(NSAttributedString(string: "x"))
        XCTAssertNil(terminal.findNext())

        // 3. FindBar performKeyEquivalent handles Cmd+G / Cmd+Shift+G / Cmd+F when searchField is focused
        buffer.clear()
        buffer.appendStream("alpha\r\nbeta\r\nalpha\r\n")
        terminal.refresh()
        scroll.showFindBar()
        scroll.searchBarOverlay.searchField.stringValue = "alpha"
        _ = terminal.performFind(query: "alpha")
        scroll.searchBarOverlay.updateMatchLabel()
        XCTAssertEqual(terminal.currentMatchIndex, 0)
        window.makeFirstResponder(scroll.searchBarOverlay.searchField)

        let cmdG = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5
        ))
        XCTAssertTrue(scroll.searchBarOverlay.performKeyEquivalent(with: cmdG))
        XCTAssertEqual(terminal.currentMatchIndex, 1)

        let cmdShiftG = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "G", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5
        ))
        XCTAssertTrue(scroll.searchBarOverlay.performKeyEquivalent(with: cmdShiftG))
        XCTAssertEqual(terminal.currentMatchIndex, 0)

        let cmdF = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
        ))
        XCTAssertTrue(scroll.searchBarOverlay.performKeyEquivalent(with: cmdF))

        // 4. ApexTermClearTerminalScreen clears focused normal-mode terminal and skips alternate screen
        scroll.hideFindBar()
        window.makeFirstResponder(terminal)
        var sent: [Data] = []
        terminal.onInput = { sent.append($0) }
        NotificationCenter.default.post(name: Notification.Name("ApexTermClearTerminalScreen"), object: nil)
        XCTAssertEqual(buffer.committedLineCount, 0)
        XCTAssertEqual(sent.last, Data([0x0C]))

        sent.removeAll()
        buffer.appendStream("\u{1B}[?1049hVim")
        NotificationCenter.default.post(name: Notification.Name("ApexTermClearTerminalScreen"), object: nil)
        XCTAssertTrue(buffer.isInAlternateScreen)
        XCTAssertTrue(sent.isEmpty, "Clear screen notification must not clear inside alternate screen")
    }

    // MARK: - TC-V30-12: Option-as-Meta, AltGr, IME, CJK guard, DirectoryChangeStreamParser, OSC 133 & FontManager
    @MainActor
    func testTC_V30_12_OptionAsMetaAltGrDirectoryParserAndFontManager() throws {
        let prevOption = NativeTerminalView.isOptionAsMetaEnabled
        let prevCJK = NativeTerminalView.shouldConvertCJKPunctuation
        defer {
            NativeTerminalView.isOptionAsMetaEnabled = prevOption
            NativeTerminalView.shouldConvertCJKPunctuation = prevCJK
        }

        let terminal = NativeTerminalView()
        var sent: [Data] = []
        terminal.onInput = { sent.append($0) }

        // Default Option-as-Meta disabled: AltGr symbol (`@` via Option+l) sends literal `@`, not `\el`
        NativeTerminalView.isOptionAsMetaEnabled = { false }
        let altGrAt = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "@", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37
        ))
        terminal.keyDown(with: altGrAt)
        XCTAssertEqual(sent, [Data("@".utf8)])

        // Option-as-Meta enabled: preserves Shift uppercase (`Option+Shift+B` -> `\eB`),
        // prefixes ESC on Ctrl+Option (`Ctrl+Option+A` -> `\e\x01`), supports `Ctrl+/` (`0x1F`),
        // and skips while IME has marked text.
        NativeTerminalView.isOptionAsMetaEnabled = { true }
        sent.removeAll()
        let optShiftB = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .shift],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "B", charactersIgnoringModifiers: "B", isARepeat: false, keyCode: 11
        ))
        terminal.keyDown(with: optShiftB)
        XCTAssertEqual(sent, [Data("\u{1B}B".utf8)])

        sent.removeAll()
        let ctrlOptA = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        terminal.keyDown(with: ctrlOptA)
        XCTAssertEqual(sent, [Data([0x1B, 0x01])])

        sent.removeAll()
        let ctrlSlash = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "/", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44
        ))
        terminal.keyDown(with: ctrlSlash)
        XCTAssertEqual(sent, [Data([0x1F])])

        // Marked text suppresses Option-as-Meta interception
        sent.removeAll()
        terminal.setMarkedText("e", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.keyDown(with: optShiftB)
        XCTAssertFalse(sent.contains(Data("\u{1B}B".utf8)))
        terminal.unmarkText()

        // CJK punctuation rewrite guarded behind shouldConvertCJKPunctuation()
        sent.removeAll()
        NativeTerminalView.shouldConvertCJKPunctuation = { false }
        terminal.insertText("：；wq\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(sent.last, Data("：；wq\r".utf8))
        NativeTerminalView.shouldConvertCJKPunctuation = { true }
        terminal.insertText("：；wq\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(sent.last, Data(":;wq\r".utf8))

        // DirectoryChangeStreamParser: aborted OSC recovers subsequent OSC 7, rejects host-only file://host, supports OSC 1337 & bare OSC 7
        var dirParser = DirectoryChangeStreamParser()
        let dirChunk = "\u{1B}]0;broken\u{1B}[32mok\u{1B}]7;file://myhost\u{07}\u{1B}]7;file://myhost/tmp/a\u{07}\u{1B}]1337;CurrentDir=/var/log\u{1B}\\\u{1B}]7;/etc\u{07}"
        let parsed = dirParser.consume(Data(dirChunk.utf8))
        XCTAssertEqual(parsed.paths, ["/tmp/a", "/var/log", "/etc"])
        XCTAssertEqual(parsed.text, "\u{1B}[32mok")

        // ShellIntegrationTracker + RingBuffer: preexec 133;C after newline recovers commandText
        let ring = TerminalRingBuffer(maxLines: 50)
        ring.appendStream("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}uname -a\r\n\u{1B}]133;C\u{07}Darwin\r\n\u{1B}]133;D;0\u{07}")
        XCTAssertEqual(ring.shellIntegration.lastCompletedRecord?.commandText, "uname -a")
        XCTAssertEqual(ring.extractLastOSC133CommandOutput(), "Darwin")

        // TerminalFontManager Nerd Font tightening & descriptor resolution
        XCTAssertFalse(TerminalFontManager.detectNerdFont("SanFrancisco"))
        XCTAssertFalse(TerminalFontManager.detectNerdFont("InfiniMono"))
        XCTAssertTrue(TerminalFontManager.detectNerdFont("MesloLGS NF"))
        XCTAssertNotNil(TerminalFontManager.resolveFont(familyName: "Menlo", size: 13))

        // Trackpad precise scrollDeltaY accumulates across sub-line-height ticks and resets on sign flip
        let altBuffer = TerminalRingBuffer()
        altBuffer.appendStream("\u{1B}[?1049h")
        terminal.ringBuffer = altBuffer
        sent.removeAll()
        let cgTick = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 6, wheel2: 0, wheel3: 0))
        let tickUp = try XCTUnwrap(NSEvent(cgEvent: cgTick))
        terminal.scrollWheel(with: tickUp)
        XCTAssertTrue(sent.isEmpty, "Sub-line-height trackpad tick (6px) must accumulate rather than flood")
        terminal.scrollWheel(with: tickUp)
        terminal.scrollWheel(with: tickUp)
        XCTAssertEqual(sent.count, 1, "Accumulated 18px > lineHeight emits exactly 1 Up arrow step")
        XCTAssertEqual(sent.first, Data("\u{1B}[A".utf8))
    }

    // MARK: - TC-V30-13: LocalTerminalSession drains final output before EOF & provides /dev/tty
    func testTC_V30_13_LocalTerminalDrainsOutputOnExitAndProvidesControllingTTY() async throws {
        final class OutputBox: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) {
                lock.withLock { data.append(chunk) }
            }
            var string: String {
                lock.withLock { String(decoding: data, as: UTF8.self) }
            }
        }

        let session = LocalTerminalSession(session: .local(name: "V30 Local Test"))
        let output = OutputBox()
        let disconnectedExp = expectation(description: "Session disconnected after exit")
        disconnectedExp.assertForOverFulfill = false

        session.setOutputHandler { data in
            output.append(data)
        }
        session.setStateChangeHandler { state in
            if state == .disconnected {
                disconnectedExp.fulfill()
            }
        }

        try await session.connect()
        try await Task.sleep(nanoseconds: 150_000_000)

        // Verify controlling terminal (/dev/tty) is available AND final output before exit is not truncated
        let script = "if exec 3</dev/tty 2>/dev/null; then echo V30_TTY_OK; else echo V30_TTY_FAIL; fi; echo V30_FINAL_OUTPUT; exit\n"
        try await session.sendInput(Data(script.utf8))

        let res = await XCTWaiter.fulfillment(of: [disconnectedExp], timeout: 5.0)
        let captured = output.string
        XCTAssertEqual(res, .completed, "Expected disconnect, got \(res), state=\(session.connectionState), captured=\(captured.debugDescription)")
        XCTAssertTrue(captured.contains("V30_TTY_OK"), "LocalTerminalSession must provide /dev/tty, got: \(captured)")
        XCTAssertTrue(captured.contains("V30_FINAL_OUTPUT"), "Final output before shell exit must drain before EOF, got: \(captured)")
        XCTAssertEqual(session.connectionState, .disconnected)
    }
}
