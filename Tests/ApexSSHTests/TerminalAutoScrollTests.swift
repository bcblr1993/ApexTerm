import AppKit
import XCTest
@testable import ApexTerminal

final class TerminalAutoScrollTests: XCTestCase {
    @MainActor
    func testRepeatedLongListingsStayPinnedToBottom() {
        _ = NSApplication.shared
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        let buffer = TerminalRingBuffer()
        scrollView.terminalView.ringBuffer = buffer

        for batch in 0..<8 {
            let listing = (0..<40).map { "file-\(batch)-\($0)" }.joined(separator: "\n") + "\n"
            buffer.appendStream(listing)
            scrollView.terminalView.refresh()
            scrollView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            XCTAssertTrue(scrollView.terminalView.isPinnedToBottom, "batch \(batch) lost follow mode")
            XCTAssertTrue(scrollView.terminalView.isScrolledToBottom(), "batch \(batch) left newest output offscreen")
        }
    }

    @MainActor
    func testNewOutputDoesNotInterruptReadingEarlierLines() {
        _ = NSApplication.shared
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        let buffer = TerminalRingBuffer()
        scrollView.terminalView.ringBuffer = buffer
        buffer.appendStream((0..<80).map { "initial-\($0)" }.joined(separator: "\n") + "\n")
        scrollView.terminalView.refresh()

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertFalse(scrollView.terminalView.isPinnedToBottom)

        buffer.appendStream((0..<40).map { "later-\($0)" }.joined(separator: "\n") + "\n")
        scrollView.terminalView.refresh()
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 1)
        XCTAssertFalse(scrollView.terminalView.isPinnedToBottom)
    }
}
