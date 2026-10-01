import Foundation

/// Consume SGR operands sequentially so RGB channel values never become style codes.
struct SGRStyle: Equatable {
    var foreground: String?
    var index: Int?
    var bold: Bool
    var background: String? = nil
    var backgroundIndex: Int? = nil
    var italic = false
    var underline = false
    var strikethrough = false
    var inverse = false

    private static let standard = ["#1E1E1E", "#FF453A", "#30D158", "#FFD60A", "#0A84FF", "#BF5AF2", "#64D2FF", "#FFFFFF", "#8E8E93", "#FF6961", "#77DD77", "#FDFD96", "#84B6F4", "#FDCAE1", "#B2FBA5", "#FFFFFF"]

    mutating func apply(_ input: [Int]) {
        let codes = input.isEmpty ? [0] : input
        var offset = 0
        while offset < codes.count {
            let code = codes[offset]
            switch code {
            case 0: self = SGRStyle(foreground: nil, index: nil, bold: false)
            case 1: bold = true
            case 3: italic = true
            case 4: underline = true
            case 7: inverse = true
            case 9: strikethrough = true
            case 22: bold = false
            case 23: italic = false
            case 24: underline = false
            case 27: inverse = false
            case 29: strikethrough = false
            case 49: background = nil; backgroundIndex = nil
            case 40...47, 100...107:
                let slot = code < 100 ? code - 40 : code - 100 + 8
                backgroundIndex = slot; background = Self.standard[slot]
            case 39: foreground = nil; index = nil
            case 30...37, 90...97:
                let slot = code < 90 ? code - 30 : code - 90 + 8
                index = slot; foreground = Self.standard[slot]
            case 38, 48:
                if offset + 4 < codes.count, codes[offset + 1] == 2 {
                    let rgb = codes[(offset + 2)...(offset + 4)].map { max(0, min(255, $0)) }
                    let color = String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2])
                    if code == 38 { foreground = color; index = nil }
                    else { background = color; backgroundIndex = nil }
                    offset += 4
                } else if offset + 2 < codes.count, codes[offset + 1] == 5 {
                    let slot = codes[offset + 2]
                    let color = VTParser.colorFrom256Palette(slot)
                    let paletteIndex = (0..<16).contains(slot) ? slot : nil
                    if code == 38 { foreground = color; index = paletteIndex }
                    else { background = color; backgroundIndex = paletteIndex }
                    offset += 2
                }
            default: break
            }
            offset += 1
        }
    }
    var escapeSequence: String {
        var codes = ["0"]
        if bold { codes.append("1") }
        if italic { codes.append("3") }
        if underline { codes.append("4") }
        if inverse { codes.append("7") }
        if strikethrough { codes.append("9") }
        func appendColor(_ hex: String?, index: Int?, foreground: Bool) {
            if let index {
                codes.append(String(index < 8 ? (foreground ? 30 : 40) + index : (foreground ? 90 : 100) + index - 8))
            } else if let hex, let rgb = UInt32(hex.dropFirst(), radix: 16) {
                codes.append("\(foreground ? 38 : 48);2;\((rgb >> 16) & 255);\((rgb >> 8) & 255);\(rgb & 255)")
            }
        }
        appendColor(foreground, index: index, foreground: true)
        appendColor(background, index: backgroundIndex, foreground: false)
        return "\u{1B}[" + codes.joined(separator: ";") + "m"
    }

}
