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
            .frame(minWidth: 960, minHeight: 640)
            .sheet(isPresented: $isAboutPresented) {
                AboutView()
            }
            .sheet(isPresented: $isShortcutsPresented) {
                ShortcutsSheetView()
            }
            .sheet(isPresented: $updateManager.isUpdateSheetPresented) {
                UpdateSheetView()
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
                Button(L10n.menuNewTab) {
                    if let selected = selectedSidebarSession ?? sessionStore.sessions.first {
                        connectToSession(selected)
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
            
            CommandMenu(L10n.menuSession) {
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
                    if let url = URL(string: "https://github.com/apexterm/apexterm#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Button(L10n.menuGitHubRepo) {
                    if let url = URL(string: "https://github.com/apexterm/apexterm") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Button(L10n.menuReportIssue) {
                    if let url = URL(string: "https://github.com/apexterm/apexterm/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        
        Settings {
            SettingsView()
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
    
    private func connectToSession(_ session: Session) {
        // Only synthetic demo host 10.0.1.10 uses Mock; real IPs (including 192.168.x.x Tart VMs) use NativeSSHSession
        let client: SSHSessionProtocol
        if session.host == "10.0.1.10" {
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
