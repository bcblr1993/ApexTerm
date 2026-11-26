import Foundation
import SwiftUI
import Combine

/// Cursor visual styles
public enum TerminalCursorShape: String, CaseIterable, Identifiable, Sendable {
    case bar = "bar"
    case block = "block"
    case underline = "underline"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .bar: return "竖线 (Bar)"
        case .block: return "方块 (Block)"
        case .underline: return "下划线 (Underline)"
        }
    }
}

/// Terminal bell notification mode
public enum TerminalBellMode: String, CaseIterable, Identifiable, Sendable {
    case audible = "audible"
    case visual = "visual"
    case none = "none"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .audible: return "声音提示 (Audible)"
        case .visual: return "视觉闪烁 (Visual Flash)"
        case .none: return "静音 (Silent)"
        }
    }
}

/// Security policy for remote terminal clipboard writes (OSC 52).
/// Clipboard read queries (`OSC 52 ; c ; ?`) are always rejected regardless of policy.
public enum OSC52ClipboardPolicy: String, CaseIterable, Identifiable, Sendable {
    case deny = "deny"
    case ask = "ask"
    case allow = "allow"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deny: return "拒绝 (Deny)"
        case .ask: return "每次询问 (Ask)"
        case .allow: return "允许写入 (Allow)"
        }
    }
}

/// Terminal theme presets
public enum TerminalThemePreset: String, CaseIterable, Identifiable, Sendable {
    case nativeLight = "经典白色（默认）"
    case modern = "VS Code Dark Modern"
    case tokyo = "Tokyo Night"
    case mocha = "Catppuccin Mocha"
    case nord = "Nord"
    case dracula = "Dracula"
    case latte = "Catppuccin Latte"
    case onedark = "One Dark Pro"
    case gruvbox = "Gruvbox Dark"
    case everforest = "Everforest"
    case rosepine = "Rosé Pine"
    case solarized = "Solarized Light"
    // Preserve saved legacy presets.
    case apexDark = "Apex Dark"
    case oledBlack = "OLED Black"
    case solarizedDark = "Solarized Dark"
    case monokai = "Monokai Pro"
    case oneDark = "One Dark"
    public static let selectablePresets: [Self] = [.nativeLight, .modern, .tokyo, .mocha, .nord, .dracula, .latte, .onedark, .gruvbox, .everforest, .rosepine, .solarized]
    public var id: String { rawValue }
    public var palette: ThemePalette { ThemePalette.forPreset(self) }
    public var isDark: Bool { ![Self.nativeLight, .latte, .solarized].contains(self) }
    public var backgroundColorHex: String { palette.terminal }
    public var foregroundColorHex: String { palette.foreground }
    public var cursorColorHex: String { palette.accent }
}

/// Central application settings manager with reactive publishing and UserDefaults persistence
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    
    private let defaults = UserDefaults.standard
    
    // MARK: - Keys
    private enum Keys {
        static let fontName = "settings.terminal.fontName"
        static let fontSize = "settings.terminal.fontSize"
        static let cursorShape = "settings.terminal.cursorShape"
        static let isCursorBlinkEnabled = "settings.terminal.cursorBlink"
        // Global appearance starts white even if an older terminal-only preset was saved.
        static let themePreset = "settings.appearance.themePreset"
        static let isCopyOnSelectEnabled = "settings.terminal.copyOnSelect"
        static let isRightClickPasteEnabled = "settings.terminal.rightClickPaste"
        static let optionAsMeta = "settings.terminal.optionAsMeta"
        static let autoConvertCJKPunctuation = "settings.terminal.autoConvertCJKPunctuation"
        static let scrollbackMaxLines = "settings.terminal.scrollbackLines"
        static let bellMode = "settings.terminal.bellMode"
        static let osc52ClipboardPolicy = "settings.terminal.osc52Policy"
        static let sensitiveClipboardAutoClearSeconds = "settings.security.sensitiveClipboardAutoClearSeconds"
        static let showHiddenFiles = "settings.sftp.showHiddenFiles"
        static let sftpAutoSyncEnabled = "settings.sftp.autoSync"
        static let defaultDownloadDirectory = "settings.sftp.downloadDir"
        static let maxConcurrentTransfers = "settings.sftp.maxTransfers"
        static let checkForUpdatesOnLaunch = "settings.updates.checkOnLaunch"
        static let isSessionLoggingEnabled = "settings.logging.enabled"
        static let sessionLogFormat = "settings.logging.format"
        static let sessionLogDirectory = "settings.logging.directory"
        static let sessionLogMaxFileSizeMB = "settings.logging.maxFileSizeMB"
        static let isAutoReconnectEnabled = "settings.ssh.autoReconnect"
        static let isKeepAliveEnhanced = "settings.ssh.keepAliveEnhanced"
    }
    
    // MARK: - Notification
    public static let didChangeNotification = Notification.Name("ApexSettingsDidChange")
    public static let didResetToDefaultsNotification = Notification.Name("ApexSettingsDidResetToDefaults")
    
    // MARK: - Published Properties
    
    // Terminal Appearance
    @Published public var fontName: String {
        didSet {
            defaults.set(fontName, forKey: Keys.fontName)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: Keys.fontSize)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var cursorShape: TerminalCursorShape {
        didSet {
            defaults.set(cursorShape.rawValue, forKey: Keys.cursorShape)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var isCursorBlinkEnabled: Bool {
        didSet {
            defaults.set(isCursorBlinkEnabled, forKey: Keys.isCursorBlinkEnabled)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var themePreset: TerminalThemePreset {
        didSet {
            defaults.set(themePreset.rawValue, forKey: Keys.themePreset)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    
    @Published public var followsSystemAppearance: Bool {
        didSet {
            defaults.set(followsSystemAppearance, forKey: "settings.appearance.followSystem")
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    // Terminal Behavior
    @Published public var isCopyOnSelectEnabled: Bool {
        didSet {
            defaults.set(isCopyOnSelectEnabled, forKey: Keys.isCopyOnSelectEnabled)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var isRightClickPasteEnabled: Bool {
        didSet {
            defaults.set(isRightClickPasteEnabled, forKey: Keys.isRightClickPasteEnabled)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var optionAsMeta: Bool {
        didSet {
            defaults.set(optionAsMeta, forKey: Keys.optionAsMeta)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var autoConvertCJKPunctuation: Bool {
        didSet {
            defaults.set(autoConvertCJKPunctuation, forKey: Keys.autoConvertCJKPunctuation)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var scrollbackMaxLines: Int {
        didSet {
            defaults.set(scrollbackMaxLines, forKey: Keys.scrollbackMaxLines)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var bellMode: TerminalBellMode {
        didSet { defaults.set(bellMode.rawValue, forKey: Keys.bellMode) }
    }
    @Published public var osc52ClipboardPolicy: OSC52ClipboardPolicy {
        didSet { defaults.set(osc52ClipboardPolicy.rawValue, forKey: Keys.osc52ClipboardPolicy) }
    }
    @Published public var sensitiveClipboardAutoClearSeconds: Int {
        didSet {
            let clamped = max(0, sensitiveClipboardAutoClearSeconds)
            if clamped != sensitiveClipboardAutoClearSeconds {
                sensitiveClipboardAutoClearSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.sensitiveClipboardAutoClearSeconds)
            SensitivePasteboardHelper.shared.autoClearSeconds = TimeInterval(clamped)
        }
    }
    
    // SFTP & Files
    @Published public var showHiddenFiles: Bool {
        didSet { defaults.set(showHiddenFiles, forKey: Keys.showHiddenFiles) }
    }
    @Published public var sftpAutoSyncEnabled: Bool {
        didSet { defaults.set(sftpAutoSyncEnabled, forKey: Keys.sftpAutoSyncEnabled) }
    }
    @Published public var defaultDownloadDirectory: String {
        didSet { defaults.set(defaultDownloadDirectory, forKey: Keys.defaultDownloadDirectory) }
    }
    @Published public var maxConcurrentTransfers: Int {
        didSet { defaults.set(maxConcurrentTransfers, forKey: Keys.maxConcurrentTransfers) }
    }
    
    // Updates
    @Published public var checkForUpdatesOnLaunch: Bool {
        didSet { defaults.set(checkForUpdatesOnLaunch, forKey: Keys.checkForUpdatesOnLaunch) }
    }
    
    // Session Audit Logging
    @Published public var isSessionLoggingEnabled: Bool {
        didSet { defaults.set(isSessionLoggingEnabled, forKey: Keys.isSessionLoggingEnabled) }
    }
    @Published public var sessionLogFormat: SessionLogFormat {
        didSet { defaults.set(sessionLogFormat.rawValue, forKey: Keys.sessionLogFormat) }
    }
    @Published public var sessionLogDirectory: String {
        didSet { defaults.set(sessionLogDirectory, forKey: Keys.sessionLogDirectory) }
    }
    @Published public var sessionLogMaxFileSizeMB: Int {
        didSet { defaults.set(sessionLogMaxFileSizeMB, forKey: Keys.sessionLogMaxFileSizeMB) }
    }
    
    // Connection Keep-Alive & Auto-Reconnect
    @Published public var isAutoReconnectEnabled: Bool {
        didSet { defaults.set(isAutoReconnectEnabled, forKey: Keys.isAutoReconnectEnabled) }
    }
    @Published public var isKeepAliveEnhanced: Bool {
        didSet { defaults.set(isKeepAliveEnhanced, forKey: Keys.isKeepAliveEnhanced) }
    }
    
    // MARK: - Init
    public init() {
        let defaultDownloadPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~/Downloads"
        let defaultLogDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("AetherTerm/Logs", isDirectory: true).path ?? "~/Documents/AetherTerm/Logs"
        
        self.fontName = defaults.string(forKey: Keys.fontName) ?? "SF Mono"
        let persistedFontSize = defaults.object(forKey: Keys.fontSize) != nil ? defaults.double(forKey: Keys.fontSize) : 13.0
        self.fontSize = persistedFontSize > 0 ? persistedFontSize : 13.0
        
        if let rawShape = defaults.string(forKey: Keys.cursorShape), let shape = TerminalCursorShape(rawValue: rawShape) {
            self.cursorShape = shape
        } else {
            self.cursorShape = .bar
        }
        
        self.isCursorBlinkEnabled = defaults.object(forKey: Keys.isCursorBlinkEnabled) != nil
            ? defaults.bool(forKey: Keys.isCursorBlinkEnabled)
            : true
        
        self.followsSystemAppearance = defaults.bool(forKey: "settings.appearance.followSystem")
        if let rawTheme = defaults.string(forKey: Keys.themePreset), let theme = TerminalThemePreset(rawValue: rawTheme) {
            self.themePreset = theme
        } else {
            self.themePreset = .nativeLight
        }
        
        self.isCopyOnSelectEnabled = defaults.object(forKey: Keys.isCopyOnSelectEnabled) != nil
            ? defaults.bool(forKey: Keys.isCopyOnSelectEnabled)
            : true
            
        self.isRightClickPasteEnabled = defaults.object(forKey: Keys.isRightClickPasteEnabled) != nil
            ? defaults.bool(forKey: Keys.isRightClickPasteEnabled)
            : true

        self.optionAsMeta = defaults.object(forKey: Keys.optionAsMeta) != nil
            ? defaults.bool(forKey: Keys.optionAsMeta)
            : false

        self.autoConvertCJKPunctuation = defaults.object(forKey: Keys.autoConvertCJKPunctuation) != nil
            ? defaults.bool(forKey: Keys.autoConvertCJKPunctuation)
            : true
            
        let persistedScrollback = defaults.object(forKey: Keys.scrollbackMaxLines) != nil
            ? defaults.integer(forKey: Keys.scrollbackMaxLines)
            : 10_000
        self.scrollbackMaxLines = max(100, persistedScrollback)
            
        if let rawBell = defaults.string(forKey: Keys.bellMode), let bell = TerminalBellMode(rawValue: rawBell) {
            self.bellMode = bell
        } else {
            self.bellMode = .audible
        }

        if let rawPolicy = defaults.string(forKey: Keys.osc52ClipboardPolicy), let policy = OSC52ClipboardPolicy(rawValue: rawPolicy) {
            self.osc52ClipboardPolicy = policy
        } else {
            self.osc52ClipboardPolicy = .ask
        }

        let persistedAutoClear: Int
        if defaults.object(forKey: Keys.sensitiveClipboardAutoClearSeconds) != nil {
            persistedAutoClear = max(0, defaults.integer(forKey: Keys.sensitiveClipboardAutoClearSeconds))
        } else {
            persistedAutoClear = max(0, Int(SensitivePasteboardHelper.shared.autoClearSeconds))
        }
        self.sensitiveClipboardAutoClearSeconds = persistedAutoClear
        SensitivePasteboardHelper.shared.autoClearSeconds = TimeInterval(persistedAutoClear)
        
        self.showHiddenFiles = defaults.object(forKey: Keys.showHiddenFiles) != nil
            ? defaults.bool(forKey: Keys.showHiddenFiles)
            : true
            
        self.sftpAutoSyncEnabled = defaults.object(forKey: Keys.sftpAutoSyncEnabled) != nil
            ? defaults.bool(forKey: Keys.sftpAutoSyncEnabled)
            : true
            
        self.defaultDownloadDirectory = defaults.string(forKey: Keys.defaultDownloadDirectory) ?? defaultDownloadPath
        
        self.isSessionLoggingEnabled = defaults.bool(forKey: Keys.isSessionLoggingEnabled)
        if let rawFormat = defaults.string(forKey: Keys.sessionLogFormat), let format = SessionLogFormat(rawValue: rawFormat) {
            self.sessionLogFormat = format
        } else {
            self.sessionLogFormat = .plainText
        }
        self.sessionLogDirectory = defaults.string(forKey: Keys.sessionLogDirectory) ?? defaultLogDir
        let persistedMaxLogMB = defaults.object(forKey: Keys.sessionLogMaxFileSizeMB) != nil ? defaults.integer(forKey: Keys.sessionLogMaxFileSizeMB) : 50
        self.sessionLogMaxFileSizeMB = max(1, persistedMaxLogMB)
        
        let persistedTransfers = defaults.object(forKey: Keys.maxConcurrentTransfers) != nil
            ? defaults.integer(forKey: Keys.maxConcurrentTransfers)
            : 3
        self.maxConcurrentTransfers = max(1, persistedTransfers)
            
        self.checkForUpdatesOnLaunch = defaults.object(forKey: Keys.checkForUpdatesOnLaunch) != nil
            ? defaults.bool(forKey: Keys.checkForUpdatesOnLaunch)
            : true
            
        self.isAutoReconnectEnabled = defaults.object(forKey: Keys.isAutoReconnectEnabled) != nil
            ? defaults.bool(forKey: Keys.isAutoReconnectEnabled)
            : true
            
        self.isKeepAliveEnhanced = defaults.object(forKey: Keys.isKeepAliveEnhanced) != nil
            ? defaults.bool(forKey: Keys.isKeepAliveEnhanced)
            : true
    }
    
    /// Reset all settings to factory default
    public func resetToDefaults() {
        let defaultDownloadPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~/Downloads"
        let defaultLogDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("AetherTerm/Logs", isDirectory: true).path ?? "~/Documents/AetherTerm/Logs"
        
        fontName = "SF Mono"
        fontSize = 13.0
        cursorShape = .bar
        isCursorBlinkEnabled = true
        themePreset = .nativeLight
        followsSystemAppearance = false
        isCopyOnSelectEnabled = true
        isRightClickPasteEnabled = true
        optionAsMeta = false
        autoConvertCJKPunctuation = true
        scrollbackMaxLines = 10_000
        bellMode = .audible
        osc52ClipboardPolicy = .ask
        sensitiveClipboardAutoClearSeconds = Int(SensitivePasteboardHelper.defaultAutoClearSeconds)
        showHiddenFiles = true
        sftpAutoSyncEnabled = true
        defaultDownloadDirectory = defaultDownloadPath
        maxConcurrentTransfers = 3
        checkForUpdatesOnLaunch = true
        isSessionLoggingEnabled = false
        sessionLogFormat = .plainText
        sessionLogDirectory = defaultLogDir
        sessionLogMaxFileSizeMB = 50
        isAutoReconnectEnabled = true
        isKeepAliveEnhanced = true

        defaults.removeObject(forKey: "externalEdit.preferredEditorBundleID")
        defaults.removeObject(forKey: "externalEdit.autoUploadOnSave")
        SensitivePasteboardHelper.shared.resetPreferences()
        DesktopNotificationManager.shared.resetPreferences()
        iCloudSyncManager.shared.resetPreferences()
        AppLockManager.shared.resetNonSecurityPreferences()
        NotificationCenter.default.post(name: Self.didResetToDefaultsNotification, object: self)
    }
}
