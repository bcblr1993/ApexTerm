import Foundation

/// Consume SGR operands sequentially so RGB channel values never become style codes.
struct SGRStyle {
    var foreground: String?
    var index: Int?
    var bold: Bool

    private static let standard = ["#1E1E1E", "#FF453A", "#30D158", "#FFD60A", "#0A84FF", "#BF5AF2", "#64D2FF", "#FFFFFF", "#8E8E93", "#FF6961", "#77DD77", "#FDFD96", "#84B6F4", "#FDCAE1", "#B2FBA5", "#FFFFFF"]

    mutating func apply(_ input: [Int]) {
        let codes = input.isEmpty ? [0] : input
        var offset = 0
        while offset < codes.count {
            let code = codes[offset]
            switch code {
            case 0: foreground = nil; index = nil; bold = false
            case 1: bold = true
            case 22: bold = false
            case 39: foreground = nil; index = nil
            case 30...37, 90...97:
                let slot = code < 90 ? code - 30 : code - 90 + 8
                index = slot; foreground = Self.standard[slot]
            case 38, 48:
                if offset + 4 < codes.count, codes[offset + 1] == 2 {
                    if code == 38 {
                        let rgb = codes[(offset + 2)...(offset + 4)].map { max(0, min(255, $0)) }
                        foreground = String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2])
                        index = nil
                    }
                    offset += 4
                } else if offset + 2 < codes.count, codes[offset + 1] == 5 {
                    if code == 38 {
                        let slot = codes[offset + 2]
                        foreground = VTParser.colorFrom256Palette(slot)
                        index = (0..<16).contains(slot) ? slot : nil
                    }
                    offset += 2
                }
            default: break
            }
            offset += 1
        }
    }
}
