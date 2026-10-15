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
    case splitVertical = "split_vertical"
    case splitHorizontal = "split_horizontal"
    case toggleMaximize = "toggle_maximize"
    case openTunnels = "open_tunnels"
    case toggleQuickCommandBar = "toggle_quick_command_bar"
    case toggleSFTP = "toggle_sftp"
    case clearScrollback = "clear_scrollback"
    case openSettings = "open_settings"
    case checkForUpdates = "check_for_updates"
    case openAbout = "open_about"
    case openShortcuts = "open_shortcuts"
    
    public var title: String {
        switch self {
        case .newLocalTerminal: return "新建本地终端"
        case .duplicateSession: return "复制当前会话 / 新建标签页"
        case .splitVertical: return "垂直分屏 (左/右)"
        case .splitHorizontal: return "水平分屏 (上/下)"
        case .toggleMaximize: return "全屏放大 / 恢复分屏"
        case .openTunnels: return "SSH 端口转发与隧道管理"
        case .toggleQuickCommandBar: return "显示 / 隐藏底部快捷命令栏"
        case .toggleSFTP: return "显示 / 隐藏 SFTP 文件管理面板"
        case .clearScrollback: return "清除当前终端屏幕与回滚缓冲区"
        case .openSettings: return "打开偏好设置"
        case .checkForUpdates: return "检查软件更新"
        case .openAbout: return "关于 AetherTerm"
        case .openShortcuts: return "快捷键速查清单"
        }
    }
    
    public var iconName: String {
        switch self {
        case .newLocalTerminal: return "laptopcomputer"
        case .duplicateSession: return "plus.square.on.square"
        case .splitVertical: return "rectangle.split.2x1"
        case .splitHorizontal: return "rectangle.split.1x2"
        case .toggleMaximize: return "arrow.up.left.and.arrow.down.right"
        case .openTunnels: return "arrow.triangle.swap"
        case .toggleQuickCommandBar: return "terminal"
        case .toggleSFTP: return "folder"
        case .clearScrollback: return "trash"
        case .openSettings: return "gearshape"
        case .checkForUpdates: return "arrow.clockwise.circle"
        case .openAbout: return "info.circle"
        case .openShortcuts: return "keyboard"
        }
    }
    
    public var shortcutHint: String? {
        switch self {
        case .newLocalTerminal: return "⌘⇧T"
        case .duplicateSession: return "⌘T"
        case .splitVertical: return "⌘D"
        case .splitHorizontal: return "⌘⇧D"
        case .toggleMaximize: return "⌘⇧↵"
        case .openTunnels: return "⌘⌥T"
        case .toggleQuickCommandBar: return "⌘⇧B"
        case .toggleSFTP: return "⌘⇧F"
        case .clearScrollback: return "⌘K"
        case .openSettings: return "⌘,"
        case .checkForUpdates: return nil
        case .openAbout: return nil
        case .openShortcuts: return "⌘/"
        }
    }
}

/// The concrete action to trigger upon selecting a palette item
public enum CommandPaletteAction: Codable, Sendable, Equatable {
    case connectSession(UUID)
    case openBookmark(String)
    case runSnippet(Snippet)
    case executeAppAction(CommandPaletteAppAction)
}

/// A searchable item in the Command Palette
public struct CommandPaletteItem: Identifiable, Codable, Sendable, Equatable {
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
}

/// Fast search and ranking engine for Command Palette items
public enum CommandPaletteSearchEngine {
    
    /// Filters and ranks items according to the query string
    public static func search(items: [CommandPaletteItem], query: String, maxResults: Int = 30) -> [CommandPaletteItem] {
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
            } else if isSubsequenceMatch(pattern: lowerQuery, text: titleLower) {
                score += 80
            } else if isSubsequenceMatch(pattern: lowerQuery, text: subLower) {
                score += 40
            }
            
            if score > 0 {
                scored.append((item, score))
            }
        }
        
        // Sort descending by score, tiebreak by title
        scored.sort { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            return a.item.title < b.item.title
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
