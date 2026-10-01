import XCTest
import AppKit
@testable import ApexTerminal

final class TerminalRenderedHistoryTests: XCTestCase {
    @MainActor
    func testChangingHistoryLimitPreservesRecentLinesAndFutureOutput() {
        let terminal = NativeTerminalView()
        let buffer = TerminalRingBuffer(maxLines: 5)
        terminal.ringBuffer = buffer
        buffer.appendStream("0\r\n1\r\n2\r\n3\r\n4\r\n")
        terminal.refresh()
        buffer.setHistoryLimit(2)
        terminal.refresh()
        XCTAssertEqual(buffer.allLines(), ["3", "4"])
        XCTAssertEqual(terminal.string, "3\n4\n")
        buffer.setHistoryLimit(4)
        buffer.appendStream("5\r\n6\r\n7\r\n")
        terminal.refresh()
        XCTAssertEqual(buffer.allLines(), ["4", "5", "6", "7"])
        XCTAssertEqual(terminal.string, "4\n5\n6\n7\n")
    }

    @MainActor
    func testCursorOnlyOutputMovesCursorWithoutEditingScrollback() async throws {
        let terminal = NativeTerminalView()
        let buffer = TerminalRingBuffer()
        terminal.ringBuffer = buffer
        buffer.appendStream("abcdefgh")
        terminal.refresh()
        let before = try XCTUnwrap(terminal.terminalCursorRect)
        let storage = try XCTUnwrap(terminal.textStorage)
        let noEdit = expectation(description: "Cursor movement must not edit scrollback text")
        noEdit.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: storage, queue: .main) { _ in noEdit.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        buffer.appendStream("\u{1B}[2D")
        terminal.refresh()
        XCTAssertEqual(terminal.string, "abcdefgh")
        XCTAssertLessThan(try XCTUnwrap(terminal.terminalCursorRect).minX, before.minX)
        await fulfillment(of: [noEdit], timeout: 0.05)
    }

    @MainActor
    func testLongHistoryViewportKeepsLatestOutputVisibleDuringEviction() {
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 683, height: 398))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        let terminal = scroll.terminalView
        let buffer = TerminalRingBuffer(maxLines: 10_000)
        terminal.ringBuffer = buffer
        buffer.appendStream((0..<10_000).map { "[QA] cycle=100 row=\($0) status=OK\r\n" }.joined())
        terminal.refresh()
        let start = CFAbsoluteTimeGetCurrent()
        for batch in 0..<20 {
            buffer.appendStream((0..<80).map { "[QA] cycle=\(batch) row=\($0) status=OK\r\n" }.joined())
            terminal.refresh()
        }
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 10, "Bounded history refresh must not monopolize the main thread")
        XCTAssertTrue(terminal.string.hasSuffix("[QA] cycle=19 row=79 status=OK\n"))
        XCTAssertFalse(terminal.string.hasPrefix("[QA] cycle=100 row=0 status=OK\n"))
        XCTAssertEqual(terminal.string.filter { $0 == "\n" }.count, 10_000)
        XCTAssertTrue(terminal.isScrolledToBottom())
        let resizeStart = CFAbsoluteTimeGetCurrent()
        let viewportWidth = scroll.contentView.bounds.width
        scroll.scrollerStyle = .legacy
        scroll.tile()
        XCTAssertEqual(scroll.contentView.bounds.width, viewportWidth)
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        scroll.scrollerStyle = .overlay
        scroll.tile()
        terminal.scrollToBottom(forceLayout: true)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - resizeStart, 10, "Scroller style changes must not block a full history viewport")
    }

    @MainActor
    func testRenderedHistoryEvictsWholeUnicodeLinesAtConfiguredLimit() {
        let terminal = NativeTerminalView()
        let buffer = TerminalRingBuffer(maxLines: 3)
        terminal.ringBuffer = buffer
        for index in 0..<10 {
            buffer.appendStream("中文🚀-\(index)\r\n")
            terminal.refresh()
        }
        XCTAssertEqual(terminal.string, "中文🚀-7\n中文🚀-8\n中文🚀-9\n")
        buffer.appendStream("\u{1B}[?1049hVim\u{1B}[?1049l")
        terminal.refresh()
        XCTAssertEqual(terminal.string, "中文🚀-7\n中文🚀-8\n中文🚀-9\n")
        terminal.clearScreen()
        buffer.appendStream("new\r\n")
        terminal.refresh()
        XCTAssertEqual(terminal.string, "new\n")
    }
}
