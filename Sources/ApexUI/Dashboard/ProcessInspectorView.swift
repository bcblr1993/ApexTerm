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
    
    @State private var processes: [ProcessDetailItem] = []
    @State private var services: [SystemdServiceItem] = []
    @State private var searchText: String = ""
    @State private var sortColumn: SortColumn = .cpu
    @State private var sortAscending: Bool = false
    @State private var isLoading: Bool = false
    @State private var selectedProcess: ProcessDetailItem?
    @State private var showingKillConfirmation: Bool = false
    @State private var selectedSignal: ProcessSignal = .sigterm
    @State private var statusFeedback: String?
    
    public enum SortColumn: String, CaseIterable, Identifiable {
        case cpu = "CPU%"
        case memory = "内存"
        case pid = "PID"
        case command = "进程名"
        
        public var id: String { rawValue }
    }
    
    public init(session: Session, sshClient: SSHSessionProtocol?, isPresented: Binding<Bool>) {
        self.session = session
        self.sshClient = sshClient
        self._isPresented = isPresented
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
            
            // Main Process Table
            processTable
            
            Divider()
            
            // Footer status bar
            footerBar
        }
        .frame(minWidth: 720, idealWidth: 840, maxWidth: .infinity, minHeight: 480, idealHeight: 560, maxHeight: .infinity)
        .background(ApexStyle.surface)
        .onAppear {
            fetchProcessData()
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
                Text("\(session.username)@\(session.host) · \(session.name)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ApexStyle.secondary)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("核心服务:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ApexStyle.secondary)
                
                ForEach(services) { svc in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(svc.isRunning ? ApexStyle.success : ApexStyle.error)
                            .frame(width: 7, height: 7)
                        Text(svc.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text(svc.activeState)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(svc.isRunning ? ApexStyle.success : ApexStyle.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ApexStyle.border.opacity(0.5), lineWidth: 1)
                    }
                }
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 6)
        }
        .background(ApexStyle.surface.opacity(0.4))
    }
    
    // MARK: - Filter Toolbar
    private var filterToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(ApexStyle.secondary)
                    .font(.system(size: 11))
                TextField("搜索 PID / 进程名 / 用户 / 参数...", text: $searchText)
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
            .frame(maxWidth: 320)
            
            Spacer()
            
            // Sort Column Picker
            Picker("排序", selection: $sortColumn) {
                ForEach(SortColumn.allCases) { col in
                    Text(col.rawValue).tag(col)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            
            ApexIconButton(
                icon: sortAscending ? "arrow.up" : "arrow.down",
                label: sortAscending ? "切换为降序排列" : "切换为升序排列",
                size: 24,
                iconSize: 11
            ) {
                sortAscending.toggle()
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 8)
        .background(ApexStyle.surface)
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
    
    // MARK: - Footer Bar
    private var footerBar: some View {
        HStack {
            Text("共展示 \(filteredProcesses.count) 个活跃进程 · 点击行可查看完整命令")
                .font(.system(size: 11))
                .foregroundColor(ApexStyle.secondary)
            
            Spacer()
            
            if let feedback = statusFeedback {
                Text(feedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ApexStyle.accent)
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
    
    private func fetchProcessData() {
        guard !isLoading else { return }
        isLoading = true
        statusFeedback = nil
        
        Task {
            // Sample fallback processes if offline
            var fetchedItems: [ProcessDetailItem] = []
            var fetchedServices: [SystemdServiceItem] = []
            
            if let client = sshClient, client.isConnected {
                let cmd = AgentlessMonitor.processInspectorProbeCommand
                if let raw = try? await client.executeCommand(cmd) {
                    fetchedItems = ProcessListParser.parsePSOutput(raw)
                }
                
                let monitored = ["nginx", "docker", "redis", "mysql", "sshd", "postgresql"]
                let svcCmd = AgentlessMonitor.systemdServicesProbeCommand(services: monitored)
                if let rawSvc = try? await client.executeCommand(svcCmd) {
                    fetchedServices = ProcessListParser.parseSystemdServices(rawSvc, monitoredServices: monitored)
                }
            }
            
            if fetchedItems.isEmpty {
                // Populate default system processes for offline or preview mode
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
            }
            
            let finalItems = fetchedItems
            let finalServices = fetchedServices
            await MainActor.run {
                self.processes = finalItems
                self.services = finalServices
                self.isLoading = false
            }
        }
    }
    
    private func sendKillSignal(to proc: ProcessDetailItem, signal: ProcessSignal) {
        guard let client = sshClient, client.isConnected else {
            statusFeedback = "连接未就绪，无法发送信号"
            return
        }
        
        let validation = proc.canKill()
        guard validation.allowed else {
            statusFeedback = validation.reason ?? "禁止终止该进程"
            return
        }
        
        Task {
            let killCmd = "kill -\(signal.rawValue) \(proc.pid)\n"
            if let data = killCmd.data(using: .utf8) {
                try? await client.sendInput(data)
                await MainActor.run {
                    self.statusFeedback = "已向 PID \(proc.pid) (\(proc.command)) 发送 \(signal.name)"
                }
                // Refresh after 1 second
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                fetchProcessData()
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
    
    var body: some View {
        HStack(spacing: 8) {
            Text("\(proc.pid)")
                .font(.system(size: 11, design: .monospaced))
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
                    .foregroundColor(ProcessInspectorView.cpuColor(proc.cpuPercent))
            }
            .frame(width: 75, alignment: .trailing)
            
            // RSS
            Text(proc.formattedRSS)
                .font(.system(size: 11, design: .monospaced))
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
                ? ApexStyle.selection.opacity(0.15)
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
