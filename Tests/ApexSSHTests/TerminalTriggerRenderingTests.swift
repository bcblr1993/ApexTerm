import XCTest
import AppKit
@testable import ApexCore
@testable import ApexTerminal

final class TerminalTriggerRenderingTests: XCTestCase {
    @MainActor
    func testTriggerColorsReachRenderedOutputAndCanBeDisabled() throws {
        let scroll = NativeTerminalScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = scroll.terminalView
        let buffer = TerminalRingBuffer()
        terminal.ringBuffer = buffer
        let trigger = Trigger(name: "Error", regexPattern: "error", action: .highlight(colorHex: "#FF0000"))
        terminal.setTriggers([trigger])
        buffer.appendStream("ERROR 中文\r\n")
        terminal.refresh()
        let color = try XCTUnwrap(terminal.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor).usingColorSpace(.deviceRGB)!
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.001)
        terminal.setTriggers([])
        let restored = try XCTUnwrap(terminal.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertNotEqual(restored, color)
        XCTAssertEqual(terminal.string, "ERROR 中文\n")
    }
}
