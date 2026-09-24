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
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 350)
            } detail: {
                WorkspaceView(
                    store: sessionStore,
                    activeTabs: $activeTabs,
                    selectedTabId: $selectedTabId
                )
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 960, minHeight: 640)
            .onAppear {
                // Automatically connect to first demo session on launch
                if let first = sessionStore.sessions.first, activeTabs.isEmpty {
                    connectToSession(first)
                }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal Tab") {
                    if let selected = selectedSidebarSession ?? sessionStore.sessions.first {
                        connectToSession(selected)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            
            CommandMenu("Session") {
                Button("Disconnect Current") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        Task { await current.sshClient.disconnect() }
                        activeTabs.removeAll(where: { $0.id == current.id })
                        selectedTabId = activeTabs.first?.id
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                
                Divider()
                
                Button("Clear Scrollback Buffer") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.ringBuffer.clear()
                    }
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
    
    private func connectToSession(_ session: Session) {
        // Use MockSSHSession for instantaneous offline simulation or NativeSSHSession
        let client: SSHSessionProtocol
        if session.host == "10.0.1.10" || session.host.hasPrefix("192.168.") || session.host.hasPrefix("172.") {
            client = MockSSHSession(session: session)
        } else {
            client = NativeSSHSession(session: session)
        }
        
        let tab = TerminalTabItem(session: session, sshClient: client)
        activeTabs.append(tab)
        selectedTabId = tab.id
        
        Task {
            try? await client.connect()
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
                try? await current.sshClient.sendInput(data)
            }
        }
    }
}
