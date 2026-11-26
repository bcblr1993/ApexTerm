import Foundation

/// Logical section categories for keyboard shortcuts and help documentation.
public enum ApexShortcutCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case navigation = "全局与调色板导航"
    case tabs = "会话与标签管理"
    case splitPanes = "终端多分屏 (Split Panes)"
    case terminal = "终端流与按键操作"
    case sftp = "SFTP 文件传输与书签"
    case mouse = "鼠标高效交互"
    case app = "应用与偏好"

    public var id: String { rawValue }

    public var title: String { rawValue }

    public var iconName: String {
        switch self {
        case .navigation: return "sparkle.magnifyingglass"
        case .tabs: return "macwindow.on.rectangle"
        case .splitPanes: return "rectangle.split.2x1"
        case .terminal: return "terminal"
        case .sftp: return "folder"
        case .mouse: return "cursorarrow.rays"
        case .app: return "gearshape"
        }
    }
}

/// Stable action keys for every registered shortcut across menus, palette, workspace, and cheat sheet.
public enum ApexShortcutActionKey: String, CaseIterable, Codable, Sendable {
    // Global & Palette Navigation
    case commandPalette
    case openProcessInspector
    case copyLastCommandOutput
    case openTunnels
    case openBatchOperations
    case toggleQuickCommandBar
    case toggleSFTP
    case lockApp
    case showMainWindow

    // Tabs & Sessions
    case duplicateSession
    case newLocalTerminal
    case nextTab
    case previousTab
    case closeCurrentTabOrPane
    case switchTabByNumber
    case tabContextMenu

    // Split Panes
    case splitVertical
    case splitHorizontal
    case toggleMaximize
    case focusPane

    // Terminal Stream & Editing
    case reconnectSession
    case find
    case findNext
    case findPrevious
    case jumpPrompt
    case clearScrollback
    case sendSIGINT
    case sendEOF
    case sendSIGTSTP
    case clearTerminalLine
    case selectAllTerminal
    case copyTerminal
    case pasteTerminal
    case terminalFontZoom
    case toggleFullScreen

    // SFTP
    case focusSFTPPath
    case sftpRemoteSearch
    case toggleHiddenFiles
    case sftpBookmarks
    case sftpDragDrop

    // Mouse
    case mouseCopyOnSelect
    case mouseRightClickPaste
    case mouseShiftRightClickMenu

    // App
    case openSettings
    case openShortcuts
    case quitApp
}

/// Single-source-of-truth definition for a shortcut or interaction hint.
public struct ApexShortcutDefinition: Identifiable, Hashable, Sendable {
    public let id: String
    public let actionKey: ApexShortcutActionKey
    public let category: ApexShortcutCategory
    public let title: String
    public let description: String
    public let keys: [String]
    public let displayShortcut: String
    public let isKeyboardShortcut: Bool

    public init(
        actionKey: ApexShortcutActionKey,
        category: ApexShortcutCategory,
        title: String,
        description: String,
        keys: [String],
        displayShortcut: String? = nil,
        isKeyboardShortcut: Bool = true
    ) {
        self.id = actionKey.rawValue
        self.actionKey = actionKey
        self.category = category
        self.title = title
        self.description = description
        self.keys = keys
        self.displayShortcut = displayShortcut ?? keys.joined()
        self.isKeyboardShortcut = isKeyboardShortcut
    }
}

/// Single source of truth for all AetherTerm keyboard shortcuts, avoiding conflicts and drift.
public enum ApexShortcutRegistry {
    public static let allEntries: [ApexShortcutDefinition] = [
        // MARK: - Navigation & Global Tools
        ApexShortcutDefinition(
            actionKey: .commandPalette,
            category: .navigation,
            title: "命令面板",
            description: "全局快速搜索与命令面板 (Command Palette)",
            keys: ["⌘", "P"]
        ),
        ApexShortcutDefinition(
            actionKey: .openProcessInspector,
            category: .navigation,
            title: "进程监视",
            description: "远程进程与服务可视化监视控制中心 (Process Inspector)",
            keys: ["⌘", "⌥", "K"]
        ),
        ApexShortcutDefinition(
            actionKey: .copyLastCommandOutput,
            category: .navigation,
            title: "复制上条命令输出",
            description: "精准提取并复制上一条命令输出 (Copy Last Command Output)",
            keys: ["⌘", "⌥", "C"]
        ),
        ApexShortcutDefinition(
            actionKey: .openTunnels,
            category: .navigation,
            title: "SSH 端口转发与隧道管理",
            description: "SSH 端口转发与隧道管理 (Port Forwarding)",
            keys: ["⌘", "⌥", "T"]
        ),
        ApexShortcutDefinition(
            actionKey: .openBatchOperations,
            category: .navigation,
            title: "批量执行命令 / 分发文件",
            description: "批量执行命令与多主机文件分发 (Batch Operations)",
            keys: ["⌘", "⌥", "B"]
        ),
        ApexShortcutDefinition(
            actionKey: .toggleQuickCommandBar,
            category: .navigation,
            title: "显示 / 隐藏底部快捷命令栏",
            description: "显示 / 隐藏底部快捷命令栏 (Quick Command Bar)",
            keys: ["⌘", "⇧", "B"]
        ),
        ApexShortcutDefinition(
            actionKey: .toggleSFTP,
            category: .navigation,
            title: "显示 / 隐藏 SFTP 文件管理面板",
            description: "显示 / 隐藏 SFTP 文件管理面板 (Toggle SFTP Panel)",
            keys: ["⌘", "⌥", "S"]
        ),
        ApexShortcutDefinition(
            actionKey: .lockApp,
            category: .navigation,
            title: "锁定应用",
            description: "立即锁定应用并遮罩会话 (Lock App)",
            keys: ["⌘", "⇧", "L"]
        ),
        ApexShortcutDefinition(
            actionKey: .showMainWindow,
            category: .navigation,
            title: "显示主窗口",
            description: "唤起或恢复主工作区窗口 (Show Main Window)",
            keys: ["⌘", "⇧", "0"]
        ),

        // MARK: - Tabs & Sessions
        ApexShortcutDefinition(
            actionKey: .duplicateSession,
            category: .tabs,
            title: "复制当前会话 / 新建标签页",
            description: "复制当前会话 / 新建标签页",
            keys: ["⌘", "T"]
        ),
        ApexShortcutDefinition(
            actionKey: .newLocalTerminal,
            category: .tabs,
            title: "新建本地终端",
            description: "新建本地终端 (Local Terminal)",
            keys: ["⌘", "⇧", "T"]
        ),
        ApexShortcutDefinition(
            actionKey: .nextTab,
            category: .tabs,
            title: "下一个标签页",
            description: "切换至下一个标签页 (Next Tab)",
            keys: ["⌘", "⇧", "]"]
        ),
        ApexShortcutDefinition(
            actionKey: .previousTab,
            category: .tabs,
            title: "上一个标签页",
            description: "切换至上一个标签页 (Previous Tab)",
            keys: ["⌘", "⇧", "["]
        ),
        ApexShortcutDefinition(
            actionKey: .closeCurrentTabOrPane,
            category: .tabs,
            title: "关闭当前标签页或分屏",
            description: "关闭当前终端标签、当前活动分屏或弹窗",
            keys: ["⌘", "W"]
        ),
        ApexShortcutDefinition(
            actionKey: .switchTabByNumber,
            category: .tabs,
            title: "按编号切换标签页",
            description: "快速切换至指定编号的标签页",
            keys: ["⌘", "1...9"]
        ),
        ApexShortcutDefinition(
            actionKey: .tabContextMenu,
            category: .tabs,
            title: "标签右键菜单",
            description: "重命名会话、复制会话、分屏、关闭其他/右侧标签",
            keys: ["标签右键"],
            isKeyboardShortcut: false
        ),

        // MARK: - Split Panes
        ApexShortcutDefinition(
            actionKey: .splitVertical,
            category: .splitPanes,
            title: "垂直分屏 (左/右)",
            description: "垂直分屏 (左右并排)",
            keys: ["⌘", "D"]
        ),
        ApexShortcutDefinition(
            actionKey: .splitHorizontal,
            category: .splitPanes,
            title: "水平分屏 (上/下)",
            description: "水平分屏 (上下并列)",
            keys: ["⌘", "⇧", "D"]
        ),
        ApexShortcutDefinition(
            actionKey: .toggleMaximize,
            category: .splitPanes,
            title: "全屏放大 / 恢复分屏",
            description: "全屏放大 / 恢复当前分屏 (Zoom Split Pane)",
            keys: ["⌘", "⇧", "↵"]
        ),
        ApexShortcutDefinition(
            actionKey: .focusPane,
            category: .splitPanes,
            title: "切换分屏焦点",
            description: "在分屏窗格间循环切换焦点",
            keys: ["⌘", "⌥", "← / → / ↑ / ↓"]
        ),

        // MARK: - Terminal Stream & Actions
        ApexShortcutDefinition(
            actionKey: .reconnectSession,
            category: .terminal,
            title: "重新连接当前会话",
            description: "重新连接当前会话",
            keys: ["⌘", "R"]
        ),
        ApexShortcutDefinition(
            actionKey: .find,
            category: .terminal,
            title: "查找",
            description: "在终端、编辑器与文件列表中快速搜索",
            keys: ["⌘", "F"]
        ),
        ApexShortcutDefinition(
            actionKey: .findNext,
            category: .terminal,
            title: "查找下一个",
            description: "跳转至下一个搜索匹配项 (Find Next)",
            keys: ["⌘", "G"]
        ),
        ApexShortcutDefinition(
            actionKey: .findPrevious,
            category: .terminal,
            title: "查找上一个",
            description: "跳转至上一个搜索匹配项 (Find Previous)",
            keys: ["⌘", "⇧", "G"]
        ),
        ApexShortcutDefinition(
            actionKey: .jumpPrompt,
            category: .terminal,
            title: "跳转命令提示符",
            description: "跳转上一条 / 下一条命令提示符 (OSC 133)",
            keys: ["⌘", "↑ / ↓"]
        ),
        ApexShortcutDefinition(
            actionKey: .clearScrollback,
            category: .terminal,
            title: "清除当前终端屏幕与回滚缓冲区",
            description: "彻底清屏并重置回滚历史（非全屏应用模式）",
            keys: ["⌘", "K"]
        ),
        ApexShortcutDefinition(
            actionKey: .sendSIGINT,
            category: .terminal,
            title: "发送中断信号",
            description: "发送中断信号 (SIGINT)",
            keys: ["⌃", "C"]
        ),
        ApexShortcutDefinition(
            actionKey: .sendEOF,
            category: .terminal,
            title: "发送 EOF",
            description: "发送 EOF / 登出当前 Shell",
            keys: ["⌃", "D"]
        ),
        ApexShortcutDefinition(
            actionKey: .sendSIGTSTP,
            category: .terminal,
            title: "挂起后台任务",
            description: "挂起后台任务 (SIGTSTP)",
            keys: ["⌃", "Z"]
        ),
        ApexShortcutDefinition(
            actionKey: .clearTerminalLine,
            category: .terminal,
            title: "清空终端屏幕",
            description: "向远端发送清屏信号 (Ctrl+L)",
            keys: ["⌃", "L"]
        ),
        ApexShortcutDefinition(
            actionKey: .selectAllTerminal,
            category: .terminal,
            title: "全选终端文本",
            description: "全选终端缓冲区内容",
            keys: ["⌘", "A"]
        ),
        ApexShortcutDefinition(
            actionKey: .copyTerminal,
            category: .terminal,
            title: "复制选中文本",
            description: "复制选中文本",
            keys: ["⌘", "C"]
        ),
        ApexShortcutDefinition(
            actionKey: .pasteTerminal,
            category: .terminal,
            title: "粘贴剪贴板内容",
            description: "粘贴剪贴板内容",
            keys: ["⌘", "V"]
        ),
        ApexShortcutDefinition(
            actionKey: .terminalFontZoom,
            category: .terminal,
            title: "调整终端字号",
            description: "放大、缩小或重置终端字号",
            keys: ["⌘", "+ / − / 0"]
        ),
        ApexShortcutDefinition(
            actionKey: .toggleFullScreen,
            category: .terminal,
            title: "切换全屏模式",
            description: "进入或退出 macOS 原生全屏模式",
            keys: ["⌘", "⌃", "F"]
        ),

        // MARK: - SFTP
        ApexShortcutDefinition(
            actionKey: .focusSFTPPath,
            category: .sftp,
            title: "聚焦远程路径",
            description: "快速聚焦远程路径输入框",
            keys: ["⌘", "L"]
        ),
        ApexShortcutDefinition(
            actionKey: .sftpRemoteSearch,
            category: .sftp,
            title: "SFTP 远端搜索",
            description: "在远端目录按文件名或内容搜索 (SFTP)",
            keys: ["⌘", "⇧", "F"]
        ),
        ApexShortcutDefinition(
            actionKey: .toggleHiddenFiles,
            category: .sftp,
            title: "显示 / 隐藏隐藏文件",
            description: "切换显示 / 隐藏点开头的隐藏文件 (.dotfile)",
            keys: ["⌘", "⇧", "."]
        ),
        ApexShortcutDefinition(
            actionKey: .sftpBookmarks,
            category: .sftp,
            title: "SFTP 书签",
            description: "快速跳转 ~、/var/log、/etc、/tmp 或收藏当前目录",
            keys: ["书签图标"],
            isKeyboardShortcut: false
        ),
        ApexShortcutDefinition(
            actionKey: .sftpDragDrop,
            category: .sftp,
            title: "文件拖拽上传",
            description: "直接将本地文件拖拽至终端或 SFTP 面板上传",
            keys: ["文件拖拽"],
            isKeyboardShortcut: false
        ),

        // MARK: - Mouse
        ApexShortcutDefinition(
            actionKey: .mouseCopyOnSelect,
            category: .mouse,
            title: "划选自动复制",
            description: "自动复制到系统剪贴板",
            keys: ["鼠标划选"],
            isKeyboardShortcut: false
        ),
        ApexShortcutDefinition(
            actionKey: .mouseRightClickPaste,
            category: .mouse,
            title: "右键粘贴",
            description: "直接粘贴系统剪贴板内容",
            keys: ["鼠标右键"],
            isKeyboardShortcut: false
        ),
        ApexShortcutDefinition(
            actionKey: .mouseShiftRightClickMenu,
            category: .mouse,
            title: "右键上下文菜单",
            description: "弹出完整右键上下文菜单",
            keys: ["⇧ + 右键"],
            isKeyboardShortcut: false
        ),

        // MARK: - App & Preferences
        ApexShortcutDefinition(
            actionKey: .openSettings,
            category: .app,
            title: "打开偏好设置",
            description: "打开偏好设置 (外观/字体/SFTP/备份)",
            keys: ["⌘", ","]
        ),
        ApexShortcutDefinition(
            actionKey: .openShortcuts,
            category: .app,
            title: "快捷键速查清单",
            description: "打开此快捷键速查表",
            keys: ["⌘", "/"]
        ),
        ApexShortcutDefinition(
            actionKey: .quitApp,
            category: .app,
            title: "退出 AetherTerm",
            description: "退出 AetherTerm",
            keys: ["⌘", "Q"]
        )
    ]

    public static var keyboardShortcuts: [ApexShortcutDefinition] {
        allEntries.filter(\.isKeyboardShortcut)
    }

    public static func entries(in category: ApexShortcutCategory) -> [ApexShortcutDefinition] {
        allEntries.filter { $0.category == category }
    }

    public static func entry(for actionKey: ApexShortcutActionKey) -> ApexShortcutDefinition? {
        allEntries.first { $0.actionKey == actionKey }
    }

    public static func shortcutHint(for actionKey: ApexShortcutActionKey) -> String? {
        entry(for: actionKey)?.displayShortcut
    }

    public static func normalizedKeySignature(_ keys: [String]) -> String {
        keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "+")
    }

    /// Returns groups of keyboard shortcuts that share the exact same key combination (should always be empty).
    public static func duplicateKeyboardShortcuts() -> [[ApexShortcutDefinition]] {
        let grouped = Dictionary(grouping: keyboardShortcuts) { normalizedKeySignature($0.keys) }
        return grouped.values.filter { $0.count > 1 }
    }
}
