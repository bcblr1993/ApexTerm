import XCTest
import AppKit
@testable import ApexTerminal

final class TerminalMouseRegressionTests: XCTestCase {
    @MainActor
    func testRightButtonDragUsesButtonTwo() throws {
        let terminal = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: nil)
        let buffer = TerminalRingBuffer()
        terminal.ringBuffer = buffer
        buffer.appendStream("\u{1B}[?1002;1006h")
        var input = ""
        terminal.onInput = { input += String(decoding: $0, as: UTF8.self) }
        let location = terminal.convert(NSPoint(x: 11, y: 11), to: nil)
        for kind in [NSEvent.EventType.rightMouseDown, .rightMouseDragged, .rightMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch kind {
            case .rightMouseDown: terminal.rightMouseDown(with: event)
            case .rightMouseDragged: terminal.rightMouseDragged(with: event)
            default: terminal.rightMouseUp(with: event)
            }
        }
        XCTAssertEqual(input, "\u{1B}[<2;1;1M\u{1B}[<34;1;1M\u{1B}[<2;1;1m")
    }

    @MainActor
    func testSGRPressReleaseAndDragReports() throws {
        let terminal = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: nil)
        let buffer = TerminalRingBuffer()
        terminal.ringBuffer = buffer
        buffer.appendStream("\u{1B}[?1049;1002;1006h")
        var input = ""
        terminal.onInput = { input += String(decoding: $0, as: UTF8.self) }
        let location = terminal.convert(NSPoint(x: 11, y: 11), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        terminal.mouseDown(with: down)
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        terminal.mouseDragged(with: drag)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        terminal.mouseUp(with: up)
        XCTAssertEqual(input, "\u{1B}[<0;1;1M\u{1B}[<32;1;1M\u{1B}[<0;1;1m")
        buffer.appendStream("\u{1B}[?1002;1006l")
        XCTAssertEqual(buffer.mouseTrackingMode, 0)
        XCTAssertFalse(buffer.isSGRMouseEnabled)
    }
}
