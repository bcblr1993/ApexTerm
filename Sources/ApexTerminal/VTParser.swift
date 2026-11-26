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
                guard nextIndex < raw.endIndex else {
                    i = raw.endIndex
                    break
                }
                let nextChar = raw[nextIndex]
                if nextChar == "[" { // CSI
                    var j = raw.index(after: nextIndex)
                    var csiParam = ""
                    var hasIntermediates = false
                    var foundFinal = false
                    while j < raw.endIndex {
                        let c = raw[j]
                        let ascii = c.asciiValue ?? 0
                        if ascii >= 0x30 && ascii <= 0x3F { // ECMA-48 parameter bytes (0-9:;<=>?)
                            if hasIntermediates { break }
                            csiParam.append(c)
                            j = raw.index(after: j)
                        } else if ascii >= 0x21 && ascii <= 0x2F { // ECMA-48 intermediate bytes (!"#$%&'()*+,-./)
                            hasIntermediates = true
                            j = raw.index(after: j)
                        } else if ascii == 0x20 { // Space intermediate (e.g. DECSCUSR `\e[6 q`)
                            let afterSpace = raw.index(after: j)
                            if afterSpace < raw.endIndex, "q@APQR~".contains(raw[afterSpace]) {
                                hasIntermediates = true
                                j = afterSpace
                            } else {
                                break
                            }
                        } else if ascii >= 0x40 && ascii <= 0x7E { // ECMA-48 final byte (@A-Z[\]^_`a-z{|}~)
                            foundFinal = true
                            break
                        } else {
                            break
                        }
                    }
                    if foundFinal && j < raw.endIndex {
                        let finalChar = raw[j]
                        if finalChar == "m" && !hasIntermediates && !csiParam.hasPrefix("?") && !csiParam.hasPrefix(">") && !csiParam.hasPrefix("<") && !csiParam.hasPrefix("=") { // SGR color/style
                            style.apply(param: csiParam)
                        }
                        i = raw.index(after: j)
                        continue
                    } else {
                        i = nextIndex
                        continue
                    }
                } else if nextChar == "]" { // OSC
                    // Skip OSC sequences like OSC 7 or OSC 0 title
                    var j = raw.index(after: nextIndex)
                    while j < raw.endIndex && raw[j] != "\u{0007}" && raw[j] != "\u{001B}" {
                        j = raw.index(after: j)
                    }
                    guard j < raw.endIndex else {
                        i = raw.endIndex
                        break
                    }
                    if raw[j] == "\u{001B}" {
                        let next = raw.index(after: j)
                        guard next < raw.endIndex else {
                            i = raw.endIndex
                            break
                        }
                        if raw[next] == "\\" {
                            i = raw.index(after: next)
                            continue
                        } else {
                            // ESC started a new sequence rather than terminating OSC with ST
                            i = j
                            continue
                        }
                    } else {
                        i = raw.index(after: j)
                        continue
                    }
                } else if "P^_X".contains(nextChar) { // DCS/PM/APC/SOS
                    let payloadStart = raw.index(after: nextIndex)
                    if let terminator = raw.range(of: "\u{1B}\\", range: payloadStart..<raw.endIndex) {
                        i = terminator.upperBound
                        continue
                    }
                    i = raw.endIndex
                    break
                } else if "()*+-./%# ".contains(nextChar) { // 3-byte ESC sequence
                    let designator = raw.index(after: nextIndex)
                    i = designator < raw.endIndex ? raw.index(after: designator) : raw.endIndex
                    continue
                } else {
                    i = raw.index(after: nextIndex)
                    continue
                }
            } else {
                currentText.append(raw[i])
                if i < raw.endIndex {
                    i = raw.index(after: i)
                }
            }
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
