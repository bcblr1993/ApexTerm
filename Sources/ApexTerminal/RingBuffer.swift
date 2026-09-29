import Foundation

/// Individual styled terminal cell
public struct TerminalCell: Equatable, Sendable {
    public var char: Character
    public var fgHex: String?
    public var isBold: Bool
    public var ansiColorIndex: Int?
    
    public init(char: Character, fgHex: String? = nil, isBold: Bool = false, ansiColorIndex: Int? = nil) {
        self.char = char
        self.fgHex = fgHex
        self.isBold = isBold
        self.ansiColorIndex = ansiColorIndex
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
    private var currentANSIIndex: Int? = nil
    private var currentBold: Bool = false
    private var pendingSequence: String = ""
    private let vtParser = VTParser()
    private var screen: [[TerminalCell]]? = nil
    private var screenRows = 35
    private var screenColumns = 120
    private var screenRow = 0
    private var screenColumn = 0
    private var savedScreenPosition: (Int, Int)?
    private var _screenRevision: Int64 = 0

    public var screenRevision: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _screenRevision
    }

    public var screenLines: [String]? {
        lock.lock(); defer { lock.unlock() }
        return screen?.map(renderCellsToString)
    }

    public func setDimensions(columns: Int, rows: Int) {
        lock.lock()
        if screenColumns == max(1, columns) && screenRows == max(1, rows) {
            lock.unlock()
            return
        }
        screenColumns = max(1, columns)
        screenRows = max(1, rows)
        var needsUpdate = false
        if var grid = screen {
            grid = Array(grid.prefix(screenRows))
            while grid.count < screenRows { grid.append([]) }
            screen = grid
            screenRow = min(screenRow, screenRows - 1)
            screenColumn = min(screenColumn, screenColumns - 1)
            _screenRevision += 1
            needsUpdate = true
        }
        let updateHandler = onUpdate
        lock.unlock()
        if needsUpdate { updateHandler?() }
    }
    
    public var onUpdate: (@Sendable () -> Void)?
    
    public init(maxLines: Int = 10_000) {
        self.maxLines = maxLines
        self.buffer = [String](repeating: "", count: maxLines)
    }
    
    private var _totalCommittedCount: Int64 = 0
    private var _isClearPending: Bool = false
    private var _isBracketedPasteEnabled: Bool = false
    
    /// Whether the remote shell has enabled bracketed paste mode (DEC private mode 2004)
    public var isBracketedPasteEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isBracketedPasteEnabled
    }
    
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
        if screen != nil { return screenColumn }
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
        
        // Ordinary ASCII log chunks can be committed in whole lines. Control sequences,
        // Unicode and cursor editing continue through the terminal state machine below.
        if pendingSequence.isEmpty, !isEditingActiveLine,
           currentFgHex == nil, currentANSIIndex == nil, !currentBold,
           text.utf8.allSatisfy({ $0 == 10 || ($0 >= 32 && $0 < 127) }) {
            let segments = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
            for (offset, segment) in segments.enumerated() {
                activeLine.append(String(decoding: segment, as: UTF8.self))
                if offset < segments.count - 1 { commitActiveLine() }
            }
            return
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
                if screen != nil { screenNewline() } else { commitActiveLine() }
                i = fullText.index(after: i)
                continue
            } else if ch == "\r" {
                if screen != nil { screenColumn = 0; i = fullText.index(after: i); continue }
                ensureEditingMode()
                cursorCol = 0
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{08}" { // Backspace (BS) - moves cursor left without deletion
                if screen != nil { screenColumn = max(0, screenColumn - 1); i = fullText.index(after: i); continue }
                ensureEditingMode()
                cursorCol = max(0, cursorCol - 1)
                i = fullText.index(after: i)
                continue
            } else if ch == "\t" { // Tab - advance to multiple of 8
                if screen != nil { screenColumn = min(screenColumns - 1, (screenColumn / 8 + 1) * 8); i = fullText.index(after: i); continue }
                ensureEditingMode()
                let nextTab = (cursorCol / 8 + 1) * 8
                while cursorCol < nextTab {
                    putCell(TerminalCell(char: " ", fgHex: currentFgHex, isBold: currentBold, ansiColorIndex: currentANSIIndex))
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
                    if screen != nil || csiParam == "?1049" || csiParam == "?1047" || csiParam == "?47" {
                        handleScreenCSI(finalChar: finalChar, param: csiParam)
                    } else {
                        ensureEditingMode()
                        handleCSI(finalChar: finalChar, param: csiParam)
                    }
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
                    if screen != nil {
                        switch nextChar {
                        case "7": savedScreenPosition = (screenRow, screenColumn)
                        case "8": if let savedScreenPosition { (screenRow, screenColumn) = savedScreenPosition }
                        case "M": screenRow = max(0, screenRow - 1)
                        default: break
                        }
                    }
                    i = fullText.index(after: next)
                    continue
                }
            } else {
                if let ascii = ch.asciiValue, ascii < 32 {
                    i = fullText.index(after: i)
                    continue
                }
                if screen != nil {
                    screenPut(TerminalCell(char: ch, fgHex: currentFgHex, isBold: currentBold, ansiColorIndex: currentANSIIndex))
                    i = fullText.index(after: i)
                    continue
                }
                if isEditingActiveLine {
                    putCell(TerminalCell(char: ch, fgHex: currentFgHex, isBold: currentBold, ansiColorIndex: currentANSIIndex))
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
                    activeCells.append(TerminalCell(char: c, fgHex: span.foregroundColorHex, isBold: span.isBold, ansiColorIndex: span.ansiColorIndex))
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

    private func screenNewline() {
        screenColumn = 0
        if screenRow < screenRows - 1 { screenRow += 1 }
        else if var grid = screen {
            grid.removeFirst()
            grid.append([])
            screen = grid
        }
        _screenRevision += 1
    }

    private func screenPut(_ cell: TerminalCell) {
        guard var grid = screen else { return }
        if screenColumn >= screenColumns { screenNewline(); grid = screen! }
        var row = grid[screenRow]
        if screenColumn > row.count {
            row.append(contentsOf: repeatElement(TerminalCell(char: " "), count: screenColumn - row.count))
        }
        if screenColumn < row.count { row[screenColumn] = cell } else { row.append(cell) }
        grid[screenRow] = row
        screen = grid
        screenColumn += 1
        _screenRevision += 1
    }

    private func handleScreenCSI(finalChar: Character, param: String) {
        if param == "?1049" || param == "?1047" || param == "?47" {
            if finalChar == "h" {
                screen = Array(repeating: [], count: screenRows)
                screenRow = 0
                screenColumn = 0
                savedScreenPosition = nil
                _screenRevision += 1
            } else if finalChar == "l" {
                screen = nil
                _screenRevision += 1
                _isClearPending = true
            }
            return
        }
        if param == "?2004" {
            _isBracketedPasteEnabled = (finalChar == "h")
            return
        }
        guard var grid = screen else { return }
        let values = param.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = values.first ?? 0
        let amount = max(1, first)
        switch finalChar {
        case "m":
            var style = SGRStyle(foreground: currentFgHex, index: currentANSIIndex, bold: currentBold)
            style.apply(param.split(separator: ";").compactMap { Int($0) })
            currentFgHex = style.foreground; currentANSIIndex = style.index; currentBold = style.bold
        case "H", "f":
            screenRow = min(screenRows - 1, max(0, amount - 1))
            screenColumn = min(screenColumns - 1, max(0, (values.count > 1 ? max(1, values[1]) : 1) - 1))
        case "A": screenRow = max(0, screenRow - amount)
        case "B": screenRow = min(screenRows - 1, screenRow + amount)
        case "C": screenColumn = min(screenColumns - 1, screenColumn + amount)
        case "D": screenColumn = max(0, screenColumn - amount)
        case "G": screenColumn = min(screenColumns - 1, amount - 1)
        case "d": screenRow = min(screenRows - 1, amount - 1)
        case "J":
            if first == 2 || first == 3 { grid = Array(repeating: [], count: screenRows) }
            else if first == 0 {
                grid[screenRow] = Array(grid[screenRow].prefix(screenColumn))
                if screenRow + 1 < screenRows { for row in (screenRow + 1)..<screenRows { grid[row] = [] } }
            }
            screen = grid; _screenRevision += 1
        case "K":
            if first == 2 { grid[screenRow] = [] }
            else if first == 0 { grid[screenRow] = Array(grid[screenRow].prefix(screenColumn)) }
            else if first == 1 {
                let end = min(screenColumn + 1, grid[screenRow].count)
                if end > 0 { for col in 0..<end { grid[screenRow][col] = TerminalCell(char: " ") } }
            }
            screen = grid; _screenRevision += 1
        case "L":
            for _ in 0..<min(amount, screenRows - screenRow) { grid.insert([], at: screenRow); grid.removeLast() }
            screen = grid; _screenRevision += 1
        case "M":
            for _ in 0..<min(amount, screenRows - screenRow) { grid.remove(at: screenRow); grid.append([]) }
            screen = grid; _screenRevision += 1
        default: break
        }
    }
    
    private func handleCSI(finalChar: Character, param: String) {
        switch finalChar {
        case "h":
            if param == "?2004" {
                _isBracketedPasteEnabled = true
            }
        case "l":
            if param == "?2004" {
                _isBracketedPasteEnabled = false
            }
        case "m": // SGR Color & Style
            let codes = param.split(separator: ";").compactMap { Int($0) }
            var style = SGRStyle(foreground: currentFgHex, index: currentANSIIndex, bold: currentBold)
            style.apply(codes)
            currentFgHex = style.foreground
            currentANSIIndex = style.index
            currentBold = style.bold
        case "J": // Erase in Display
            let mode = Int(param) ?? 0
            if mode == 0 {
                ensureEditingMode()
                if cursorCol < activeCells.count {
                    activeCells.removeSubrange(cursorCol..<activeCells.count)
                }
            } else if mode == 2 || mode == 3 {
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
            let blanks = Array(repeating: TerminalCell(char: " ", fgHex: currentFgHex, isBold: currentBold, ansiColorIndex: currentANSIIndex), count: n)
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
        var currentIndex: Int? = nil
        var currentBold = false
        
        for idx in 0..<effectiveCount {
            let cell = cells[idx]
            if cell.fgHex != currentFg || cell.ansiColorIndex != currentIndex || cell.isBold != currentBold {
                if cell.fgHex == nil && !cell.isBold {
                    result.append("\u{001B}[0m")
                } else {
                    var params = [String]()
                    if cell.isBold { params.append("1") }
                    if let index = cell.ansiColorIndex {
                        params.append(String(index < 8 ? 30 + index : 90 + index - 8))
                    } else if let hex = cell.fgHex {
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
                currentIndex = cell.ansiColorIndex
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
        currentANSIIndex = nil
        currentBold = false
        _isClearPending = true
        let updateHandler = onUpdate
        lock.unlock()
        
        updateHandler?()
    }
}
