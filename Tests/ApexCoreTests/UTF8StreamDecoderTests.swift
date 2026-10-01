import XCTest
@testable import ApexCore

final class UTF8StreamDecoderTests: XCTestCase {
    func testEverySplitPreservesUnicode() {
        let text = "中文かな한글🚀👩🏽‍💻e\u{301}\r\n\u{1B}[31m红色\u{1B}[0m"
        let data = Data(text.utf8)
        for split in 0...data.count {
            var decoder = UTF8StreamDecoder()
            let result = decoder.decode(data.prefix(split)) + decoder.decode(data.dropFirst(split)) + decoder.finish()
            XCTAssertEqual(result, text, "Byte split \(split)")
        }
    }

    func testOneBytePacketsAndMalformedTrailingSequence() {
        var decoder = UTF8StreamDecoder()
        let text = "中文🚀"
        var result = ""
        for byte in text.utf8 { result += decoder.decode(Data([byte])) }
        XCTAssertEqual(result, text)
        XCTAssertEqual(decoder.decode(Data([0xF0, 0x9F])), "")
        XCTAssertEqual(decoder.finish(), "�")
        XCTAssertEqual(decoder.decode(Data("next".utf8)), "next")
    }
}
