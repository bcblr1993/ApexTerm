import SwiftUI
import ApexCore
import ApexSSH

/// Modal view for managing SSH Port Forwarding tunnels (Local, Remote, Dynamic SOCKS5)
public struct SSHTunnelModalView: View {
    @ObservedObject public var store: SessionStore
    @ObservedObject public var tunnelManager = SSHTunnelManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var isAddSheetPresented = false
    @State private var editingTunnel: SSHTunnel? = nil
    @State private var errorMessage: String? = nil
    @State private var diagnosticTunnel: SSHTunnel? = nil
    @State private var logViewerTunnel: SSHTunnel? = nil
    
    public init(store: SessionStore) {
        self.store = store
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: ApexStyle.s2) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(ApexStyle.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SSH 端口转发与隧道管理")
                            .font(.headline)
                        Text("配置与监控 Local (-L)、Remote (-R) 与 Dynamic SOCKS5 (-D) 隧道")
                            .font(.caption)
                            .foregroundColor(ApexStyle.secondary)
                            .lineLimit(1)
                    }
                }
                
                // Without this spacer the title and actions huddled in the middle of the sheet.
                Spacer(minLength: ApexStyle.s4)
                
                HStack(spacing: ApexStyle.s2) {
                    ApexActionButton("新建隧道", icon: "plus", tint: ApexStyle.accent, size: .small, isProminent: true) {
                        editingTunnel = nil
                        isAddSheetPresented = true
                    }
                    
                    ApexIconButton(
                        icon: "xmark",
                        label: "关闭 (Esc)",
                        size: 26,
                        iconSize: 11
                    ) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            // Same horizontal inset as the footer so both rows share left/right edges.
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, ApexStyle.s4)
            .background(ApexStyle.surface)
            
            Divider()
            
            // Error banner if any
            if let err = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(ApexStyle.error)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(ApexStyle.error)
                    Spacer()
                    ApexIconButton(
                        icon: "xmark",
                        label: "关闭提示",
                        size: 20,
                        iconSize: 9
                    ) {
                        errorMessage = nil
                    }
                }
                .padding(.horizontal, ApexStyle.s4)
                .padding(.vertical, 8)
                .background(ApexStyle.error.opacity(0.1))
                Divider()
            }
            
            // Tunnel List
            if tunnelManager.tunnels.isEmpty {
                VStack(spacing: ApexStyle.s3) {
                    Spacer()
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 40))
                        .foregroundColor(ApexStyle.secondary.opacity(0.6))
                    Text("暂无配置的 SSH 端口转发隧道")
                        .font(.subheadline)
                    Text("支持将本地端口转发到远程内网、将远程端口反向暴露，或一键开启 SOCKS5 代理网关。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    
                    ApexActionButton("添加第一个隧道", icon: "plus", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                        editingTunnel = nil
                        isAddSheetPresented = true
                    }
                    .padding(.top, 4)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(tunnelManager.tunnels) { tunnel in
                        TunnelRowView(
                            tunnel: tunnel,
                            session: store.sessions.first(where: { $0.id == tunnel.sessionId }),
                            state: tunnelManager.state(for: tunnel.id),
                            autoReconnect: tunnelManager.isAutoReconnectEnabled(for: tunnel.id),
                            reconnectNote: tunnelManager.reconnectStatusNotes[tunnel.id],
                            hasStderrLogs: !(tunnelManager.stderrLogs[tunnel.id]?.isEmpty ?? true),
                            onToggle: {
                                toggleTunnel(tunnel)
                            },
                            onDiagnose: {
                                diagnosticTunnel = tunnel
                            },
                            onViewLogs: {
                                logViewerTunnel = tunnel
                            },
                            onEdit: {
                                editingTunnel = tunnel
                                isAddSheetPresented = true
                            },
                            onDelete: {
                                tunnelManager.deleteTunnel(id: tunnel.id)
                            }
                        )
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            
            Divider()
            
            // Footer
            HStack {
                Text("运行中：\(tunnelManager.tunnels.filter { tunnelManager.state(for: $0.id).isRunning }.count) / \(tunnelManager.tunnels.count)")
                    .font(.caption.monospaced())
                    .monospacedDigit()
                    .foregroundColor(ApexStyle.secondary)
                
                Spacer()
                
                ApexActionButton("完成", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(ApexStyle.s4)
            .background(ApexStyle.subtleSurface.opacity(0.5))
        }
        .frame(width: 720, height: 480)
        .sheet(isPresented: $isAddSheetPresented) {
            AddOrEditTunnelSheet(
                existingTunnel: editingTunnel,
                initialAutoReconnect: editingTunnel.map { tunnelManager.isAutoReconnectEnabled(for: $0.id) } ?? false,
                sessions: store.sessions.filter { !$0.isLocal },
                onSave: { newOrUpdated, autoReconnect in
                    if editingTunnel != nil {
                        let wasRunning = tunnelManager.state(for: newOrUpdated.id).canStop
                        try tunnelManager.updateTunnel(newOrUpdated)
                        tunnelManager.setAutoReconnect(autoReconnect, for: newOrUpdated.id)
                        isAddSheetPresented = false
                        errorMessage = nil
                        if wasRunning {
                            tunnelManager.stopTunnel(id: newOrUpdated.id)
                            startTunnelAsync(newOrUpdated)
                        }
                    } else {
                        try tunnelManager.addTunnel(newOrUpdated)
                        tunnelManager.setAutoReconnect(autoReconnect, for: newOrUpdated.id)
                        isAddSheetPresented = false
                        errorMessage = nil
                    }
                },
                onCancel: {
                    isAddSheetPresented = false
                }
            )
            .apexTheme()
        }
        .sheet(item: $diagnosticTunnel) { tunnel in
            TunnelDiagnosticsSheet(
                tunnel: tunnel,
                session: store.sessions.first(where: { $0.id == tunnel.sessionId }),
                availableSessions: store.sessions,
                tunnelManager: tunnelManager
            )
            .apexTheme()
        }
        .sheet(item: $logViewerTunnel) { tunnel in
            TunnelLogViewerSheet(
                tunnel: tunnel,
                tunnelManager: tunnelManager
            )
            .apexTheme()
        }
    }
    
    private func toggleTunnel(_ tunnel: SSHTunnel) {
        let state = tunnelManager.state(for: tunnel.id)
        if state.canStop {
            tunnelManager.stopTunnel(id: tunnel.id)
        } else {
            startTunnelAsync(tunnel)
        }
    }

    private func startTunnelAsync(_ tunnel: SSHTunnel) {
        guard let session = store.sessions.first(where: { $0.id == tunnel.sessionId }) else {
            errorMessage = "未找到关联的主机会话"
            return
        }
        Task { @MainActor in
            let pw = await SSHTunnelManager.resolveSecret(for: session)
            let keyPath = session.privateKeyPath
            let sshpassPath = (SSHClientFactory.makeClient(for: session) as? NativeSSHSession)?.sshpassExecutablePath
            let jumpChain = SSHArgumentBuilder.resolveJumpChain(for: session, availableSessions: store.sessions).hops

            do {
                try tunnelManager.startTunnel(
                    id: tunnel.id,
                    session: session,
                    password: pw,
                    privateKeyPath: keyPath,
                    sshpassPath: sshpassPath,
                    jumpChain: jumpChain
                )
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct TunnelRowView: View {
    let tunnel: SSHTunnel
    let session: Session?
    let state: SSHTunnelState
    let autoReconnect: Bool
    let reconnectNote: String?
    let hasStderrLogs: Bool
    let onToggle: () -> Void
    let onDiagnose: () -> Void
    let onViewLogs: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: ApexStyle.s3) {
            // Status Indicator Circle
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(state.canStop ? 0.7 : 0.2), radius: state.canStop ? 3 : 1)
                .help(statusText)
                .accessibilityLabel(statusText)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tunnel.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    
                    Text(typeBadgeText)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(typeBadgeColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundColor(typeBadgeColor)
                    
                    if tunnel.autoStart {
                        Text("自启")
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(ApexStyle.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundColor(ApexStyle.secondary)
                    }

                    if autoReconnect {
                        Text("自动重连")
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundColor(ApexStyle.accent)
                    }
                }
                
                HStack(spacing: 8) {
                    Text(forwardingSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if let s = session {
                        Text("• 通过 \(s.name) (\(s.host))")
                            .font(.system(size: 11))
                            .foregroundColor(ApexStyle.secondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let reconnectNote, !reconnectNote.isEmpty {
                    Text(reconnectNote)
                        .font(.caption2)
                        .foregroundColor(ApexStyle.warning)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if case .failed(let reason) = state {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(ApexStyle.error)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(reason)
                }
            }
            
            Spacer()
            
            // Toggle Start / Stop Button
            ApexActionButton(
                state.canStop ? "停止" : "启动",
                icon: state.canStop ? "stop.fill" : "play.fill",
                tint: state.canStop ? ApexStyle.error : ApexStyle.success
            ) {
                onToggle()
            }

            ApexActionButton("诊断链路", icon: "stethoscope", tint: ApexStyle.accent, size: .small) {
                onDiagnose()
            }
            .help("检查本地端口绑定、SSH Agent 与跳板机链路可达性")

            ApexIconButton(
                icon: "text.alignleft",
                label: "查看实时 stderr 日志",
                size: 24,
                iconSize: 11,
                tint: hasStderrLogs ? ApexStyle.accent : nil
            ) {
                onViewLogs()
            }
            
            // Edit Button
            ApexIconButton(
                icon: "pencil",
                label: "编辑隧道参数",
                size: 24,
                iconSize: 11
            ) {
                onEdit()
            }
            
            // Delete Button
            ApexIconButton(
                icon: "trash",
                label: "删除隧道",
                size: 24,
                iconSize: 11
            ) {
                onDelete()
            }
        }
        .padding(.vertical, 4)
    }
    
    private var typeBadgeText: String {
        switch tunnel.type {
        case .local: return "本地 -L"
        case .remote: return "远程 -R"
        case .dynamic: return "SOCKS5 -D"
        }
    }
    
    private var typeBadgeColor: Color {
        switch tunnel.type {
        case .local: return ApexStyle.accent
        case .remote: return ApexStyle.warning
        case .dynamic: return ApexStyle.success
        }
    }
    
    private var forwardingSummary: String {
        switch tunnel.type {
        case .local:
            return "\(tunnel.bindHost):\(tunnel.bindPort) ➔ 远程 \(tunnel.targetHost):\(tunnel.targetPort)"
        case .remote:
            return "远程 \(tunnel.bindHost):\(tunnel.bindPort) ➔ 本地 \(tunnel.targetHost):\(tunnel.targetPort)"
        case .dynamic:
            return "SOCKS5 代理网关监听在 \(tunnel.bindHost):\(tunnel.bindPort)"
        }
    }
    
    private var statusColor: Color {
        switch state {
        case .stopped: return ApexStyle.secondary.opacity(0.6)
        case .starting: return ApexStyle.warning
        case .active: return ApexStyle.success
        case .failed: return ApexStyle.error
        }
    }
    
    private var statusText: String {
        switch state {
        case .stopped: return "已停止"
        case .starting: return "启动中"
        case .active: return "运行中"
        case .failed(let err): return "失败: \(err)"
        }
    }
}

/// Sheet to create or edit an SSH tunnel configuration
struct AddOrEditTunnelSheet: View {
    let existingTunnel: SSHTunnel?
    let initialAutoReconnect: Bool
    let sessions: [Session]
    let onSave: (SSHTunnel, Bool) throws -> Void
    let onCancel: () -> Void
    
    @State private var name: String = ""
    @State private var selectedSessionId: UUID = UUID()
    @State private var type: SSHTunnelType = .local
    @State private var bindHost: String = "127.0.0.1"
    @State private var bindPortString: String = "3306"
    @State private var targetHost: String = "localhost"
    @State private var targetPortString: String = "3306"
    @State private var autoStart: Bool = false
    @State private var autoReconnect: Bool = false
    @State private var saveErrorMessage: String? = nil
    
    private var hasValidSession: Bool {
        sessions.contains(where: { $0.id == selectedSessionId })
    }

    private var draft: SSHTunnel {
        Self.makeDraft(id: existingTunnel?.id ?? UUID(), name: name, type: type, sessionId: selectedSessionId,
                       bindHost: bindHost, bindPort: bindPortString, targetHost: targetHost,
                       targetPort: targetPortString, autoStart: autoStart)
    }

    private var validationMessage: String? {
        Self.validationMessage(for: draft, bindPort: bindPortString, targetPort: targetPortString)
    }

    private var footerError: (message: String, isWarning: Bool)? {
        if sessions.isEmpty {
            return ("暂无可用的远程 SSH 会话", true)
        }
        if !hasValidSession {
            return ("原关联会话已删除，请重新选择关联会话", true)
        }
        if let validationMessage {
            return (validationMessage, true)
        }
        if let saveErrorMessage {
            return (saveErrorMessage, false)
        }
        return nil
    }

    /// Trims every field so pasted values such as " 3306" or "db " still save correctly.
    static func makeDraft(id: UUID, name: String, type: SSHTunnelType, sessionId: UUID, bindHost: String,
                          bindPort: String, targetHost: String, targetPort: String, autoStart: Bool) -> SSHTunnel {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let bPort = Int(trim(bindPort)) ?? 0
        let host = trim(bindHost)
        return SSHTunnel(id: id,
                         name: trim(name).isEmpty ? "\(host.isEmpty ? "127.0.0.1" : host):\(bPort)" : trim(name),
                         type: type, sessionId: sessionId,
                         bindHost: host, bindPort: bPort,
                         targetHost: trim(targetHost), targetPort: Int(trim(targetPort)) ?? 0,
                         autoStart: autoStart)
    }

    static func validationMessage(for tunnel: SSHTunnel, bindPort: String, targetPort: String) -> String? {
        if !(1...65535).contains(tunnel.bindPort) {
            return bindPort.trimmingCharacters(in: .whitespaces).isEmpty ? "请填写监听端口" : "监听端口须为 1–65535"
        }
        if tunnel.type != .dynamic && !(1...65535).contains(tunnel.targetPort) {
            return targetPort.trimmingCharacters(in: .whitespaces).isEmpty ? "请填写目标端口" : "目标端口须为 1–65535"
        }
        return tunnel.isValid ? nil : "隧道配置无效"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s4) {
            HStack {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                Text(existingTunnel == nil ? "新建端口转发隧道" : "编辑端口转发隧道")
                    .font(.headline)
                Spacer()
            }
            
            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text("隧道名称")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                TextField("例如：内网 MySQL 数据库映射", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            
            // Associated Session
            VStack(alignment: .leading, spacing: 4) {
                Text("关联 SSH 服务器")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                if sessions.isEmpty {
                    Text("暂无可用的远程 SSH 会话，请先在左侧新建会话")
                        .font(.caption)
                        .foregroundColor(ApexStyle.error)
                } else {
                    Picker("会话", selection: $selectedSessionId) {
                        if !hasValidSession {
                            Text("原关联会话已失效（请重新选择）").tag(selectedSessionId)
                        }
                        ForEach(sessions) { s in
                            Text("\(s.name) (\(s.username)@\(s.host))").tag(s.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            
            // Tunnel Type Picker
            VStack(alignment: .leading, spacing: 4) {
                Text("转发类型")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                Picker("类型", selection: $type) {
                    ForEach(SSHTunnelType.allCases) { t in
                        Text(t.shortLabel).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                
                Text("\(type.displayName)：\(type.shortDescription)")
                    .font(.caption2)
                    .foregroundColor(ApexStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Forwarding Ports Configuration
            HStack(spacing: ApexStyle.s4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(type == .remote ? "远程绑定地址与端口" : "本地监听地址与端口")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(ApexStyle.secondary)
                    HStack(spacing: 6) {
                        TextField("地址", text: $bindHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 140, maxWidth: .infinity)
                        Text(":")
                        TextField("端口", text: $bindPortString)
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                            .frame(width: 68)
                    }
                }
                
                if type != .dynamic {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(type == .remote ? "本地目标地址与端口" : "远程目标地址与端口")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(ApexStyle.secondary)
                        HStack(spacing: 6) {
                            TextField("目标地址", text: $targetHost)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 140, maxWidth: .infinity)
                            Text(":")
                            TextField("端口", text: $targetPortString)
                                .textFieldStyle(.roundedBorder)
                                .monospacedDigit()
                                .frame(width: 68)
                        }
                    }
                }
            }
            
            Toggle("连接会话时自动启动此隧道", isOn: $autoStart)
                .font(.caption)

            Toggle("断线自动重连 (异常退出 255 时指数退避重试)", isOn: $autoReconnect)
                .font(.caption)
            
            Divider()
            
            HStack(spacing: ApexStyle.s2) {
                if let footerError {
                    Text(footerError.message)
                        .font(.caption)
                        .foregroundStyle(footerError.isWarning ? ApexStyle.warning : ApexStyle.error)
                        .lineLimit(2)
                        .help(footerError.message)
                        .accessibilityIdentifier("tunnel.validationMessage")
                }
                Spacer(minLength: ApexStyle.s2)
                ApexActionButton("取消", tint: ApexStyle.secondary, size: .regular) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                ApexActionButton("保存", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    do {
                        saveErrorMessage = nil
                        try onSave(draft, autoReconnect)
                    } catch {
                        saveErrorMessage = error.localizedDescription
                    }
                }
                .disabled(!hasValidSession || validationMessage != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ApexStyle.s4)
        .frame(width: 520)
        .onChange(of: bindHost) { _, _ in saveErrorMessage = nil }
        .onChange(of: bindPortString) { _, _ in saveErrorMessage = nil }
        .onChange(of: targetHost) { _, _ in saveErrorMessage = nil }
        .onChange(of: targetPortString) { _, _ in saveErrorMessage = nil }
        .onChange(of: type) { _, _ in saveErrorMessage = nil }
        .onChange(of: selectedSessionId) { _, _ in saveErrorMessage = nil }
        .onExitCommand {
            onCancel()
        }
        .onAppear {
            autoReconnect = initialAutoReconnect
            if let t = existingTunnel {
                name = t.name
                selectedSessionId = t.sessionId
                type = t.type
                bindHost = t.bindHost
                bindPortString = String(t.bindPort)
                targetHost = t.targetHost
                targetPortString = String(t.targetPort)
                autoStart = t.autoStart
            } else if let first = sessions.first {
                selectedSessionId = first.id
            }
        }
    }
}

private struct TunnelDiagnosticsSheet: View {
    let tunnel: SSHTunnel
    let session: Session?
    let availableSessions: [Session]
    @ObservedObject var tunnelManager: SSHTunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var report: SSHTunnelDiagnosticReport? = nil
    @State private var isRunning: Bool = false
    @State private var statusBanner: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s3) {
            HStack(spacing: ApexStyle.s2) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("隧道链路诊断 · \(tunnel.name)")
                        .font(.headline)
                    Text(tunnel.openSSHSpecifier)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                }
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.small)
                }
                ApexActionButton("重新检测", icon: "arrow.clockwise", tint: ApexStyle.accent, size: .small) {
                    runDiagnostics()
                }
                .disabled(isRunning)
                ApexIconButton(icon: "xmark", label: "关闭", size: 24, iconSize: 11) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            if let statusBanner {
                Text(statusBanner)
                    .font(.caption)
                    .foregroundColor(ApexStyle.success)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ApexStyle.success.opacity(0.12), in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
            }

            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: ApexStyle.s3) {
                        diagnosticRow(
                            title: "本地监听端口",
                            ok: report.isLocalPortAvailable,
                            detail: report.localPortMessage
                        )
                        diagnosticRow(
                            title: "SSH Agent (SSH_AUTH_SOCK)",
                            ok: report.isSSHAuthSockAvailable || !report.forwardAgentEnabled,
                            detail: report.isSSHAuthSockAvailable
                                ? "可用: \(report.sshAuthSockPath ?? "")"
                                : (report.forwardAgentEnabled ? "未检测到有效的 SSH_AUTH_SOCK，agent 转发可能失败" : "未设置 SSH_AUTH_SOCK (当前未启用 ForwardAgent)")
                        )

                        VStack(alignment: .leading, spacing: 6) {
                            Text("跳板链路与目标可达性 (\(report.hopResults.count) 跳)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(ApexStyle.secondary)
                            ForEach(report.hopResults) { hop in
                                diagnosticRow(
                                    title: "\(hop.label) · \(hop.host):\(hop.port)",
                                    ok: hop.isReachable && !hop.hasHostKeyConflict,
                                    detail: hop.message
                                )
                            }
                        }

                        if report.hasHostKeyConflict, let cHost = report.conflictHost, let cPort = report.conflictPort {
                            HStack(spacing: ApexStyle.s2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(ApexStyle.error)
                                Text("检测到 \(cHost):\(cPort) 主机指纹冲突")
                                    .font(.caption)
                                    .foregroundColor(ApexStyle.error)
                                Spacer()
                                ApexActionButton("一键移除旧指纹", icon: "trash", tint: ApexStyle.warning, size: .small) {
                                    do {
                                        let removed = try SSHTunnelManager.clearHostKeyConflict(host: cHost, port: cPort)
                                        statusBanner = "已从 known_hosts 移除 \(removed) 条冲突记录，正在重新诊断..."
                                        runDiagnostics()
                                    } catch {
                                        statusBanner = "清理失败: \(error.localizedDescription)"
                                    }
                                }
                            }
                            .padding(10)
                            .background(ApexStyle.error.opacity(0.10), in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                        }
                    }
                }
            } else if session == nil {
                Text("未找到关联的 SSH 会话，无法诊断远端跳板链路。")
                    .font(.caption)
                    .foregroundColor(ApexStyle.error)
                Spacer()
            } else {
                VStack {
                    Spacer()
                    ProgressView("正在检查本地端口与跳板链路...")
                        .controlSize(.regular)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                Spacer()
                ApexActionButton("完成", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    dismiss()
                }
            }
        }
        .padding(ApexStyle.s4)
        .frame(width: 560, height: 420)
        .onAppear {
            runDiagnostics()
        }
    }

    private func diagnosticRow(title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 13))
                .foregroundColor(ok ? ApexStyle.success : ApexStyle.error)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ApexStyle.primary)
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ApexStyle.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(8)
        .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
    }

    private func runDiagnostics() {
        guard let session else { return }
        isRunning = true
        let chain = SSHArgumentBuilder.resolveJumpChain(for: session, availableSessions: availableSessions).hops
        Task {
            let result = await tunnelManager.diagnoseTunnel(tunnel, session: session, jumpChain: chain)
            await MainActor.run {
                self.report = result
                self.isRunning = false
            }
        }
    }
}

private struct TunnelLogViewerSheet: View {
    let tunnel: SSHTunnel
    @ObservedObject var tunnelManager: SSHTunnelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lines = tunnelManager.stderrLogs[tunnel.id] ?? []
        VStack(alignment: .leading, spacing: ApexStyle.s3) {
            HStack(spacing: ApexStyle.s2) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("隧道实时诊断输出 · \(tunnel.name)")
                        .font(.headline)
                    Text("显示最近 \(lines.count) 行 stderr / 重连事件")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
                Spacer()
                ApexActionButton("复制", icon: "doc.on.doc", tint: ApexStyle.secondary, size: .small) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tunnelManager.stderrLogText(for: tunnel.id), forType: .string)
                }
                .disabled(lines.isEmpty)
                ApexActionButton("清空", icon: "trash", tint: ApexStyle.secondary, size: .small) {
                    tunnelManager.clearStderrLog(for: tunnel.id)
                }
                .disabled(lines.isEmpty)
                ApexIconButton(icon: "xmark", label: "关闭", size: 24, iconSize: 11) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            ScrollView {
                Text(lines.isEmpty ? "（暂无 stderr 日志输出）" : lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ApexStyle.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))

            HStack {
                Spacer()
                ApexActionButton("关闭", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    dismiss()
                }
            }
        }
        .padding(ApexStyle.s4)
        .frame(width: 620, height: 420)
    }
}
