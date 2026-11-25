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
            if keyRef.contains("PRIVATE KEY") || KeychainStore.isManagedReference(keyRef) || keyRef.hasPrefix("vault://") || (!keyRef.contains("/") && !keyRef.hasPrefix("~")) {
                copy.authMethod = .privateKey(keychainRef: "", passphraseRef: nil)
            } else {
                copy.authMethod = .privateKey(keychainRef: portablePath(keyRef), passphraseRef: nil)
            }
        case .certificate(let keyRef, let certPath, _):
            let safeKeyRef: String
            if keyRef.contains("PRIVATE KEY") || KeychainStore.isManagedReference(keyRef) || keyRef.hasPrefix("vault://") || (!keyRef.contains("/") && !keyRef.hasPrefix("~")) {
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
        copy.proxyCommand = SessionStartupHelper.sanitizeProxyCommand(copy.proxyCommand)
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

        // Remap jumpServerId / jumpServerChain if jump hosts were matched to existing session IDs
        for incoming in pack.sessions {
            let incomingChain = incoming.effectiveJumpServerChain
            guard !incomingChain.isEmpty,
                  let targetSessionId = sessionIdRemap[incoming.id],
                  var targetSession = store.sessions.first(where: { $0.id == targetSessionId }) else {
                continue
            }
            let mappedChain = incomingChain.map { sessionIdRemap[$0] ?? $0 }
            if mappedChain != targetSession.effectiveJumpServerChain {
                targetSession.jumpServerChain = mappedChain
                targetSession.jumpServerId = mappedChain.first
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

            if session.forwardAgent {
                lines.append("    ForwardAgent yes")
            }
            if session.compression {
                lines.append("    Compression yes")
            }

            if let sanitizedProxy = SessionStartupHelper.sanitizeProxyCommand(session.proxyCommand), !sanitizedProxy.isEmpty {
                lines.append("    ProxyCommand \(sanitizedProxy)")
            } else {
                let jumpChain = session.effectiveJumpServerChain
                if !jumpChain.isEmpty {
                    let hopSpecs: [String] = jumpChain.compactMap { jumpId in
                        if let jumpAlias = aliasBySessionId[jumpId] {
                            return jumpAlias
                        } else if let jumpSession = remoteSessions.first(where: { $0.id == jumpId }) {
                            return jumpSession.port == 22
                                ? "\(jumpSession.username)@\(jumpSession.host)"
                                : "\(jumpSession.username)@\(jumpSession.host):\(jumpSession.port)"
                        }
                        return nil
                    }
                    if !hopSpecs.isEmpty {
                        lines.append("    ProxyJump \(hopSpecs.joined(separator: ","))")
                    }
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

    // MARK: - v2 Encrypted / App-Sealed Group Share Export & Import

    /// Normalizes a session's folder name and returns sorted unique folder names across `sessions`.
    public static func normalizedGroupNames(for sessions: [Session]) -> [String] {
        var names = Set<String>()
        for session in sessions where !session.isLocal {
            let trimmed = (session.folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            names.insert(trimmed.isEmpty ? L10n.generalFolder : trimmed)
        }
        return names.sorted()
    }

    /// Recursively collects remote jump hosts referenced by `selectedSessionIDs` that reside outside `selectedSessionIDs`.
    public static func crossGroupJumpHosts(for selectedSessionIDs: Set<UUID>, allSessions: [Session]) -> [Session] {
        let byId = Dictionary(uniqueKeysWithValues: allSessions.filter { !$0.isLocal }.map { ($0.id, $0) })
        var visited = selectedSessionIDs
        var queue: [UUID] = selectedSessionIDs.compactMap { byId[$0] }.flatMap(\.effectiveJumpServerChain)
        var discoveredIDs = Set<UUID>()

        while !queue.isEmpty {
            let nextId = queue.removeFirst()
            guard !visited.contains(nextId), let jumpSession = byId[nextId] else { continue }
            visited.insert(nextId)
            discoveredIDs.insert(nextId)
            queue.append(contentsOf: jumpSession.effectiveJumpServerChain)
        }

        return allSessions.filter { !$0.isLocal && discoveredIDs.contains($0.id) }
    }

    /// Resolves selected sessions plus optional transitive jump-host dependencies while preserving `allSessions` order.
    public static func resolveExportSelection(
        selectedSessionIDs: Set<UUID>,
        allSessions: [Session],
        includeCrossGroupJumpHosts: Bool
    ) -> (sessions: [Session], addedJumpHostIDs: [UUID]) {
        let extraJumps = includeCrossGroupJumpHosts
            ? crossGroupJumpHosts(for: selectedSessionIDs, allSessions: allSessions)
            : []
        let extraIDs = Set(extraJumps.map(\.id))
        let combinedIDs = selectedSessionIDs.union(extraIDs)

        var seen = Set<UUID>()
        var resolved: [Session] = []
        for session in allSessions where !session.isLocal && combinedIDs.contains(session.id) {
            if seen.insert(session.id).inserted {
                resolved.append(session)
            }
        }
        return (resolved, extraJumps.map(\.id))
    }

    /// Builds a filesystem-safe default filename for `.aetherpack` share bundles.
    public static func suggestedFilename(forFolder folder: String?, sessionCount: Int) -> String {
        let trimmed = (folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return sessionCount <= 1 ? "aetherterm-session.aetherpack" : "aetherterm-sessions.aetherpack"
        }
        let illegalChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let sanitized = trimmed
            .components(separatedBy: illegalChars)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let stem = sanitized.isEmpty ? "aetherterm-group" : sanitized
        return "\(stem).aetherpack"
    }

    /// Checks whether `url` has an `.aetherpack`, `.aetherpack.json`, or `.json` share extension.
    public static func isSupportedShareFileURL(_ url: URL) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        return lowerName.hasSuffix(".aetherpack")
            || lowerName.hasSuffix(".aetherpack.json")
            || url.pathExtension.lowercased() == "json"
    }

    /// Exports an `.aetherpack` v2 envelope with the selected protection mode and optional embedded credentials.
    public static func exportEnvelopeData(
        sessions: [Session],
        snippets: [Snippet] = [],
        triggers: [Trigger] = [],
        bookmarks: [SFTPBookmark] = [],
        tunnels: [SSHTunnel] = [],
        protectionMode: SharePackProtectionMode = .appSealed,
        passphrase: String? = nil,
        appVersion: String = "1.26.0",
        vaultKeys: [SSHKeyIdentity] = [],
        secretLookup: @Sendable (String) async -> String? = { try? await KeychainStore.shared.get(key: $0) }
    ) async throws -> Data {
        var uniqueSessions: [Session] = []
        var seenIDs = Set<UUID>()
        for session in sessions where !session.isLocal {
            if seenIDs.insert(session.id).inserted {
                uniqueSessions.append(session)
            }
        }

        let allowedSessionIDs = Set(uniqueSessions.map(\.id))
        let scopedTunnels = tunnels.filter { allowedSessionIDs.contains($0.sessionId) }
        let header = AetherShareEnvelopeHeader(
            groupNames: normalizedGroupNames(for: uniqueSessions),
            sessionCount: uniqueSessions.count,
            tunnelCount: scopedTunnels.count,
            includesCredentials: protectionMode != .zeroCredential,
            exportedByAppVersion: appVersion,
            exportedAt: Date()
        )

        var credentials = SharePackCredentialPayload()
        if protectionMode != .zeroCredential {
            var embeddedVaultRefs = Set<String>()
            let vaultByRef = Dictionary(uniqueKeysWithValues: vaultKeys.map { ($0.keychainPrivateKeyRef, $0) })

            for session in uniqueSessions {
                switch session.authMethod {
                case .password(let ref):
                    guard !ref.isEmpty else { break }
                    let secret: String? = KeychainStore.isManagedReference(ref) ? await secretLookup(ref) : ref
                    if let secret, !secret.isEmpty {
                        credentials.sessionPasswords[session.id] = secret
                    }

                case .privateKey(let keyRef, let passRef), .certificate(let keyRef, _, let passRef):
                    if KeychainStore.isVaultPrivateKeyReference(keyRef) {
                        credentials.sessionVaultKeyRefs[session.id] = keyRef
                        if embeddedVaultRefs.insert(keyRef).inserted,
                           let privPEM = await secretLookup(keyRef),
                           !privPEM.isEmpty {
                            let identity = vaultByRef[keyRef]
                            let vaultPassRef = identity?.keychainPassphraseRef ?? passRef
                            var vaultPass: String? = nil
                            if let vaultPassRef, !vaultPassRef.isEmpty {
                                vaultPass = KeychainStore.isManagedReference(vaultPassRef)
                                    ? await secretLookup(vaultPassRef)
                                    : vaultPassRef
                            }
                            credentials.embeddedVaultKeys.append(
                                SharePackVaultKeyRecord(
                                    originalPrivateKeyRef: keyRef,
                                    name: identity?.name ?? session.name,
                                    publicKeyOpenSSH: identity?.publicKeyOpenSSH ?? "",
                                    privateKeyPEM: privPEM,
                                    passphrase: (vaultPass?.isEmpty == false) ? vaultPass : nil
                                )
                            )
                        }
                    } else if keyRef.contains("PRIVATE KEY") {
                        credentials.sessionPrivateKeysPEM[session.id] = keyRef
                    }

                    if let passRef, !passRef.isEmpty {
                        let resolvedPass: String? = KeychainStore.isManagedReference(passRef)
                            ? await secretLookup(passRef)
                            : passRef
                        if let resolvedPass, !resolvedPass.isEmpty {
                            credentials.sessionPassphrases[session.id] = resolvedPass
                        }
                    }

                case .agent, .none:
                    break
                }
            }
        }

        let pack = sanitizePack(
            AetherSharePack(
                appVersion: appVersion,
                sessions: uniqueSessions,
                snippets: snippets,
                triggers: triggers,
                bookmarks: bookmarks,
                tunnels: scopedTunnels
            )
        )
        let bundle = SharePackSecretBundle(pack: pack, credentials: credentials)
        let envelope = try SharePackCrypto.encryptBundle(
            bundle,
            mode: protectionMode,
            passphrase: passphrase,
            header: header
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Parses a share file to determine its format, unencrypted summary metadata, and (unless passphrase-locked) decrypted bundle.
    public static func inspectSharePackData(_ data: Data) throws -> SharePackInspection {
        struct EnvelopeProbe: Decodable {
            let magic: String?
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let probe = try? decoder.decode(EnvelopeProbe.self, from: data),
           probe.magic == AetherShareEnvelope.magic {
            let envelope: AetherShareEnvelope
            do {
                envelope = try decoder.decode(AetherShareEnvelope.self, from: data)
            } catch {
                throw SharePackCryptoError.invalidEnvelope("分享包格式损坏：\(error.localizedDescription)")
            }

            guard envelope.envelopeVersion > 0 && envelope.envelopeVersion <= AetherShareEnvelope.currentEnvelopeVersion else {
                throw SharePackCryptoError.unsupportedFormatVersion(envelope.envelopeVersion)
            }

            if envelope.protectionMode == .passphrase {
                return SharePackInspection(
                    sourceFormat: .envelopeV2(.passphrase),
                    header: envelope.header,
                    requiresPassphrase: true,
                    decryptedBundle: nil
                )
            }

            let bundle = try SharePackCrypto.decryptEnvelope(envelope, passphrase: nil)
            return SharePackInspection(
                sourceFormat: .envelopeV2(envelope.protectionMode),
                header: envelope.header,
                requiresPassphrase: false,
                decryptedBundle: bundle
            )
        }

        if let legacyPack = try? decoder.decode(AetherSharePack.self, from: data) {
            let sanitized = sanitizePack(legacyPack)
            let header = AetherShareEnvelopeHeader(
                groupNames: normalizedGroupNames(for: sanitized.sessions),
                sessionCount: sanitized.sessions.count,
                tunnelCount: sanitized.tunnels.count,
                includesCredentials: false,
                exportedByAppVersion: sanitized.appVersion,
                exportedAt: sanitized.exportedAt
            )
            return SharePackInspection(
                sourceFormat: .legacySharePackV1,
                header: header,
                requiresPassphrase: false,
                decryptedBundle: SharePackSecretBundle(pack: sanitized)
            )
        }

        if let legacySessions = try? JSONDecoder().decode([Session].self, from: data) {
            let sanitized = sanitizePack(AetherSharePack(sessions: legacySessions))
            let header = AetherShareEnvelopeHeader(
                groupNames: normalizedGroupNames(for: sanitized.sessions),
                sessionCount: sanitized.sessions.count,
                tunnelCount: 0,
                includesCredentials: false,
                exportedByAppVersion: "legacy",
                exportedAt: Date()
            )
            return SharePackInspection(
                sourceFormat: .legacySessionArray,
                header: header,
                requiresPassphrase: false,
                decryptedBundle: SharePackSecretBundle(pack: sanitized)
            )
        }

        throw SharePackCryptoError.invalidEnvelope("文件不是有效的 AetherTerm 分享包或会话 JSON。")
    }

    /// Decrypts a passphrase-protected `.aetherpack` v2 envelope using the user-supplied passphrase.
    public static func decryptSharePackData(_ data: Data, passphrase: String) throws -> SharePackSecretBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: AetherShareEnvelope
        do {
            envelope = try decoder.decode(AetherShareEnvelope.self, from: data)
        } catch {
            throw SharePackCryptoError.invalidEnvelope("无法解析加密分享包：\(error.localizedDescription)")
        }
        return try SharePackCrypto.decryptEnvelope(envelope, passphrase: passphrase)
    }

    /// Imports a decrypted (or zero-credential) share bundle into local stores with target-folder mapping,
    /// duplicate conflict resolution, jump-host chain remapping, and isolated local Keychain storage.
    @MainActor
    public static func importDecryptedBundle(
        _ bundle: SharePackSecretBundle,
        into store: SessionStore,
        options: SharePackImportOptions = .init(),
        bookmarkManager: SFTPBookmarkManager? = nil,
        tunnelManager: SSHTunnelManager? = nil,
        vaultManager: SSHKeyVaultManager? = nil,
        secretSaver: ((String, String) throws -> String)? = nil
    ) throws -> SharePackImportResult {
        let saver: (String, String) throws -> String = secretSaver ?? { key, secret in
            try KeychainStore.shared.save(key: key, secret: secret)
        }

        let allCandidates = bundle.pack.sessions.filter { !$0.isLocal }
        let chosenSessions = options.selectedSessionIDs.map { selected in
            allCandidates.filter { selected.contains($0.id) }
        } ?? allCandidates
        let chosenOriginIDs = Set(chosenSessions.map(\.id))

        // 1. Import referenced Key Vault identities (deduplicated by SHA-256 fingerprint)
        var vaultRefRemap: [String: String] = [:]
        var vaultPassRefByNewPrivRef: [String: String] = [:]
        var importedVaultKeys = 0

        if options.importCredentials {
            let referencedVaultRefs = Set(chosenOriginIDs.compactMap { bundle.credentials.sessionVaultKeyRefs[$0] })
            for record in bundle.credentials.embeddedVaultKeys where referencedVaultRefs.contains(record.originalPrivateKeyRef) {
                if let vm = vaultManager, !record.publicKeyOpenSSH.isEmpty {
                    let fp = SSHKeyIdentity.computeFingerprint(from: record.publicKeyOpenSSH)
                    if let existingKey = vm.keys.first(where: { $0.fingerprintSHA256 == fp }) {
                        vaultRefRemap[record.originalPrivateKeyRef] = existingKey.keychainPrivateKeyRef
                        if let existingPassRef = existingKey.keychainPassphraseRef {
                            vaultPassRefByNewPrivRef[existingKey.keychainPrivateKeyRef] = existingPassRef
                        }
                    } else if !record.privateKeyPEM.isEmpty {
                        let created = try vm.importKey(
                            name: record.name,
                            privateKeyPEM: record.privateKeyPEM,
                            publicKeyOpenSSH: record.publicKeyOpenSSH,
                            passphrase: record.passphrase,
                            secretSaver: saver
                        )
                        vaultRefRemap[record.originalPrivateKeyRef] = created.keychainPrivateKeyRef
                        if let passRef = created.keychainPassphraseRef {
                            vaultPassRefByNewPrivRef[created.keychainPrivateKeyRef] = passRef
                        }
                        importedVaultKeys += 1
                    }
                }
            }
        }

        // 2. Seed canonical folder pool from current store
        var folderPool: [String] = [L10n.generalFolder]
        for existingFolder in store.folders {
            let trimmed = existingFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !folderPool.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                folderPool.append(trimmed)
            }
        }
        for s in store.sessions where !s.isLocal {
            let trimmed = (s.folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !folderPool.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                folderPool.append(trimmed)
            }
        }

        func canonicalFolderName(_ raw: String?) -> String {
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = trimmed.isEmpty ? L10n.generalFolder : trimmed
            if let existing = folderPool.first(where: { $0.caseInsensitiveCompare(fallback) == .orderedSame }) {
                return existing
            }
            folderPool.append(fallback)
            return fallback
        }

        // 3. Pass 1: Insert / Update / Skip sessions and write isolated Keychain credentials
        var importedSessions = 0
        var updatedSessions = 0
        var skippedSessions = 0
        var importedCredentials = 0
        var sessionIdRemap: [UUID: UUID] = [:]
        var rawJumpChainByTargetId: [UUID: [UUID]] = [:]
        var importedFolderSet = Set<String>()

        for incoming in chosenSessions {
            let existingMatch = store.sessions.first {
                $0.id == incoming.id || (
                    $0.host.caseInsensitiveCompare(incoming.host) == .orderedSame &&
                    $0.port == incoming.port &&
                    $0.username.caseInsensitiveCompare(incoming.username) == .orderedSame &&
                    $0.name.caseInsensitiveCompare(incoming.name) == .orderedSame
                )
            }

            let resolvedFolder: String
            switch options.targetFolderMode {
            case .preserveOriginal:
                resolvedFolder = canonicalFolderName(incoming.folder)
            case .assignToFolder(let explicitFolder):
                resolvedFolder = canonicalFolderName(explicitFolder)
            }

            if let existing = existingMatch {
                switch options.conflictStrategy {
                case .skipExisting:
                    sessionIdRemap[incoming.id] = existing.id
                    skippedSessions += 1
                    continue

                case .overwriteExisting:
                    var updated = sanitizeSessionForShare(incoming)
                    updated.id = existing.id
                    updated.folder = resolvedFolder
                    updated.createdAt = existing.createdAt
                    updated.lastConnectedAt = existing.lastConnectedAt

                    let appliedCred = try applyImportedCredentials(
                        to: &updated,
                        sourceSessionID: incoming.id,
                        existingAuthMethod: existing.authMethod,
                        bundleCredentials: bundle.credentials,
                        importCredentials: options.importCredentials,
                        vaultRefRemap: vaultRefRemap,
                        vaultPassRefByNewPrivRef: vaultPassRefByNewPrivRef,
                        secretSaver: saver
                    )
                    if appliedCred { importedCredentials += 1 }

                    sessionIdRemap[incoming.id] = existing.id
                    rawJumpChainByTargetId[existing.id] = incoming.effectiveJumpServerChain
                    store.updateSession(updated)
                    updatedSessions += 1
                    importedFolderSet.insert(resolvedFolder)

                case .keepBoth:
                    let newId = UUID()
                    var copy = sanitizeSessionForShare(incoming)
                    copy.id = newId
                    copy.name = disambiguatedImportName(baseName: incoming.name, existingSessions: store.sessions)
                    copy.folder = resolvedFolder
                    copy.createdAt = Date()
                    copy.lastConnectedAt = nil

                    let appliedCred = try applyImportedCredentials(
                        to: &copy,
                        sourceSessionID: incoming.id,
                        existingAuthMethod: nil,
                        bundleCredentials: bundle.credentials,
                        importCredentials: options.importCredentials,
                        vaultRefRemap: vaultRefRemap,
                        vaultPassRefByNewPrivRef: vaultPassRefByNewPrivRef,
                        secretSaver: saver
                    )
                    if appliedCred { importedCredentials += 1 }

                    sessionIdRemap[incoming.id] = newId
                    rawJumpChainByTargetId[newId] = incoming.effectiveJumpServerChain
                    store.addSession(copy)
                    importedSessions += 1
                    importedFolderSet.insert(resolvedFolder)
                }
            } else {
                let targetId = store.sessions.contains(where: { $0.id == incoming.id }) ? UUID() : incoming.id
                var copy = sanitizeSessionForShare(incoming)
                copy.id = targetId
                copy.folder = resolvedFolder

                let appliedCred = try applyImportedCredentials(
                    to: &copy,
                    sourceSessionID: incoming.id,
                    existingAuthMethod: nil,
                    bundleCredentials: bundle.credentials,
                    importCredentials: options.importCredentials,
                    vaultRefRemap: vaultRefRemap,
                    vaultPassRefByNewPrivRef: vaultPassRefByNewPrivRef,
                    secretSaver: saver
                )
                if appliedCred { importedCredentials += 1 }

                sessionIdRemap[incoming.id] = targetId
                rawJumpChainByTargetId[targetId] = incoming.effectiveJumpServerChain
                store.addSession(copy)
                importedSessions += 1
                importedFolderSet.insert(resolvedFolder)
            }
        }

        // 4. Pass 2: Remap jumpServerChain / jumpServerId using final session ID mapping
        if !rawJumpChainByTargetId.isEmpty {
            var patched = store.sessions
            var didModifyJumpChain = false
            for idx in patched.indices {
                let targetId = patched[idx].id
                guard let origChain = rawJumpChainByTargetId[targetId], !origChain.isEmpty else { continue }
                let mappedChain = origChain.map { sessionIdRemap[$0] ?? $0 }
                if mappedChain != patched[idx].effectiveJumpServerChain {
                    patched[idx].jumpServerChain = mappedChain
                    patched[idx].jumpServerId = mappedChain.first
                    didModifyJumpChain = true
                }
            }
            if didModifyJumpChain {
                store.replaceAllSessions(patched)
            }
        }

        // 5. Merge selected attachments (tunnels scoped to non-skipped sessions, snippets, triggers, bookmarks)
        var importedTunnels = 0
        if options.includeTunnels, let tunManager = tunnelManager {
            let activeTargetIDs = Set(rawJumpChainByTargetId.keys)
            for var tun in bundle.pack.tunnels {
                guard chosenOriginIDs.contains(tun.sessionId),
                      let mappedSessionId = sessionIdRemap[tun.sessionId] else {
                    continue
                }
                if !activeTargetIDs.contains(mappedSessionId) && options.conflictStrategy == .skipExisting {
                    // For skipped existing sessions, still avoid breaking or duplicating tunnels unless new
                    if tunManager.tunnels.contains(where: {
                        $0.sessionId == mappedSessionId &&
                        $0.type == tun.type &&
                        $0.bindPort == tun.bindPort &&
                        $0.targetHost == tun.targetHost &&
                        $0.targetPort == tun.targetPort
                    }) {
                        continue
                    }
                }
                tun.sessionId = mappedSessionId
                if tunManager.tunnels.contains(where: { $0.id == tun.id }) {
                    tun.id = UUID()
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

        var importedSnippets = 0
        if options.includeSnippets {
            for snippet in bundle.pack.snippets {
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
        }

        var importedTriggers = 0
        if options.includeTriggers {
            var updatedTriggers = store.triggers
            for trigger in bundle.pack.triggers {
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
        }

        var importedBookmarks = 0
        if options.includeBookmarks, let bmManager = bookmarkManager {
            for bm in bundle.pack.bookmarks where !bm.isPreset {
                if !bmManager.isBookmarked(path: bm.path) {
                    bmManager.addCustomBookmark(name: bm.name, path: bm.path)
                    importedBookmarks += 1
                }
            }
        }

        return SharePackImportResult(
            importedSessions: importedSessions,
            updatedSessions: updatedSessions,
            skippedDuplicateSessions: skippedSessions,
            importedCredentials: importedCredentials,
            importedVaultKeys: importedVaultKeys,
            importedTunnels: importedTunnels,
            importedSnippets: importedSnippets,
            importedTriggers: importedTriggers,
            importedBookmarks: importedBookmarks,
            importedFolderNames: importedFolderSet.sorted()
        )
    }

    private static func disambiguatedImportName(baseName: String, existingSessions: [Session]) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? "导入主机" : trimmed
        let initial = "\(root) (导入)"
        if !existingSessions.contains(where: { $0.name.caseInsensitiveCompare(initial) == .orderedSame }) {
            return initial
        }
        var suffix = 2
        while existingSessions.contains(where: { $0.name.caseInsensitiveCompare("\(root) (导入 \(suffix))") == .orderedSame }) {
            suffix += 1
        }
        return "\(root) (导入 \(suffix))"
    }

    private static func applyImportedCredentials(
        to session: inout Session,
        sourceSessionID: UUID,
        existingAuthMethod: SSHAuthMethod?,
        bundleCredentials: SharePackCredentialPayload,
        importCredentials: Bool,
        vaultRefRemap: [String: String],
        vaultPassRefByNewPrivRef: [String: String],
        secretSaver: (String, String) throws -> String
    ) throws -> Bool {
        var didImportAny = false

        switch session.authMethod {
        case .password:
            if importCredentials,
               let password = bundleCredentials.sessionPasswords[sourceSessionID],
               !password.isEmpty {
                let desiredRef: String
                if case .password(let existingRef) = existingAuthMethod,
                   KeychainStore.isSessionSecretReference(existingRef) {
                    desiredRef = existingRef
                } else {
                    desiredRef = "ssh_\(session.id.uuidString)"
                }
                let savedRef = try secretSaver(desiredRef, password)
                session.authMethod = .password(keychainRef: savedRef)
                didImportAny = true
            } else if case .password(let existingRef) = existingAuthMethod {
                session.authMethod = .password(keychainRef: existingRef)
            } else {
                session.authMethod = .password(keychainRef: "")
            }

        case .privateKey(let keyPath, _):
            var resolvedKeyRef = keyPath
            var vaultLinkedPassRef: String? = nil

            if importCredentials,
               let origVaultRef = bundleCredentials.sessionVaultKeyRefs[sourceSessionID],
               let newVaultRef = vaultRefRemap[origVaultRef] {
                resolvedKeyRef = newVaultRef
                vaultLinkedPassRef = vaultPassRefByNewPrivRef[newVaultRef]
                didImportAny = true
            } else if resolvedKeyRef.isEmpty,
                      case .privateKey(let existingKeyRef, _) = existingAuthMethod {
                resolvedKeyRef = existingKeyRef
            }

            let savedPassRef: String?
            if importCredentials,
               let pass = bundleCredentials.sessionPassphrases[sourceSessionID],
               !pass.isEmpty {
                if let vaultPassRef = vaultLinkedPassRef {
                    savedPassRef = vaultPassRef
                } else {
                    let desiredPassRef: String
                    if case .privateKey(_, let existingPassRef?) = existingAuthMethod,
                       KeychainStore.isSessionSecretReference(existingPassRef) {
                        desiredPassRef = existingPassRef
                    } else {
                        desiredPassRef = "passphrase_\(session.id.uuidString)"
                    }
                    savedPassRef = try secretSaver(desiredPassRef, pass)
                    didImportAny = true
                }
            } else if let vaultPassRef = vaultLinkedPassRef {
                savedPassRef = vaultPassRef
            } else if case .privateKey(_, let existingPassRef) = existingAuthMethod {
                savedPassRef = existingPassRef
            } else {
                savedPassRef = nil
            }

            session.authMethod = .privateKey(keychainRef: resolvedKeyRef, passphraseRef: savedPassRef)

        case .certificate(let keyPath, let certPath, _):
            var resolvedKeyRef = keyPath
            var resolvedCertPath = certPath
            var vaultLinkedPassRef: String? = nil

            if importCredentials,
               let origVaultRef = bundleCredentials.sessionVaultKeyRefs[sourceSessionID],
               let newVaultRef = vaultRefRemap[origVaultRef] {
                resolvedKeyRef = newVaultRef
                vaultLinkedPassRef = vaultPassRefByNewPrivRef[newVaultRef]
                didImportAny = true
            } else if resolvedKeyRef.isEmpty,
                      case .certificate(let existingKeyRef, let existingCertPath, _) = existingAuthMethod {
                resolvedKeyRef = existingKeyRef
                if resolvedCertPath.isEmpty {
                    resolvedCertPath = existingCertPath
                }
            }

            let savedPassRef: String?
            if importCredentials,
               let pass = bundleCredentials.sessionPassphrases[sourceSessionID],
               !pass.isEmpty {
                if let vaultPassRef = vaultLinkedPassRef {
                    savedPassRef = vaultPassRef
                } else {
                    let desiredPassRef: String
                    if case .certificate(_, _, let existingPassRef?) = existingAuthMethod,
                       KeychainStore.isSessionSecretReference(existingPassRef) {
                        desiredPassRef = existingPassRef
                    } else {
                        desiredPassRef = "passphrase_\(session.id.uuidString)"
                    }
                    savedPassRef = try secretSaver(desiredPassRef, pass)
                    didImportAny = true
                }
            } else if let vaultPassRef = vaultLinkedPassRef {
                savedPassRef = vaultPassRef
            } else if case .certificate(_, _, let existingPassRef) = existingAuthMethod {
                savedPassRef = existingPassRef
            } else {
                savedPassRef = nil
            }

            session.authMethod = .certificate(
                keychainRef: resolvedKeyRef,
                certificatePath: resolvedCertPath,
                passphraseRef: savedPassRef
            )

        case .agent, .none:
            break
        }

        return didImportAny
    }
}

/// Source format detected by `SessionBundleExporter.inspectSharePackData(_:)`.
public enum SharePackSourceFormat: Sendable, Equatable {
    case envelopeV2(SharePackProtectionMode)
    case legacySharePackV1
    case legacySessionArray
}

/// Metadata & optional unlocked payload returned after inspecting an `.aetherpack` / `.json` file.
public struct SharePackInspection: Sendable, Equatable {
    public let sourceFormat: SharePackSourceFormat
    public let header: AetherShareEnvelopeHeader
    public let requiresPassphrase: Bool
    public let decryptedBundle: SharePackSecretBundle?

    public init(
        sourceFormat: SharePackSourceFormat,
        header: AetherShareEnvelopeHeader,
        requiresPassphrase: Bool,
        decryptedBundle: SharePackSecretBundle?
    ) {
        self.sourceFormat = sourceFormat
        self.header = header
        self.requiresPassphrase = requiresPassphrase
        self.decryptedBundle = decryptedBundle
    }
}

/// Duplicate-host handling mode during interactive share import.
public enum SharePackConflictStrategy: String, CaseIterable, Sendable, Equatable {
    case skipExisting
    case overwriteExisting
    case keepBoth

    public var title: String {
        switch self {
        case .skipExisting: return "跳过重复"
        case .overwriteExisting: return "覆盖更新"
        case .keepBoth: return "保留两份"
        }
    }
}

/// Destination group strategy when importing shared sessions.
public enum SharePackTargetFolderMode: Sendable, Equatable {
    case preserveOriginal
    case assignToFolder(String)
}

/// User options passed into `SessionBundleExporter.importDecryptedBundle(...)`.
public struct SharePackImportOptions: Sendable, Equatable {
    public var selectedSessionIDs: Set<UUID>?
    public var includeTunnels: Bool
    public var includeSnippets: Bool
    public var includeTriggers: Bool
    public var includeBookmarks: Bool
    public var conflictStrategy: SharePackConflictStrategy
    public var targetFolderMode: SharePackTargetFolderMode
    public var importCredentials: Bool

    public init(
        selectedSessionIDs: Set<UUID>? = nil,
        includeTunnels: Bool = true,
        includeSnippets: Bool = true,
        includeTriggers: Bool = true,
        includeBookmarks: Bool = true,
        conflictStrategy: SharePackConflictStrategy = .skipExisting,
        targetFolderMode: SharePackTargetFolderMode = .preserveOriginal,
        importCredentials: Bool = true
    ) {
        self.selectedSessionIDs = selectedSessionIDs
        self.includeTunnels = includeTunnels
        self.includeSnippets = includeSnippets
        self.includeTriggers = includeTriggers
        self.includeBookmarks = includeBookmarks
        self.conflictStrategy = conflictStrategy
        self.targetFolderMode = targetFolderMode
        self.importCredentials = importCredentials
    }
}

/// Detailed summary produced by `SessionBundleExporter.importDecryptedBundle(...)`.
public struct SharePackImportResult: Sendable, Equatable {
    public let importedSessions: Int
    public let updatedSessions: Int
    public let skippedDuplicateSessions: Int
    public let importedCredentials: Int
    public let importedVaultKeys: Int
    public let importedTunnels: Int
    public let importedSnippets: Int
    public let importedTriggers: Int
    public let importedBookmarks: Int
    public let importedFolderNames: [String]

    public init(
        importedSessions: Int,
        updatedSessions: Int,
        skippedDuplicateSessions: Int,
        importedCredentials: Int,
        importedVaultKeys: Int,
        importedTunnels: Int,
        importedSnippets: Int,
        importedTriggers: Int,
        importedBookmarks: Int,
        importedFolderNames: [String]
    ) {
        self.importedSessions = importedSessions
        self.updatedSessions = updatedSessions
        self.skippedDuplicateSessions = skippedDuplicateSessions
        self.importedCredentials = importedCredentials
        self.importedVaultKeys = importedVaultKeys
        self.importedTunnels = importedTunnels
        self.importedSnippets = importedSnippets
        self.importedTriggers = importedTriggers
        self.importedBookmarks = importedBookmarks
        self.importedFolderNames = importedFolderNames
    }

    public var summaryText: String {
        var parts: [String] = []
        if importedSessions > 0 { parts.append("新增 \(importedSessions) 台主机") }
        if updatedSessions > 0 { parts.append("覆盖更新 \(updatedSessions) 台") }
        if skippedDuplicateSessions > 0 { parts.append("跳过重复 \(skippedDuplicateSessions) 台") }
        if importedCredentials > 0 { parts.append("写入凭据 \(importedCredentials) 项") }
        if importedVaultKeys > 0 { parts.append("导入保险库密钥 \(importedVaultKeys) 把") }
        if importedTunnels > 0 { parts.append("隧道 \(importedTunnels) 条") }
        if importedSnippets > 0 { parts.append("快捷命令 \(importedSnippets) 条") }
        if importedTriggers > 0 { parts.append("触发器 \(importedTriggers) 条") }
        if importedBookmarks > 0 { parts.append("书签 \(importedBookmarks) 个") }
        return parts.isEmpty ? "未导入任何新项目" : parts.joined(separator: " · ")
    }
}
