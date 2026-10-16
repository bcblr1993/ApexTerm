import Foundation

/// Represents a fast-access remote directory bookmark
public struct SFTPBookmark: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public let isPreset: Bool
    public let iconName: String

    public init(id: UUID = UUID(), name: String, path: String, isPreset: Bool = false, iconName: String = "folder") {
        self.id = id
        self.name = name
        self.path = path
        self.isPreset = isPreset
        self.iconName = iconName
    }
}

/// Central bookmark manager for SFTP quick access paths with persistence
@MainActor
public final class SFTPBookmarkManager: ObservableObject {
    public static let shared = SFTPBookmarkManager()

    public static let defaultPresets: [SFTPBookmark] = [
        SFTPBookmark(name: "用户主目录 (~)", path: "~", isPreset: true, iconName: "house"),
        SFTPBookmark(name: "系统日志 (/var/log)", path: "/var/log", isPreset: true, iconName: "doc.text.magnifyingglass"),
        SFTPBookmark(name: "系统配置 (/etc)", path: "/etc", isPreset: true, iconName: "gearshape.2"),
        SFTPBookmark(name: "临时目录 (/tmp)", path: "/tmp", isPreset: true, iconName: "trash"),
        SFTPBookmark(name: "应用部署 (/opt)", path: "/opt", isPreset: true, iconName: "shippingbox"),
        SFTPBookmark(name: "本地软件 (/usr/local)", path: "/usr/local", isPreset: true, iconName: "folder.badge.gearshape")
    ]

    private let storageKey = "sftp.bookmarks.custom"
    @Published public private(set) var customBookmarks: [SFTPBookmark] = []

    public init() {
        loadCustomBookmarks()
    }

    public var allBookmarks: [SFTPBookmark] {
        Self.defaultPresets + customBookmarks
    }

    public func addCustomBookmark(name: String, path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? trimmedPath : cleanName

        // Update existing if path matches or append new
        if let existingIdx = customBookmarks.firstIndex(where: { $0.path == trimmedPath }) {
            customBookmarks[existingIdx] = SFTPBookmark(name: finalName, path: trimmedPath, isPreset: false, iconName: "star.fill")
        } else {
            customBookmarks.append(SFTPBookmark(name: finalName, path: trimmedPath, isPreset: false, iconName: "star.fill"))
        }
        saveCustomBookmarks()
    }

    public func removeCustomBookmark(id: UUID) {
        customBookmarks.removeAll(where: { $0.id == id })
        saveCustomBookmarks()
    }

    public func replaceCustomBookmarks(_ newBookmarks: [SFTPBookmark]) {
        self.customBookmarks = newBookmarks
        saveCustomBookmarks()
    }

    public func isBookmarked(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return allBookmarks.contains(where: { $0.path == trimmed })
    }

    public func resetToDefaults() {
        customBookmarks.removeAll()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func loadCustomBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([SFTPBookmark].self, from: data) else {
            return
        }
        self.customBookmarks = list
    }

    private func saveCustomBookmarks() {
        if let data = try? JSONEncoder().encode(customBookmarks) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
