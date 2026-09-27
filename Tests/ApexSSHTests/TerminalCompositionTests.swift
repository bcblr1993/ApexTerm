import XCTest
import AppKit
@testable import ApexTerminal

final class TerminalCompositionTests: XCTestCase {
    @MainActor
    func testCompositionDoesNotTransmitUntilCandidateCommitted() {
        let terminal = NativeTerminalView()
        terminal.textStorage?.setAttributedString(NSAttributedString(string: "host % "))
        var inputs: [Data] = []
        terminal.onInput = { inputs.append($0) }
        terminal.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(terminal.hasMarkedText())
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(terminal.string, "host % ", "Preedit must not overwrite remote output")
        terminal.insertText(NSAttributedString(string: "中文🙂"),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(inputs, [Data("中文🙂".utf8)])
        XCTAssertFalse(terminal.hasMarkedText())
        XCTAssertEqual(terminal.markedRange().location, NSNotFound)
    }

    @MainActor
    func testDiscardingCompositionDoesNotSendRemoteInput() {
        let terminal = NativeTerminalView()
        var inputs: [Data] = []
        terminal.onInput = { inputs.append($0) }
        terminal.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.unmarkText()
        XCTAssertFalse(terminal.hasMarkedText())
        XCTAssertTrue(inputs.isEmpty)
    }
    @MainActor
    func testPreeditRendersWithoutChangingRemoteOutputAndDisappearsOnCancel() throws {
        _ = NSApplication.shared
        let terminal = NativeTerminalView()
        terminal.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        terminal.isVerticallyResizable = false
        terminal.isHorizontallyResizable = false
        terminal.textContainer?.containerSize = NSSize(width: 420, height: 100)
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.backgroundColor = .white
        terminal.textColor = .black
        terminal.textStorage?.setAttributedString(NSAttributedString(string: "host % ", attributes: [.font: terminal.font!, .foregroundColor: NSColor.black]))
        terminal.layoutManager?.ensureLayout(for: try XCTUnwrap(terminal.textContainer))
        func pixels() throws -> Data {
            // A CI worker can have no WindowServer backing; draw into a real offscreen bitmap.
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 420, pixelsHigh: 100,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            context.cgContext.translateBy(x: 0, y: 100)
            context.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            print("Composition bitmap: bounds=\(terminal.bounds), origin=\(terminal.textContainerOrigin), font=\(String(describing: terminal.font)), glyphBounds=\(terminal.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 0, length: terminal.layoutManager!.numberOfGlyphs), in: terminal.textContainer!)), marked=\(terminal.hasMarkedText())")
            terminal.draw(terminal.bounds)
            XCTAssertNotNil(NSGraphicsContext.current, "AppKit must retain the offscreen drawing context")
            context.cgContext.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
            context.cgContext.fill(CGRect(x: 410, y: 90, width: 5, height: 5))
            context.flushGraphics()
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 412, y: 7)).alphaComponent, 0,
                                 "The offscreen bitmap must receive actual drawing operations")
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let before = try pixels()
        terminal.setMarkedText("中文候选", selectedRange: NSRange(location: 4, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(terminal.markedRange(), NSRange(location: 7, length: 4))
        XCTAssertEqual(terminal.selectedRange(), NSRange(location: 11, length: 0))
        var actual = NSRange(location: NSNotFound, length: 0)
        XCTAssertEqual(terminal.attributedSubstring(forProposedRange: terminal.markedRange(), actualRange: &actual)?.string, "中文候选")
        XCTAssertEqual(actual, terminal.markedRange())
        XCTAssertEqual(terminal.string, "host % ")
        XCTAssertNotEqual(try pixels(), before, "Composition must be visible, not merely retained in state")
        terminal.unmarkText()
        XCTAssertEqual(try pixels(), before, "Cancel must remove the overlay and preserve terminal output")
    }

    @MainActor
    func testCandidateRectangleUsesActualCompositionRange() {
        let terminal = NativeTerminalView()
        terminal.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = terminal
        terminal.textStorage?.setAttributedString(NSAttributedString(string: "host % "))
        terminal.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        var actual = NSRange(location: NSNotFound, length: 0)
        let rect = terminal.firstRect(forCharacterRange: terminal.markedRange(), actualRange: &actual)
        XCTAssertEqual(actual, NSRange(location: 7, length: 2))
        XCTAssertGreaterThan(rect.width, 12)
        XCTAssertGreaterThan(rect.height, 0)
        let local = terminal.convert(window.convertFromScreen(rect), from: nil)
        XCTAssertTrue(terminal.bounds.intersects(local), "Candidate must remain at the terminal in window coordinates")
    }

}
