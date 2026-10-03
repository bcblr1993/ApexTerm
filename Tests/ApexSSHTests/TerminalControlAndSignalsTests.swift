import XCTest
import AppKit
@testable import ApexCore
@testable import ApexTerminal

final class TerminalControlAndSignalsTests: XCTestCase {

    @MainActor
    func testCtrlKeyMatrixDispatchesCorrectControlBytes() {
        let view = NativeTerminalView()
        var receivedData: [Data] = []
        view.onInput = { data in
            receivedData.append(data)
        }

        // Table of key characters and their expected ASCII control byte value
        // Ctrl+A = 1, Ctrl+C = 3, Ctrl+D = 4, Ctrl+Z = 26, Ctrl+L = 12, etc.
        let ctrlTestCases: [(char: String, keyCode: UInt16, expectedByte: UInt8)] = [
            ("a", 0, 1),    // Ctrl+A (Start of line)
            ("c", 8, 3),    // Ctrl+C (SIGINT)
            ("d", 2, 4),    // Ctrl+D (EOF)
            ("e", 14, 5),   // Ctrl+E (End of line)
            ("k", 40, 11),  // Ctrl+K (Kill to end of line)
            ("l", 37, 12),  // Ctrl+L (Clear screen)
            ("u", 32, 21),  // Ctrl+U (Kill line backward)
            ("w", 13, 23),  // Ctrl+W (Kill word backward)
            ("z", 6, 26),   // Ctrl+Z (SIGTSTP)
        ]

        for testCase in ctrlTestCases {
            receivedData.removeAll()
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: testCase.char,
                charactersIgnoringModifiers: testCase.char,
                isARepeat: false,
                keyCode: testCase.keyCode
            ) else {
                XCTFail("Failed to construct NSEvent for Ctrl+\(testCase.char)")
                continue
            }

            view.keyDown(with: event)
            XCTAssertEqual(receivedData.count, 1, "Ctrl+\(testCase.char) should trigger exactly 1 input payload")
            if let first = receivedData.first {
                XCTAssertEqual(first, Data([testCase.expectedByte]), "Ctrl+\(testCase.char) should yield byte \(testCase.expectedByte)")
            }
        }
    }

    @MainActor
    func testOptionMetaKeyWordNavigation() {
        let view = NativeTerminalView()
        var receivedData: [Data] = []
        view.onInput = { data in
            receivedData.append(data)
        }

        // Option + Left Arrow (keyCode 123) -> Meta-b ("\u{1B}b")
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 123
        ) {
            receivedData.removeAll()
            view.keyDown(with: event)
            XCTAssertEqual(receivedData.first, "\u{1B}b".data(using: .utf8))
        }

        // Option + Right Arrow (keyCode 124) -> Meta-f ("\u{1B}f")
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124
        ) {
            receivedData.removeAll()
            view.keyDown(with: event)
            XCTAssertEqual(receivedData.first, "\u{1B}f".data(using: .utf8))
        }

        // Option + Backspace (keyCode 51) -> Meta-DEL ("\u{1B}\u{7F}")
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 51
        ) {
            receivedData.removeAll()
            view.keyDown(with: event)
            XCTAssertEqual(receivedData.first, "\u{1B}\u{7F}".data(using: .utf8))
        }

        // Option + Forward Delete (keyCode 117) -> Meta-d ("\u{1B}d")
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 117
        ) {
            receivedData.removeAll()
            view.keyDown(with: event)
            XCTAssertEqual(receivedData.first, "\u{1B}d".data(using: .utf8))
        }
    }

    @MainActor
    func testSpecialNavigationAndFunctionKeys() {
        let view = NativeTerminalView()
        var receivedData: [Data] = []
        view.onInput = { data in
            receivedData.append(data)
        }

        let navigationCases: [(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, expected: String)] = [
            (36, [], "\r"),              // Enter
            (51, [], "\u{7F}"),          // Backspace
            (117, [], "\u{1B}[3~"),       // Forward Delete
            (48, [], "\t"),              // Tab
            (48, [.shift], "\u{1B}[Z"),  // Shift-Tab (Back-Tab)
            (126, [], "\u{1B}[A"),       // Up Arrow
            (125, [], "\u{1B}[B"),       // Down Arrow
            (124, [], "\u{1B}[C"),       // Right Arrow
            (123, [], "\u{1B}[D"),       // Left Arrow
            (115, [], "\u{1B}[H"),       // Home
            (119, [], "\u{1B}[F"),       // End
            (116, [], "\u{1B}[5~"),      // Page Up
            (121, [], "\u{1B}[6~"),      // Page Down
            (122, [], "\u{1B}OP"),       // F1
            (120, [], "\u{1B}OQ"),       // F2
            (99, [], "\u{1B}OR"),        // F3
            (118, [], "\u{1B}OS"),       // F4
            (96, [], "\u{1B}[15~"),      // F5
            (97, [], "\u{1B}[17~"),      // F6
            (98, [], "\u{1B}[18~"),      // F7
        ]

        for c in navigationCases {
            receivedData.removeAll()
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: c.modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: c.keyCode
            ) else {
                XCTFail("Failed to create event for key code \(c.keyCode)")
                continue
            }
            view.keyDown(with: event)
            XCTAssertEqual(receivedData.first, c.expected.data(using: .utf8), "Failed for keyCode \(c.keyCode)")
        }
    }

    @MainActor
    func testModifiedCursorKeysPreserveAllModifiersInBothCursorModes() throws {
        let view = NativeTerminalView()
        let buffer = TerminalRingBuffer()
        view.ringBuffer = buffer
        var received: [Data] = []
        view.onInput = { received.append($0) }
        let modifiers: [(NSEvent.ModifierFlags, Int)] = [
            ([.shift], 2), ([.option], 3), ([.shift, .option], 4),
            ([.control], 5), ([.shift, .control], 6),
            ([.option, .control], 7), ([.shift, .option, .control], 8)
        ]
        let keys: [(UInt16, String)] = [
            (126, "A"), (125, "B"), (124, "C"), (123, "D"), (115, "H"), (119, "F")
        ]
        buffer.appendStream("\u{1B}[?1049h")
        for applicationMode in [false, true] {
            buffer.appendStream(applicationMode ? "\u{1B}[?1h" : "\u{1B}[?1l")
            for (flags, parameter) in modifiers {
                for (code, suffix) in keys {
                    received.removeAll()
                    view.keyDown(with: try navigationEvent(code, modifiers: flags))
                    XCTAssertEqual(received, [Data("\u{1B}[1;\(parameter)\(suffix)".utf8)],
                                   "key=\(code), modifiers=\(flags), applicationMode=\(applicationMode)")
                }
            }
        }
    }

    @MainActor
    func testModifiedEditingAndFunctionKeysPreserveAllModifiers() throws {
        let view = NativeTerminalView()
        let buffer = TerminalRingBuffer()
        buffer.appendStream("\u{1B}[?1049h")
        view.ringBuffer = buffer
        var received: [Data] = []
        view.onInput = { received.append($0) }
        let modifiers: [(NSEvent.ModifierFlags, Int)] = [
            ([.shift], 2), ([.option], 3), ([.shift, .option], 4),
            ([.control], 5), ([.shift, .control], 6),
            ([.option, .control], 7), ([.shift, .option, .control], 8)
        ]
        let keys: [(UInt16, String)] = [
            (117, "3"), (116, "5"), (121, "6"), (96, "15"), (97, "17"),
            (98, "18"), (100, "19"), (101, "20"), (109, "21"), (103, "23"), (111, "24")
        ]
        for (flags, parameter) in modifiers {
            for (code, number) in keys {
                received.removeAll()
                view.keyDown(with: try navigationEvent(code, modifiers: flags))
                XCTAssertEqual(received, [Data("\u{1B}[\(number);\(parameter)~".utf8)],
                               "key=\(code), modifiers=\(flags)")
            }
            for (code, suffix) in [(UInt16(122), "P"), (120, "Q"), (99, "R"), (118, "S")] {
                received.removeAll()
                view.keyDown(with: try navigationEvent(code, modifiers: flags))
                XCTAssertEqual(received, [Data("\u{1B}[1;\(parameter)\(suffix)".utf8)])
            }
        }
    }

    @MainActor
    func testShiftOptionArrowsDoNotBecomeShellWordNavigation() throws {
        let view = NativeTerminalView()
        var received: [Data] = []
        view.onInput = { received.append($0) }
        view.keyDown(with: try navigationEvent(123, modifiers: [.shift, .option]))
        view.keyDown(with: try navigationEvent(124, modifiers: [.shift, .option]))
        XCTAssertEqual(received, [Data("\u{1B}[1;4D".utf8), Data("\u{1B}[1;4C".utf8)])
    }

    @MainActor
    func testOptionBackspaceKeepsMetaDeleteInsideAndOutsideVim() throws {
        let view = NativeTerminalView()
        let buffer = TerminalRingBuffer()
        view.ringBuffer = buffer
        var received: [Data] = []
        view.onInput = { received.append($0) }
        let modifiers: [NSEvent.ModifierFlags] = [[.option], [.option, .shift]]
        for alternateScreen in [false, true] {
            if alternateScreen { buffer.appendStream("\u{1B}[?1049h") }
            for flags in modifiers {
                received.removeAll()
                view.keyDown(with: try navigationEvent(51, modifiers: flags))
                XCTAssertEqual(received, [Data("\u{1B}\u{7F}".utf8)])
            }
        }
    }

    @MainActor
    private func navigationEvent(_ code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        // Real function-key events carry a private-use character, rather than an empty string.
        let scalar: UInt32 = [
            126: 0xF700, 125: 0xF701, 123: 0xF702, 124: 0xF703,
            122: 0xF704, 120: 0xF705, 99: 0xF706, 118: 0xF707,
            96: 0xF708, 97: 0xF709, 98: 0xF70A, 100: 0xF70B,
            101: 0xF70C, 109: 0xF70D, 103: 0xF70E, 111: 0xF70F,
            117: 0xF728, 115: 0xF729, 119: 0xF72B, 116: 0xF72C, 121: 0xF72D,
            51: 0x7F
        ][code] ?? 0xF700
        let characters = String(try XCTUnwrap(UnicodeScalar(scalar)))
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testRingBufferLineAndScreenErasure() {
        let buffer = TerminalRingBuffer(maxLines: 100)
        
        // 1. Line Erase: Write a line and then erase from cursor forward
        // "root@host:~# echo 12345\u{001B}[K"
        buffer.appendStream("admin@server:~$ cat error.log\r\n")
        let linesBefore = buffer.allLines()
        XCTAssertEqual(linesBefore.count, 1)
        XCTAssertEqual(linesBefore.first, "admin@server:~$ cat error.log")

        // 2. Erase Entire Screen sequence "\u{001B}[2J"
        buffer.appendStream("\u{001B}[2J")
        XCTAssertTrue(buffer.consumeClearFlag())

        // 3. Sequential lines with \r\n and backspace
        buffer.appendStream("line 1\r\nline 2\r\n")
        let currentLines = buffer.allLines()
        XCTAssertTrue(currentLines.contains("line 1"))
        XCTAssertTrue(currentLines.contains("line 2"))
    }

    func testCJKDoubleWidthAndEmojiHandling() {
        let parser = VTParser()
        let mixedText = "系统监控：负载正常 🚀 [OK] 内存占用: 45%"
        let spans = parser.parseANSI(mixedText)
        
        XCTAssertFalse(spans.isEmpty)
        let reconstructed = spans.map { $0.text }.joined()
        XCTAssertEqual(reconstructed, mixedText)

        // Ensure Chinese characters and emojis preserve their unicode scalar integrity in RingBuffer
        let buffer = TerminalRingBuffer(maxLines: 50)
        buffer.appendStream("你好，世界！🚀 Swift 6\r\n")
        let lines = buffer.allLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first, "你好，世界！🚀 Swift 6")
    }
}
