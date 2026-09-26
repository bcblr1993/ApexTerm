import SwiftUI
import AppKit
import ApexCore
import ApexSSH
import ApexTerminal
import ApexUI

@main
struct ApexTermApp: App {
    @StateObject private var sessionStore = SessionStore.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var settings = AppSettings.shared
    
    @State private var activeTabs: [TerminalTabItem] = []
    @State private var selectedTabId: UUID?
    @State private var selectedSidebarSession: Session?
    
    @State private var isAboutPresented = false
    @State private var isShortcutsPresented = false
    
    var body: some Scene {
        WindowGroup {
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
                .frame(minWidth: 260, idealWidth: 290, maxWidth: 370)
            } detail: {
                WorkspaceView(
                    store: sessionStore,
                    activeTabs: $activeTabs,
                    selectedTabId: $selectedTabId
                )
            }
            .navigationSplitViewStyle(.balanced)
            .apexTheme()
            .frame(minWidth: 960, minHeight: 640)
            .sheet(isPresented: $isAboutPresented) {
                AboutView().apexTheme()
            }
            .sheet(isPresented: $isShortcutsPresented) {
                ShortcutsSheetView().apexTheme()
            }
            .sheet(isPresented: $updateManager.isUpdateSheetPresented) {
                UpdateSheetView().apexTheme()
            }
            .task {
                if settings.checkForUpdatesOnLaunch {
                    await updateManager.checkForUpdates(manual: false)
                }
            }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.menuAbout) {
                    isAboutPresented = true
                }
                
                Button(L10n.menuCheckUpdates) {
                    Task {
                        await updateManager.checkForUpdates(manual: true)
                    }
                }
            }
            
            CommandGroup(replacing: .newItem) {
                Button("复制当前会话 / 新建标签页") {
                    if activeTabs.contains(where: { $0.id == selectedTabId }) {
                        duplicateCurrentSession()
                    } else if let selected = selectedSidebarSession ?? sessionStore.sessions.first {
                        connectToSession(selected)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                
                Button("复制当前会话") {
                    duplicateCurrentSession()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                
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
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerTerminalFind"), object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            
            CommandMenu(L10n.menuSession) {
                Button("复制此会话到新标签页") {
                    duplicateCurrentSession()
                }
                .disabled(activeTabs.isEmpty)
                
                Divider()
                
                Button(L10n.menuDisconnect) {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
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
                }
                .keyboardShortcut("w", modifiers: .command)
                
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
                
                Divider()
                
                Button(L10n.menuClearScrollback) {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.ringBuffer.clear()
                    }
                }
                .keyboardShortcut("k", modifiers: .command)
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
        }
    }
    
    private func exportSessions() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "apexterm-sessions-backup.json"
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
    
    private func duplicateCurrentSession() {
        guard let current = activeTabs.first(where: { $0.id == selectedTabId }) else { return }
        let session = current.session
        let client: SSHSessionProtocol = session.host == "192.0.2.10" ? MockSSHSession(session: session) : NativeSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        tab.currentRemotePath = current.currentRemotePath
        tab.isDirectoryLinkageEnabled = current.isDirectoryLinkageEnabled
        
        if let idx = activeTabs.firstIndex(where: { $0.id == current.id }) {
            activeTabs.insert(tab, at: idx + 1)
        } else {
            activeTabs.append(tab)
        }
        selectedTabId = tab.id
        
        Task {
            tab.connectionState = .connecting(step: "正在连接")
            do {
                try await client.connect()
                tab.connectionState = client.connectionState
            } catch {
                tab.connectionState = .failed(error.localizedDescription)
            }
        }
    }

    private func connectToSession(_ session: Session) {
        // Only synthetic demo host 192.0.2.10 uses Mock; real IPs (including 192.168.x.x Tart VMs) use NativeSSHSession
        let client: SSHSessionProtocol
        if session.host == "192.0.2.10" {
            client = MockSSHSession(session: session)
        } else {
            client = NativeSSHSession(session: session)
        }
        
        let tab = TerminalTabItem(session: session, sshClient: client)
        activeTabs.append(tab)
        selectedTabId = tab.id
        
        Task {
            tab.connectionState = .connecting(step: "正在连接")
            do {
                try await client.connect()
                tab.connectionState = client.connectionState
            } catch {
                tab.connectionState = .failed(error.localizedDescription)
            }
        }
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
