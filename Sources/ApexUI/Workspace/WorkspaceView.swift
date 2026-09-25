import SwiftUI
import ApexCore
import ApexSSH
import ApexTerminal

public enum PaneSplitMode: String, Sendable {
    case single
    case vertical
    case horizontal
}

@MainActor
public final class TerminalPaneItem: Identifiable, ObservableObject {
    public let id = UUID()
    public let session: Session
    public let sshClient: SSHSessionProtocol
    public let ringBuffer = TerminalRingBuffer(maxLines: 50_000)
    public let title: String
    @Published public var connectionState: SSHConnectionState = .disconnected
    
    public init(session: Session, sshClient: SSHSessionProtocol, title: String) {
        self.session = session
        self.sshClient = sshClient
        self.title = title
        
        let ringBuffer = self.ringBuffer
        self.sshClient.setOutputHandler { data in
            if let text = String(data: data, encoding: .utf8) {
                ringBuffer.appendStream(text)
            } else {
                let lossy = String(decoding: data, as: UTF8.self)
                ringBuffer.appendStream(lossy)
            }
        }
    }
}

@MainActor
public final class TerminalTabItem: Identifiable, ObservableObject {
    public let id = UUID()
    public let session: Session
    public let sshClient: SSHSessionProtocol
    public let metricsHistory = ObservableMetricsHistory()
    @Published public var currentRemotePath: String
    @Published public var isDirectoryLinkageEnabled: Bool
    @Published public var connectionState: SSHConnectionState = .disconnected
    
    // Split Panes
    @Published public var panes: [TerminalPaneItem] = []
    @Published public var activePaneId: UUID?
    @Published public var splitMode: PaneSplitMode = .single
    
    private let fallbackRingBuffer = TerminalRingBuffer(maxLines: 50_000)
    public var ringBuffer: TerminalRingBuffer {
        activePane?.ringBuffer ?? panes.first?.ringBuffer ?? fallbackRingBuffer
    }
    
    public var activePane: TerminalPaneItem? {
        panes.first(where: { $0.id == activePaneId }) ?? panes.first
    }
    
    public init(session: Session, sshClient: SSHSessionProtocol) {
        self.session = session
        self.sshClient = sshClient
        self.currentRemotePath = session.username == "root" ? "/root" : (session.username.isEmpty ? "~" : "/home/\(session.username)")
        self.isDirectoryLinkageEnabled = session.sftpAutoSyncEnabled
        
        let primaryPane = TerminalPaneItem(session: session, sshClient: sshClient, title: session.name)
        self.panes = [primaryPane]
        self.activePaneId = primaryPane.id
        
        let metricsHistory = self.metricsHistory
        self.sshClient.setMetricsHandler { snapshot in
            Task { @MainActor in
                metricsHistory.append(snapshot)
            }
        }
        
        self.sshClient.setDirectoryChangeHandler { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self, self.isDirectoryLinkageEnabled else { return }
                if self.currentRemotePath != path {
                    self.currentRemotePath = path
                }
            }
        }
    }
    
    public func split(mode: PaneSplitMode) {
        guard panes.count < 2 else { return }
        let newClient: SSHSessionProtocol
        if session.host == "10.0.1.10" {
            newClient = MockSSHSession(session: session)
        } else {
            newClient = NativeSSHSession(session: session)
        }
        
        let newPane = TerminalPaneItem(session: session, sshClient: newClient, title: "\(session.name) (分屏)")
        self.panes.append(newPane)
        self.activePaneId = newPane.id
        self.splitMode = mode
        
        Task {
            newPane.connectionState = .connecting(step: "连接中")
            do {
                try await newClient.connect()
                newPane.connectionState = newClient.connectionState
            } catch {
                newPane.connectionState = .failed(error.localizedDescription)
            }
        }
    }
    
    public func closePane(id: UUID) {
        guard let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        let pane = panes[idx]
        Task { await pane.sshClient.disconnect() }
        panes.remove(at: idx)
        splitMode = .single
        activePaneId = panes.first?.id
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
            if let tab = currentTab {
                WorkspaceHeaderBar(tab: tab, isSFTPVisible: $isSFTPVisible)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("工作台")
                            .font(.headline)
                        Text("选择左侧会话开始连接")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(ApexStyle.surface)
            }

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
                                for pane in tab.panes {
                                    Task { try? await pane.sshClient.sendInput(data) }
                                }
                            }
                        }
                    )
                }
            }
            
            // Hidden buttons for split keyboard shortcuts
            Group {
                Button("") { currentTab?.split(mode: .vertical) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("") { currentTab?.split(mode: .horizontal) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            
            // Workspace Split: Terminal on Top, SFTP on Bottom (electerm layout)
            if let tab = currentTab {
                WorkspaceActiveTabSplitView(
                    tab: tab,
                    activeTabs: activeTabs,
                    isBroadcastActive: isBroadcastActive,
                    isSFTPVisible: $isSFTPVisible,
                    splitRatio: $splitRatio,
                    splitDragStartRatio: $splitDragStartRatio
                )
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
            if let tab = currentTab {
                WorkspaceBottomStatusBar(tab: tab)
            } else {
                HStack {
                    Text(L10n.readyStatus)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(ApexStyle.surface)
            }
        }
        .onChange(of: activeTabs.count) { _, count in
            if count < 2 { isBroadcastActive = false }
        }
    }
    
    private func closeTab(_ tab: TerminalTabItem) {
        for pane in tab.panes {
            Task { await pane.sshClient.disconnect() }
        }
        activeTabs.removeAll(where: { $0.id == tab.id })
        if selectedTabId == tab.id {
            selectedTabId = activeTabs.first?.id
        }
    }
}

private struct WorkspaceHeaderBar: View {
    @ObservedObject var tab: TerminalTabItem
    @Binding var isSFTPVisible: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.session.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(tab.session.username)@\(tab.session.host)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            
            // Split Buttons
            HStack(spacing: 4) {
                Button(action: { tab.split(mode: .vertical) }) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("垂直分屏 (⌘D)")
                .disabled(tab.panes.count >= 2)
                
                Button(action: { tab.split(mode: .horizontal) }) {
                    Image(systemName: "rectangle.split.1x2")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("水平分屏 (⌘⇧D)")
                .disabled(tab.panes.count >= 2)
            }
            
            MetricCapsuleView(historyStore: tab.metricsHistory)
            
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) { isSFTPVisible.toggle() }
            }) {
                Label(isSFTPVisible ? "隐藏文件" : "显示文件", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ApexStyle.surface)
    }
}

private struct WorkspaceActiveTabSplitView: View {
    @ObservedObject var tab: TerminalTabItem
    let activeTabs: [TerminalTabItem]
    let isBroadcastActive: Bool
    @Binding var isSFTPVisible: Bool
    @Binding var splitRatio: CGFloat
    @Binding var splitDragStartRatio: CGFloat?
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Terminal Area with Split Panes
                Group {
                    if tab.splitMode == .single || tab.panes.count < 2 {
                        if let pane = tab.panes.first {
                            PaneContainerView(pane: pane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                        }
                    } else if tab.splitMode == .vertical {
                        HStack(spacing: 4) {
                            ForEach(tab.panes) { pane in
                                PaneContainerView(pane: pane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                            }
                        }
                    } else {
                        VStack(spacing: 4) {
                            ForEach(tab.panes) { pane in
                                PaneContainerView(pane: pane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                            }
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
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let start = splitDragStartRatio ?? splitRatio
                                if splitDragStartRatio == nil { splitDragStartRatio = start }
                                let newRatio = start + value.translation.height / geometry.size.height
                                let minRatio = 120.0 / max(geometry.size.height, 240)
                                let maxRatio = 1.0 - (100.0 / max(geometry.size.height, 240))
                                splitRatio = min(max(newRatio, minRatio), maxRatio)
                            }
                            .onEnded { _ in splitDragStartRatio = nil }
                    )
                    
                    // Integrated SFTP Panel with live observed bindings
                    SFTPView(
                        currentPath: $tab.currentRemotePath,
                        isLinkageEnabled: $tab.isDirectoryLinkageEnabled,
                        session: tab.sshClient
                    )
                    .frame(height: max(0, geometry.size.height * (1.0 - splitRatio) - 8))
                }
            }
        }
    }
}

private struct PaneContainerView: View {
    @ObservedObject var pane: TerminalPaneItem
    @ObservedObject var tab: TerminalTabItem
    let activeTabs: [TerminalTabItem]
    let isBroadcastActive: Bool
    
    var isFocused: Bool {
        tab.activePaneId == pane.id
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if tab.panes.count > 1 {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isFocused ? ApexStyle.accent : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(pane.title)
                        .font(.system(size: 11, weight: isFocused ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(isFocused ? .primary : .secondary)
                    Spacer()
                    Button(action: { tab.closePane(id: pane.id) }) {
                        Label("关闭此分屏", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("关闭此分屏")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isFocused ? ApexStyle.accent.opacity(0.12) : ApexStyle.subtleSurface)
            }
            
            TerminalRepresentable(
                ringBuffer: pane.ringBuffer,
                onResize: { cols, rows in
                    Task {
                        try? await pane.sshClient.resizeTerminal(columns: cols, rows: rows)
                    }
                },
                onFileDrop: { localURL in
                    let targetDir = tab.currentRemotePath
                    let dest = targetDir.hasSuffix("/") ? "\(targetDir)\(localURL.lastPathComponent)" : "\(targetDir)/\(localURL.lastPathComponent)"
                    TransferManager.shared.enqueueUpload(session: pane.sshClient, localURL: localURL, remotePath: dest)
                }
            ) { inputData in
                Task {
                    if isBroadcastActive {
                        for t in activeTabs {
                            for p in t.panes {
                                try? await p.sshClient.sendInput(inputData)
                            }
                        }
                    } else {
                        try? await pane.sshClient.sendInput(inputData)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused && tab.panes.count > 1 ? ApexStyle.accent.opacity(0.85) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            tab.activePaneId = pane.id
        }
    }
}

private struct WorkspaceBottomStatusBar: View {
    @ObservedObject var tab: TerminalTabItem
    
    var body: some View {
        HStack(spacing: 16) {
            ConnectionStatusView(tab: tab)
            
            Text("UTF-8")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            
            Toggle(isOn: $tab.isDirectoryLinkageEnabled) {
                Label(tab.isDirectoryLinkageEnabled ? L10n.linkageOn : L10n.linkageOff,
                      systemImage: tab.isDirectoryLinkageEnabled ? "link" : "link.slash")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(tab.isDirectoryLinkageEnabled ? L10n.linkageHelpOn : L10n.linkageHelpOff)
            
            Spacer()
            
            Text("\(L10n.currentDirectory): \(tab.currentRemotePath)")
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(ApexStyle.surface)
    }
}

private struct ConnectionStatusView: View {
    @ObservedObject var tab: TerminalTabItem

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text("\(statusText) · \(tab.session.username)@\(tab.session.host):\(tab.session.port)")
                .font(.caption.monospaced())
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
                Label("关闭 \(title)", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
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
