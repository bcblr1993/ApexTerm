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

    public enum SyncStatus: Equatable, Sendable {
        case downloading
        case watching
        case uploading
        case synced
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

        public init(
            id: UUID,
            tabID: UUID?,
            sessionName: String,
            remotePath: String,
            localURL: URL,
            editorName: String,
            status: SyncStatus,
            lastSyncedAt: Date? = nil,
            lastHash: Data = Data()
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
        }

        public var fileName: String {
            let last = (remotePath as NSString).lastPathComponent
            return last.isEmpty ? localURL.lastPathComponent : last
        }
    }

    public typealias DownloadHandler = @Sendable (_ remotePath: String, _ localURL: URL) async throws -> Void
    public typealias UploadHandler = @Sendable (_ localURL: URL, _ remotePath: String) async throws -> Void
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
        let uploadHandler: UploadHandler
        var fileSource: DispatchSourceFileSystemObject?
        var dirSource: DispatchSourceFileSystemObject?
        var pollTask: Task<Void, Never>?
        var debounceTask: Task<Void, Never>?
        var lastFingerprint: FileFingerprint?
        var isUploading = false
        var needsReuploadAfterCurrent = false

        init(
            id: UUID,
            stagingDir: URL,
            localURL: URL,
            remotePath: String,
            editorBundleID: String?,
            editorAppURL: URL?,
            uploadHandler: @escaping UploadHandler
        ) {
            self.id = id
            self.stagingDir = stagingDir
            self.localURL = localURL
            self.remotePath = remotePath
            self.editorBundleID = editorBundleID
            self.editorAppURL = editorAppURL
            self.uploadHandler = uploadHandler
        }

        func cancelWatchers() {
            debounceTask?.cancel()
            debounceTask = nil
            pollTask?.cancel()
            pollTask = nil
            fileSource?.cancel()
            fileSource = nil
            dirSource?.cancel()
            dirSource = nil
        }
    }

    private var runtimes: [UUID: SessionRuntime] = [:]
    private let watcherQueue = DispatchQueue(label: "com.apexterm.sftp.external-edit-watcher", qos: .utility)
    private let stagingRootURL: URL
    private let debounceDuration: Duration
    private let fallbackPollInterval: Duration
    private let defaultDownloadHandler: DownloadHandler?
    private let defaultUploadHandler: UploadHandler?
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
        openHandler: OpenHandler? = nil
    ) {
        self.defaults = defaults
        self.stagingRootURL = stagingRootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherterm-external-edit", isDirectory: true)
        self.debounceDuration = debounceDuration
        self.fallbackPollInterval = fallbackPollInterval
        self.defaultDownloadHandler = downloadHandler
        self.defaultUploadHandler = uploadHandler
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
        upload: UploadHandler? = nil
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
            lastHash: Data()
        )
        activeSessions.append(placeholder)

        do {
            try await resolvedDownload(remotePath, localURL)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                throw ExternalEditError.stagedFileMissing
            }
            let initialData = try Data(contentsOf: localURL)
            let initialHash = Self.sha256(initialData)
            let launchedEditorName = try await openHandler(localURL, effectiveBundleID, editorAppURL)

            // Guard in case stopSession was called while awaiting download/open.
            guard let idx = activeSessions.firstIndex(where: { $0.id == editID }) else {
                try? FileManager.default.removeItem(at: stagingDir)
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
                lastHash: initialHash
            )
            activeSessions[idx] = finalSession

            let runtime = SessionRuntime(
                id: editID,
                stagingDir: stagingDir,
                localURL: localURL,
                remotePath: remotePath,
                editorBundleID: effectiveBundleID,
                editorAppURL: editorAppURL,
                uploadHandler: resolvedUpload
            )
            runtime.lastFingerprint = Self.readFingerprint(at: localURL)
            runtimes[editID] = runtime
            startWatchers(for: runtime)

            return finalSession
        } catch {
            activeSessions.removeAll(where: { $0.id == editID })
            runtimes.removeValue(forKey: editID)?.cancelWatchers()
            try? FileManager.default.removeItem(at: stagingDir)
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
        await performUpload(sessionID: id, force: true)
    }

    /// Stops watching a single edit session and deletes its isolated staging directory.
    public func stopSession(id: UUID) {
        if let runtime = runtimes.removeValue(forKey: id) {
            runtime.cancelWatchers()
            try? FileManager.default.removeItem(at: runtime.stagingDir)
        }
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

    private func performUpload(sessionID: UUID, force: Bool) async {
        guard let runtime = runtimes[sessionID],
              let idx = activeSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        if !force && !autoUploadOnSave {
            return
        }

        if runtime.isUploading {
            runtime.needsReuploadAfterCurrent = true
            return
        }

        guard FileManager.default.fileExists(atPath: runtime.localURL.path),
              let data = try? Data(contentsOf: runtime.localURL) else {
            if force {
                updateSession(id: sessionID) { $0.status = .error("本地临时文件不存在") }
            }
            return
        }

        let newHash = Self.sha256(data)
        if !force && newHash == activeSessions[idx].lastHash {
            return
        }

        runtime.isUploading = true
        runtime.needsReuploadAfterCurrent = false
        updateSession(id: sessionID) { $0.status = .uploading }

        do {
            try await runtime.uploadHandler(runtime.localURL, runtime.remotePath)
            guard runtimes[sessionID] != nil else { return }
            runtime.isUploading = false
            updateSession(id: sessionID) { session in
                session.lastHash = newHash
                session.lastSyncedAt = Date()
                session.status = .synced
            }

            // Re-check if the editor wrote newer bytes while upload was in-flight.
            let latestData = try? Data(contentsOf: runtime.localURL)
            let latestHash = latestData.map(Self.sha256)
            if runtime.needsReuploadAfterCurrent || (latestHash != nil && latestHash != newHash) {
                runtime.needsReuploadAfterCurrent = false
                if autoUploadOnSave {
                    scheduleDebouncedSyncCheck(for: runtime)
                }
            }
        } catch {
            guard runtimes[sessionID] != nil else { return }
            runtime.isUploading = false
            runtime.needsReuploadAfterCurrent = false
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
