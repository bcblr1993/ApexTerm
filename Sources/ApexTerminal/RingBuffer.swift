import Foundation

/// Individual styled terminal cell
public struct TerminalCell: Equatable, Sendable {
    public var char: Character
    public var fgHex: String?
    public var isBold: Bool
    
    public init(char: Character, fgHex: String? = nil, isBold: Bool = false) {
        self.char = char
        self.fgHex = fgHex
        self.isBold = isBold
    }
}

/// High-performance circular line buffer for terminal scrollback history with real-time update notifications
public final class TerminalRingBuffer: @unchecked Sendable {
    public let maxLines: Int
    private var buffer: [String]
    private var head: Int = 0
    private var count: Int = 0
    private let lock = NSLock()
    
    private var activeLine: String = ""
    private var isEditingActiveLine: Bool = false
    private var activeCells: [TerminalCell] = []
    private var cursorCol: Int = 0
    private var currentFgHex: String? = nil
    private var currentBold: Bool = false
    private var pendingSequence: String = ""
    private let vtParser = VTParser()
    
    public var onUpdate: (@Sendable () -> Void)?
    
    public init(maxLines: Int = 10_000) {
        self.maxLines = maxLines
        self.buffer = [String](repeating: "", count: maxLines)
    }
    
    private var _totalCommittedCount: Int64 = 0
    private var _isClearPending: Bool = false
    
    /// Atomically consume and reset clear pending flag
    public func consumeClearFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _isClearPending {
            _isClearPending = false
            return true
        }
        return false
    }
    
    /// Total lifetime committed line count (monotonically increasing)
    public var totalCommittedCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _totalCommittedCount
    }
    
    /// Committed historical line count in circular window (capped at maxLines)
    public var committedLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    
    /// Current cursor column position (0-indexed) on the active line
    public var cursorColumn: Int {
        lock.lock()
        defer { lock.unlock() }
        if isEditingActiveLine {
            return cursorCol
        } else {
            return activeLine.count
        }
    }
    
    /// Current in-progress active line text (e.g. prompt and typed characters)
    public var currentActiveLine: String {
        lock.lock()
        defer { lock.unlock() }
        if isEditingActiveLine {
            return renderCellsToString(activeCells)
        } else {
            return activeLine
        }
    }
    
    /// Return committed lines from start index to count
    public func committedLines(from start: Int, count requestedCount: Int) -> [String] {
        lines(from: start, count: requestedCount)
    }
    
    /// Return the most recent N committed lines in chronological order
    public func tailLines(count requestedCount: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        
        let fetchCount = min(requestedCount, count)
        guard fetchCount > 0 else { return [] }
        var result = [String]()
        result.reserveCapacity(fetchCount)
        let startOffset = count - fetchCount
        for i in 0..<fetchCount {
            let index = (head + startOffset + i) % maxLines
            result.append(buffer[index])
        }
        return result
    }
    
    /// Append streaming raw output from terminal PTY
    public func appendStream(_ text: String) {
        lock.lock()
        defer {
            let updateHandler = onUpdate
            lock.unlock()
            updateHandler?()
        }
        
        var fullText = text
        if !pendingSequence.isEmpty {
            fullText = pendingSequence + fullText
            pendingSequence = ""
        }
        var i = fullText.startIndex
        while i < fullText.endIndex {
            let ch = fullText[i]
            if ch == "\r\n" || ch == "\n" {
                commitActiveLine()
                i = fullText.index(after: i)
                continue
            } else if ch == "\r" {
                ensureEditingMode()
                cursorCol = 0
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{08}" { // Backspace (BS) - moves cursor left without deletion
                ensureEditingMode()
                cursorCol = max(0, cursorCol - 1)
                i = fullText.index(after: i)
                continue
            } else if ch == "\t" { // Tab - advance to multiple of 8
                ensureEditingMode()
                let nextTab = (cursorCol / 8 + 1) * 8
                while cursorCol < nextTab {
                    putCell(TerminalCell(char: " ", fgHex: currentFgHex, isBold: currentBold))
                }
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{07}" { // Bell
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{001B}" { // ESC sequence
                let escapeStart = i
                let next = fullText.index(after: i)
                if next == fullText.endIndex {
                    pendingSequence = String(fullText[escapeStart...])
                    break
                }
                
                let nextChar = fullText[next]
                if nextChar == "[" { // CSI Sequence
                    var j = fullText.index(after: next)
                    var csiParam = ""
                    var foundFinal = false
                    while j < fullText.endIndex {
                        let c = fullText[j]
                        let ascii = c.asciiValue ?? 0
                        if ascii >= 0x30 && ascii <= 0x3F { // Parameter bytes
                            csiParam.append(c)
                            j = fullText.index(after: j)
                        } else if ascii >= 0x20 && ascii <= 0x2F { // Intermediate bytes
                            j = fullText.index(after: j)
                        } else if ascii >= 0x40 && ascii <= 0x7E { // Final byte
                            foundFinal = true
                            break
                        } else {
                            break
                        }
                    }
                    if !foundFinal {
                        if j == fullText.endIndex {
                            pendingSequence = String(fullText[escapeStart...])
                            break
                        }
                        i = j
                        continue
                    }
                    
                    let finalChar = fullText[j]
                    ensureEditingMode()
                    handleCSI(finalChar: finalChar, param: csiParam)
                    i = fullText.index(after: j)
                    continue
                } else if nextChar == "]" { // OSC Sequence
                    var j = fullText.index(after: next)
                    while j < fullText.endIndex && fullText[j] != "\u{0007}" && fullText[j] != "\u{001B}" {
                        j = fullText.index(after: j)
                    }
                    if j < fullText.endIndex && fullText[j] == "\u{001B}" {
                        let afterEsc = fullText.index(after: j)
                        if afterEsc < fullText.endIndex && fullText[afterEsc] == "\\" {
                            j = afterEsc
                        }
                    }
                    if j == fullText.endIndex {
                        pendingSequence = String(fullText[escapeStart...])
                        break
                    }
                    i = fullText.index(after: j)
                    continue
                } else {
                    // 2-byte escape sequence (e.g. ESC M, ESC =, ESC >, ESC 7, ESC 8)
                    // Consume both bytes so the second byte does not print as garbage
                    i = fullText.index(after: next)
                    continue
                }
            } else {
                if let ascii = ch.asciiValue, ascii < 32 {
                    i = fullText.index(after: i)
                    continue
                }
                if isEditingActiveLine {
                    putCell(TerminalCell(char: ch, fgHex: currentFgHex, isBold: currentBold))
                } else {
                    activeLine.append(ch)
                }
                i = fullText.index(after: i)
            }
        }
    }
    
    private func ensureEditingMode() {
        guard !isEditingActiveLine else { return }
        isEditingActiveLine = true
        activeCells.removeAll(keepingCapacity: true)
        if !activeLine.isEmpty {
            let spans = vtParser.parseANSI(activeLine)
            for span in spans {
                for c in span.text {
                    activeCells.append(TerminalCell(char: c, fgHex: span.foregroundColorHex, isBold: span.isBold))
                }
            }
            activeLine = ""
        }
        cursorCol = activeCells.count
    }
    
    private func putCell(_ cell: TerminalCell) {
        if cursorCol < activeCells.count {
            activeCells[cursorCol] = cell
        } else {
            if cursorCol > activeCells.count {
                let pad = cursorCol - activeCells.count
                activeCells.append(contentsOf: repeatElement(TerminalCell(char: " ", fgHex: nil, isBold: false), count: pad))
            }
            activeCells.append(cell)
        }
        cursorCol += 1
    }
    
    private func handleCSI(finalChar: Character, param: String) {
        switch finalChar {
        case "m": // SGR Color & Style
            let codes = param.split(separator: ";").compactMap { Int($0) }
            if codes.isEmpty || codes.contains(0) {
                currentFgHex = nil
                currentBold = false
            }
            if codes.contains(1) {
                currentBold = true
            }
            if codes.contains(22) {
                currentBold = false
            }
            if codes.count >= 5 && codes[0] == 38 && codes[1] == 2 {
                let r = max(0, min(255, codes[2]))
                let g = max(0, min(255, codes[3]))
                let b = max(0, min(255, codes[4]))
                currentFgHex = String(format: "#%02X%02X%02X", r, g, b)
            } else if codes.count >= 3 && codes[0] == 38 && codes[1] == 5 {
                currentFgHex = VTParser.colorFrom256Palette(codes[2])
            } else {
                for code in codes {
                    switch code {
                    case 30: currentFgHex = "#1E1E1E"
                    case 31: currentFgHex = "#FF453A"
                    case 32: currentFgHex = "#30D158"
                    case 33: currentFgHex = "#FFD60A"
                    case 34: currentFgHex = "#0A84FF"
                    case 35: currentFgHex = "#BF5AF2"
                    case 36: currentFgHex = "#64D2FF"
                    case 37: currentFgHex = "#FFFFFF"
                    case 39: currentFgHex = nil
                    case 90: currentFgHex = "#8E8E93"
                    case 91: currentFgHex = "#FF6961"
                    case 92: currentFgHex = "#77DD77"
                    case 93: currentFgHex = "#FDFD96"
                    case 94: currentFgHex = "#84B6F4"
                    case 95: currentFgHex = "#FDCAE1"
                    case 96: currentFgHex = "#B2FBA5"
                    default: break
                    }
                }
            }
        case "J": // Erase in Display
            if param.contains("2") || param.contains("3") || param.isEmpty {
                head = 0
                count = 0
                _totalCommittedCount = 0
                activeLine = ""
                activeCells.removeAll(keepingCapacity: true)
                isEditingActiveLine = false
                cursorCol = 0
                _isClearPending = true
            }
        case "K": // Erase in Line
            if param.isEmpty || param == "0" {
                // Erase from cursor to end of line
                if cursorCol < activeCells.count {
                    activeCells.removeSubrange(cursorCol..<activeCells.count)
                }
            } else if param == "1" {
                // Erase from start of line to cursor
                let limit = min(cursorCol + 1, activeCells.count)
                for k in 0..<limit {
                    activeCells[k] = TerminalCell(char: " ", fgHex: nil, isBold: false)
                }
            } else if param.contains("2") {
                // Erase entire line
                activeCells.removeAll(keepingCapacity: true)
            }
        case "C": // Cursor Forward (Right)
            let n = max(1, Int(param) ?? 1)
            cursorCol += n
        case "D": // Cursor Backward (Left)
            let n = max(1, Int(param) ?? 1)
            cursorCol = max(0, cursorCol - n)
        case "A": // Cursor Up
            break
        case "B": // Cursor Down
            break
        case "G": // Cursor Horizontal Absolute
            let col = max(1, Int(param) ?? 1)
            cursorCol = max(0, col - 1)
        case "H", "f": // Cursor Position
            if param.contains(";") {
                let parts = param.split(separator: ";")
                if parts.count >= 2, let col = Int(parts[1]) {
                    cursorCol = max(0, col - 1)
                }
            } else {
                cursorCol = 0
            }
        case "@": // Insert Character (ICH)
            let n = max(1, Int(param) ?? 1)
            if cursorCol > activeCells.count {
                let pad = cursorCol - activeCells.count
                activeCells.append(contentsOf: repeatElement(TerminalCell(char: " ", fgHex: nil, isBold: false), count: pad))
            }
            let blanks = Array(repeating: TerminalCell(char: " ", fgHex: currentFgHex, isBold: currentBold), count: n)
            activeCells.insert(contentsOf: blanks, at: min(cursorCol, activeCells.count))
        case "P": // Delete Character (DCH)
            let n = max(1, Int(param) ?? 1)
            if cursorCol < activeCells.count {
                let toRemove = min(n, activeCells.count - cursorCol)
                activeCells.removeSubrange(cursorCol..<(cursorCol + toRemove))
            }
        case "X": // Erase Character (ECH)
            let n = max(1, Int(param) ?? 1)
            if cursorCol < activeCells.count {
                let toErase = min(n, activeCells.count - cursorCol)
                for k in cursorCol..<(cursorCol + toErase) {
                    activeCells[k] = TerminalCell(char: " ", fgHex: nil, isBold: false)
                }
            }
        default:
            break
        }
    }
    
    private func commitActiveLine() {
        if isEditingActiveLine {
            let line = renderCellsToString(activeCells)
            commitFastLine(line)
            activeCells.removeAll(keepingCapacity: true)
            isEditingActiveLine = false
            cursorCol = 0
        } else {
            commitFastLine(activeLine)
            activeLine = ""
        }
    }
    
    private func commitFastLine(_ line: String) {
        let index = (head + count) % maxLines
        if count < maxLines {
            buffer[index] = line
            count += 1
        } else {
            buffer[head] = line
            head = (head + 1) % maxLines
        }
        _totalCommittedCount += 1
    }
    
    private func renderCellsToString(_ cells: [TerminalCell]) -> String {
        // Trim trailing erasure spaces at or past cursorCol (e.g. from \b \b or erase operations)
        var effectiveCount = cells.count
        while effectiveCount > cursorCol && cells[effectiveCount - 1].char == " " {
            effectiveCount -= 1
        }
        guard effectiveCount > 0 else { return "" }
        var result = ""
        result.reserveCapacity(effectiveCount + 16)
        var currentFg: String? = nil
        var currentBold = false
        
        for idx in 0..<effectiveCount {
            let cell = cells[idx]
            if cell.fgHex != currentFg || cell.isBold != currentBold {
                if cell.fgHex == nil && !cell.isBold {
                    result.append("\u{001B}[0m")
                } else {
                    var params = [String]()
                    if cell.isBold { params.append("1") }
                    if let hex = cell.fgHex {
                        if hex.count == 7 && hex.hasPrefix("#") {
                            let start = hex.index(hex.startIndex, offsetBy: 1)
                            let rEnd = hex.index(start, offsetBy: 2)
                            let gEnd = hex.index(rEnd, offsetBy: 2)
                            let bEnd = hex.index(gEnd, offsetBy: 2)
                            let r = Int(hex[start..<rEnd], radix: 16) ?? 0
                            let g = Int(hex[rEnd..<gEnd], radix: 16) ?? 0
                            let b = Int(hex[gEnd..<bEnd], radix: 16) ?? 0
                            params.append("38;2;\(r);\(g);\(b)")
                        }
                    }
                    result.append("\u{001B}[" + params.joined(separator: ";") + "m")
                }
                currentFg = cell.fgHex
                currentBold = cell.isBold
            }
            result.append(cell.char)
        }
        if currentFg != nil || currentBold {
            result.append("\u{001B}[0m")
        }
        return result
    }
    
    /// Append a single line into circular buffer
    public func appendLine(_ line: String) {
        lock.lock()
        commitFastLine(line)
        let updateHandler = onUpdate
        lock.unlock()
        
        updateHandler?()
    }
    
    /// Append multiple lines
    public func appendLines(_ lines: [String]) {
        lock.lock()
        for line in lines {
            let index = (head + count) % maxLines
            if count < maxLines {
                buffer[index] = line
                count += 1
            } else {
                buffer[head] = line
                head = (head + 1) % maxLines
            }
        }
        _totalCommittedCount += Int64(lines.count)
        let updateHandler = onUpdate
        lock.unlock()
        
        updateHandler?()
    }
    
    /// Return all active lines in chronological order
    public func allLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        
        let active = isEditingActiveLine ? renderCellsToString(activeCells) : activeLine
        var result = [String]()
        result.reserveCapacity(count + (active.isEmpty ? 0 : 1))
        for i in 0..<count {
            let index = (head + i) % maxLines
            result.append(buffer[index])
        }
        if !active.isEmpty {
            result.append(active)
        }
        return result
    }
    
    /// Return lines from offset to count for incremental rendering
    public func lines(from start: Int, count requestedCount: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        
        guard start < count else { return [] }
        let available = count - start
        let fetchCount = min(requestedCount, available)
        var result = [String]()
        result.reserveCapacity(fetchCount)
        for i in 0..<fetchCount {
            let index = (head + start + i) % maxLines
            result.append(buffer[index])
        }
        return result
    }
    
    /// Get the total number of lines in the buffer
    public var lineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        let hasActive = isEditingActiveLine ? !activeCells.isEmpty : !activeLine.isEmpty
        return count + (hasActive ? 1 : 0)
    }
    
    /// Clear all lines
    public func clear() {
        lock.lock()
        head = 0
        count = 0
        _totalCommittedCount = 0
        activeLine = ""
        activeCells.removeAll(keepingCapacity: true)
        isEditingActiveLine = false
        cursorCol = 0
        pendingSequence = ""
        currentFgHex = nil
        currentBold = false
        _isClearPending = true
        let updateHandler = onUpdate
        lock.unlock()
        
        updateHandler?()
    }
}
