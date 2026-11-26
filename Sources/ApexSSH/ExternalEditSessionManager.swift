import Foundation
import AppKit
import CryptoKit
import Darwin
import ApexCore

/// Represents an installed macOS application capable of editing files externally.
public struct ExternalEditorApp: Identifiable, Hashable, Sendable {
    public let bundleID: String
    public let name: String
    public let appURL: URL

    public var id: String { bundleID }

    public init(bundleID: String, name: String, appURL: URL) {
        self.bundleID = bundleID
        self.name = name
        self.appURL = appURL
    }
}

/// Coordinates SFTP external editor staging, atomic-save-safe file watching, SHA-256 diffing,
/// debounced auto-upload, and preference persistence.
@MainActor
public final class ExternalEditSessionManager: ObservableObject {
    public static let shared = ExternalEditSessionManager()

    public struct RemoteFileMetadata: Equatable, Sendable {
        public let mtime: TimeInterval?
        public let size: Int64?
        public let sha256: String?

        public init(mtime: TimeInterval? = nil, size: Int64? = nil, sha256: String? = nil) {
            self.mtime = mtime
            self.size = size
            self.sha256 = sha256
        }

        public func hasChanged(comparedTo baseline: RemoteFileMetadata) -> Bool {
            if let currentHash = sha256?.lowercased(), !currentHash.isEmpty,
               let baseHash = baseline.sha256?.lowercased(), !baseHash.isEmpty {
                return currentHash != baseHash
            }
            if let currentSize = size, let baseSize = baseline.size, currentSize != baseSize {
                return true
            }
            if let currentMtime = mtime, let baseMtime = baseline.mtime, abs(currentMtime - baseMtime) > 0.001 {
                return true
            }
            return false
        }
    }

    public struct RemoteConflictState: Equatable, Sendable {
        public let baselineMetadata: RemoteFileMetadata?
        public let remoteMetadata: RemoteFileMetadata
        public let detectedAt: Date
        public let localHash: Data

        public init(
            baselineMetadata: RemoteFileMetadata?,
            remoteMetadata: RemoteFileMetadata,
            detectedAt: Date = Date(),
            localHash: Data = Data()
        ) {
            self.baselineMetadata = baselineMetadata
            self.remoteMetadata = remoteMetadata
            self.detectedAt = detectedAt
            self.localHash = localHash
        }
    }

    public enum SyncStatus: Equatable, Sendable {
        case downloading
        case watching
        case uploading
        case synced
        case conflict(RemoteConflictState)
        case error(String)

        public var isBusy: Bool {
            switch self {
            case .downloading, .uploading: return true
            default: return false
            }
        }

        public var isError: Bool {
            if case .error = self { return true }
            return false
        }

        public var isConflict: Bool {
            if case .conflict = self { return true }
            return false
        }
    }

    public struct ActiveEditSession: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let tabID: UUID?
        public let sessionName: String
        public let remotePath: String
        public let localURL: URL
        public let editorName: String
        public var status: SyncStatus
        public var lastSyncedAt: Date?
        public var lastHash: Data
        public var baselineMetadata: RemoteFileMetadata?

        public init(
            id: UUID,
            tabID: UUID?,
            sessionName: String,
            remotePath: String,
            localURL: URL,
            editorName: String,
            status: SyncStatus,
            lastSyncedAt: Date? = nil,
            lastHash: Data = Data(),
            baselineMetadata: RemoteFileMetadata? = nil
        ) {
            self.id = id
            self.tabID = tabID
            self.sessionName = sessionName
            self.remotePath = remotePath
            self.localURL = localURL
            self.editorName = editorName
            self.status = status
            self.lastSyncedAt = lastSyncedAt
            self.lastHash = lastHash
            self.baselineMetadata = baselineMetadata
        }

        public var fileName: String {
            let last = (remotePath as NSString).lastPathComponent
            return last.isEmpty ? localURL.lastPathComponent : last
        }
    }

    public typealias DownloadHandler = @Sendable (_ remotePath: String, _ localURL: URL) async throws -> Void
    public typealias UploadHandler = @Sendable (_ localURL: URL, _ remotePath: String) async throws -> Void
    public typealias MetadataProbeHandler = @Sendable (_ remotePath: String) async throws -> RemoteFileMetadata?
    public typealias OpenHandler = @MainActor (_ localURL: URL, _ editorBundleID: String?, _ editorAppURL: URL?) async throws -> String

    // MARK: - Preferences

    private let defaults: UserDefaults
    private let preferredEditorKey = "externalEdit.preferredEditorBundleID"
    private let autoUploadKey = "externalEdit.autoUploadOnSave"
    private var suppressPreferenceSave = false

    @Published public var preferredEditorBundleID: String {
        didSet {
            guard !suppressPreferenceSave else { return }
            defaults.set(preferredEditorBundleID, forKey: preferredEditorKey)
        }
    }

    @Published public var autoUploadOnSave: Bool {
        didSet {
            guard !suppressPreferenceSave else { return }
            defaults.set(autoUploadOnSave, forKey: autoUploadKey)
        }
    }

    public func resetPreferences() {
        suppressPreferenceSave = true
        defer { suppressPreferenceSave = false }
        defaults.removeObject(forKey: preferredEditorKey)
        defaults.removeObject(forKey: autoUploadKey)
        preferredEditorBundleID = ""
        autoUploadOnSave = true
    }

    // MARK: - Active Sessions & Runtime

    @Published public private(set) var activeSessions: [ActiveEditSession] = []

    private struct FileFingerprint: Equatable {
        let inode: UInt64
        let modificationSeconds: TimeInterval
        let size: Int64
    }

    private final class SessionRuntime {
        let id: UUID
        let stagingDir: URL
        let localURL: URL
        let remotePath: String
        let editorBundleID: String?
        let editorAppURL: URL?
        let downloadHandler: DownloadHandler
        let uploadHandler: UploadHandler
        let metadataProbe: MetadataProbeHandler?
        var baselineMetadata: RemoteFileMetadata?
        var fileSource: DispatchSourceFileSystemObject?
        var dirSource: DispatchSourceFileSystemObject?
        var pollTask: Task<Void, Never>?
        var debounceTask: Task<Void, Never>?
        var uploadTask: Task<Void, Error>?
        var lastFingerprint: FileFingerprint?
        var isUploading = false
        var needsReuploadAfterCurrent = false
        var pendingForcedUpload = false

        init(
            id: UUID,
            stagingDir: URL,
            localURL: URL,
            remotePath: String,
            editorBundleID: String?,
            editorAppURL: URL?,
            downloadHandler: @escaping DownloadHandler,
            uploadHandler: @escaping UploadHandler,
            metadataProbe: MetadataProbeHandler?,
            baselineMetadata: RemoteFileMetadata?
        ) {
            self.id = id
            self.stagingDir = stagingDir
            self.localURL = localURL
            self.remotePath = remotePath
            self.editorBundleID = editorBundleID
            self.editorAppURL = editorAppURL
            self.downloadHandler = downloadHandler
            self.uploadHandler = uploadHandler
            self.metadataProbe = metadataProbe
            self.baselineMetadata = baselineMetadata
        }

        func cancelAllTasks() {
            debounceTask?.cancel()
            debounceTask = nil
            pollTask?.cancel()
            pollTask = nil
            uploadTask?.cancel()
            uploadTask = nil
            fileSource?.cancel()
            fileSource = nil
            dirSource?.cancel()
            dirSource = nil
        }
    }

    private static let activeStagingLock = NSLock()
    nonisolated(unsafe) private static var activeStagingIDs: [String: Int] = [:]

    private static func registerActiveStagingID(_ id: String) {
        activeStagingLock.withLock {
            activeStagingIDs[id, default: 0] += 1
        }
    }

    private static func unregisterActiveStagingID(_ id: String) {
        activeStagingLock.withLock {
            guard let count = activeStagingIDs[id] else { return }
            if count <= 1 {
                activeStagingIDs.removeValue(forKey: id)
            } else {
                activeStagingIDs[id] = count - 1
            }
        }
    }

    private static func isStagingIDActive(_ id: String) -> Bool {
        activeStagingLock.withLock {
            (activeStagingIDs[id] ?? 0) > 0
        }
    }

    private var runtimes: [UUID: SessionRuntime] = [:]
    private let watcherQueue = DispatchQueue(label: "com.apexterm.sftp.external-edit-watcher", qos: .utility)
    private let stagingRootURL: URL
    private let debounceDuration: Duration
    private let fallbackPollInterval: Duration
    private let defaultDownloadHandler: DownloadHandler?
    private let defaultUploadHandler: UploadHandler?
    private let defaultMetadataProbeHandler: MetadataProbeHandler?
    private let openHandler: OpenHandler
    nonisolated(unsafe) private var resetObserver: NSObjectProtocol?

    deinit {
        if let resetObserver {
            NotificationCenter.default.removeObserver(resetObserver)
        }
    }

    public init(
        defaults: UserDefaults = .standard,
        stagingRootURL: URL? = nil,
        debounceDuration: Duration = .milliseconds(250),
        fallbackPollInterval: Duration = .milliseconds(200),
        downloadHandler: DownloadHandler? = nil,
        uploadHandler: UploadHandler? = nil,
        metadataProbeHandler: MetadataProbeHandler? = nil,
        openHandler: OpenHandler? = nil
    ) {
        self.defaults = defaults
        self.stagingRootURL = stagingRootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherterm-external-edit", isDirectory: true)
        self.debounceDuration = debounceDuration
        self.fallbackPollInterval = fallbackPollInterval
        self.defaultDownloadHandler = downloadHandler
        self.defaultUploadHandler = uploadHandler
        self.defaultMetadataProbeHandler = metadataProbeHandler
        self.openHandler = openHandler ?? { localURL, editorBundleID, editorAppURL in
            try await Self.defaultOpenInExternalApp(
                localURL: localURL,
                editorBundleID: editorBundleID,
                editorAppURL: editorAppURL
            )
        }

        self.suppressPreferenceSave = true
        self.preferredEditorBundleID = defaults.string(forKey: preferredEditorKey) ?? ""
        if let savedAuto = defaults.object(forKey: autoUploadKey) as? Bool {
            self.autoUploadOnSave = savedAuto
        } else {
            self.autoUploadOnSave = true
        }
        self.suppressPreferenceSave = false

        if defaults === UserDefaults.standard {
            self.resetObserver = NotificationCenter.default.addObserver(
                forName: AppSettings.didResetToDefaultsNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.resetPreferences()
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.resetPreferences()
                    }
                }
            }
        }

        _ = cleanupStaleStagingDirectories()
    }

    /// Removes orphaned staging directories inside `stagingRootURL` that do not belong to any live edit session.
    @discardableResult
    public func cleanupStaleStagingDirectories(olderThan maxAgeSeconds: TimeInterval = 0, now: Date = Date()) -> Int {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: stagingRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: []
        ) else {
            return 0
        }
        let ownActiveIDs = Set(runtimes.keys.map(\.uuidString) + activeSessions.map(\.id.uuidString))
        var removed = 0
        for childURL in children {
            let folderName = childURL.lastPathComponent
            if ownActiveIDs.contains(folderName) || Self.isStagingIDActive(folderName) {
                continue
            }
            if maxAgeSeconds > 0 {
                let values = try? childURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                let timestamp = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
                guard now.timeIntervalSince(timestamp) >= maxAgeSeconds else { continue }
            }
            if (try? FileManager.default.removeItem(at: childURL)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Queries

    public func sessions(forTabID tabID: UUID?) -> [ActiveEditSession] {
        activeSessions.filter { $0.tabID == tabID }
    }

    public func session(id: UUID) -> ActiveEditSession? {
        activeSessions.first(where: { $0.id == id })
    }

    // MARK: - Lifecycle Actions

    /// Downloads `remotePath` to an isolated staging directory, opens it in an external editor,
    /// and starts watching for saves (including atomic rename-saves) to sync back to the server.
    @discardableResult
    public func openInExternalEditor(
        session: (any SSHSessionProtocol)? = nil,
        tabID: UUID? = nil,
        sessionName: String = "",
        remotePath: String,
        editorBundleID: String? = nil,
        editorAppURL: URL? = nil,
        download: DownloadHandler? = nil,
        upload: UploadHandler? = nil,
        metadataProbe: MetadataProbeHandler? = nil
    ) async throws -> ActiveEditSession {
        let resolvedDownload: DownloadHandler
        if let download {
            resolvedDownload = download
        } else if let defaultDownloadHandler {
            resolvedDownload = defaultDownloadHandler
        } else if let session {
            resolvedDownload = { remote, local in
                try await session.downloadFile(remotePath: remote, localURL: local, progress: { _ in })
            }
        } else {
            throw ExternalEditError.missingSession
        }

        let resolvedUpload: UploadHandler
        if let upload {
            resolvedUpload = upload
        } else if let defaultUploadHandler {
            resolvedUpload = defaultUploadHandler
        } else if let session {
            resolvedUpload = { local, remote in
                try await session.uploadFile(localURL: local, remotePath: remote, progress: { _ in })
            }
        } else {
            throw ExternalEditError.missingSession
        }

        let resolvedProbe: MetadataProbeHandler?
        if let metadataProbe {
            resolvedProbe = metadataProbe
        } else if let defaultMetadataProbeHandler {
            resolvedProbe = defaultMetadataProbeHandler
        } else if let session {
            resolvedProbe = { path in
                await Self.defaultRemoteMetadataProbe(session: session, remotePath: path)
            }
        } else {
            resolvedProbe = nil
        }

        // Replace any existing watcher for the exact same tab + remotePath to prevent duplicate sync races.
        for existing in activeSessions where existing.tabID == tabID && existing.remotePath == remotePath {
            stopSession(id: existing.id)
        }

        let editID = UUID()
        let stagingDir = stagingRootURL.appendingPathComponent(editID.uuidString, isDirectory: true)
        let localURL = stagingDir.appendingPathComponent(Self.safeFilename(from: remotePath), isDirectory: false)

        let effectiveBundleID: String?
        if let editorBundleID {
            effectiveBundleID = editorBundleID.isEmpty ? nil : editorBundleID
        } else {
            effectiveBundleID = preferredEditorBundleID.isEmpty ? nil : preferredEditorBundleID
        }

        let initialEditorName = Self.resolveEditorName(
            localURL: localURL,
            editorBundleID: effectiveBundleID,
            editorAppURL: editorAppURL
        )

        Self.registerActiveStagingID(editID.uuidString)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let placeholder = ActiveEditSession(
            id: editID,
            tabID: tabID,
            sessionName: sessionName,
            remotePath: remotePath,
            localURL: localURL,
            editorName: initialEditorName,
            status: .downloading,
            lastSyncedAt: nil,
            lastHash: Data(),
            baselineMetadata: nil
        )
        activeSessions.append(placeholder)

        do {
            try await resolvedDownload(remotePath, localURL)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                throw ExternalEditError.stagedFileMissing
            }
            let initialHash = try await Self.streamingSHA256(at: localURL)
            let baselineMetadata = try? await resolvedProbe?(remotePath)
            let launchedEditorName = try await openHandler(localURL, effectiveBundleID, editorAppURL)

            // Guard in case stopSession was called while awaiting download/open.
            guard let idx = activeSessions.firstIndex(where: { $0.id == editID }) else {
                try? FileManager.default.removeItem(at: stagingDir)
                Self.unregisterActiveStagingID(editID.uuidString)
                throw CancellationError()
            }

            let finalSession = ActiveEditSession(
                id: editID,
                tabID: tabID,
                sessionName: sessionName,
                remotePath: remotePath,
                localURL: localURL,
                editorName: launchedEditorName.isEmpty ? initialEditorName : launchedEditorName,
                status: .watching,
                lastSyncedAt: nil,
                lastHash: initialHash,
                baselineMetadata: baselineMetadata
            )
            activeSessions[idx] = finalSession

            let runtime = SessionRuntime(
                id: editID,
                stagingDir: stagingDir,
                localURL: localURL,
                remotePath: remotePath,
                editorBundleID: effectiveBundleID,
                editorAppURL: editorAppURL,
                downloadHandler: resolvedDownload,
                uploadHandler: resolvedUpload,
                metadataProbe: resolvedProbe,
                baselineMetadata: baselineMetadata
            )
            runtime.lastFingerprint = Self.readFingerprint(at: localURL)
            runtimes[editID] = runtime
            startWatchers(for: runtime)

            return finalSession
        } catch {
            activeSessions.removeAll(where: { $0.id == editID })
            runtimes.removeValue(forKey: editID)?.cancelAllTasks()
            try? FileManager.default.removeItem(at: stagingDir)
            Self.unregisterActiveStagingID(editID.uuidString)
            throw error
        }
    }

    /// Re-opens the local staged file in its associated external editor.
    public func reopenInEditor(id: UUID) async throws {
        guard let runtime = runtimes[id] else { return }
        _ = try await openHandler(runtime.localURL, runtime.editorBundleID, runtime.editorAppURL)
    }

    /// Manually triggers an upload of the staged local file regardless of `autoUploadOnSave` or hash equality.
    public func triggerManualUpload(id: UUID) async {
        await performUpload(sessionID: id, force: true, bypassConflictCheck: true)
    }

    /// Resolves a `.conflict` session by forcing local contents to overwrite the remote file.
    public func resolveConflictForceOverwrite(id: UUID) async {
        await performUpload(sessionID: id, force: true, bypassConflictCheck: true)
    }

    /// Resolves a `.conflict` session by discarding local conflict state and re-downloading the latest remote version.
    public func resolveConflictReloadRemote(id: UUID) async {
        guard let runtime = runtimes[id] else { return }
        runtime.debounceTask?.cancel()
        runtime.debounceTask = nil
        runtime.uploadTask?.cancel()
        runtime.uploadTask = nil
        runtime.isUploading = false
        runtime.needsReuploadAfterCurrent = false
        runtime.pendingForcedUpload = false

        updateSession(id: id) { $0.status = .downloading }

        let reloadTempURL = runtime.stagingDir.appendingPathComponent(".reload-\(UUID().uuidString)")
        do {
            try await runtime.downloadHandler(runtime.remotePath, reloadTempURL)
            guard runtimes[id] != nil else {
                try? FileManager.default.removeItem(at: reloadTempURL)
                return
            }
            guard FileManager.default.fileExists(atPath: reloadTempURL.path) else {
                throw ExternalEditError.stagedFileMissing
            }
            if FileManager.default.fileExists(atPath: runtime.localURL.path) {
                _ = try FileManager.default.replaceItemAt(runtime.localURL, withItemAt: reloadTempURL)
            } else {
                try FileManager.default.moveItem(at: reloadTempURL, to: runtime.localURL)
            }
            let newHash = try await Self.streamingSHA256(at: runtime.localURL)
            let newMetadata = try? await runtime.metadataProbe?(runtime.remotePath)
            guard let liveRuntime = runtimes[id] else { return }
            liveRuntime.lastFingerprint = Self.readFingerprint(at: liveRuntime.localURL)
            liveRuntime.baselineMetadata = newMetadata
            armFileSource(for: liveRuntime)
            updateSession(id: id) { session in
                session.lastHash = newHash
                session.baselineMetadata = newMetadata
                session.status = .watching
            }
        } catch {
            try? FileManager.default.removeItem(at: reloadTempURL)
            guard runtimes[id] != nil else { return }
            if error is CancellationError || Task.isCancelled { return }
            updateSession(id: id) { $0.status = .error(error.localizedDescription) }
        }
    }

    /// Stops watching a single edit session and deletes its isolated staging directory.
    public func stopSession(id: UUID) {
        if let runtime = runtimes.removeValue(forKey: id) {
            runtime.cancelAllTasks()
            try? FileManager.default.removeItem(at: runtime.stagingDir)
        }
        Self.unregisterActiveStagingID(id.uuidString)
        activeSessions.removeAll(where: { $0.id == id })
    }

    /// Stops all edit sessions belonging to `tabID` and cleans up their temp directories.
    public func stopAll(forTabID tabID: UUID?) {
        let ids = activeSessions.filter { $0.tabID == tabID }.map(\.id)
        for id in ids {
            stopSession(id: id)
        }
    }

    /// Stops every active edit session across all tabs and removes all temp directories.
    public func stopAllSessions() {
        let ids = Array(Set(activeSessions.map(\.id) + Array(runtimes.keys)))
        for id in ids {
            stopSession(id: id)
        }
    }

    // MARK: - Watching & Debounced Sync

    private func startWatchers(for runtime: SessionRuntime) {
        armFileSource(for: runtime)
        armDirectorySource(for: runtime)

        let id = runtime.id
        let pollInterval = fallbackPollInterval
        runtime.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { break }
                self.pollFileState(sessionID: id)
            }
        }
    }

    private func armFileSource(for runtime: SessionRuntime) {
        runtime.fileSource?.cancel()
        runtime.fileSource = Self.createFileSource(
            path: runtime.localURL.path,
            queue: watcherQueue,
            sessionID: runtime.id,
            manager: self
        )
    }

    private func armDirectorySource(for runtime: SessionRuntime) {
        runtime.dirSource?.cancel()
        runtime.dirSource = Self.createDirectorySource(
            path: runtime.stagingDir.path,
            queue: watcherQueue,
            sessionID: runtime.id,
            manager: self
        )
    }

    nonisolated private static func createFileSource(
        path: String,
        queue: DispatchQueue,
        sessionID: UUID,
        manager: ExternalEditSessionManager
    ) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: queue
        )
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.setEventHandler { [weak manager, weak source] in
            let flags = source?.data ?? []
            let needsRearm = flags.contains(.rename) || flags.contains(.delete) || flags.contains(.revoke)
            Task { @MainActor [weak manager] in
                manager?.handleFileSourceEvent(sessionID: sessionID, needsRearm: needsRearm)
            }
        }
        source.resume()
        return source
    }

    nonisolated private static func createDirectorySource(
        path: String,
        queue: DispatchQueue,
        sessionID: UUID,
        manager: ExternalEditSessionManager
    ) -> DispatchSourceFileSystemObject? {
        let dirFD = Darwin.open(path, O_EVTONLY)
        guard dirFD >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setCancelHandler {
            Darwin.close(dirFD)
        }
        source.setEventHandler { [weak manager] in
            Task { @MainActor [weak manager] in
                manager?.handleDirectoryEvent(sessionID: sessionID)
            }
        }
        source.resume()
        return source
    }

    private func handleFileSourceEvent(sessionID: UUID, needsRearm: Bool) {
        guard let runtime = runtimes[sessionID] else { return }
        if needsRearm {
            armFileSource(for: runtime)
        }
        if let fp = Self.readFingerprint(at: runtime.localURL) {
            runtime.lastFingerprint = fp
        }
        scheduleDebouncedSyncCheck(for: runtime)
    }

    private func handleDirectoryEvent(sessionID: UUID) {
        guard let runtime = runtimes[sessionID] else { return }
        let currentFP = Self.readFingerprint(at: runtime.localURL)
        if let currentFP {
            if runtime.fileSource == nil || currentFP.inode != runtime.lastFingerprint?.inode {
                armFileSource(for: runtime)
            }
            if currentFP != runtime.lastFingerprint {
                runtime.lastFingerprint = currentFP
                scheduleDebouncedSyncCheck(for: runtime)
            }
        }
    }

    private func pollFileState(sessionID: UUID) {
        guard let runtime = runtimes[sessionID] else { return }
        guard let currentFP = Self.readFingerprint(at: runtime.localURL) else { return }
        if runtime.fileSource == nil || currentFP.inode != runtime.lastFingerprint?.inode {
            armFileSource(for: runtime)
        }
        if currentFP != runtime.lastFingerprint {
            runtime.lastFingerprint = currentFP
            scheduleDebouncedSyncCheck(for: runtime)
        }
    }

    private func scheduleDebouncedSyncCheck(for runtime: SessionRuntime) {
        runtime.debounceTask?.cancel()
        let sessionID = runtime.id
        let delay = debounceDuration
        runtime.debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.performUpload(sessionID: sessionID, force: false)
        }
    }

    private func performUpload(sessionID: UUID, force: Bool, bypassConflictCheck: Bool = false) async {
        guard let runtime = runtimes[sessionID],
              let idx = activeSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        if !force && !autoUploadOnSave {
            return
        }

        if !force && !bypassConflictCheck && activeSessions[idx].status.isConflict {
            return
        }

        if runtime.isUploading {
            if force {
                runtime.pendingForcedUpload = true
            } else {
                runtime.needsReuploadAfterCurrent = true
            }
            return
        }

        guard FileManager.default.fileExists(atPath: runtime.localURL.path),
              let newHash = try? await Self.streamingSHA256(at: runtime.localURL) else {
            if force {
                updateSession(id: sessionID) { $0.status = .error("本地临时文件不存在") }
            }
            return
        }

        guard let liveRuntime = runtimes[sessionID],
              let liveIdx = activeSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        if !force && newHash == activeSessions[liveIdx].lastHash {
            return
        }

        // Before every auto-upload, check remote metadata if a probe is available.
        if !force && !bypassConflictCheck,
           let probe = liveRuntime.metadataProbe,
           let baseline = liveRuntime.baselineMetadata,
           let remoteMeta = try? await probe(liveRuntime.remotePath) {
            guard runtimes[sessionID] != nil else { return }
            if remoteMeta.hasChanged(comparedTo: baseline) {
                let conflict = RemoteConflictState(
                    baselineMetadata: baseline,
                    remoteMetadata: remoteMeta,
                    detectedAt: Date(),
                    localHash: newHash
                )
                updateSession(id: sessionID) { $0.status = .conflict(conflict) }
                return
            }
        }

        guard let activeRuntime = runtimes[sessionID] else { return }
        activeRuntime.isUploading = true
        activeRuntime.needsReuploadAfterCurrent = false
        activeRuntime.pendingForcedUpload = false
        updateSession(id: sessionID) { $0.status = .uploading }

        let localURL = activeRuntime.localURL
        let remotePath = activeRuntime.remotePath
        let uploadHandler = activeRuntime.uploadHandler
        let uploadTask = Task<Void, Error> {
            try await uploadHandler(localURL, remotePath)
        }
        activeRuntime.uploadTask = uploadTask

        do {
            try await uploadTask.value
            guard let postRuntime = runtimes[sessionID], !Task.isCancelled else { return }
            postRuntime.uploadTask = nil
            postRuntime.isUploading = false

            var refreshedMetadata = postRuntime.baselineMetadata
            if let probe = postRuntime.metadataProbe {
                refreshedMetadata = try? await probe(postRuntime.remotePath)
            }
            guard let postProbeRuntime = runtimes[sessionID], !Task.isCancelled else { return }
            postProbeRuntime.baselineMetadata = refreshedMetadata

            updateSession(id: sessionID) { session in
                session.lastHash = newHash
                session.lastSyncedAt = Date()
                session.status = .synced
                session.baselineMetadata = refreshedMetadata
            }

            // Re-check if the user triggered a forced upload or the editor wrote newer bytes while upload was in-flight.
            let latestHash = try? await Self.streamingSHA256(at: postProbeRuntime.localURL)
            if postProbeRuntime.pendingForcedUpload {
                postProbeRuntime.pendingForcedUpload = false
                postProbeRuntime.needsReuploadAfterCurrent = false
                await performUpload(sessionID: sessionID, force: true, bypassConflictCheck: true)
            } else if postProbeRuntime.needsReuploadAfterCurrent || (latestHash != nil && latestHash != newHash) {
                postProbeRuntime.needsReuploadAfterCurrent = false
                if autoUploadOnSave {
                    scheduleDebouncedSyncCheck(for: postProbeRuntime)
                }
            }
        } catch {
            guard let failedRuntime = runtimes[sessionID] else { return }
            failedRuntime.uploadTask = nil
            failedRuntime.isUploading = false
            if error is CancellationError || Task.isCancelled {
                return
            }
            failedRuntime.needsReuploadAfterCurrent = false
            failedRuntime.pendingForcedUpload = false
            updateSession(id: sessionID) { session in
                session.status = .error(error.localizedDescription)
            }
        }
    }

    private func updateSession(id: UUID, mutate: (inout ActiveEditSession) -> Void) {
        guard let idx = activeSessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&activeSessions[idx])
    }

    // MARK: - Helpers & Editor Discovery

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Computes SHA-256 over a file in fixed-size chunks via `FileHandle` without loading the entire file into RAM.
    public static func streamingSHA256(at url: URL, chunkSize: Int = 256 * 1024) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try sha256FileSync(at: url, chunkSize: chunkSize)
        }.value
    }

    nonisolated public static func sha256FileSync(at url: URL, chunkSize: Int = 256 * 1024) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let effectiveChunkSize = max(4096, chunkSize)
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: effectiveChunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    public static func defaultRemoteMetadataProbe(session: any SSHSessionProtocol, remotePath: String) async -> RemoteFileMetadata? {
        guard session.isConnected else { return nil }
        let quoted = SFTPRemoteOperations.shellQuotedRemotePath(remotePath)
        let cmd = "stat -c '%Y %s' \(quoted) 2>/dev/null || stat -f '%m %z' \(quoted) 2>/dev/null"
        guard let result = try? await session.executeCommandWithResult(cmd),
              result.exitCode == 0 else {
            return nil
        }
        return parseRemoteStatOutput(result.stdout)
    }

    nonisolated public static func parseRemoteStatOutput(_ raw: String) -> RemoteFileMetadata? {
        for rawLine in raw.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2,
                  let mtime = TimeInterval(parts[0]),
                  let size = Int64(parts[1]),
                  mtime >= 0,
                  size >= 0 else {
                continue
            }
            return RemoteFileMetadata(mtime: mtime, size: size, sha256: nil)
        }
        return nil
    }

    public static func safeFilename(from remotePath: String) -> String {
        let raw = (remotePath as NSString).lastPathComponent
        let sanitized = String(raw.map { ch -> Character in
            (ch == "/" || ch == "\\" || ch == "\0" || ch == ":") ? "_" : ch
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            return "untitled"
        }
        return sanitized
    }

    private static func readFingerprint(at url: URL) -> FileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modSec = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return FileFingerprint(inode: inode, modificationSeconds: modSec, size: size)
    }

    private static let knownEditorBundleIDs: [(bundleID: String, fallbackName: String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.microsoft.VSCodeInsiders", "Visual Studio Code - Insiders"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.exafunction.windsurf", "Windsurf"),
        ("dev.zed.Zed", "Zed"),
        ("com.sublimetext.4", "Sublime Text"),
        ("com.sublimetext.3", "Sublime Text"),
        ("com.panic.Nova", "Nova"),
        ("com.barebones.bbedit", "BBEdit"),
        ("com.coteditor.CotEditor", "CotEditor"),
        ("com.apple.dt.Xcode", "Xcode"),
        ("org.vim.MacVim", "MacVim"),
        ("com.apple.TextEdit", "TextEdit")
    ]

    /// Detects common code/text editors installed on the user's Mac.
    public static func installedEditors() -> [ExternalEditorApp] {
        var seenBundleIDs = Set<String>()
        var result: [ExternalEditorApp] = []
        for entry in knownEditorBundleIDs {
            guard !seenBundleIDs.contains(entry.bundleID) else { continue }
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) {
                seenBundleIDs.insert(entry.bundleID)
                let name = applicationDisplayName(at: appURL) ?? entry.fallbackName
                result.append(ExternalEditorApp(bundleID: entry.bundleID, name: name, appURL: appURL))
            }
        }
        return result
    }

    public static func displayName(forBundleID bundleID: String) -> String {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "系统默认应用" }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed),
           let name = applicationDisplayName(at: appURL) {
            return name
        }
        if let known = knownEditorBundleIDs.first(where: { $0.bundleID == trimmed }) {
            return known.fallbackName
        }
        return trimmed
    }

    public static func applicationDisplayName(at appURL: URL) -> String? {
        if let bundle = Bundle(url: appURL) {
            if let display = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String, !display.isEmpty {
                return display
            }
            if let display = bundle.infoDictionary?["CFBundleDisplayName"] as? String, !display.isEmpty {
                return display
            }
            if let name = bundle.localizedInfoDictionary?["CFBundleName"] as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.infoDictionary?["CFBundleName"] as? String, !name.isEmpty {
                return name
            }
        }
        let base = appURL.deletingPathExtension().lastPathComponent
        return base.isEmpty ? nil : base
    }

    private static func resolveEditorName(localURL: URL, editorBundleID: String?, editorAppURL: URL?) -> String {
        if let editorAppURL, let name = applicationDisplayName(at: editorAppURL) {
            return name
        }
        if let editorBundleID, !editorBundleID.isEmpty {
            return displayName(forBundleID: editorBundleID)
        }
        if let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: localURL),
           let name = applicationDisplayName(at: defaultURL) {
            return name
        }
        return "系统默认应用"
    }

    private static func defaultOpenInExternalApp(
        localURL: URL,
        editorBundleID: String?,
        editorAppURL: URL?
    ) async throws -> String {
        let resolvedAppURL: URL?
        if let editorAppURL {
            resolvedAppURL = editorAppURL
        } else if let editorBundleID, !editorBundleID.isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editorBundleID) else {
                throw ExternalEditError.editorNotFound(editorBundleID)
            }
            resolvedAppURL = url
        } else {
            resolvedAppURL = NSWorkspace.shared.urlForApplication(toOpen: localURL)
        }

        if let appURL = resolvedAppURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try await NSWorkspace.shared.open([localURL], withApplicationAt: appURL, configuration: config)
            return applicationDisplayName(at: appURL) ?? resolveEditorName(
                localURL: localURL,
                editorBundleID: editorBundleID,
                editorAppURL: appURL
            )
        }

        guard NSWorkspace.shared.open(localURL) else {
            throw ExternalEditError.launchFailed(localURL.lastPathComponent)
        }
        return "系统默认应用"
    }
}

public enum ExternalEditError: LocalizedError, Sendable {
    case missingSession
    case stagedFileMissing
    case editorNotFound(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSession:
            return "无可用的 SSH/SFTP 会话"
        case .stagedFileMissing:
            return "本地临时文件创建失败"
        case .editorNotFound(let id):
            return "未找到指定的外部编辑器 (\(id))"
        case .launchFailed(let name):
            return "无法在系统默认应用中打开「\(name)」"
        }
    }
}
