import Foundation

public enum TransferDirection: String, Codable, Sendable {
    case upload
    case download
}

public enum TransferStatus: Sendable, Equatable {
    case queued
    case transferring
    case completed
    case failed(String)
    case cancelled
}

public struct TransferTask: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let fileName: String
    public let remotePath: String
    public let localURL: URL
    public let direction: TransferDirection
    public var totalBytes: Int64
    public var transferredBytes: Int64
    public var speedBytesPerSec: Double
    public var status: TransferStatus
    public var startedAt: Date
    public var completedAt: Date?
    
    public init(
        id: UUID = UUID(),
        fileName: String,
        remotePath: String,
        localURL: URL,
        direction: TransferDirection,
        totalBytes: Int64 = 0,
        transferredBytes: Int64 = 0,
        speedBytesPerSec: Double = 0,
        status: TransferStatus = .queued,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.remotePath = remotePath
        self.localURL = localURL
        self.direction = direction
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.speedBytesPerSec = speedBytesPerSec
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
    
    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(transferredBytes) / Double(totalBytes), 0.0), 1.0)
    }
    
    public var formattedSpeed: String {
        guard status == .transferring else { return "" }
        if speedBytesPerSec >= 1024 * 1024 {
            return String(format: "%.1f MB/s", speedBytesPerSec / (1024 * 1024))
        } else if speedBytesPerSec >= 1024 {
            return String(format: "%.0f KB/s", speedBytesPerSec / 1024)
        } else {
            return String(format: "%.0f B/s", speedBytesPerSec)
        }
    }
    
    public var formattedProgress: String {
        return String(format: "%.0f%%", progress * 100)
    }
}
