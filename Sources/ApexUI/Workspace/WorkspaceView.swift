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
    public let ringBuffer = TerminalRingBuffer(maxLines: AppSettings.shared.scrollbackMaxLines)
    @Published public var title: String
    @Published public var connectionState: SSHConnectionState {
        didSet {
            if oldValue != connectionState {
                onConnectionStateChanged?(connectionState)
            }
        }
    }
    public var onConnectionStateChanged: ((SSHConnectionState) -> Void)?
    public private(set) var logger: SessionLogger?
    
    public init(session: Session, sshClient: SSHSessionProtocol, title: String, initialState: SSHConnectionState = .connecting(step: "正在连接")) {
        self.session = session
        self.sshClient = sshClient
        self.title = title
        self.connectionState = initialState
        
        if AppSettings.shared.isSessionLoggingEnabled {
            let config = SessionLogConfig(
                autoLoggingEnabled: true,
                logDirectoryPath: AppSettings.shared.sessionLogDirectory,
                format: AppSettings.shared.sessionLogFormat,
                maxFileSizeMB: AppSettings.shared.sessionLogMaxFileSizeMB
            )
            self.logger = SessionLogger(session: session, config: config)
        }
        
        let ringBuffer = self.ringBuffer
        let sessionLogger = self.logger
        self.sshClient.setOutputHandler { data in
            ringBuffer.appendData(data)
            sessionLogger?.appendData(data)
        }

        self.sshClient.setStateChangeHandler { [weak self] state in
            if case .disconnected = state {
                ringBuffer.finishStream()
                sessionLogger?.close()
            }
            if case .failed = state {
                ringBuffer.finishStream()
                sessionLogger?.close()
            }
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
    @Published public var isPaneMaximized: Bool = false
    
    private let fallbackRingBuffer = TerminalRingBuffer(maxLines: AppSettings.shared.scrollbackMaxLines)
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
        
        registerDirectoryLinkage(for: self.sshClient)
    }

    private var linkageRefreshTask: Task<Void, Never>? = nil

    public func scheduleDirectoryLinkageRefresh() {
        linkageRefreshTask?.cancel()
        linkageRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self = self, self.isDirectoryLinkageEnabled, !Task.isCancelled else { return }
            NotificationCenter.default.post(
                name: NSNotification.Name("SFTPDirectoryRefreshNeeded"),
                object: self.currentRemotePath
            )
        }
    }

    public func registerDirectoryLinkage(for client: SSHSessionProtocol) {
        client.setDirectoryChangeHandler { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let needsHomeResolution = self.currentRemotePath == "~" || self.currentRemotePath.hasPrefix("~/")
                guard self.isDirectoryLinkageEnabled || needsHomeResolution else { return }
                if self.currentRemotePath != path {
                    self.linkageRefreshTask?.cancel()
                    self.currentRemotePath = path
                } else if self.isDirectoryLinkageEnabled {
                    self.scheduleDirectoryLinkageRefresh()
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
                let dims = p.ringBuffer.dimensions
                try? await p.sshClient.resizeTerminal(columns: dims.columns, rows: dims.rows)
                p.connectionState = p.sshClient.connectionState
                if p.id == (self.activePane?.id ?? self.panes.first?.id) {
                    self.connectionState = p.sshClient.connectionState
                }
                
                // Auto-start configured tunnels for this session
                let autoTunnels = SSHTunnelManager.shared.tunnels(for: self.session.id).filter { $0.autoStart }
                for t in autoTunnels {
                    if !SSHTunnelManager.shared.state(for: t.id).isRunning {
                        let pw = await SSHTunnelManager.resolveSecret(for: self.session)
                        let sshpass = (self.sshClient as? NativeSSHSession)?.sshpassExecutablePath
                        try? SSHTunnelManager.shared.startTunnel(id: t.id, session: self.session, password: pw, privateKeyPath: self.session.privateKeyPath, sshpassPath: sshpass)
                    }
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
        let newClient = SSHClientFactory.makeClient(for: session)
        
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
        registerDirectoryLinkage(for: newClient)
        
        connect(pane: newPane)
    }
    
    public func closePane(id: UUID) {
        guard let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        let pane = panes[idx]
        Task { await pane.sshClient.disconnect() }
        panes.remove(at: idx)
        splitMode = .single
        paneSplitRatio = 0.5
        if panes.count <= 1 {
            isPaneMaximized = false
        }
        if let remaining = panes.first {
            remaining.title = session.name
            activePaneId = remaining.id
        }
    }
    
    public func toggleMaximizeActivePane() {
        guard panes.count > 1 else {
            isPaneMaximized = false
            return
        }
        isPaneMaximized.toggle()
    }
    
    public func focusNextPane() {
        guard panes.count > 1 else { return }
        if let curId = activePaneId, let idx = panes.firstIndex(where: { $0.id == curId }) {
            let nextIdx = (idx + 1) % panes.count
            activePaneId = panes[nextIdx].id
        } else {
            activePaneId = panes.first?.id
        }
    }
    
    public func focusPreviousPane() {
        guard panes.count > 1 else { return }
        if let curId = activePaneId, let idx = panes.firstIndex(where: { $0.id == curId }) {
            let prevIdx = (idx - 1 + panes.count) % panes.count
            activePaneId = panes[prevIdx].id
        } else {
            activePaneId = panes.last?.id
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
    @State private var isQuickCommandBarVisible: Bool = false
    @State private var isCommandPalettePresented: Bool = false
    @State private var isTunnelModalPresented: Bool = false
    @State private var isProcessInspectorPresented: Bool = false
    @State private var hudToastMessage: String?
    
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
                            ApexIconButton(
                                icon: "plus",
                                label: "复制当前会话 / 新建标签页 (⌘T)",
                                size: 26,
                                iconSize: 11
                            ) {
                                if let cur = currentTab {
                                    duplicateTab(cur)
                                } else if let first = store.sessions.first {
                                    let client = SSHClientFactory.makeClient(for: first)
                                    let newTab = TerminalTabItem(session: first, sshClient: client)
                                    activeTabs.append(newTab)
                                    selectedTabId = newTab.id
                                    newTab.connect()
                                } else {
                                    openLocalTerminal()
                                }
                            }
                            
                            // Dedicated Local Terminal button
                            ApexIconButton(
                                icon: "laptopcomputer",
                                label: "新建本地终端 (⇧⌘T)",
                                size: 26,
                                iconSize: 11
                            ) {
                                openLocalTerminal()
                            }
                        }
                        .padding(.horizontal, ApexStyle.s4)
                        .padding(.vertical, 4)
                    }
                }
                .frame(height: 38)
                .background(ApexStyle.subtleSurface.opacity(0.55))
                .overlay(alignment: .bottom) { Divider() }

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
                ForEach(1...9, id: \.self) { number in
                    Button("") {
                        guard activeTabs.indices.contains(number - 1) else { return }
                        selectedTabId = activeTabs[number - 1].id
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
                Button("") { currentTab?.split(mode: .vertical) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("") { currentTab?.split(mode: .horizontal) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("") { openLocalTerminal() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("") {
                    if let cur = currentTab, let active = cur.activePane {
                        cur.reconnect(pane: active)
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("") { selectNextTab() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("") { selectPreviousTab() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("") { currentTab?.toggleMaximizeActivePane() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("") { currentTab?.focusNextPane() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("") { currentTab?.focusPreviousPane() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("") { currentTab?.focusNextPane() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("") { currentTab?.focusPreviousPane() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("") { isCommandPalettePresented.toggle() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("") { isQuickCommandBarVisible.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("") { isTunnelModalPresented.toggle() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("") { isProcessInspectorPresented.toggle() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                Button("") { copyLastCommandOutput() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            
            // Workspace Split: Terminal on Top, SFTP on Bottom (electerm layout)
            if let tab = currentTab {
                WorkspaceActiveTabSplitView(
                    store: store,
                    tab: tab,
                    activeTabs: activeTabs,
                    isBroadcastActive: isBroadcastActive,
                    isSFTPVisible: $isSFTPVisible,
                    splitRatio: splitRatioBinding,
                    splitDragStartRatio: $splitDragStartRatio
                )
                
                if isQuickCommandBarVisible {
                    QuickCommandBarView(
                        store: store,
                        isVisible: $isQuickCommandBarVisible,
                        onExecuteCommand: { cmd in
                            if let pane = tab.activePane ?? tab.panes.first,
                               let data = cmd.data(using: .utf8) {
                                Task { try? await pane.sshClient.sendInput(data) }
                            }
                        }
                    )
                }
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 44))
                            .foregroundColor(ApexStyle.accent)
                            .frame(width: 84, height: 84)
                            .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22)
                                    .stroke(ApexStyle.accent.opacity(0.25), lineWidth: 1)
                            )
                            .shadow(color: ApexStyle.accent.opacity(0.18), radius: 12, x: 0, y: 4)
                        
                        VStack(spacing: 6) {
                            Text("从会话开始")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(ApexStyle.primary)
                            Text("在左侧选择主机连接，或者直接新建本地终端")
                                .font(.system(size: 13))
                                .foregroundColor(ApexStyle.secondary)
                        }
                        
                        Button(action: { openLocalTerminal() }) {
                            Label(L10n.openLocalTerminal, systemImage: "laptopcomputer")
                        }
                        .apexProminentButton()
                        .controlSize(.regular)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .apexGlassCard(cornerRadius: 20, material: .ultraThinMaterial, borderColor: ApexStyle.border.opacity(0.7), shadowRadius: 14)
                    
                    HStack(spacing: 16) {
                        HStack(spacing: 5) {
                            Text("⌘P").apexKeycap()
                            Text("命令面板").font(.system(size: 11)).foregroundColor(ApexStyle.secondary)
                        }
                        HStack(spacing: 5) {
                            Text("⌘⌥K").apexKeycap()
                            Text("进程监视").font(.system(size: 11)).foregroundColor(ApexStyle.secondary)
                        }
                        HStack(spacing: 5) {
                            Text("⌘⌥T").apexKeycap()
                            Text("端口转发").font(.system(size: 11)).foregroundColor(ApexStyle.secondary)
                        }
                    }
                    .padding(.top, 6)
                    
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
                .padding(.horizontal, ApexStyle.s4)
                .padding(.vertical, 8)
                .frame(minHeight: 32)
                .background(ApexStyle.surface)
            }
        }
        .navigationTitle(currentTab?.displayTitle ?? L10n.appName)
        .navigationSubtitle(currentTab.map { $0.session.isLocal ? "本机 Shell (\($0.session.username))" : "\($0.session.username)@\($0.session.host)" } ?? "SSH 与文件工作台")
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerCommandPalette"))) { _ in
            isCommandPalettePresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerSSHTunnels"))) { _ in
            isTunnelModalPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerQuickCommandBar"))) { _ in
            isQuickCommandBarVisible.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerProcessInspector"))) { _ in
            isProcessInspectorPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerCopyLastCommandOutput"))) { _ in
            copyLastCommandOutput()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowStatusToast"))) { notif in
            if let msg = notif.object as? String {
                showHUDToast(msg)
            }
        }
        .sheet(isPresented: $isTunnelModalPresented) {
            SSHTunnelModalView(store: store).apexTheme()
        }
        .sheet(isPresented: $isProcessInspectorPresented) {
            if let tab = currentTab {
                ProcessInspectorView(
                    session: tab.session,
                    sshClient: tab.activePane?.sshClient ?? tab.sshClient,
                    isPresented: $isProcessInspectorPresented
                )
                .apexTheme()
            }
        }
        .overlay {
            if isCommandPalettePresented {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture {
                            isCommandPalettePresented = false
                        }
                    
                    VStack {
                        CommandPaletteModalView(
                            store: store,
                            isPresented: $isCommandPalettePresented,
                            onSelectAction: { action in
                                handleCommandPaletteAction(action)
                            }
                        )
                        .padding(.top, 40)
                        Spacer()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            
            if let toast = hudToastMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(ApexStyle.success)
                        Text(toast)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(ApexStyle.primary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .apexGlassCard(cornerRadius: 18, material: .regularMaterial, borderColor: Color.primary.opacity(0.12), shadowRadius: 10)
                    .padding(.bottom, 36)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
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
                
                Button(action: { isTunnelModalPresented = true }) {
                    Label("端口转发", systemImage: "arrow.triangle.swap")
                }
                .help("SSH 端口转发与隧道管理 (⌘⌥T)")
                
                Button(action: { isCommandPalettePresented = true }) {
                    Label("命令面板", systemImage: "command")
                }
                .help("全局快速搜索与命令面板 (⌘P)")
                
                Button(action: { isProcessInspectorPresented = true }) {
                    Label("进程监视", systemImage: "list.bullet.rectangle.portrait")
                }
                .help("Linux/macOS 远程进程与服务监视控制中心 (⌘⌥K)")
            }
            ToolbarItem(placement: .primaryAction) {
                if let primaryPane = tab.panes.first {
                    WorkspaceMetricsView(pane: primaryPane, historyStore: tab.metricsHistory, monitoringEnabled: tab.session.agentlessMonitorEnabled)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $isQuickCommandBarVisible) {
                    Label("快捷命令", systemImage: isQuickCommandBarVisible ? "bolt.fill" : "bolt")
                }
                .toggleStyle(.button)
                .help(isQuickCommandBarVisible ? "隐藏底部快捷命令栏 (⌘⇧B)" : "显示底部快捷命令栏 (⌘⇧B)")

                Toggle(isOn: $isSFTPVisible) {
                    Label("文件面板", systemImage: isSFTPVisible ? "folder.fill" : "folder")
                }
                .toggleStyle(.button)
                .help(isSFTPVisible ? "隐藏文件面板" : "显示文件面板")
            }
        }
    }

    private func copyLastCommandOutput() {
        guard let tab = currentTab, let active = tab.activePane else { return }
        let lines = active.ringBuffer.allLines()
        if let output = CommandBoundaryDetector.extractLastCommandOutput(from: lines) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
            showHUDToast("已复制上一条命令输出 (\(output.count) 字符)")
        } else {
            showHUDToast("未检测到上一条命令输出")
        }
    }
    
    private func showHUDToast(_ message: String) {
        hudToastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.hudToastMessage == message {
                self.hudToastMessage = nil
            }
        }
    }

    public func connectToSession(_ session: Session) {
        let client = SSHClientFactory.makeClient(for: session)
        let newTab = TerminalTabItem(session: session, sshClient: client)
        activeTabs.append(newTab)
        selectedTabId = newTab.id
        newTab.connect()
    }
    
    private func handleCommandPaletteAction(_ action: CommandPaletteAction) {
        switch action {
        case .connectSession(let id):
            if let session = store.sessions.first(where: { $0.id == id }) {
                connectToSession(session)
            }
        case .openBookmark(let path):
            if let tab = currentTab {
                tab.currentRemotePath = path
                isSFTPVisible = true
            }
        case .runSnippet(let snippet):
            if let tab = currentTab, let pane = tab.activePane ?? tab.panes.first {
                let resolved = snippet.resolvedCommand(context: [
                    "host": tab.session.host,
                    "user": tab.session.username,
                    "port": "\(tab.session.port)"
                ])
                if let data = (resolved + "\n").data(using: .utf8) {
                    Task { try? await pane.sshClient.sendInput(data) }
                }
            }
        case .executeAppAction(let appAction):
            switch appAction {
            case .newLocalTerminal:
                openLocalTerminal()
            case .duplicateSession:
                if let cur = currentTab { duplicateTab(cur) }
            case .splitVertical:
                currentTab?.split(mode: .vertical)
            case .splitHorizontal:
                currentTab?.split(mode: .horizontal)
            case .toggleMaximize:
                currentTab?.toggleMaximizeActivePane()
            case .openTunnels:
                isTunnelModalPresented = true
            case .toggleQuickCommandBar:
                isQuickCommandBarVisible.toggle()
            case .toggleSFTP:
                isSFTPVisible.toggle()
            case .clearScrollback:
                currentTab?.ringBuffer.clear()
            case .openSettings:
                NotificationCenter.default.post(name: NSNotification.Name("OpenSettingsModal"), object: nil)
            case .checkForUpdates:
                Task { await UpdateManager.shared.checkForUpdates(manual: true) }
            case .openAbout:
                NotificationCenter.default.post(name: NSNotification.Name("OpenAboutModal"), object: nil)
            case .openShortcuts:
                NotificationCenter.default.post(name: NSNotification.Name("OpenShortcutsModal"), object: nil)
            }
        }
    }

    public func duplicateTab(_ tab: TerminalTabItem) {
        let session = tab.session
        let client = SSHClientFactory.makeClient(for: session)
        
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
    
    public func openLocalTerminal() {
        let local = Session.local()
        let client = SSHClientFactory.makeClient(for: local)
        let newTab = TerminalTabItem(session: local, sshClient: client)
        activeTabs.append(newTab)
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
    
    public func selectNextTab() {
        guard activeTabs.count > 1 else { return }
        let curIdx = activeTabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
        let nextIdx = (curIdx + 1) % activeTabs.count
        selectedTabId = activeTabs[nextIdx].id
    }
    
    public func selectPreviousTab() {
        guard activeTabs.count > 1 else { return }
        let curIdx = activeTabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
        let prevIdx = (curIdx - 1 + activeTabs.count) % activeTabs.count
        selectedTabId = activeTabs[prevIdx].id
    }
}

private struct WorkspaceMetricsView: View {
    @ObservedObject var pane: TerminalPaneItem
    let historyStore: ObservableMetricsHistory
    let monitoringEnabled: Bool

    var body: some View {
        MetricCapsuleView(historyStore: historyStore, compact: true,
                          monitoringEnabled: monitoringEnabled,
                          connectionActive: pane.connectionState == .connected,
                          connectionConnecting: isConnecting)
    }

    private var isConnecting: Bool {
        if case .connecting = pane.connectionState { return true }
        return false
    }
}

private struct WorkspaceActiveTabSplitView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject var store: SessionStore
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
                    if tab.splitMode == .single || tab.panes.count < 2 || tab.isPaneMaximized {
                        if let pane = tab.activePane ?? tab.panes.first {
                            ZStack(alignment: .topTrailing) {
                                PaneContainerView(store: store, pane: pane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                                    .id(pane.id)
                                
                                if tab.isPaneMaximized && tab.panes.count > 1 {
                                    Button {
                                        tab.toggleMaximizeActivePane()
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(ApexStyle.accent)
                                            Text("分屏已放大")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(ApexStyle.primary)
                                            Text("⌘⇧Enter")
                                                .apexKeycap()
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                    }
                                    .buttonStyle(.plain)
                                    .apexGlassCard(cornerRadius: 16, material: .regularMaterial, borderColor: ApexStyle.accent.opacity(0.4), shadowRadius: 6)
                                    .padding(10)
                                    .help("还原分屏布局 (⌘⇧Enter)")
                                }
                            }
                        }
                    } else if tab.splitMode == .vertical {
                        GeometryReader { paneGeo in
                            let totalW = paneGeo.size.width
                            let leftW = max(80, min(totalW - 88, (totalW - 8) * tab.paneSplitRatio))
                            let rightW = max(80, totalW - 8 - leftW)
                            
                            HStack(spacing: 0) {
                                if let firstPane = tab.panes.first {
                                    PaneContainerView(store: store, pane: firstPane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                                        .frame(width: leftW)
                                        .id(firstPane.id)
                                }
                                
                                // Vertical draggable divider between panes
                                ApexSplitDividerHandle(isVertical: true)
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
                                    PaneContainerView(store: store, pane: secondPane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
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
                                    PaneContainerView(store: store, pane: firstPane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
                                        .frame(height: topH)
                                        .id(firstPane.id)
                                }
                                
                                // Horizontal draggable divider between panes
                                ApexSplitDividerHandle(isVertical: false)
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
                                    PaneContainerView(store: store, pane: secondPane, tab: tab, activeTabs: activeTabs, isBroadcastActive: isBroadcastActive)
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
                    ApexSplitDividerHandle(isVertical: false)
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
    @ObservedObject var store: SessionStore
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
                        .shadow(color: isFocused ? ApexStyle.accent.opacity(0.6) : .clear, radius: 3)
                    Text(pane.title)
                        .font(.system(size: 11, weight: isFocused ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(isFocused ? ApexStyle.primary : ApexStyle.secondary)
                    Spacer()
                    ApexIconButton(
                        icon: "xmark",
                        label: "关闭此分屏",
                        size: 18,
                        iconSize: 8
                    ) {
                        tab.closePane(id: pane.id)
                    }
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
                    triggers: store.triggers,
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
                    if tab.isDirectoryLinkageEnabled && (inputData.contains(13) || inputData.contains(10)) {
                        tab.scheduleDirectoryLinkageRefresh()
                    }
                }
                
                // Reconnect floating prompt on disconnect or failure
                if case .disconnected = pane.connectionState {
                    VStack {
                        HStack(spacing: 8) {
                            Circle().fill(ApexStyle.secondary).frame(width: 8, height: 8)
                                .shadow(color: ApexStyle.secondary.opacity(0.5), radius: 3)
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
                        .apexGlassCard(cornerRadius: 12, material: .regularMaterial, borderColor: ApexStyle.secondary.opacity(0.3), shadowRadius: 8)
                        .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                } else if case .failed(let err) = pane.connectionState {
                    VStack {
                        HStack(spacing: 8) {
                            Circle().fill(ApexStyle.error).frame(width: 8, height: 8)
                                .shadow(color: ApexStyle.error.opacity(0.6), radius: 4)
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
                        .apexGlassCard(cornerRadius: 12, material: .regularMaterial, borderColor: ApexStyle.error.opacity(0.4), shadowRadius: 8)
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
        HStack(spacing: 14) {
            if let pane = tab.activePane ?? tab.panes.first {
                ConnectionStatusView(tab: tab, pane: pane)
            }
            
            Text("UTF-8")
                .apexKeycap()
            
            if showsDirectoryControls {
                Divider().frame(height: 12)
                
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
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 8)
        .frame(minHeight: 32)
        .background(ApexStyle.surface)
        .overlay(
            Rectangle()
                .frame(height: 0.75)
                .foregroundColor(ApexStyle.border.opacity(0.6)),
            alignment: .top
        )
    }
}

private struct ConnectionStatusView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject var tab: TerminalTabItem
    @ObservedObject var pane: TerminalPaneItem

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.6), radius: 2)
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
    
    @State private var isHovered: Bool = false
    @State private var isCloseHovered: Bool = false
    
    private var dotColor: Color {
        Color(hex: colorHex ?? "#0A84FF") ?? .blue
    }
    
    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: dotColor.opacity(isSelected ? 0.6 : 0.2), radius: isSelected ? 3 : 1)
            
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? ApexStyle.primary : (isHovered ? ApexStyle.primary.opacity(0.85) : ApexStyle.secondary))
                .lineLimit(1)
            
            Button(action: onClose) {
                ZStack {
                    Circle()
                        .fill(isCloseHovered ? ApexStyle.primary.opacity(0.12) : Color.clear)
                        .frame(width: 16, height: 16)
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(isCloseHovered ? ApexStyle.primary : ApexStyle.secondary)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isSelected || isHovered ? 1.0 : 0.0)
            .animation(ApexStyle.hoverTransition, value: isHovered)
            .animation(ApexStyle.hoverTransition, value: isSelected)
            .onHover { closeHovering in
                isCloseHovered = closeHovering
            }
            .help("关闭标签页 (⌘W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    isSelected
                        ? (themeSettings.followsSystemAppearance ? Color(nsColor: .windowBackgroundColor) : ApexStyle.accent.opacity(0.14))
                        : (isHovered ? ApexStyle.primary.opacity(0.06) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isSelected
                        ? (themeSettings.followsSystemAppearance ? ApexStyle.border : ApexStyle.accent.opacity(0.35))
                        : (isHovered ? ApexStyle.border.opacity(0.5) : Color.clear),
                    lineWidth: 0.75
                )
        )
        .shadow(color: isSelected ? Color.black.opacity(0.06) : Color.clear, radius: 3, x: 0, y: 1)
        .scaleEffect(isHovered && !isSelected ? 1.015 : 1.0)
        .animation(ApexStyle.springSnappy, value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onRename()
            }
        )
        .onHover { hovering in
            withAnimation(ApexStyle.hoverTransition) {
                isHovered = hovering
            }
        }
        .animation(ApexStyle.springSnappy, value: isSelected)
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
