import XCTest
@testable import ApexTerminal

final class VTParserStressTests: XCTestCase {
    func testVimAlternateScreenRendersRowsAndRestoresShell() {
        let terminal = TerminalRingBuffer()
        terminal.setDimensions(columns: 60, rows: 8)
        terminal.appendStream("shell prompt\n")
        terminal.appendStream("\u{001B}[?1049h\u{001B}[2J\u{001B}[Hname: traefik\r\nservices:\r\n  traefik:\r\n    image: traefik:v2.11")
        XCTAssertEqual(terminal.screenLines?[0], "name: traefik")
        XCTAssertEqual(terminal.screenLines?[1], "services:")
        XCTAssertEqual(terminal.screenLines?[3], "    image: traefik:v2.11")
        terminal.appendStream("\u{001B}[2;1Hupdated\u{001B}[K\u{001B}[8;1H1,1 Top")
        XCTAssertEqual(terminal.screenLines?[1], "updated")
        XCTAssertEqual(terminal.screenLines?[7], "1,1 Top")
        terminal.appendStream("\u{001B}[?1049l")
        XCTAssertNil(terminal.screenLines)
        XCTAssertEqual(terminal.tailLines(count: 1), ["shell prompt"])
    }
    
    /// Test 1: 24-bit TrueColor RGB parsing (\e[38;2;R;G;Bm)
    func testTrueColorRGBParsing() {
        let parser = VTParser()
        let raw = "\u{001B}[38;2;255;85;0m[Orange Alert]\u{001B}[0m Normal Text \u{001B}[38;2;120;200;80m[Custom Green]\u{001B}[0m"
        let spans = parser.parseANSI(raw)
        
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].text, "[Orange Alert]")
        XCTAssertEqual(spans[0].foregroundColorHex, "#FF5500")
        
        XCTAssertEqual(spans[1].text, " Normal Text ")
        XCTAssertNil(spans[1].foregroundColorHex)
        
        XCTAssertEqual(spans[2].text, "[Custom Green]")
        XCTAssertEqual(spans[2].foregroundColorHex, "#78C850")
    }
    
    /// Test 2: 256-color ANSI palette parsing (\e[38;5;Nm)
    func test256ColorPaletteParsing() {
        let parser = VTParser()
        // Index 9 is bright red (#FF0000), Index 240 is grayscale
        let raw = "\u{001B}[38;5;9mBright Red\u{001B}[0m \u{001B}[38;5;240mGray Text\u{001B}[0m"
        let spans = parser.parseANSI(raw)
        
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].text, "Bright Red")
        XCTAssertEqual(spans[0].foregroundColorHex, "#FF0000")
        
        XCTAssertEqual(spans[1].text, " ")
        XCTAssertNil(spans[1].foregroundColorHex)
        
        XCTAssertEqual(spans[2].text, "Gray Text")
        XCTAssertNotNil(spans[2].foregroundColorHex)
    }
    
    /// Test 3: Complex real-world ANSI stream (htop / neofetch color bar)
    func testComplexMultiColorStreamPerformance() {
        let parser = VTParser()
        var stream = ""
        for i in 0..<1000 {
            let r = i % 256
            let g = (i * 2) % 256
            let b = (i * 3) % 256
            stream += "\u{001B}[38;2;\(r);\(g);\(b)m[\(i)]\u{001B}[0m "
        }
        
        let start = CFAbsoluteTimeGetCurrent()
        let spans = parser.parseANSI(stream)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        XCTAssertGreaterThan(spans.count, 1500)
        XCTAssertLessThan(elapsed, 0.25, "1000 ANSI color transitions should parse in under 250ms (actual: \(elapsed)s)")
    }
    
    /// Test 4: Multibyte Chinese UTF-8 preservation in colored spans
    func testMultibyteChineseAnsiSpans() {
        let parser = VTParser()
        let raw = "\u{001B}[1;32m[系统状态]\u{001B}[0m 节点运行正常，CPU 负载 \u{001B}[33m0.15\u{001B}[0m，内存占用 \u{001B}[36m3.2GB\u{001B}[0m。"
        let spans = parser.parseANSI(raw)
        
        XCTAssertEqual(spans.count, 6)
        XCTAssertEqual(spans[0].text, "[系统状态]")
        XCTAssertTrue(spans[0].isBold)
        XCTAssertEqual(spans[0].foregroundColorHex, "#30D158")
        
        XCTAssertEqual(spans[1].text, " 节点运行正常，CPU 负载 ")
        XCTAssertEqual(spans[2].text, "0.15")
        XCTAssertEqual(spans[2].foregroundColorHex, "#FFD60A")
        
        XCTAssertEqual(spans[3].text, "，内存占用 ")
        XCTAssertEqual(spans[4].text, "3.2GB")
        XCTAssertEqual(spans[4].foregroundColorHex, "#64D2FF")
        
        XCTAssertEqual(spans[5].text, "。")
    }
    
    /// Test 5: Malformed and unclosed ANSI sequences
    func testMalformedAnsiSequences() {
        let parser = VTParser()
        let malformed = "Normal \u{001B}[31 Unfinished \u{001B}[999m Unknown \u{001B} Corrupt"
        let spans = parser.parseANSI(malformed)
        // Ensure parser does not crash or infinite loop
        XCTAssertGreaterThan(spans.count, 0)
        let reconstructed = spans.map { $0.text }.joined()
        XCTAssertTrue(reconstructed.contains("Normal"))
        XCTAssertTrue(reconstructed.contains("Unfinished"))
        XCTAssertTrue(reconstructed.contains("Unknown"))
    }

    func testSGRColonSubparametersEmptySemicolonResetAndEscStripping() {
        let parser = VTParser()
        // Empty semicolon resets style (";32m"), colon TrueColor (38:2::R:G:B), colon 256 (48:5:N), curly underline (4:3 / 4:0)
        let raw = "\u{1B}[1;31mRed\u{1B}[;32mGreen\u{1B}[38:2::10:20:30;48:5:220;4:3mStyled\u{1B}[4:0mNoUL\u{1B}[<u\u{1B}(B\u{1B}%G\u{1B}Pdcs-ignored\u{1B}\\End"
        let spans = parser.parseANSI(raw)
        XCTAssertEqual(spans.map(\.text).joined(), "RedGreenStyledNoULEnd")
        XCTAssertEqual(spans[0].isBold, true)
        XCTAssertEqual(spans[1].isBold, false)
        XCTAssertEqual(spans[1].ansiColorIndex, 2)
        XCTAssertEqual(spans[2].foregroundColorHex, "#0A141E")
        XCTAssertEqual(spans[2].isUnderlined, true)
        XCTAssertEqual(spans[3].isUnderlined, false)

        // ESC starting a new CSI aborts unclosed OSC without swallowing the next CSI
        let aborted = parser.parseANSI("\u{1B}]0;title\u{1B}[33mYellow\u{1B}[0m")
        XCTAssertEqual(aborted.map(\.text).joined(), "Yellow")
        XCTAssertEqual(aborted.first?.ansiColorIndex, 3)
    }

    func testRingBufferMultiLineSGRAndAlternateScreenEdgeCases() {
        let buffer = TerminalRingBuffer(maxLines: 50)
        buffer.setDimensions(columns: 10, rows: 4)

        // Multi-line active SGR color persists across newlines in normal mode
        buffer.appendStream("\u{1B}[32mline1\r\nline2\r\n\u{1B}[0mplain\r\n")
        let lines = buffer.allLines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("\u{1B}[0;32mline1\u{1B}[0m"))
        XCTAssertTrue(lines[1].contains("\u{1B}[0;32mline2\u{1B}[0m"))
        XCTAssertEqual(lines[2], "plain")

        // Oversized unclosed OSC (>160KB) must drop trailing bytes cleanly without printing garbage
        let oversizedOSC = "\u{1B}]52;c;" + String(repeating: "A", count: 170_000)
        buffer.appendStream(oversizedOSC)
        buffer.appendStream("clean-after-osc\r\n")
        XCTAssertEqual(buffer.allLines().last, "clean-after-osc")

        // 3-byte charset / DECALN sequences must not leak trailing character
        buffer.appendStream("\u{1B}%G\u{1B}#8ok\r\n")
        XCTAssertEqual(buffer.allLines().last, "ok")

        // Alternate screen CNL (E), CPL (F), and deferred-wrap 1K clamping
        buffer.appendStream("\u{1B}[?1049h\u{1B}[1;1H0123456789\u{1B}[1K")
        XCTAssertEqual(buffer.screenLines?[0], "")
        buffer.appendStream("\u{1B}[1;1H0123456789\u{1B}[1;5H\u{1B}[1K")
        XCTAssertEqual(buffer.screenLines?[0], "     56789")
        buffer.appendStream("\u{1B}[1;5H\u{1B}[2Erow2\u{1B}[1Frow1")
        XCTAssertEqual(buffer.screenLines?[1], "row1")
        XCTAssertEqual(buffer.screenLines?[2], "row2")
    }
}
