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
}
