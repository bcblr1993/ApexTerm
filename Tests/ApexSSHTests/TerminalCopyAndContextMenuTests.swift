import XCTest
import AppKit
@testable import ApexCore
@testable import ApexTerminal

final class TerminalCopyAndContextMenuTests: XCTestCase {
    @MainActor
    func testCommandVPastesInsteadOfSendingShortcutToTerminal() throws {
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        pasteboard.clearContents()
        pasteboard.setString("qa-paste\n", forType: .string)
        let terminal = NativeTerminalView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = terminal
        window.makeFirstResponder(terminal)
        var inputs: [Data] = []
        terminal.onInput = { inputs.append($0) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(terminal.performKeyEquivalent(with: event))
        XCTAssertEqual(inputs, [Data("qa-paste\r".utf8)])
        inputs.removeAll()
        terminal.keyDown(with: event)
        XCTAssertEqual(inputs, [Data("qa-paste\r".utf8)])
    }

    
    @MainActor
    func testCopySelectionToPasteboard() {
        let view = NativeTerminalView()
        view.isCopyOnSelectEnabled = true
        
        let sample = "Linux 6.6.0-generic aarch64 ApexTerm ProMotion"
        view.textStorage?.setAttributedString(NSAttributedString(string: sample))
        
        // 1. No selection -> should return false and not alter pasteboard
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let copiedNoSelection = view.copySelectionToPasteboardIfAny()
        XCTAssertFalse(copiedNoSelection)
        
        // 2. Select "Linux 6.6.0"
        let targetRange = NSRange(location: 0, length: 11)
        view.setSelectedRange(targetRange)
        let copied = view.copySelectionToPasteboardIfAny()
        XCTAssertTrue(copied)
        
        let pasteboardString = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasteboardString, "Linux 6.6.0")
    }
    
    @MainActor
    func testRightClickContextMenuStructureAndState() {
        let view = NativeTerminalView()
        let sample = "echo 'Hello ApexTerm'"
        view.textStorage?.setAttributedString(NSAttributedString(string: sample))
        
        // When nothing selected
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let dummyEvent = NSEvent()
        let menuWithoutSelection = view.menu(for: dummyEvent)
        XCTAssertNotNil(menuWithoutSelection)
        
        let copyItemNoSel = menuWithoutSelection?.items.first(where: { $0.title.contains("复制") })
        XCTAssertNotNil(copyItemNoSel)
        XCTAssertFalse(copyItemNoSel!.isEnabled, "Copy item should be disabled when nothing is selected")
        
        let pasteItem = menuWithoutSelection?.items.first(where: { $0.title.contains("粘贴") })
        XCTAssertNotNil(pasteItem)
        
        let selectAllItem = menuWithoutSelection?.items.first(where: { $0.title.contains("全选") })
        XCTAssertNotNil(selectAllItem)
        
        let clearItem = menuWithoutSelection?.items.first(where: { $0.title.contains("清屏") })
        XCTAssertNotNil(clearItem)
        
        // When text is selected
        view.setSelectedRange(NSRange(location: 5, length: 16)) // "'Hello ApexTerm'"
        let menuWithSelection = view.menu(for: dummyEvent)
        let copyItemSel = menuWithSelection?.items.first(where: { $0.title.contains("复制") })
        XCTAssertNotNil(copyItemSel)
        XCTAssertTrue(copyItemSel!.isEnabled, "Copy item should be enabled when text is selected")
        
        // Right click menu invocation should also automatically copy selection to pasteboard
        let currentClip = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(currentClip, "'Hello ApexTerm'")
    }
    
    @MainActor
    func testClearScreenMenuAction() {
        let ringBuffer = TerminalRingBuffer(maxLines: 100)
        ringBuffer.appendLine("Log line 1")
        ringBuffer.appendLine("Log line 2")
        
        let view = NativeTerminalView()
        view.ringBuffer = ringBuffer
        view.textStorage?.setAttributedString(NSAttributedString(string: "Log line 1\nLog line 2\n"))
        
        XCTAssertEqual(view.textStorage?.length, 22)
        XCTAssertEqual(ringBuffer.committedLineCount, 2)
        
        // Trigger clear screen
        let dummyMenu = view.menu(for: NSEvent())
        let clearItem = dummyMenu?.items.first(where: { $0.title.contains("清屏") })
        XCTAssertNotNil(clearItem)
        
        if let action = clearItem?.action {
            _ = view.perform(action, with: clearItem)
        }
        
        XCTAssertEqual(view.textStorage?.length, 0)
        XCTAssertEqual(ringBuffer.committedLineCount, 0)
    }
    
    @MainActor
    func testAutoCopyOnSelectViaSetSelectedRanges() {
        let view = NativeTerminalView()
        view.isCopyOnSelectEnabled = true
        let sample = "git status --short"
        view.textStorage?.setAttributedString(NSAttributedString(string: sample))
        
        // 1. While still selecting (dragging mouse), should not finalize copy
        let rangeVal = NSValue(range: NSRange(location: 0, length: 10)) // "git status"
        view.setSelectedRanges([rangeVal], affinity: .downstream, stillSelecting: true)
        
        // 2. Mouse released / drag finished -> stillSelecting is false
        view.setSelectedRanges([rangeVal], affinity: .downstream, stillSelecting: false)
        let clipboard = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(clipboard, "git status")
    }
    
    @MainActor
    func testRightClickDirectPaste() {
        let view = NativeTerminalView()
        let sampleText = "curl https://api.apexterm.dev\n"
        
        // Put text into clipboard
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(sampleText, forType: .string)
        
        var receivedInput: Data?
        view.onInput = { data in
            receivedInput = data
        }
        
        // Simulate rightMouseDown without shift (PuTTY / SecureCRT style direct paste)
        let dummyEvent = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!
        
        view.rightMouseDown(with: dummyEvent)
        
        XCTAssertNotNil(receivedInput)
        let pastedString = String(data: receivedInput!, encoding: .utf8)
        // \n should be normalized to \r for terminal input
        XCTAssertEqual(pastedString, "curl https://api.apexterm.dev\r")
    }

    @MainActor
    func testBracketedPasteWithTrailingNewlineAndBackspaceEditsInPlaceWithoutDuplicating() {
        let buffer = TerminalRingBuffer(maxLines: 200)
        buffer.setDimensions(columns: 90, rows: 24)
        let view = NativeTerminalView()
        view.ringBuffer = buffer

        // 1. Prompt with bracketed paste enabled (?2004h) + bracketed paste echo with trailing CR (\e[7m...\e[27m\r\n\r)
        let prompt = "\u{1B}[?2004hqa@test-host:~$ "
        let afterPaste = "\u{1B}[7m2026 from 198.51.100.42\u{1B}[27m\r\n\r"
        buffer.appendStream(prompt + afterPaste)
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "qa@test-host:~$ 2026 from 198.51.100.42\n")

        // 2. Backspace #1 in GNU Readline 8.2: CUU (\e[A), 16x CUF, clear inverse redraw, CR+LF, EL, CUU, 39x CUF
        let cuf16 = String(repeating: "\u{1B}[C", count: 16)
        let cuf39 = String(repeating: "\u{1B}[C", count: 39)
        let key1Response = "\u{1B}[A" + cuf16 + "2026 from 198.51.100.42\r\n\r\u{1B}[K\u{1B}[A" + cuf39
        buffer.appendStream(key1Response)
        view.refresh()

        XCTAssertEqual(
            view.textStorage?.string,
            "qa@test-host:~$ 2026 from 198.51.100.42",
            "First backspace redraw after bracketed paste must edit the prompt line in place without duplicating it"
        )
        XCTAssertEqual(buffer.committedLineCount, 0)
        XCTAssertEqual(buffer.activeCursorUTF16Offset, 39)
        if let storage = view.textStorage, storage.length > 17 {
            let attrs = storage.attributes(at: 17, effectiveRange: nil)
            XCTAssertNil(attrs[.backgroundColor], "Rewritten pasted text must clear inverse background attribute")
        }

        // 3. Backspace #2 deletes the trailing digit "2" cleanly in place
        buffer.appendStream("\u{08}\u{1B}[K")
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "qa@test-host:~$ 2026 from 198.51.100.4")
        XCTAssertEqual(buffer.activeCursorUTF16Offset, 38)

        // 4. Deleting the remaining 22 characters leaves only the clean shell prompt
        buffer.appendStream(String(repeating: "\u{08}\u{1B}[K", count: 22))
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "qa@test-host:~$ ")
        XCTAssertEqual(buffer.activeCursorUTF16Offset, 16)

        // 5. Normal typing & Enter after full delete still commits cleanly
        buffer.appendStream("pwd\r\n/home/qa\r\n")
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "qa@test-host:~$ pwd\n/home/qa\n")
    }

    @MainActor
    func testNormalModeMultiLineCursorUpDownAndEraseBelow() {
        let buffer = TerminalRingBuffer(maxLines: 200)
        buffer.setDimensions(columns: 80, rows: 10)
        let view = NativeTerminalView()
        view.ringBuffer = buffer

        buffer.appendStream("line0\r\nline1\r\nline2\r\nactive")
        view.refresh()
        XCTAssertEqual(buffer.committedLineCount, 3)

        // Move up 2 lines, edit line1 -> lineX, clear below with CSI 0 J
        buffer.appendStream("\u{1B}[2A\u{0D}\u{1B}[4CX\u{1B}[0J")
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "line0\nlineX")
        XCTAssertEqual(buffer.committedLineCount, 1)

        // Move down / up via CSI B / CSI F / ESC M without exceeding screenRows - 1 clamp
        for idx in 0..<20 {
            buffer.appendStream("\r\nhist_\(idx)")
        }
        buffer.appendStream("\r\n")
        view.refresh()
        let beforeHugeCUU = buffer.committedLineCount
        buffer.appendStream("\u{1B}[999A")
        view.refresh()
        XCTAssertEqual(
            beforeHugeCUU - buffer.committedLineCount,
            9,
            "Normal-mode CSI A must clamp rewind to screenRows - 1 so older scrollback stays immutable"
        )
        // Return back down with CSI 999B (clamped to belowActiveRows.count)
        buffer.appendStream("\u{1B}[999B")
        view.refresh()
        XCTAssertEqual(buffer.committedLineCount, beforeHugeCUU)
    }

    @MainActor
    func testCopyOnSelectDisabledDoesNotAutoCopyWhileCmdCAndMenuCopyWork() throws {
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        pasteboard.clearContents()
        pasteboard.setString("sentinel-clip", forType: .string)

        let view = NativeTerminalView()
        view.isCopyOnSelectEnabled = false
        view.textStorage?.setAttributedString(NSAttributedString(string: "hello terminal world"))

        let rangeVal = NSValue(range: NSRange(location: 0, length: 5))
        view.setSelectedRanges([rangeVal], affinity: .downstream, stillSelecting: false)
        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel-clip")

        _ = view.menu(for: NSEvent())
        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel-clip")

        view.selectAll(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel-clip")

        let cmdC = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ))
        view.keyDown(with: cmdC)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello terminal world")
    }

    @MainActor
    func testRightClickPasteDisabledAndShiftRightClickOpenContextMenu() throws {
        let settings = AppSettings.shared
        let oldRightClick = settings.isRightClickPasteEnabled
        defer { settings.isRightClickPasteEnabled = oldRightClick }

        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        pasteboard.clearContents()
        pasteboard.setString("should-not-paste", forType: .string)

        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), textContainer: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        var sent: [Data] = []
        view.onInput = { sent.append($0) }

        // 1. Shift+Right-Click with rightClickPaste enabled routes to context menu, never pastes
        settings.isRightClickPasteEnabled = true
        let shiftRightDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [.shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        XCTAssertTrue(view.shouldOpenContextMenuOnRightClick(with: shiftRightDown))
        let menu = view.menu(for: shiftRightDown)
        XCTAssertNotNil(menu)
        XCTAssertTrue(sent.isEmpty)

        // 2. Plain Right-Click with isRightClickPasteEnabled = false routes to context menu, never pastes
        let plainRightDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 50, y: 50), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        ))
        XCTAssertFalse(view.shouldOpenContextMenuOnRightClick(with: plainRightDown))
        settings.isRightClickPasteEnabled = false
        XCTAssertTrue(view.shouldOpenContextMenuOnRightClick(with: plainRightDown))
        XCTAssertNotNil(view.menu(for: plainRightDown))
        XCTAssertTrue(sent.isEmpty)

        // 3. Plain Right-Click with isRightClickPasteEnabled = true pastes directly
        settings.isRightClickPasteEnabled = true
        view.rightMouseDown(with: plainRightDown)
        XCTAssertEqual(sent, [Data("should-not-paste".utf8)])
    }

    @MainActor
    func testBracketedPasteStripsEmbeddedEndMarkerAndNormalizesMultiLine() throws {
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        pasteboard.clearContents()
        pasteboard.setString("echo safe\r\n\u{1B}[201~rm -rf /\u{1B}[200~\n", forType: .string)

        let buffer = TerminalRingBuffer()
        buffer.appendStream("\u{1B}[?2004h")
        let view = NativeTerminalView()
        view.ringBuffer = buffer
        var sent: [Data] = []
        view.onInput = { sent.append($0) }

        XCTAssertTrue(view.pasteFromClipboard())
        let payload = try XCTUnwrap(sent.first).withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(payload, "\u{1B}[200~echo safe\rrm -rf /\r\u{1B}[201~")
    }

    @MainActor
    func testCommandShortcutsDoNotHijackCommandOptionAndFindNavigationWorks() throws {
        let buffer = TerminalRingBuffer(maxLines: 100)
        buffer.appendStream("alpha\r\nbeta\r\nalpha two\r\n")
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let view = scrollView.terminalView
        view.ringBuffer = buffer
        view.refresh()

        // Cmd+Opt+K must NOT wipe the terminal
        let cmdOptK = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40
        ))
        view.keyDown(with: cmdOptK)
        XCTAssertEqual(buffer.committedLineCount, 3)

        // Cmd+Opt+F must NOT open Find bar
        let cmdOptF = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
        ))
        view.keyDown(with: cmdOptF)
        XCTAssertTrue(scrollView.searchBarOverlay.isHidden)

        // Cmd+F opens Find bar, Cmd+G / Cmd+Shift+G cycles matches
        let cmdF = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
        ))
        view.keyDown(with: cmdF)
        XCTAssertFalse(scrollView.searchBarOverlay.isHidden)

        XCTAssertEqual(view.performFind(query: "alpha"), 2)
        XCTAssertEqual(view.currentMatchIndex, 0)

        let cmdG = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5
        ))
        view.keyDown(with: cmdG)
        XCTAssertEqual(view.currentMatchIndex, 1)

        let cmdShiftG = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "G", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5
        ))
        view.keyDown(with: cmdShiftG)
        XCTAssertEqual(view.currentMatchIndex, 0)

        // Cmd+K clears screen and emits Ctrl+L
        var sent: [Data] = []
        view.onInput = { sent.append($0) }
        let cmdK = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40
        ))
        view.keyDown(with: cmdK)
        XCTAssertEqual(buffer.committedLineCount, 0)
        XCTAssertEqual(view.textStorage?.string, "")
        XCTAssertEqual(sent, [Data([0x0C])])
        scrollView.tearDown()
    }

    @MainActor
    func testNormalModeRewindAndRecommitWithinSameRefreshWindowUpdatesRenderedLines() {
        let buffer = TerminalRingBuffer(maxLines: 100)
        buffer.setDimensions(columns: 80, rows: 10)
        let view = NativeTerminalView()
        view.ringBuffer = buffer

        buffer.appendStream("A\r\nB\r\nC\r\n")
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "A\nB\nC\n")

        // Rewind 2 lines and commit 2 replacement lines in a single packet (net committed delta == 0!)
        buffer.appendStream("\u{1B}[2A\u{1B}[0JX\r\nY\r\n")
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "A\nX\nY\n")

        // Rewind 2 lines and commit 1 replacement line (net delta == -1)
        buffer.appendStream("\u{1B}[2A\u{1B}[0JZ\r\n")
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "A\nZ\n")
    }
}
