import SwiftUI
import AppKit
import ApexCore
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
                Picker(L10n.bellSettings, selection: $settings.bellMode) {
                    ForEach(TerminalBellMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("系统通知与提示音")
            }
            
            Section {
                ApexActionButton(
                    "恢复所有默认设置",
                    icon: "arrow.counterclockwise",
                    tint: ApexStyle.error,
                    size: .small
                ) {
                    settings.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
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
                                    .background(Color.accentColor.opacity(0.15))
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
                Toggle("窗口外观跟随系统", isOn: $settings.followsSystemAppearance)
                Text("跟随系统时，窗口使用系统明暗外观；终端保留所选配色。")
                    .font(.caption)
                    .foregroundStyle(ApexStyle.secondary)
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
                    
                    HStack(spacing: 4) {
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
            } header: {
                Text(L10n.settingsTabBehavior)
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
                Toggle("启用终端会话自动审计记录", isOn: $settings.isSessionLoggingEnabled)
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
                            let url = URL(fileURLWithPath: settings.sessionLogDirectory, isDirectory: true)
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
            } header: {
                Text("会话审计与日志记录")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab 4: SFTP
private struct SFTPSettingsTab: View {
    @ObservedObject var settings: AppSettings
    
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
        }
        .formStyle(.grouped)
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
    @State private var alertMessage: String?
    @State private var isShowingAlert = false
    @State private var isSyncingAction = false
    
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
                                .foregroundColor(ApexStyle.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
                    
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
                            runForceUpload()
                        }
                        .disabled(isSyncingAction)
                        
                        ApexActionButton(
                            "下载覆盖本地",
                            icon: "arrow.down.circle",
                            tint: ApexStyle.accent,
                            size: .small
                        ) {
                            runForceDownload()
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
                    
                    HStack(spacing: 12) {
                        ApexActionButton(
                            L10n.exportButton,
                            icon: "square.and.arrow.up",
                            tint: ApexStyle.secondary,
                            size: .small
                        ) {
                            exportSessions()
                        }
                        
                        ApexActionButton(
                            L10n.importButton,
                            icon: "square.and.arrow.down",
                            tint: ApexStyle.secondary,
                            size: .small
                        ) {
                            importSessions()
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
        .alert(alertMessage ?? "", isPresented: $isShowingAlert) {
            Button("好的", role: .cancel) {}
        }
    }
    
    private var statusIndicatorColor: Color {
        switch syncManager.syncStatus {
        case .idle: return .gray.opacity(0.7)
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
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
    
    private func runManualSync() {
        isSyncingAction = true
        Task {
            do {
                let res = try await syncManager.syncNow()
                await MainActor.run {
                    isSyncingAction = false
                    alertMessage = res.message
                    isShowingAlert = true
                }
            } catch {
                await MainActor.run {
                    isSyncingAction = false
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
                let old = syncManager.conflictStrategy
                syncManager.conflictStrategy = .overwriteCloud
                let res = try await syncManager.syncNow()
                syncManager.conflictStrategy = old
                await MainActor.run {
                    isSyncingAction = false
                    alertMessage = res.message
                    isShowingAlert = true
                }
            } catch {
                await MainActor.run {
                    isSyncingAction = false
                    alertMessage = error.localizedDescription
                    isShowingAlert = true
                }
            }
        }
    }
    
    private func runForceDownload() {
        isSyncingAction = true
        Task {
            do {
                let old = syncManager.conflictStrategy
                syncManager.conflictStrategy = .overwriteLocal
                let res = try await syncManager.syncNow()
                syncManager.conflictStrategy = old
                await MainActor.run {
                    isSyncingAction = false
                    alertMessage = res.message
                    isShowingAlert = true
                }
            } catch {
                await MainActor.run {
                    isSyncingAction = false
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
                alertMessage = L10n.exportSuccess
                isShowingAlert = true
            } catch {
                alertMessage = "导出失败: \(error.localizedDescription)"
                isShowingAlert = true
            }
        }
    }
    
    private func importSessions() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "导入"
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            do {
                let data = try Data(contentsOf: url)
                let count = try SessionStore.shared.importSessionsJSON(from: data, overwrite: false)
                alertMessage = String(format: L10n.importSuccess, count)
                isShowingAlert = true
            } catch {
                alertMessage = L10n.importFailure
                isShowingAlert = true
            }
        }
    }
}
