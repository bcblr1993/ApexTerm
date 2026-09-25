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
    @Published public var currentRemotePath: String
    @Published public var connectionState: SSHConnectionState = .disconnected
    
    public init(session: Session, sshClient: SSHSessionProtocol) {
        self.session = session
        self.sshClient = sshClient
        self.currentRemotePath = session.username == "root" ? "/root" : (session.username.isEmpty ? "~" : "/home/\(session.username)")
        
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
    @State private var splitRatio: CGFloat = 0.70
    @State private var splitDragStartRatio: CGFloat?
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
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentTab?.session.name ?? "工作台")
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text(currentTab.map { "\($0.session.username)@\($0.session.host)" } ?? "选择左侧会话开始连接")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if let tab = currentTab {
                    MetricCapsuleView(historyStore: tab.metricsHistory)
                }
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) { isSFTPVisible.toggle() }
                }) {
                    Label(isSFTPVisible ? "隐藏文件" : "显示文件", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(currentTab == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(ApexStyle.surface)

            if !activeTabs.isEmpty {
                HStack(spacing: 8) {
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
                        .padding(.horizontal, 12)
                    }
                }
                .frame(height: 38)
                .background(ApexStyle.subtleSurface.opacity(0.5))

                if activeTabs.count > 1 {
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
                }
            }
            
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
                            HStack {
                                Spacer()
                                Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 36, height: 3)
                                Spacer()
                            }
                                .frame(height: 8)
                                .background(ApexStyle.surface)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let start = splitDragStartRatio ?? splitRatio
                                            if splitDragStartRatio == nil { splitDragStartRatio = start }
                                            let newRatio = start + value.translation.height / geometry.size.height
                                            splitRatio = min(max(newRatio, 0.25), 0.85)
                                        }
                                        .onEnded { _ in splitDragStartRatio = nil }
                                )
                            
                            // Integrated SFTP Panel
                            SFTPView(
                                currentPath: Binding(
                                    get: { tab.currentRemotePath },
                                    set: { tab.currentRemotePath = $0 }
                                ),
                                session: tab.sshClient
                            )
                            .frame(height: max(0, geometry.size.height * (1.0 - splitRatio) - 8))
                        }
                    }
                }
            } else {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 48))
                        .foregroundColor(ApexStyle.accent)
                        .frame(width: 88, height: 88)
                        .background(ApexStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
                    Text("从会话开始")
                        .font(.title2.weight(.semibold))
                    Text("在左侧选择主机，然后点击连接按钮")
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
                    ConnectionStatusView(tab: tab)
                    
                    Text("UTF-8")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("\(L10n.currentDirectory): \(tab.currentRemotePath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(L10n.readyStatus)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(ApexStyle.surface)
        }
        .onChange(of: activeTabs.count) { _, count in
            if count < 2 { isBroadcastActive = false }
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

private struct ConnectionStatusView: View {
    @ObservedObject var tab: TerminalTabItem

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text("\(statusText) · \(tab.session.username)@\(tab.session.host):\(tab.session.port)")
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .help(statusText)
        }
    }

    private var statusText: String {
        let state = tab.connectionState
        switch state {
        case .disconnected: return "已断开"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .failed(let message): return "连接失败：\(message)"
        }
    }

    private var statusColor: Color {
        let state = tab.connectionState
        switch state {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
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
        HStack(spacing: 7) {
            Circle()
                .fill(Color(hex: colorHex ?? "#0A84FF") ?? .blue)
                .frame(width: 6, height: 6)
            
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
            
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? ApexStyle.accent.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }
}
