import Foundation

/// Split layout orientation captured inside a `WorkspaceTabSnapshot`.
public enum WorkspaceSnapshotSplitMode: String, Codable, Sendable, Equatable, Hashable {
    case single
    case vertical
    case horizontal
    case mainPlusTwo = "1+2"
    case grid2x2 = "2x2"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? "single"
        self = Self(rawValue: raw) ?? .single
    }
}

/// Credential-free snapshot of a single workspace tab and its split layout.
public struct WorkspaceTabSnapshot: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var sessionID: UUID?
    public var isLocal: Bool
    public var customTitle: String?
    public var splitMode: WorkspaceSnapshotSplitMode
    public var paneCount: Int
    public var paneSplitRatio: Double
    public var isPaneMaximized: Bool
    public var currentRemotePath: String
    public var isDirectoryLinkageEnabled: Bool

    public init(
        id: UUID = UUID(),
        sessionID: UUID?,
        isLocal: Bool = false,
        customTitle: String? = nil,
        splitMode: WorkspaceSnapshotSplitMode = .single,
        paneCount: Int = 1,
        paneSplitRatio: Double = 0.5,
        isPaneMaximized: Bool = false,
        currentRemotePath: String = "~",
        isDirectoryLinkageEnabled: Bool = true
    ) {
        self.id = id
        self.sessionID = sessionID
        self.isLocal = isLocal
        self.customTitle = customTitle
        self.splitMode = splitMode
        self.paneCount = max(1, paneCount)
        self.paneSplitRatio = min(max(paneSplitRatio, 0.15), 0.85)
        self.isPaneMaximized = isPaneMaximized
        let trimmedPath = currentRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentRemotePath = trimmedPath.isEmpty ? "~" : trimmedPath
        self.isDirectoryLinkageEnabled = isDirectoryLinkageEnabled
    }
}

/// Credential-free saved layout of open terminal tabs, split panes, and SFTP dock state.
public struct WorkspaceSnapshot: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var tabs: [WorkspaceTabSnapshot]
    public var selectedTabIndex: Int?
    public var isSFTPVisible: Bool
    public var filesSplitRatio: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        tabs: [WorkspaceTabSnapshot],
        selectedTabIndex: Int? = nil,
        isSFTPVisible: Bool = true,
        filesSplitRatio: Double = 0.70,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleanName.isEmpty ? "未命名工作区" : cleanName
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.isSFTPVisible = isSFTPVisible
        self.filesSplitRatio = min(max(filesSplitRatio, 0.2), 0.85)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Returns only tabs that can be cleanly restored against the current `SessionStore`
    /// (preserving local terminal tabs and remote tabs whose `sessionID` still exists).
    public func resolvedTabs(using availableSessions: [Session]) -> [WorkspaceTabSnapshot] {
        let validIDs = Set(availableSessions.map(\.id))
        return tabs.filter { tab in
            if tab.isLocal { return true }
            guard let sid = tab.sessionID else { return false }
            return validIDs.contains(sid)
        }
    }
}

/// Persistent store for named credential-free workspace snapshots (`workspace_snapshots.json`).
@MainActor
public final class WorkspaceSnapshotStore: ObservableObject {
    public static let shared = WorkspaceSnapshotStore()

    @Published public private(set) var snapshots: [WorkspaceSnapshot] = []

    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = SessionStore.defaultDirectory(appSupport: appSupport, bundleIdentifier: Bundle.main.bundleIdentifier)
        }

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        try? fileManager.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
        loadSnapshots()
    }

    public var snapshotsFileURL: URL {
        baseDirectory.appendingPathComponent("workspace_snapshots.json")
    }

    public var lastWorkspaceFileURL: URL {
        baseDirectory.appendingPathComponent("last_workspace.json")
    }

    public func saveLastWorkspace(_ snapshot: WorkspaceSnapshot) {
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: lastWorkspaceFileURL, options: .atomic)
        }
    }

    public func loadLastWorkspace() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: lastWorkspaceFileURL),
              let decoded = try? decoder.decode(WorkspaceSnapshot.self, from: data) else {
            return nil
        }
        return decoded
    }

    public func loadSnapshots() {
        guard let data = try? Data(contentsOf: snapshotsFileURL),
              let decoded = try? decoder.decode([WorkspaceSnapshot].self, from: data) else {
            return
        }
        self.snapshots = decoded
    }

    public func saveAll() {
        if let data = try? encoder.encode(snapshots) {
            try? data.write(to: snapshotsFileURL, options: .atomic)
        }
    }

    @discardableResult
    public func createSnapshot(
        name: String,
        tabs: [WorkspaceTabSnapshot],
        selectedTabIndex: Int? = nil,
        isSFTPVisible: Bool = true,
        filesSplitRatio: Double = 0.70
    ) -> WorkspaceSnapshot {
        let snapshot = WorkspaceSnapshot(
            name: name,
            tabs: tabs,
            selectedTabIndex: selectedTabIndex,
            isSFTPVisible: isSFTPVisible,
            filesSplitRatio: filesSplitRatio
        )
        saveSnapshot(snapshot)
        return snapshot
    }

    public func saveSnapshot(_ snapshot: WorkspaceSnapshot) {
        if let idx = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            var updated = snapshot
            updated.updatedAt = Date()
            snapshots[idx] = updated
        } else {
            snapshots.insert(snapshot, at: 0)
        }
        saveAll()
    }

    public func snapshot(id: UUID) -> WorkspaceSnapshot? {
        snapshots.first(where: { $0.id == id })
    }

    public func renameSnapshot(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = snapshots.firstIndex(where: { $0.id == id }) else { return }
        snapshots[idx].name = trimmed
        snapshots[idx].updatedAt = Date()
        saveAll()
    }

    public func deleteSnapshot(id: UUID) {
        snapshots.removeAll(where: { $0.id == id })
        saveAll()
    }

    public func replaceAllSnapshots(_ newSnapshots: [WorkspaceSnapshot]) {
        snapshots = newSnapshots
        saveAll()
    }
}
