import Foundation

/// Action categories supported in the global Command Palette
public enum CommandPaletteCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case session = "主机会话"
    case bookmark = "SFTP 路径"
    case snippet = "快捷命令"
    case action = "功能操作"
    
    public var id: String { rawValue }
    
    public var prefixSymbol: String {
        switch self {
        case .session: return "@"
        case .bookmark: return "/"
        case .snippet: return "#"
        case .action: return ">"
        }
    }
}

/// Predefined standard application actions executable from the Command Palette
public enum CommandPaletteAppAction: String, CaseIterable, Codable, Sendable {
    case newLocalTerminal = "new_local_terminal"
    case duplicateSession = "duplicate_session"
    case newSession = "new_session"
    case importSSHConfig = "import_ssh_config"
    case splitVertical = "split_vertical"
    case splitHorizontal = "split_horizontal"
    case toggleMaximize = "toggle_maximize"
    case reconnectSession = "reconnect_session"
    case toggleBroadcast = "toggle_broadcast"
    case openTunnels = "open_tunnels"
    case openProcessInspector = "open_process_inspector"
    case copyLastCommandOutput = "copy_last_command_output"
    case toggleQuickCommandBar = "toggle_quick_command_bar"
    case toggleSFTP = "toggle_sftp"
    case openBatchOperations = "open_batch_operations"
    case clearScrollback = "clear_scrollback"
    case lockApp = "lock_app"
    case openSettings = "open_settings"
    case checkForUpdates = "check_for_updates"
    case openAbout = "open_about"
    case openShortcuts = "open_shortcuts"
    case saveWorkspaceSnapshot = "save_workspace_snapshot"
    case restoreLastWorkspaceSnapshot = "restore_last_workspace_snapshot"
    
    public var title: String {
        switch self {
        case .newLocalTerminal: return "新建本地终端"
        case .duplicateSession: return "复制当前会话 / 新建标签页"
        case .newSession: return "新建 SSH 会话..."
        case .importSSHConfig: return "从 ~/.ssh/config 导入主机..."
        case .splitVertical: return "垂直分屏 (左/右)"
        case .splitHorizontal: return "水平分屏 (上/下)"
        case .toggleMaximize: return "全屏放大 / 恢复分屏"
        case .reconnectSession: return "重新连接当前会话"
        case .toggleBroadcast: return "开启 / 关闭多终端命令广播模式"
        case .openTunnels: return "SSH 端口转发与隧道管理"
        case .openProcessInspector: return "远程进程与服务监视控制中心"
        case .copyLastCommandOutput: return "复制上一条命令输出"
        case .toggleQuickCommandBar: return "显示 / 隐藏底部快捷命令栏"
        case .toggleSFTP: return "显示 / 隐藏 SFTP 文件管理面板"
        case .openBatchOperations: return CommandPaletteItem.batchOperationsTitle
        case .clearScrollback: return "清除当前终端屏幕与回滚缓冲区"
        case .lockApp: return "立即锁定应用"
        case .openSettings: return "打开偏好设置"
        case .checkForUpdates: return "检查软件更新"
        case .openAbout: return "关于 AetherTerm"
        case .openShortcuts: return "快捷键速查清单"
        case .saveWorkspaceSnapshot: return "保存当前工作区快照..."
        case .restoreLastWorkspaceSnapshot: return "恢复上次工作区布局"
        }
    }
    
    public var iconName: String {
        switch self {
        case .newLocalTerminal: return "laptopcomputer"
        case .duplicateSession: return "plus.square.on.square"
        case .newSession: return "plus.circle"
        case .importSSHConfig: return "doc.text"
        case .splitVertical: return "rectangle.split.2x1"
        case .splitHorizontal: return "rectangle.split.1x2"
        case .toggleMaximize: return "arrow.up.left.and.arrow.down.right"
        case .reconnectSession: return "arrow.clockwise"
        case .toggleBroadcast: return "antenna.radiowaves.left.and.right"
        case .openTunnels: return "arrow.triangle.swap"
        case .openProcessInspector: return "list.bullet.rectangle.portrait"
        case .copyLastCommandOutput: return "doc.on.clipboard"
        case .toggleQuickCommandBar: return "terminal"
        case .toggleSFTP: return "folder"
        case .openBatchOperations: return CommandPaletteItem.batchOperationsIconName
        case .clearScrollback: return "trash"
        case .lockApp: return "lock.fill"
        case .openSettings: return "gearshape"
        case .checkForUpdates: return "arrow.clockwise.circle"
        case .openAbout: return "info.circle"
        case .openShortcuts: return "keyboard"
        case .saveWorkspaceSnapshot: return "rectangle.3.group.badge.plus"
        case .restoreLastWorkspaceSnapshot: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }
    
    public var shortcutHint: String? {
        switch self {
        case .newLocalTerminal: return ApexShortcutRegistry.shortcutHint(for: .newLocalTerminal)
        case .duplicateSession: return ApexShortcutRegistry.shortcutHint(for: .duplicateSession)
        case .newSession: return nil
        case .importSSHConfig: return nil
        case .splitVertical: return ApexShortcutRegistry.shortcutHint(for: .splitVertical)
        case .splitHorizontal: return ApexShortcutRegistry.shortcutHint(for: .splitHorizontal)
        case .toggleMaximize: return ApexShortcutRegistry.shortcutHint(for: .toggleMaximize)
        case .reconnectSession: return ApexShortcutRegistry.shortcutHint(for: .reconnectSession)
        case .toggleBroadcast: return nil
        case .openTunnels: return ApexShortcutRegistry.shortcutHint(for: .openTunnels)
        case .openProcessInspector: return ApexShortcutRegistry.shortcutHint(for: .openProcessInspector)
        case .copyLastCommandOutput: return ApexShortcutRegistry.shortcutHint(for: .copyLastCommandOutput)
        case .toggleQuickCommandBar: return ApexShortcutRegistry.shortcutHint(for: .toggleQuickCommandBar)
        case .toggleSFTP: return ApexShortcutRegistry.shortcutHint(for: .toggleSFTP)
        case .openBatchOperations: return CommandPaletteItem.batchOperationsShortcutHint
        case .clearScrollback: return ApexShortcutRegistry.shortcutHint(for: .clearScrollback)
        case .lockApp: return ApexShortcutRegistry.shortcutHint(for: .lockApp)
        case .openSettings: return ApexShortcutRegistry.shortcutHint(for: .openSettings)
        case .checkForUpdates: return nil
        case .openAbout: return nil
        case .openShortcuts: return ApexShortcutRegistry.shortcutHint(for: .openShortcuts)
        case .saveWorkspaceSnapshot: return nil
        case .restoreLastWorkspaceSnapshot: return nil
        }
    }
}

/// The concrete action to trigger upon selecting a palette item
public enum CommandPaletteAction: Codable, Sendable, Equatable {
    case connectSession(UUID)
    case openBookmark(String)
    case runSnippet(Snippet)
    case executeAppAction(CommandPaletteAppAction)
    case restoreWorkspaceSnapshot(UUID)
}

/// A searchable item in the Command Palette
public struct CommandPaletteItem: Identifiable, Codable, Sendable, Equatable {
    public static let openBatchOperationsNotification = Notification.Name("ApexTermOpenBatchOperations")

    public static let batchOperationsTitle = "批量执行命令 / 分发文件"
    public static let batchOperationsSubtitle = "向多台主机并发执行命令或分发本地文件"
    public static let batchOperationsIconName = "square.stack.3d.up"
    public static let batchOperationsShortcutHint = ApexShortcutRegistry.shortcutHint(for: .openBatchOperations) ?? "⌘⌥B"

    public static func batchOperationsUserInfo(sessionIDs: [UUID], folder: String? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = ["sessionIDs": sessionIDs]
        if let folder, !folder.isEmpty {
            info["folder"] = folder
        }
        return info
    }

    public static func postOpenBatchOperations(sessionIDs: [UUID] = [], folder: String? = nil) {
        NotificationCenter.default.post(
            name: openBatchOperationsNotification,
            object: nil,
            userInfo: batchOperationsUserInfo(sessionIDs: sessionIDs, folder: folder)
        )
    }

    public var id: UUID
    public var title: String
    public var subtitle: String
    public var category: CommandPaletteCategory
    public var iconName: String
    public var shortcutHint: String?
    public var action: CommandPaletteAction
    
    public init(
        id: UUID = UUID(),
        title: String,
        subtitle: String = "",
        category: CommandPaletteCategory,
        iconName: String,
        shortcutHint: String? = nil,
        action: CommandPaletteAction
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.iconName = iconName
        self.shortcutHint = shortcutHint
        self.action = action
    }

    /// Produces a deterministic UUID from a stable string key so rebuilt palette items retain ForEach identity.
    public static func stableID(for key: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        var h2: UInt64 = 0xaf63bd4c8601b7df
        for byte in key.utf8 {
            h1 ^= UInt64(byte)
            h1 &*= 0x100000001b3
            h2 ^= UInt64(byte) &+ 0x9e3779b97f4a7c15
            h2 &*= 0x100000001b3
        }
        var bytes: uuid_t = (
            UInt8((h1 >> 56) & 0xff), UInt8((h1 >> 48) & 0xff),
            UInt8((h1 >> 40) & 0xff), UInt8((h1 >> 32) & 0xff),
            UInt8((h1 >> 24) & 0xff), UInt8((h1 >> 16) & 0xff),
            UInt8((h1 >> 8) & 0xff),  UInt8(h1 & 0xff),
            UInt8((h2 >> 56) & 0xff), UInt8((h2 >> 48) & 0xff),
            UInt8((h2 >> 40) & 0xff), UInt8((h2 >> 32) & 0xff),
            UInt8((h2 >> 24) & 0xff), UInt8((h2 >> 16) & 0xff),
            UInt8((h2 >> 8) & 0xff),  UInt8(h2 & 0xff)
        )
        // Mark RFC 4122 version 4 & variant bits deterministically.
        bytes.6 = (bytes.6 & 0x0f) | 0x40
        bytes.8 = (bytes.8 & 0x3f) | 0x80
        return UUID(uuid: bytes)
    }
}

/// Fast search and ranking engine for Command Palette items
public enum CommandPaletteSearchEngine {
    
    /// Filters and ranks items according to the query string
    public static func search(items: [CommandPaletteItem], query: String, maxResults: Int = 30) -> [CommandPaletteItem] {
        guard maxResults > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Array(items.prefix(maxResults))
        }
        
        var effectiveQuery = trimmed
        var targetCategory: CommandPaletteCategory? = nil
        
        // Detect category prefix triggers
        if effectiveQuery.hasPrefix(">") {
            targetCategory = .action
            effectiveQuery = String(effectiveQuery.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if effectiveQuery.hasPrefix("@") {
            targetCategory = .session
            effectiveQuery = String(effectiveQuery.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if effectiveQuery.hasPrefix("/") {
            targetCategory = .bookmark
            effectiveQuery = String(effectiveQuery.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if effectiveQuery.hasPrefix("#") {
            targetCategory = .snippet
            effectiveQuery = String(effectiveQuery.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        
        let candidateItems: [CommandPaletteItem]
        if let cat = targetCategory {
            candidateItems = items.filter { $0.category == cat }
        } else {
            candidateItems = items
        }
        
        if effectiveQuery.isEmpty {
            return Array(candidateItems.prefix(maxResults))
        }
        
        let lowerQuery = effectiveQuery.lowercased()
        let queryTokens = lowerQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        
        // Score items
        var scored: [(item: CommandPaletteItem, score: Int)] = []
        for item in candidateItems {
            let titleLower = item.title.lowercased()
            let subLower = item.subtitle.lowercased()
            let catLower = item.category.rawValue.lowercased()
            
            var score = 0
            
            if titleLower == lowerQuery {
                score += 1000
            } else if titleLower.hasPrefix(lowerQuery) {
                score += 500
            } else if titleLower.contains(lowerQuery) {
                score += 300
            } else if subLower.hasPrefix(lowerQuery) {
                score += 200
            } else if subLower.contains(lowerQuery) {
                score += 150
            } else if catLower.contains(lowerQuery) {
                score += 100
            } else if queryTokens.count > 1,
                      queryTokens.allSatisfy({ titleLower.contains($0) || subLower.contains($0) || catLower.contains($0) }) {
                score += 90
            } else if isSubsequenceMatch(pattern: lowerQuery, text: titleLower) {
                score += 80
            } else if isSubsequenceMatch(pattern: lowerQuery, text: subLower) {
                score += 40
            }
            
            if score > 0 {
                scored.append((item, score))
            }
        }
        
        // Sort descending by score, tiebreak by title then subtitle
        scored.sort { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            if a.item.title != b.item.title {
                return a.item.title < b.item.title
            }
            return a.item.subtitle < b.item.subtitle
        }
        
        return Array(scored.prefix(maxResults).map { $0.item })
    }
    
    /// Checks whether `pattern` is a subsequence of `text`
    private static func isSubsequenceMatch(pattern: String, text: String) -> Bool {
        guard !pattern.isEmpty else { return true }
        var patternIndex = pattern.startIndex
        var textIndex = text.startIndex
        
        while patternIndex < pattern.endIndex && textIndex < text.endIndex {
            if pattern[patternIndex] == text[textIndex] {
                patternIndex = pattern.index(after: patternIndex)
            }
            textIndex = text.index(after: textIndex)
        }
        return patternIndex == pattern.endIndex
    }
}
