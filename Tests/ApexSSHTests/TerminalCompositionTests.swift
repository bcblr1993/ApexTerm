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
}
