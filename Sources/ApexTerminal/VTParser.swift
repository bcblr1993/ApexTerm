import Foundation

public struct FormattedSpan: Sendable, Equatable {
    public let text: String
    public let foregroundColorHex: String?
    public let isBold: Bool
    
    public init(text: String, foregroundColorHex: String? = nil, isBold: Bool = false) {
        self.text = text
        self.foregroundColorHex = foregroundColorHex
        self.isBold = isBold
    }
}

/// ANSI and VT100 stream parser
public final class VTParser: Sendable {
    public init() {}
    
    /// Parse raw terminal output into readable text and formatted spans
    public func parseANSI(_ raw: String) -> [FormattedSpan] {
        var spans: [FormattedSpan] = []
        var currentText = ""
        var currentColor: String? = nil
        var currentBold = false
        
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "\u{001B}" { // ESC
                // Flush accumulated text
                if !currentText.isEmpty {
                    spans.append(FormattedSpan(text: currentText, foregroundColorHex: currentColor, isBold: currentBold))
                    currentText = ""
                }
                
                let nextIndex = raw.index(after: i)
                if nextIndex < raw.endIndex && raw[nextIndex] == "[" { // CSI
                    var j = raw.index(after: nextIndex)
                    var csiParam = ""
                    var isValidCsi = true
                    while j < raw.endIndex && !raw[j].isLetter {
                        let c = raw[j]
                        if c.isNumber || c == ";" || c == "?" {
                            csiParam.append(c)
                            j = raw.index(after: j)
                        } else {
                            isValidCsi = false
                            break
                        }
                    }
                    if isValidCsi && j < raw.endIndex {
                        let finalChar = raw[j]
                        if finalChar == "m" { // SGR color/style
                            let codes = csiParam.split(separator: ";").compactMap { Int($0) }
                            if codes.isEmpty || codes.contains(0) {
                                currentColor = nil
                                currentBold = false
                            }
                            if codes.contains(1) {
                                currentBold = true
                            }
                            // Check for 24-bit TrueColor RGB: 38;2;r;g;b
                            if codes.count >= 5 && codes[0] == 38 && codes[1] == 2 {
                                let r = max(0, min(255, codes[2]))
                                let g = max(0, min(255, codes[3]))
                                let b = max(0, min(255, codes[4]))
                                currentColor = String(format: "#%02X%02X%02X", r, g, b)
                            } else if codes.count >= 3 && codes[0] == 38 && codes[1] == 5 {
                                // 256-color palette
                                currentColor = Self.colorFrom256Palette(codes[2])
                            } else {
                                for code in codes {
                                    switch code {
                                    case 30: currentColor = "#1E1E1E"
                                    case 31: currentColor = "#FF453A" // Red
                                    case 32: currentColor = "#30D158" // Green
                                    case 33: currentColor = "#FFD60A" // Yellow
                                    case 34: currentColor = "#0A84FF" // Blue
                                    case 35: currentColor = "#BF5AF2" // Magenta
                                    case 36: currentColor = "#64D2FF" // Cyan
                                    case 37: currentColor = "#FFFFFF" // White
                                    case 39: currentColor = nil       // Default foreground
                                    case 90: currentColor = "#8E8E93" // Bright Black / Gray
                                    case 91: currentColor = "#FF6961"
                                    case 92: currentColor = "#77DD77"
                                    case 93: currentColor = "#FDFD96"
                                    case 94: currentColor = "#84B6F4"
                                    case 95: currentColor = "#FDCAE1"
                                    case 96: currentColor = "#B2FBA5"
                                    default: break
                                    }
                                }
                            }
                        }
                        i = j
                    } else {
                        i = raw.index(after: i)
                    }
                } else if nextIndex < raw.endIndex && raw[nextIndex] == "]" { // OSC
                    // Skip OSC sequences like OSC 7 or OSC 0 title
                    var j = raw.index(after: nextIndex)
                    while j < raw.endIndex && raw[j] != "\u{0007}" && raw[j] != "\u{001B}" {
                        j = raw.index(after: j)
                    }
                    if j < raw.endIndex && raw[j] == "\u{001B}" {
                        let next = raw.index(after: j)
                        if next < raw.endIndex && raw[next] == "\\" {
                            j = next
                        }
                    }
                    i = j
                } else {
                    i = nextIndex
                }
            } else {
                currentText.append(raw[i])
            }
            i = raw.index(after: i)
        }
        
        if !currentText.isEmpty {
            spans.append(FormattedSpan(text: currentText, foregroundColorHex: currentColor, isBold: currentBold))
        }
        return spans
    }
    
    public static func colorFrom256Palette(_ index: Int) -> String {
        let idx = max(0, min(255, index))
        if idx < 16 {
            let standard16 = [
                "#000000", "#CD0000", "#00CD00", "#CDCD00",
                "#0000EE", "#CD00CD", "#00CDCD", "#E5E5E5",
                "#7F7F7F", "#FF0000", "#00FF00", "#FFFF00",
                "#5C5CFF", "#FF00FF", "#00FFFF", "#FFFFFF"
            ]
            return standard16[idx]
        } else if idx < 232 {
            let offset = idx - 16
            let r = (offset / 36) * 51
            let g = ((offset % 36) / 6) * 51
            let b = (offset % 6) * 51
            return String(format: "#%02X%02X%02X", r, g, b)
        } else {
            let gray = (idx - 232) * 10 + 8
            return String(format: "#%02X%02X%02X", gray, gray, gray)
        }
    }
}
