import XCTest
import AppKit
@testable import ApexTerminal

final class TerminalStateRecoveryTests: XCTestCase {
    func testSavedCursorRestoresSafelyAfterShrinkingScreen() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 24)
        buffer.appendStream("\u{1B}[?1049h\u{1B}[24;80H\u{1B}7")
        buffer.setDimensions(columns: 10, rows: 3)
        buffer.appendStream("\u{1B}8X")
        XCTAssertEqual(buffer.cursorPosition.row, 2)
        XCTAssertEqual(buffer.screenLines?[2], "         X")
    }

    func testResetClearsModesAndAllowsShellInput() {
        let buffer = TerminalRingBuffer()
        buffer.appendStream("history\r\n\u{1B}[?1049;2004;1002;1006h\u{1B}[?25l\u{1B}cplain")
        XCTAssertFalse(buffer.isInAlternateScreen)
        XCTAssertFalse(buffer.isCursorHidden)
        XCTAssertFalse(buffer.isBracketedPasteEnabled)
        XCTAssertEqual(buffer.mouseTrackingMode, 0)
        XCTAssertEqual(buffer.allLines(), ["plain"])
    }

    func testFragmentedControlStringPayloadDoesNotPrint() {
        let buffer = TerminalRingBuffer()
        buffer.appendStream("before\u{1B}Pignored")
        buffer.appendStream("payload\u{1B}")
        buffer.appendStream("\\after")
        XCTAssertEqual(buffer.currentActiveLine, "beforeafter")
    }

    @MainActor
    func testVimExitRestoresRenderedShellHistory() {
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let buffer = TerminalRingBuffer()
        scroll.terminalView.ringBuffer = buffer
        buffer.appendStream("history\r\nprompt$ ")
        scroll.terminalView.refresh()
        let before = scroll.terminalView.string
        buffer.appendStream("\u{1B}[?1049hVim screen")
        scroll.terminalView.refresh()
        buffer.appendStream("\u{1B}[?1049l")
        scroll.terminalView.refresh()
        XCTAssertEqual(scroll.terminalView.string, before)
    }

    func testInvalidHistoryArgumentsAreSafe() {
        let buffer = TerminalRingBuffer(maxLines: 0)
        buffer.appendLines(["one", "two"])
        XCTAssertEqual(buffer.allLines(), ["two"])
        XCTAssertTrue(buffer.tailLines(count: -1).isEmpty)
        XCTAssertTrue(buffer.lines(from: -1, count: 1).isEmpty)
        XCTAssertTrue(buffer.lines(from: 0, count: -1).isEmpty)
    }
}
