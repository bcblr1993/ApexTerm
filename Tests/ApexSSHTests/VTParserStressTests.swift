import XCTest
@testable import ApexTerminal

final class VTParserStressTests: XCTestCase {
    
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
        PerformanceThreshold.assertLessThan(elapsed, 0.25, "1000 ANSI color transitions should parse in under 250ms")
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
}
