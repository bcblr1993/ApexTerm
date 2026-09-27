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
    @Published public var title: String
    @Published public var connectionState: SSHConnectionState {
        didSet {
            if oldValue != connectionState {
                onConnectionStateChanged?(connectionState)
            }
        }
    }
    public var onConnectionStateChanged: ((SSHConnectionState) -> Void)?
    
    public init(session: Session, sshClient: SSHSessionProtocol, title: String, initialState: SSHConnectionState = .connecting(step: "正在连接")) {
        self.session = session
        self.sshClient = sshClient
        self.title = title
        self.connectionState = initialState
        
        let ringBuffer = self.ringBuffer
        self.sshClient.setOutputHandler { data in
            if let text = String(data: data, encoding: .utf8) {
                ringBuffer.appendStream(text)
            } else {
                let lossy = String(decoding: data, as: UTF8.self)
                ringBuffer.appendStream(lossy)
            }
        }

        self.sshClient.setStateChangeHandler { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.connectionState = state
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
    @Published public var currentRemotePath: String {
        didSet { UserDefaults.standard.set(currentRemotePath, forKey: "workspace.remotePath.\(session.id.uuidString)") }
    }
    @Published public var isDirectoryLinkageEnabled: Bool
    @Published public var connectionState: SSHConnectionState = .connecting(step: "正在连接") {
        didSet {
            // Keep primary pane's connectionState in sync if single pane
            if let first = panes.first, panes.count == 1, first.connectionState != connectionState {
                first.connectionState = connectionState
            }
        }
    }
    @Published public var customTitle: String? = nil
    @Published public var paneSplitRatio: CGFloat = 0.5
    
    public var displayTitle: String {
        customTitle ?? session.name
    }
    
    // Split Panes
    @Published public var panes: [TerminalPaneItem] = []
    @Published public var activePaneId: UUID? {
        didSet {
            if let active = activePane {
                self.connectionState = active.connectionState
            }
        }
    }
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
        self.currentRemotePath = UserDefaults.standard.string(forKey: "workspace.remotePath.\(session.id.uuidString)")
            ?? "~"
        self.isDirectoryLinkageEnabled = session.sftpAutoSyncEnabled
        self.connectionState = .connecting(step: "正在连接")
        
        let primaryPane = TerminalPaneItem(session: session, sshClient: sshClient, title: session.name, initialState: .connecting(step: "正在连接"))
        self.panes = [primaryPane]
        self.activePaneId = primaryPane.id
        
        primaryPane.onConnectionStateChanged = { [weak self, weak primaryPane] newState in
            guard let self = self, let primaryPane = primaryPane else { return }
            if self.activePaneId == primaryPane.id && self.connectionState != newState {
                self.connectionState = newState
            }
        }

        let metricsHistory = self.metricsHistory
        self.sshClient.setMetricsHandler { snapshot in
            Task { @MainActor in
                metricsHistory.append(snapshot)
            }
        }
        
        self.sshClient.setDirectoryChangeHandler { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let needsHomeResolution = self.currentRemotePath == "~" || self.currentRemotePath.hasPrefix("~/")
                guard self.isDirectoryLinkageEnabled || needsHomeResolution else { return }
                if self.currentRemotePath != path {
                    self.currentRemotePath = path
                }
            }
        }
    }
    
    public func connect(pane: TerminalPaneItem? = nil) {
        let targetPane = pane ?? activePane ?? panes.first
        guard let p = targetPane else { return }
        p.connectionState = .connecting(step: "正在连接")
        if p.id == (activePane?.id ?? panes.first?.id) {
            self.connectionState = .connecting(step: "正在连接")
        }
        Task {
            do {
                try await p.sshClient.connect()
                p.connectionState = p.sshClient.connectionState
                if p.id == (self.activePane?.id ?? self.panes.first?.id) {
                    self.connectionState = p.sshClient.connectionState
                }
            } catch {
                p.connectionState = .failed(error.localizedDescription)
                if p.id == (self.activePane?.id ?? self.panes.first?.id) {
                    self.connectionState = .failed(error.localizedDescription)
                }
            }
        }
    }
    
    public func reconnect(pane: TerminalPaneItem) {
        connect(pane: pane)
    }

    public func reconnectAll() {
        for pane in panes {
            connect(pane: pane)
        }
    }
    
    public func split(mode: PaneSplitMode) {
        if panes.count >= 2 {
            self.splitMode = mode
            return
        }
        let newClient: SSHSessionProtocol
        if session.host == "192.0.2.10" {
            newClient = MockSSHSession(session: session)
        } else {
            newClient = NativeSSHSession(session: session)
        }
        
        let newPane = TerminalPaneItem(session: session, sshClient: newClient, title: "\(session.name) (分屏)", initialState: .connecting(step: "连接中"))
        newPane.onConnectionStateChanged = { [weak self, weak newPane] newState in
            guard let self = self, let newPane = newPane else { return }
            if self.activePaneId == newPane.id && self.connectionState != newState {
                self.connectionState = newState
            }
        }
        self.panes.append(newPane)
        self.activePaneId = newPane.id
        self.splitMode = mode
        self.paneSplitRatio = 0.5
        
        connect(pane: newPane)
    }
    
    public func closePane(id: UUID) {
        guard let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        let pane = panes[idx]
        Task { await pane.sshClient.disconnect() }
        panes.remove(at: idx)
        splitMode = .single
        paneSplitRatio = 0.5
        if let remaining = panes.first {
            remaining.title = session.name
            activePaneId = remaining.id
        }
    }
}

/// Central workspace view with tabs, terminal, SFTP split, and FinalShell live dashboard
public struct WorkspaceView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject public var store: SessionStore
    @Binding public var activeTabs: [TerminalTabItem]
    @Binding public var selectedTabId: UUID?
    
    @State private var isBroadcastActive = false
    @AppStorage("workspace.filesSplitRatio") private var storedSplitRatio: Double = 0.70
    private var splitRatioBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(min(max(storedSplitRatio, 0.2), 0.85)) },
                set: { storedSplitRatio = Double(min(max($0, 0.2), 0.85)) })
    }
    @State private var splitDragStartRatio: CGFloat?
    @AppStorage("workspace.filesVisible") private var isSFTPVisible = true
    
    // Tab Rename
    @State private var tabToRename: TerminalTabItem?
    @State private var tabRenameText: String = ""
    @State private var isShowingTabRenameAlert: Bool = false
    
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

            if !activeTabs.isEmpty {
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(activeTabs) { tab in
                                TabButton(
                                    title: tab.displayTitle,
                                    isSelected: tab.id == currentTab?.id,
                                    colorHex: tab.session.colorHex,
                                    onSelect: { selectedTabId = tab.id },
                                    onClose: { closeTab(tab) },
                                    onDuplicate: { duplicateTab(tab) },
                                    onRename: {
                                        tabToRename = tab
                                        tabRenameText = tab.customTitle ?? tab.session.name
                                        isShowingTabRenameAlert = true
                                    },
                                    onReconnect: {
                                        tab.reconnectAll()
                                    },
                                    onSplitVertical: { tab.split(mode: .vertical) },
                                    onSplitHorizontal: { tab.split(mode: .horizontal) },
                                    onCloseOthers: { closeOtherTabs(tab) },
                                    onCloseRight: { closeTabsToTheRight(tab) }
                                )
                            }
                            
                            // + Button to duplicate current session or open new tab
                            Button(action: {
                                if let cur = currentTab {
                                    duplicateTab(cur)
                                } else if let first = store.sessions.first {
                                    let client: SSHSessionProtocol = first.host == "192.0.2.10" ? MockSSHSession(session: first) : NativeSSHSession(session: first)
                                    let newTab = TerminalTabItem(session: first, sshClient: client)
                                    activeTabs.append(newTab)
                                    selectedTabId = newTab.id
                                    newTab.connect()
                                }
                            }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(ApexStyle.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(ApexStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help("复制当前会话 (⌘T)")
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
            
            // Hidden buttons for split and reconnect keyboard shortcuts
            Group {
                Button("") { currentTab?.split(mode: .vertical) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("") { currentTab?.split(mode: .horizontal) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("") {
                    if let cur = currentTab, let active = cur.activePane {
                        cur.reconnect(pane: active)
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
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
                    splitRatio: splitRatioBinding,
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
                        .foregroundColor(ApexStyle.secondary.opacity(0.8))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Divider()
            
            // Bottom Status Bar
            if let tab = currentTab {
                WorkspaceBottomStatusBar(tab: tab, showsDirectoryControls: !isSFTPVisible)
            } else {
                HStack {
                    Text(L10n.readyStatus)
                        .font(.system(size: 11))
                        .foregroundColor(ApexStyle.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(ApexStyle.surface)
            }
        }
        .navigationTitle(currentTab?.displayTitle ?? "ApexTerm")
        .navigationSubtitle(currentTab.map { "\($0.session.username)@\($0.session.host)" } ?? "SSH 与文件工作台")
        .toolbar { workspaceToolbar }
        .onChange(of: activeTabs.count) { _, count in
            if count < 2 { isBroadcastActive = false }
        }
        .alert("重命名标签页", isPresented: $isShowingTabRenameAlert) {
            TextField("标签页名称", text: $tabRenameText)
            Button("确定") {
                if let tab = tabToRename {
                    let trimmed = tabRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    tab.customTitle = trimmed.isEmpty ? nil : trimmed
                }
            }
            Button("恢复默认名称", role: .destructive) {
                tabToRename?.customTitle = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("自定义该标签页的显示名称，输入留空或恢复默认将恢复为服务器名称。")
        }
    }
    
    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        if let tab = currentTab {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: { duplicateTab(tab) }) {
                    Label("复制会话", systemImage: "plus.square.on.square")
                }
                .help("复制此会话到新标签页 (⌘T)")
                Menu {
                    Button("垂直分屏", systemImage: "rectangle.split.2x1") { tab.split(mode: .vertical) }
                    Button("水平分屏", systemImage: "rectangle.split.1x2") { tab.split(mode: .horizontal) }
                } label: {
                    Label("分屏", systemImage: "rectangle.split.2x1")
                }
                .disabled(tab.panes.count >= 2)
                .help("分屏 (⌘D / ⌘⇧D)")
            }
            ToolbarItem(placement: .primaryAction) {
                MetricCapsuleView(historyStore: tab.metricsHistory, compact: true, monitoringEnabled: tab.session.agentlessMonitorEnabled)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $isSFTPVisible) {
                    Label("文件面板", systemImage: "folder")
                }
                .toggleStyle(.button)
                .help(isSFTPVisible ? "隐藏文件面板" : "显示文件面板")
            }
        }
    }

    public func duplicateTab(_ tab: TerminalTabItem) {
        let session = tab.session
        let client: SSHSessionProtocol
        if session.host == "192.0.2.10" {
            client = MockSSHSession(session: session)
        } else {
            client = NativeSSHSession(session: session)
        }
        
        let newTab = TerminalTabItem(session: session, sshClient: client)
        newTab.currentRemotePath = tab.currentRemotePath
        newTab.isDirectoryLinkageEnabled = tab.isDirectoryLinkageEnabled
        
        if let idx = activeTabs.firstIndex(where: { $0.id == tab.id }) {
            activeTabs.insert(newTab, at: idx + 1)
        } else {
            activeTabs.append(newTab)
        }
        selectedTabId = newTab.id
        newTab.connect()
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
    
    private func closeOtherTabs(_ tab: TerminalTabItem) {
        let toClose = activeTabs.filter { $0.id != tab.id }
        for t in toClose {
            for pane in t.panes {
                Task { await pane.sshClient.disconnect() }
            }
        }
        activeTabs = [tab]
        selectedTabId = tab.id
    }
    
    private func closeTabsToTheRight(_ tab: TerminalTabItem) {
        guard let idx = activeTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let toClose = Array(activeTabs.suffix(from: idx + 1))
        for t in toClose {
            for pane in t.panes {
                Task { await pane.sshClient.disconnect() }
            }
        }
        activeTabs.removeSubrange((idx + 1)...)
        if !activeTabs.contains(where: { $0.id == selectedTabId }) {
            selectedTabId = tab.id
        }
    }
}

private struct WorkspaceActiveTabSplitView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject var tab: TerminalTabItem
    let activeTabs: [TerminalTabItem]
    let isBroadcastActive: Bool
    @Binding var isSFTPVisible: Bool
    @Binding var splitRatio: CGFloat
    @Binding var splitDragStartRatio: CGFloat?
    @State private var paneDragStartRatio: CGFloat?
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Terminal Area with Split Panes
                Group {
                    if tab.splitMode == .single || tab.panes.count < 2 {
                        if let pane = tab.panes.first {
                            PaneContainerView(pane: pane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                                .id(pane.id)
                        }
                    } else if tab.splitMode == .vertical {
                        GeometryReader { paneGeo in
                            let totalW = paneGeo.size.width
                            let leftW = max(80, min(totalW - 88, (totalW - 8) * tab.paneSplitRatio))
                            let rightW = max(80, totalW - 8 - leftW)
                            
                            HStack(spacing: 0) {
                                if let firstPane = tab.panes.first {
                                    PaneContainerView(pane: firstPane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                                        .frame(width: leftW)
                                        .id(firstPane.id)
                                }
                                
                                // Vertical draggable divider between panes
                                VStack {
                                    Spacer()
                                    Capsule().fill(ApexStyle.secondary.opacity(0.4)).frame(width: 3, height: 32)
                                    Spacer()
                                }
                                .frame(width: 8)
                                .background(ApexStyle.surface)
                                .contentShape(Rectangle())
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("左右终端分屏比例")
                                .accessibilityValue("\(Int(tab.paneSplitRatio * 100))%")
                                .accessibilityAdjustableAction { direction in
                                    switch direction {
                                    case .increment: tab.paneSplitRatio = min(0.85, tab.paneSplitRatio + 0.05)
                                    case .decrement: tab.paneSplitRatio = max(0.15, tab.paneSplitRatio - 0.05)
                                    @unknown default: break
                                    }
                                }
                                .gesture(
                                    DragGesture()
                                        .onChanged { val in
                                            let start = paneDragStartRatio ?? tab.paneSplitRatio
                                            if paneDragStartRatio == nil { paneDragStartRatio = start }
                                            let newRatio = start + val.translation.width / max(totalW - 8, 100)
                                            tab.paneSplitRatio = min(max(newRatio, 0.15), 0.85)
                                        }
                                        .onEnded { _ in paneDragStartRatio = nil }
                                )
                                
                                if tab.panes.count > 1 {
                                    let secondPane = tab.panes[1]
                                    PaneContainerView(pane: secondPane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                                        .frame(width: rightW)
                                        .id(secondPane.id)
                                }
                            }
                        }
                    } else { // horizontal split
                        GeometryReader { paneGeo in
                            let totalH = paneGeo.size.height
                            let topH = max(60, min(totalH - 68, (totalH - 8) * tab.paneSplitRatio))
                            let bottomH = max(60, totalH - 8 - topH)
                            
                            VStack(spacing: 0) {
                                if let firstPane = tab.panes.first {
                                    PaneContainerView(pane: firstPane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                                        .frame(height: topH)
                                        .id(firstPane.id)
                                }
                                
                                // Horizontal draggable divider between panes
                                HStack {
                                    Spacer()
                                    Capsule().fill(ApexStyle.secondary.opacity(0.4)).frame(width: 32, height: 3)
                                    Spacer()
                                }
                                .frame(height: 8)
                                .background(ApexStyle.surface)
                                .contentShape(Rectangle())
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("上下终端分屏比例")
                                .accessibilityValue("\(Int(tab.paneSplitRatio * 100))%")
                                .accessibilityAdjustableAction { direction in
                                    switch direction {
                                    case .increment: tab.paneSplitRatio = min(0.85, tab.paneSplitRatio + 0.05)
                                    case .decrement: tab.paneSplitRatio = max(0.15, tab.paneSplitRatio - 0.05)
                                    @unknown default: break
                                    }
                                }
                                .gesture(
                                    DragGesture()
                                        .onChanged { val in
                                            let start = paneDragStartRatio ?? tab.paneSplitRatio
                                            if paneDragStartRatio == nil { paneDragStartRatio = start }
                                            let newRatio = start + val.translation.height / max(totalH - 8, 80)
                                            tab.paneSplitRatio = min(max(newRatio, 0.15), 0.85)
                                        }
                                        .onEnded { _ in paneDragStartRatio = nil }
                                )
                                
                                if tab.panes.count > 1 {
                                    let secondPane = tab.panes[1]
                                    PaneContainerView(pane: secondPane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                                        .frame(height: bottomH)
                                        .id(secondPane.id)
                                }
                            }
                        }
                    }
                }
                .frame(height: isSFTPVisible ? geometry.size.height * splitRatio : geometry.size.height)
                
                if isSFTPVisible {
                    // Split Divider with draggable handle
                    HStack {
                        Spacer()
                        Capsule().fill(ApexStyle.secondary.opacity(0.5)).frame(width: 36, height: 3)
                        Spacer()
                    }
                    .frame(height: 8)
                    .background(ApexStyle.surface)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("终端与文件面板比例")
                    .accessibilityValue("\(Int(splitRatio * 100))%")
                    .accessibilityAdjustableAction { direction in
                        let minimum = 120.0 / max(geometry.size.height, 240)
                        let maximum = 1.0 - 100.0 / max(geometry.size.height, 240)
                        switch direction {
                        case .increment: splitRatio = min(maximum, splitRatio + 0.05)
                        case .decrement: splitRatio = max(minimum, splitRatio - 0.05)
                        @unknown default: break
                        }
                    }
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
    @ObservedObject private var themeSettings = AppSettings.shared
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
                        .fill(isFocused ? ApexStyle.accent : ApexStyle.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(pane.title)
                        .font(.system(size: 11, weight: isFocused ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(isFocused ? ApexStyle.primary : ApexStyle.secondary)
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
                .contentShape(Rectangle())
                .onTapGesture {
                    tab.activePaneId = pane.id
                }
            }
            
            ZStack {
                TerminalRepresentable(
                    ringBuffer: pane.ringBuffer,
                    isFocused: isFocused,
                    onFocus: {
                        if tab.activePaneId != pane.id {
                            tab.activePaneId = pane.id
                        }
                    },
                    onResize: { cols, rows in
                        Task {
                            try? await pane.sshClient.resizeTerminal(columns: cols, rows: rows)
                        }
                    },
                    onFileDrop: { localURL in
                        let targetDir = tab.currentRemotePath
                        let dest = targetDir.hasSuffix("/") ? "\(targetDir)\(localURL.lastPathComponent)" : "\(targetDir)/\(localURL.lastPathComponent)"
                        TransferManager.shared.enqueueUpload(session: pane.sshClient, localURL: localURL, remotePath: dest, onResult: { _ in
                            Task { @MainActor in
                                NotificationCenter.default.post(name: NSNotification.Name("SFTPDirectoryRefreshNeeded"), object: dest)
                            }
                        })
                    }
                ) { inputData in
                    if isBroadcastActive {
                        for t in activeTabs {
                            for p in t.panes {
                                p.sshClient.sendInputSync(inputData)
                            }
                        }
                    } else {
                        pane.sshClient.sendInputSync(inputData)
                    }
                }
                
                // Reconnect floating prompt on disconnect or failure
                if case .disconnected = pane.connectionState {
                    VStack {
                        HStack(spacing: 8) {
                            Circle().fill(ApexStyle.secondary).frame(width: 8, height: 8)
                            Text("会话已断开")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(ApexStyle.primary)
                            Button("重新连接 (⌘R)") {
                                tab.reconnect(pane: pane)
                            }
                            .apexProminentButton()
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ApexStyle.secondary.opacity(0.3), lineWidth: 1))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                } else if case .failed(let err) = pane.connectionState {
                    VStack {
                        HStack(spacing: 8) {
                            Circle().fill(ApexStyle.error).frame(width: 8, height: 8)
                            Text("连接失败：\(err)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(ApexStyle.error)
                                .lineLimit(1)
                            Button("重新连接 (⌘R)") {
                                tab.reconnect(pane: pane)
                            }
                            .apexProminentButton()
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ApexStyle.error.opacity(0.4), lineWidth: 1))
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                        .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused && tab.panes.count > 1 ? ApexStyle.accent.opacity(0.85) : Color.clear, lineWidth: 1.5)
        )
    }
}

private struct WorkspaceBottomStatusBar: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject var tab: TerminalTabItem
    let showsDirectoryControls: Bool
    @ObservedObject var transferManager = TransferManager.shared
    
    var body: some View {
        HStack(spacing: 16) {
            if let pane = tab.activePane ?? tab.panes.first {
                ConnectionStatusView(tab: tab, pane: pane)
            }
            
            Text("UTF-8")
                .font(.caption.monospaced())
                .foregroundColor(ApexStyle.secondary)
            
            if showsDirectoryControls {
            Toggle(isOn: $tab.isDirectoryLinkageEnabled) {
                Label(tab.isDirectoryLinkageEnabled ? L10n.linkageOn : L10n.linkageOff,
                      systemImage: tab.isDirectoryLinkageEnabled ? "link" : "link.slash")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help(tab.isDirectoryLinkageEnabled ? L10n.linkageHelpOn : L10n.linkageHelpOff)
            
            }

            if !transferManager.tasks.isEmpty {
                Divider().frame(height: 12)
                HStack(spacing: 6) {
                    Image(systemName: transferManager.activeCount > 0 ? "arrow.triangle.2.circlepath" : "arrow.up.arrow.down")
                        .font(.system(size: 10))
                        .foregroundColor(transferManager.activeCount > 0 ? ApexStyle.accent : ApexStyle.secondary)
                    if transferManager.activeCount > 0 {
                        Text("传输中 \(transferManager.activeCount) 项 · \(transferManager.formattedTotalSpeed)")
                            .font(.caption.monospaced())
                            .foregroundColor(ApexStyle.accent)
                    } else {
                        Text("传输记录 \(transferManager.tasks.count) 项")
                            .font(.caption.monospaced())
                            .foregroundColor(ApexStyle.secondary)
                    }
                }
            }
            
            Spacer()
            
            if showsDirectoryControls {
            Text("\(L10n.currentDirectory): \(tab.currentRemotePath)")
                .font(.caption.monospaced())
                .foregroundColor(ApexStyle.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(ApexStyle.surface)
    }
}

private struct ConnectionStatusView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject var tab: TerminalTabItem
    @ObservedObject var pane: TerminalPaneItem

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
        let state = pane.connectionState
        switch state {
        case .disconnected: return "已断开"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .failed(let message): return "连接失败：\(message)"
        }
    }

    private var statusColor: Color {
        let state = pane.connectionState
        switch state {
        case .disconnected: return ApexStyle.secondary
        case .connecting: return ApexStyle.warning
        case .connected: return ApexStyle.success
        case .failed: return ApexStyle.error
        }
    }
}

struct TabButton: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    let title: String
    let isSelected: Bool
    let colorHex: String?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onDuplicate: () -> Void
    let onRename: () -> Void
    let onReconnect: () -> Void
    let onSplitVertical: () -> Void
    let onSplitHorizontal: () -> Void
    let onCloseOthers: () -> Void
    let onCloseRight: () -> Void
    
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(hex: colorHex ?? "#0A84FF") ?? .blue)
                .frame(width: 6, height: 6)
            
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? ApexStyle.primary : ApexStyle.secondary)
            
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
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onRename()
            }
        )
        .contextMenu {
            Button {
                onReconnect()
            } label: {
                Label("重新连接 (⌘R)", systemImage: "arrow.clockwise")
            }
            
            Button {
                onRename()
            } label: {
                Label("重命名标签页...", systemImage: "pencil")
            }
            
            Button {
                onDuplicate()
            } label: {
                Label("复制会话", systemImage: "plus.square.on.square")
            }
            
            Divider()
            
            Button {
                onSplitVertical()
            } label: {
                Label("垂直分屏 (⌘D)", systemImage: "rectangle.split.2x1")
            }
            
            Button {
                onSplitHorizontal()
            } label: {
                Label("水平分屏 (⌘⇧D)", systemImage: "rectangle.split.1x2")
            }
            
            Divider()
            
            Button(role: .destructive) {
                onClose()
            } label: {
                Label("关闭标签页 (⌘W)", systemImage: "xmark")
            }
            
            Button {
                onCloseOthers()
            } label: {
                Label("关闭其他标签页", systemImage: "xmark.circle")
            }
            
            Button {
                onCloseRight()
            } label: {
                Label("关闭右侧标签页", systemImage: "arrow.right.to.line")
            }
        }
    }
}
