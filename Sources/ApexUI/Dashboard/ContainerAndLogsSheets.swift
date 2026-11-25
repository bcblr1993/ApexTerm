import SwiftUI
import AppKit
import ApexCore
import ApexSSH

/// Row view representing a Docker or Podman container in `ProcessInspectorView`.
struct ContainerRowView: View {
    let container: ContainerItem
    let onExecShell: () -> Void
    let onViewLogs: () -> Void
    let onRequestAction: (ContainerAction) -> Void

    @State private var isHovered = false

    private var stateColor: Color {
        switch container.state.lowercased() {
        case "running":
            return ApexStyle.success
        case "paused", "restarting":
            return ApexStyle.warning
        default:
            return ApexStyle.secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(container.name)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(ApexStyle.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(container.runtime.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(ApexStyle.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                        .lineLimit(1)
                        .fixedSize()
                }
                Text(container.shortId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ApexStyle.secondary)
                    .lineLimit(1)
            }
            .frame(width: 145, alignment: .leading)
            .help("\(container.name) (\(container.shortId))")

            Text(container.image)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ApexStyle.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 120, alignment: .leading)
                .help(container.image)

            HStack(spacing: 4) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                Text(container.state)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(stateColor)
                    .lineLimit(1)
            }
            .frame(width: 72, alignment: .leading)

            Text(container.status)
                .font(.system(size: 10.5))
                .foregroundColor(ApexStyle.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 88, alignment: .leading)
                .help(container.status)

            Text(container.ports.isEmpty ? "—" : container.ports)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(ApexStyle.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(container.ports)

            HStack(spacing: 4) {
                ApexIconButton(
                    icon: "terminal",
                    label: "进入容器终端",
                    size: 24,
                    iconSize: 11,
                    tint: ApexStyle.accent
                ) {
                    onExecShell()
                }
                .disabled(!container.isRunning)
                .help(container.isRunning ? "打开新标签页进入容器终端 (exec)" : "容器未运行，无法进入终端")

                ApexIconButton(
                    icon: "doc.text.magnifyingglass",
                    label: "查看容器日志",
                    size: 24,
                    iconSize: 11
                ) {
                    onViewLogs()
                }
                .help("查看容器最近 200 行日志")

                if container.isRunning {
                    ApexIconButton(
                        icon: "arrow.clockwise",
                        label: "重启容器",
                        size: 24,
                        iconSize: 11,
                        tint: ApexStyle.warning
                    ) {
                        onRequestAction(.restart)
                    }
                    .help("重启容器")

                    ApexIconButton(
                        icon: "stop.fill",
                        label: "停止容器",
                        size: 24,
                        iconSize: 10,
                        tint: ApexStyle.error
                    ) {
                        onRequestAction(.stop)
                    }
                    .help("停止容器")
                } else {
                    ApexIconButton(
                        icon: "play.fill",
                        label: "启动容器",
                        size: 24,
                        iconSize: 10,
                        tint: ApexStyle.success
                    ) {
                        onRequestAction(.start)
                    }
                    .help("启动容器")
                }
            }
            .frame(width: 112, alignment: .trailing)
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

/// Target descriptor for `RemoteLogViewerSheet`.
enum RemoteLogTarget: Identifiable {
    case container(ContainerItem)
    case systemd(SystemdServiceItem)

    var id: String {
        switch self {
        case .container(let item): return "container:\(item.runtime.rawValue):\(item.id)"
        case .systemd(let svc): return "systemd:\(svc.name)"
        }
    }

    var title: String {
        switch self {
        case .container(let item): return "\(item.runtime.displayName) 容器日志 · \(item.name)"
        case .systemd(let svc): return "Systemd 服务 · \(svc.name)"
        }
    }

    var subtitle: String {
        switch self {
        case .container(let item): return "\(item.image) · \(item.shortId)"
        case .systemd(let svc): return "状态: \(svc.activeState)\(svc.subState.isEmpty ? "" : " (\(svc.subState))")"
        }
    }
}

/// Reusable modal sheet displaying remote container logs or systemd journalctl output with safe unit lifecycle controls.
struct RemoteLogViewerSheet: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    let target: RemoteLogTarget
    let sshClient: SSHSessionProtocol?
    let onServiceMutated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var rawLogs: String = ""
    @State private var filterText: String = ""
    @State private var isLoading: Bool = false
    @State private var actionFeedback: String? = nil
    @State private var pendingSystemdAction: SystemdServiceAction? = nil
    @State private var showSystemdActionConfirm: Bool = false

    private var filteredLogLines: String {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rawLogs }
        let matched = rawLogs.components(separatedBy: .newlines).filter {
            $0.localizedCaseInsensitiveContains(query)
        }
        return matched.isEmpty ? "（无匹配日志行）" : matched.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(ApexStyle.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(target.title)
                    Text(target.subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(target.subtitle)
                }

                Spacer()

                if isLoading {
                    ProgressView().controlSize(.small)
                }

                ApexIconButton(
                    icon: "arrow.clockwise",
                    label: "刷新日志",
                    size: 26,
                    iconSize: 12
                ) {
                    fetchLogs()
                }
                .help("重新拉取最新日志")

                ApexIconButton(
                    icon: "xmark",
                    label: "关闭",
                    size: 26,
                    iconSize: 11
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 10)
            .background(ApexStyle.subtleSurface)

            Divider()

            // Optional Systemd control strip + log filter toolbar
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(ApexStyle.secondary)
                    TextField("过滤日志关键字...", text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !filterText.isEmpty {
                        ApexIconButton(
                            icon: "xmark.circle.fill",
                            label: "清空过滤",
                            size: 18,
                            iconSize: 10
                        ) {
                            filterText = ""
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ApexStyle.border, lineWidth: 1))
                .frame(maxWidth: 260)

                Spacer()

                if case .systemd(let svc) = target {
                    HStack(spacing: 6) {
                        ApexActionButton("启动", icon: "play.fill", tint: ApexStyle.success, size: .small) {
                            pendingSystemdAction = .start
                            showSystemdActionConfirm = true
                        }
                        ApexActionButton("重启", icon: "arrow.clockwise", tint: ApexStyle.warning, size: .small) {
                            pendingSystemdAction = .restart
                            showSystemdActionConfirm = true
                        }
                        if svc.isProtectedForStop {
                            Label("核心服务禁停", systemImage: "lock.fill")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(ApexStyle.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(ApexStyle.subtleSurface, in: Capsule())
                                .accessibilityLabel("核心系统服务 (\(svc.name)) 禁止直接停止")
                                .help("核心系统服务 (\(svc.name)) 禁止直接停止，以防远程连接中断")
                        } else {
                            ApexActionButton("停止", icon: "stop.fill", tint: ApexStyle.error, size: .small) {
                                pendingSystemdAction = .stop
                                showSystemdActionConfirm = true
                            }
                        }
                    }
                }

                ApexActionButton("复制全部", icon: "doc.on.doc", tint: ApexStyle.secondary, size: .small) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(filteredLogLines, forType: .string)
                    actionFeedback = "已复制日志到剪贴板"
                }
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 8)
            .background(ApexStyle.surface)

            Divider()

            ScrollView {
                Text(rawLogs.isEmpty ? (isLoading ? "正在拉取远端日志..." : "（暂无日志输出）") : filteredLogLines)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(ApexStyle.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ApexStyle.s4)
            }
            .background(ApexStyle.subtleSurface.opacity(0.45))

            Divider()

            HStack {
                let footerMessage = actionFeedback ?? "只读日志视图 · 非 root 用户如提示权限不足请使用终端提权查看"
                Text(footerMessage)
                    .font(.system(size: 11))
                    .foregroundColor(actionFeedback == nil ? ApexStyle.secondary : ApexStyle.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(footerMessage)
                Spacer()
                ApexActionButton("关闭", tint: ApexStyle.secondary, size: .regular) {
                    dismiss()
                }
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 10)
            .background(ApexStyle.subtleSurface.opacity(0.6))
        }
        .frame(width: 720, height: 500)
        .background(ApexStyle.surface)
        .onAppear { fetchLogs() }
        .confirmationDialog(
            "Systemd 服务操作确认",
            isPresented: $showSystemdActionConfirm,
            presenting: pendingSystemdAction
        ) { action in
            Button("确认\(action.displayName)", role: action == .stop ? .destructive : .none) {
                executeSystemdAction(action)
            }
            Button("取消", role: .cancel) {}
        } message: { action in
            if case .systemd(let svc) = target {
                Text("确定要对服务 \(svc.name) 执行 systemctl \(action.rawValue) 吗？")
            }
        }
    }

    private func fetchLogs() {
        guard !isLoading else { return }
        guard let client = sshClient, client.isConnected else {
            rawLogs = "当前处于离线预览状态或会话未连接。"
            return
        }
        let command: String?
        switch target {
        case .container(let item):
            command = AgentlessMonitor.containerLogsCommand(runtime: item.runtime, id: item.id, tail: 200)
        case .systemd(let svc):
            command = AgentlessMonitor.systemdJournalCommand(unit: svc.name, lines: 100)
        }
        guard let cmd = command else {
            rawLogs = "目标标识校验失败，已阻止不安全的命令执行。"
            return
        }
        isLoading = true
        Task {
            do {
                let out = try await client.executeCommand(cmd)
                await MainActor.run {
                    self.rawLogs = out.trimmingCharacters(in: .newlines)
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.rawLogs = "拉取日志失败: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }

    private func executeSystemdAction(_ action: SystemdServiceAction) {
        guard case .systemd(let svc) = target else { return }
        guard let client = sshClient, client.isConnected else {
            actionFeedback = "会话未连接，无法执行服务操作"
            return
        }
        guard let cmd = AgentlessMonitor.systemdActionCommand(unit: svc.name, action: action) else {
            actionFeedback = "核心服务 \(svc.name) 受保护或名称非法，已阻止操作"
            return
        }
        isLoading = true
        Task {
            do {
                let out = try await client.executeCommand(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    self.isLoading = false
                    self.actionFeedback = out.isEmpty ? "已执行 systemctl \(action.rawValue) \(svc.name)" : out
                    onServiceMutated()
                    fetchLogs()
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.actionFeedback = "执行失败: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Full list modal showing all dynamically discovered Systemd services with quick filtering.
struct SystemdAllServicesSheet: View {
    let services: [SystemdServiceItem]
    let onSelectService: (SystemdServiceItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""

    private var filtered: [SystemdServiceItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return services }
        return services.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.activeState.localizedCaseInsensitiveContains(q)
                || $0.subState.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .foregroundColor(ApexStyle.accent)
                    .accessibilityHidden(true)
                Text("全部 Systemd 服务 (\(services.count))")
                    .font(.system(size: 13.5, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer()
                ApexIconButton(icon: "xmark", label: "关闭", size: 26, iconSize: 11) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 10)
            .background(ApexStyle.subtleSurface)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(ApexStyle.secondary)
                TextField("搜索服务名或状态 (active / failed / inactive)...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    ApexIconButton(
                        icon: "xmark.circle.fill",
                        label: "清空搜索",
                        size: 18,
                        iconSize: 10
                    ) {
                        query = ""
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(ApexStyle.border, lineWidth: 1))
            .padding(ApexStyle.s4)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    services.isEmpty ? "未检测到 Systemd 服务" : "未找到匹配的服务",
                    systemImage: "gearshape.2",
                    description: Text(services.isEmpty ? "当前主机未返回可用的 Systemd 服务列表。" : "请尝试调整搜索关键字或清空搜索。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { svc in
                            Button {
                                dismiss()
                                onSelectService(svc)
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(svc.isRunning ? ApexStyle.success : (svc.activeState == "failed" ? ApexStyle.error : ApexStyle.secondary))
                                        .frame(width: 7, height: 7)
                                    Text(svc.name)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(ApexStyle.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(svc.name)
                                    Spacer()
                                    if svc.isProtectedForStop {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(ApexStyle.secondary)
                                            .accessibilityLabel("核心系统服务受保护，禁止直接停止")
                                            .help("核心系统服务受保护，禁止直接停止")
                                    }
                                    Text(svc.subState.isEmpty ? svc.activeState : "\(svc.activeState) (\(svc.subState))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(svc.isRunning ? ApexStyle.success : (svc.activeState == "failed" ? ApexStyle.error : ApexStyle.secondary))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10))
                                        .foregroundColor(ApexStyle.secondary)
                                }
                                .padding(.horizontal, ApexStyle.s4)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 460)
        .background(ApexStyle.surface)
    }
}
