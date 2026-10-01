import XCTest
import AppKit
import ApexCore
@testable import ApexTerminal

final class TerminalUnicodeRegressionTests: XCTestCase {
    @MainActor
    func testLiveFontSizeChangeKeepsExistingUnicodeOnCellBoundaries() throws {
        let settings = AppSettings.shared
        let oldSize = settings.fontSize, oldName = settings.fontName
        defer { settings.fontSize = oldSize; settings.fontName = oldName }
        settings.fontName = "Menlo"
        settings.fontSize = 13
        let terminal = NativeTerminalView()
        terminal.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let buffer = TerminalRingBuffer()
        terminal.ringBuffer = buffer
        buffer.appendStream("A中🚀e\u{301}X\r\n")
        terminal.refresh()
        settings.fontSize = 18
        terminal.applyAppSettings()
        let layout = try XCTUnwrap(terminal.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(terminal.textContainer))
        let width = ("M" as NSString).size(withAttributes: [.font: try XCTUnwrap(NSFont(name: "Menlo", size: 18))]).width
        let index = (terminal.string as NSString).range(of: "X").location
        XCTAssertEqual(layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: index)).x, width * 6, accuracy: 0.5)
    }

    @MainActor
    func testConfiguredFontSizesKeepMixedTextOnCellBoundaries() throws {
        let settings = AppSettings.shared
        let oldSize = settings.fontSize
        let oldName = settings.fontName
        defer { settings.fontSize = oldSize; settings.fontName = oldName }
        for name in ["System Monospaced", "Menlo"] {
            settings.fontName = name
            for size in [11.0, 13.0, 18.0, 22.0] {
                settings.fontSize = size
                let terminal = NativeTerminalView()
                terminal.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
                let font = try XCTUnwrap(terminal.font)
                let width = ("M" as NSString).size(withAttributes: [.font: font]).width
                let layout = try XCTUnwrap(terminal.layoutManager)
                let container = try XCTUnwrap(terminal.textContainer)
                for (text, columns) in [("A中🚀e\u{301}X", 6), ("A👩‍💻👍🏽🇨🇳❤️X", 9)] {
                    terminal.textStorage?.setAttributedString(terminal.formatANSI(text))
                    layout.ensureLayout(for: container)
                    let glyph = layout.glyphIndexForCharacter(at: text.utf16.count - 1)
                    XCTAssertEqual(layout.location(forGlyphAt: glyph).x, width * CGFloat(columns), accuracy: 0.5, "\(name) \(size) \(text)")
                }
            }
        }
    }

    @MainActor
    func testRenderedWideGlyphAdvancesMatchCursorGrid() throws {
        let terminal = NativeTerminalView()
        terminal.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let font = try XCTUnwrap(terminal.font)
        let dimensionsBeforeOutput = terminal.calculateTerminalDimensions()
        terminal.textStorage?.setAttributedString(terminal.formatANSI("中🚀X"))
        let layout = try XCTUnwrap(terminal.layoutManager)
        let container = try XCTUnwrap(terminal.textContainer)
        container.containerSize = NSSize(width: 800, height: 600)
        layout.ensureLayout(for: container)
        let columnWidth = max(6, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let glyph = layout.glyphIndexForCharacter(at: 3)
        XCTAssertEqual(layout.location(forGlyphAt: glyph).x, columnWidth * 4, accuracy: 0.5)
        XCTAssertEqual(terminal.calculateTerminalDimensions().cols, dimensionsBeforeOutput.cols)
        XCTAssertEqual(terminal.calculateTerminalDimensions().rows, dimensionsBeforeOutput.rows)
        let next = terminal.formatANSI("next")
        XCTAssertEqual((next.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName, font.fontName)
    }

    func testPTYBytePacketsPreserveChineseAndEmoji() {
        let buffer = TerminalRingBuffer()
        for byte in "中文🚀\r\n".utf8 { buffer.appendData(Data([byte])) }
        XCTAssertEqual(buffer.allLines(), ["中文🚀"])
    }

    func testAlternateScreenCJKAndEmojiUseTwoColumns() {
        let buffer = TerminalRingBuffer()
        buffer.appendStream("\u{1B}[?1049h中🚀X")
        XCTAssertEqual(buffer.cursorPosition.column, 5)
        XCTAssertEqual(buffer.screenLines?.first, "中🚀X")
        buffer.appendStream("\u{1B}[1;2HY")
        XCTAssertEqual(buffer.screenLines?.first, " Y🚀X", "Overwrite half a wide glyph without leaving a broken character")
    }

    func testWideCharacterWrapsBeforeRightMargin() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 5, rows: 3)
        buffer.appendStream("\u{1B}[?1049habcd中")
        XCTAssertEqual(buffer.screenLines?[0], "abcd")
        XCTAssertEqual(buffer.screenLines?[1], "中")
        XCTAssertEqual(buffer.cursorPosition.row, 1)
        XCTAssertEqual(buffer.cursorPosition.column, 2)
    }

    func testShellCursorMapsColumnsToUTF16() {
        let buffer = TerminalRingBuffer()
        buffer.appendStream("中🚀X\u{1B}[1D")
        XCTAssertEqual(buffer.cursorColumn, 4)
        XCTAssertEqual(buffer.activeCursorUTF16Offset, 3)
        buffer.appendStream("Y")
        XCTAssertEqual(buffer.currentActiveLine, "中🚀Y")
    }

    func testCombiningMarkPacketDoesNotAdvanceCursor() {
        let buffer = TerminalRingBuffer()
        buffer.appendStream("\u{1B}[?1049he")
        buffer.appendStream("\u{301}")
        XCTAssertEqual(buffer.screenLines?.first, "e\u{301}")
        XCTAssertEqual(buffer.cursorPosition.column, 1)
    }

    func testWideGlyphBoundariesSurviveResizeEraseInsertAndDelete() {
        for control in ["\u{1B}[1;2H\u{1B}[X", "\u{1B}[1;2H\u{1B}[P", "\u{1B}[1;2H\u{1B}[@", "\u{1B}[1;2H\u{1B}[K"] {
            let buffer = TerminalRingBuffer()
            buffer.appendStream("\u{1B}[?1049h中A" + control)
            XCTAssertFalse(buffer.screenLines![0].contains("中"), "A split wide glyph must be cleared")
        }
        let buffer = TerminalRingBuffer()
        buffer.appendStream("\u{1B}[?1049hA中")
        buffer.setDimensions(columns: 2, rows: 3)
        XCTAssertEqual(buffer.screenLines?[0], "A")
    }

    func testFragmentedEmojiGraphemesStayInTheirOriginalCells() {
        let buffer = TerminalRingBuffer()
        buffer.appendStream("\u{1B}[?1049h")
        let text = "👩‍💻👍🏽🇨🇳❤️"
        for byte in text.utf8 { buffer.appendData(Data([byte])) }
        XCTAssertEqual(buffer.screenLines?.first, text)
        XCTAssertEqual(buffer.cursorPosition.column, 8)
    }

    func testVariationSelectorCanWrapItsEntireGrapheme() {
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 3, rows: 3)
        buffer.appendStream("\u{1B}[?1049hab❤")
        buffer.appendStream("\u{FE0F}")
        XCTAssertEqual(buffer.screenLines?[0], "ab")
        XCTAssertEqual(buffer.screenLines?[1], "❤️")
        XCTAssertEqual(buffer.cursorPosition.column, 2)
    }

    func testXterm256ColorCubeLevels() {
        XCTAssertEqual(VTParser.colorFrom256Palette(17), "#00005F")
        XCTAssertEqual(VTParser.colorFrom256Palette(67), "#5F87AF")
        XCTAssertEqual(VTParser.colorFrom256Palette(231), "#FFFFFF")
    }
}
