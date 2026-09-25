import Foundation
import SwiftUI
import ApexCore

/// High-performance non-blocking SFTP Transfer Manager
/// Manages upload/download task queue, throttling UI updates for 120Hz smoothness
@MainActor
public final class TransferManager: ObservableObject {
    public static let shared = TransferManager()
    
    @Published public private(set) var tasks: [TransferTask] = []
    
    private var activeTaskHandles: [UUID: Task<Void, Never>] = [:]
    private var lastSpeedSampleTime: [UUID: Date] = [:]
    private var lastSampledBytes: [UUID: Int64] = [:]
    
    public init() {}
    
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
        onCompleted: (@Sendable () -> Void)? = nil
    ) -> UUID {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
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
        
        let runner = Task { [weak self] in
            guard let self = self else { return }
            await self.executeUpload(taskId: taskId, session: session, localURL: localURL, remotePath: remotePath, onCompleted: onCompleted)
        }
        activeTaskHandles[taskId] = runner
        return taskId
    }
    
    /// Enqueue a download task
    @discardableResult
    public func enqueueDownload(
        session: SSHSessionProtocol,
        remotePath: String,
        localURL: URL,
        totalBytes: Int64,
        onCompleted: (@Sendable () -> Void)? = nil
    ) -> UUID {
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
        
        let runner = Task { [weak self] in
            guard let self = self else { return }
            await self.executeDownload(taskId: taskId, session: session, remotePath: remotePath, localURL: localURL, onCompleted: onCompleted)
        }
        activeTaskHandles[taskId] = runner
        return taskId
    }
    
    public func cancelTask(id: UUID) {
        activeTaskHandles[id]?.cancel()
        activeTaskHandles.removeValue(forKey: id)
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx].status = .cancelled
            tasks[idx].completedAt = Date()
        }
    }
    
    public func clearCompleted() {
        tasks.removeAll { $0.status == .completed || $0.status == .cancelled }
    }
    
    // MARK: - Internal Execution
    
    private func executeUpload(
        taskId: UUID,
        session: SSHSessionProtocol,
        localURL: URL,
        remotePath: String,
        onCompleted: (@Sendable () -> Void)?
    ) async {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
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
            
            if let finalIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[finalIdx].transferredBytes = tasks[finalIdx].totalBytes
                tasks[finalIdx].status = .completed
                tasks[finalIdx].completedAt = Date()
            }
            onCompleted?()
        } catch {
            if let finalIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                if Task.isCancelled {
                    tasks[finalIdx].status = .cancelled
                } else {
                    tasks[finalIdx].status = .failed(error.localizedDescription)
                }
                tasks[finalIdx].completedAt = Date()
            }
        }
        
        activeTaskHandles.removeValue(forKey: taskId)
        lastSpeedSampleTime.removeValue(forKey: taskId)
        lastSampledBytes.removeValue(forKey: taskId)
    }
    
    private func executeDownload(
        taskId: UUID,
        session: SSHSessionProtocol,
        remotePath: String,
        localURL: URL,
        onCompleted: (@Sendable () -> Void)?
    ) async {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[idx].status = .transferring
        tasks[idx].startedAt = Date()
        lastSpeedSampleTime[taskId] = Date()
        lastSampledBytes[taskId] = 0
        
        do {
            try await session.downloadFile(remotePath: remotePath, localURL: localURL) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.updateProgress(taskId: taskId, fraction: fraction)
                }
            }
            
            if let finalIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                tasks[finalIdx].transferredBytes = tasks[finalIdx].totalBytes
                tasks[finalIdx].status = .completed
                tasks[finalIdx].completedAt = Date()
            }
            onCompleted?()
        } catch {
            if let finalIdx = tasks.firstIndex(where: { $0.id == taskId }) {
                if Task.isCancelled {
                    tasks[finalIdx].status = .cancelled
                } else {
                    tasks[finalIdx].status = .failed(error.localizedDescription)
                }
                tasks[finalIdx].completedAt = Date()
            }
        }
        
        activeTaskHandles.removeValue(forKey: taskId)
        lastSpeedSampleTime.removeValue(forKey: taskId)
        lastSampledBytes.removeValue(forKey: taskId)
    }
    
    private func updateProgress(taskId: UUID, fraction: Double) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        let total = tasks[idx].totalBytes
        let transferred = total > 0 ? Int64(Double(total) * fraction) : Int64(fraction * 100)
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
