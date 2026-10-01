import Foundation

public struct FormattedSpan: Sendable, Equatable {
    public let text: String
    public let foregroundColorHex: String?
    public let isBold: Bool
    public let ansiColorIndex: Int?
    public var backgroundColorHex: String? = nil
    public var backgroundANSIColorIndex: Int? = nil
    public var isItalic = false
    public var isUnderlined = false
    public var isStrikethrough = false
    public var isInverse = false
    
    public init(text: String, foregroundColorHex: String? = nil, isBold: Bool = false, ansiColorIndex: Int? = nil) {
        self.text = text
        self.foregroundColorHex = foregroundColorHex
        self.isBold = isBold
        self.ansiColorIndex = ansiColorIndex
    }
}

/// ANSI and VT100 stream parser
public final class VTParser: Sendable {
    public init() {}
    
    private func span(_ text: String, style: SGRStyle) -> FormattedSpan {
        var result = FormattedSpan(text: text, foregroundColorHex: style.foreground, isBold: style.bold, ansiColorIndex: style.index)
        result.backgroundColorHex = style.background
        result.backgroundANSIColorIndex = style.backgroundIndex
        result.isItalic = style.italic
        result.isUnderlined = style.underline
        result.isStrikethrough = style.strikethrough
        result.isInverse = style.inverse
        return result
    }

    /// Parse raw terminal output into readable text and formatted spans
    public func parseANSI(_ raw: String) -> [FormattedSpan] {
        var spans: [FormattedSpan] = []
        var currentText = ""
        var style = SGRStyle(foreground: nil, index: nil, bold: false)
        
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "\u{001B}" { // ESC
                // Flush accumulated text
                if !currentText.isEmpty {
                    spans.append(span(currentText, style: style))
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
                            style.apply(codes)
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
            spans.append(span(currentText, style: style))
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
            let levels = [0, 95, 135, 175, 215, 255]
            let r = levels[offset / 36]
            let g = levels[(offset % 36) / 6]
            let b = levels[offset % 6]
            return String(format: "#%02X%02X%02X", r, g, b)
        } else {
            let gray = (idx - 232) * 10 + 8
            return String(format: "#%02X%02X%02X", gray, gray, gray)
        }
    }
}
