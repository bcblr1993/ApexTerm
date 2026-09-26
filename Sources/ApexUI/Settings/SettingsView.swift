import SwiftUI
import AppKit
import ApexCore

/// Standard macOS Preferences / Settings View
public struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    
    @State private var selectedTab: Int

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
        }
        .frame(width: 580, height: 460)
        .padding()
    }
}

// MARK: - Tab 1: General
private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var updateManager = UpdateManager.shared
    
    var body: some View {
        Form {
            Section {
                Toggle(L10n.autoCheckUpdates, isOn: $settings.checkForUpdatesOnLaunch)
                
                HStack {
                    Text("当前版本: v\(updateManager.currentVersion) (Build \(updateManager.currentBuild))")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                    
                    Spacer()
                    
                    Button(L10n.checkUpdatesNow) {
                        Task {
                            await updateManager.checkForUpdates(manual: true)
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
                Button("恢复所有默认设置", role: .destructive) {
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
    
    private let availableFonts = ["SF Mono", "Menlo", "Courier", "Monaco", "JetBrains Mono", "PingFang SC"]
    
    var body: some View {
        Form {
            Section {
                Picker(L10n.fontNameLabel, selection: $settings.fontName) {
                    ForEach(availableFonts, id: \.self) { font in
                        Text(font).tag(font)
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
                        Text("user@apexterm:~$")
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
                
                Divider()
                
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
                    
                    Button(L10n.choosePathButton) {
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
            settings.defaultDownloadDirectory = url.path
        }
    }
}

// MARK: - Tab 5: Data Backup & Migration
private struct BackupSettingsTab: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @State private var alertMessage: String?
    @State private var isShowingAlert = false
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.backupTitle)
                        .font(.headline)
                    
                    Text(L10n.backupDesc)
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                    
                    HStack(spacing: 12) {
                        Button {
                            exportSessions()
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text(L10n.exportButton)
                            }
                        }
                        
                        Button {
                            importSessions()
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text(L10n.importButton)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            } header: {
                Text("数据同步与备份")
            }
        }
        .formStyle(.grouped)
        .alert(alertMessage ?? "", isPresented: $isShowingAlert) {
            Button("好的", role: .cancel) {}
        }
    }
    
    private func exportSessions() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "apexterm-sessions-backup.json"
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
