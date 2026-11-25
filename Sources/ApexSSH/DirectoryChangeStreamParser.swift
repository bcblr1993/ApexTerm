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
            if payload.hasPrefix("7;file://") {
                if let path = Self.parseOSC7FileURLPath(String(payload.dropFirst(2))) {
                    paths.append(path)
                }
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

    /// Parses an OSC 7 `file://[host]/path` URI, falling back gracefully when shells emit unencoded spaces or CJK.
    private static func parseOSC7FileURLPath(_ uriString: String) -> String? {
        if let url = URL(string: uriString), url.scheme == "file" {
            return url.path
        }
        guard uriString.hasPrefix("file://") else { return nil }
        let afterScheme = uriString.dropFirst("file://".count)
        guard let slashIdx = afterScheme.firstIndex(of: "/") else { return nil }
        let rawPath = String(afterScheme[slashIdx...])
        return rawPath.removingPercentEncoding ?? rawPath
    }
}
