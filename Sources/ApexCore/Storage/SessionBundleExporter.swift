import Foundation

/// Portable, zero-credential configuration bundle (`.aetherpack.json`) for team sharing and offline backup.
public struct AetherSharePack: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var appVersion: String
    public var sessions: [Session]
    public var snippets: [Snippet]
    public var triggers: [Trigger]
    public var bookmarks: [SFTPBookmark]
    public var tunnels: [SSHTunnel]

    public init(
        formatVersion: Int = AetherSharePack.currentFormatVersion,
        exportedAt: Date = Date(),
        appVersion: String = "1.23.0",
        sessions: [Session] = [],
        snippets: [Snippet] = [],
        triggers: [Trigger] = [],
        bookmarks: [SFTPBookmark] = [],
        tunnels: [SSHTunnel] = []
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.sessions = sessions
        self.snippets = snippets
        self.triggers = triggers
        self.bookmarks = bookmarks
        self.tunnels = tunnels
    }
}

/// Summary report returned after importing an `AetherSharePack`.
public struct SessionBundleImportReport: Sendable, Equatable {
    public let importedSessions: Int
    public let skippedDuplicateSessions: Int
    public let importedSnippets: Int
    public let importedTriggers: Int
    public let importedBookmarks: Int
    public let importedTunnels: Int

    public init(
        importedSessions: Int,
        skippedDuplicateSessions: Int,
        importedSnippets: Int,
        importedTriggers: Int,
        importedBookmarks: Int,
        importedTunnels: Int
    ) {
        self.importedSessions = importedSessions
        self.skippedDuplicateSessions = skippedDuplicateSessions
        self.importedSnippets = importedSnippets
        self.importedTriggers = importedTriggers
        self.importedBookmarks = importedBookmarks
        self.importedTunnels = importedTunnels
    }

    public var summaryText: String {
        "已导入 \(importedSessions) 个会话（跳过重复 \(skippedDuplicateSessions) 个）、\(importedSnippets) 条快捷命令、\(importedTriggers) 条触发器、\(importedBookmarks) 个书签与 \(importedTunnels) 条隧道"
    }
}

/// Exports and imports portable `.aetherpack.json` bundles and generates standard OpenSSH `~/.ssh/config` files.
public enum SessionBundleExporter {

    /// Normalizes a local macOS home path (`/Users/<name>/...`) into a portable tilde path (`~/...`).
    public static func portablePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let currentHome = FileManager.default.homeDirectoryForCurrentUser.path
        if trimmed.hasPrefix(currentHome + "/") {
            return "~" + String(trimmed.dropFirst(currentHome.count))
        }
        // Also normalize generic /Users/<username>/.ssh/... paths for cross-machine portability
        if trimmed.hasPrefix("/Users/") {
            let parts = trimmed.dropFirst("/Users/".count).split(separator: "/", omittingEmptySubsequences: false)
            if parts.count >= 2 {
                let relative = parts.dropFirst().joined(separator: "/")
                return "~/\(relative)"
            }
        }
        return trimmed
    }

    /// Strictly strips all password/passphrase Keychain references, inline secrets, raw PEM blocks,
    /// and sensitive environment variables from a `Session` before sharing.
    public static func sanitizeSessionForShare(_ session: Session) -> Session {
        var copy = session
        switch copy.authMethod {
        case .password:
            copy.authMethod = .password(keychainRef: "")
        case .privateKey(let keyRef, _):
            if keyRef.contains("PRIVATE KEY") || keyRef.hasPrefix("vault://") || !keyRef.contains("/") && !keyRef.hasPrefix("~") {
                copy.authMethod = .privateKey(keychainRef: "", passphraseRef: nil)
            } else {
                copy.authMethod = .privateKey(keychainRef: portablePath(keyRef), passphraseRef: nil)
            }
        case .certificate(let keyRef, let certPath, _):
            let safeKeyRef: String
            if keyRef.contains("PRIVATE KEY") || keyRef.hasPrefix("vault://") || (!keyRef.contains("/") && !keyRef.hasPrefix("~")) {
                safeKeyRef = ""
            } else {
                safeKeyRef = portablePath(keyRef)
            }
            let safeCertPath = certPath.contains("PRIVATE KEY") ? "" : portablePath(certPath)
            copy.authMethod = .certificate(keychainRef: safeKeyRef, certificatePath: safeCertPath, passphraseRef: nil)
        case .agent:
            copy.authMethod = .agent
        case .none:
            copy.authMethod = .none
        }

        copy.environmentVariables = SessionStartupHelper.sanitizeEnvironmentForCloud(copy.environmentVariables)
        return copy
    }

    /// Sanitizes an entire `AetherSharePack` so it contains zero credentials or sensitive environment variables.
    public static func sanitizePack(_ pack: AetherSharePack) -> AetherSharePack {
        var copy = pack
        let allowedSessionIds = Set(copy.sessions.filter { !$0.isLocal }.map(\.id))
        copy.sessions = copy.sessions
            .filter { !$0.isLocal }
            .map { sanitizeSessionForShare($0) }
        copy.bookmarks = copy.bookmarks.filter { !$0.isPreset && !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        copy.tunnels = copy.tunnels.filter { allowedSessionIds.contains($0.sessionId) }
        return copy
    }

    /// Builds and encodes a sanitized `AetherSharePack` JSON data blob, optionally scoped to a specific folder.
    public static func exportSharePackData(
        sessions: [Session],
        snippets: [Snippet] = [],
        triggers: [Trigger] = [],
        bookmarks: [SFTPBookmark] = [],
        tunnels: [SSHTunnel] = [],
        onlyFolder: String? = nil,
        appVersion: String = "1.23.0"
    ) throws -> Data {
        let filteredSessions: [Session]
        if let folderFilter = onlyFolder?.trimmingCharacters(in: .whitespacesAndNewlines), !folderFilter.isEmpty {
            filteredSessions = sessions.filter {
                !$0.isLocal && ($0.folder?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(folderFilter) == .orderedSame)
            }
        } else {
            filteredSessions = sessions.filter { !$0.isLocal }
        }

        let pack = sanitizePack(
            AetherSharePack(
                appVersion: appVersion,
                sessions: filteredSessions,
                snippets: snippets,
                triggers: triggers,
                bookmarks: bookmarks,
                tunnels: tunnels
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(pack)
    }

    /// Decodes a share pack (or legacy `[Session]` JSON array) and merges non-duplicate items into the target stores.
    @MainActor
    public static func importSharePackData(
        _ data: Data,
        into store: SessionStore,
        bookmarkManager: SFTPBookmarkManager? = nil,
        tunnelManager: SSHTunnelManager? = nil,
        overwriteExisting: Bool = false
    ) throws -> SessionBundleImportReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let pack: AetherSharePack
        if let decodedPack = try? decoder.decode(AetherSharePack.self, from: data) {
            pack = sanitizePack(decodedPack)
        } else {
            let legacySessions = try JSONDecoder().decode([Session].self, from: data)
            pack = sanitizePack(AetherSharePack(sessions: legacySessions))
        }

        var importedSessions = 0
        var skippedSessions = 0
        var sessionIdRemap: [UUID: UUID] = [:]

        for incoming in pack.sessions where !incoming.isLocal {
            if let existingIdx = store.sessions.firstIndex(where: {
                $0.id == incoming.id || (
                    $0.host.caseInsensitiveCompare(incoming.host) == .orderedSame &&
                    $0.port == incoming.port &&
                    $0.username.caseInsensitiveCompare(incoming.username) == .orderedSame &&
                    $0.name.caseInsensitiveCompare(incoming.name) == .orderedSame
                )
            }) {
                let existing = store.sessions[existingIdx]
                sessionIdRemap[incoming.id] = existing.id
                if overwriteExisting {
                    var updated = incoming
                    updated.id = existing.id
                    store.updateSession(updated)
                    importedSessions += 1
                } else {
                    skippedSessions += 1
                }
            } else {
                store.addSession(incoming)
                sessionIdRemap[incoming.id] = incoming.id
                importedSessions += 1
            }
        }

        // Remap jumpServerId if a jump host was matched to an existing session ID
        for incoming in pack.sessions {
            if let oldJumpId = incoming.jumpServerId,
               let mappedJumpId = sessionIdRemap[oldJumpId],
               mappedJumpId != oldJumpId,
               let targetSessionId = sessionIdRemap[incoming.id],
               var targetSession = store.sessions.first(where: { $0.id == targetSessionId }) {
                targetSession.jumpServerId = mappedJumpId
                store.updateSession(targetSession)
            }
        }

        var importedSnippets = 0
        for snippet in pack.snippets {
            let exists = store.snippets.contains {
                $0.id == snippet.id || (
                    $0.title.caseInsensitiveCompare(snippet.title) == .orderedSame &&
                    $0.command == snippet.command
                )
            }
            if !exists {
                store.addSnippet(snippet)
                importedSnippets += 1
            }
        }

        var importedTriggers = 0
        var updatedTriggers = store.triggers
        for trigger in pack.triggers {
            let exists = updatedTriggers.contains {
                $0.id == trigger.id || (
                    $0.name.caseInsensitiveCompare(trigger.name) == .orderedSame &&
                    $0.regexPattern == trigger.regexPattern
                )
            }
            if !exists {
                updatedTriggers.append(trigger)
                importedTriggers += 1
            }
        }
        if importedTriggers > 0 {
            store.replaceAllTriggers(updatedTriggers)
        }

        var importedBookmarks = 0
        if let bmManager = bookmarkManager {
            for bm in pack.bookmarks where !bm.isPreset {
                if !bmManager.isBookmarked(path: bm.path) {
                    bmManager.addCustomBookmark(name: bm.name, path: bm.path)
                    importedBookmarks += 1
                }
            }
        }

        var importedTunnels = 0
        if let tunManager = tunnelManager {
            for var tun in pack.tunnels {
                if let mappedSessionId = sessionIdRemap[tun.sessionId] {
                    tun.sessionId = mappedSessionId
                }
                let exists = tunManager.tunnels.contains {
                    $0.sessionId == tun.sessionId &&
                    $0.type == tun.type &&
                    $0.bindPort == tun.bindPort &&
                    $0.targetHost == tun.targetHost &&
                    $0.targetPort == tun.targetPort
                }
                if !exists, (try? tunManager.addTunnel(tun)) != nil {
                    importedTunnels += 1
                }
            }
        }

        return SessionBundleImportReport(
            importedSessions: importedSessions,
            skippedDuplicateSessions: skippedSessions,
            importedSnippets: importedSnippets,
            importedTriggers: importedTriggers,
            importedBookmarks: importedBookmarks,
            importedTunnels: importedTunnels
        )
    }

    // MARK: - OpenSSH ~/.ssh/config Generator

    /// Generates a standards-compliant OpenSSH `~/.ssh/config` text from `[Session]`.
    public static func generateOpenSSHConfig(from sessions: [Session]) -> String {
        let remoteSessions = sessions.filter { !$0.isLocal }
        guard !remoteSessions.isEmpty else {
            return "# Generated by AetherTerm — No remote SSH sessions configured\n"
        }

        // Map session ID -> unique Host alias
        var aliasBySessionId: [UUID: String] = [:]
        var usedAliases: Set<String> = []

        for session in remoteSessions {
            let baseAlias = sanitizeHostAlias(session.name.isEmpty ? session.host : session.name)
            var candidate = baseAlias
            var suffix = 2
            while usedAliases.contains(candidate.lowercased()) {
                candidate = "\(baseAlias)-\(suffix)"
                suffix += 1
            }
            usedAliases.insert(candidate.lowercased())
            aliasBySessionId[session.id] = candidate
        }

        var blocks: [String] = [
            "# Generated by AetherTerm OpenSSH Config Exporter"
        ]

        for session in remoteSessions {
            guard let alias = aliasBySessionId[session.id] else { continue }
            var lines: [String] = []
            if let folder = session.folder?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
                lines.append("# Group: \(folder)")
            }
            lines.append("Host \(alias)")
            lines.append("    HostName \(session.host)")
            lines.append("    User \(session.username)")
            lines.append("    Port \(session.port)")

            switch session.authMethod {
            case .privateKey(let keyRef, _):
                let portable = portablePath(keyRef)
                if !portable.isEmpty && (portable.hasPrefix("/") || portable.hasPrefix("~")) {
                    lines.append("    IdentityFile \(portable)")
                }
            case .certificate(let keyRef, let certPath, _):
                let portableKey = portablePath(keyRef)
                if !portableKey.isEmpty && (portableKey.hasPrefix("/") || portableKey.hasPrefix("~")) {
                    lines.append("    IdentityFile \(portableKey)")
                }
                let portableCert = portablePath(certPath)
                if !portableCert.isEmpty && (portableCert.hasPrefix("/") || portableCert.hasPrefix("~")) {
                    lines.append("    CertificateFile \(portableCert)")
                }
            case .password, .agent, .none:
                break
            }

            if let jumpId = session.jumpServerId {
                if let jumpAlias = aliasBySessionId[jumpId] {
                    lines.append("    ProxyJump \(jumpAlias)")
                } else if let jumpSession = remoteSessions.first(where: { $0.id == jumpId }) {
                    let jumpSpec = jumpSession.port == 22
                        ? "\(jumpSession.username)@\(jumpSession.host)"
                        : "\(jumpSession.username)@\(jumpSession.host):\(jumpSession.port)"
                    lines.append("    ProxyJump \(jumpSpec)")
                }
            }

            let safeEnvs = SessionStartupHelper.sanitizeEnvironmentForCloud(session.environmentVariables)
            for key in safeEnvs.keys.sorted() where SessionStartupHelper.isValidEnvKey(key) {
                if let val = safeEnvs[key] {
                    let escapedVal = val.replacingOccurrences(of: "\"", with: "\\\"")
                    lines.append("    SetEnv \(key)=\"\(escapedVal)\"")
                }
            }

            if let startup = session.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !startup.isEmpty {
                let singleLine = startup
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "; ")
                if !singleLine.isEmpty {
                    lines.append("    RemoteCommand \(singleLine)")
                }
            }

            blocks.append(lines.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func sanitizeHostAlias(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "server" }
        var result = ""
        for ch in trimmed {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." {
                result.append(ch)
            } else if ch.isWhitespace {
                if result.last != "-" {
                    result.append("-")
                }
            }
        }
        let cleaned = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return cleaned.isEmpty ? "server" : cleaned
    }
}
