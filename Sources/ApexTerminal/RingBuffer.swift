import Foundation

/// High-performance circular line buffer for terminal scrollback history
public final class TerminalRingBuffer: @unchecked Sendable {
    public let maxLines: Int
    private var buffer: [String]
    private var head: Int = 0
    private var count: Int = 0
    private let lock = NSLock()
    
    public init(maxLines: Int = 10_000) {
        self.maxLines = maxLines
        self.buffer = [String](repeating: "", count: maxLines)
    }
    
    /// Append a single line into circular buffer
    public func appendLine(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        
        let index = (head + count) % maxLines
        if count < maxLines {
            buffer[index] = line
            count += 1
        } else {
            buffer[head] = line
            head = (head + 1) % maxLines
        }
    }
    
    /// Append multiple lines
    public func appendLines(_ lines: [String]) {
        for line in lines {
            appendLine(line)
        }
    }
    
    /// Return all active lines in chronological order
    public func allLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        
        var result = [String]()
        result.reserveCapacity(count)
        for i in 0..<count {
            let index = (head + i) % maxLines
            result.append(buffer[index])
        }
        return result
    }
    
    /// Get the total number of lines in the buffer
    public var lineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    
    /// Clear all lines
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        head = 0
        count = 0
    }
}
