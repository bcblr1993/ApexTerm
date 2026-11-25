import XCTest
import AppKit
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
        let prompt = "\u{1B}[?2004hubuntu@VM-0-17-ubuntu:~$ "
        let afterPaste = "\u{1B}[7m2026 from 43.155.167.224\u{1B}[27m\r\n\r"
        buffer.appendStream(prompt + afterPaste)
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "ubuntu@VM-0-17-ubuntu:~$ 2026 from 43.155.167.224\n")

        // 2. Backspace #1 in GNU Readline 8.2: CUU (\e[A), 25x CUF, clear inverse redraw, CR+LF, EL, CUU, 49x CUF
        let cuf25 = String(repeating: "\u{1B}[C", count: 25)
        let cuf49 = String(repeating: "\u{1B}[C", count: 49)
        let key1Response = "\u{1B}[A" + cuf25 + "2026 from 43.155.167.224\r\n\r\u{1B}[K\u{1B}[A" + cuf49
        buffer.appendStream(key1Response)
        view.refresh()

        XCTAssertEqual(
            view.textStorage?.string,
            "ubuntu@VM-0-17-ubuntu:~$ 2026 from 43.155.167.224",
            "First backspace redraw after bracketed paste must edit the prompt line in place without duplicating it"
        )
        XCTAssertEqual(buffer.committedLineCount, 0)
        XCTAssertEqual(buffer.activeCursorUTF16Offset, 49)
        if let storage = view.textStorage, storage.length > 26 {
            let attrs = storage.attributes(at: 26, effectiveRange: nil)
            XCTAssertNil(attrs[.backgroundColor], "Rewritten pasted text must clear inverse background attribute")
        }

        // 3. Backspace #2 deletes the trailing digit "4" cleanly in place
        buffer.appendStream("\u{08}\u{1B}[K")
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "ubuntu@VM-0-17-ubuntu:~$ 2026 from 43.155.167.22")
        XCTAssertEqual(buffer.activeCursorUTF16Offset, 48)

        // 4. Deleting the remaining 23 characters leaves only the clean shell prompt
        buffer.appendStream(String(repeating: "\u{08}\u{1B}[K", count: 23))
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "ubuntu@VM-0-17-ubuntu:~$ ")
        XCTAssertEqual(buffer.activeCursorUTF16Offset, 25)

        // 5. Normal typing & Enter after full delete still commits cleanly
        buffer.appendStream("pwd\r\n/home/ubuntu\r\n")
        view.refresh()
        XCTAssertEqual(view.textStorage?.string, "ubuntu@VM-0-17-ubuntu:~$ pwd\n/home/ubuntu\n")
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
}
