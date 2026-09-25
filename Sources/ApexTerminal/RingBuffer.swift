import Foundation

/// High-performance circular line buffer for terminal scrollback history with real-time update notifications
public final class TerminalRingBuffer: @unchecked Sendable {
    public let maxLines: Int
    private var buffer: [String]
    private var head: Int = 0
    private var count: Int = 0
    private let lock = NSLock()
    
    private var activeLine: String = ""
    private var pendingSequence: String = ""
    
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
    
    /// Current in-progress active line text (e.g. prompt and typed characters)
    public var currentActiveLine: String {
        lock.lock()
        defer { lock.unlock() }
        return activeLine
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
                activeLine = ""
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{08}" { // Backspace (BS)
                if !activeLine.isEmpty {
                    activeLine.removeLast()
                }
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{001B}" { // ESC sequence
                let escapeStart = i
                let next = fullText.index(after: i)
                if next == fullText.endIndex {
                    pendingSequence = String(fullText[escapeStart...])
                    break
                }
                if fullText[next] == "[" { // CSI
                    var j = fullText.index(after: next)
                    var csiParam = ""
                    while j < fullText.endIndex && !fullText[j].isLetter && fullText[j] != "@" {
                        csiParam.append(fullText[j])
                        j = fullText.index(after: j)
                    }
                    if j == fullText.endIndex {
                        // Incomplete CSI sequence
                        pendingSequence = String(fullText[escapeStart...])
                        break
                    }
                    let finalChar = fullText[j]
                    switch finalChar {
                    case "J": // Erase in Display (clear command output)
                        if csiParam.contains("2") || csiParam.contains("3") || csiParam.isEmpty {
                            head = 0
                            count = 0
                            _totalCommittedCount = 0
                            activeLine = ""
                            _isClearPending = true
                        }
                    case "K": // Erase in Line
                        if csiParam.contains("2") || csiParam == "1" {
                            activeLine = ""
                        }
                    case "m": // SGR color / style: preserve in activeLine for VTParser
                        activeLine.append(String(fullText[escapeStart...j]))
                    default:
                        break
                    }
                    i = fullText.index(after: j)
                    continue
                } else if fullText[next] == "]" { // OSC
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
                }
                i = fullText.index(after: i)
                continue
            } else if ch == "\u{07}" { // Bell
                i = fullText.index(after: i)
                continue
            } else {
                activeLine.append(ch)
                i = fullText.index(after: i)
            }
        }
    }
    
    private func commitActiveLine() {
        let index = (head + count) % maxLines
        if count < maxLines {
            buffer[index] = activeLine
            count += 1
        } else {
            buffer[head] = activeLine
            head = (head + 1) % maxLines
        }
        _totalCommittedCount += 1
        activeLine = ""
    }
    
    /// Append a single line into circular buffer
    public func appendLine(_ line: String) {
        lock.lock()
        let index = (head + count) % maxLines
        if count < maxLines {
            buffer[index] = line
            count += 1
        } else {
            buffer[head] = line
            head = (head + 1) % maxLines
        }
        _totalCommittedCount += 1
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
        
        var result = [String]()
        result.reserveCapacity(count + (activeLine.isEmpty ? 0 : 1))
        for i in 0..<count {
            let index = (head + i) % maxLines
            result.append(buffer[index])
        }
        if !activeLine.isEmpty {
            result.append(activeLine)
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
        return count + (activeLine.isEmpty ? 0 : 1)
    }
    
    /// Clear all lines
    public func clear() {
        lock.lock()
        head = 0
        count = 0
        _totalCommittedCount = 0
        activeLine = ""
        pendingSequence = ""
        _isClearPending = true
        let updateHandler = onUpdate
        lock.unlock()
        
        updateHandler?()
    }
}
