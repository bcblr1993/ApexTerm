import Foundation

/// Strategy for resolving conflicts when local data differs from remote iCloud data
public enum iCloudConflictStrategy: String, CaseIterable, Codable, Sendable {
    case smartMerge = "智能双向合并 (推荐)"
    case overwriteCloud = "本地覆盖云端"
    case overwriteLocal = "云端覆盖本地"
}

/// Lifecycle status for iCloud synchronization
public enum iCloudSyncStatus: Equatable, Sendable {
    case idle(lastSyncDate: Date?)
    case syncing(step: String)
    case success(timestamp: Date, count: Int)
    case unavailable(reason: String)
    case error(String)
}

/// Errors occurring during iCloud synchronization
public enum iCloudSyncError: LocalizedError, Equatable {
    case cloudUnavailable(String)
    case payloadCorrupted(String)
    case writeFailed(String)
    case mergeFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .cloudUnavailable(let msg):
            return "iCloud 存储不可用：\(msg)"
        case .payloadCorrupted(let msg):
            return "云端同步数据损坏或格式不兼容：\(msg)"
        case .writeFailed(let msg):
            return "写入云端数据失败：\(msg)"
        case .mergeFailed(let msg):
            return "合并数据冲突失败：\(msg)"
        }
    }
}

/// Summary result of a completed synchronization cycle
public struct iCloudSyncResult: Equatable, Sendable {
    public let timestamp: Date
    public let uploadedSessionsCount: Int
    public let downloadedSessionsCount: Int
    public let totalSessionsCount: Int
    public let uploadedSnippetsCount: Int
    public let downloadedSnippetsCount: Int
    public let totalSnippetsCount: Int
    public let message: String
    
    public init(
        timestamp: Date = Date(),
        uploadedSessionsCount: Int = 0,
        downloadedSessionsCount: Int = 0,
        totalSessionsCount: Int = 0,
        uploadedSnippetsCount: Int = 0,
        downloadedSnippetsCount: Int = 0,
        totalSnippetsCount: Int = 0,
        message: String = "同步成功"
    ) {
        self.timestamp = timestamp
        self.uploadedSessionsCount = uploadedSessionsCount
        self.downloadedSessionsCount = downloadedSessionsCount
        self.totalSessionsCount = totalSessionsCount
        self.uploadedSnippetsCount = uploadedSnippetsCount
        self.downloadedSnippetsCount = downloadedSnippetsCount
        self.totalSnippetsCount = totalSnippetsCount
        self.message = message
    }
}

/// Complete multi-domain sync payload stored on iCloud
public struct iCloudSyncPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var lastModified: Date
    public var deviceId: String
    public var deviceName: String
    public var appVersion: String
    
    // Synced Data Domains
    public var sessions: [Session]
    public var snippets: [Snippet]
    public var triggers: [Trigger]
    public var bookmarks: [SFTPBookmark]
    public var tunnels: [SSHTunnel]
    
    public init(
        version: Int = 1,
        lastModified: Date = Date(),
        deviceId: String = Host.current().localizedName ?? UUID().uuidString,
        deviceName: String = Host.current().localizedName ?? "Mac",
        appVersion: String = "1.12.0",
        sessions: [Session] = [],
        snippets: [Snippet] = [],
        triggers: [Trigger] = [],
        bookmarks: [SFTPBookmark] = [],
        tunnels: [SSHTunnel] = []
    ) {
        self.version = version
        self.lastModified = lastModified
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.sessions = sessions
        self.snippets = snippets
        self.triggers = triggers
        self.bookmarks = bookmarks
        self.tunnels = tunnels
    }
}
