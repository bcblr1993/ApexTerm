import Foundation
import CryptoKit

/// Marker prefix in OpenSSH `known_hosts` lines.
public enum KnownHostMarker: String, Codable, Sendable, Equatable {
    case standard = "standard"
    case certAuthority = "@cert-authority"
    case revoked = "@revoked"
}

/// Represents a parsed public key trust entry from `~/.ssh/known_hosts`.
public struct KnownHostEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let lineNumber: Int
    public let rawLine: String
    public let marker: KnownHostMarker
    public let hostPattern: String
    public let keyType: String
    public let base64PublicKey: String
    public let comment: String?
    public let fingerprintSHA256: String

    public init(
        id: UUID = UUID(),
        lineNumber: Int,
        rawLine: String,
        marker: KnownHostMarker = .standard,
        hostPattern: String,
        keyType: String,
        base64PublicKey: String,
        comment: String? = nil,
        fingerprintSHA256: String? = nil
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.rawLine = rawLine
        self.marker = marker
        self.hostPattern = hostPattern
        self.keyType = keyType
        self.base64PublicKey = base64PublicKey
        self.comment = comment
        self.fingerprintSHA256 = fingerprintSHA256 ?? KnownHostsManager.computeSHA256Fingerprint(base64PublicKey: base64PublicKey)
    }

    /// Whether this entry uses HMAC-SHA1 hashed hostname format (`|1|salt|hash`).
    public var isHashed: Bool {
        hostPattern.hasPrefix("|1|")
    }

    /// Individual host tokens split by comma (for unhashed entries).
    public var individualHosts: [String] {
        if isHashed {
            return [hostPattern]
        }
        return hostPattern
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public var displayHostTitle: String {
        if isHashed {
            return "哈希混淆主机 (Hashed Host)"
        }
        return individualHosts.joined(separator: ", ")
    }

    public var algorithmBadge: String {
        let lower = keyType.lowercased()
        if lower.contains("ed25519") {
            return "ED25519"
        } else if lower.contains("ecdsa") {
            return "ECDSA"
        } else if lower.contains("rsa") {
            return "RSA"
        } else if lower.contains("dss") || lower.contains("dsa") {
            return "DSA"
        }
        return keyType.uppercased()
    }

    /// Checks whether this entry matches a target host and port according to OpenSSH `known_hosts` conventions.
    public func matchesEndpoint(host: String, port: Int = 22) -> Bool {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanHost.isEmpty, !isHashed else { return false }

        let bracketed = "[\(cleanHost)]:\(port)"
        for token in individualHosts {
            let lowerToken = token.lowercased()
            if port == 22 {
                if lowerToken == cleanHost || lowerToken == bracketed {
                    return true
                }
            } else {
                if lowerToken == bracketed {
                    return true
                }
            }
        }
        return false
    }
}

/// Represents a host key conflict where the same endpoint and key algorithm have multiple differing fingerprints.
public struct KnownHostConflict: Identifiable, Sendable, Equatable {
    public var id: String { "\(endpoint)|\(keyType)" }
    public let endpoint: String
    public let keyType: String
    public let conflictingEntries: [KnownHostEntry]

    public init(endpoint: String, keyType: String, conflictingEntries: [KnownHostEntry]) {
        self.endpoint = endpoint
        self.keyType = keyType
        self.conflictingEntries = conflictingEntries
    }
}

/// Manages parsing, SHA-256 fingerprint calculation, conflict detection, and atomic editing of `~/.ssh/known_hosts`.
public final class KnownHostsManager: ObservableObject, @unchecked Sendable {
    public static let shared = KnownHostsManager()

    @Published public private(set) var entries: [KnownHostEntry] = []
    @Published public private(set) var conflicts: [KnownHostConflict] = []

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        if let custom = fileURL {
            self.fileURL = custom
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = home.appendingPathComponent(".ssh/known_hosts")
        }
        reload()
    }

    /// Computes the standard OpenSSH `SHA256:<unpadded-base64>` fingerprint from a base64-encoded public key blob.
    public static func computeSHA256Fingerprint(base64PublicKey: String) -> String {
        let trimmed = base64PublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyData = Data(base64Encoded: trimmed) ?? Data(trimmed.utf8)
        let digest = SHA256.hash(data: keyData)
        let b64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }

    /// Parses the text content of an OpenSSH `known_hosts` file.
    public static func parse(content: String) -> [KnownHostEntry] {
        var result: [KnownHostEntry] = []
        let lines = content.components(separatedBy: .newlines)

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let tokens = tokenizeWhitespace(trimmed)
            guard tokens.count >= 3 else { continue }

            var cursor = 0
            var marker: KnownHostMarker = .standard
            if tokens[0] == "@cert-authority" {
                marker = .certAuthority
                cursor = 1
            } else if tokens[0] == "@revoked" {
                marker = .revoked
                cursor = 1
            }

            guard tokens.count >= cursor + 3 else { continue }
            let hostPattern = tokens[cursor]
            let keyType = tokens[cursor + 1]
            let base64Key = tokens[cursor + 2]
            guard !hostPattern.isEmpty, !keyType.isEmpty, !base64Key.isEmpty else { continue }

            let comment: String?
            if tokens.count > cursor + 3 {
                let joined = tokens[(cursor + 3)...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
                comment = joined.isEmpty ? nil : joined
            } else {
                comment = nil
            }

            let entry = KnownHostEntry(
                lineNumber: index + 1,
                rawLine: rawLine,
                marker: marker,
                hostPattern: hostPattern,
                keyType: keyType,
                base64PublicKey: base64Key,
                comment: comment
            )
            result.append(entry)
        }
        return result
    }

    /// Detects host endpoints that have multiple conflicting fingerprints for the same key algorithm.
    public static func detectConflicts(in entries: [KnownHostEntry]) -> [KnownHostConflict] {
        var grouped: [String: [KnownHostEntry]] = [:]
        var keyMeta: [String: (endpoint: String, keyType: String)] = [:]

        for entry in entries where !entry.isHashed && entry.marker == .standard {
            for hostToken in entry.individualHosts {
                let normalizedHost = normalizeEndpointToken(hostToken)
                let groupKey = "\(normalizedHost)|\(entry.keyType.lowercased())"
                grouped[groupKey, default: []].append(entry)
                if keyMeta[groupKey] == nil {
                    keyMeta[groupKey] = (normalizedHost, entry.keyType)
                }
            }
        }

        var conflicts: [KnownHostConflict] = []
        for (groupKey, groupEntries) in grouped {
            let distinctFingerprints = Set(groupEntries.map(\.fingerprintSHA256))
            if distinctFingerprints.count > 1, let meta = keyMeta[groupKey] {
                conflicts.append(
                    KnownHostConflict(
                        endpoint: meta.endpoint,
                        keyType: meta.keyType,
                        conflictingEntries: groupEntries
                    )
                )
            }
        }

        return conflicts.sorted { lhs, rhs in
            if lhs.endpoint != rhs.endpoint { return lhs.endpoint < rhs.endpoint }
            return lhs.keyType < rhs.keyType
        }
    }

    private static func normalizeEndpointToken(_ token: String) -> String {
        let lower = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("["), lower.hasSuffix("]:22") {
            let inner = String(lower.dropFirst().dropLast(4))
            if !inner.contains(":") {
                return inner
            }
        }
        return lower
    }

    /// Filters entries by host pattern, key algorithm, SHA-256 fingerprint, comment, or marker.
    public static func filter(_ entries: [KnownHostEntry], query: String) -> [KnownHostEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { item in
            item.hostPattern.lowercased().contains(q)
                || item.displayHostTitle.lowercased().contains(q)
                || item.keyType.lowercased().contains(q)
                || item.algorithmBadge.lowercased().contains(q)
                || item.fingerprintSHA256.lowercased().contains(q)
                || (item.comment?.lowercased().contains(q) ?? false)
                || item.marker.rawValue.lowercased().contains(q)
        }
    }

    /// Reloads `~/.ssh/known_hosts` from disk and updates `entries` and `conflicts`.
    public func reload() {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            entries = []
            conflicts = []
            return
        }
        let parsed = Self.parse(content: content)
        entries = parsed
        conflicts = Self.detectConflicts(in: parsed)
    }

    /// Backup file URL (`known_hosts.bak` in the same directory).
    public var backupFileURL: URL {
        fileURL.appendingPathExtension("bak")
    }

    /// Removes a specific `KnownHostEntry` by ID, writing an atomic `.bak` backup before saving.
    @discardableResult
    public func removeEntry(id: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let currentEntries = Self.parse(content: content)
        guard let target = entries.first(where: { $0.id == id }) ?? currentEntries.first(where: { $0.id == id }) else {
            return false
        }

        var lines = content.components(separatedBy: "\n")
        let targetIndex = target.lineNumber - 1
        if targetIndex >= 0 && targetIndex < lines.count && lines[targetIndex].trimmingCharacters(in: .whitespacesAndNewlines) == target.rawLine.trimmingCharacters(in: .whitespacesAndNewlines) {
            lines.remove(at: targetIndex)
        } else if let fallbackIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == target.rawLine.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            lines.remove(at: fallbackIdx)
        } else {
            return false
        }

        try writeUpdatedLinesLocked(lines, originalContent: content)
        return true
    }

    /// Removes all entries matching `(host, port)`. If a line contains multiple comma-separated hosts,
    /// only the matching host token is removed from that line while preserving sibling hosts.
    @discardableResult
    public func removeEntries(matchingEndpoint host: String, port: Int = 22) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return 0 }
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanHost.isEmpty else { return 0 }
        let bracketed = "[\(cleanHost)]:\(port)"

        var updatedLines: [String] = []
        var modifiedCount = 0

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                updatedLines.append(rawLine)
                continue
            }

            let tokens = Self.tokenizeWhitespace(trimmed)
            var cursor = 0
            if tokens.first == "@cert-authority" || tokens.first == "@revoked" {
                cursor = 1
            }
            guard tokens.count >= cursor + 3 else {
                updatedLines.append(rawLine)
                continue
            }

            let hostPattern = tokens[cursor]
            if hostPattern.hasPrefix("|1|") {
                updatedLines.append(rawLine)
                continue
            }

            let individual = hostPattern.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let remaining = individual.filter { token in
                let lower = token.lowercased()
                if port == 22 {
                    return lower != cleanHost && lower != bracketed
                } else {
                    return lower != bracketed
                }
            }

            if remaining.count == individual.count {
                updatedLines.append(rawLine)
            } else {
                modifiedCount += 1
                if !remaining.isEmpty {
                    var rebuiltTokens = tokens
                    rebuiltTokens[cursor] = remaining.joined(separator: ",")
                    updatedLines.append(rebuiltTokens.joined(separator: " "))
                }
            }
        }

        if modifiedCount > 0 {
            try writeUpdatedLinesLocked(updatedLines, originalContent: content)
        }
        return modifiedCount
    }

    private func writeUpdatedLinesLocked(_ lines: [String], originalContent: String) throws {
        try originalContent.write(to: backupFileURL, atomically: true, encoding: .utf8)
        let newContent = lines.joined(separator: "\n")
        try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
        let parsed = Self.parse(content: newContent)
        entries = parsed
        conflicts = Self.detectConflicts(in: parsed)
    }

    private static func tokenizeWhitespace(_ text: String) -> [String] {
        text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }
}
