import XCTest
import AppKit
@testable import ApexTerminal

final class TerminalCompositionTests: XCTestCase {
    @MainActor
    func testCompositionDoesNotTransmitUntilCandidateCommitted() {
        let terminal = NativeTerminalView()
        terminal.textStorage?.setAttributedString(NSAttributedString(string: "host % "))
        var inputs: [Data] = []
        terminal.onInput = { inputs.append($0) }
        terminal.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(terminal.hasMarkedText())
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(terminal.string, "host % ", "Preedit must not overwrite remote output")
        terminal.insertText(NSAttributedString(string: "中文🙂"),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(inputs, [Data("中文🙂".utf8)])
        XCTAssertFalse(terminal.hasMarkedText())
        XCTAssertEqual(terminal.markedRange().location, NSNotFound)
    }

    @MainActor
    func testDiscardingCompositionDoesNotSendRemoteInput() {
        let terminal = NativeTerminalView()
        var inputs: [Data] = []
        terminal.onInput = { inputs.append($0) }
        terminal.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.unmarkText()
        XCTAssertFalse(terminal.hasMarkedText())
        XCTAssertTrue(inputs.isEmpty)
    }
    @MainActor
    func testPreeditRendersWithoutChangingRemoteOutputAndDisappearsOnCancel() throws {
        let terminal = NativeTerminalView()
        terminal.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        terminal.textStorage?.setAttributedString(NSAttributedString(string: "host % "))
        terminal.layoutManager?.ensureLayout(for: try XCTUnwrap(terminal.textContainer))
        func pixels() throws -> Data {
            let bitmap = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
            terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let before = try pixels()
        terminal.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(terminal.markedRange(), NSRange(location: 7, length: 4))
        XCTAssertEqual(terminal.selectedRange(), NSRange(location: 11, length: 0))
        var actual = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(terminal.attributedSubstring(forProposedRange: terminal.markedRange(), actualRange: &actual)?.string, "中文候选")
        XCTAssertEqual(actual, terminal.markedRange())
        XCTAssertEqual(terminal.string, "host % ")
        XCTAssertNotEqual(try pixels(), before, "Composition must be visible, not merely retained in state")
        terminal.unmarkText()
        XCTAssertEqual(try pixels(), before, "Cancel must remove the overlay and preserve terminal output")
    }

    @MainActor
    func testCandidateRectangleUsesActualCompositionRange() {
        let terminal = NativeTerminalView()
        terminal.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = terminal
        terminal.textStorage?.setAttributedString(NSAttributedString(string: "host % "))
        terminal.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        var actual = NSRange(location: NSNotFound, length: 0)
        let rect = terminal.firstRect(forCharacterRange: terminal.markedRange(), actualRange: &actual)
        XCTAssertEqual(actual, NSRange(location: 7, length: 2))
        XCTAssertGreaterThan(rect.width, 12)
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertTrue(window.frame.intersects(rect))
    }

}
