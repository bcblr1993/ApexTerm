import SwiftUI
import AppKit
import ApexCore
import ApexSSH

/// macOS native fluid & classy Process and Service Inspector
public struct ProcessInspectorView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    public let session: Session
    public let sshClient: SSHSessionProtocol?
    @Binding public var isPresented: Bool
    public var onOpenContainerShell: ((Session, String) -> Void)? = nil
    
    @State private var processes: [ProcessDetailItem] = []
    @State private var services: [SystemdServiceItem] = []
    @State private var containers: [ContainerItem] = []
    @State private var composeStacks: [DockerComposeStackItem] = []
    @State private var containerRuntime: ContainerRuntime? = nil
    @State private var containerErrorMessage: String? = nil
    @State private var listeningPorts: [ListeningPortItem] = []
    @State private var inspectorMode: InspectorMode = .processes
    @State private var searchText: String = ""
    @State private var sortColumn: SortColumn = .cpu
    @State private var sortAscending: Bool = false
    @State private var isLoading: Bool = false
    @State private var selectedProcess: ProcessDetailItem?
    @State private var showingKillConfirmation: Bool = false
    @State private var selectedSignal: ProcessSignal = .sigterm
    @State private var statusFeedback: String?
    @State private var activeLogTarget: RemoteLogTarget? = nil
    @State private var pendingContainerAction: (container: ContainerItem, action: ContainerAction)? = nil
    @State private var showingContainerActionConfirm: Bool = false
    @State private var showingAllSystemdServices: Bool = false
    @State private var pendingSystemdTarget: SystemdServiceItem? = nil
    @State private var fetchTask: Task<Void, Never>? = nil

    public enum InspectorMode: String, CaseIterable, Identifiable {
        case processes = "活跃进程"
        case containers = "容器"
        case listeningPorts = "监听端口"

        public var id: String { rawValue }
    }
    
    public enum SortColumn: String, CaseIterable, Identifiable {
        case cpu = "CPU%"
        case memory = "内存"
        case pid = "PID"
        case command = "进程名"
        
        public var id: String { rawValue }
    }
    
    public init(
        session: Session,
        sshClient: SSHSessionProtocol?,
        isPresented: Binding<Bool>,
        onOpenContainerShell: ((Session, String) -> Void)? = nil
    ) {
        self.session = session
        self.sshClient = sshClient
        self._isPresented = isPresented
        self.onOpenContainerShell = onOpenContainerShell
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar
            
            Divider()
            
            // Systemd Service Strip (Linux servers)
            if !services.isEmpty {
                systemdServicesStrip
                Divider()
            }
            
            // Toolbar: Search & Sort filter
            filterToolbar
            
            Divider()
            
            // Main Process, Container, or Listening Ports Table
            switch inspectorMode {
            case .processes:
                processTable
            case .containers:
                containersTable
            case .listeningPorts:
                listeningPortsTable
            }
            
            Divider()
            
            // Footer status bar
            footerBar
        }
        .frame(minWidth: 720, idealWidth: 840, maxWidth: .infinity, minHeight: 480, idealHeight: 560, maxHeight: .infinity)
        .background(ApexStyle.surface)
        .onAppear {
            fetchProcessData()
        }
        .onDisappear {
            fetchTask?.cancel()
            fetchTask = nil
        }
        .confirmationDialog(
            "终止进程确认",
            isPresented: $showingKillConfirmation,
            presenting: selectedProcess
        ) { proc in
            Button("发送 SIGTERM (优雅退出)", role: .none) {
                sendKillSignal(to: proc, signal: .sigterm)
            }
            Button("发送 SIGKILL (强制结束)", role: .destructive) {
                sendKillSignal(to: proc, signal: .sigkill)
            }
            Button("发送 SIGHUP (重载配置)", role: .none) {
                sendKillSignal(to: proc, signal: .sighup)
            }
            Button("取消", role: .cancel) {}
        } message: { proc in
            Text("确定要向进程 \(proc.command) (PID: \(proc.pid), 用户: \(proc.user)) 发送信号吗？")
        }
        .confirmationDialog(
            "容器操作确认",
            isPresented: $showingContainerActionConfirm,
            presenting: pendingContainerAction
        ) { req in
            Button("确认\(req.action.displayName) \(req.container.name)", role: req.action == .stop ? .destructive : .none) {
                executeContainerAction(req.container, action: req.action)
            }
            Button("取消", role: .cancel) {}
        } message: { req in
            Text("确定要对容器 \(req.container.name) (\(req.container.shortId)) 执行 \(req.action.rawValue) 吗？")
        }
        .sheet(item: $activeLogTarget) { target in
            RemoteLogViewerSheet(
                target: target,
                sshClient: sshClient,
                onServiceMutated: { fetchProcessData() }
            )
            .apexTheme()
        }
        .sheet(isPresented: $showingAllSystemdServices, onDismiss: {
            if let svc = pendingSystemdTarget {
                pendingSystemdTarget = nil
                activeLogTarget = .systemd(svc)
            }
        }) {
            SystemdAllServicesSheet(services: services) { svc in
                pendingSystemdTarget = svc
                showingAllSystemdServices = false
            }
            .apexTheme()
        }
    }
    
    // MARK: - Header Bar
    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(ApexStyle.accent)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("进程与服务监视中心")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ApexStyle.primary)
                    .lineLimit(1)
                let hostSubtitle = "\(session.username)@\(session.host) · \(session.name)"
                Text(hostSubtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ApexStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(hostSubtitle)
            }
            
            Spacer()
            
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            
            ApexIconButton(
                icon: "arrow.clockwise",
                label: "刷新进程列表 (⌘R)",
                size: 26,
                iconSize: 12
            ) {
                fetchProcessData()
            }
            .keyboardShortcut("r", modifiers: .command)
            
            ApexIconButton(
                icon: "xmark",
                label: "关闭面板 (Esc)",
                size: 26,
                iconSize: 11
            ) {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 10)
        .background(ApexStyle.subtleSurface.opacity(0.8))
    }
    
    // MARK: - Systemd Services Strip
    private var systemdServicesStrip: some View {
        let isOpenRC = services.first?.subState.lowercased().hasPrefix("openrc") ?? false
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(isOpenRC ? "OpenRC 服务:" : "Systemd 服务:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ApexStyle.secondary)
                
                ForEach(services.prefix(12)) { svc in
                    Button {
                        activeLogTarget = .systemd(svc)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(svc.isRunning ? ApexStyle.success : (svc.activeState == "failed" ? ApexStyle.error : ApexStyle.secondary))
                                .frame(width: 7, height: 7)
                            Text(svc.name)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(ApexStyle.primary)
                            Text(svc.activeState)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(svc.isRunning ? ApexStyle.success : (svc.activeState == "failed" ? ApexStyle.error : ApexStyle.secondary))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(ApexStyle.border.opacity(0.5), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("点击查看 \(svc.name) 的 journalctl 日志与启停控制")
                }

                if services.count > 12 {
                    Button {
                        showingAllSystemdServices = true
                    } label: {
                        Text("全部 \(services.count) 项…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(ApexStyle.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(ApexStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("查看全部动态发现的 Systemd 服务")
                }
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 6)
        }
        .background(ApexStyle.surface.opacity(0.4))
    }
    
    // MARK: - Filter Toolbar
    private var filterToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                modePicker
                toolbarSearchField
                    .frame(minWidth: 160, maxWidth: 280)
                Spacer(minLength: 4)
                trailingToolbarControls
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    modePicker
                    Spacer(minLength: 4)
                    trailingToolbarControls
                }
                toolbarSearchField
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 8)
        .background(ApexStyle.surface)
    }

    private var modePicker: some View {
        Picker("视图", selection: $inspectorMode) {
            Text("活跃进程 (\(processes.count))").monospacedDigit().tag(InspectorMode.processes)
            Text("容器 (\(containers.count))").monospacedDigit().tag(InspectorMode.containers)
            Text("监听端口 (\(listeningPorts.count))").monospacedDigit().tag(InspectorMode.listeningPorts)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("processInspector.modePicker")
    }

    private var toolbarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(ApexStyle.secondary)
                .font(.system(size: 11))
            TextField(
                searchPlaceholder,
                text: $searchText
            )
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
            if !searchText.isEmpty {
                ApexIconButton(
                    icon: "xmark.circle.fill",
                    label: "清空搜索",
                    size: 18,
                    iconSize: 10
                ) {
                    searchText = ""
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(ApexStyle.border, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var trailingToolbarControls: some View {
        if inspectorMode == .processes {
            HStack(spacing: 8) {
                Picker("排序", selection: $sortColumn) {
                    ForEach(SortColumn.allCases) { col in
                        Text(col.rawValue).tag(col)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                ApexIconButton(
                    icon: sortAscending ? "arrow.up" : "arrow.down",
                    label: sortAscending ? "切换为降序排列" : "切换为升序排列",
                    size: 24,
                    iconSize: 11
                ) {
                    sortAscending.toggle()
                }
            }
        } else if inspectorMode == .containers {
            let runningCount = filteredContainers.filter(\.isRunning).count
            HStack(spacing: 6) {
                Circle()
                    .fill(runningCount > 0 ? ApexStyle.success : ApexStyle.secondary)
                    .frame(width: 7, height: 7)
                Text("\(containerRuntime?.displayName ?? "容器") · 运行中: \(runningCount)/\(filteredContainers.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundColor(ApexStyle.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        } else {
            let publicCount = filteredListeningPorts.filter(\.isPubliclyExposed).count
            HStack(spacing: 6) {
                Circle()
                    .fill(publicCount > 0 ? ApexStyle.warning : ApexStyle.success)
                    .frame(width: 7, height: 7)
                Text("公网/全网卡暴露: \(publicCount) 项")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundColor(ApexStyle.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
    
    // MARK: - Process Table
    private var processTable: some View {
        VStack(spacing: 0) {
            // Table Header
            HStack(spacing: 8) {
                Text("PID")
                    .frame(width: 60, alignment: .leading)
                Text("用户")
                    .frame(width: 80, alignment: .leading)
                Text("状态")
                    .frame(width: 70, alignment: .leading)
                Text("CPU%")
                    .frame(width: 75, alignment: .trailing)
                Text("物理内存 (RSS)")
                    .frame(width: 95, alignment: .trailing)
                Text("进程名 / 命令参数")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("操作")
                    .frame(width: 65, alignment: .center)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(ApexStyle.secondary)
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 6)
            .background(ApexStyle.subtleSurface.opacity(0.6))
            
            Divider()
            
            // Table Rows
            if filteredProcesses.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "cpu")
                        .font(.system(size: 28))
                        .foregroundColor(ApexStyle.secondary.opacity(0.5))
                    Text(isLoading ? "正在检索远程进程数据..." : "未找到匹配的进程")
                        .font(.system(size: 12))
                        .foregroundColor(ApexStyle.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredProcesses) { proc in
                            ProcessRowView(
                                proc: proc,
                                isSelected: selectedProcess?.pid == proc.pid,
                                onSelect: { selectedProcess = proc },
                                onKill: {
                                    selectedProcess = proc
                                    showingKillConfirmation = true
                                }
                            )
                            Divider()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Containers Table
    private var containersTable: some View {
        VStack(spacing: 0) {
            if !composeStacks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text("Compose 栈:")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(ApexStyle.secondary)
                        ForEach(composeStacks) { stack in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(stack.isRunning ? ApexStyle.success : ApexStyle.secondary)
                                    .frame(width: 6, height: 6)
                                Text(stack.name)
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(ApexStyle.primary)
                                Text(stack.status)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(stack.isRunning ? ApexStyle.success : ApexStyle.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(ApexStyle.border.opacity(0.5), lineWidth: 0.75))
                            .help(stack.configFiles.isEmpty ? stack.name : "\(stack.name)\n\(stack.configFiles)")
                        }
                    }
                    .padding(.horizontal, ApexStyle.s4)
                    .padding(.vertical, 6)
                }
                .background(ApexStyle.surface.opacity(0.5))
                Divider()
            }

            HStack(spacing: 8) {
                Text("容器名 / ID")
                    .frame(width: 145, alignment: .leading)
                Text("镜像")
                    .frame(width: 120, alignment: .leading)
                Text("状态")
                    .frame(width: 72, alignment: .leading)
                Text("运行时长")
                    .frame(width: 82, alignment: .leading)
                Text("实时资源 (CPU / MEM / NET / BLK) · 端口")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("操作")
                    .frame(width: 112, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(ApexStyle.secondary)
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 6)
            .background(ApexStyle.subtleSurface.opacity(0.6))

            Divider()

            if filteredContainers.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "shippingbox")
                        .font(.system(size: 28))
                        .foregroundColor(ApexStyle.secondary.opacity(0.5))
                    if let containerErrorMessage, !containerErrorMessage.isEmpty {
                        Text(containerErrorMessage)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(ApexStyle.error)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    } else {
                        Text(isLoading ? "正在探测远程 Docker / Podman 容器..." : (containerRuntime == nil ? "未在远端检测到 Docker 或 Podman 引擎" : "未找到匹配的容器"))
                            .font(.system(size: 12))
                            .foregroundColor(ApexStyle.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredContainers) { container in
                            ContainerRowView(
                                container: container,
                                onExecShell: {
                                    if let cmd = AgentlessMonitor.containerExecCommand(runtime: container.runtime, id: container.id) {
                                        isPresented = false
                                        onOpenContainerShell?(session, cmd)
                                    }
                                },
                                onViewLogs: {
                                    activeLogTarget = .container(container)
                                },
                                onRequestAction: { action in
                                    pendingContainerAction = (container, action)
                                    showingContainerActionConfirm = true
                                }
                            )
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Listening Ports Table
    private var listeningPortsTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("协议")
                    .frame(width: 56, alignment: .leading)
                Text("监听地址与端口")
                    .frame(width: 170, alignment: .leading)
                Text("暴露范围")
                    .frame(width: 96, alignment: .leading)
                Text("PID")
                    .frame(width: 68, alignment: .leading)
                Text("所属进程")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("快捷操作")
                    .frame(width: 165, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(ApexStyle.secondary)
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 6)
            .background(ApexStyle.subtleSurface.opacity(0.6))

            Divider()

            if filteredListeningPorts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "network")
                        .font(.system(size: 28))
                        .foregroundColor(ApexStyle.secondary.opacity(0.5))
                    Text(isLoading ? "正在探测远程监听端口..." : "未找到匹配的监听端口")
                        .font(.system(size: 12))
                        .foregroundColor(ApexStyle.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredListeningPorts) { item in
                            ListeningPortRowView(
                                item: item,
                                onCopyEndpoint: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.endpointDisplay, forType: .string)
                                    statusFeedback = "已复制监听端点 \(item.endpointDisplay)"
                                },
                                onCreateTunnel: {
                                    createLocalTunnel(for: item)
                                }
                            )
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer Bar
    private var footerBar: some View {
        HStack {
            Text(footerSummaryText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(ApexStyle.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            
            Spacer()
            
            if let feedback = statusFeedback {
                Text(feedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ApexStyle.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(feedback)
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 6)
        .background(ApexStyle.subtleSurface.opacity(0.5))
    }
    
    // MARK: - Data Fetching & Operations
    private var filteredProcesses: [ProcessDetailItem] {
        var result = processes
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                "\($0.pid)".contains(query) ||
                $0.command.lowercased().contains(query) ||
                $0.user.lowercased().contains(query) ||
                $0.fullCommandLine.lowercased().contains(query)
            }
        }
        
        result.sort { a, b in
            switch sortColumn {
            case .cpu:
                return sortAscending ? (a.cpuPercent < b.cpuPercent) : (a.cpuPercent > b.cpuPercent)
            case .memory:
                return sortAscending ? (a.rssBytes < b.rssBytes) : (a.rssBytes > b.rssBytes)
            case .pid:
                return sortAscending ? (a.pid < b.pid) : (a.pid > b.pid)
            case .command:
                return sortAscending ? (a.command < b.command) : (a.command > b.command)
            }
        }
        return result
    }

    private var searchPlaceholder: String {
        switch inspectorMode {
        case .processes: return "搜索 PID / 进程名 / 用户 / 参数..."
        case .containers: return "搜索容器名 / 镜像 / 端口 / 状态..."
        case .listeningPorts: return "搜索端口 / 进程 / 协议 / 公网..."
        }
    }

    private var footerSummaryText: String {
        switch inspectorMode {
        case .processes:
            return "共展示 \(filteredProcesses.count) 个活跃进程 · 点击行可查看完整命令"
        case .containers:
            return "共检测到 \(filteredContainers.count) 个容器 · 支持一键进入容器终端 (exec) 与查看日志"
        case .listeningPorts:
            return "共检测到 \(filteredListeningPorts.count) 个监听端口 · 支持一键生成本地端口转发隧道 (-L)"
        }
    }

    private var filteredContainers: [ContainerItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return containers }
        return containers.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.shortId.localizedCaseInsensitiveContains(query)
                || $0.image.localizedCaseInsensitiveContains(query)
                || $0.state.localizedCaseInsensitiveContains(query)
                || $0.ports.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredListeningPorts: [ListeningPortItem] {
        ListeningPortParser.filter(listeningPorts, query: searchText)
    }

    private func createLocalTunnel(for item: ListeningPortItem) {
        let tunnel = item.toLocalForwardingTunnel(
            sessionId: session.id,
            existingTunnels: SSHTunnelManager.shared.tunnels
        )
        do {
            try SSHTunnelManager.shared.addTunnel(tunnel)
            statusFeedback = "已创建本地转发隧道 127.0.0.1:\(tunnel.bindPort) → 127.0.0.1:\(tunnel.targetPort)"
        } catch {
            statusFeedback = error.localizedDescription
        }
    }
    
    private func fetchProcessData() {
        fetchTask?.cancel()
        isLoading = true
        statusFeedback = nil
        
        let task = Task {
            // Sample fallback processes if offline
            var fetchedItems: [ProcessDetailItem] = []
            var fetchedServices: [SystemdServiceItem] = []
            var fetchedContainers: [ContainerItem] = []
            var fetchedComposeStacks: [DockerComposeStackItem] = []
            var fetchedContainerRuntime: ContainerRuntime? = nil
            var fetchedContainerError: String? = nil
            var fetchedPorts: [ListeningPortItem] = []
            var fetchFailureFeedback: String? = nil
            
            if let client = sshClient, client.isConnected {
                async let psAttempt: Result<SSHCommandResult, Error> = {
                    do { return .success(try await client.executeCommandWithResult(AgentlessMonitor.processInspectorProbeCommand)) }
                    catch { return .failure(error) }
                }()
                async let dynSvcAttempt: Result<SSHCommandResult, Error> = {
                    do { return .success(try await client.executeCommandWithResult(AgentlessMonitor.systemdDynamicProbeCommand)) }
                    catch { return .failure(error) }
                }()
                async let contAttempt: Result<SSHCommandResult, Error> = {
                    do { return .success(try await client.executeCommandWithResult(AgentlessMonitor.containerListProbeCommand)) }
                    catch { return .failure(error) }
                }()
                async let composeAttempt: Result<SSHCommandResult, Error> = {
                    do { return .success(try await client.executeCommandWithResult(AgentlessMonitor.dockerComposeStacksProbeCommand)) }
                    catch { return .failure(error) }
                }()
                async let portsAttempt: Result<SSHCommandResult, Error> = {
                    do { return .success(try await client.executeCommandWithResult(AgentlessMonitor.listeningPortsProbeCommand)) }
                    catch { return .failure(error) }
                }()

                let (psResult, dynSvcResult, contResult, composeResult, portsResult) = await (psAttempt, dynSvcAttempt, contAttempt, composeAttempt, portsAttempt)
                guard !Task.isCancelled else { return }

                switch psResult {
                case .success(let res):
                    if res.exitCode == 0 || !res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        fetchedItems = ProcessListParser.parsePSOutput(res.stdout)
                    } else {
                        let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        fetchFailureFeedback = err.isEmpty ? "进程列表获取失败 (退出码 \(res.exitCode))" : "进程列表获取失败: \(err)"
                    }
                case .failure(let error):
                    fetchFailureFeedback = "进程列表获取失败: \(error.localizedDescription)"
                }

                if case .success(let dynRes) = dynSvcResult, dynRes.exitCode == 0 {
                    fetchedServices = AgentlessMonitor.parseSystemdDynamicOutput(dynRes.stdout)
                }
                if fetchedServices.isEmpty && !Task.isCancelled {
                    let monitored = ["nginx", "docker", "redis", "mysql", "sshd", "postgresql"]
                    let svcCmd = AgentlessMonitor.systemdServicesProbeCommand(services: monitored)
                    if let rawSvc = try? await client.executeCommandWithResult(svcCmd), rawSvc.exitCode == 0 {
                        fetchedServices = ProcessListParser.parseSystemdServices(rawSvc.stdout, monitoredServices: monitored)
                    }
                }
                if fetchedServices.isEmpty && !Task.isCancelled {
                    if let rcRes = try? await client.executeCommandWithResult(AgentlessMonitor.openRCServicesProbeCommand), rcRes.exitCode == 0 {
                        fetchedServices = AgentlessMonitor.parseOpenRCOutput(rcRes.stdout)
                    }
                }

                switch contResult {
                case .success(let res):
                    let parsed = AgentlessMonitor.parseContainerProbeResult(res.stdout)
                    fetchedContainerRuntime = parsed.runtime
                    fetchedContainers = parsed.items
                    let errTrimmed = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let parsedErr = parsed.errorMessage, !parsedErr.isEmpty {
                        fetchedContainerError = parsedErr
                    } else if res.exitCode != 0 && parsed.items.isEmpty && !errTrimmed.isEmpty {
                        fetchedContainerError = errTrimmed
                    }
                case .failure(let error):
                    fetchedContainerError = "容器探测失败: \(error.localizedDescription)"
                }

                if let runtime = fetchedContainerRuntime, fetchedContainers.contains(where: \.isRunning), !Task.isCancelled {
                    if let statsRes = try? await client.executeCommandWithResult(AgentlessMonitor.containerStatsProbeCommand(runtime: runtime)),
                       statsRes.exitCode == 0 {
                        let stats = AgentlessMonitor.parseContainerStatsOutput(statsRes.stdout)
                        fetchedContainers = AgentlessMonitor.mergingStats(stats, into: fetchedContainers)
                    }
                }

                if case .success(let composeRes) = composeResult, composeRes.exitCode == 0 {
                    fetchedComposeStacks = AgentlessMonitor.parseDockerComposeStacksOutput(composeRes.stdout)
                }

                if case .success(let portsRes) = portsResult, portsRes.exitCode == 0 {
                    fetchedPorts = ListeningPortParser.parseOutput(portsRes.stdout)
                }
            }
            
            if sshClient == nil, fetchedItems.isEmpty {
                // Populate default system processes only in standalone SwiftUI preview mode without a session client
                fetchedItems = [
                    ProcessDetailItem(pid: 1, user: "root", cpuPercent: 0.0, memPercent: 0.1, rssBytes: 11840 * 1024, state: .sleeping, command: "systemd", fullCommandLine: "/sbin/init"),
                    ProcessDetailItem(pid: 684, user: "root", cpuPercent: 0.1, memPercent: 0.1, rssBytes: 8420 * 1024, state: .sleeping, command: "sshd", fullCommandLine: "/usr/sbin/sshd -D"),
                    ProcessDetailItem(pid: 1024, user: "deploy", cpuPercent: 3.4, memPercent: 4.8, rssBytes: 196608 * 1024, state: .running, command: "node", fullCommandLine: "node /var/www/server.js --port 3000"),
                    ProcessDetailItem(pid: 2048, user: "ubuntu", cpuPercent: 1.2, memPercent: 2.5, rssBytes: 102400 * 1024, state: .sleeping, command: "python3", fullCommandLine: "python3 /app/worker.py"),
                    ProcessDetailItem(pid: 3072, user: "redis", cpuPercent: 0.5, memPercent: 1.0, rssBytes: 40960 * 1024, state: .sleeping, command: "redis-server", fullCommandLine: "redis-server *:6379"),
                    ProcessDetailItem(pid: 4096, user: "nginx", cpuPercent: 0.2, memPercent: 0.6, rssBytes: 24576 * 1024, state: .sleeping, command: "nginx", fullCommandLine: "nginx: worker process")
                ]
                fetchedServices = [
                    SystemdServiceItem(name: "nginx", activeState: "active"),
                    SystemdServiceItem(name: "docker", activeState: "active"),
                    SystemdServiceItem(name: "redis", activeState: "active"),
                    SystemdServiceItem(name: "sshd", activeState: "active")
                ]
                fetchedContainerRuntime = .docker
                fetchedContainers = [
                    ContainerItem(id: "a1b2c3d4e5f6", name: "api-gateway", image: "nginx:1.27-alpine", state: "running", status: "Up 3 days", ports: "0.0.0.0:80->80/tcp", runtime: .docker),
                    ContainerItem(id: "f6e5d4c3b2a1", name: "redis-cache", image: "redis:7-alpine", state: "running", status: "Up 3 days", ports: "127.0.0.1:6379->6379/tcp", runtime: .docker)
                ]
                fetchedPorts = [
                    ListeningPortItem(proto: "TCP", bindAddress: "0.0.0.0", port: 22, pid: 684, processName: "sshd"),
                    ListeningPortItem(proto: "TCP", bindAddress: "0.0.0.0", port: 80, pid: 4096, processName: "nginx"),
                    ListeningPortItem(proto: "TCP", bindAddress: "127.0.0.1", port: 3000, pid: 1024, processName: "node"),
                    ListeningPortItem(proto: "TCP", bindAddress: "127.0.0.1", port: 6379, pid: 3072, processName: "redis-server")
                ]
            }
            
            guard !Task.isCancelled else { return }
            let finalItems = fetchedItems
            let finalServices = fetchedServices
            let finalContainers = fetchedContainers
            let finalComposeStacks = fetchedComposeStacks
            let finalRuntime = fetchedContainerRuntime
            let finalContainerError = fetchedContainerError
            let finalPorts = fetchedPorts
            let finalFeedback = fetchFailureFeedback
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.processes = finalItems
                self.services = finalServices
                self.containers = finalContainers
                self.composeStacks = finalComposeStacks
                self.containerRuntime = finalRuntime
                self.containerErrorMessage = finalContainerError
                self.listeningPorts = finalPorts
                if let finalFeedback {
                    self.statusFeedback = finalFeedback
                }
                self.isLoading = false
            }
        }
        fetchTask = task
    }
    
    public static func performKillSignal(to proc: ProcessDetailItem, signal: ProcessSignal, client: SSHSessionProtocol?) async -> String {
        guard let client = client, client.isConnected else {
            return "连接未就绪，无法发送信号"
        }

        let validation = proc.canKill()
        guard validation.allowed else {
            return validation.reason ?? "禁止终止该进程"
        }

        let killCmd = "kill -\(signal.rawValue) \(proc.pid) 2>&1"
        do {
            let result = try await client.executeCommandWithResult(killCmd)
            let combined = [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if result.exitCode != 0 || (!combined.isEmpty && (
                combined.localizedCaseInsensitiveContains("not permitted") ||
                combined.localizedCaseInsensitiveContains("permission denied") ||
                combined.localizedCaseInsensitiveContains("no such process") ||
                combined.localizedCaseInsensitiveContains("kill:")
            )) {
                let reason = combined.isEmpty ? "退出码 \(result.exitCode)" : combined
                return "发送信号失败: \(reason)"
            }
            return "已向 PID \(proc.pid) (\(proc.command)) 发送 \(signal.name)"
        } catch {
            return "发送信号失败: \(error.localizedDescription)"
        }
    }

    private func sendKillSignal(to proc: ProcessDetailItem, signal: ProcessSignal) {
        Task {
            let feedback = await Self.performKillSignal(to: proc, signal: signal, client: sshClient)
            await MainActor.run {
                self.statusFeedback = feedback
            }
            if feedback.hasPrefix("已向 PID") {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                fetchProcessData()
            }
        }
    }

    private func executeContainerAction(_ container: ContainerItem, action: ContainerAction) {
        guard let client = sshClient, client.isConnected else {
            statusFeedback = "连接未就绪，无法操作容器"
            return
        }
        guard let cmd = AgentlessMonitor.containerActionCommand(runtime: container.runtime, id: container.id, action: action) else {
            statusFeedback = "容器标识校验失败，已拦截不安全命令"
            return
        }
        isLoading = true
        Task {
            do {
                let result = try await client.executeCommandWithResult(cmd)
                let combined = [result.stdout, result.stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                await MainActor.run {
                    self.isLoading = false
                    if result.exitCode == 0 {
                        self.statusFeedback = combined.isEmpty
                            ? "已对容器 \(container.name) 执行 \(action.rawValue)"
                            : "[\(container.name)] \(combined)"
                    } else {
                        let reason = combined.isEmpty ? "退出码 \(result.exitCode)" : combined
                        self.statusFeedback = "容器操作失败: \(reason)"
                    }
                }
                if result.exitCode == 0 {
                    fetchProcessData()
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.statusFeedback = "容器操作失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Style Helpers
    static func cpuColor(_ cpu: Double) -> Color {
        if cpu > 80 { return ApexStyle.error }
        if cpu > 40 { return ApexStyle.warning }
        return ApexStyle.primary
    }
    
    static func stateColor(_ state: ProcessState) -> Color {
        switch state {
        case .running: return ApexStyle.success
        case .sleeping: return ApexStyle.secondary
        case .diskSleep: return ApexStyle.warning
        case .zombie: return ApexStyle.error
        case .stopped: return ApexStyle.warning
        case .unknown: return ApexStyle.secondary
        }
    }
}

private struct ProcessRowView: View {
    let proc: ProcessDetailItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onKill: () -> Void
    
    @State private var isHovered = false
    
    private var selectedRowBackground: Color {
        if let sel = NSColor(ApexStyle.selection).usingColorSpace(.sRGB),
           let surf = NSColor(ApexStyle.surface).usingColorSpace(.sRGB),
           abs(sel.redComponent - surf.redComponent) < 0.01,
           abs(sel.greenComponent - surf.greenComponent) < 0.01,
           abs(sel.blueComponent - surf.blueComponent) < 0.01 {
            return ApexStyle.accent.opacity(0.16)
        }
        return ApexStyle.selection
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(proc.pid)")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(ApexStyle.secondary)
                .frame(width: 60, alignment: .leading)
            
            Text(proc.user)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ApexStyle.primary)
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)
            
            // State badge
            Text(proc.state.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(ProcessInspectorView.stateColor(proc.state))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(ProcessInspectorView.stateColor(proc.state).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                .frame(width: 70, alignment: .leading)
                .help(proc.state.displayName)
            
            // CPU%
            HStack(spacing: 4) {
                Text(String(format: "%.1f%%", proc.cpuPercent))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(ProcessInspectorView.cpuColor(proc.cpuPercent))
            }
            .frame(width: 75, alignment: .trailing)
            
            // RSS
            Text(proc.formattedRSS)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(ApexStyle.primary)
                .frame(width: 95, alignment: .trailing)
            
            // Command & full commandline
            VStack(alignment: .leading, spacing: 1) {
                Text(proc.command)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ApexStyle.primary)
                    .lineLimit(1)
                if proc.fullCommandLine != proc.command {
                    Text(proc.fullCommandLine)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(proc.fullCommandLine)
            
            // Action button
            if proc.isProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(ApexStyle.secondary.opacity(0.6))
                    .frame(width: 65, alignment: .center)
                    .accessibilityLabel("受保护的核心系统进程，禁止终止")
                    .help("受保护的核心系统进程，禁止终止")
            } else {
                ApexActionButton("终止", tint: ApexStyle.error, size: .small) {
                    onKill()
                }
                .frame(width: 65, alignment: .center)
                .help("终止进程 (SIGTERM / SIGKILL)")
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? selectedRowBackground
                : (isHovered ? ApexStyle.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(ApexStyle.hoverTransition) {
                isHovered = hovering
            }
        }
    }
}

private struct ListeningPortRowView: View {
    let item: ListeningPortItem
    let onCopyEndpoint: () -> Void
    let onCreateTunnel: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(item.proto)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(ApexStyle.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 56, alignment: .leading)

            Text(item.endpointDisplay)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(ApexStyle.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
                .help(item.endpointDisplay)

            HStack(spacing: 4) {
                Circle()
                    .fill(item.isPubliclyExposed ? ApexStyle.warning : ApexStyle.success)
                    .frame(width: 6, height: 6)
                Text(item.exposureBadgeText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(item.isPubliclyExposed ? ApexStyle.warning : ApexStyle.success)
                    .lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)

            Text(item.pid.map { "\($0)" } ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(ApexStyle.secondary)
                .frame(width: 68, alignment: .leading)

            Text(item.processName.isEmpty ? "未知或内核进程" : item.processName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(ApexStyle.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ApexActionButton("复制", tint: ApexStyle.secondary, size: .small) {
                    onCopyEndpoint()
                }
                .help("复制监听地址与端口")

                ApexActionButton("转本地隧道", icon: "arrow.triangle.swap", tint: ApexStyle.accent, size: .small) {
                    onCreateTunnel()
                }
                .help("一键创建指向该端口的本地转发隧道 (-L)")
            }
            .frame(width: 165, alignment: .trailing)
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 6)
        .background(isHovered ? ApexStyle.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(ApexStyle.hoverTransition) {
                isHovered = hovering
            }
        }
    }
}
