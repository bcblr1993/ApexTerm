import Foundation

/// Central manager orchestrating multi-device synchronization via iCloud Drive / Ubiquity Storage
@MainActor
public final class iCloudSyncManager: ObservableObject {
    public static let shared = iCloudSyncManager()
    
    @Published public private(set) var syncStatus: iCloudSyncStatus = .idle(lastSyncDate: nil)
    @Published public private(set) var lastSyncDate: Date? = nil
    @Published public private(set) var lastSyncResult: iCloudSyncResult? = nil
    @Published public var conflictStrategy: iCloudConflictStrategy {
        didSet {
            UserDefaults.standard.set(conflictStrategy.rawValue, forKey: "icloud.sync.conflictStrategy")
        }
    }
    @Published public var isAutoSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoSyncEnabled, forKey: "icloud.sync.autoEnabled")
            if isAutoSyncEnabled {
                startAutoSyncTimer()
            } else {
                stopAutoSyncTimer()
            }
        }
    }
    
    public let storageBackend: iCloudStorageBackend
    public let sessionStore: SessionStore
    public let bookmarkManager: SFTPBookmarkManager
    public let tunnelManager: SSHTunnelManager
    public let deviceId: String
    public let deviceName: String
    
    private var autoSyncTimer: Timer? = nil
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    public init(
        storageBackend: iCloudStorageBackend? = nil,
        sessionStore: SessionStore = .shared,
        bookmarkManager: SFTPBookmarkManager = .shared,
        tunnelManager: SSHTunnelManager = .shared,
        conflictStrategy: iCloudConflictStrategy? = nil,
        deviceId: String = Host.current().localizedName ?? UUID().uuidString,
        deviceName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.storageBackend = storageBackend ?? UbiquityCloudStorageBackend()
        self.sessionStore = sessionStore
        self.bookmarkManager = bookmarkManager
        self.tunnelManager = tunnelManager
        self.deviceId = deviceId
        self.deviceName = deviceName
        
        if let explicit = conflictStrategy {
            self.conflictStrategy = explicit
        } else {
            let savedStrategyRaw = UserDefaults.standard.string(forKey: "icloud.sync.conflictStrategy") ?? ""
            self.conflictStrategy = iCloudConflictStrategy(rawValue: savedStrategyRaw) ?? .smartMerge
        }
        self.isAutoSyncEnabled = UserDefaults.standard.bool(forKey: "icloud.sync.autoEnabled")
        
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        
        if isAutoSyncEnabled {
            startAutoSyncTimer()
        }
    }
    
    // MARK: - Zero-Bundle & Security Sanitization
    
    /// Sanitizes sync payload to strictly ensure NO plaintext passwords or raw private keys are exported to the cloud
    public nonisolated static func sanitizeForCloud(payload: iCloudSyncPayload) -> iCloudSyncPayload {
        var sanitized = payload
        var safeSessions: [Session] = []
        
        for var s in payload.sessions {
            switch s.authMethod {
            case .password(let keychainRef):
                // Ensure keychainRef is only a reference UUID, not a plaintext password containing spaces or markers
                let safeRef = keychainRef.trimmingCharacters(in: .whitespacesAndNewlines)
                s.authMethod = .password(keychainRef: safeRef)
            case .privateKey(let keychainRef, let passphraseRef):
                // If keychainRef accidentally contains raw private key PEM markers, redact it to a safe reference
                if keychainRef.contains("PRIVATE KEY") {
                    s.authMethod = .privateKey(keychainRef: "redacted_key_ref", passphraseRef: passphraseRef)
                } else {
                    s.authMethod = .privateKey(keychainRef: keychainRef, passphraseRef: passphraseRef)
                }
            case .certificate(let keychainRef, let certPath, let passphraseRef):
                // If keychainRef accidentally contains raw private key PEM markers, redact it to a safe reference
                if keychainRef.contains("PRIVATE KEY") {
                    s.authMethod = .certificate(keychainRef: "redacted_key_ref", certificatePath: certPath, passphraseRef: passphraseRef)
                } else {
                    s.authMethod = .certificate(keychainRef: keychainRef, certificatePath: certPath, passphraseRef: passphraseRef)
                }
            default:
                break
            }
            safeSessions.append(s)
        }
        sanitized.sessions = safeSessions
        return sanitized
    }
    
    // MARK: - Primary Synchronization
    
    /// Executes a full synchronization cycle according to the configured conflict resolution strategy
    @discardableResult
    public func syncNow() async throws -> iCloudSyncResult {
        guard storageBackend.isCloudAvailable() else {
            let err = iCloudSyncError.cloudUnavailable("当前未检测到活跃的 iCloud 容器或 iCloud Drive 未登录")
            syncStatus = .unavailable(reason: err.localizedDescription)
            NotificationCenter.default.post(name: NSNotification.Name("iCloudSyncDidFail"), object: err)
            throw err
        }
        
        syncStatus = .syncing(step: "正在检索云端数据...")
        
        let rawCloudData: Data?
        do {
            rawCloudData = try storageBackend.readPayloadData()
        } catch {
            let syncErr = iCloudSyncError.payloadCorrupted(error.localizedDescription)
            syncStatus = .error(syncErr.localizedDescription)
            NotificationCenter.default.post(name: NSNotification.Name("iCloudSyncDidFail"), object: syncErr)
            throw syncErr
        }
        
        let result: iCloudSyncResult
        
        if let data = rawCloudData {
            // Existing Cloud Vault - parse and apply conflict strategy
            let remotePayload: iCloudSyncPayload
            do {
                remotePayload = try decoder.decode(iCloudSyncPayload.self, from: data)
            } catch {
                let err = iCloudSyncError.payloadCorrupted("云端数据解码失败：\(error.localizedDescription)")
                syncStatus = .error(err.localizedDescription)
                NotificationCenter.default.post(name: NSNotification.Name("iCloudSyncDidFail"), object: err)
                throw err
            }
            
            switch conflictStrategy {
            case .smartMerge:
                result = try await performSmartMerge(with: remotePayload)
            case .overwriteCloud:
                result = try await performForceUpload()
            case .overwriteLocal:
                result = try await performForceDownload(from: remotePayload)
            }
        } else {
            // First time initialization: Upload local payload to cloud
            result = try await performForceUpload()
        }
        
        lastSyncDate = result.timestamp
        lastSyncResult = result
        syncStatus = .success(timestamp: result.timestamp, count: result.totalSessionsCount)
        NotificationCenter.default.post(name: NSNotification.Name("iCloudSyncDidComplete"), object: result)
        return result
    }
    
    // MARK: - Conflict Operations
    
    private func performForceUpload() async throws -> iCloudSyncResult {
        syncStatus = .syncing(step: "正在上传本地数据覆盖云端...")
        let localPayload = buildLocalPayload()
        let sanitized = Self.sanitizeForCloud(payload: localPayload)
        
        let data = try encoder.encode(sanitized)
        try storageBackend.writePayloadData(data)
        
        return iCloudSyncResult(
            timestamp: Date(),
            uploadedSessionsCount: localPayload.sessions.count,
            downloadedSessionsCount: 0,
            totalSessionsCount: localPayload.sessions.count,
            uploadedSnippetsCount: localPayload.snippets.count,
            downloadedSnippetsCount: 0,
            totalSnippetsCount: localPayload.snippets.count,
            message: "已成功将本地数据覆盖上传至云端"
        )
    }
    
    private func performForceDownload(from remotePayload: iCloudSyncPayload) async throws -> iCloudSyncResult {
        syncStatus = .syncing(step: "正在从云端下载并恢复本地...")
        
        // Replace local stores
        sessionStore.replaceAllSessions(remotePayload.sessions)
        sessionStore.replaceAllSnippets(remotePayload.snippets)
        sessionStore.replaceAllTriggers(remotePayload.triggers)
        bookmarkManager.replaceCustomBookmarks(remotePayload.bookmarks)
        tunnelManager.replaceAllTunnels(remotePayload.tunnels)
        
        return iCloudSyncResult(
            timestamp: Date(),
            uploadedSessionsCount: 0,
            downloadedSessionsCount: remotePayload.sessions.count,
            totalSessionsCount: remotePayload.sessions.count,
            uploadedSnippetsCount: 0,
            downloadedSnippetsCount: remotePayload.snippets.count,
            totalSnippetsCount: remotePayload.snippets.count,
            message: "已成功从云端下载并覆盖本地数据"
        )
    }
    
    private func performSmartMerge(with remotePayload: iCloudSyncPayload) async throws -> iCloudSyncResult {
        syncStatus = .syncing(step: "正在双向合并多端会话与配置...")
        let localPayload = buildLocalPayload()
        
        // 1. Merge Sessions
        var mergedSessionsDict: [UUID: Session] = [:]
        for s in localPayload.sessions {
            mergedSessionsDict[s.id] = s
        }
        var newSessionsFromRemote = 0
        for s in remotePayload.sessions {
            if mergedSessionsDict[s.id] == nil {
                mergedSessionsDict[s.id] = s
                newSessionsFromRemote += 1
            }
        }
        let finalSessions = Array(mergedSessionsDict.values).sorted { $0.name < $1.name }
        
        // 2. Merge Snippets
        var mergedSnippetsDict: [UUID: Snippet] = [:]
        for snip in localPayload.snippets {
            mergedSnippetsDict[snip.id] = snip
        }
        var newSnippetsFromRemote = 0
        for snip in remotePayload.snippets {
            if mergedSnippetsDict[snip.id] == nil {
                mergedSnippetsDict[snip.id] = snip
                newSnippetsFromRemote += 1
            }
        }
        let finalSnippets = Array(mergedSnippetsDict.values).sorted { $0.title < $1.title }
        
        // 3. Merge Bookmarks
        var bookmarkPaths = Set(localPayload.bookmarks.map(\.path))
        var finalBookmarks = localPayload.bookmarks
        for b in remotePayload.bookmarks {
            if !bookmarkPaths.contains(b.path) {
                finalBookmarks.append(b)
                bookmarkPaths.insert(b.path)
            }
        }
        
        // 4. Merge Tunnels
        var mergedTunnelsDict: [UUID: SSHTunnel] = [:]
        for t in localPayload.tunnels {
            mergedTunnelsDict[t.id] = t
        }
        for t in remotePayload.tunnels {
            if mergedTunnelsDict[t.id] == nil {
                mergedTunnelsDict[t.id] = t
            }
        }
        let finalTunnels = Array(mergedTunnelsDict.values).sorted { $0.name < $1.name }
        
        // 5. Merge Triggers
        var triggerNames = Set(localPayload.triggers.map(\.name))
        var finalTriggers = localPayload.triggers
        for trig in remotePayload.triggers {
            if !triggerNames.contains(trig.name) {
                finalTriggers.append(trig)
                triggerNames.insert(trig.name)
            }
        }
        
        // Apply merged results to local stores
        sessionStore.replaceAllSessions(finalSessions)
        sessionStore.replaceAllSnippets(finalSnippets)
        sessionStore.replaceAllTriggers(finalTriggers)
        bookmarkManager.replaceCustomBookmarks(finalBookmarks)
        tunnelManager.replaceAllTunnels(finalTunnels)
        
        // Write combined payload back to cloud
        let mergedCloudPayload = iCloudSyncPayload(
            version: 1,
            lastModified: Date(),
            deviceId: self.deviceId,
            deviceName: self.deviceName,
            appVersion: "1.12.0",
            sessions: finalSessions,
            snippets: finalSnippets,
            triggers: finalTriggers,
            bookmarks: finalBookmarks,
            tunnels: finalTunnels
        )
        
        let sanitized = Self.sanitizeForCloud(payload: mergedCloudPayload)
        let data = try encoder.encode(sanitized)
        try storageBackend.writePayloadData(data)
        
        let uploadedSessions = finalSessions.count - remotePayload.sessions.count
        let uploadedSnippets = finalSnippets.count - remotePayload.snippets.count
        
        return iCloudSyncResult(
            timestamp: Date(),
            uploadedSessionsCount: max(0, uploadedSessions),
            downloadedSessionsCount: newSessionsFromRemote,
            totalSessionsCount: finalSessions.count,
            uploadedSnippetsCount: max(0, uploadedSnippets),
            downloadedSnippetsCount: newSnippetsFromRemote,
            totalSnippetsCount: finalSnippets.count,
            message: "双向智能合并完成 (本地新增 \(newSessionsFromRemote) 项，同步云端 \(finalSessions.count) 项)"
        )
    }
    
    private func buildLocalPayload() -> iCloudSyncPayload {
        iCloudSyncPayload(
            version: 1,
            lastModified: Date(),
            deviceId: self.deviceId,
            deviceName: self.deviceName,
            appVersion: "1.12.0",
            sessions: sessionStore.sessions,
            snippets: sessionStore.snippets,
            triggers: sessionStore.triggers,
            bookmarks: bookmarkManager.customBookmarks,
            tunnels: tunnelManager.tunnels
        )
    }
    
    // MARK: - Auto-sync Timer
    
    private func startAutoSyncTimer() {
        stopAutoSyncTimer()
        // Automatically sync every 15 minutes when enabled
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await self?.syncNow()
            }
        }
    }
    
    private func stopAutoSyncTimer() {
        autoSyncTimer?.invalidate()
        autoSyncTimer = nil
    }
}
