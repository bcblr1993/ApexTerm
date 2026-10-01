import XCTest
import AppKit
import ApexCore
@testable import ApexTerminal

final class TerminalFontShortcutTests: XCTestCase {
    @MainActor
    func testFontShortcutsClampResetAndNeverSendRemoteInput() throws {
        let settings = AppSettings.shared
        let previous = settings.fontSize
        defer { settings.fontSize = previous }
        let terminal = NativeTerminalView(frame: .zero, textContainer: nil)
        var sent = Data()
        terminal.onInput = { sent.append($0) }
        func press(_ character: String) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
            terminal.keyDown(with: event)
        }
        settings.fontSize = 22
        try press("=")
        XCTAssertEqual(settings.fontSize, 22)
        try press("-")
        XCTAssertEqual(settings.fontSize, 21)
        settings.fontSize = 10
        try press("-")
        XCTAssertEqual(settings.fontSize, 10)
        try press("0")
        XCTAssertEqual(settings.fontSize, 13)
        XCTAssertTrue(sent.isEmpty)
    }
}
