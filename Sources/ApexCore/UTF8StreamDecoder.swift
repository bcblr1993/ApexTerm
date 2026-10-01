import Foundation

/// Keeps incomplete UTF-8 code points between reads from a byte stream.
public struct UTF8StreamDecoder: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func decode(_ data: Data) -> String {
        pending.append(data)
        var completeCount = pending.count
        if !pending.isEmpty {
            let bytes = Array(pending.suffix(4))
            var start = bytes.count - 1
            while start > 0 && (bytes[start] & 0xC0) == 0x80 { start -= 1 }
            let first = bytes[start]
            let expected: Int
            switch first {
            case 0xC2...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF4: expected = 4
            default: expected = 1
            }
            let available = bytes.count - start
            if available < expected { completeCount -= available }
        }
        let text = String(decoding: pending.prefix(completeCount), as: UTF8.self)
        pending = Data(pending.dropFirst(completeCount))
        return text
    }

    /// Flush an incomplete final sequence when the source closes.
    public mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: true) }
        return String(decoding: pending, as: UTF8.self)
    }
}
