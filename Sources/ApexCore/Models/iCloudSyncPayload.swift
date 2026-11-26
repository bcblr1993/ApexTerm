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
    case cloudDownloadingPlaceholder(String)
    case payloadCorrupted(String)
    case writeFailed(String)
    case mergeFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .cloudUnavailable(let msg):
            return "iCloud 存储不可用：\(msg)"
        case .cloudDownloadingPlaceholder(let msg):
            return "iCloud 数据正在下载：\(msg)"
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

/// Complete multi-domain sync payload stored on iCloud (v1 & v2 backwards-compatible)
public struct iCloudSyncPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var lastModified: Date
    public var updatedAt: Date?
    public var deviceId: String
    public var deviceName: String
    public var appVersion: String
    
    // Synced Data Domains
    public var sessions: [Session]
    public var snippets: [Snippet]
    public var triggers: [Trigger]
    public var bookmarks: [SFTPBookmark]
    public var tunnels: [SSHTunnel]

    // v2 Tombstone & Per-Item Timestamp Metadata (Optional for v1 JSON compatibility)
    public var deletedTombstones: [UUID: Date]?
    public var itemUpdatedAt: [UUID: Date]?
    public var deletedBookmarkPaths: [String: Date]?
    
    public init(
        version: Int = 2,
        lastModified: Date = Date(),
        updatedAt: Date? = nil,
        deviceId: String = Host.current().localizedName ?? UUID().uuidString,
        deviceName: String = Host.current().localizedName ?? "Mac",
        appVersion: String = Bundle.apexResolvedAppVersion,
        sessions: [Session] = [],
        snippets: [Snippet] = [],
        triggers: [Trigger] = [],
        bookmarks: [SFTPBookmark] = [],
        tunnels: [SSHTunnel] = [],
        deletedTombstones: [UUID: Date]? = nil,
        itemUpdatedAt: [UUID: Date]? = nil,
        deletedBookmarkPaths: [String: Date]? = nil
    ) {
        self.version = version
        self.lastModified = lastModified
        self.updatedAt = updatedAt
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.sessions = sessions
        self.snippets = snippets
        self.triggers = triggers
        self.bookmarks = bookmarks
        self.tunnels = tunnels
        self.deletedTombstones = deletedTombstones
        self.itemUpdatedAt = itemUpdatedAt
        self.deletedBookmarkPaths = deletedBookmarkPaths
    }
}

/// Domain category for a previewed iCloud sync diff entry.
public enum iCloudSyncDiffDomain: String, CaseIterable, Codable, Sendable, Identifiable {
    case session = "会话"
    case snippet = "快捷命令"
    case trigger = "触发器"
    case bookmark = "SFTP 书签"
    case tunnel = "SSH 隧道"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .session: return "server.rack"
        case .snippet: return "bolt.fill"
        case .trigger: return "wand.and.stars"
        case .bookmark: return "bookmark.fill"
        case .tunnel: return "network"
        }
    }
}

/// Change type for a previewed iCloud sync diff entry.
public enum iCloudSyncDiffChangeKind: String, CaseIterable, Codable, Sendable {
    case added = "新增"
    case modified = "变更"
    case deleted = "删除"
}

/// Side that introduces or wins a change in the diff preview.
public enum iCloudSyncDiffSource: String, Codable, Sendable {
    case local = "本地"
    case remote = "云端"
}

/// Single entity difference computed by `iCloudSyncManager.previewDiff()`.
public struct iCloudSyncDiffItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let entityId: UUID?
    public let domain: iCloudSyncDiffDomain
    public let kind: iCloudSyncDiffChangeKind
    public let source: iCloudSyncDiffSource
    public let title: String
    public let subtitle: String
    public let localTimestamp: Date?
    public let remoteTimestamp: Date?

    public init(
        id: String,
        entityId: UUID? = nil,
        domain: iCloudSyncDiffDomain,
        kind: iCloudSyncDiffChangeKind,
        source: iCloudSyncDiffSource,
        title: String,
        subtitle: String = "",
        localTimestamp: Date? = nil,
        remoteTimestamp: Date? = nil
    ) {
        self.id = id
        self.entityId = entityId
        self.domain = domain
        self.kind = kind
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.localTimestamp = localTimestamp
        self.remoteTimestamp = remoteTimestamp
    }
}

/// Structured preview of changes before applying iCloud sync.
public struct iCloudSyncDiff: Equatable, Sendable {
    public var added: [iCloudSyncDiffItem]
    public var modified: [iCloudSyncDiffItem]
    public var deleted: [iCloudSyncDiffItem]
    public var remoteLastModified: Date?
    public var remoteDeviceName: String?
    public var generatedAt: Date

    public var hasChanges: Bool {
        !added.isEmpty || !modified.isEmpty || !deleted.isEmpty
    }

    public var totalCount: Int {
        added.count + modified.count + deleted.count
    }

    public init(
        added: [iCloudSyncDiffItem] = [],
        modified: [iCloudSyncDiffItem] = [],
        deleted: [iCloudSyncDiffItem] = [],
        remoteLastModified: Date? = nil,
        remoteDeviceName: String? = nil,
        generatedAt: Date = Date()
    ) {
        self.added = added
        self.modified = modified
        self.deleted = deleted
        self.remoteLastModified = remoteLastModified
        self.remoteDeviceName = remoteDeviceName
        self.generatedAt = generatedAt
    }
}
