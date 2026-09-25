import SwiftUI
import AppKit
import ApexCore
import ApexSSH
import ApexTerminal
import ApexUI

@main
struct ApexTermApp: App {
    @StateObject private var sessionStore = SessionStore.shared
    @State private var activeTabs: [TerminalTabItem] = []
    @State private var selectedTabId: UUID?
    @State private var selectedSidebarSession: Session?
    
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
        }
        // Keep the system-owned traffic lights and sidebar control in a compact
        // native toolbar. The full-height unified toolbar added an empty title
        // row above our own session and workspace headers.
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.menuNewTab) {
                    if let selected = selectedSidebarSession ?? sessionStore.sessions.first {
                        connectToSession(selected)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
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
