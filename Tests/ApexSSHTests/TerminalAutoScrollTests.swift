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

    @MainActor
    func testSingleLinePromptStaysAtTop() {
        _ = NSApplication.shared
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        let buffer = TerminalRingBuffer()
        scrollView.terminalView.ringBuffer = buffer
        buffer.appendStream("root@node-1:~# ")
        scrollView.terminalView.refresh()
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 1)
    }

    @MainActor
    func testMakeNSViewZeroFrameInitialScroll() {
        _ = NSApplication.shared
        let scrollView = NativeTerminalScrollView()
        let tv = scrollView.terminalView
        tv.ringBuffer = TerminalRingBuffer()
        tv.ringBuffer?.appendStream("root@node-1:~# ")
        tv.refresh()
        
        scrollView.setFrameSize(NSSize(width: 800, height: 600))
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 1)
        XCTAssertEqual(tv.frame.origin.y, 0, accuracy: 1)
    }

    @MainActor
    func testResizeScrollViewDoesNotScrollPromptOffScreen() {
        _ = NSApplication.shared
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        let buffer = TerminalRingBuffer()
        scrollView.terminalView.ringBuffer = buffer
        buffer.appendStream("root@node-1:~# ")
        scrollView.terminalView.refresh()
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 1)
        
        // Resize to smaller height (e.g. split divider drag or SFTP panel toggle)
        scrollView.setFrameSize(NSSize(width: 640, height: 300))
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 1)
    }

    @MainActor
    func testClearScreenResetsScrollToTop() {
        _ = NSApplication.shared
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let buffer = TerminalRingBuffer()
        scrollView.terminalView.ringBuffer = buffer
        buffer.appendStream((0..<50).map { "line \($0)" }.joined(separator: "\n") + "\n")
        scrollView.terminalView.refresh()
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 100)

        // Clear screen (ESC [ 2 J and ESC [ H)
        buffer.appendStream("\u{1b}[2J\u{1b}[Hroot@node-1:~# ")
        scrollView.terminalView.refresh()
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0, accuracy: 1)
    }
}
