import SwiftUI
import AppKit
import ApexCore
import ApexSSH
import ApexTerminal
import ApexUI

private struct WorkspaceCommandFocusKey: FocusedValueKey {
    typealias Value = Bool
}

private extension FocusedValues {
    var isWorkspaceWindow: Bool? {
        get { self[WorkspaceCommandFocusKey.self] }
        set { self[WorkspaceCommandFocusKey.self] = newValue }
    }
}

@MainActor
private final class ApexTermAppDelegate: NSObject, NSApplicationDelegate {
    var reopenMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            reopenMainWindow?()
            return reopenMainWindow == nil
        }
        return true
    }
}

@main
struct ApexTermApp: App {
    @NSApplicationDelegateAdaptor(ApexTermAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var sessionStore = SessionStore.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var settings = AppSettings.shared
    
    @FocusedValue(\.isWorkspaceWindow) private var isWorkspaceWindow

    @State private var activeTabs: [TerminalTabItem] = []
    @State private var selectedTabId: UUID?
    @State private var selectedSidebarSession: Session?
    
    @State private var isAboutPresented = false
    @State private var isShortcutsPresented = false
    @State private var isNewSessionPresented = false
    
    var body: some Scene {
        WindowGroup(id: "main") {
            NavigationSplitView {
                SidebarView(
                    store: sessionStore,
                    selectedSession: $selectedSidebarSession,
                    onConnect: { session in
                        connectToSession(session)
                    },
                    onRunSnippet: { snippet in
                        runSnippet(snippet)
                    }
                )
                .frame(minWidth: ApexStyle.minSidebarWidth, idealWidth: ApexStyle.idealSidebarWidth, maxWidth: ApexStyle.maxSidebarWidth)
            } detail: {
                WorkspaceView(
                    store: sessionStore,
                    activeTabs: $activeTabs,
                    selectedTabId: $selectedTabId
                )
            }
            .focusedSceneValue(\.isWorkspaceWindow, true)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                for tab in activeTabs {
                    for pane in tab.panes {
                        (pane.sshClient as? NativeSSHSession)?.terminatePTYProcess()
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .background(WindowStateView().frame(width: 0, height: 0))
            .apexTheme()
            .frame(minWidth: ApexStyle.minWindowWidth, minHeight: ApexStyle.minWindowHeight)
            .sheet(isPresented: $isAboutPresented) {
                AboutView().apexTheme()
            }
            .sheet(isPresented: $isShortcutsPresented) {
                ShortcutsSheetView().apexTheme()
            }
            .sheet(isPresented: $isNewSessionPresented) {
                SessionEditModal(session: nil) { session in
                    sessionStore.addSession(session)
                }.apexTheme()
            }
            .sheet(isPresented: $updateManager.isUpdateSheetPresented) {
                UpdateSheetView().apexTheme()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenAboutModal"))) { _ in
                isAboutPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenShortcutsModal"))) { _ in
                isShortcutsPresented = true
            }
            .onChange(of: updateManager.isUpdateSheetPresented) { _, isPresented in
                if isPresented && isAboutPresented {
                    isAboutPresented = false
                }
            }
            .task {
                appDelegate.reopenMainWindow = { showMainWindow() }
                if updateManager.distributionChannel == .direct && settings.checkForUpdatesOnLaunch && ProcessInfo.processInfo.environment["APEX_UI_TEST_REOPEN"] != "1" {
                    await updateManager.checkForUpdates(manual: false)
                }
            }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .defaultSize(width: ApexStyle.defaultWindowWidth, height: ApexStyle.defaultWindowHeight)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("显示主窗口") {
                    showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .appInfo) {
                Button(L10n.menuAbout) {
                    isAboutPresented = true
                }
                
                Button(L10n.menuCheckUpdates) {
                    if updateManager.distributionChannel == .appStore {
                        NSWorkspace.shared.open(DistributionChannel.appStoreURL)
                    } else {
                        Task {
                            await updateManager.checkForUpdates(manual: true)
                        }
                    }
                }
            }
            
            CommandGroup(replacing: .newItem) {
                Button("新建本地终端") {
                    openLocalTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                
                Button("复制当前会话 / 新建标签页") {
                    if activeTabs.contains(where: { $0.id == selectedTabId }) {
                        duplicateCurrentSession()
                    } else if let selected = selectedSidebarSession ?? sessionStore.sessions.first {
                        connectToSession(selected)
                    } else {
                        openLocalTerminal()
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                
                Divider()
                
                Button(L10n.menuExportSessions) {
                    exportSessions()
                }
                
                Button(L10n.menuImportSessions) {
                    importSessions()
                }
            }
            
            CommandGroup(after: .pasteboard) {
                Button("查找...") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable, !editor.isFieldEditor {
                        let action = NSMenuItem()
                        action.tag = NSTextFinder.Action.showFindInterface.rawValue
                        editor.performTextFinderAction(action)
                    } else {
                        NotificationCenter.default.post(name: NSNotification.Name("TriggerSFTPFind"), object: nil)
                        NotificationCenter.default.post(name: NSNotification.Name("TriggerTerminalFind"), object: nil)
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            
            CommandGroup(replacing: .saveItem) {
                Button("关闭当前窗格 / 标签页") {
                    if isWorkspaceWindow == true, NSApp.keyWindow?.sheetParent == nil,
                       NSApp.keyWindow?.attachedSheet == nil,
                       activeTabs.contains(where: { $0.id == selectedTabId }) {
                        closeCurrentConnection()
                    } else {
                        NSApplication.shared.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandMenu(L10n.menuSession) {
                Button("复制此会话到新标签页") {
                    duplicateCurrentSession()
                }
                .disabled(activeTabs.isEmpty)
                
                Divider()
                
                Button(L10n.menuDisconnect) {
                    closeCurrentConnection()
                }
                .disabled(!activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Divider()
                
                Button("垂直分屏") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.split(mode: .vertical)
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                
                Button("水平分屏") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.split(mode: .horizontal)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                
                Button("全屏放大 / 恢复分屏") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.toggleMaximizeActivePane()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled((activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Button("切换到下一个分屏窗格") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.focusNextPane()
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled((activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Button("切换到上一个分屏窗格") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.focusPreviousPane()
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled((activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Divider()

                Button("下一个标签页") {
                    selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(activeTabs.count < 2)

                Button("上一个标签页") {
                    selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(activeTabs.count < 2)
                
                Divider()
                
                Button(L10n.menuClearScrollback) {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.ringBuffer.clear()
                    }
                }
                .keyboardShortcut("k", modifiers: .command)
                
                Divider()
                
                Button("全局快速搜索与命令面板...") {
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerCommandPalette"), object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                
                Button("SSH 端口转发与隧道管理...") {
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerSSHTunnels"), object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                
                Button("显示 / 隐藏底部快捷命令栏") {
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerQuickCommandBar"), object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            
            CommandGroup(replacing: .help) {
                Button(L10n.menuShortcuts) {
                    isShortcutsPresented = true
                }
                .keyboardShortcut("/", modifiers: .command)
                
                Divider()
                
                Button(L10n.menuDocumentation) {
                    if let url = URL(string: "https://github.com/bcblr1993/ApexTerm#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Button(L10n.menuGitHubRepo) {
                    if let url = URL(string: "https://github.com/bcblr1993/ApexTerm") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Button(L10n.menuReportIssue) {
                    if let url = URL(string: "https://github.com/bcblr1993/ApexTerm/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        
        Settings {
            SettingsView().apexTheme()
                .focusedSceneValue(\.isWorkspaceWindow, false)
        }
    }

    private func showMainWindow() {
        let workspace = NSApp.windows.first(where: {
            $0.isVisible && ($0.frameAutosaveName == "ApexTerm.MainWorkspace"
                || $0.identifier?.rawValue.hasPrefix("main-") == true)
        }) ?? NSApp.windows.first(where: { $0.frameAutosaveName == "ApexTerm.MainWorkspace" })
        if let window = workspace {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: "main")
        }
    }
    
    private func exportSessions() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "aetherterm-sessions-backup.json"
        savePanel.prompt = "导出"
        if savePanel.runModal() == .OK, let url = savePanel.url {
            if let data = try? sessionStore.exportSessionsJSON() {
                try? data.write(to: url)
            }
        }
    }
    
    private func importSessions() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "导入"
        if openPanel.runModal() == .OK, let url = openPanel.url {
            if let data = try? Data(contentsOf: url) {
                _ = try? sessionStore.importSessionsJSON(from: data, overwrite: false)
            }
        }
    }
    
    private func closeCurrentConnection() {
        guard let current = activeTabs.first(where: { $0.id == selectedTabId }) else { return }
        if current.panes.count > 1, let activeId = current.activePaneId {
            current.closePane(id: activeId)
        } else {
            for pane in current.panes {
                Task { await pane.sshClient.disconnect() }
            }
            activeTabs.removeAll(where: { $0.id == current.id })
            selectedTabId = activeTabs.first?.id
        }
    }

    private func duplicateCurrentSession() {
        guard let current = activeTabs.first(where: { $0.id == selectedTabId }) else { return }
        let session = current.session
        let client = SSHClientFactory.makeClient(for: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        tab.currentRemotePath = current.currentRemotePath
        tab.isDirectoryLinkageEnabled = current.isDirectoryLinkageEnabled
        
        if let idx = activeTabs.firstIndex(where: { $0.id == current.id }) {
            activeTabs.insert(tab, at: idx + 1)
        } else {
            activeTabs.append(tab)
        }
        selectedTabId = tab.id
        tab.connect()
    }

    private func selectNextTab() {
        guard activeTabs.count > 1 else { return }
        let curIdx = activeTabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
        let nextIdx = (curIdx + 1) % activeTabs.count
        selectedTabId = activeTabs[nextIdx].id
    }

    private func selectPreviousTab() {
        guard activeTabs.count > 1 else { return }
        let curIdx = activeTabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
        let prevIdx = (curIdx - 1 + activeTabs.count) % activeTabs.count
        selectedTabId = activeTabs[prevIdx].id
    }

    private func connectToSession(_ session: Session) {
        let client = SSHClientFactory.makeClient(for: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        activeTabs.append(tab)
        selectedTabId = tab.id
        tab.connect()
    }
    
    private func openLocalTerminal() {
        let local = Session.local()
        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)
        activeTabs.append(tab)
        selectedTabId = tab.id
        tab.connect()
    }
    
    private func runSnippet(_ snippet: Snippet) {
        guard let current = activeTabs.first(where: { $0.id == selectedTabId }) else { return }
        let resolved = snippet.resolvedCommand(context: [
            "host": current.session.host,
            "user": current.session.username,
            "port": "\(current.session.port)"
        ])
        let toSend = snippet.autoExecute ? "\(resolved)\n" : resolved
        if let data = toSend.data(using: .utf8) {
            Task {
                let target = current.activePane?.sshClient ?? current.sshClient
                try? await target.sendInput(data)
            }
        }
    }
}
