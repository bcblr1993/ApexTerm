import XCTest
import AppKit
@testable import ApexTerminal

final class VimViewportRegressionTests: XCTestCase {
    @MainActor
    func testScrollViewFrameChangesNotifyFinalViewportDimensions() async throws {
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let terminal = scroll.terminalView
        terminal.ringBuffer = TerminalRingBuffer()
        var reported: [(Int, Int)] = []
        terminal.onResize = { reported.append(($0, $1)) }
        terminal.notifyDimensionsChangedIfNeeded(immediate: true)
        let initial = terminal.calculateTerminalDimensions()
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let final = terminal.calculateTerminalDimensions()
        XCTAssertGreaterThan(final.rows, initial.rows)
        XCTAssertEqual(reported.last?.1, final.rows)
    }

    @MainActor
    func testRepeatedLayoutAtSameSizeDoesNotPostponePTYResize() async throws {
        let terminal = NativeTerminalView()
        terminal.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        var resizeCount = 0
        terminal.onResize = { _, _ in resizeCount += 1 }
        for _ in 0..<30 {
            terminal.notifyDimensionsChangedIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(resizeCount, 1, "Identical layout passes must not restart the resize debounce")
        terminal.frame.size = NSSize(width: 1000, height: 700)
        terminal.notifyDimensionsChangedIfNeeded()
        terminal.frame.size = NSSize(width: 800, height: 600)
        terminal.notifyDimensionsChangedIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(resizeCount, 1, "Returning to the reported size must cancel the stale resize")
        terminal.ringBuffer = TerminalRingBuffer()
        terminal.notifyDimensionsChangedIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(resizeCount, 2, "A new session needs the viewport size even when its frame is unchanged")
    }

    func testFragmentedCharsetSelectionDoesNotPrintGarbage() {
        let buffer = TerminalRingBuffer()
        buffer.appendStream("\u{1B}[?1049h\u{1B}(")
        buffer.appendStream("Bhello")
        XCTAssertEqual(buffer.screenLines?.first, "hello")
        XCTAssertEqual(buffer.cursorPosition.column, 5)
    }

    @MainActor
    func testAppKitArrowCommandsRespectVimApplicationMode() {
        let terminal = NativeTerminalView()
        let buffer = TerminalRingBuffer()
        terminal.ringBuffer = buffer
        buffer.appendStream("\u{1B}[?1049h\u{1B}[?1h")
        var input = Data()
        terminal.onInput = { input.append($0) }
        terminal.doCommand(by: #selector(NSResponder.moveDown(_:)))
        terminal.doCommand(by: #selector(NSResponder.moveRight(_:)))
        XCTAssertEqual(input, Data("\u{1B}OB\u{1B}OC".utf8))
    }

    @MainActor
    func testRealVimPTYArrowsPasteCursorAndSave() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", #"""
import os, pty, subprocess, select, time, fcntl, termios, struct, tempfile, json, base64
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
with tempfile.TemporaryDirectory(prefix='apex-vim-') as directory:
    path = os.path.join(directory, 'edit.txt')
    child = subprocess.Popen(['/usr/bin/vim', '-Nu', 'NONE', '-n', path],
        stdin=slave, stdout=slave, stderr=slave, env=dict(os.environ, TERM='xterm-256color'))
    os.close(slave)
    def read():
        output = b''
        deadline = time.monotonic() + 0.4
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.05)[0]:
                try: output += os.read(master, 65536)
                except OSError: break
        return output
    try:
        initial = read()
        os.write(master, b'i\x1b[200~one\ntwo\nthree\x1b[201~\x1bgg\x1bOB')
        editing = read()
        os.write(master, b':wq\r')
        exiting = read()
        child.wait(timeout=3)
        with open(path) as saved: text = saved.read()
        print(json.dumps(dict(initial=base64.b64encode(initial).decode(),
            editing=base64.b64encode(editing).decode(), exiting=base64.b64encode(exiting).decode(), saved=text)))
    finally:
        if child.poll() is None: child.kill(); child.wait()
        os.close(master)
"""#]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: String])
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 24)
        // Replay each byte separately to exercise arbitrary SSH packet boundaries.
        for key in ["initial", "editing"] {
            let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result[key])))
            for byte in bytes { buffer.appendStream(String(UnicodeScalar(byte))) }
        }
        let parser = VTParser()
        let lines = try XCTUnwrap(buffer.screenLines).map { parser.parseANSI($0).map(\.text).joined() }
        XCTAssertEqual(Array(lines.prefix(3)), ["one", "two", "three"])
        XCTAssertEqual(buffer.cursorPosition.row, 1)
        XCTAssertEqual(buffer.cursorPosition.column, 0)
        XCTAssertFalse(buffer.isCursorHidden)
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.terminalView.ringBuffer = buffer
        scroll.terminalView.refresh()
        let cursor = try XCTUnwrap(scroll.terminalView.terminalCursorRect)
        XCTAssertTrue(scroll.contentView.bounds.contains(cursor))
        buffer.appendStream(String(decoding: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result["exiting"]))), as: UTF8.self))
        XCTAssertFalse(buffer.isInAlternateScreen)
        XCTAssertEqual(result["saved"], "one\ntwo\nthree\n")
    }

    @MainActor
    func testCommandShortcutsNeverInsertCharactersIntoVim() throws {
        let terminal = NativeTerminalView()
        let buffer = TerminalRingBuffer()
        terminal.ringBuffer = buffer
        buffer.appendStream("\u{1B}[?1049hhello")
        terminal.refresh()
        var input = Data()
        terminal.onInput = { input.append($0) }
        for (letter, keyCode) in [("c", UInt16(8)), ("a", UInt16(0)), ("s", UInt16(1))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: letter, charactersIgnoringModifiers: letter, isARepeat: false, keyCode: keyCode))
            terminal.keyDown(with: event)
        }
        XCTAssertTrue(input.isEmpty)
    }

    func testPlainTextPacketsStayOnVimScreen() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 20, rows: 5)
        buffer.appendStream("\u{1B}[?1049h\u{1B}[2;3H")
        buffer.appendStream("hello")
        buffer.appendStream(" world")
        XCTAssertEqual(buffer.screenLines?[1], "  hello world")
        XCTAssertEqual(buffer.cursorPosition.column, 13)
        XCTAssertEqual(buffer.committedLineCount, 0)
    }

    func testLineFeedPreservesColumnAndCRLFResetsIt() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 20, rows: 5)
        buffer.appendStream("\u{1B}[?1049h\u{1B}[1;4H\nX\r\nY")
        XCTAssertEqual(buffer.screenLines?[1], "   X")
        XCTAssertEqual(buffer.screenLines?[2], "Y")
    }

    func testReverseIndexScrollsOnlyVimRegion() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 20, rows: 5)
        buffer.appendStream("\u{1B}[?1049h")
        for row in 1...5 { buffer.appendStream("\u{1B}[\(row);1Hline\(row)") }
        buffer.appendStream("\u{1B}[2;4r\u{1B}[2;1H\u{1B}M")
        XCTAssertEqual(buffer.screenLines, ["line1", "", "line2", "line3", "line5"])
        XCTAssertEqual(buffer.cursorPosition.row, 1)
    }

    func testShrinkingScreenTruncatesColumns() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 20, rows: 5)
        buffer.appendStream("\u{1B}[?1049h1234567890")
        buffer.setDimensions(columns: 5, rows: 3)
        XCTAssertEqual(buffer.screenLines?.first, "12345")
        XCTAssertEqual(buffer.screenLines?.count, 3)
    }

    @MainActor
    func testPTYDimensionsUseViewportInsteadOfScrollbackHeight() {
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = scroll.terminalView
        let before = terminal.calculateTerminalDimensions()
        terminal.setFrameSize(NSSize(width: 1600, height: 10000))
        let after = terminal.calculateTerminalDimensions()
        XCTAssertEqual(after.cols, before.cols)
        XCTAssertEqual(after.rows, before.rows)
        scroll.setFrameSize(NSSize(width: 400, height: 250))
        let smaller = terminal.calculateTerminalDimensions()
        XCTAssertLessThan(smaller.cols, before.cols)
        XCTAssertLessThan(smaller.rows, before.rows)
    }

    @MainActor
    func testCursorOnlyRefreshDoesNotReplaceTextStorage() {
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = scroll.terminalView
        let buffer = TerminalRingBuffer()
        terminal.ringBuffer = buffer
        buffer.appendStream("\u{1B}[?1049hhello")
        terminal.refresh()
        let recorder = EditRecorder()
        terminal.textStorage?.delegate = recorder
        buffer.appendStream("\u{1B}[2;3H")
        terminal.refresh()
        XCTAssertEqual(recorder.edits, 0)
    }

    @MainActor
    func testStyledScreenRefreshKeepsSelectionAndUpdatesOnlyChangedRows() throws {
        let terminal = NativeTerminalView()
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 24)
        terminal.ringBuffer = buffer
        buffer.appendStream("\u{1B}[?1049h\u{1B}[31mred\u{1B}[0m\r\nsecond\r\nthird")
        terminal.refresh()
        let storage = try XCTUnwrap(terminal.textStorage)
        let firstRow = storage.attributedSubstring(from: NSRange(location: 0, length: 4))
        terminal.setSelectedRange(NSRange(location: 0, length: 3))
        buffer.appendStream("\u{1B}[2;1HSECOND")
        terminal.refresh()
        XCTAssertEqual(terminal.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertTrue(storage.attributedSubstring(from: NSRange(location: 0, length: 4)).isEqual(to: firstRow))
        XCTAssertTrue(storage.string.contains("SECOND"))
        buffer.setDimensions(columns: 40, rows: 12)
        terminal.refresh()
        XCTAssertEqual(storage.string.components(separatedBy: "\n").count, 12)
        XCTAssertTrue(storage.string.contains("SECOND"))
        buffer.appendStream("\u{1B}[?1049l\u{1B}[?1049hnew screen")
        terminal.refresh()
        XCTAssertTrue(storage.string.hasPrefix("new screen"))
        XCTAssertFalse(storage.string.contains("SECOND"))
    }

    @MainActor
    func testCursorRefreshPerformanceOnStyledVimScreen() {
        let terminal = NativeTerminalView()
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 120, rows: 40)
        terminal.ringBuffer = buffer
        buffer.appendStream("\u{1B}[?1049h")
        for row in 1...40 {
            buffer.appendStream("\u{1B}[\(row);1H\u{1B}[\(31 + row % 6)m" + String(repeating: "styled text ", count: 9))
        }
        terminal.refresh()
        measure {
            for column in 1...100 {
                buffer.appendStream("\u{1B}[20;\(column)H")
                terminal.refresh()
            }
        }
    }
}

@MainActor
private final class EditRecorder: NSObject, @preconcurrency NSTextStorageDelegate {
    var edits = 0
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        edits += 1
    }
}
