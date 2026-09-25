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

/// Terminal theme presets
public enum TerminalThemePreset: String, CaseIterable, Identifiable, Sendable {
    case apexDark = "Apex Dark"
    case oledBlack = "OLED Black"
    case solarizedDark = "Solarized Dark"
    case monokai = "Monokai Pro"
    case oneDark = "One Dark"
    
    public var id: String { rawValue }
    
    public var backgroundColorHex: String {
        switch self {
        case .apexDark: return "#161922"
        case .oledBlack: return "#000000"
        case .solarizedDark: return "#002B36"
        case .monokai: return "#2D2A2E"
        case .oneDark: return "#282C34"
        }
    }
    
    public var foregroundColorHex: String {
        switch self {
        case .apexDark: return "#F0F4F8"
        case .oledBlack: return "#FFFFFF"
        case .solarizedDark: return "#839496"
        case .monokai: return "#FCFCFA"
        case .oneDark: return "#ABB2BF"
        }
    }
    
    public var cursorColorHex: String {
        switch self {
        case .apexDark: return "#38BDF8"
        case .oledBlack: return "#00FF66"
        case .solarizedDark: return "#268BD2"
        case .monokai: return "#FFD866"
        case .oneDark: return "#528BFF"
        }
    }
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
        static let themePreset = "settings.terminal.themePreset"
        static let isCopyOnSelectEnabled = "settings.terminal.copyOnSelect"
        static let isRightClickPasteEnabled = "settings.terminal.rightClickPaste"
        static let scrollbackMaxLines = "settings.terminal.scrollbackLines"
        static let bellMode = "settings.terminal.bellMode"
        static let showHiddenFiles = "settings.sftp.showHiddenFiles"
        static let sftpAutoSyncEnabled = "settings.sftp.autoSync"
        static let defaultDownloadDirectory = "settings.sftp.downloadDir"
        static let maxConcurrentTransfers = "settings.sftp.maxTransfers"
        static let checkForUpdatesOnLaunch = "settings.updates.checkOnLaunch"
    }
    
    // MARK: - Notification
    public static let didChangeNotification = Notification.Name("ApexSettingsDidChange")
    
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
    @Published public var scrollbackMaxLines: Int {
        didSet {
            defaults.set(scrollbackMaxLines, forKey: Keys.scrollbackMaxLines)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
    @Published public var bellMode: TerminalBellMode {
        didSet { defaults.set(bellMode.rawValue, forKey: Keys.bellMode) }
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
    
    // MARK: - Init
    public init() {
        let defaultDownloadPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~/Downloads"
        
        self.fontName = defaults.string(forKey: Keys.fontName) ?? "SF Mono"
        self.fontSize = defaults.object(forKey: Keys.fontSize) != nil ? defaults.double(forKey: Keys.fontSize) : 13.0
        
        if let rawShape = defaults.string(forKey: Keys.cursorShape), let shape = TerminalCursorShape(rawValue: rawShape) {
            self.cursorShape = shape
        } else {
            self.cursorShape = .bar
        }
        
        self.isCursorBlinkEnabled = defaults.object(forKey: Keys.isCursorBlinkEnabled) != nil
            ? defaults.bool(forKey: Keys.isCursorBlinkEnabled)
            : true
        
        if let rawTheme = defaults.string(forKey: Keys.themePreset), let theme = TerminalThemePreset(rawValue: rawTheme) {
            self.themePreset = theme
        } else {
            self.themePreset = .apexDark
        }
        
        self.isCopyOnSelectEnabled = defaults.object(forKey: Keys.isCopyOnSelectEnabled) != nil
            ? defaults.bool(forKey: Keys.isCopyOnSelectEnabled)
            : true
            
        self.isRightClickPasteEnabled = defaults.object(forKey: Keys.isRightClickPasteEnabled) != nil
            ? defaults.bool(forKey: Keys.isRightClickPasteEnabled)
            : true
            
        self.scrollbackMaxLines = defaults.object(forKey: Keys.scrollbackMaxLines) != nil
            ? defaults.integer(forKey: Keys.scrollbackMaxLines)
            : 10_000
            
        if let rawBell = defaults.string(forKey: Keys.bellMode), let bell = TerminalBellMode(rawValue: rawBell) {
            self.bellMode = bell
        } else {
            self.bellMode = .audible
        }
        
        self.showHiddenFiles = defaults.object(forKey: Keys.showHiddenFiles) != nil
            ? defaults.bool(forKey: Keys.showHiddenFiles)
            : true
            
        self.sftpAutoSyncEnabled = defaults.object(forKey: Keys.sftpAutoSyncEnabled) != nil
            ? defaults.bool(forKey: Keys.sftpAutoSyncEnabled)
            : true
            
        self.defaultDownloadDirectory = defaults.string(forKey: Keys.defaultDownloadDirectory) ?? defaultDownloadPath
        
        self.maxConcurrentTransfers = defaults.object(forKey: Keys.maxConcurrentTransfers) != nil
            ? defaults.integer(forKey: Keys.maxConcurrentTransfers)
            : 3
            
        self.checkForUpdatesOnLaunch = defaults.object(forKey: Keys.checkForUpdatesOnLaunch) != nil
            ? defaults.bool(forKey: Keys.checkForUpdatesOnLaunch)
            : true
    }
    
    /// Reset all settings to factory default
    public func resetToDefaults() {
        let defaultDownloadPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "~/Downloads"
        
        fontName = "SF Mono"
        fontSize = 13.0
        cursorShape = .bar
        isCursorBlinkEnabled = true
        themePreset = .apexDark
        isCopyOnSelectEnabled = true
        isRightClickPasteEnabled = true
        scrollbackMaxLines = 10_000
        bellMode = .audible
        showHiddenFiles = true
        sftpAutoSyncEnabled = true
        defaultDownloadDirectory = defaultDownloadPath
        maxConcurrentTransfers = 3
        checkForUpdatesOnLaunch = true
    }
}
