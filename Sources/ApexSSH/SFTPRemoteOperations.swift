import Foundation

/// Supported remote archive formats for SFTP compression.
public enum SFTPArchiveFormat: String, Sendable, CaseIterable {
    case tarGz = "tar.gz"
    case zip = "zip"

    public var fileExtension: String { ".\(rawValue)" }

    public var menuTitle: String {
        switch self {
        case .tarGz: return "压缩为 .tar.gz"
        case .zip: return "压缩为 .zip"
        }
    }
}

/// Remote SFTP search mode.
public enum SFTPSearchMode: String, Sendable, CaseIterable, Identifiable {
    case filename = "文件名"
    case content = "文件内容"

    public var id: String { rawValue }
}

/// Represents a remote file or content search match returned by `SFTPRemoteOperations`.
public struct SFTPSearchHit: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { "\(path)#\(lineNumber ?? -1)#\(snippet ?? "")" }
    public let path: String
    public let lineNumber: Int?
    public let snippet: String?

    public init(path: String, lineNumber: Int? = nil, snippet: String? = nil) {
        self.path = path
        self.lineNumber = lineNumber
        self.snippet = snippet
    }

    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    public var parentDirectory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }
}

/// Pure command builders and parsers for remote SFTP archive, extract, and search operations.
public enum SFTPRemoteOperations: Sendable {
    public static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func shellQuotedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return "\"$HOME\""
        }
        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            return suffix.isEmpty ? "\"$HOME\"" : "\"$HOME\"/\(posixSingleQuoted(suffix))"
        }
        return posixSingleQuoted(trimmed)
    }

    public static func isSupportedArchiveName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasSuffix(".tar.gz")
            || lower.hasSuffix(".tgz")
            || lower.hasSuffix(".tar")
            || lower.hasSuffix(".zip")
    }

    private static func isSafeRelativeName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }

    private static func containsPathTraversal(_ path: String) -> Bool {
        path.contains("\0") || path.split(separator: "/").contains("..")
    }

    /// Builds a shell-safe remote command to compress `items` inside `inDirectory`.
    public static func archiveCommand(
        items: [String],
        inDirectory: String,
        format: SFTPArchiveFormat,
        archiveName: String
    ) -> String? {
        let dir = inDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetArchive = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty,
              !containsPathTraversal(dir),
              isSafeRelativeName(targetArchive),
              !items.isEmpty else {
            return nil
        }
        let cleanItems = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cleanItems.allSatisfy(isSafeRelativeName) else { return nil }

        let safeDir = shellQuotedRemotePath(dir)
        let safeArchive = posixSingleQuoted(targetArchive.hasPrefix("-") ? "./\(targetArchive)" : targetArchive)
        let safeOperands = cleanItems.map { item -> String in
            let safeName = item.hasPrefix("-") ? "./\(item)" : item
            return posixSingleQuoted(safeName)
        }.joined(separator: " ")

        switch format {
        case .tarGz:
            return "cd \(safeDir) && tar -czf \(safeArchive) \(safeOperands) 2>&1"
        case .zip:
            return "cd \(safeDir) && if command -v zip >/dev/null 2>&1; then zip -rq \(safeArchive) \(safeOperands) 2>&1; else echo 'zip command not found on remote host' >&2; exit 127; fi"
        }
    }

    /// Builds a shell-safe remote command to extract `.tar.gz`, `.tgz`, `.tar`, or `.zip` into `targetDirectory`.
    public static func extractCommand(archivePath: String, targetDirectory: String) -> String? {
        let archive = archivePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !archive.isEmpty,
              !target.isEmpty,
              !containsPathTraversal(archive),
              !containsPathTraversal(target) else {
            return nil
        }

        let safeArchive = shellQuotedRemotePath(archive)
        let safeTarget = shellQuotedRemotePath(target)
        let lower = archive.lowercased()

        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            return "mkdir -p \(safeTarget) && tar -xzf \(safeArchive) -C \(safeTarget) 2>&1"
        } else if lower.hasSuffix(".tar") {
            return "mkdir -p \(safeTarget) && tar -xf \(safeArchive) -C \(safeTarget) 2>&1"
        } else if lower.hasSuffix(".zip") {
            return "mkdir -p \(safeTarget) && if command -v unzip >/dev/null 2>&1; then unzip -oq \(safeArchive) -d \(safeTarget) 2>&1; else echo 'unzip command not found on remote host' >&2; exit 127; fi"
        }
        return nil
    }

    /// Builds a bounded remote `find` or `grep -F` search command.
    public static func searchCommand(
        basePath: String,
        query: String,
        mode: SFTPSearchMode,
        maxDepth: Int = 5,
        maxResults: Int = 200
    ) -> String? {
        let base = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !q.isEmpty, !containsPathTraversal(base), !q.contains("\0") else {
            return nil
        }
        let depth = min(max(1, maxDepth), 10)
        let limit = min(max(1, maxResults), 500)
        let safeBase = shellQuotedRemotePath(base)

        switch mode {
        case .filename:
            // Escape glob metacharacters so user input is treated as substring match.
            var escapedGlob = ""
            for ch in q {
                if ch == "*" || ch == "?" || ch == "[" || ch == "]" || ch == "\\" {
                    escapedGlob.append("\\")
                }
                escapedGlob.append(ch)
            }
            let patternArg = posixSingleQuoted("*\(escapedGlob)*")
            return "find \(safeBase) -maxdepth \(depth) -iname \(patternArg) 2>/dev/null | head -n \(limit)"
        case .content:
            let queryArg = posixSingleQuoted(q)
            return "grep -rnI --max-count=5 -F -- \(queryArg) \(safeBase) 2>/dev/null | head -n \(limit)"
        }
    }

    /// Parses stdout from `searchCommand` into structured `SFTPSearchHit` entries.
    public static func parseSearchOutput(_ raw: String, mode: SFTPSearchMode) -> [SFTPSearchHit] {
        var hits: [SFTPSearchHit] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !line.isEmpty else { continue }

            switch mode {
            case .filename:
                hits.append(SFTPSearchHit(path: line, lineNumber: nil, snippet: nil))
            case .content:
                // Format: <path>:<lineNumber>:<matched content>
                guard let firstColon = line.firstIndex(of: ":") else { continue }
                let path = String(line[..<firstColon])
                let afterFirst = line[line.index(after: firstColon)...]
                guard let secondColon = afterFirst.firstIndex(of: ":") else { continue }
                let lineStr = String(afterFirst[..<secondColon])
                guard let lineNum = Int(lineStr) else { continue }
                let snippet = String(afterFirst[afterFirst.index(after: secondColon)...])
                    .trimmingCharacters(in: .whitespaces)
                hits.append(SFTPSearchHit(path: path, lineNumber: lineNum, snippet: snippet))
            }
        }
        return hits
    }
}
