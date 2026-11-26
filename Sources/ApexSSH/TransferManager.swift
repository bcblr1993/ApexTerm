import Foundation
import SwiftUI
import ApexCore

/// High-performance non-blocking SFTP Transfer Manager
/// Manages upload/download task queue, throttling UI updates for 120Hz smoothness
@MainActor
public final class TransferManager: ObservableObject {
    public static let shared = TransferManager()
    
    @Published public private(set) var tasks: [TransferTask] = []
    public var maxConcurrentTransfers: Int?
    /// Upper bound on retained completed/failed/cancelled task records to prevent unbounded memory growth.
    public var maxCompletedHistory: Int = 200
    
    private final class RetryContext {
        weak var session: SSHSessionProtocol?
        let tabID: UUID?
        let onCompleted: (@Sendable () -> Void)?
        let onResult: (@Sendable (Result<String, Error>) -> Void)?
        let onDownloadResult: (@Sendable (Result<URL, Error>) -> Void)?
        private var accessLease: FileAccessLease?

        init(
            session: SSHSessionProtocol?,
            tabID: UUID?,
            onCompleted: (@Sendable () -> Void)?,
            onResult: (@Sendable (Result<String, Error>) -> Void)?,
            onDownloadResult: (@Sendable (Result<URL, Error>) -> Void)?,
            accessLease: FileAccessLease? = nil
        ) {
            self.session = session
            self.tabID = tabID
            self.onCompleted = onCompleted
            self.onResult = onResult
            self.onDownloadResult = onDownloadResult
            self.accessLease = accessLease
        }

        func takeAccessLease() -> FileAccessLease? {
            let lease = accessLease
            accessLease = nil
            return lease
        }

        func closeAccessLease() {
            accessLease?.close()
            accessLease = nil
        }

        deinit {
            closeAccessLease()
        }
    }

    private var activeTaskHandles: [UUID: Task<Void, Never>] = [:]
    private var externalCancelHandlers: [UUID: @Sendable () -> Void] = [:]
    private var retryContexts: [UUID: RetryContext] = [:]
    private var runningTransferCount: Int = 0
    private var slotWaiters: [(id: UUID, maxConcurrent: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var lastSpeedSampleTime: [UUID: Date] = [:]
    private var lastSampledBytes: [UUID: Int64] = [:]
    
    private let distributionChannel: DistributionChannel
    private let fileAccessStore: FileAccessStore

    public init(distributionChannel: DistributionChannel = .current,
                fileAccessStore: FileAccessStore = .shared,
                maxConcurrentTransfers: Int? = nil,
                maxCompletedHistory: Int = 200) {
        self.distributionChannel = distributionChannel
        self.fileAccessStore = fileAccessStore
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.maxCompletedHistory = max(1, maxCompletedHistory)
    }

    /// Prunes oldest terminal (`.completed`, `.failed`, `.cancelled`) tasks when count exceeds `maxCompletedHistory`,
    /// preserving all `.queued` and `.transferring` tasks.
    public func pruneCompletedHistoryIfNeeded() {
        let limit = max(1, maxCompletedHistory)
        let terminalIndices = tasks.indices.filter { tasks[$0].status.isTerminal }
        guard terminalIndices.count > limit else { return }
        // Since new tasks are inserted at index 0, the oldest terminal tasks sit at the end of `terminalIndices`.
        let indicesToRemove = terminalIndices.suffix(terminalIndices.count - limit)
        let idsToRemove = Set(indicesToRemove.map { tasks[$0].id })
        for id in idsToRemove {
            activeTaskHandles.removeValue(forKey: id)
            externalCancelHandlers.removeValue(forKey: id)
            retryContexts.removeValue(forKey: id)?.closeAccessLease()
            lastSpeedSampleTime.removeValue(forKey: id)
            lastSampledBytes.removeValue(forKey: id)
        }
        tasks.removeAll { idsToRemove.contains($0.id) }
    }

    private func effectiveMaxConcurrent(for session: SSHSessionProtocol) -> Int {
        if let explicit = maxConcurrentTransfers {
            return max(1, explicit)
        }
        if session is MockSSHSession {
            return Int.max
        }
        return max(1, AppSettings.shared.maxConcurrentTransfers)
    }

    private func acquireTransferSlot(taskId: UUID, maxConcurrent: Int) async -> Bool {
        if Task.isCancelled { return false }
        if let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].status == .cancelled {
            return false
        }
        if runningTransferCount < maxConcurrent {
            runningTransferCount += 1
            return true
        }
        return await withCheckedContinuation { continuation in
            slotWaiters.append((id: taskId, maxConcurrent: maxConcurrent, continuation: continuation))
        }
    }

    private func releaseTransferSlot() {
        runningTransferCount = max(0, runningTransferCount - 1)
        var index = 0
        while index < slotWaiters.count {
            let candidate = slotWaiters[index]
            if runningTransferCount < candidate.maxConcurrent {
                slotWaiters.remove(at: index)
                runningTransferCount += 1
                candidate.continuation.resume(returning: true)
            } else {
                index += 1
            }
        }
    }
    
    public var activeCount: Int {
        tasks.filter { $0.status == .transferring || $0.status == .queued }.count
    }
    
    public var totalSpeedBytesPerSec: Double {
        tasks.filter { $0.status == .transferring }.reduce(0) { $0 + $1.speedBytesPerSec }
    }
    
    public var formattedTotalSpeed: String {
        let speed = totalSpeedBytesPerSec
        if speed >= 1024 * 1024 {
            return String(format: "%.1f MB/s", speed / (1024 * 1024))
        } else if speed >= 1024 {
            return String(format: "%.0f KB/s", speed / 1024)
        } else {
            return String(format: "%.0f B/s", speed)
        }
    }
    
    /// Enqueue an upload task
    @discardableResult
    public func enqueueUpload(
        session: SSHSessionProtocol,
        localURL: URL,
        remotePath: String,
        tabID: UUID? = nil,
        onCompleted: (@Sendable () -> Void)? = nil,
        onResult: (@Sendable (Result<String, Error>) -> Void)? = nil
    ) -> UUID {
        enqueueUploadInternal(
            session: session,
            localURL: localURL,
            remotePath: remotePath,
            tabID: tabID,
            retainedLease: nil,
            onCompleted: onCompleted,
            onResult: onResult
        )
    }

    @discardableResult
    private func enqueueUploadInternal(
        session: SSHSessionProtocol,
        localURL: URL,
        remotePath: String,
        tabID: UUID?,
        retainedLease: FileAccessLease?,
        onCompleted: (@Sendable () -> Void)?,
        onResult: (@Sendable (Result<String, Error>) -> Void)?
    ) -> UUID {
        // Acquire while the panel/Finder URL is still live, before scheduling the task.
        let accessResult = Result<FileAccessLease?, Error> {
            if let retainedLease {
                return retainedLease
            }
            return distributionChannel == .appStore ? try fileAccessStore.acquire(localURL) : nil
        }
        let accessLease = try? accessResult.get()
        let localURL = accessLease?.url ?? localURL
        let fileSize = max(
            Self.currentTransferredBytes(at: localURL),
            (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        )
        let taskId = UUID()
        let task = TransferTask(
            id: taskId,
            fileName: localURL.lastPathComponent,
            remotePath: remotePath,
            localURL: localURL,
            direction: .upload,
            totalBytes: fileSize,
            status: .queued
        )
        tasks.insert(task, at: 0)
        retryContexts[taskId] = RetryContext(
            session: session,
            tabID: tabID,
            onCompleted: onCompleted,
            onResult: onResult,
            onDownloadResult: nil,
            accessLease: accessLease
        )

        let runner = Task { [weak self] in
            guard let self = self else { return }
            do {
                _ = try accessResult.get()
            } catch {
                if let index = self.tasks.firstIndex(where: { $0.id == taskId }) {
                    self.tasks[index].status = .failed(error.localizedDescription)
                    self.tasks[index].completedAt = Date()
                }
                onResult?(.failure(error))
                self.activeTaskHandles.removeValue(forKey: taskId)
                self.pruneCompletedHistoryIfNeeded()
                return
            }
            await self.executeUpload(
                taskId: taskId,
                session: session,
                localURL: localURL,
                remotePath: remotePath,
                tabID: tabID,
                onCompleted: onCompleted,
                onResult: onResult
            )
        }
        activeTaskHandles[taskId] = runner
        return taskId
    }
    
    /// Keep existing downloads and queued destinations intact when names collide.
    public func availableDownloadURL(in directory: URL, fileName: String) -> URL {
        let original = directory.appendingPathComponent(fileName)
        let stem = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        let reserved = Set(tasks.filter { $0.status == .queued || $0.status == .transferring }.map { $0.localURL.standardizedFileURL.path })
        var candidate = original
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.standardizedFileURL.path) {
            let name = "\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    /// Enqueue a download task
    @discardableResult
    public func enqueueDownload(
        session: SSHSessionProtocol,
        remotePath: String,
        localURL: URL,
        totalBytes: Int64,
        onCompleted: (@Sendable () -> Void)? = nil,
        onResult: (@Sendable (Result<URL, Error>) -> Void)? = nil
    ) -> UUID {
        enqueueDownloadInternal(
            session: session,
            remotePath: remotePath,
            localURL: localURL,
            totalBytes: totalBytes,
            retainedLease: nil,
            onCompleted: onCompleted,
            onResult: onResult
        )
    }

    @discardableResult
    private func enqueueDownloadInternal(
        session: SSHSessionProtocol,
        remotePath: String,
        localURL: URL,
        totalBytes: Int64,
        retainedLease: FileAccessLease?,
        onCompleted: (@Sendable () -> Void)?,
        onResult: (@Sendable (Result<URL, Error>) -> Void)?
    ) -> UUID {
        // Acquire while the panel/Finder URL is still live, before scheduling the task.
        let accessResult = Result<FileAccessLease?, Error> {
            if let retainedLease {
                return retainedLease
            }
            return distributionChannel == .appStore ? try fileAccessStore.acquire(localURL) : nil
        }
        let accessLease = try? accessResult.get()
        let localURL = accessLease?.url ?? localURL
        let taskId = UUID()
        let fileName = (remotePath as NSString).lastPathComponent
        let task = TransferTask(
            id: taskId,
            fileName: fileName,
            remotePath: remotePath,
            localURL: localURL,
            direction: .download,
            totalBytes: totalBytes,
            status: .queued
        )
        tasks.insert(task, at: 0)
        retryContexts[taskId] = RetryContext(
            session: session,
            tabID: nil,
            onCompleted: onCompleted,
            onResult: nil,
            onDownloadResult: onResult,
            accessLease: accessLease
        )

        let runner = Task { [weak self] in
            guard let self = self else { return }
            do {
                _ = try accessResult.get()
            } catch {
                if let index = self.tasks.firstIndex(where: { $0.id == taskId }) {
                    self.tasks[index].status = .failed(error.localizedDescription)
                    self.tasks[index].completedAt = Date()
                }
                onResult?(.failure(error))
                self.activeTaskHandles.removeValue(forKey: taskId)
                self.pruneCompletedHistoryIfNeeded()
                return
            }
            await self.executeDownload(
                taskId: taskId,
                session: session,
                remotePath: remotePath,
                localURL: localURL,
                onCompleted: onCompleted,
                onResult: onResult
            )
        }
        activeTaskHandles[taskId] = runner
        return taskId
    }
    
    public func cancelTask(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }), !tasks[idx].status.isTerminal else {
            return
        }
        if let waiterIdx = slotWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = slotWaiters.remove(at: waiterIdx)
            waiter.continuation.resume(returning: false)
        }
        activeTaskHandles[id]?.cancel()
        activeTaskHandles.removeValue(forKey: id)
        let externalCancel = externalCancelHandlers.removeValue(forKey: id)
        lastSpeedSampleTime.removeValue(forKey: id)
        lastSampledBytes.removeValue(forKey: id)
        tasks[idx].status = .cancelled
        tasks[idx].completedAt = Date()
        externalCancel?()
        pruneCompletedHistoryIfNeeded()
    }

    public func removeTask(id: UUID) {
        if let idx = tasks.firstIndex(where: { $0.id == id }), !tasks[idx].status.isTerminal {
            cancelTask(id: id)
        } else {
            activeTaskHandles[id]?.cancel()
            activeTaskHandles.removeValue(forKey: id)
            externalCancelHandlers.removeValue(forKey: id)
            lastSpeedSampleTime.removeValue(forKey: id)
            lastSampledBytes.removeValue(forKey: id)
        }
        retryContexts.removeValue(forKey: id)?.closeAccessLease()
        tasks.removeAll { $0.id == id }
    }

    public func canRetryTask(id: UUID) -> Bool {
        guard let task = tasks.first(where: { $0.id == id }) else { return false }
        switch task.status {
        case .failed, .cancelled:
            return retryContexts[id]?.session != nil
        case .queued, .transferring, .completed:
            return false
        }
    }

    @discardableResult
    public func retryTask(id: UUID) -> UUID? {
        guard let task = tasks.first(where: { $0.id == id }) else { return nil }
        switch task.status {
        case .failed, .cancelled:
            break
        case .queued, .transferring, .completed:
            return nil
        }
        guard let context = retryContexts[id], let session = context.session else { return nil }
        let retainedLease = context.takeAccessLease()
        removeTask(id: id)
        switch task.direction {
        case .upload:
            return enqueueUploadInternal(
                session: session,
                localURL: task.localURL,
                remotePath: task.remotePath,
                tabID: context.tabID,
                retainedLease: retainedLease,
                onCompleted: context.onCompleted,
                onResult: context.onResult
            )
        case .download:
            return enqueueDownloadInternal(
                session: session,
                remotePath: task.remotePath,
                localURL: task.localURL,
                totalBytes: task.totalBytes,
                retainedLease: retainedLease,
                onCompleted: context.onCompleted,
                onResult: context.onDownloadResult
            )
        }
    }

    public func cancelAllTasks() {
        let allWaiters = slotWaiters
        slotWaiters.removeAll()
        for waiter in allWaiters {
            waiter.continuation.resume(returning: false)
        }
        for (_, handle) in activeTaskHandles {
            handle.cancel()
        }
        activeTaskHandles.removeAll()
        let cancelHandlers = Array(externalCancelHandlers.values)
        externalCancelHandlers.removeAll()
        lastSpeedSampleTime.removeAll()
        lastSampledBytes.removeAll()
        let now = Date()
        for idx in tasks.indices where tasks[idx].status == .queued || tasks[idx].status == .transferring {
            tasks[idx].status = .cancelled
            tasks[idx].completedAt = now
        }
        for handler in cancelHandlers {
            handler()
        }
        pruneCompletedHistoryIfNeeded()
    }
    
    public func clearCompleted() {
        let terminalIds = tasks.filter { $0.status.isTerminal }.map(\.id)
        for id in terminalIds {
            activeTaskHandles.removeValue(forKey: id)
            externalCancelHandlers.removeValue(forKey: id)
            retryContexts.removeValue(forKey: id)?.closeAccessLease()
            lastSpeedSampleTime.removeValue(forKey: id)
            lastSampledBytes.removeValue(forKey: id)
        }
        tasks.removeAll { $0.status.isTerminal }
    }
    
    // MARK: - Externally Driven Transfers (Drag & Drop Export / Streaming)
    
    /// Register and begin tracking an externally-driven transfer (e.g. drag & drop export to Finder or drag upload)
    @discardableResult
    public func beginExternalTransfer(
        id: UUID = UUID(),
        fileName: String,
        remotePath: String,
        localURL: URL,
        direction: TransferDirection,
        totalBytes: Int64,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> UUID {
        let task = TransferTask(
            id: id,
            fileName: fileName,
            remotePath: remotePath,
            localURL: localURL,
            direction: direction,
            totalBytes: totalBytes,
            transferredBytes: 0,
            speedBytesPerSec: 0,
            status: .transferring,
            startedAt: Date()
        )
        tasks.insert(task, at: 0)
        if let onCancel {
            externalCancelHandlers[id] = onCancel
        }
        lastSpeedSampleTime[id] = Date()
        lastSampledBytes[id] = 0
        return id
    }
    
    /// Safely calculate the current total bytes written to a file or directory
    nonisolated public static func currentTransferredBytes(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                return size.int64Value
            }
            return 0
        } else {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return 0
            }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                   resourceValues.isRegularFile == true,
                   let size = resourceValues.fileSize {
                    total += Int64(size)
                }
            }
            return total
        }
    }

    /// Update progress for an externally-driven transfer
    public func updateExternalProgress(taskId: UUID, fraction: Double, transferredBytes: Int64? = nil) {
        updateProgress(taskId: taskId, fraction: fraction, transferredBytes: transferredBytes)
    }
    
    /// Mark an externally-driven transfer as completed
    public func completeExternalTransfer(taskId: UUID) {
        externalCancelHandlers.removeValue(forKey: taskId)
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              !tasks[idx].status.isTerminal else {
            return
        }
        tasks[idx].transferredBytes = max(tasks[idx].transferredBytes, tasks[idx].totalBytes)
        tasks[idx].status = .completed
        tasks[idx].completedAt = Date()
        lastSpeedSampleTime.removeValue(forKey: taskId)
        lastSampledBytes.removeValue(forKey: taskId)
        pruneCompletedHistoryIfNeeded()
    }
    
    /// Mark an externally-driven transfer as failed
    public func failExternalTransfer(taskId: UUID, error: Error) {
        externalCancelHandlers.removeValue(forKey: taskId)
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].status != .cancelled else {
            return
        }
        tasks[idx].status = .failed(error.localizedDescription)
        tasks[idx].completedAt = Date()
        lastSpeedSampleTime.removeValue(forKey: taskId)
        lastSampledBytes.removeValue(forKey: taskId)
        pruneCompletedHistoryIfNeeded()
    }
    
    /// Mark an externally-driven transfer as cancelled
    public func cancelExternalTransfer(taskId: UUID) {
        externalCancelHandlers.removeValue(forKey: taskId)
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].status != .completed else {
            return
        }
        tasks[idx].status = .cancelled
        tasks[idx].completedAt = Date()
        lastSpeedSampleTime.removeValue(forKey: taskId)
        lastSampledBytes.removeValue(forKey: taskId)
        pruneCompletedHistoryIfNeeded()
    }
    
    // MARK: - Internal Execution
    
    private func executeUpload(
        taskId: UUID,
        session: SSHSessionProtocol,
        localURL: URL,
        remotePath: String,
        tabID: UUID?,
        onCompleted: (@Sendable () -> Void)?,
        onResult: (@Sendable (Result<String, Error>) -> Void)? = nil
    ) async {
        let maxConcurrent = effectiveMaxConcurrent(for: session)
        let acquired = await acquireTransferSlot(taskId: taskId, maxConcurrent: maxConcurrent)
        guard acquired else {
            if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[idx].status = .cancelled
                tasks[idx].completedAt = Date()
            }
            activeTaskHandles.removeValue(forKey: taskId)
            onResult?(.failure(CancellationError()))
            return
        }
        defer { releaseTransferSlot() }

        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].status != .cancelled,
              !Task.isCancelled else {
            activeTaskHandles.removeValue(forKey: taskId)
            onResult?(.failure(CancellationError()))
            return
        }
        tasks[idx].status = .transferring
        tasks[idx].startedAt = Date()
        lastSpeedSampleTime[taskId] = Date()
        lastSampledBytes[taskId] = 0
        
        do {
            try await session.uploadFile(localURL: localURL, remotePath: remotePath) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.updateProgress(taskId: taskId, fraction: fraction)
                }
            }
            
            try Task.checkCancellation()
            if let finalIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[finalIdx].transferredBytes = tasks[finalIdx].totalBytes
                tasks[finalIdx].status = .completed
                tasks[finalIdx].completedAt = Date()
            }
            retryContexts.removeValue(forKey: taskId)?.closeAccessLease()
            onResult?(.success(remotePath))
            onCompleted?()
            let refreshUserInfo: [AnyHashable: Any]? = tabID.map { ["tabId": $0] }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("SFTPDirectoryRefreshNeeded"),
                    object: remotePath,
                    userInfo: refreshUserInfo
                )
            }
        } catch {
            if let finalIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                if Task.isCancelled || error is CancellationError || tasks[finalIdx].status == .cancelled {
                    tasks[finalIdx].status = .cancelled
                } else {
                    tasks[finalIdx].status = .failed(error.localizedDescription)
                }
                tasks[finalIdx].completedAt = Date()
            }
            onResult?(.failure(error))
        }
        
        activeTaskHandles.removeValue(forKey: taskId)
        lastSpeedSampleTime.removeValue(forKey: taskId)
        lastSampledBytes.removeValue(forKey: taskId)
        pruneCompletedHistoryIfNeeded()
    }
    
    private func executeDownload(
        taskId: UUID,
        session: SSHSessionProtocol,
        remotePath: String,
        localURL: URL,
        onCompleted: (@Sendable () -> Void)?,
        onResult: (@Sendable (Result<URL, Error>) -> Void)? = nil
    ) async {
        let maxConcurrent = effectiveMaxConcurrent(for: session)
        let acquired = await acquireTransferSlot(taskId: taskId, maxConcurrent: maxConcurrent)
        guard acquired else {
            if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[idx].status = .cancelled
                tasks[idx].completedAt = Date()
            }
            activeTaskHandles.removeValue(forKey: taskId)
            onResult?(.failure(CancellationError()))
            return
        }
        defer { releaseTransferSlot() }

        guard let idx = tasks.firstIndex(where: { $0.id == taskId }),
              tasks[idx].status != .cancelled,
              !Task.isCancelled else {
            activeTaskHandles.removeValue(forKey: taskId)
            onResult?(.failure(CancellationError()))
            return
        }
        tasks[idx].status = .transferring
        tasks[idx].startedAt = Date()
        lastSpeedSampleTime[taskId] = Date()
        lastSampledBytes[taskId] = 0
        let totalBytes = tasks[idx].totalBytes

        let destDir = localURL.deletingLastPathComponent()
        let stagingURL: URL
        if distributionChannel != .appStore,
           FileManager.default.isWritableFile(atPath: destDir.path) {
            stagingURL = destDir.appendingPathComponent(".\(localURL.lastPathComponent).\(taskId.uuidString.prefix(8)).aetherpart")
        } else {
            stagingURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(localURL.lastPathComponent).\(taskId.uuidString.prefix(8)).aetherpart")
        }
        
        // Active file size poller off the main thread to ensure real-time progress & throughput updates
        let progressMonitor = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000) // 150ms sampling
                if Task.isCancelled { break }
                let bytes = Self.currentTransferredBytes(at: stagingURL)
                if bytes > 0 {
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        let fraction = totalBytes > 0 ? min(Double(bytes) / Double(totalBytes), 1.0) : 0.0
                        self.updateProgress(taskId: taskId, fraction: fraction, transferredBytes: bytes)
                    }
                }
            }
        }
        defer { progressMonitor.cancel() }
        
        do {
            try await session.downloadFile(remotePath: remotePath, localURL: stagingURL) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.updateProgress(taskId: taskId, fraction: fraction)
                }
            }
            
            try Task.checkCancellation()
            progressMonitor.cancel()

            if FileManager.default.fileExists(atPath: stagingURL.path) {
                let parentDir = localURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                if FileManager.default.fileExists(atPath: localURL.path) {
                    _ = try FileManager.default.replaceItemAt(localURL, withItemAt: stagingURL)
                } else {
                    try FileManager.default.moveItem(at: stagingURL, to: localURL)
                }
            }

            if let finalIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                let actualSize = Self.currentTransferredBytes(at: localURL)
                let finalBytes = actualSize > 0 ? actualSize : tasks[finalIdx].totalBytes
                tasks[finalIdx].totalBytes = max(tasks[finalIdx].totalBytes, finalBytes)
                tasks[finalIdx].transferredBytes = tasks[finalIdx].totalBytes
                tasks[finalIdx].status = .completed
                tasks[finalIdx].completedAt = Date()
            }
            retryContexts.removeValue(forKey: taskId)?.closeAccessLease()
            onResult?(.success(localURL))
            onCompleted?()
        } catch {
            progressMonitor.cancel()
            try? FileManager.default.removeItem(at: stagingURL)
            if let finalIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                if Task.isCancelled || error is CancellationError || tasks[finalIdx].status == .cancelled {
                    tasks[finalIdx].status = .cancelled
                } else {
                    tasks[finalIdx].status = .failed(error.localizedDescription)
                }
                tasks[finalIdx].completedAt = Date()
            }
            onResult?(.failure(error))
        }
        
        activeTaskHandles.removeValue(forKey: taskId)
        lastSpeedSampleTime.removeValue(forKey: taskId)
        lastSampledBytes.removeValue(forKey: taskId)
        pruneCompletedHistoryIfNeeded()
    }
    
    public func updateProgress(taskId: UUID, fraction: Double, transferredBytes: Int64? = nil) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].status == .transferring else { return }
        let total = tasks[idx].totalBytes
        let computed: Int64
        if let direct = transferredBytes {
            computed = direct
        } else if total > 0 {
            computed = Int64(Double(total) * fraction)
        } else {
            computed = 0
        }
        let transferred = max(tasks[idx].transferredBytes, computed)
        tasks[idx].transferredBytes = transferred
        
        let now = Date()
        if let lastTime = lastSpeedSampleTime[taskId], let lastBytes = lastSampledBytes[taskId] {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed >= 0.25 {
                let deltaBytes = Double(transferred - lastBytes)
                let speed = deltaBytes / elapsed
                tasks[idx].speedBytesPerSec = max(0, speed)
                lastSpeedSampleTime[taskId] = now
                lastSampledBytes[taskId] = transferred
            }
        } else {
            lastSpeedSampleTime[taskId] = now
            lastSampledBytes[taskId] = transferred
        }
    }
}
