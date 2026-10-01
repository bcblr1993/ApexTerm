import XCTest
import AppKit
@testable import ApexTerminal

final class TerminalStyleRegressionTests: XCTestCase {
    func testStylesAndBackgroundSurviveScreenCellEdits() throws {
        let buffer = TerminalRingBuffer()
        buffer.appendStream("\u{1B}[?1049h\u{1B}[1;3;4;7;9;48;2;12;34;56mA")
        buffer.appendStream("B\u{1B}[22;23;24;27;29;49mC")
        let spans = VTParser().parseANSI(try XCTUnwrap(buffer.screenLines?.first))
        XCTAssertEqual(spans.map(\.text), ["AB", "C"])
        XCTAssertTrue(spans[0].isBold)
        XCTAssertTrue(spans[0].isItalic)
        XCTAssertTrue(spans[0].isUnderlined)
        XCTAssertTrue(spans[0].isStrikethrough)
        XCTAssertTrue(spans[0].isInverse)
        XCTAssertEqual(spans[0].backgroundColorHex, "#0C2238")
        XCTAssertFalse(spans[1].isBold)
        XCTAssertFalse(spans[1].isItalic)
        XCTAssertFalse(spans[1].isUnderlined)
        XCTAssertFalse(spans[1].isInverse)
        XCTAssertNil(spans[1].backgroundColorHex)
    }

    func testEraseRetainsBackgroundThroughRightMargin() throws {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 5, rows: 3)
        buffer.appendStream("\u{1B}[?1049hABCDE\u{1B}[1;3H\u{1B}[44m\u{1B}[K")
        let spans = VTParser().parseANSI(try XCTUnwrap(buffer.screenLines?.first))
        XCTAssertEqual(spans.map(\.text), ["AB", "   "])
        XCTAssertEqual(spans.last?.backgroundANSIColorIndex, 4)
        buffer.appendStream("\u{1B}[0m\u{1B}[2;2H\u{1B}[1J")
        XCTAssertEqual(buffer.screenLines?.first, "")
    }

    @MainActor
    func testTextStorageReceivesUnderlineStrikeBackgroundAndInverse() throws {
        let terminal = NativeTerminalView()
        let styled = terminal.formatANSI("\u{1B}[4;9;48;2;12;34;56mA\u{1B}[0mB\u{1B}[7mC")
        XCTAssertEqual(styled.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(styled.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        let background = try XCTUnwrap(styled.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor).usingColorSpace(.deviceRGB)!
        XCTAssertEqual(background.redComponent, 12.0/255, accuracy: 0.001)
        XCTAssertNil(styled.attribute(.backgroundColor, at: 1, effectiveRange: nil))
        XCTAssertNotNil(styled.attribute(.backgroundColor, at: 2, effectiveRange: nil))
    }
}
