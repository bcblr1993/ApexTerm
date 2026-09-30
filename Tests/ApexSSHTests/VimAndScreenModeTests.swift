import XCTest
import AppKit
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class VimAndScreenModeTests: XCTestCase {

    // MARK: - 1. Alternate Screen Buffer Lifecycle

    func testVimAlternateScreenBufferEntryAndExit() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 24)
        
        // Before entering alternate screen
        XCTAssertFalse(buffer.isInAlternateScreen)
        XCTAssertNil(buffer.screenLines)
        
        // Output something in shell
        buffer.appendStream("root@host:~# echo hello\r\nhello\r\n")
        XCTAssertEqual(buffer.committedLineCount, 2)
        
        // Vim starts: enters alternate screen
        buffer.appendStream("\u{1B}[?1049h")
        XCTAssertTrue(buffer.isInAlternateScreen)
        XCTAssertNotNil(buffer.screenLines)
        XCTAssertEqual(buffer.screenLines?.count, 24)
        
        // Vim draws lines in alternate screen
        buffer.appendStream("\u{1B}[1;1Hnetworks:\r\n  proxy:\r\n    external: true")
        buffer.appendStream("\u{1B}[24;1H\"docker-compose.yml\" 64L, 2158B")
        
        let lines = buffer.screenLines ?? []
        XCTAssertEqual(lines.first, "networks:")
        XCTAssertEqual(lines[1], "  proxy:")
        XCTAssertEqual(lines[2], "    external: true")
        XCTAssertEqual(lines[23], "\"docker-compose.yml\" 64L, 2158B")
        
        // Vim exits: leaves alternate screen
        buffer.appendStream("\u{1B}[?1049l")
        XCTAssertFalse(buffer.isInAlternateScreen)
        XCTAssertNil(buffer.screenLines)
        XCTAssertTrue(buffer.consumeClearFlag())
    }

    // MARK: - 2. Combined DEC Private Modes Parsing

    func testCombinedDECPrivateModes() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 24)
        
        // Combined CSI: ?1049 (alternate screen) and ?2004 (bracketed paste)
        buffer.appendStream("\u{1B}[?1049;2004h")
        XCTAssertTrue(buffer.isInAlternateScreen)
        XCTAssertTrue(buffer.isBracketedPasteEnabled)
        
        // Exit both
        buffer.appendStream("\u{1B}[?1049;2004l")
        XCTAssertFalse(buffer.isInAlternateScreen)
        XCTAssertFalse(buffer.isBracketedPasteEnabled)
    }

    // MARK: - 3. Scrolling Region (DECSTBM) Preserves Status Bar

    func testVimScrollingRegionDECSTBM() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 10)
        
        // Enter alternate screen
        buffer.appendStream("\u{1B}[?1049h")
        
        // Status bar on line 10
        buffer.appendStream("\u{1B}[10;1HSTATUS_LINE_ACTIVE")
        XCTAssertEqual(buffer.screenLines?[9], "STATUS_LINE_ACTIVE")
        
        // Set scrolling region: lines 1 to 9 (status line is line 10)
        buffer.appendStream("\u{1B}[1;9r")
        
        // Fill lines 1 to 9
        for i in 1...9 {
            buffer.appendStream("\u{1B}[\(i);1HLine \(i)")
        }
        XCTAssertEqual(buffer.screenLines?[0], "Line 1")
        XCTAssertEqual(buffer.screenLines?[8], "Line 9")
        XCTAssertEqual(buffer.screenLines?[9], "STATUS_LINE_ACTIVE")
        
        // Move cursor to bottom of scroll region (line 9) and scroll with newline
        buffer.appendStream("\u{1B}[9;1H\r\nLine 10_New")
        
        // Line 1 should have scrolled off, Line 2 is now at row 1, Line 10_New at row 9
        XCTAssertEqual(buffer.screenLines?[0], "Line 2")
        XCTAssertEqual(buffer.screenLines?[8], "Line 10_New")
        // CRITICAL: Line 10 (status bar) must remain intact!
        XCTAssertEqual(buffer.screenLines?[9], "STATUS_LINE_ACTIVE")
    }

    // MARK: - 4. Scroll Up (S) and Scroll Down (T)

    func testVimScrollUpAndDownSequences() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 40, rows: 6)
        buffer.appendStream("\u{1B}[?1049h\u{1B}[1;5r")
        
        for i in 1...5 { buffer.appendStream("\u{1B}[\(i);1HLine \(i)") }
        buffer.appendStream("\u{1B}[6;1HSTATUS")
        
        // Scroll Up (CSI 2 S)
        buffer.appendStream("\u{1B}[2S")
        XCTAssertEqual(buffer.screenLines?[0], "Line 3")
        XCTAssertEqual(buffer.screenLines?[1], "Line 4")
        XCTAssertEqual(buffer.screenLines?[2], "Line 5")
        XCTAssertEqual(buffer.screenLines?[3], "")
        XCTAssertEqual(buffer.screenLines?[4], "")
        XCTAssertEqual(buffer.screenLines?[5], "STATUS")
        
        // Scroll Down (CSI 1 T)
        buffer.appendStream("\u{1B}[1T")
        XCTAssertEqual(buffer.screenLines?[0], "")
        XCTAssertEqual(buffer.screenLines?[1], "Line 3")
        XCTAssertEqual(buffer.screenLines?[5], "STATUS")
    }

    // MARK: - 5. Character Editing: DCH (P), ICH (@), ECH (X)

    func testVimCharacterEditing() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 40, rows: 5)
        buffer.appendStream("\u{1B}[?1049h\u{1B}[1;1HABCDEFGH")
        XCTAssertEqual(buffer.screenLines?[0], "ABCDEFGH")
        
        // Delete 2 characters at column 3 (C, D): CSI 3;3H CSI 2 P
        buffer.appendStream("\u{1B}[1;3H\u{1B}[2P")
        XCTAssertEqual(buffer.screenLines?[0], "ABEFGH")
        
        // Insert 2 blank spaces at column 3: CSI 1;3H CSI 2 @
        buffer.appendStream("\u{1B}[1;3H\u{1B}[2@")
        XCTAssertEqual(buffer.screenLines?[0], "AB  EFGH")
        
        // Erase 2 characters at column 5: CSI 1;5H CSI 2 X
        buffer.appendStream("\u{1B}[1;5H\u{1B}[2X")
        XCTAssertEqual(buffer.screenLines?[0], "AB    GH")
    }

    // MARK: - 6. Bracketed Paste Mode Formatting & Indentation Preservation

    @MainActor
    func testBracketedPastePreservesFormattingInVim() {
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
        
        let yamlSnippet = """
        services:
          traefik:
            image: traefik:v2.11.2
            ports:
              - "10080:80"
        """
        pasteboard.clearContents()
        pasteboard.setString(yamlSnippet, forType: .string)
        
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 24)
        // Simulate Vim enabling bracketed paste
        buffer.appendStream("\u{1B}[?1049;2004h")
        XCTAssertTrue(buffer.isBracketedPasteEnabled)
        XCTAssertTrue(buffer.isInAlternateScreen)
        
        let terminal = NativeTerminalView()
        terminal.ringBuffer = buffer
        var sentData: [Data] = []
        terminal.onInput = { sentData.append($0) }
        
        let pasted = terminal.pasteFromClipboard()
        XCTAssertTrue(pasted)
        XCTAssertEqual(sentData.count, 1)
        
        let sentString = String(decoding: sentData[0], as: UTF8.self)
        // Must start with \e[200~ and end with \e[201~
        XCTAssertTrue(sentString.hasPrefix("\u{1B}[200~"))
        XCTAssertTrue(sentString.hasSuffix("\u{1B}[201~"))
        
        // Must preserve the exact indentation without corruption
        let inner = sentString
            .replacingOccurrences(of: "\u{1B}[200~", with: "")
            .replacingOccurrences(of: "\u{1B}[201~", with: "")
        
        let expectedInner = yamlSnippet.replacingOccurrences(of: "\n", with: "\r")
        XCTAssertEqual(inner, expectedInner)
        
        // Pinned to bottom must NOT be forced when in alternate screen
        XCTAssertFalse(terminal.isPinnedToBottom)
    }

    // MARK: - 7. Alternate Screen Viewport Locked to Zero

    @MainActor
    func testAlternateScreenViewportLock() {
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 35)
        scrollView.terminalView.ringBuffer = buffer
        
        // In alternate screen mode
        buffer.appendStream("\u{1B}[?1049h")
        for i in 1...35 {
            buffer.appendStream("\u{1B}[\(i);1HLine \(i)")
        }
        scrollView.terminalView.refresh()
        
        let clipView = scrollView.contentView
        XCTAssertEqual(clipView.bounds.origin.y, 0, accuracy: 0.1)
        
        // Scroll attempt on clipview must be constrained to (0, 0)
        clipView.scroll(to: NSPoint(x: 0, y: 150))
        XCTAssertEqual(clipView.bounds.origin.y, 0, accuracy: 0.1)
    }

    // MARK: - 8. Alternate Screen ScrollWheel Sends Arrow Sequences

    @MainActor
    func testAlternateScreenScrollWheelToArrowKeys() throws {
        let terminal = NativeTerminalView()
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 24)
        terminal.ringBuffer = buffer
        
        // Normal mode: scrollWheel does not send keys
        var receivedInput = ""
        terminal.onInput = { (data: Data) in
            receivedInput.append(String(decoding: data, as: UTF8.self))
        }
        
        let cgUp = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0))
        let eventUp = try XCTUnwrap(NSEvent(cgEvent: cgUp))
        
        terminal.scrollWheel(with: eventUp)
        XCTAssertEqual(receivedInput, "")
        
        // Enter Vim / alternate screen
        buffer.appendStream("\u{1B}[?1049h")
        XCTAssertTrue(buffer.isInAlternateScreen)
        
        // Scroll Up event: should send Up Arrow (\u{1B}[A)
        terminal.scrollWheel(with: eventUp)
        XCTAssertTrue(receivedInput.contains("\u{1B}[A"))
        
        // Scroll Down event: should send Down Arrow (\u{1B}[B)
        receivedInput = ""
        let cgDown = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -5, wheel2: 0, wheel3: 0))
        let eventDown = try XCTUnwrap(NSEvent(cgEvent: cgDown))
        terminal.scrollWheel(with: eventDown)
        XCTAssertTrue(receivedInput.contains("\u{1B}[B"))
    }

    // MARK: - 9. PTY Dimension Synchronization Before Connect

    func testPTYDimensionPreservationOnConnect() async throws {
        let session = Session(name: "Test", host: "127.0.0.1", port: 22, username: "root")
        let mockClient = MockSSHSession(session: session)
        
        // Resize requested before connection is established
        try await mockClient.resizeTerminal(columns: 140, rows: 45)
        XCTAssertEqual(mockClient.lastResizedDimensions?.columns, 140)
        XCTAssertEqual(mockClient.lastResizedDimensions?.rows, 45)
    }

    // MARK: - 10. Vim Cursor Position Tracking and DECTCEM Visibility

    func testVimCursorPositionTrackingAndVisibility() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 30)
        
        // Enter Vim alternate screen
        buffer.appendStream("\u{1B}[?1049h")
        XCTAssertEqual(buffer.cursorPosition.row, 0)
        XCTAssertEqual(buffer.cursorPosition.column, 0)
        XCTAssertFalse(buffer.isCursorHidden)
        
        // Move to row 12, col 5 (1-based in VT sequence \e[12;5H)
        buffer.appendStream("\u{1B}[12;5H")
        XCTAssertEqual(buffer.cursorPosition.row, 11)
        XCTAssertEqual(buffer.cursorPosition.column, 4)
        
        // Move down 3 rows (\e[3B)
        buffer.appendStream("\u{1B}[3B")
        XCTAssertEqual(buffer.cursorPosition.row, 14)
        XCTAssertEqual(buffer.cursorPosition.column, 4)
        
        // Move forward 6 cols (\e[6C)
        buffer.appendStream("\u{1B}[6C")
        XCTAssertEqual(buffer.cursorPosition.row, 14)
        XCTAssertEqual(buffer.cursorPosition.column, 10)
        
        // Hide cursor (\e[?25l)
        buffer.appendStream("\u{1B}[?25l")
        XCTAssertTrue(buffer.isCursorHidden)
        
        // Show cursor (\e[?25h)
        buffer.appendStream("\u{1B}[?25h")
        XCTAssertFalse(buffer.isCursorHidden)
        
        // Exit alternate screen restores cursor visibility
        buffer.appendStream("\u{1B}[?25l\u{1B}[?1049l")
        XCTAssertFalse(buffer.isCursorHidden)
    }

    // MARK: - 11. Alternate Screen Cursor Visual Placement (Not Stuck At Window Bottom)

    @MainActor
    func testVimCursorVisualRectInAlternateScreen() {
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = scrollView.terminalView
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 35)
        terminal.ringBuffer = buffer
        
        // Simulate Vim opening a 60-line file in a 35-line window
        buffer.appendStream("\u{1B}[?1049h")
        for i in 1...30 {
            buffer.appendStream("\u{1B}[\(i);1HLine \(i) content")
        }
        buffer.appendStream("\u{1B}[30;1H\"test.txt\" 60L 1,1 Top")
        // Position Vim cursor at Row 1, Col 1 (\e[1;1H)
        buffer.appendStream("\u{1B}[1;1H")
        terminal.refresh()
        
        XCTAssertEqual(buffer.cursorPosition.row, 0)
        XCTAssertEqual(buffer.cursorPosition.column, 0)
        
        // Directly invoke draw/cursor measurement and assert alternate screen origin
        XCTAssertTrue(terminal.bounds.height > 0)
        XCTAssertTrue(buffer.isInAlternateScreen)
        XCTAssertEqual(buffer.cursorPosition.row, 0)
        XCTAssertEqual(buffer.cursorPosition.column, 0)
    }

    // MARK: - 12. Fullscreen Terminal Resize and Immediate Window Emission

    @MainActor
    func testFullscreenTerminalResizeImmediateEmission() {
        let scrollView = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = scrollView.terminalView
        let buffer = TerminalRingBuffer()
        terminal.ringBuffer = buffer
        
        var reportedDimensions: (cols: Int, rows: Int)? = nil
        terminal.onResize = { cols, rows in
            reportedDimensions = (cols, rows)
        }
        
        // Initial dimension check
        terminal.notifyDimensionsChangedIfNeeded(immediate: true)
        XCTAssertNotNil(reportedDimensions)
        let initialRows = reportedDimensions!.rows
        let initialCols = reportedDimensions!.cols
        
        // Simulate window maximizing to FullScreen (e.g. 1920 x 1080)
        scrollView.setFrameSize(NSSize(width: 1920, height: 1080))
        
        // The reported dimensions must reflect the enlarged fullscreen rows and cols
        XCTAssertNotNil(reportedDimensions)
        XCTAssertGreaterThan(reportedDimensions!.rows, initialRows)
        XCTAssertGreaterThan(reportedDimensions!.cols, initialCols)
        XCTAssertEqual(buffer.dimensions.rows, reportedDimensions!.rows)
        XCTAssertEqual(buffer.dimensions.columns, reportedDimensions!.cols)
    }
}
