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
            let bodyStart = pending.index(pending.startIndex, offsetBy: 2)
            var scan = bodyStart
            var payloadEnd: String.Index? = nil
            var terminatorEnd: String.Index? = nil
            var abortedAtEsc: String.Index? = nil
            while scan < pending.endIndex {
                let ch = pending[scan]
                if ch == "\u{07}" {
                    payloadEnd = scan
                    terminatorEnd = pending.index(after: scan)
                    break
                } else if ch == "\u{1B}" {
                    let afterEsc = pending.index(after: scan)
                    if afterEsc == pending.endIndex {
                        // Could be ST (`\e\\`) split across packets; wait unless oversized.
                        if pending.utf8.count > 16_384 { pending = "" }
                        return (text, paths)
                    }
                    if pending[afterEsc] == "\\" {
                        payloadEnd = scan
                        terminatorEnd = pending.index(after: afterEsc)
                    } else {
                        // A non-ST ESC aborts the unterminated OSC and starts a new sequence.
                        abortedAtEsc = scan
                    }
                    break
                }
                scan = pending.index(after: scan)
            }
            if let abortedAtEsc {
                pending = String(pending[abortedAtEsc...])
                continue
            }
            guard let payloadEnd, let terminatorEnd else {
                // Bound malformed/unterminated control strings.
                if pending.utf8.count > 16_384 { pending = "" }
                return (text, paths)
            }
            let payload = String(pending[bodyStart..<payloadEnd])
            if payload.hasPrefix("7;") {
                let rawURI = String(payload.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let path = Self.parseOSC7Path(rawURI), !path.isEmpty {
                    paths.append(path)
                }
            } else if payload.hasPrefix("1337;") {
                let body = String(payload.dropFirst(5))
                for segment in body.split(separator: ";") {
                    let s = String(segment).trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("CurrentDir=") {
                        let dir = String(s.dropFirst("CurrentDir=".count))
                        if !dir.isEmpty {
                            paths.append(dir)
                            break
                        }
                    }
                }
            } else if payload.hasPrefix("0;") || payload.hasPrefix("2;") {
                if let path = NativeSSHSession.directoryFromWindowTitle(String(payload.dropFirst(2))), !path.isEmpty {
                    paths.append(path)
                }
            }
            pending = String(pending[terminatorEnd...])
        }
        text += pending
        pending = ""
        return (text, paths)
    }

    /// Parses an OSC 7 `file://[host]/path` URI or bare `/path`, falling back gracefully when shells emit unencoded spaces or CJK.
    private static func parseOSC7Path(_ uriString: String) -> String? {
        if uriString.hasPrefix("file://") {
            if let url = URL(string: uriString), url.scheme == "file" {
                return url.path.isEmpty ? nil : url.path
            }
            let afterScheme = uriString.dropFirst("file://".count)
            guard let slashIdx = afterScheme.firstIndex(of: "/") else { return nil }
            let rawPath = String(afterScheme[slashIdx...])
            let decoded = rawPath.removingPercentEncoding ?? rawPath
            return decoded.isEmpty ? nil : decoded
        } else if uriString.hasPrefix("/") {
            return uriString.isEmpty ? nil : uriString
        }
        return nil
    }
}
