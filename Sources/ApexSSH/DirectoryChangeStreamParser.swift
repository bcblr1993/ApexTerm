import Foundation
import ApexCore

/// OSC titles and directory hints can span both PTY reads and UTF-8 code points.
struct DirectoryChangeStreamParser {
    private var decoder = UTF8StreamDecoder()
    private var pending = ""

    mutating func consume(_ data: Data) -> (text: String, paths: [String]) {
        pending += decoder.decode(data)
        var text = ""
        var paths: [String] = []
        while let escape = pending.firstIndex(of: "\u{1B}") {
            text += pending[..<escape]
            pending = String(pending[escape...])
            guard pending.count > 1 else { return (text, paths) }
            guard pending.hasPrefix("\u{1B}]") else {
                text.append(pending.removeFirst())
                continue
            }
            let body = pending.dropFirst(2)
            let bell = body.firstIndex(of: "\u{7}")
            let st = body.range(of: "\u{1B}\\")
            let end = [bell, st?.lowerBound].compactMap { $0 }.min()
            guard let end else {
                // Bound malformed/unterminated control strings.
                if pending.utf8.count > 16_384 { pending = "" }
                return (text, paths)
            }
            let payload = String(body[..<end])
            if payload.hasPrefix("7;file://"),
               let url = URL(string: String(payload.dropFirst(2))), url.scheme == "file" {
                paths.append(url.path)
            } else if payload.hasPrefix("0;") || payload.hasPrefix("2;") {
                if let path = NativeSSHSession.directoryFromWindowTitle(String(payload.dropFirst(2))) {
                    paths.append(path)
                }
            }
            let next = end == bell ? pending.index(after: end) : st!.upperBound
            pending = String(pending[next...])
        }
        text += pending
        pending = ""
        return (text, paths)
    }
}
