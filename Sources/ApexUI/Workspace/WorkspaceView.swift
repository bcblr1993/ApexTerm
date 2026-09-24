import SwiftUI
import ApexCore
import ApexSSH
import ApexTerminal

@MainActor
public final class TerminalTabItem: Identifiable, ObservableObject {
    public let id = UUID()
    public let session: Session
    public let sshClient: SSHSessionProtocol
    public let ringBuffer = TerminalRingBuffer(maxLines: 50_000)
    public let metricsHistory = ObservableMetricsHistory()
    @Published public var currentRemotePath = "/root"
    @Published public var connectionState: SSHConnectionState = .disconnected
    
    public init(session: Session, sshClient: SSHSessionProtocol) {
        self.session = session
        self.sshClient = sshClient
        
        let ringBuffer = self.ringBuffer
        let metricsHistory = self.metricsHistory
        
        self.sshClient.setOutputHandler { data in
            guard let text = String(data: data, encoding: .utf8) else { return }
            ringBuffer.appendLine(text)
        }
        
        self.sshClient.setMetricsHandler { snapshot in
            Task { @MainActor in
                metricsHistory.append(snapshot)
            }
        }
        
        self.sshClient.setDirectoryChangeHandler { [weak self] path in
            Task { @MainActor [weak self] in
                self?.currentRemotePath = path
            }
        }
    }
}

/// Central workspace view with tabs, terminal, SFTP split, and FinalShell live dashboard
public struct WorkspaceView: View {
    @ObservedObject public var store: SessionStore
    @Binding public var activeTabs: [TerminalTabItem]
    @Binding public var selectedTabId: UUID?
    
    @State private var isBroadcastActive = false
    @State private var splitRatio: CGFloat = 0.65 // 65% terminal, 35% sftp
    @State private var isSFTPVisible = true
    
    public init(
        store: SessionStore,
        activeTabs: Binding<[TerminalTabItem]>,
        selectedTabId: Binding<UUID?>
    ) {
        self.store = store
        self._activeTabs = activeTabs
        self._selectedTabId = selectedTabId
    }
    
    private var currentTab: TerminalTabItem? {
        activeTabs.first(where: { $0.id == selectedTabId }) ?? activeTabs.first
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar: Tabs & Live Performance Capsule
            HStack(spacing: 8) {
                // Tab bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(activeTabs) { tab in
                            TabButton(
                                title: tab.session.name,
                                isSelected: tab.id == currentTab?.id,
                                colorHex: tab.session.colorHex,
                                onSelect: { selectedTabId = tab.id },
                                onClose: { closeTab(tab) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
                
                Spacer()
                
                // FinalShell-style live performance capsule
                if let tab = currentTab {
                    MetricCapsuleView(historyStore: tab.metricsHistory)
                        .padding(.trailing, 6)
                }
                
                // Toggle SFTP layout button
                Button(action: { withAnimation { isSFTPVisible.toggle() } }) {
                    Image(systemName: isSFTPVisible ? "rectangle.split.2x1.fill" : "rectangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(isSFTPVisible ? "Hide SFTP Panel" : "Show SFTP Panel")
                .padding(.trailing, 10)
            }
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            // Broadcast input bar (SecureCRT feature)
            BroadcastBar(
                isBroadcastActive: $isBroadcastActive,
                targetCount: activeTabs.count,
                onBroadcastSubmit: { cmd in
                    guard let data = cmd.data(using: .utf8) else { return }
                    for tab in activeTabs {
                        Task { try? await tab.sshClient.sendInput(data) }
                    }
                }
            )
            
            // Workspace Split: Terminal on Top, SFTP on Bottom (electerm layout)
            if let tab = currentTab {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        // Terminal Area
                        TerminalRepresentable(ringBuffer: tab.ringBuffer) { inputData in
                            Task {
                                if isBroadcastActive {
                                    for t in activeTabs {
                                        try? await t.sshClient.sendInput(inputData)
                                    }
                                } else {
                                    try? await tab.sshClient.sendInput(inputData)
                                }
                            }
                        }
                        .frame(height: isSFTPVisible ? geometry.size.height * splitRatio : geometry.size.height)
                        
                        if isSFTPVisible {
                            // Split Divider with draggable handle
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(height: 3)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let newRatio = (geometry.size.height * splitRatio + value.translation.height) / geometry.size.height
                                            splitRatio = min(max(newRatio, 0.25), 0.85)
                                        }
                                )
                            
                            // Integrated SFTP Panel
                            SFTPView(
                                currentPath: Binding(
                                    get: { tab.currentRemotePath },
                                    set: { tab.currentRemotePath = $0 }
                                ),
                                session: tab.sshClient
                            )
                            .frame(height: geometry.size.height * (1.0 - splitRatio) - 3)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No Active Session")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Double-click a session in the left sidebar to connect.")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.8))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Divider()
            
            // Bottom Status Bar
            HStack(spacing: 16) {
                if let tab = currentTab {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text("Connected: \(tab.session.username)@\(tab.session.host):\(tab.session.port)")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    
                    Text("UTF-8")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Text("120Hz Metal Render")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.cyan)
                    
                    Spacer()
                    
                    Text("Directory: \(tab.currentRemotePath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text("Ready")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    
    private func closeTab(_ tab: TerminalTabItem) {
        Task { await tab.sshClient.disconnect() }
        activeTabs.removeAll(where: { $0.id == tab.id })
        if selectedTabId == tab.id {
            selectedTabId = activeTabs.first?.id
        }
    }
}

struct TabButton: View {
    let title: String
    let isSelected: Bool
    let colorHex: String?
    let onSelect: () -> Void
    let onClose: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: colorHex ?? "#0A84FF") ?? .blue)
                .frame(width: 6, height: 6)
            
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
            
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}
