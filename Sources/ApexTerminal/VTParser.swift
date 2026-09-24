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
                    while j < raw.endIndex && !raw[j].isLetter {
                        csiParam.append(raw[j])
                        j = raw.index(after: j)
                    }
                    if j < raw.endIndex {
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
}
