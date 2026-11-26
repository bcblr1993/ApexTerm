import SwiftUI
import AppKit
import ApexCore
import ApexSSH
import ApexTerminal

/// Standard macOS Preferences / Settings View
public struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    
    @State private var selectedTab: Int

    /// Wide enough for all six toolbar tabs to stay visible on macOS 14–27.
    public static let contentWidth: CGFloat = 720

    public init(initialTab: Int = 0) {
        _selectedTab = State(initialValue: initialTab)
    }
    
    public var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab(settings: settings)
                .tabItem {
                    Label(L10n.settingsTabGeneral, systemImage: "gearshape")
                }
                .tag(0)
            
            AppearanceSettingsTab(settings: settings)
                .tabItem {
                    Label(L10n.settingsTabTerminal, systemImage: "character.cursor.ibeam")
                }
                .tag(1)
            
            BehaviorSettingsTab(settings: settings)
                .tabItem {
                    Label(L10n.settingsTabBehavior, systemImage: "keyboard")
                }
                .tag(2)
            
            SFTPSettingsTab(settings: settings)
                .tabItem {
                    Label(L10n.settingsTabSFTP, systemImage: "externaldrive.connected.to.line.below")
                }
                .tag(3)
            
            BackupSettingsTab()
                .tabItem {
                    Label(L10n.settingsTabData, systemImage: "externaldrive.badge.icloud")
                }
                .tag(4)
            
            SSHKeyVaultSettingsView()
                .tabItem {
                    Label("密钥保险库", systemImage: "key.fill")
                }
                .tag(5)
        }
        // Six toolbar tabs overflow into "more toolbar items" below ~700pt, hiding every tab.
        // No outer padding: grouped forms inset themselves, and padding exposed the window
        // background as a mismatched stripe around the form in dark themes.
        .frame(width: SettingsView.contentWidth, height: 512)
    }
}

// MARK: - Tab 1: General
private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var lockManager = AppLockManager.shared
    @ObservedObject private var notificationManager = DesktopNotificationManager.shared
    @ObservedObject private var externalEditManager = ExternalEditSessionManager.shared
    @State private var isShowingResetConfirm = false
    @State private var isUpdatingSecuritySetting = false
    @State private var isResettingDefaults = false
    @State private var appLockToggleError: String?

    private static let pasteboardAutoClearPresets: [(label: String, seconds: Int)] = [
        ("从不自动清除", 0),
        ("15 秒", 15),
        ("30 秒 (默认)", 30),
        ("1 分钟", 60),
        ("3 分钟", 180),
        ("5 分钟", 300)
    ]

    private static let notificationDurationPresets: [(label: String, seconds: Double)] = [
        ("立即 (0 秒)", 0),
        ("5 秒", 5),
        ("10 秒", 10),
        ("30 秒", 30),
        ("1 分钟", 60),
        ("5 分钟", 300)
    ]
    
    var body: some View {
        Form {
            Section {
                if updateManager.distributionChannel == .direct {
                    Toggle(L10n.autoCheckUpdates, isOn: $settings.checkForUpdatesOnLaunch)
                } else {
                    Text("更新由 App Store 管理")
                }
                
                HStack {
                    Text("当前版本: v\(updateManager.currentVersion) (Build \(updateManager.currentBuild))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(ApexStyle.secondary)
                    
                    Spacer()
                    
                    ApexActionButton(
                        L10n.checkUpdatesNow,
                        icon: "arrow.triangle.2.circlepath",
                        tint: ApexStyle.accent,
                        size: .small,
                        isLoading: updateManager.isChecking
                    ) {
                        if updateManager.distributionChannel == .appStore {
                            NSWorkspace.shared.open(DistributionChannel.appStoreURL)
                        } else {
                            Task {
                                await updateManager.checkForUpdates(manual: true)
                            }
                        }
                    }
                    .disabled(updateManager.isChecking)
                }
            } header: {
                Text("软件更新")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("启动时恢复上次工作区布局", isOn: $settings.restoreWorkspaceOnLaunch)
                    Text("自动恢复上次关闭前的打开标签页、分屏预设及 SFTP 目录路径（不含明文密码与私钥；若启用应用锁则在解锁后恢复）。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
            } header: {
                Text("工作区启动行为")
            }
            
            Section {
                Picker(L10n.bellSettings, selection: $settings.bellMode) {
                    ForEach(TerminalBellMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("启用桌面通知 (长命令完成 / OSC 通知)", isOn: $notificationManager.notificationsEnabled)
                    Text("当后台标签页或非激活窗口中的命令完成（或收到 OSC 9 / OSC 777 序列）时发送 macOS 系统通知。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }

                Toggle("仅在后台标签页或应用非激活时通知", isOn: $notificationManager.onlyWhenInactiveOrBackgroundTab)
                    .disabled(!notificationManager.notificationsEnabled)

                Picker("长命令通知阈值", selection: $notificationManager.minimumCommandDurationSeconds) {
                    ForEach(Self.notificationDurationPresets, id: \.seconds) { preset in
                        Text(preset.label).tag(preset.seconds)
                    }
                    if !Self.notificationDurationPresets.contains(where: { $0.seconds == notificationManager.minimumCommandDurationSeconds }) {
                        Text("\(Int(notificationManager.minimumCommandDurationSeconds)) 秒")
                            .tag(notificationManager.minimumCommandDurationSeconds)
                    }
                }
                .disabled(!notificationManager.notificationsEnabled)

                Toggle("接收终端 OSC 9 / OSC 777 通知序列", isOn: $notificationManager.notifyOnOSCSequences)
                    .disabled(!notificationManager.notificationsEnabled)

                Toggle("桌面通知附带提示音", isOn: $notificationManager.playSound)
                    .disabled(!notificationManager.notificationsEnabled)
            } header: {
                Text("系统通知与提示音")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("启用应用锁 (Touch ID / 系统密码)", isOn: Binding(
                        get: { lockManager.appLockEnabled },
                        set: { newValue in
                            guard newValue != lockManager.appLockEnabled, !isUpdatingSecuritySetting else { return }
                            isUpdatingSecuritySetting = true
                            appLockToggleError = nil
                            Task {
                                let ok = await lockManager.setAppLockEnabled(newValue)
                                isUpdatingSecuritySetting = false
                                if !ok {
                                    appLockToggleError = lockManager.lastErrorMessage ?? (newValue ? "身份验证未通过，未启用应用锁" : "身份验证未通过，无法关闭应用锁")
                                }
                            }
                        }
                    ))
                    .disabled(isUpdatingSecuritySetting)

                    if let appLockToggleError {
                        Text(appLockToggleError)
                            .font(.caption)
                            .foregroundColor(ApexStyle.error)
                    } else {
                        Text("锁定后使用毛玻璃遮罩隐藏所有终端、SFTP 文件与凭据信息。")
                            .font(.caption)
                            .foregroundColor(ApexStyle.secondary)
                    }
                }

                Picker("闲置自动锁定", selection: Binding(
                    get: { lockManager.idleTimeoutSeconds },
                    set: { newValue in
                        guard newValue != lockManager.idleTimeoutSeconds, !isUpdatingSecuritySetting else { return }
                        isUpdatingSecuritySetting = true
                        appLockToggleError = nil
                        Task {
                            let ok = await lockManager.updateIdleTimeout(newValue)
                            isUpdatingSecuritySetting = false
                            if !ok {
                                appLockToggleError = lockManager.lastErrorMessage ?? "身份验证未通过，未修改闲置自动锁定时间"
                            }
                        }
                    }
                )) {
                    Text("从不").tag(TimeInterval(0))
                    Text("1 分钟").tag(TimeInterval(60))
                    Text("5 分钟").tag(TimeInterval(300))
                    Text("15 分钟").tag(TimeInterval(900))
                    Text("30 分钟").tag(TimeInterval(1800))
                }
                .disabled(!lockManager.appLockEnabled || isUpdatingSecuritySetting)

                Toggle("应用切至后台时自动锁定", isOn: Binding(
                    get: { lockManager.lockOnAppBackground },
                    set: { newValue in
                        guard newValue != lockManager.lockOnAppBackground, !isUpdatingSecuritySetting else { return }
                        isUpdatingSecuritySetting = true
                        appLockToggleError = nil
                        Task {
                            let ok = await lockManager.setLockOnAppBackground(newValue)
                            isUpdatingSecuritySetting = false
                            if !ok {
                                appLockToggleError = lockManager.lastErrorMessage ?? "身份验证未通过，无法关闭后台自动锁定"
                            }
                        }
                    }
                ))
                .disabled(!lockManager.appLockEnabled || isUpdatingSecuritySetting)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("敏感操作二次验证 (查看密码 / 导出凭据 / 读取私钥)", isOn: Binding(
                        get: { lockManager.requireAuthForSensitiveActions },
                        set: { newValue in
                            guard newValue != lockManager.requireAuthForSensitiveActions, !isUpdatingSecuritySetting else { return }
                            isUpdatingSecuritySetting = true
                            appLockToggleError = nil
                            Task {
                                let ok = await lockManager.setRequireAuthForSensitiveActions(newValue)
                                isUpdatingSecuritySetting = false
                                if !ok {
                                    appLockToggleError = lockManager.lastErrorMessage ?? "身份验证未通过，无法关闭敏感操作二次验证"
                                }
                            }
                        }
                    ))
                    .disabled(isUpdatingSecuritySetting)
                    Text("查看已保存密码或口令、导出含凭据分享包、查看或导出保险库私钥前需验证 Touch ID 或系统密码。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker(L10n.pasteboardAutoClearLabel, selection: $settings.sensitiveClipboardAutoClearSeconds) {
                        ForEach(Self.pasteboardAutoClearPresets, id: \.seconds) { preset in
                            Text(preset.label).tag(preset.seconds)
                        }
                        if !Self.pasteboardAutoClearPresets.contains(where: { $0.seconds == settings.sensitiveClipboardAutoClearSeconds }) {
                            Text("\(settings.sensitiveClipboardAutoClearSeconds) 秒")
                                .tag(settings.sensitiveClipboardAutoClearSeconds)
                        }
                    }
                    Text("复制密码、口令或私钥时自动写入 Concealed/Transient 隐私标记，并在剪贴板未被新内容覆盖时到期自动清空。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }

                HStack {
                    Text("快捷键 ⌘⇧L 可随时手动锁定应用")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)

                    Spacer()

                    ApexActionButton(
                        "立即锁定",
                        icon: "lock.fill",
                        tint: ApexStyle.accent,
                        size: .small
                    ) {
                        lockManager.lockNow()
                    }
                }
            } header: {
                Text("安全与应用锁")
            }
            
            Section {
                ApexActionButton(
                    "恢复所有默认设置",
                    icon: "arrow.counterclockwise",
                    tint: ApexStyle.error,
                    size: .small,
                    isLoading: isResettingDefaults
                ) {
                    isShowingResetConfirm = true
                }
                .disabled(isResettingDefaults)
            }
        }
        .formStyle(.grouped)
        .alert("恢复默认设置", isPresented: $isShowingResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                guard !isResettingDefaults else { return }
                isResettingDefaults = true
                appLockToggleError = nil
                Task {
                    let authorized = await lockManager.resetAllPreferencesWithAuthentication()
                    isResettingDefaults = false
                    guard authorized else {
                        appLockToggleError = lockManager.lastErrorMessage ?? "未通过身份验证，已保留当前安全锁配置"
                        return
                    }
                    settings.resetToDefaults()
                    externalEditManager.resetPreferences()
                }
            }
        } message: {
            Text("确定要将字体、主题、操作习惯、SFTP 与安全锁偏好恢复为初始默认值吗？已保存的 SSH 会话与密钥不受影响。")
        }
    }
}

// MARK: - Tab 2: Appearance
private struct AppearanceSettingsTab: View {
    @ObservedObject var settings: AppSettings
    
    private var availableFontOptions: [TerminalFontOption] {
        let list = TerminalFontManager.shared.availableFonts()
        if !list.contains(where: { $0.familyName == settings.fontName }) {
            return [TerminalFontOption(familyName: settings.fontName)] + list
        }
        return list
    }
    
    var body: some View {
        Form {
            Section {
                Picker(L10n.fontNameLabel, selection: $settings.fontName) {
                    ForEach(availableFontOptions) { option in
                        HStack {
                            Text(option.displayName)
                            if option.isNerdFont {
                                Spacer()
                                Text("NF")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(ApexStyle.accent.opacity(0.15))
                                    .cornerRadius(3)
                            }
                        }
                        .tag(option.familyName)
                    }
                }
                
                HStack {
                    Text(L10n.fontSizeLabel)
                    Slider(value: $settings.fontSize, in: 10...22, step: 1)
                    Text("\(Int(settings.fontSize)) pt")
                        .frame(width: 45, alignment: .trailing)
                        .font(.monospacedDigit(.body)())
                }
            } header: {
                Text(L10n.fontSettings)
            }
            
            Section {
                Picker(L10n.cursorShapeLabel, selection: $settings.cursorShape) {
                    ForEach(TerminalCursorShape.allCases) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                
                Toggle(L10n.cursorBlinkLabel, isOn: $settings.isCursorBlinkEnabled)
            } header: {
                Text(L10n.cursorSettings)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("窗口外观跟随系统", isOn: $settings.followsSystemAppearance)
                    Text("跟随系统时，窗口使用系统明暗外观；终端保留所选配色。")
                        .font(.caption)
                        .foregroundStyle(ApexStyle.secondary)
                }
                Picker("全局主题", selection: $settings.themePreset) {
                    ForEach(TerminalThemePreset.selectablePresets + (TerminalThemePreset.selectablePresets.contains(settings.themePreset) ? [] : [settings.themePreset])) { preset in
                        HStack {
                            Circle()
                                .fill(Color(hex: preset.backgroundColorHex) ?? .black)
                                .frame(width: 10, height: 10)
                            Text(preset.rawValue)
                        }
                        .tag(preset)
                    }
                }
                
                // Live preview box
                VStack(alignment: .leading, spacing: 3) {
                    Text("效果实时预览:")
                        .font(.caption2)
                        .foregroundColor(ApexStyle.secondary)
                    
                    HStack(alignment: settings.cursorShape == .underline ? .bottom : .center, spacing: 4) {
                        Text("user@aetherterm:~$")
                            .foregroundColor(Color(hex: settings.themePreset.foregroundColorHex) ?? .white)
                        Text("uname -a")
                            .foregroundColor(Color(hex: settings.themePreset.palette.success) ?? .primary)
                        Rectangle()
                            .fill(Color(hex: settings.themePreset.cursorColorHex) ?? .cyan)
                            .frame(width: settings.cursorShape == .bar ? 2 : 8, height: settings.cursorShape == .underline ? 2 : 14)
                    }
                    .font(.custom(settings.fontName == "SF Mono" ? "SFMono-Regular" : settings.fontName, size: CGFloat(settings.fontSize)))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: settings.themePreset.backgroundColorHex) ?? Color(red: 0.08, green: 0.09, blue: 0.11))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ApexStyle.border, lineWidth: 1)
                    )
                }
                .padding(.top, 4)
            } header: {
                Text("界面与终端主题")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab 3: Behavior
private struct BehaviorSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var isShowingAuditLogViewer = false
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.copyOnSelectLabel, isOn: $settings.isCopyOnSelectEnabled)
                    Text(L10n.copyOnSelectDesc)
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L10n.rightClickPasteLabel, isOn: $settings.isRightClickPasteEnabled)
                    Text(L10n.rightClickPasteDesc)
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("远端剪贴板写入 (OSC 52)", selection: $settings.osc52ClipboardPolicy) {
                        ForEach(OSC52ClipboardPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    Text("允许 tmux、Neovim 等远端程序将内容写入本机剪贴板（永久禁止远端读取本机剪贴板，单次上限 100 KB）。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
            } header: {
                Text(L10n.settingsTabBehavior)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("将 Option 键作为 Meta (Esc) 键", isOn: $settings.optionAsMeta)
                    Text("开启后，Option + 按键将发送 ESC 前缀序列（如 Option+B / Option+F 词级跳转）；关闭时保留 macOS 原生符号输入。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("中文输入法自动转换全角标点", isOn: $settings.autoConvertCJKPunctuation)
                    Text("开启后，在终端中输入中文全角标点（如 ：；，。）将自动转换为半角 ASCII 标点，便于命令行与 Vim 操作。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
            } header: {
                Text("键盘与输入法")
            }
            
            Section {
                HStack {
                    Text(L10n.scrollbackBuffer)
                    Spacer()
                    Stepper("\(settings.scrollbackMaxLines) 行", value: $settings.scrollbackMaxLines, in: 1000...50000, step: 1000)
                }
            } header: {
                Text("终端缓冲区")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("意外断线自动重连", isOn: $settings.isAutoReconnectEnabled)
                    Text("当网络波动、Wi-Fi 切换或远端空闲超时导致连接非正常断开时，自动发起平滑重连（手动输入 exit / Ctrl+D 退出时不会误重连）。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("增强型双层心跳保活（防止后台休眠与 NAT 空闲断连）", isOn: $settings.isKeepAliveEnhanced)
                    Text("同时维持 SSH 传输层心跳、PTY 通道级保活与 macOS 防休眠断言，确保切换窗口或长时间静置不断线。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("启用 SSH ControlMaster 连接复用池", isOn: $settings.controlMasterPoolEnabled)
                    Text("同主机、端口、密钥与跳板机链的标签页、SFTP 传输与后台监控自动共享已认证主通道，避免重复输入密码或 2FA 验证码。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
                .onChange(of: settings.controlMasterPoolEnabled) { _, enabled in
                    SSHControlMasterPool.isPoolEnabled = enabled
                }
            } header: {
                Text("连接保活与复用")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("允许触发器自动发送响应内容 (SendResponse)", isOn: $settings.triggerAutoResponseEnabled)
                    Text("默认关闭以防止输出回显循环或误响应。开启后，仅当触发器规则启用了「发送响应」且超过冷却时间时自动向当前终端发送文本。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
            } header: {
                Text("终端触发器自动化")
            }
            
            Section {
                Toggle("启用终端会话自动审计记录", isOn: $settings.isSessionLoggingEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("自动脱敏密码、Bearer Token 与私钥块", isOn: $settings.redactSecrets)
                    Text("在审计日志落盘前自动将 PEM 私钥块、Authorization 头及密码提示后的敏感内容替换为 [REDACTED]，日志权限强制为 0o600。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
                if settings.isSessionLoggingEnabled {
                    Picker("记录格式", selection: $settings.sessionLogFormat) {
                        ForEach(SessionLogFormat.allCases, id: \.self) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("日志存储路径")
                            Text(settings.sessionLogDirectory)
                                .font(.caption)
                                .foregroundColor(ApexStyle.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        ApexActionButton(
                            "打开目录",
                            icon: "folder",
                            tint: ApexStyle.secondary,
                            size: .small
                        ) {
                            let expanded = (settings.sessionLogDirectory as NSString).expandingTildeInPath
                            let url = URL(fileURLWithPath: expanded, isDirectory: true)
                            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(url)
                        }
                    }
                    
                    HStack {
                        Text("单文件自动切分上限")
                        Spacer()
                        Stepper("\(settings.sessionLogMaxFileSizeMB) MB", value: $settings.sessionLogMaxFileSizeMB, in: 10...500, step: 10)
                    }
                }

                HStack {
                    Text("查看已记录的会话审计日志文件与内容检索")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                    Spacer()
                    ApexActionButton(
                        "审计日志查看器...",
                        icon: "doc.text.magnifyingglass",
                        tint: ApexStyle.accent,
                        size: .small
                    ) {
                        isShowingAuditLogViewer = true
                    }
                }
            } header: {
                Text("会话审计与日志记录")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingAuditLogViewer) {
            AuditLogViewerSheet(logDirectoryPath: settings.sessionLogDirectory)
                .apexTheme()
        }
    }
}

// MARK: - Tab 4: SFTP
private struct SFTPSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var externalEditManager = ExternalEditSessionManager.shared
    @State private var installedEditors: [ExternalEditorApp] = []
    
    var body: some View {
        Form {
            Section {
                Toggle(L10n.sftpShowHiddenLabel, isOn: $settings.showHiddenFiles)
                Toggle(L10n.sftpAutoSyncLabel, isOn: $settings.sftpAutoSyncEnabled)
            } header: {
                Text("文件浏览")
            }
            
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.defaultDownloadPath)
                        Text(settings.defaultDownloadDirectory)
                            .font(.caption)
                            .foregroundColor(ApexStyle.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    
                    Spacer()
                    
                    ApexActionButton(
                        L10n.choosePathButton,
                        icon: "folder.badge.gearshape",
                        tint: ApexStyle.secondary,
                        size: .small
                    ) {
                        selectDownloadDirectory()
                    }
                }
                
                HStack {
                    Text("最大并发文件传输数")
                    Spacer()
                    Stepper("\(settings.maxConcurrentTransfers)", value: $settings.maxConcurrentTransfers, in: 1...8)
                }
            } header: {
                Text("传输设置")
            }

            Section {
                Picker("首选外部编辑器", selection: $externalEditManager.preferredEditorBundleID) {
                    Text("系统默认应用").tag("")
                    ForEach(installedEditors) { editor in
                        Text(editor.name).tag(editor.bundleID)
                    }
                    if !externalEditManager.preferredEditorBundleID.isEmpty,
                       !installedEditors.contains(where: { $0.bundleID == externalEditManager.preferredEditorBundleID }) {
                        Text(ExternalEditSessionManager.displayName(forBundleID: externalEditManager.preferredEditorBundleID))
                            .tag(externalEditManager.preferredEditorBundleID)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("保存时自动上传回远端", isOn: $externalEditManager.autoUploadOnSave)
                    Text("使用外部编辑器打开远端文件后，监听本地保存（含原子重命名保存）并自动比对 SHA-256 同步回服务器；关闭标签页时自动清理临时目录。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
            } header: {
                Text("外部编辑器")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            installedEditors = ExternalEditSessionManager.installedEditors()
        }
    }
    
    private func selectDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                if DistributionChannel.current == .appStore {
                    try FileAccessStore.shared.remember(url, isDirectory: true)
                }
                settings.defaultDownloadDirectory = url.path
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法保存文件夹授权"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

// MARK: - Tab 5: Data Backup & iCloud Sync
private struct BackupSettingsTab: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject private var syncManager = iCloudSyncManager.shared
    @State private var alertTitle: String = "提示"
    @State private var alertMessage: String?
    @State private var isShowingAlert = false
    @State private var isSyncingAction = false
    @State private var pendingForceSyncAction: ForceSyncAction?
    @State private var showingGroupExportSheet = false
    @State private var showingGroupImportSheet = false
    @State private var showingSyncDiffSheet = false
    @State private var isLoadingSyncDiff = false
    @State private var syncDiffResult: iCloudSyncDiff?
    @State private var syncDiffError: String?

    private enum ForceSyncAction: String, Identifiable {
        case overwriteCloud
        case overwriteLocal
        var id: String { rawValue }
    }
    
    var body: some View {
        Form {
            // Section 1: iCloud Cloud Vault
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.fill")
                            .font(.system(size: 20))
                            .foregroundColor(ApexStyle.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud 云端多设备同步 (Cloud Vault)")
                                .font(.headline)
                            Text("将保存的 SSH 会话、快捷命令、SFTP 书签与端口转发拓扑安全同步至个人 iCloud Drive")
                                .font(.caption)
                                .foregroundColor(ApexStyle.secondary)
                        }
                    }
                    
                    Toggle("开启 iCloud 自动同步 (定时自动双向同步)", isOn: $syncManager.isAutoSyncEnabled)
                        .padding(.top, 2)
                    
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusIndicatorColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: statusIndicatorColor.opacity(0.6), radius: 3)
                        Text(statusDescription)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(ApexStyle.primary)
                        
                        Spacer()
                        
                        if let date = syncManager.lastSyncDate {
                            Text("上次同步: \(formattedDate(date))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(ApexStyle.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ApexStyle.border.opacity(0.5), lineWidth: 1)
                    )
                    
                    Picker("冲突解决策略", selection: $syncManager.conflictStrategy) {
                        ForEach(iCloudConflictStrategy.allCases, id: \.self) { strat in
                            Text(strat.rawValue).tag(strat)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    HStack(spacing: 10) {
                        ApexActionButton(
                            "立即同步",
                            icon: "arrow.triangle.2.circlepath",
                            tint: ApexStyle.accent,
                            size: .small,
                            isProminent: true,
                            isLoading: isSyncingAction
                        ) {
                            runManualSync()
                        }
                        .disabled(isSyncingAction)
                        
                        ApexActionButton(
                            "上传覆盖云端",
                            icon: "arrow.up.circle",
                            tint: ApexStyle.accent,
                            size: .small
                        ) {
                            pendingForceSyncAction = .overwriteCloud
                        }
                        .disabled(isSyncingAction)
                        
                        ApexActionButton(
                            "下载覆盖本地",
                            icon: "arrow.down.circle",
                            tint: ApexStyle.accent,
                            size: .small
                        ) {
                            pendingForceSyncAction = .overwriteLocal
                        }
                        .disabled(isSyncingAction)

                        ApexActionButton(
                            "差异预览...",
                            icon: "arrow.left.arrow.right",
                            tint: ApexStyle.secondary,
                            size: .small
                        ) {
                            showingSyncDiffSheet = true
                            loadSyncDiff()
                        }
                        .disabled(isSyncingAction)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            } header: {
                Text("iCloud 云端同步")
            }
            
            // Section 2: Local JSON Backup
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.backupTitle)
                        .font(.headline)
                    
                    Text(L10n.backupDesc)
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                    
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            ApexActionButton(
                                "导出分组分享包 (.aetherpack)",
                                icon: "shippingbox.and.arrow.backward",
                                tint: ApexStyle.accent,
                                size: .small
                            ) {
                                showingGroupExportSheet = true
                            }

                            ApexActionButton(
                                "导入分组分享包...",
                                icon: "square.and.arrow.down",
                                tint: ApexStyle.accent,
                                size: .small
                            ) {
                                showingGroupImportSheet = true
                            }
                        }

                        GridRow {
                            ApexActionButton(
                                "导出 OpenSSH Config",
                                icon: "doc.text",
                                tint: ApexStyle.secondary,
                                size: .small
                            ) {
                                exportOpenSSHConfig()
                            }

                            ApexActionButton(
                                L10n.exportButton,
                                icon: "square.and.arrow.up",
                                tint: ApexStyle.secondary,
                                size: .small
                            ) {
                                exportSessions()
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            } header: {
                Text("离线数据导入与导出")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingGroupExportSheet) {
            GroupShareExportSheet(store: SessionStore.shared) { summary in
                alertTitle = "导出完成"
                alertMessage = summary
                isShowingAlert = true
            }
            .apexTheme()
        }
        .sheet(isPresented: $showingGroupImportSheet) {
            GroupShareImportSheet(store: SessionStore.shared) { result in
                alertTitle = "导入完成"
                alertMessage = result.summaryText
                isShowingAlert = true
            }
            .apexTheme()
        }
        .sheet(isPresented: $showingSyncDiffSheet) {
            iCloudConflictDiffSheet(
                diff: syncDiffResult,
                isLoading: isLoadingSyncDiff,
                errorMessage: syncDiffError,
                onRefresh: { loadSyncDiff() },
                onApplyStrategy: { strategy in
                    runSyncWithStrategy(strategy)
                }
            )
            .apexTheme()
        }
        .alert(alertTitle, isPresented: $isShowingAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog(
            pendingForceSyncAction == .overwriteCloud ? "确认用本地配置覆盖云端？" : "确认用云端配置覆盖本地？",
            isPresented: Binding(
                get: { pendingForceSyncAction != nil },
                set: { if !$0 { pendingForceSyncAction = nil } }
            ),
            presenting: pendingForceSyncAction
        ) { action in
            Button(action == .overwriteCloud ? "上传并覆盖云端" : "下载并覆盖本地", role: .destructive) {
                pendingForceSyncAction = nil
                if action == .overwriteCloud {
                    runForceUpload()
                } else {
                    runForceDownload()
                }
            }
            Button("取消", role: .cancel) {
                pendingForceSyncAction = nil
            }
        } message: { action in
            Text(
                action == .overwriteCloud
                    ? "将使用当前设备上的会话、命令和隧道覆盖 iCloud 云端备份。"
                    : "将使用 iCloud 云端配置替换本机当前会话、命令、书签与隧道配置，不可撤销。"
            )
        }
    }
    
    private var statusIndicatorColor: Color {
        switch syncManager.syncStatus {
        case .idle: return ApexStyle.secondary.opacity(0.7)
        case .syncing: return ApexStyle.warning
        case .success: return ApexStyle.success
        case .unavailable: return ApexStyle.secondary
        case .error: return ApexStyle.error
        }
    }
    
    private var statusDescription: String {
        switch syncManager.syncStatus {
        case .idle:
            return "就绪 · 点击立即同步"
        case .syncing(let step):
            return step
        case .success(_, let count):
            return "同步成功 · 当前管理 \(count) 个会话配置"
        case .unavailable(let reason):
            return reason
        case .error(let msg):
            return "同步失败: \(msg)"
        }
    }
    
    private static let syncDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.syncDateFormatter.string(from: date)
    }
    
    private func runManualSync() {
        isSyncingAction = true
        Task {
            do {
                let res = try await syncManager.syncNow()
                await MainActor.run {
                    isSyncingAction = false
                    alertTitle = "同步状态"
                    alertMessage = res.message
                    isShowingAlert = true
                }
            } catch {
                await MainActor.run {
                    isSyncingAction = false
                    alertTitle = "同步状态"
                    alertMessage = error.localizedDescription
                    isShowingAlert = true
                }
            }
        }
    }
    
    private func runForceUpload() {
        isSyncingAction = true
        Task {
            do {
                let res = try await syncManager.syncNow(withTemporaryStrategy: .overwriteCloud)
                await MainActor.run {
                    isSyncingAction = false
                    alertTitle = "同步状态"
                    alertMessage = res.message
                    isShowingAlert = true
                }
            } catch {
                await MainActor.run {
                    isSyncingAction = false
                    alertTitle = "同步状态"
                    alertMessage = error.localizedDescription
                    isShowingAlert = true
                }
            }
        }
    }
    
    private func runForceDownload() {
        runSyncWithStrategy(.overwriteLocal)
    }

    private func loadSyncDiff() {
        isLoadingSyncDiff = true
        syncDiffError = nil
        Task {
            do {
                let diff = try await syncManager.previewDiff()
                await MainActor.run {
                    syncDiffResult = diff
                    isLoadingSyncDiff = false
                }
            } catch {
                await MainActor.run {
                    syncDiffResult = nil
                    syncDiffError = error.localizedDescription
                    isLoadingSyncDiff = false
                }
            }
        }
    }

    private func runSyncWithStrategy(_ strategy: iCloudConflictStrategy) {
        isSyncingAction = true
        Task {
            do {
                let res = try await syncManager.syncNow(withTemporaryStrategy: strategy)
                await MainActor.run {
                    isSyncingAction = false
                    alertTitle = "同步状态"
                    alertMessage = res.message
                    isShowingAlert = true
                }
            } catch {
                await MainActor.run {
                    isSyncingAction = false
                    alertTitle = "同步状态"
                    alertMessage = error.localizedDescription
                    isShowingAlert = true
                }
            }
        }
    }
    
    private func exportSessions() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "aetherterm-sessions-backup.json"
        savePanel.prompt = "导出"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                let data = try SessionStore.shared.exportSessionsJSON()
                try data.write(to: url)
                alertTitle = "导出完成"
                alertMessage = L10n.exportSuccess
                isShowingAlert = true
            } catch {
                alertTitle = "导出失败"
                alertMessage = "导出失败: \(error.localizedDescription)"
                isShowingAlert = true
            }
        }
    }

    private func exportOpenSSHConfig() {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "ssh_config"
        savePanel.prompt = "导出 OpenSSH Config"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                let configText = SessionBundleExporter.generateOpenSSHConfig(from: SessionStore.shared.sessions)
                try configText.write(to: url, atomically: true, encoding: .utf8)
                alertTitle = "导出完成"
                alertMessage = "已成功导出标准 OpenSSH Config 文件"
                isShowingAlert = true
            } catch {
                alertTitle = "导出失败"
                alertMessage = "导出 OpenSSH Config 失败: \(error.localizedDescription)"
                isShowingAlert = true
            }
        }
    }
}
