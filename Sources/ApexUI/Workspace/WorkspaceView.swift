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
    @Published public var hasEverConnected: Bool = false
    @Published public var isAutoReconnecting: Bool = false
    @Published public var autoReconnectAttempt: Int = 0
    private var autoReconnectTask: Task<Void, Never>?
    private var connectAttemptId = UUID()
    private var connectTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?
    private var disconnectToken: UUID?
    public var onAutoReconnectRequested: ((TerminalPaneItem) -> Void)?
    @Published public var connectionState: SSHConnectionState {
        didSet {
            if case .connected = connectionState {
                hasEverConnected = true
                isAutoReconnecting = false
                autoReconnectAttempt = 0
                autoReconnectTask?.cancel()
                autoReconnectTask = nil
            }
            if oldValue != connectionState {
                onConnectionStateChanged?(connectionState)
            }
        }
    }
    public var onConnectionStateChanged: ((SSHConnectionState) -> Void)?
    public private(set) var logger: SessionLogger?
    public private(set) var isTornDown: Bool = false
    @Published public var pendingOSC52Request: OSC52WriteRequest? = nil
    @Published public var isOSC52SessionAllowed: Bool = false
    public var onWriteClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func handleOSC52WriteRequest(
        _ request: OSC52WriteRequest,
        policy: OSC52ClipboardPolicy = AppSettings.shared.osc52ClipboardPolicy
    ) {
        guard !isTornDown else { return }
        switch policy {
        case .deny:
            pendingOSC52Request = nil
        case .allow:
            onWriteClipboard(request.text)
        case .ask:
            if isOSC52SessionAllowed {
                onWriteClipboard(request.text)
            } else {
                pendingOSC52Request = request
            }
        }
    }

    public func allowPendingOSC52Once() {
        guard let req = pendingOSC52Request else { return }
        onWriteClipboard(req.text)
        pendingOSC52Request = nil
    }

    public func allowPendingOSC52ForSession() {
        isOSC52SessionAllowed = true
        allowPendingOSC52Once()
    }

    public func denyPendingOSC52() {
        pendingOSC52Request = nil
    }
    
    public func cancelAutoReconnect() {
        autoReconnectTask?.cancel()
        autoReconnectTask = nil
        isAutoReconnecting = false
        autoReconnectAttempt = 0
    }

    func beginConnectAttempt() -> UUID {
        connectTask?.cancel()
        connectTask = nil
        let attemptId = UUID()
        connectAttemptId = attemptId
        return attemptId
    }

    func setConnectTask(_ task: Task<Void, Never>, for attemptId: UUID) {
        guard connectAttemptId == attemptId else {
            task.cancel()
            return
        }
        connectTask = task
    }

    func finishConnectAttempt(_ attemptId: UUID) {
        if connectAttemptId == attemptId {
            connectTask = nil
        }
    }

    func isCurrentConnectAttempt(_ attemptId: UUID) -> Bool {
        connectAttemptId == attemptId
    }

    func waitForPendingDisconnect() async {
        guard let pending = disconnectTask, let token = disconnectToken else { return }
        await pending.value
        if disconnectToken == token {
            disconnectTask = nil
            disconnectToken = nil
        }
    }

    public func cancelCurrentConnection() {
        guard !isTornDown else { return }
        cancelAutoReconnect()
        connectAttemptId = UUID()
        connectTask?.cancel()
        connectTask = nil
        connectionState = .disconnected
        let client = sshClient
        let prevDisconnect = disconnectTask
        let token = UUID()
        disconnectToken = token
        disconnectTask = Task { @MainActor [weak self] in
            await prevDisconnect?.value
            await client.disconnect()
            if self?.disconnectToken == token {
                self?.disconnectTask = nil
                self?.disconnectToken = nil
            }
        }
    }
    
    /// Explicitly tears down the pane, cancelling pending auto-reconnect timers, closing audit logs,
    /// clearing scrollback memory, detaching SSH callbacks, and disconnecting the underlying session.
    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        cancelAutoReconnect()
        connectAttemptId = UUID()
        connectTask?.cancel()
        connectTask = nil
        disconnectTask?.cancel()
        disconnectTask = nil
        disconnectToken = nil
        onAutoReconnectRequested = nil
        onConnectionStateChanged = nil
        sshClient.setOutputHandler { _ in }
        sshClient.setStateChangeHandler { _ in }
        sshClient.setDirectoryChangeHandler { _ in }
        sshClient.setMetricsHandler { _ in }
        ringBuffer.onUpdate = nil
        ringBuffer.onOSC52WriteRequest = nil
        pendingOSC52Request = nil
        ringBuffer.finishStream()
        ringBuffer.clear()
        logger?.close()
        logger = nil
        let client = sshClient
        Task { await client.disconnect() }
    }
    
    private func scheduleAutoReconnect() {
        guard !isTornDown else { return }
        autoReconnectTask?.cancel()
        autoReconnectAttempt += 1
        isAutoReconnecting = true
        let attempt = autoReconnectAttempt
        let delays: [UInt64] = [1_500_000_000, 3_000_000_000, 5_000_000_000, 8_000_000_000, 12_000_000_000]
        let delayNs = delays[min(max(attempt - 1, 0), delays.count - 1)]
        autoReconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self = self, !Task.isCancelled, !self.isTornDown, self.isAutoReconnecting else { return }
            self.onAutoReconnectRequested?(self)
        }
    }
    
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
        ringBuffer.onOSC52WriteRequest = { [weak self] request in
            Task { @MainActor [weak self] in
                self?.handleOSC52WriteRequest(request)
            }
        }
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
                guard let self = self, !self.isTornDown else { return }
                if self.disconnectTask != nil {
                    if self.connectTask != nil || state != .disconnected {
                        return
                    }
                }
                self.connectionState = state
                if case .disconnected = state,
                   self.hasEverConnected,
                   !self.session.isLocal,
                   !self.sshClient.wasUserInitiatedDisconnect,
                   AppSettings.shared.isAutoReconnectEnabled,
                   self.autoReconnectAttempt < 5 {
                    self.scheduleAutoReconnect()
                }
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
    /// TERM the remote host lacks a terminfo entry for; drives the warning banner
    @Published public var terminfoWarning: TerminalType? = nil
    private var terminfoProbeTask: Task<Void, Never>? = nil
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
    public private(set) var isTornDown: Bool = false
    
    private let fallbackRingBuffer = TerminalRingBuffer(maxLines: AppSettings.shared.scrollbackMaxLines)
    
    /// Explicitly tears down the tab and all its split panes, cancelling background tasks and reclaiming memory.
    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        terminfoProbeTask?.cancel()
        terminfoProbeTask = nil
        linkageRefreshTask?.cancel()
        linkageRefreshTask = nil
        metricsHistory.clear()
        fallbackRingBuffer.clear()
        for pane in panes {
            pane.tearDown()
        }
    }
    public var ringBuffer: TerminalRingBuffer {
        activePane?.ringBuffer ?? panes.first?.ringBuffer ?? fallbackRingBuffer
    }
    
    public var activePane: TerminalPaneItem? {
        panes.first(where: { $0.id == activePaneId }) ?? panes.first
    }
    
    public init(session: Session, sshClient: SSHSessionProtocol) {
        self.session = session
        self.sshClient = sshClient
        let defaultRemoteDir: String = {
            if let initDir = session.initialWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !initDir.isEmpty {
                return initDir
            }
            return "~"
        }()
        self.currentRemotePath = UserDefaults.standard.string(forKey: "workspace.remotePath.\(session.id.uuidString)")
            ?? defaultRemoteDir
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
        primaryPane.onAutoReconnectRequested = { [weak self] pane in
            self?.connect(pane: pane)
        }

        attachMetricsHandler(to: self.sshClient)
        
        registerDirectoryLinkage(for: self.sshClient, paneId: primaryPane.id)
    }

    private func attachMetricsHandler(to client: SSHSessionProtocol) {
        let metricsHistory = self.metricsHistory
        client.setMetricsHandler { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isTornDown else { return }
                metricsHistory.append(snapshot)
            }
        }
    }

    private var linkageRefreshTask: Task<Void, Never>? = nil

    public func scheduleDirectoryLinkageRefresh() {
        linkageRefreshTask?.cancel()
        linkageRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self = self, !self.isTornDown, self.isDirectoryLinkageEnabled, !Task.isCancelled else { return }
            NotificationCenter.default.post(
                name: NSNotification.Name("SFTPDirectoryRefreshNeeded"),
                object: self.currentRemotePath,
                userInfo: ["tabId": self.id]
            )
        }
    }

    public func registerDirectoryLinkage(for client: SSHSessionProtocol, paneId: UUID? = nil) {
        client.setDirectoryChangeHandler { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isTornDown else { return }
                if let paneId, let activeId = self.activePaneId ?? self.panes.first?.id, activeId != paneId {
                    return
                }
                if self.isDirectoryLinkageEnabled {
                    if self.currentRemotePath != path {
                        self.linkageRefreshTask?.cancel()
                        self.currentRemotePath = path
                    } else {
                        self.scheduleDirectoryLinkageRefresh()
                    }
                    return
                }
                if self.currentRemotePath == "~", path.hasPrefix("/") {
                    self.linkageRefreshTask?.cancel()
                    self.currentRemotePath = path
                } else if self.currentRemotePath.hasPrefix("~/"), path.hasPrefix("/") {
                    let suffix = String(self.currentRemotePath.dropFirst(2))
                    let trimmedBase = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
                    let resolved = trimmedBase == "/" ? "/\(suffix)" : "\(trimmedBase)/\(suffix)"
                    if self.currentRemotePath != resolved {
                        self.linkageRefreshTask?.cancel()
                        self.currentRemotePath = resolved
                    }
                }
            }
        }
    }
    
    public func connect(pane: TerminalPaneItem? = nil) {
        let targetPane = pane ?? activePane ?? panes.first
        guard let p = targetPane else { return }
        let isPrimaryPane = p.id == panes.first?.id
        if isPrimaryPane {
            terminfoProbeTask?.cancel()
            terminfoWarning = nil
        }
        let attemptId = p.beginConnectAttempt()
        p.connectionState = .connecting(step: "正在连接")
        if p.id == (activePane?.id ?? panes.first?.id) {
            self.connectionState = .connecting(step: "正在连接")
        }
        let task = Task { @MainActor in
            defer { p.finishConnectAttempt(attemptId) }
            do {
                await p.waitForPendingDisconnect()
                guard p.isCurrentConnectAttempt(attemptId), !p.isTornDown, !self.isTornDown else { return }
                let shouldRunStartupBootstrap = !p.hasEverConnected
                try await p.sshClient.connect()
                guard p.isCurrentConnectAttempt(attemptId), !p.isTornDown, !self.isTornDown else { return }
                let dims = p.ringBuffer.dimensions
                try? await p.sshClient.resizeTerminal(columns: dims.columns, rows: dims.rows)
                p.connectionState = p.sshClient.connectionState
                if p.id == (self.activePane?.id ?? self.panes.first?.id) {
                    self.connectionState = p.sshClient.connectionState
                }
                guard p.connectionState == .connected else { return }
                if isPrimaryPane {
                    self.probeTerminfo(client: p.sshClient)
                }
                if shouldRunStartupBootstrap,
                   let bootstrap = SessionStartupHelper.buildBootstrapCommand(
                       for: self.session,
                       includeWorkingDirectory: !self.session.isLocal,
                       includeEnvExports: !self.session.isLocal
                   ),
                   let data = (bootstrap + "\n").data(using: .utf8) {
                    try? await p.sshClient.sendInput(data)
                }
                
                // Auto-start configured tunnels for this session
                let autoTunnels = SSHTunnelManager.shared.tunnels(for: self.session.id).filter { $0.autoStart }
                for t in autoTunnels {
                    if !SSHTunnelManager.shared.state(for: t.id).isRunning {
                        let pw = await SSHTunnelManager.resolveSecret(for: self.session)
                        guard p.isCurrentConnectAttempt(attemptId), !p.isTornDown, !self.isTornDown else { return }
                        let sshpass = (self.sshClient as? NativeSSHSession)?.sshpassExecutablePath
                        try? SSHTunnelManager.shared.startTunnel(id: t.id, session: self.session, password: pw, privateKeyPath: self.session.privateKeyPath, sshpassPath: sshpass)
                    }
                }
            } catch is CancellationError {
                guard p.isCurrentConnectAttempt(attemptId), !p.isTornDown, !self.isTornDown else { return }
                p.connectionState = .disconnected
                if p.id == (self.activePane?.id ?? self.panes.first?.id) {
                    self.connectionState = .disconnected
                }
            } catch {
                guard p.isCurrentConnectAttempt(attemptId), !p.isTornDown, !self.isTornDown else { return }
                let nextState: SSHConnectionState = p.sshClient.wasUserInitiatedDisconnect ? .disconnected : .failed(error.localizedDescription)
                p.connectionState = nextState
                if p.id == (self.activePane?.id ?? self.panes.first?.id) {
                    self.connectionState = nextState
                }
            }
        }
        p.setConnectTask(task, for: attemptId)
    }
    
    public func reconnect(pane: TerminalPaneItem) {
        pane.cancelAutoReconnect()
        connect(pane: pane)
    }

    /// Silently checks the remote terminfo database over the one-shot command channel.
    private func probeTerminfo(client: SSHSessionProtocol) {
        guard !session.isLocal else { return }
        let type = client.terminalType
        terminfoProbeTask = Task { @MainActor [weak self] in
            let result = await TerminfoProbe.run(on: client)
            guard let self = self, !Task.isCancelled, result == .missing else { return }
            self.terminfoWarning = type
        }
    }

    /// Persists the fallback TERM for this session and reconnects every pane with it.
    public func applyTerminfoFallback(store: SessionStore = .shared) {
        guard let missing = terminfoWarning else { return }
        let target = missing.fallback
        terminfoWarning = nil
        if var saved = store.sessions.first(where: { $0.id == session.id }) {
            saved.terminalType = target
            store.updateSession(saved)
        }
        for pane in panes {
            pane.sshClient.setTerminalType(target)
        }
        reconnectAll()
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
        let inheritedTerminalType = (activePane ?? panes.first)?.sshClient.terminalType ?? sshClient.terminalType
        newClient.setTerminalType(inheritedTerminalType)
        
        let newPane = TerminalPaneItem(session: session, sshClient: newClient, title: "\(session.name) (分屏)", initialState: .connecting(step: "连接中"))
        newPane.onConnectionStateChanged = { [weak self, weak newPane] newState in
            guard let self = self, let newPane = newPane else { return }
            if self.activePaneId == newPane.id && self.connectionState != newState {
                self.connectionState = newState
            }
        }
        newPane.onAutoReconnectRequested = { [weak self] pane in
            self?.connect(pane: pane)
        }
        self.panes.append(newPane)
        self.activePaneId = newPane.id
        self.splitMode = mode
        self.paneSplitRatio = 0.5
        registerDirectoryLinkage(for: newClient, paneId: newPane.id)
        
        connect(pane: newPane)
    }
    
    public func closePane(id: UUID) {
        guard let idx = panes.firstIndex(where: { $0.id == id }) else { return }
        let wasPrimary = idx == 0
        let pane = panes[idx]
        pane.tearDown()
        panes.remove(at: idx)
        splitMode = .single
        paneSplitRatio = 0.5
        if panes.count <= 1 {
            isPaneMaximized = false
        }
        if let remaining = panes.first {
            remaining.title = session.name
            activePaneId = remaining.id
            if wasPrimary {
                attachMetricsHandler(to: remaining.sshClient)
            }
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
    /// Owned here, not by the toolbar-hosted capsule, so the popover survives toolbar rebuilds.
    /// Held without observation: toggling it must not re-evaluate the toolbar, which would tear
    /// down the popover's anchor and re-present it as a non-key window that ignores Escape.
    @State private var metricsDetail = MetricsDetailPresentation()
    @AppStorage("workspace.metricsDockWidth") private var storedMetricsDockWidth: Double = Double(WorkspaceMainAreaWithMetricsDock.defaultDockedMetricsWidth)
    private var metricsDockWidthBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(storedMetricsDockWidth) },
            set: { storedMetricsDockWidth = Double($0) }
        )
    }
    @State private var metricsDockDragStartWidth: CGFloat?
    /// Owned here without observation so toggling the transfer drawer never triggers toolbar rebuilds.
    @State private var transferDrawer = TransferDrawerPresentation()
    @State private var workspaceContentSize: CGSize = .zero
    @State private var hudToastMessage: String?
    @State private var pendingSnippetForVariables: Snippet? = nil
    @State private var pendingSnippetVariables: [String: String] = [:]
    
    public static let executeSnippetNotification = NSNotification.Name("ExecuteSnippetInWorkspace")
    
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
                                    tab: tab,
                                    isSelected: tab.id == currentTab?.id,
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
                                for p in tab.panes where p.connectionState == .connected {
                                    Task { try? await p.sshClient.sendInput(data) }
                                }
                                if tab.isDirectoryLinkageEnabled && (data.contains(13) || data.contains(10)) {
                                    tab.scheduleDirectoryLinkageRefresh()
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
            
            // Workspace Split: Terminal on Top, SFTP on Bottom (electerm layout), optional right-docked Metrics panel
            if let tab = currentTab {
                WorkspaceMainAreaWithMetricsDock(
                    store: store,
                    tab: tab,
                    activeTabs: activeTabs,
                    isBroadcastActive: isBroadcastActive,
                    isSFTPVisible: $isSFTPVisible,
                    splitRatio: splitRatioBinding,
                    splitDragStartRatio: $splitDragStartRatio,
                    metricsPresentation: metricsDetail,
                    metricsDockWidth: metricsDockWidthBinding,
                    metricsDockDragStartWidth: $metricsDockDragStartWidth,
                    transferPresentation: transferDrawer
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
                WorkspaceBottomStatusBar(
                    tab: tab,
                    showsDirectoryControls: !isSFTPVisible,
                    transferPresentation: transferDrawer
                )
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { workspaceContentSize = $0 }
        .navigationTitle(currentTab?.displayTitle ?? L10n.appName)
        .navigationSubtitle(currentTab.map { $0.session.isLocal ? "本机 Shell (\($0.session.username))" : "\($0.session.username)@\($0.session.host)" } ?? "SSH 与文件工作台")
        .toolbar { workspaceToolbar }
        .overlay(alignment: .topTrailing) {
            if let tab = currentTab {
                WorkspaceMetricsDetailHost(presentation: metricsDetail, tab: tab)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if currentTab != nil && !isSFTPVisible {
                WorkspaceTransferOverlayHost(
                    presentation: transferDrawer,
                    containerSize: workspaceContentSize
                )
            }
        }
        .onChange(of: selectedTabId) { _, _ in metricsDetail.handleTabChanged() }
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
        .onReceive(NotificationCenter.default.publisher(for: Self.executeSnippetNotification)) { notif in
            if let snippet = notif.object as? Snippet {
                executeSnippet(snippet)
            }
        }
        .sheet(item: $pendingSnippetForVariables) { snippet in
            VariableInputSheet(
                snippet: snippet,
                variableValues: $pendingSnippetVariables,
                onConfirm: { resolved in
                    sendSnippetCommand(resolved, autoExecute: true)
                    pendingSnippetForVariables = nil
                },
                onCancel: {
                    pendingSnippetForVariables = nil
                }
            )
            .apexTheme()
        }
        .sheet(isPresented: $isTunnelModalPresented) {
            SSHTunnelModalView(store: store).apexTheme()
        }
        .sheet(isPresented: $isProcessInspectorPresented) {
            if let tab = currentTab {
                ProcessInspectorView(
                    session: tab.session,
                    sshClient: tab.activePane?.sshClient ?? tab.sshClient,
                    isPresented: $isProcessInspectorPresented,
                    onOpenContainerShell: { hostSession, execCommand in
                        var containerSession = hostSession
                        containerSession.initialWorkingDirectory = nil
                        containerSession.startupCommand = execCommand
                        let client = SSHClientFactory.makeClient(for: containerSession)
                        let newTab = TerminalTabItem(session: containerSession, sshClient: client)
                        newTab.customTitle = "\(hostSession.name) · 容器终端"
                        activeTabs.append(newTab)
                        selectedTabId = newTab.id
                        newTab.connect()
                    }
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
                WorkspaceSplitToolbarMenu(tab: tab)
                
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
                WorkspaceMetricsToolbarHost(tab: tab, presentation: metricsDetail)
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
        if let oscOutput = active.ringBuffer.extractLastOSC133CommandOutput() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(oscOutput, forType: .string)
            showHUDToast("已复制上一条命令输出 (\(oscOutput.count) 字符)")
            return
        }
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
            executeSnippet(snippet)
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

    public func executeSnippet(_ snippet: Snippet) {
        guard let tab = currentTab else { return }
        let baseContext: [String: String] = [
            "host": tab.session.host,
            "user": tab.session.username
        ]
        let unresolved = snippet.unresolvedVariables(context: baseContext)
        if unresolved.isEmpty {
            let resolved = snippet.resolvedCommand(context: baseContext)
            sendSnippetCommand(resolved, autoExecute: true)
        } else {
            var initialValues = baseContext
            for v in unresolved {
                initialValues[v] = ""
            }
            pendingSnippetVariables = initialValues
            pendingSnippetForVariables = snippet
        }
    }

    private func sendSnippetCommand(_ command: String, autoExecute: Bool) {
        guard let tab = currentTab, let pane = tab.activePane ?? tab.panes.first else { return }
        let payload = autoExecute ? (command + "\n") : command
        if let data = payload.data(using: .utf8) {
            Task { try? await pane.sshClient.sendInput(data) }
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
        tab.tearDown()
        activeTabs.removeAll(where: { $0.id == tab.id })
        if selectedTabId == tab.id {
            selectedTabId = activeTabs.first?.id
        }
    }
    
    private func closeOtherTabs(_ tab: TerminalTabItem) {
        let toClose = activeTabs.filter { $0.id != tab.id }
        for t in toClose {
            t.tearDown()
        }
        activeTabs = [tab]
        selectedTabId = tab.id
    }
    
    private func closeTabsToTheRight(_ tab: TerminalTabItem) {
        guard let idx = activeTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let toClose = Array(activeTabs.suffix(from: idx + 1))
        for t in toClose {
            t.tearDown()
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

private struct WorkspaceSplitToolbarMenu: View {
    @ObservedObject var tab: TerminalTabItem

    var body: some View {
        Menu {
            Button("垂直分屏", systemImage: "rectangle.split.2x1") { tab.split(mode: .vertical) }
            Button("水平分屏", systemImage: "rectangle.split.1x2") { tab.split(mode: .horizontal) }
        } label: {
            Label("分屏", systemImage: "rectangle.split.2x1")
        }
        .disabled(tab.panes.count >= 2)
        .help("分屏 (⌘D / ⌘⇧D)")
    }
}

private struct WorkspaceMetricsToolbarHost: View {
    @ObservedObject var tab: TerminalTabItem
    let presentation: MetricsDetailPresentation

    var body: some View {
        if let primaryPane = tab.panes.first {
            WorkspaceMetricsView(
                pane: primaryPane,
                historyStore: tab.metricsHistory,
                monitoringEnabled: tab.session.agentlessMonitorEnabled,
                presentation: presentation
            )
        }
    }
}

private struct WorkspaceMetricsDetailHost: View {
    let presentation: MetricsDetailPresentation
    @ObservedObject var tab: TerminalTabItem

    var body: some View {
        if let primaryPane = tab.panes.first {
            MetricsDetailOverlay(
                presentation: presentation,
                tab: tab,
                pane: primaryPane,
                historyStore: tab.metricsHistory,
                monitoringEnabled: tab.session.agentlessMonitorEnabled
            )
        }
    }
}

private struct WorkspaceMetricsView: View {
    @ObservedObject var pane: TerminalPaneItem
    let historyStore: ObservableMetricsHistory
    let monitoringEnabled: Bool
    @ObservedObject var presentation: MetricsDetailPresentation

    var body: some View {
        MetricCapsuleView(
            historyStore: historyStore,
            compact: true,
            monitoringEnabled: monitoringEnabled,
            connectionActive: pane.connectionState == .connected,
            connectionConnecting: isConnecting,
            isDetailPresented: $presentation.isPresented,
            isPinned: presentation.isPinned,
            onToggleDetail: {
                presentation.toggleFromToolbar()
            }
        )
    }

    private var isConnecting: Bool {
        if case .connecting = pane.connectionState { return true }
        return false
    }
}

@MainActor
public final class MetricsDetailPresentation: ObservableObject {
    private let defaults: UserDefaults
    private let storageKey: String

    @Published public var isPresented: Bool = false
    @Published public var isPinned: Bool {
        didSet {
            defaults.set(isPinned, forKey: storageKey)
        }
    }

    public init(defaults: UserDefaults = .standard, storageKey: String = "workspace.metricsPanelPinned") {
        self.defaults = defaults
        self.storageKey = storageKey
        self.isPinned = defaults.bool(forKey: storageKey)
    }

    public var showsFloatingOverlay: Bool {
        isPresented && !isPinned
    }

    public var showsDockedPanel: Bool {
        isPinned
    }

    public func toggleFromToolbar() {
        if isPinned {
            isPinned = false
            isPresented = false
        } else {
            isPresented.toggle()
        }
    }

    public func togglePin() {
        if isPinned {
            isPinned = false
            isPresented = true
        } else {
            isPinned = true
            isPresented = false
        }
    }

    public func dismissFloating() {
        isPresented = false
    }

    public func closeDocked() {
        isPinned = false
        isPresented = false
    }

    public func handleTabChanged() {
        if !isPinned {
            isPresented = false
        }
    }
}

/// The metrics detail card, presented from the window content instead of a toolbar-anchored
/// popover so its lifetime never depends on the toolbar item host. Clicking outside the card or
/// pressing Escape closes it; the Escape interceptor exists only while the floating card is open so
/// terminal programs such as vim keep receiving Escape otherwise.
private struct MetricsDetailOverlay: View {
    @ObservedObject var presentation: MetricsDetailPresentation
    @ObservedObject var tab: TerminalTabItem
    @ObservedObject var pane: TerminalPaneItem
    let historyStore: ObservableMetricsHistory
    let monitoringEnabled: Bool

    var body: some View {
        if presentation.showsFloatingOverlay {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { presentation.dismissFloating() }
                    .accessibilityHidden(true)
                MetricDetailView(
                    historyStore: historyStore,
                    monitoringEnabled: monitoringEnabled,
                    connectionActive: pane.connectionState == .connected,
                    connectionConnecting: isConnecting,
                    isPinned: false,
                    sessionLabel: tab.displayTitle,
                    onTogglePin: {
                        withAnimation(ApexStyle.springSnappy) {
                            presentation.togglePin()
                        }
                    },
                    onDismiss: {
                        withAnimation(ApexStyle.springSnappy) {
                            presentation.dismissFloating()
                        }
                    }
                )
                    .frame(width: 416)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ApexStyle.border.opacity(0.6), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .padding(.top, 6)
                    .padding(.trailing, 12)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("metrics.detail")
                // The terminal is usually first responder and consumes Escape in keyDown (it
                // forwards ESC to the PTY), so a SwiftUI cancel shortcut never fires. Intercept
                // Escape for this window only while the card is visible.
                EscapeKeyInterceptor { presentation.dismissFloating() }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
        }
    }

    private var isConnecting: Bool {
        if case .connecting = pane.connectionState { return true }
        return false
    }
}

public struct WorkspaceMainAreaWithMetricsDock: View {
    nonisolated public static let minDockedMetricsWidth: CGFloat = 310
    nonisolated public static let defaultDockedMetricsWidth: CGFloat = 372
    nonisolated public static let maxDockedMetricsWidth: CGFloat = 480
    nonisolated public static let minTerminalWidthAlongsideDockedMetrics: CGFloat = 240

    @ObservedObject var store: SessionStore
    @ObservedObject var tab: TerminalTabItem
    let activeTabs: [TerminalTabItem]
    let isBroadcastActive: Bool
    @Binding var isSFTPVisible: Bool
    @Binding var splitRatio: CGFloat
    @Binding var splitDragStartRatio: CGFloat?
    @ObservedObject var metricsPresentation: MetricsDetailPresentation
    @Binding var metricsDockWidth: CGFloat
    @Binding var metricsDockDragStartWidth: CGFloat?
    let transferPresentation: TransferDrawerPresentation

    nonisolated public static func clampedDockedWidth(preferred: CGFloat, availableTotalWidth: CGFloat) -> CGFloat {
        let dividerWidth: CGFloat = 8
        let maxAllowed = max(0, availableTotalWidth - minTerminalWidthAlongsideDockedMetrics - dividerWidth)
        if maxAllowed < 240 {
            return max(0, min(preferred, floor((availableTotalWidth - dividerWidth) * 0.48)))
        }
        let upper = min(maxDockedMetricsWidth, maxAllowed)
        let lower = min(minDockedMetricsWidth, upper)
        return min(max(preferred, lower), upper)
    }

    public var body: some View {
        GeometryReader { geo in
            let effectiveDockedWidth = metricsPresentation.showsDockedPanel
                ? Self.clampedDockedWidth(preferred: metricsDockWidth, availableTotalWidth: geo.size.width)
                : 0
            HStack(spacing: 0) {
                WorkspaceActiveTabSplitView(
                    store: store,
                    tab: tab,
                    activeTabs: activeTabs,
                    isBroadcastActive: isBroadcastActive,
                    isSFTPVisible: $isSFTPVisible,
                    splitRatio: $splitRatio,
                    splitDragStartRatio: $splitDragStartRatio,
                    transferPresentation: transferPresentation
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if metricsPresentation.showsDockedPanel && effectiveDockedWidth > 0 {
                    ApexSplitDividerHandle(isVertical: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("右侧监控面板宽度")
                        .accessibilityValue("\(Int(effectiveDockedWidth))pt")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment:
                                metricsDockWidth = Self.clampedDockedWidth(
                                    preferred: effectiveDockedWidth + 20,
                                    availableTotalWidth: geo.size.width
                                )
                            case .decrement:
                                metricsDockWidth = Self.clampedDockedWidth(
                                    preferred: effectiveDockedWidth - 20,
                                    availableTotalWidth: geo.size.width
                                )
                            @unknown default:
                                break
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let start = metricsDockDragStartWidth ?? effectiveDockedWidth
                                    if metricsDockDragStartWidth == nil {
                                        metricsDockDragStartWidth = start
                                    }
                                    let proposed = start - value.translation.width
                                    metricsDockWidth = Self.clampedDockedWidth(
                                        preferred: proposed,
                                        availableTotalWidth: geo.size.width
                                    )
                                }
                                .onEnded { _ in
                                    metricsDockDragStartWidth = nil
                                }
                        )

                    WorkspaceDockedMetricsPanel(
                        presentation: metricsPresentation,
                        tab: tab
                    )
                    .frame(width: effectiveDockedWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }
}

private struct WorkspaceDockedMetricsPanel: View {
    @ObservedObject var presentation: MetricsDetailPresentation
    @ObservedObject var tab: TerminalTabItem

    var body: some View {
        if let primaryPane = tab.panes.first {
            DockedMetricsPanelContent(
                presentation: presentation,
                tab: tab,
                pane: primaryPane
            )
        }
    }
}

private struct DockedMetricsPanelContent: View {
    @ObservedObject var presentation: MetricsDetailPresentation
    @ObservedObject var tab: TerminalTabItem
    @ObservedObject var pane: TerminalPaneItem

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            MetricDetailView(
                historyStore: tab.metricsHistory,
                monitoringEnabled: tab.session.agentlessMonitorEnabled,
                connectionActive: pane.connectionState == .connected,
                connectionConnecting: isConnecting,
                isPinned: true,
                sessionLabel: tab.displayTitle,
                onTogglePin: {
                    withAnimation(ApexStyle.springSnappy) {
                        presentation.togglePin()
                    }
                },
                onDismiss: {
                    withAnimation(ApexStyle.springSnappy) {
                        presentation.closeDocked()
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ApexStyle.surface)
        .overlay(alignment: .leading) {
            Rectangle()
                .frame(width: 0.75)
                .foregroundColor(ApexStyle.border.opacity(0.6))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("metrics.dockedPanel")
    }

    private var isConnecting: Bool {
        if case .connecting = pane.connectionState { return true }
        return false
    }
}

/// Consumes a plain Escape key press in its own window while mounted.
private struct EscapeKeyInterceptor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> InterceptorView {
        let view = InterceptorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: InterceptorView, context: Context) {
        nsView.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: InterceptorView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class InterceptorView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                    return event
                }
                self.onEscape?()
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
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
    let transferPresentation: TransferDrawerPresentation
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
                    let activeTargetPane = tab.activePane ?? tab.panes.first
                    SFTPTransferBoundView(
                        presentation: transferPresentation,
                        currentPath: $tab.currentRemotePath,
                        isLinkageEnabled: $tab.isDirectoryLinkageEnabled,
                        session: activeTargetPane?.sshClient ?? tab.sshClient,
                        connectionState: activeTargetPane?.connectionState ?? tab.connectionState,
                        tabID: tab.id
                    )
                    .id(activeTargetPane?.id ?? tab.id)
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
    @State private var dropTransferNotice: String? = nil
    @State private var dropTransferIsError: Bool = false
    
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
                    isCopyOnSelectEnabled: themeSettings.isCopyOnSelectEnabled,
                    triggers: store.triggers,
                    onResize: { cols, rows in
                        Task {
                            try? await pane.sshClient.resizeTerminal(columns: cols, rows: rows)
                        }
                    },
                    onFileDrop: { localURL in
                        if tab.session.isLocal {
                            let escapedPath = "'" + localURL.path.replacingOccurrences(of: "'", with: "'\\''") + "' "
                            if let data = escapedPath.data(using: .utf8) {
                                pane.sshClient.sendInputSync(data)
                            }
                            return
                        }
                        let targetDir = tab.currentRemotePath
                        let fileName = localURL.lastPathComponent
                        let dest = targetDir.hasSuffix("/") ? "\(targetDir)\(fileName)" : "\(targetDir)/\(fileName)"
                        dropTransferIsError = false
                        dropTransferNotice = "正在上传 \(fileName) 至 \(targetDir)…"
                        TransferManager.shared.enqueueUpload(session: pane.sshClient, localURL: localURL, remotePath: dest, onResult: { result in
                            Task { @MainActor in
                                switch result {
                                case .success:
                                    dropTransferIsError = false
                                    dropTransferNotice = "已上传 \(fileName) 至 \(targetDir)"
                                    NotificationCenter.default.post(
                                        name: NSNotification.Name("SFTPDirectoryRefreshNeeded"),
                                        object: dest,
                                        userInfo: ["tabId": tab.id]
                                    )
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                                        if dropTransferNotice == "已上传 \(fileName) 至 \(targetDir)" {
                                            dropTransferNotice = nil
                                        }
                                    }
                                case .failure(let error):
                                    dropTransferIsError = true
                                    if error is CancellationError {
                                        dropTransferNotice = "已取消上传: \(fileName)"
                                    } else {
                                        dropTransferNotice = "上传失败: \(error.localizedDescription)"
                                    }
                                }
                            }
                        })
                    }
                ) { inputData in
                    if isBroadcastActive {
                        for t in activeTabs {
                            for p in t.panes where p.connectionState == .connected {
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
                
                // Connecting / Reconnect floating prompt
                if case .connecting(let step) = pane.connectionState, !tab.session.isLocal {
                    VStack {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(step.isEmpty || step == "正在连接" ? "正在连接 \(tab.session.username)@\(tab.session.host):\(tab.session.port)…" : step)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(ApexStyle.primary)
                                .lineLimit(1)
                            Button("取消") {
                                pane.cancelCurrentConnection()
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            .foregroundColor(ApexStyle.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .apexGlassCard(cornerRadius: 12, material: .regularMaterial, borderColor: ApexStyle.warning.opacity(0.4), shadowRadius: 8)
                        .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                } else if case .disconnected = pane.connectionState {
                    VStack {
                        HStack(spacing: 8) {
                            Circle().fill(pane.isAutoReconnecting ? ApexStyle.warning : ApexStyle.secondary).frame(width: 8, height: 8)
                                .shadow(color: (pane.isAutoReconnecting ? ApexStyle.warning : ApexStyle.secondary).opacity(0.5), radius: 3)
                            Text(pane.isAutoReconnecting ? "连接中断，正在自动重连 (\(pane.autoReconnectAttempt)/5)..." : "会话已断开")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(ApexStyle.primary)
                            Button(pane.isAutoReconnecting ? "立即重连" : "重新连接 (⌘R)") {
                                tab.reconnect(pane: pane)
                            }
                            .apexProminentButton()
                            .controlSize(.small)
                            if pane.isAutoReconnecting {
                                Button("停止") {
                                    pane.cancelAutoReconnect()
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                                .foregroundColor(ApexStyle.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .apexGlassCard(cornerRadius: 12, material: .regularMaterial, borderColor: (pane.isAutoReconnecting ? ApexStyle.warning : ApexStyle.secondary).opacity(0.35), shadowRadius: 8)
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
                } else if let missing = tab.terminfoWarning, pane.id == tab.panes.first?.id {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(ApexStyle.warning)
                                .accessibilityHidden(true)
                            Text("远端缺少 \(missing.rawValue) 终端描述，长命令无法自动换行")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(ApexStyle.primary)
                                .lineLimit(1)
                            Button("切换为 \(missing.fallback.rawValue) 并重连") {
                                tab.applyTerminfoFallback(store: store)
                            }
                            .apexProminentButton()
                            .controlSize(.small)
                            .accessibilityIdentifier("terminal.terminfoFallbackButton")
                            Button {
                                tab.terminfoWarning = nil
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("关闭提示")
                            .accessibilityLabel("关闭提示")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .apexGlassCard(cornerRadius: 12, material: .regularMaterial, borderColor: ApexStyle.warning.opacity(0.4), shadowRadius: 8)
                        .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                } else if let osc52 = pane.pendingOSC52Request {
                    VStack {
                        let preview = osc52.text
                            .replacingOccurrences(of: "\r", with: " ")
                            .replacingOccurrences(of: "\n", with: " ")
                        let truncated = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
                        HStack(spacing: 8) {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundColor(ApexStyle.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(pane.session.name) 请求写入剪贴板 (\(osc52.byteCount) B)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(ApexStyle.primary)
                                    .lineLimit(1)
                                Text(truncated)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(ApexStyle.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("允许一次") {
                                pane.allowPendingOSC52Once()
                            }
                            .apexProminentButton()
                            .controlSize(.small)
                            Button("本次会话允许") {
                                pane.allowPendingOSC52ForSession()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button("拒绝") {
                                pane.denyPendingOSC52()
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            .foregroundColor(ApexStyle.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .apexGlassCard(cornerRadius: 12, material: .regularMaterial, borderColor: ApexStyle.accent.opacity(0.4), shadowRadius: 8)
                        .padding(.horizontal, ApexStyle.s4)
                        .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.opacity)
                } else if let notice = dropTransferNotice {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: dropTransferIsError ? "exclamationmark.triangle.fill" : (notice.hasPrefix("正在上传") ? "arrow.up.circle.fill" : "checkmark.circle.fill"))
                                .foregroundColor(dropTransferIsError ? ApexStyle.error : (notice.hasPrefix("正在上传") ? ApexStyle.accent : ApexStyle.success))
                            Text(notice)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(dropTransferIsError ? ApexStyle.error : ApexStyle.primary)
                                .lineLimit(1)
                            Button {
                                dropTransferNotice = nil
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .help("关闭提示")
                            .accessibilityLabel("关闭提示")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .apexGlassCard(
                            cornerRadius: 12,
                            material: .regularMaterial,
                            borderColor: (dropTransferIsError ? ApexStyle.error : ApexStyle.accent).opacity(0.4),
                            shadowRadius: 8
                        )
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

private struct SFTPTransferBoundView: View {
    @ObservedObject var presentation: TransferDrawerPresentation
    @Binding var currentPath: String
    @Binding var isLinkageEnabled: Bool
    let session: SSHSessionProtocol?
    let connectionState: SSHConnectionState
    let tabID: UUID?

    var body: some View {
        SFTPView(
            currentPath: $currentPath,
            isLinkageEnabled: $isLinkageEnabled,
            session: session,
            connectionState: connectionState,
            tabID: tabID,
            isTransferDrawerExpanded: $presentation.isPresented
        )
    }
}

private struct WorkspaceTransferOverlayHost: View {
    @ObservedObject var presentation: TransferDrawerPresentation
    let containerSize: CGSize

    var body: some View {
        if presentation.isPresented {
            let cardWidth = containerSize.width > 0
                ? min(560, max(320, containerSize.width - 24))
                : 540
            let cardHeight = containerSize.height > 0
                ? min(268, max(180, containerSize.height - 84))
                : 260
            TransferDrawer(isExpanded: $presentation.isPresented)
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(ApexStyle.border.opacity(0.6), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                .padding(.trailing, 12)
                .padding(.bottom, 40)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transfer.floatingCard")
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct StatusBarTransferIndicator: View {
    @ObservedObject private var transferManager = TransferManager.shared
    @ObservedObject var presentation: TransferDrawerPresentation
    let showsInlineProgress: Bool

    var body: some View {
        if !transferManager.tasks.isEmpty {
            Divider().frame(height: 12)

            if showsInlineProgress,
               let summary = TransferProgressSummary.make(
                   from: transferManager.tasks,
                   formattedTotalSpeed: transferManager.formattedTotalSpeed
               ) {
                let directionTint = summary.primaryTask.direction == .upload ? ApexStyle.accent : ApexStyle.success
                let directionIcon = summary.primaryTask.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"

                HStack(spacing: 6) {
                    Button {
                        withAnimation(ApexStyle.springSnappy) {
                            presentation.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: directionIcon)
                                .font(.system(size: 10.5))
                                .foregroundColor(directionTint)

                            Text(summary.primaryTask.fileName)
                                .font(.caption.monospaced())
                                .foregroundColor(ApexStyle.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 120, alignment: .leading)

                            if summary.otherActiveCount > 0 {
                                Text("+\(summary.otherActiveCount)")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(ApexStyle.accent.opacity(0.14), in: Capsule())
                                    .foregroundColor(ApexStyle.accent)
                            }

                            ApexTransferProgressTrack(
                                fraction: summary.progressFraction,
                                tint: directionTint,
                                height: 5
                            )
                            .frame(width: 60)

                            Text(summary.percentText)
                                .font(.caption.monospaced())
                                .monospacedDigit()
                                .foregroundColor(directionTint)

                            if !summary.speedText.isEmpty {
                                Text(summary.speedText)
                                    .font(.caption.monospaced())
                                    .monospacedDigit()
                                    .foregroundColor(ApexStyle.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(presentation.isPresented ? "收起传输任务面板" : "点击展开传输任务面板")
                    .accessibilityIdentifier("statusBar.transferInlineProgress")

                    ApexIconButton(
                        icon: "xmark",
                        label: "取消传输 \(summary.primaryTask.fileName)",
                        size: 16,
                        iconSize: 8
                    ) {
                        transferManager.cancelTask(id: summary.primaryTask.id)
                    }
                }
            } else {
                Button {
                    withAnimation(ApexStyle.springSnappy) {
                        presentation.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: transferManager.activeCount > 0 ? "arrow.triangle.2.circlepath" : "arrow.up.arrow.down")
                            .font(.system(size: 10))
                            .foregroundColor((transferManager.activeCount > 0 || presentation.isPresented) ? ApexStyle.accent : ApexStyle.secondary)
                        if let summary = TransferProgressSummary.make(
                            from: transferManager.tasks,
                            formattedTotalSpeed: transferManager.formattedTotalSpeed
                        ) {
                            let speedSuffix = summary.speedText.isEmpty ? "" : " · \(summary.speedText)"
                            Text("传输中 \(summary.activeCount) 项 · \(summary.percentText)\(speedSuffix)")
                                .font(.caption.monospaced())
                                .foregroundColor(ApexStyle.accent)
                        } else {
                            Text("传输记录 \(transferManager.tasks.count) 项")
                                .font(.caption.monospaced())
                                .foregroundColor(presentation.isPresented ? ApexStyle.accent : ApexStyle.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(presentation.isPresented ? "收起传输任务面板" : "点击查看文件传输记录")
                .accessibilityIdentifier("statusBar.transferButton")
            }
        }
    }
}

private struct WorkspaceBottomStatusBar: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject var tab: TerminalTabItem
    let showsDirectoryControls: Bool
    let transferPresentation: TransferDrawerPresentation
    
    var body: some View {
        HStack(spacing: 14) {
            if let pane = tab.activePane ?? tab.panes.first {
                ConnectionStatusView(tab: tab, pane: pane)
            }
            
            Text("UTF-8")
                .apexKeycap()
            
            if let pane = tab.activePane ?? tab.panes.first,
               let lastRecord = pane.ringBuffer.shellIntegration.lastCompletedRecord {
                Divider().frame(height: 12)
                Menu {
                    let records = Array(pane.ringBuffer.shellIntegration.allRecords().suffix(10).reversed())
                    ForEach(records) { rec in
                        let titleCmd = rec.commandText ?? "Shell 命令"
                        let statusBadge = rec.isFailed ? "✗ Exit \(rec.exitCode ?? 1)" : "✓"
                        Menu("\(statusBadge) \(titleCmd) (\(rec.formattedDuration))") {
                            if let cmd = rec.commandText, !cmd.isEmpty {
                                Button("复制命令文本") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(cmd, forType: .string)
                                }
                            }
                            Button("复制此命令输出") {
                                if let out = pane.ringBuffer.extractOSC133CommandOutput(for: rec) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(out, forType: .string)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: lastRecord.isFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(lastRecord.isFailed ? ApexStyle.error : ApexStyle.success)
                        Text(lastRecord.isFailed ? "Exit \(lastRecord.exitCode ?? 1) · \(lastRecord.formattedDuration)" : lastRecord.formattedDuration)
                            .font(.caption.monospaced())
                            .foregroundColor(lastRecord.isFailed ? ApexStyle.error : ApexStyle.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("OSC 133 Shell 集成：最近命令执行状态与耗时记录")

                if lastRecord.isFailed {
                    Button {
                        let output = pane.ringBuffer.extractLastOSC133CommandOutput()
                            ?? CommandBoundaryDetector.extractLastCommandOutput(from: pane.ringBuffer.allLines())
                            ?? lastRecord.commandText
                        if let output, !output.isEmpty {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(output, forType: .string)
                            NotificationCenter.default.post(
                                name: NSNotification.Name("ShowStatusToast"),
                                object: "已复制失败命令输出 (\(output.count) 字符)"
                            )
                        }
                    } label: {
                        Text("exit \(lastRecord.exitCode ?? 1)")
                            .font(.caption.monospaced())
                            .foregroundColor(ApexStyle.error)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ApexStyle.error.opacity(0.14), in: Capsule())
                            .overlay(Capsule().stroke(ApexStyle.error.opacity(0.35), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .help("点击复制失败命令完整输出 (⌘⌥C)")
                    .accessibilityLabel("复制失败命令输出")
                }
            }
            
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

            if showsDirectoryControls {
                StatusBarTransferIndicator(
                    presentation: transferPresentation,
                    showsInlineProgress: true
                )
            }
            
            Spacer()
            
            if showsDirectoryControls {
                let activeState = (tab.activePane ?? tab.panes.first)?.connectionState ?? tab.connectionState
                let pathText: String = {
                    switch activeState {
                    case .connected:
                        return tab.currentRemotePath
                    case .connecting:
                        return "等待连接…"
                    case .disconnected, .failed:
                        return "—"
                    }
                }()
                Text("\(L10n.currentDirectory): \(pathText)")
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
    }
}

private struct ConnectionStatusView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject var tab: TerminalTabItem
    @ObservedObject var pane: TerminalPaneItem

    var body: some View {
        HStack(spacing: 6) {
            if case .connecting = pane.connectionState {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
                    .frame(width: 9, height: 9)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 2)
            }
            Text("\(statusText) · \(tab.session.username)@\(tab.session.host):\(tab.session.port)")
                .font(.caption.monospaced())
                .lineLimit(1)
                .help(helpText)
        }
    }

    private var statusText: String {
        switch pane.connectionState {
        case .disconnected: return "已断开"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .failed(let message): return "连接失败：\(message)"
        }
    }

    private var helpText: String {
        switch pane.connectionState {
        case .connecting(let step) where !step.isEmpty:
            return step
        default:
            return statusText
        }
    }

    private var statusColor: Color {
        switch pane.connectionState {
        case .disconnected: return ApexStyle.secondary
        case .connecting: return ApexStyle.warning
        case .connected: return ApexStyle.success
        case .failed: return ApexStyle.error
        }
    }
}

struct TabButton: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject var tab: TerminalTabItem
    let isSelected: Bool
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
        switch tab.connectionState {
        case .connected:
            return Color(hex: tab.session.colorHex ?? "#0A84FF") ?? .blue
        case .connecting:
            return ApexStyle.warning
        case .disconnected:
            return ApexStyle.secondary.opacity(0.55)
        case .failed:
            return ApexStyle.error
        }
    }
    
    var body: some View {
        HStack(spacing: 7) {
            if case .connecting = tab.connectionState {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: dotColor.opacity(isSelected ? 0.6 : 0.2), radius: isSelected ? 3 : 1)
            }
            
            Text(tab.displayTitle)
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
