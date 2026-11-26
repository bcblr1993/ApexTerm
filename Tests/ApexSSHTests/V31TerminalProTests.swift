import XCTest
import AppKit
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class V31TerminalProTests: XCTestCase {

    // MARK: - TC-V31-15: OSC 8 Hyperlink Span & Link Attribute Preservation
    @MainActor
    func testTC_V31_15_OSC8HyperlinkSpanAndLinkAttributePreservation() throws {
        let parser = VTParser()
        let raw = "Open \u{1B}]8;id=doc1;https://aetherterm.dev/docs\u{07}\u{1B}[32mDocs\u{1B}[0m Guide\u{1B}]8;;\u{1B}\\ now"
        let spans = parser.parseANSI(raw)

        XCTAssertEqual(spans.map(\.text).joined(), "Open Docs Guide now")
        let docsSpan = try XCTUnwrap(spans.first(where: { $0.text == "Docs" }))
        let guideSpan = try XCTUnwrap(spans.first(where: { $0.text == " Guide" }))
        let openSpan = try XCTUnwrap(spans.first(where: { $0.text == "Open " }))
        let nowSpan = try XCTUnwrap(spans.first(where: { $0.text == " now" }))

        XCTAssertEqual(docsSpan.linkURI, "https://aetherterm.dev/docs")
        XCTAssertEqual(docsSpan.ansiColorIndex, 2)
        // SGR 0 resets colors but preserves active OSC 8 hyperlink until OSC 8;;
        XCTAssertEqual(guideSpan.linkURI, "https://aetherterm.dev/docs")
        XCTAssertNil(guideSpan.ansiColorIndex)
        XCTAssertNil(openSpan.linkURI)
        XCTAssertNil(nowSpan.linkURI)

        // Unsafe URI schemes must be rejected cleanly
        let unsafe = "\u{1B}]8;;javascript:alert(1)\u{07}click\u{1B}]8;;\u{07}"
        XCTAssertNil(parser.parseANSI(unsafe).first?.linkURI)

        // RingBuffer committed line preserves OSC 8 into NativeTerminalView NSAttributedString `.link`
        let buffer = TerminalRingBuffer(maxLines: 50)
        buffer.appendStream("Visit \u{1B}]8;;https://example.com/runbook\u{07}Runbook\u{1B}]8;;\u{07}!\r\n")
        let terminal = NativeTerminalView()
        terminal.frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        terminal.textContainer?.containerSize = NSSize(width: 640, height: 240)
        terminal.ringBuffer = buffer
        terminal.refresh()

        let storage = try XCTUnwrap(terminal.textStorage)
        let fullStr = storage.string as NSString
        let runbookRange = fullStr.range(of: "Runbook")
        XCTAssertNotEqual(runbookRange.location, NSNotFound)
        let linkAttr = storage.attribute(.link, at: runbookRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(linkAttr?.absoluteString, "https://example.com/runbook")

        let visitRange = fullStr.range(of: "Visit ")
        XCTAssertNil(storage.attribute(.link, at: visitRange.location, effectiveRange: nil))

        // urlAtPoint returns OSC 8 link URL
        let layout = try XCTUnwrap(terminal.layoutManager)
        let container = try XCTUnwrap(terminal.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: runbookRange.location + 1)
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let hitPoint = NSPoint(x: terminal.textContainerOrigin.x + glyphRect.midX, y: terminal.textContainerOrigin.y + glyphRect.midY)
        XCTAssertEqual(terminal.urlAtPoint(hitPoint)?.absoluteString, "https://example.com/runbook")
    }

    // MARK: - TC-V31-16: file:line[:col] Detection Across Relative & Absolute Paths
    @MainActor
    func testTC_V31_16_FileLineColumnDetectionAndCmdClickNotification() throws {
        let logLine = "error at Sources/Foo.swift:42:10 and ./main.py:18 or /etc/nginx/nginx.conf:5 (see https://example.com/foo.swift:9 and 127.0.0.1:8080 and 12:34:56)"
        let detected = NativeTerminalView.detectFileLocations(in: logLine)

        XCTAssertEqual(detected.count, 3)
        XCTAssertEqual(detected[0].path, "Sources/Foo.swift")
        XCTAssertEqual(detected[0].line, 42)
        XCTAssertEqual(detected[0].column, 10)

        XCTAssertEqual(detected[1].path, "./main.py")
        XCTAssertEqual(detected[1].line, 18)
        XCTAssertNil(detected[1].column)

        XCTAssertEqual(detected[2].path, "/etc/nginx/nginx.conf")
        XCTAssertEqual(detected[2].line, 5)
        XCTAssertNil(detected[2].column)

        // Verify compiler output trailing colon also matches cleanly
        let compilerLine = "Sources/Foo.swift:42:10: error: cannot find 'bar'"
        let compilerMatches = NativeTerminalView.detectFileLocations(in: compilerLine)
        XCTAssertEqual(compilerMatches.first?.path, "Sources/Foo.swift")
        XCTAssertEqual(compilerMatches.first?.line, 42)
        XCTAssertEqual(compilerMatches.first?.column, 10)

        // Verify urlAtPoint, fileLocationAtPoint & Cmd+Click ApexTermOpenDetectedFilePath notification
        let buffer = TerminalRingBuffer(maxLines: 50)
        buffer.appendStream("\u{1B}]7;file://host/Users/dev/project\u{07}")
        buffer.appendStream("Check Sources/Foo.swift:42:10 now\r\n")

        let terminal = NativeTerminalView()
        terminal.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
        terminal.textContainer?.containerSize = NSSize(width: 800, height: 200)
        terminal.ringBuffer = buffer
        terminal.refresh()

        let layout = try XCTUnwrap(terminal.layoutManager)
        let container = try XCTUnwrap(terminal.textContainer)
        layout.ensureLayout(for: container)

        let text = (terminal.textStorage?.string ?? "") as NSString
        let targetRange = text.range(of: "Sources/Foo.swift:42:10")
        XCTAssertNotEqual(targetRange.location, NSNotFound)
        let glyph = layout.glyphIndexForCharacter(at: targetRange.location + 4)
        let charRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let pt = NSPoint(x: terminal.textContainerOrigin.x + charRect.midX, y: terminal.textContainerOrigin.y + charRect.midY)

        let url = try XCTUnwrap(terminal.urlAtPoint(pt))
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, "/Users/dev/project/Sources/Foo.swift")

        let loc = try XCTUnwrap(terminal.fileLocationAtPoint(pt))
        XCTAssertEqual(loc.path, "Sources/Foo.swift")
        XCTAssertEqual(loc.line, 42)
        XCTAssertEqual(loc.column, 10)

        let receivedBox = SendableBox<(path: String?, line: Int?, column: Int?, cwd: String?)>((nil, nil, nil, nil))
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("ApexTermOpenDetectedFilePath"),
            object: terminal,
            queue: .main
        ) { note in
            let path = note.userInfo?["path"] as? String
            let line = note.userInfo?["line"] as? Int
            let column = note.userInfo?["column"] as? Int
            let cwd = note.userInfo?["workingDirectory"] as? String
            receivedBox.withValue { $0 = (path, line, column, cwd) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        terminal.openDetectedFileLocation(loc)
        let receivedInfo = receivedBox.withValue { $0 }
        XCTAssertEqual(receivedInfo.path, "Sources/Foo.swift")
        XCTAssertEqual(receivedInfo.line, 42)
        XCTAssertEqual(receivedInfo.column, 10)
        XCTAssertEqual(receivedInfo.cwd, "/Users/dev/project")
    }

    // MARK: - TC-V31-17: Trigger .notify & .sendResponse Execution + Cooldown Anti-Loop Protection
    @MainActor
    func testTC_V31_17_TriggerActionEngineGatingAndCooldownAntiLoop() throws {
        // Legacy Trigger JSON without cooldownSeconds must decode with default 5.0s
        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","regexPattern":"err","isCaseSensitive":false,"action":{"notify":{"title":"Alert"}},"isEnabled":true}
        """
        let decodedLegacy = try JSONDecoder().decode(Trigger.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decodedLegacy.cooldownSeconds, 5.0)

        let prevAutoResp = NativeTerminalView.isTriggerAutoResponseEnabled
        defer { NativeTerminalView.isTriggerAutoResponseEnabled = prevAutoResp }

        let notifyTrigger = Trigger(
            name: "Build Done",
            regexPattern: "BUILD SUCCEEDED",
            action: .notify(title: "Build Status"),
            cooldownSeconds: 5.0
        )
        let responseTrigger = Trigger(
            name: "Confirm Prompt",
            regexPattern: "Continue\\? \\[y/N\\]",
            action: .sendResponse(text: "y\n"),
            cooldownSeconds: 5.0
        )

        let buffer = TerminalRingBuffer(maxLines: 50)
        let notifications = SendableBox<[(String?, String)]>([])
        var sentResponses: [String] = []
        buffer.onDesktopNotification = { title, body in
            notifications.withValue { $0.append((title, body)) }
        }

        let terminal = NativeTerminalView()
        terminal.onTriggerSendResponse = { response in
            sentResponses.append(response)
        }
        NativeTerminalView.isTriggerAutoResponseEnabled = { false }
        terminal.ringBuffer = buffer
        terminal.setTriggers([notifyTrigger, responseTrigger])

        // 1. Auto-response disabled -> .notify fires, .sendResponse MUST NOT fire
        buffer.appendStream("BUILD SUCCEEDED\r\n")
        buffer.appendStream("Continue? [y/N] ")
        XCTAssertEqual(notifications.withValue { $0.count }, 1)
        XCTAssertEqual(notifications.withValue { $0.first?.0 }, "Build Status")
        XCTAssertTrue(sentResponses.isEmpty, ".sendResponse must stay gated while isTriggerAutoResponseEnabled() is false")

        // 2. Enable auto-response -> .sendResponse fires ONCE, then cooldown blocks echo loop
        NativeTerminalView.isTriggerAutoResponseEnabled = { true }
        buffer.appendStream("\r\nContinue? [y/N] ")
        XCTAssertEqual(sentResponses, ["y\n"])

        // Immediate repeat / echo within 5s cooldown must be throttled
        buffer.appendStream("\r\nContinue? [y/N] ")
        buffer.appendStream("\r\nContinue? [y/N] ")
        buffer.appendStream("BUILD SUCCEEDED\r\n")
        XCTAssertEqual(sentResponses.count, 1, "Cooldown must prevent infinite echo loops")
        XCTAssertEqual(notifications.withValue { $0.count }, 1, "Notify cooldown must also throttle repeats within 5s")

        // 3. Direct KeywordHighlighter deterministic timestamp check past cooldown
        let evaluator = KeywordHighlighter(triggers: [responseTrigger])
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(evaluator.evaluateActions(in: "Continue? [y/N]", now: t0, allowAutoResponse: true).count, 1)
        XCTAssertEqual(evaluator.evaluateActions(in: "Continue? [y/N]", now: t0.addingTimeInterval(4.9), allowAutoResponse: true).count, 0)
        XCTAssertEqual(evaluator.evaluateActions(in: "Continue? [y/N]", now: t0.addingTimeInterval(5.1), allowAutoResponse: true).count, 1)
    }

    // MARK: - TC-V31-18: Regex (.*) & Case-Sensitive (Aa) Find Modes + Live Re-Sync
    @MainActor
    func testTC_V31_18_RegexAndCaseSensitiveFindModesAndLiveResync() async {
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        defer { scroll.tearDown() }
        let terminal = scroll.terminalView
        let findBar = scroll.searchBarOverlay
        let buffer = TerminalRingBuffer(maxLines: 100)
        terminal.ringBuffer = buffer

        buffer.appendStream("Error alpha-101\r\nerror alpha-202\r\nERROR beta-303\r\n")
        terminal.refresh()

        // 1. Case-sensitive toggle (`Aa`)
        findBar.show(withInitialText: "Error")
        XCTAssertEqual(terminal.currentMatches.count, 3)

        findBar.isCaseSensitive = true
        XCTAssertEqual(terminal.currentMatches.count, 1)
        XCTAssertEqual(findBar.matchLabel.stringValue, "1/1")

        // 2. Regex toggle (`.*`)
        findBar.isCaseSensitive = false
        findBar.isRegexEnabled = true
        findBar.searchField.stringValue = #"alpha-\d{3}"#
        findBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(terminal.currentMatches.count, 2)
        XCTAssertFalse(terminal.isFindRegexInvalid)
        XCTAssertFalse(findBar.showsInvalidRegexBadge)

        // 3. Invalid regex pattern sets safe badge without crashing
        findBar.searchField.stringValue = "[unclosed("
        findBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(terminal.currentMatches.count, 0)
        XCTAssertTrue(terminal.isFindRegexInvalid)
        XCTAssertTrue(findBar.showsInvalidRegexBadge)
        XCTAssertEqual(findBar.matchLabel.stringValue, "正则无效")

        // 4. Valid regex + debounced live re-sync picks up newly appended buffer output
        findBar.searchField.stringValue = #"(?:alpha|gamma)-\d{3}"#
        findBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(terminal.currentMatches.count, 2)

        buffer.appendStream("ok gamma-404\r\n")
        terminal.refresh()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(terminal.currentMatches.count, 3)
        XCTAssertEqual(findBar.matchLabel.stringValue, "1/3")
    }

    // MARK: - TC-V31-19: SGR 2 (Dim) & Back-Color Erase (BCE)
    @MainActor
    func testTC_V31_19_SGR2DimAndBackColorErase() throws {
        let parser = VTParser()
        let spans = parser.parseANSI("\u{1B}[31mnormal\u{1B}[2mdim\u{1B}[22mrestored\u{1B}[0m")
        XCTAssertEqual(spans.count, 3)
        XCTAssertFalse(spans[0].isDim)
        XCTAssertTrue(spans[1].isDim)
        XCTAssertFalse(spans[2].isDim)

        let terminal = NativeTerminalView()
        let attr = terminal.formatANSI("\u{1B}[31mnormal\u{1B}[2mdim\u{1B}[0m")
        let normalColor = try XCTUnwrap(attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
            .usingColorSpace(.deviceRGB)
        let dimColor = try XCTUnwrap(attr.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor)
            .usingColorSpace(.deviceRGB)
        XCTAssertEqual(normalColor?.alphaComponent ?? 0, 1.0, accuracy: 0.01)
        XCTAssertLessThan(dimColor?.alphaComponent ?? 1.0, 0.7)

        // BCE in normal mode on K (EL), X (ECH), and J (ED)
        let buffer = TerminalRingBuffer(maxLines: 50)
        buffer.setDimensions(columns: 10, rows: 5)
        // EL (K): write "ab", set blue background (44), erase to end of line
        buffer.appendStream("ab\u{1B}[44m\u{1B}[K\r\n")
        // ECH (X): write "hello", move to col 1, set red background (41), erase 3 chars
        buffer.appendStream("hello\u{1B}[2G\u{1B}[41m\u{1B}[3X\r\n")
        // ED (J): write "xy", set green background (42), erase to end of display
        buffer.appendStream("xy\u{1B}[42m\u{1B}[J\r\n")

        let lines = buffer.allLines()
        XCTAssertEqual(lines.count, 3)

        let line0Spans = parser.parseANSI(lines[0])
        XCTAssertEqual(line0Spans.map(\.text).joined(), "ab        ")
        XCTAssertEqual(line0Spans.last?.backgroundANSIColorIndex, 4)

        let line1Spans = parser.parseANSI(lines[1])
        XCTAssertEqual(line1Spans.map(\.text).joined(), "h   o")
        XCTAssertEqual(line1Spans[1].backgroundANSIColorIndex, 1)

        let line2Spans = parser.parseANSI(lines[2])
        XCTAssertEqual(line2Spans.map(\.text).joined(), "xy        ")
        XCTAssertEqual(line2Spans.last?.backgroundANSIColorIndex, 2)
    }

    // MARK: - TC-V31-20: Alt-Screen Normal Snapshot Cache Hit & Invalidation
    @MainActor
    func testTC_V31_20_NormalSnapshotCacheHitAndInvalidation() {
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        defer { scroll.tearDown() }
        let terminal = scroll.terminalView
        let buffer = TerminalRingBuffer(maxLines: 500)
        terminal.ringBuffer = buffer

        for i in 0..<200 {
            buffer.appendStream("normal-line-\(i)\r\n")
        }
        terminal.refresh()
        XCTAssertTrue(terminal.string.contains("normal-line-199"))

        // Enter alternate screen (?1049h): normal-mode NSAttributedString snapshot is captured
        buffer.appendStream("\u{1B}[?1049hVim Editor Screen")
        terminal.refresh()
        XCTAssertTrue(terminal.hasCachedNormalSnapshot)
        XCTAssertTrue(terminal.string.contains("Vim Editor Screen"))
        XCTAssertFalse(terminal.string.contains("normal-line-199"))

        // Exit alternate screen (?1049l): O(1) cache hit restores normal-mode output
        buffer.appendStream("\u{1B}[?1049l")
        terminal.refresh()
        XCTAssertEqual(terminal.normalSnapshotCacheHits, 1)
        XCTAssertEqual(terminal.normalSnapshotCacheMisses, 0)
        XCTAssertFalse(terminal.hasCachedNormalSnapshot)
        XCTAssertTrue(terminal.string.contains("normal-line-0"))
        XCTAssertTrue(terminal.string.contains("normal-line-199"))

        // Invalidation path 1: buffer.clear() while in alternate screen invalidates snapshot
        buffer.appendStream("\u{1B}[?1049hInside Less")
        terminal.refresh()
        XCTAssertTrue(terminal.hasCachedNormalSnapshot)
        buffer.clear()
        buffer.appendStream("\u{1B}[?1049lfresh-after-clear\r\n")
        terminal.refresh()
        XCTAssertEqual(terminal.normalSnapshotCacheMisses, 1)
        XCTAssertTrue(terminal.string.contains("fresh-after-clear"))
        XCTAssertFalse(terminal.string.contains("normal-line-199"))

        // Invalidation path 2: setTriggers() while in alternate screen invalidates snapshot
        buffer.appendStream("\u{1B}[?1049hInside Htop")
        terminal.refresh()
        XCTAssertTrue(terminal.hasCachedNormalSnapshot)
        terminal.setTriggers([Trigger(name: "Fresh", regexPattern: "fresh", action: .highlight(colorHex: "#FF453A"))])
        XCTAssertFalse(terminal.hasCachedNormalSnapshot)
        buffer.appendStream("\u{1B}[?1049l")
        terminal.refresh()
        XCTAssertEqual(terminal.normalSnapshotCacheMisses, 2)
        XCTAssertTrue(terminal.string.contains("fresh-after-clear"))
    }

    // MARK: - TC-V31-21: OSC 133 Command Blocks & Failed-Command Navigation Helper
    @MainActor
    func testTC_V31_21_OSC133CommandBlocksAndFailedNavigation() {
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 180))
        defer { scroll.tearDown() }
        let terminal = scroll.terminalView
        let buffer = TerminalRingBuffer(maxLines: 500)
        terminal.ringBuffer = buffer

        // Command 0: success (0)
        buffer.appendStream("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}echo start\u{1B}]133;C\u{07}\n")
        for i in 1...8 { buffer.appendStream("ok-\(i)\n") }
        buffer.appendStream("\u{1B}]133;D;0\u{07}")

        // Command 1: failed (1)
        buffer.appendStream("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}make test\u{1B}]133;C\u{07}\n")
        buffer.appendStream("fatal: test failed\n")
        for i in 1...8 { buffer.appendStream("trace-\(i)\n") }
        buffer.appendStream("\u{1B}]133;D;1\u{07}")

        // Command 2: success (0)
        buffer.appendStream("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}echo done\u{1B}]133;C\u{07}\n")
        for i in 1...8 { buffer.appendStream("done-\(i)\n") }
        buffer.appendStream("\u{1B}]133;D;0\u{07}")

        // Idle prompt at bottom
        buffer.appendStream("\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}")
        terminal.refresh()

        let records = buffer.shellIntegration.allRecords()
        XCTAssertEqual(records.count, 3)
        let failedRec = records[1]
        XCTAssertTrue(failedRec.isFailed)
        XCTAssertEqual(failedRec.commandText, "make test")
        XCTAssertEqual(buffer.shellIntegration.record(atLine: failedRec.outputStartLine)?.id, failedRec.id)
        XCTAssertEqual(buffer.shellIntegration.latestFailedRecord()?.id, failedRec.id)

        // Jump to previous failed command navigates directly to command 1's prompt line (skipping command 2)
        XCTAssertTrue(terminal.jumpToPreviousFailedCommand())
        XCTAssertEqual(terminal.currentTopVisibleLineIndex(), failedRec.promptStartLine)
        XCTAssertFalse(terminal.jumpToPreviousFailedCommand())

        // Copy command output copies exact stdout/stderr of that record
        XCTAssertTrue(terminal.copyCommandOutput(for: failedRec))
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(copied.contains("fatal: test failed"))
        XCTAssertFalse(copied.contains("done-1"))

        // Re-run command sends `<command>\r` to onInput
        var sent: [Data] = []
        terminal.onInput = { sent.append($0) }
        XCTAssertTrue(terminal.rerunCommand(failedRec))
        XCTAssertEqual(sent.last, Data("make test\r".utf8))
    }
}

private final class SendableBox<T>: @unchecked Sendable {
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
