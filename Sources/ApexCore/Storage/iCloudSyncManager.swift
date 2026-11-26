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

    /// Local sync baseline persisted when `stateStorageURL` is configured (for `.shared` or explicit test state URL).
    private struct SyncBaselineState: Codable {
        var knownSessionIDs: Set<UUID> = []
        var knownSnippetIDs: Set<UUID> = []
        var knownTriggerIDs: Set<UUID> = []
        var knownTunnelIDs: Set<UUID> = []
        var knownBookmarkPaths: Set<String> = []
        var itemHashes: [UUID: String] = [:]
        var itemUpdatedAt: [UUID: Date] = [:]
        var deletedTombstones: [UUID: Date] = [:]
        var deletedBookmarkPaths: [String: Date] = [:]
    }

    private var baselineState = SyncBaselineState()
    private let stateStorageURL: URL?
    private var autoSyncTimer: Timer? = nil
    private var isSyncing = false
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    
    public init(
        storageBackend: iCloudStorageBackend? = nil,
        sessionStore: SessionStore = .shared,
        bookmarkManager: SFTPBookmarkManager = .shared,
        tunnelManager: SSHTunnelManager = .shared,
        conflictStrategy: iCloudConflictStrategy? = nil,
        deviceId: String = Host.current().localizedName ?? UUID().uuidString,
        deviceName: String = Host.current().localizedName ?? "Mac",
        stateStorageURL: URL? = nil
    ) {
        self.storageBackend = storageBackend ?? UbiquityCloudStorageBackend()
        self.sessionStore = sessionStore
        self.bookmarkManager = bookmarkManager
        self.tunnelManager = tunnelManager
        self.deviceId = deviceId
        self.deviceName = deviceName

        if let stateStorageURL {
            self.stateStorageURL = stateStorageURL
        } else if storageBackend == nil {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = SessionStore.defaultDirectory(appSupport: appSupport, bundleIdentifier: Bundle.main.bundleIdentifier)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.stateStorageURL = dir.appendingPathComponent("icloud_sync_baseline.json")
        } else {
            self.stateStorageURL = nil
        }
        
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

        loadBaselineState()
        
        if isAutoSyncEnabled {
            startAutoSyncTimer()
        }
    }
    
    public nonisolated static var resolvedAppVersion: String {
        Bundle.apexResolvedAppVersion
    }

    // MARK: - Zero-Bundle & Security Sanitization
    
    /// Sanitizes sync payload to strictly ensure NO plaintext passwords or raw private keys are exported to the cloud
    public nonisolated static func sanitizeForCloud(payload: iCloudSyncPayload) -> iCloudSyncPayload {
        var sanitized = payload
        var safeSessions: [Session] = []
        
        for var s in payload.sessions {
            switch s.authMethod {
            case .password(let keychainRef):
                // Clear anything that is not a recognized Keychain reference (blocks single-token legacy passwords too).
                let safeRef = keychainRef.trimmingCharacters(in: .whitespacesAndNewlines)
                if KeychainStore.isManagedReference(safeRef) {
                    s.authMethod = .password(keychainRef: safeRef)
                } else {
                    s.authMethod = .password(keychainRef: "")
                }
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
            s.environmentVariables = SessionStartupHelper.sanitizeEnvironmentForCloud(s.environmentVariables)
            s.proxyCommand = SessionStartupHelper.sanitizeProxyCommand(s.proxyCommand)
            safeSessions.append(s)
        }
        sanitized.sessions = safeSessions
        return sanitized
    }

    // MARK: - Explicit Tombstone Helpers

    /// Records a local deletion tombstone for an entity UUID (session, snippet, trigger, or tunnel).
    public func recordDeletion(id: UUID, at date: Date = Date()) {
        baselineState.deletedTombstones[id] = max(baselineState.deletedTombstones[id] ?? .distantPast, date)
        baselineState.knownSessionIDs.remove(id)
        baselineState.knownSnippetIDs.remove(id)
        baselineState.knownTriggerIDs.remove(id)
        baselineState.knownTunnelIDs.remove(id)
        saveBaselineState()
    }

    /// Records a local deletion tombstone for a custom SFTP bookmark path.
    public func recordBookmarkDeletion(path: String, at date: Date = Date()) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        baselineState.deletedBookmarkPaths[trimmed] = max(baselineState.deletedBookmarkPaths[trimmed] ?? .distantPast, date)
        baselineState.knownBookmarkPaths.remove(trimmed)
        saveBaselineState()
    }

    // MARK: - Primary Synchronization
    
    /// Executes a synchronization cycle with a temporary conflict resolution strategy without mutating persisted settings.
    @discardableResult
    public func syncNow(withTemporaryStrategy strategy: iCloudConflictStrategy) async throws -> iCloudSyncResult {
        try await performSync(strategy: strategy)
    }

    /// Executes a full synchronization cycle according to the configured conflict resolution strategy
    @discardableResult
    public func syncNow() async throws -> iCloudSyncResult {
        try await performSync(strategy: conflictStrategy)
    }

    /// Computes a read-only preview diff between local state and remote iCloud vault without mutating either side.
    public func previewDiff() async throws -> iCloudSyncDiff {
        guard storageBackend.isCloudAvailable() else {
            throw iCloudSyncError.cloudUnavailable("当前未检测到活跃的 iCloud 容器或 iCloud Drive 未登录")
        }

        let rawCloudData = try await storageBackend.readPayloadDataAsync()
        let localSnapshot = buildLocalSnapshot(commitBaselineMutations: false)

        guard let data = rawCloudData else {
            return Self.computeDiff(local: localSnapshot.payload, remote: nil)
        }

        let remotePayload: iCloudSyncPayload
        do {
            remotePayload = try decoder.decode(iCloudSyncPayload.self, from: data)
        } catch {
            throw iCloudSyncError.payloadCorrupted("云端数据解码失败：\(error.localizedDescription)")
        }
        return Self.computeDiff(local: localSnapshot.payload, remote: remotePayload)
    }

    private func performSync(strategy: iCloudConflictStrategy) async throws -> iCloudSyncResult {
        guard !isSyncing else {
            throw iCloudSyncError.mergeFailed("已有同步任务正在进行中")
        }
        isSyncing = true
        defer { isSyncing = false }

        guard storageBackend.isCloudAvailable() else {
            let err = iCloudSyncError.cloudUnavailable("当前未检测到活跃的 iCloud 容器或 iCloud Drive 未登录")
            syncStatus = .unavailable(reason: err.localizedDescription)
            NotificationCenter.default.post(name: NSNotification.Name("iCloudSyncDidFail"), object: err)
            throw err
        }
        
        syncStatus = .syncing(step: "正在检索云端数据...")
        
        let rawCloudData: Data?
        do {
            rawCloudData = try await storageBackend.readPayloadDataAsync()
        } catch let syncErr as iCloudSyncError {
            if case .cloudDownloadingPlaceholder(let msg) = syncErr {
                syncStatus = .unavailable(reason: msg)
            } else {
                syncStatus = .error(syncErr.localizedDescription)
            }
            NotificationCenter.default.post(name: NSNotification.Name("iCloudSyncDidFail"), object: syncErr)
            throw syncErr
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
            
            switch strategy {
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
        let snapshot = buildLocalSnapshot(commitBaselineMutations: true)
        let localPayload = snapshot.payload
        let sanitized = Self.sanitizeForCloud(payload: localPayload)
        
        let data = try encoder.encode(sanitized)
        try await storageBackend.writePayloadDataAsync(data)

        commitSyncedBaseline(payload: localPayload, itemUpdatedAt: localPayload.itemUpdatedAt ?? [:], tombstones: localPayload.deletedTombstones ?? [:], bookmarkTombstones: localPayload.deletedBookmarkPaths ?? [:])
        
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

        commitSyncedBaseline(
            payload: remotePayload,
            itemUpdatedAt: remotePayload.itemUpdatedAt ?? [:],
            tombstones: remotePayload.deletedTombstones ?? [:],
            bookmarkTombstones: remotePayload.deletedBookmarkPaths ?? [:]
        )
        
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
        let snapshot = buildLocalSnapshot(commitBaselineMutations: true)
        let outcome = Self.mergePayloads(
            local: snapshot.payload,
            remote: remotePayload,
            deviceId: deviceId,
            deviceName: deviceName,
            appVersion: Self.resolvedAppVersion
        )

        // Apply merged results to local stores
        sessionStore.replaceAllSessions(outcome.mergedPayload.sessions)
        sessionStore.replaceAllSnippets(outcome.mergedPayload.snippets)
        sessionStore.replaceAllTriggers(outcome.mergedPayload.triggers)
        bookmarkManager.replaceCustomBookmarks(outcome.mergedPayload.bookmarks)
        tunnelManager.replaceAllTunnels(outcome.mergedPayload.tunnels)
        
        // Write combined payload back to cloud off-MainActor
        let sanitized = Self.sanitizeForCloud(payload: outcome.mergedPayload)
        let data = try encoder.encode(sanitized)
        try await storageBackend.writePayloadDataAsync(data)

        commitSyncedBaseline(
            payload: outcome.mergedPayload,
            itemUpdatedAt: outcome.mergedPayload.itemUpdatedAt ?? [:],
            tombstones: outcome.mergedPayload.deletedTombstones ?? [:],
            bookmarkTombstones: outcome.mergedPayload.deletedBookmarkPaths ?? [:]
        )
        
        return iCloudSyncResult(
            timestamp: Date(),
            uploadedSessionsCount: outcome.uploadedSessionsCount,
            downloadedSessionsCount: outcome.downloadedSessionsCount,
            totalSessionsCount: outcome.mergedPayload.sessions.count,
            uploadedSnippetsCount: outcome.uploadedSnippetsCount,
            downloadedSnippetsCount: outcome.downloadedSnippetsCount,
            totalSnippetsCount: outcome.mergedPayload.snippets.count,
            message: "双向智能合并完成 (本地新增/更新 \(outcome.downloadedSessionsCount) 项，移除 \(outcome.deletedSessionsCount) 项，同步云端 \(outcome.mergedPayload.sessions.count) 项)"
        )
    }

    // MARK: - Pure v2 Merge & Diff Engine

    private struct MergeOutcome {
        let mergedPayload: iCloudSyncPayload
        let uploadedSessionsCount: Int
        let downloadedSessionsCount: Int
        let deletedSessionsCount: Int
        let uploadedSnippetsCount: Int
        let downloadedSnippetsCount: Int
    }

    private nonisolated static func effectiveSessionTimestamp(_ session: Session, payload: iCloudSyncPayload) -> Date? {
        let explicit = session.updatedAt
        let meta = payload.itemUpdatedAt?[session.id]
        switch (explicit, meta) {
        case (.some(let a), .some(let b)): return max(a, b)
        case (.some(let a), .none): return a
        case (.none, .some(let b)): return b
        case (.none, .none): return nil
        }
    }

    private nonisolated static func fallbackSessionComparisonDate(_ session: Session) -> Date {
        session.updatedAt ?? session.lastConnectedAt ?? session.createdAt
    }

    private nonisolated static func pruneOldTombstones(_ tombstones: [UUID: Date], now: Date = Date()) -> [UUID: Date] {
        let cutoff = now.addingTimeInterval(-90 * 24 * 3600)
        return tombstones.filter { $0.value >= cutoff }
    }

    private nonisolated static func mergeUUIDEntities<T: Identifiable & Equatable>(
        localItems: [T],
        remoteItems: [T],
        localTimestamp: (T) -> Date?,
        remoteTimestamp: (T) -> Date?,
        localTombstones: [UUID: Date],
        remoteTombstones: [UUID: Date],
        sort: (T, T) -> Bool
    ) -> (
        merged: [T],
        itemTimestamps: [UUID: Date],
        survivingTombstones: [UUID: Date],
        addedFromRemote: Int,
        updatedFromRemote: Int,
        deletedLocally: Int,
        deletedRemotely: Int
    ) where T.ID == UUID {
        let localMap = Dictionary(localItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteMap = Dictionary(remoteItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var allIDs = Set(localMap.keys).union(remoteMap.keys)
        allIDs.formUnion(localTombstones.keys)
        allIDs.formUnion(remoteTombstones.keys)

        var merged: [T] = []
        var itemTimestamps: [UUID: Date] = [:]
        var survivingTombstones: [UUID: Date] = [:]
        var addedFromRemote = 0
        var updatedFromRemote = 0
        var deletedLocally = 0
        var deletedRemotely = 0

        for id in allIDs {
            let localItem = localMap[id]
            let remoteItem = remoteMap[id]
            let localTomb = localTombstones[id]
            let remoteTomb = remoteTombstones[id]
            let latestTomb = [localTomb, remoteTomb].compactMap { $0 }.max()

            switch (localItem, remoteItem) {
            case (.some(let lItem), .some(let rItem)):
                let lTime = localTimestamp(lItem)
                let rTime = remoteTimestamp(rItem)
                let newestItemTime = [lTime, rTime].compactMap { $0 }.max()

                if let tomb = latestTomb, (newestItemTime == nil || tomb >= newestItemTime!) {
                    survivingTombstones[id] = tomb
                    deletedLocally += 1
                    continue
                }

                if lItem == rItem {
                    merged.append(lItem)
                    if let t = newestItemTime { itemTimestamps[id] = t }
                } else if let rt = rTime, (lTime == nil || rt > lTime!) {
                    merged.append(rItem)
                    itemTimestamps[id] = rt
                    updatedFromRemote += 1
                } else {
                    merged.append(lItem)
                    if let t = lTime ?? rTime { itemTimestamps[id] = t }
                }

            case (.some(let lItem), .none):
                let lTime = localTimestamp(lItem)
                if let rTomb = remoteTomb, (lTime == nil || rTomb >= lTime!) {
                    survivingTombstones[id] = rTomb
                    deletedLocally += 1
                } else {
                    merged.append(lItem)
                    if let t = lTime { itemTimestamps[id] = t }
                }

            case (.none, .some(let rItem)):
                let rTime = remoteTimestamp(rItem)
                if let lTomb = localTomb, (rTime == nil || lTomb >= rTime!) {
                    survivingTombstones[id] = lTomb
                    deletedRemotely += 1
                } else {
                    merged.append(rItem)
                    if let t = rTime { itemTimestamps[id] = t }
                    addedFromRemote += 1
                }

            case (.none, .none):
                if let tomb = latestTomb {
                    survivingTombstones[id] = tomb
                }
            }
        }

        merged.sort(by: sort)
        return (
            merged,
            itemTimestamps,
            survivingTombstones,
            addedFromRemote,
            updatedFromRemote,
            deletedLocally,
            deletedRemotely
        )
    }

    private nonisolated static func mergePayloads(
        local: iCloudSyncPayload,
        remote: iCloudSyncPayload,
        deviceId: String,
        deviceName: String,
        appVersion: String
    ) -> MergeOutcome {
        let localTombstones = local.deletedTombstones ?? [:]
        let remoteTombstones = remote.deletedTombstones ?? [:]
        let now = Date()

        // 1. Sessions (honor explicit Session.updatedAt / itemUpdatedAt, fallback to createdAt/lastConnectedAt only if one side is edited)
        let sessionMerge = mergeUUIDEntities(
            localItems: local.sessions,
            remoteItems: remote.sessions,
            localTimestamp: { effectiveSessionTimestamp($0, payload: local) },
            remoteTimestamp: { effectiveSessionTimestamp($0, payload: remote) },
            localTombstones: localTombstones,
            remoteTombstones: remoteTombstones,
            sort: { $0.name < $1.name }
        )

        // 2. Snippets
        let snippetMerge = mergeUUIDEntities(
            localItems: local.snippets,
            remoteItems: remote.snippets,
            localTimestamp: { local.itemUpdatedAt?[$0.id] },
            remoteTimestamp: { remote.itemUpdatedAt?[$0.id] },
            localTombstones: localTombstones,
            remoteTombstones: remoteTombstones,
            sort: { $0.title < $1.title }
        )

        // 3. Bookmarks (keyed by path, supporting path tombstones)
        let localBMTomb = local.deletedBookmarkPaths ?? [:]
        let remoteBMTomb = remote.deletedBookmarkPaths ?? [:]
        var finalBookmarks: [SFTPBookmark] = []
        var seenBookmarkPaths = Set<String>()
        var survivingBookmarkTombstones: [String: Date] = [:]

        for b in local.bookmarks where !b.isPreset {
            let path = b.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !seenBookmarkPaths.contains(path) else { continue }
            let lTime = local.itemUpdatedAt?[b.id]
            if let rTomb = remoteBMTomb[path], (lTime == nil || rTomb >= lTime!) {
                survivingBookmarkTombstones[path] = rTomb
                continue
            }
            finalBookmarks.append(b)
            seenBookmarkPaths.insert(path)
        }
        for b in remote.bookmarks where !b.isPreset {
            let path = b.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !seenBookmarkPaths.contains(path) else { continue }
            let rTime = remote.itemUpdatedAt?[b.id]
            if let lTomb = localBMTomb[path], (rTime == nil || lTomb >= rTime!) {
                survivingBookmarkTombstones[path] = lTomb
                continue
            }
            finalBookmarks.append(b)
            seenBookmarkPaths.insert(path)
        }
        for (path, date) in localBMTomb.merging(remoteBMTomb, uniquingKeysWith: { max($0, $1) }) {
            if !seenBookmarkPaths.contains(path) {
                survivingBookmarkTombstones[path] = date
            }
        }

        // 4. Tunnels
        let tunnelMerge = mergeUUIDEntities(
            localItems: local.tunnels,
            remoteItems: remote.tunnels,
            localTimestamp: { local.itemUpdatedAt?[$0.id] },
            remoteTimestamp: { remote.itemUpdatedAt?[$0.id] },
            localTombstones: localTombstones,
            remoteTombstones: remoteTombstones,
            sort: { $0.name < $1.name }
        )

        // 5. Triggers (preserve UUID merge + name deduplication for seeded defaults)
        var triggerMerge = mergeUUIDEntities(
            localItems: local.triggers,
            remoteItems: remote.triggers,
            localTimestamp: { local.itemUpdatedAt?[$0.id] },
            remoteTimestamp: { remote.itemUpdatedAt?[$0.id] },
            localTombstones: localTombstones,
            remoteTombstones: remoteTombstones,
            sort: { $0.name < $1.name }
        )
        var seenTriggerNames = Set<String>()
        triggerMerge.merged = triggerMerge.merged.filter { seenTriggerNames.insert($0.name).inserted }

        var combinedItemUpdatedAt: [UUID: Date] = [:]
        for dict in [sessionMerge.itemTimestamps, snippetMerge.itemTimestamps, tunnelMerge.itemTimestamps, triggerMerge.itemTimestamps] {
            for (k, v) in dict {
                combinedItemUpdatedAt[k] = max(combinedItemUpdatedAt[k] ?? .distantPast, v)
            }
        }

        var combinedTombstones: [UUID: Date] = [:]
        for dict in [sessionMerge.survivingTombstones, snippetMerge.survivingTombstones, tunnelMerge.survivingTombstones, triggerMerge.survivingTombstones] {
            for (k, v) in dict {
                combinedTombstones[k] = max(combinedTombstones[k] ?? .distantPast, v)
            }
        }
        combinedTombstones = pruneOldTombstones(combinedTombstones, now: now)

        let mergedPayload = iCloudSyncPayload(
            version: 2,
            lastModified: now,
            updatedAt: now,
            deviceId: deviceId,
            deviceName: deviceName,
            appVersion: appVersion,
            sessions: sessionMerge.merged,
            snippets: snippetMerge.merged,
            triggers: triggerMerge.merged,
            bookmarks: finalBookmarks,
            tunnels: tunnelMerge.merged,
            deletedTombstones: combinedTombstones.isEmpty ? nil : combinedTombstones,
            itemUpdatedAt: combinedItemUpdatedAt.isEmpty ? nil : combinedItemUpdatedAt,
            deletedBookmarkPaths: survivingBookmarkTombstones.isEmpty ? nil : survivingBookmarkTombstones
        )

        let uploadedSessions = max(0, sessionMerge.merged.count - remote.sessions.count)
        let uploadedSnippets = max(0, snippetMerge.merged.count - remote.snippets.count)

        return MergeOutcome(
            mergedPayload: mergedPayload,
            uploadedSessionsCount: uploadedSessions,
            downloadedSessionsCount: sessionMerge.addedFromRemote + sessionMerge.updatedFromRemote,
            deletedSessionsCount: sessionMerge.deletedLocally,
            uploadedSnippetsCount: uploadedSnippets,
            downloadedSnippetsCount: snippetMerge.addedFromRemote + snippetMerge.updatedFromRemote
        )
    }

    /// Pure diff calculation between a local payload and optional remote payload.
    public nonisolated static func computeDiff(local: iCloudSyncPayload, remote: iCloudSyncPayload?) -> iCloudSyncDiff {
        guard let remote else {
            var added: [iCloudSyncDiffItem] = []
            for s in local.sessions {
                added.append(iCloudSyncDiffItem(
                    id: "session-\(s.id.uuidString)",
                    entityId: s.id,
                    domain: .session,
                    kind: .added,
                    source: .local,
                    title: s.name,
                    subtitle: "\(s.username)@\(s.host):\(s.port)",
                    localTimestamp: effectiveSessionTimestamp(s, payload: local) ?? s.createdAt
                ))
            }
            for snip in local.snippets {
                added.append(iCloudSyncDiffItem(
                    id: "snippet-\(snip.id.uuidString)",
                    entityId: snip.id,
                    domain: .snippet,
                    kind: .added,
                    source: .local,
                    title: snip.title,
                    subtitle: snip.command,
                    localTimestamp: local.itemUpdatedAt?[snip.id]
                ))
            }
            for tun in local.tunnels {
                added.append(iCloudSyncDiffItem(
                    id: "tunnel-\(tun.id.uuidString)",
                    entityId: tun.id,
                    domain: .tunnel,
                    kind: .added,
                    source: .local,
                    title: tun.name,
                    subtitle: tun.openSSHSpecifier,
                    localTimestamp: local.itemUpdatedAt?[tun.id]
                ))
            }
            for bm in local.bookmarks where !bm.isPreset {
                added.append(iCloudSyncDiffItem(
                    id: "bookmark-\(bm.path)",
                    entityId: bm.id,
                    domain: .bookmark,
                    kind: .added,
                    source: .local,
                    title: bm.name,
                    subtitle: bm.path
                ))
            }
            return iCloudSyncDiff(added: added)
        }

        var added: [iCloudSyncDiffItem] = []
        var modified: [iCloudSyncDiffItem] = []
        var deleted: [iCloudSyncDiffItem] = []

        let localTombstones = local.deletedTombstones ?? [:]
        let remoteTombstones = remote.deletedTombstones ?? [:]

        func diffUUIDDomain<T: Identifiable & Equatable>(
            domain: iCloudSyncDiffDomain,
            localItems: [T],
            remoteItems: [T],
            titleOf: (T) -> String,
            subtitleOf: (T) -> String,
            localTimeOf: (T) -> Date?,
            remoteTimeOf: (T) -> Date?
        ) where T.ID == UUID {
            let localMap = Dictionary(localItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let remoteMap = Dictionary(remoteItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let allIDs = Set(localMap.keys).union(remoteMap.keys)

            for id in allIDs {
                let lItem = localMap[id]
                let rItem = remoteMap[id]
                let lTomb = localTombstones[id]
                let rTomb = remoteTombstones[id]

                switch (lItem, rItem) {
                case (.some(let l), .some(let r)):
                    let lt = localTimeOf(l)
                    let rt = remoteTimeOf(r)
                    let latestItemTime = [lt, rt].compactMap { $0 }.max()
                    if let tomb = [lTomb, rTomb].compactMap({ $0 }).max(),
                       (latestItemTime == nil || tomb >= latestItemTime!) {
                        deleted.append(iCloudSyncDiffItem(
                            id: "\(domain.rawValue)-del-\(id.uuidString)",
                            entityId: id,
                            domain: domain,
                            kind: .deleted,
                            source: rTomb != nil ? .remote : .local,
                            title: titleOf(l),
                            subtitle: subtitleOf(l),
                            localTimestamp: lt ?? lTomb,
                            remoteTimestamp: rt ?? rTomb
                        ))
                    } else if l != r {
                        let winner: iCloudSyncDiffSource = (rt != nil && (lt == nil || rt! > lt!)) ? .remote : .local
                        modified.append(iCloudSyncDiffItem(
                            id: "\(domain.rawValue)-mod-\(id.uuidString)",
                            entityId: id,
                            domain: domain,
                            kind: .modified,
                            source: winner,
                            title: winner == .remote ? titleOf(r) : titleOf(l),
                            subtitle: winner == .remote ? subtitleOf(r) : subtitleOf(l),
                            localTimestamp: lt,
                            remoteTimestamp: rt
                        ))
                    }

                case (.some(let l), .none):
                    let lt = localTimeOf(l)
                    if let rTomb, (lt == nil || rTomb >= lt!) {
                        deleted.append(iCloudSyncDiffItem(
                            id: "\(domain.rawValue)-del-local-\(id.uuidString)",
                            entityId: id,
                            domain: domain,
                            kind: .deleted,
                            source: .remote,
                            title: titleOf(l),
                            subtitle: subtitleOf(l),
                            localTimestamp: lt,
                            remoteTimestamp: rTomb
                        ))
                    } else {
                        added.append(iCloudSyncDiffItem(
                            id: "\(domain.rawValue)-add-local-\(id.uuidString)",
                            entityId: id,
                            domain: domain,
                            kind: .added,
                            source: .local,
                            title: titleOf(l),
                            subtitle: subtitleOf(l),
                            localTimestamp: lt
                        ))
                    }

                case (.none, .some(let r)):
                    let rt = remoteTimeOf(r)
                    if let lTomb, (rt == nil || lTomb >= rt!) {
                        deleted.append(iCloudSyncDiffItem(
                            id: "\(domain.rawValue)-del-remote-\(id.uuidString)",
                            entityId: id,
                            domain: domain,
                            kind: .deleted,
                            source: .local,
                            title: titleOf(r),
                            subtitle: subtitleOf(r),
                            localTimestamp: lTomb,
                            remoteTimestamp: rt
                        ))
                    } else {
                        added.append(iCloudSyncDiffItem(
                            id: "\(domain.rawValue)-add-remote-\(id.uuidString)",
                            entityId: id,
                            domain: domain,
                            kind: .added,
                            source: .remote,
                            title: titleOf(r),
                            subtitle: subtitleOf(r),
                            remoteTimestamp: rt
                        ))
                    }

                case (.none, .none):
                    break
                }
            }
        }

        diffUUIDDomain(
            domain: .session,
            localItems: local.sessions,
            remoteItems: remote.sessions,
            titleOf: \.name,
            subtitleOf: { "\($0.username)@\($0.host):\($0.port)" },
            localTimeOf: { effectiveSessionTimestamp($0, payload: local) },
            remoteTimeOf: { effectiveSessionTimestamp($0, payload: remote) }
        )
        diffUUIDDomain(
            domain: .snippet,
            localItems: local.snippets,
            remoteItems: remote.snippets,
            titleOf: \.title,
            subtitleOf: \.command,
            localTimeOf: { local.itemUpdatedAt?[$0.id] },
            remoteTimeOf: { remote.itemUpdatedAt?[$0.id] }
        )
        diffUUIDDomain(
            domain: .tunnel,
            localItems: local.tunnels,
            remoteItems: remote.tunnels,
            titleOf: \.name,
            subtitleOf: \.openSSHSpecifier,
            localTimeOf: { local.itemUpdatedAt?[$0.id] },
            remoteTimeOf: { remote.itemUpdatedAt?[$0.id] }
        )
        diffUUIDDomain(
            domain: .trigger,
            localItems: local.triggers,
            remoteItems: remote.triggers,
            titleOf: \.name,
            subtitleOf: \.regexPattern,
            localTimeOf: { local.itemUpdatedAt?[$0.id] },
            remoteTimeOf: { remote.itemUpdatedAt?[$0.id] }
        )

        // Bookmarks diff by path
        let localBMMap = Dictionary(local.bookmarks.filter { !$0.isPreset }.map { ($0.path, $0) }, uniquingKeysWith: { f, _ in f })
        let remoteBMMap = Dictionary(remote.bookmarks.filter { !$0.isPreset }.map { ($0.path, $0) }, uniquingKeysWith: { f, _ in f })
        let localBMTomb = local.deletedBookmarkPaths ?? [:]
        let remoteBMTomb = remote.deletedBookmarkPaths ?? [:]
        for path in Set(localBMMap.keys).union(remoteBMMap.keys) {
            switch (localBMMap[path], remoteBMMap[path]) {
            case (.some(let l), .none):
                if let rTomb = remoteBMTomb[path] {
                    deleted.append(iCloudSyncDiffItem(id: "bm-del-\(path)", entityId: l.id, domain: .bookmark, kind: .deleted, source: .remote, title: l.name, subtitle: l.path, remoteTimestamp: rTomb))
                } else {
                    added.append(iCloudSyncDiffItem(id: "bm-add-local-\(path)", entityId: l.id, domain: .bookmark, kind: .added, source: .local, title: l.name, subtitle: l.path))
                }
            case (.none, .some(let r)):
                if let lTomb = localBMTomb[path] {
                    deleted.append(iCloudSyncDiffItem(id: "bm-del-remote-\(path)", entityId: r.id, domain: .bookmark, kind: .deleted, source: .local, title: r.name, subtitle: r.path, localTimestamp: lTomb))
                } else {
                    added.append(iCloudSyncDiffItem(id: "bm-add-remote-\(path)", entityId: r.id, domain: .bookmark, kind: .added, source: .remote, title: r.name, subtitle: r.path))
                }
            default:
                break
            }
        }

        added.sort { $0.title < $1.title }
        modified.sort { $0.title < $1.title }
        deleted.sort { $0.title < $1.title }

        return iCloudSyncDiff(
            added: added,
            modified: modified,
            deleted: deleted,
            remoteLastModified: remote.updatedAt ?? remote.lastModified,
            remoteDeviceName: remote.deviceName
        )
    }

    // MARK: - Baseline Tracking & Local Snapshot

    private func buildLocalSnapshot(commitBaselineMutations: Bool) -> (payload: iCloudSyncPayload, itemUpdatedAt: [UUID: Date]) {
        let now = Date()
        var working = baselineState

        let currentSessions = sessionStore.sessions
        let currentSnippets = sessionStore.snippets
        let currentTriggers = sessionStore.triggers
        let currentBookmarks = bookmarkManager.customBookmarks.filter { !$0.isPreset }
        let currentTunnels = tunnelManager.tunnels

        let currentSessionIDs = Set(currentSessions.map(\.id))
        let currentSnippetIDs = Set(currentSnippets.map(\.id))
        let currentTriggerIDs = Set(currentTriggers.map(\.id))
        let currentTunnelIDs = Set(currentTunnels.map(\.id))
        let currentBookmarkPaths = Set(currentBookmarks.map(\.path))

        // Detect deletions compared to previously synced baseline
        for oldId in working.knownSessionIDs where !currentSessionIDs.contains(oldId) {
            working.deletedTombstones[oldId] = max(working.deletedTombstones[oldId] ?? .distantPast, now)
        }
        for oldId in working.knownSnippetIDs where !currentSnippetIDs.contains(oldId) {
            working.deletedTombstones[oldId] = max(working.deletedTombstones[oldId] ?? .distantPast, now)
        }
        for oldId in working.knownTriggerIDs where !currentTriggerIDs.contains(oldId) {
            working.deletedTombstones[oldId] = max(working.deletedTombstones[oldId] ?? .distantPast, now)
        }
        for oldId in working.knownTunnelIDs where !currentTunnelIDs.contains(oldId) {
            working.deletedTombstones[oldId] = max(working.deletedTombstones[oldId] ?? .distantPast, now)
        }
        for oldPath in working.knownBookmarkPaths where !currentBookmarkPaths.contains(oldPath) {
            working.deletedBookmarkPaths[oldPath] = max(working.deletedBookmarkPaths[oldPath] ?? .distantPast, now)
        }

        // Detect content edits vs baseline and stamp itemUpdatedAt
        var itemTimestamps = working.itemUpdatedAt
        for s in currentSessions {
            let hash = itemDigest(s)
            if let explicit = s.updatedAt {
                itemTimestamps[s.id] = max(itemTimestamps[s.id] ?? .distantPast, explicit)
            } else if working.knownSessionIDs.contains(s.id), working.itemHashes[s.id] != hash {
                itemTimestamps[s.id] = now
            }
            if working.deletedTombstones[s.id] != nil {
                // Local item exists again -> keep item if newer
                if let ts = itemTimestamps[s.id], let tomb = working.deletedTombstones[s.id], ts > tomb {
                    working.deletedTombstones.removeValue(forKey: s.id)
                }
            }
            if commitBaselineMutations {
                working.itemHashes[s.id] = hash
            }
        }
        for snip in currentSnippets {
            let hash = itemDigest(snip)
            if working.knownSnippetIDs.contains(snip.id), working.itemHashes[snip.id] != hash {
                itemTimestamps[snip.id] = now
            }
            if commitBaselineMutations { working.itemHashes[snip.id] = hash }
        }
        for trig in currentTriggers {
            let hash = itemDigest(trig)
            if working.knownTriggerIDs.contains(trig.id), working.itemHashes[trig.id] != hash {
                itemTimestamps[trig.id] = now
            }
            if commitBaselineMutations { working.itemHashes[trig.id] = hash }
        }
        for tun in currentTunnels {
            let hash = itemDigest(tun)
            if working.knownTunnelIDs.contains(tun.id), working.itemHashes[tun.id] != hash {
                itemTimestamps[tun.id] = now
            }
            if commitBaselineMutations { working.itemHashes[tun.id] = hash }
        }

        if commitBaselineMutations {
            working.itemUpdatedAt = itemTimestamps
            baselineState = working
        }

        let payload = iCloudSyncPayload(
            version: 2,
            lastModified: now,
            updatedAt: now,
            deviceId: self.deviceId,
            deviceName: self.deviceName,
            appVersion: Self.resolvedAppVersion,
            sessions: currentSessions,
            snippets: currentSnippets,
            triggers: currentTriggers,
            bookmarks: currentBookmarks,
            tunnels: currentTunnels,
            deletedTombstones: working.deletedTombstones.isEmpty ? nil : working.deletedTombstones,
            itemUpdatedAt: itemTimestamps.isEmpty ? nil : itemTimestamps,
            deletedBookmarkPaths: working.deletedBookmarkPaths.isEmpty ? nil : working.deletedBookmarkPaths
        )
        return (payload, itemTimestamps)
    }

    private func commitSyncedBaseline(
        payload: iCloudSyncPayload,
        itemUpdatedAt: [UUID: Date],
        tombstones: [UUID: Date],
        bookmarkTombstones: [String: Date]
    ) {
        baselineState.knownSessionIDs = Set(payload.sessions.map(\.id))
        baselineState.knownSnippetIDs = Set(payload.snippets.map(\.id))
        baselineState.knownTriggerIDs = Set(payload.triggers.map(\.id))
        baselineState.knownTunnelIDs = Set(payload.tunnels.map(\.id))
        baselineState.knownBookmarkPaths = Set(payload.bookmarks.filter { !$0.isPreset }.map(\.path))
        baselineState.itemUpdatedAt = itemUpdatedAt
        baselineState.deletedTombstones = tombstones
        baselineState.deletedBookmarkPaths = bookmarkTombstones

        var hashes: [UUID: String] = [:]
        for s in sessionStore.sessions { hashes[s.id] = itemDigest(s) }
        for snip in sessionStore.snippets { hashes[snip.id] = itemDigest(snip) }
        for trig in sessionStore.triggers { hashes[trig.id] = itemDigest(trig) }
        for tun in tunnelManager.tunnels { hashes[tun.id] = itemDigest(tun) }
        baselineState.itemHashes = hashes
        saveBaselineState()
    }

    private func itemDigest<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "" }
        return data.base64EncodedString()
    }

    private func loadBaselineState() {
        guard let stateStorageURL,
              let data = try? Data(contentsOf: stateStorageURL),
              let decoded = try? decoder.decode(SyncBaselineState.self, from: data) else {
            return
        }
        self.baselineState = decoded
    }

    private func saveBaselineState() {
        guard let stateStorageURL,
              let data = try? encoder.encode(baselineState) else {
            return
        }
        try? data.write(to: stateStorageURL, options: .atomic)
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

    /// Resets non-security sync preferences to factory defaults.
    public func resetPreferences() {
        conflictStrategy = .smartMerge
        isAutoSyncEnabled = false
    }
}
