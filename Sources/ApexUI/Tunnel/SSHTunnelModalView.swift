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
                    }
                }
                
                HStack(spacing: ApexStyle.s2) {
                    Button {
                        editingTunnel = nil
                        isAddSheetPresented = true
                    } label: {
                        Label("新建隧道", systemImage: "plus")
                    }
                    .apexProminentButton()
                    
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
            .padding(ApexStyle.s5)
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
                    Button {
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(ApexStyle.secondary)
                    }
                    .buttonStyle(.plain)
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
                    
                    Button("添加第一个隧道") {
                        isAddSheetPresented = true
                    }
                    .apexProminentButton()
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
                            onToggle: {
                                toggleTunnel(tunnel)
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
                    .foregroundColor(ApexStyle.secondary)
                
                Spacer()
                
                Button("完成") {
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
                sessions: store.sessions.filter { !$0.isLocal },
                onSave: { newOrUpdated in
                    do {
                        if editingTunnel != nil {
                            try tunnelManager.updateTunnel(newOrUpdated)
                        } else {
                            try tunnelManager.addTunnel(newOrUpdated)
                        }
                        isAddSheetPresented = false
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                },
                onCancel: {
                    isAddSheetPresented = false
                }
            )
            .apexTheme()
        }
    }
    
    private func toggleTunnel(_ tunnel: SSHTunnel) {
        let state = tunnelManager.state(for: tunnel.id)
        if state.isRunning {
            tunnelManager.stopTunnel(id: tunnel.id)
        } else {
            guard let session = store.sessions.first(where: { $0.id == tunnel.sessionId }) else {
                errorMessage = "未找到关联的主机会话"
                return
            }
            Task { @MainActor in
                var pw: String? = nil
                switch session.authMethod {
                case .password(let ref):
                    if let found = try? await KeychainStore.shared.get(key: ref) {
                        pw = found
                    } else {
                        pw = ref
                    }
                case .privateKey(_, let passphraseRef):
                    if let ref = passphraseRef, !ref.isEmpty {
                        pw = try? await KeychainStore.shared.get(key: ref)
                    }
                default:
                    break
                }
                
                var keyPath: String? = nil
                if case .privateKey(let ref, _) = session.authMethod {
                    keyPath = ref
                }
                let sshpassPath = (SSHClientFactory.makeClient(for: session) as? NativeSSHSession)?.sshpassExecutablePath
                
                do {
                    try tunnelManager.startTunnel(
                        id: tunnel.id,
                        session: session,
                        password: pw,
                        privateKeyPath: keyPath,
                        sshpassPath: sshpassPath
                    )
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct TunnelRowView: View {
    let tunnel: SSHTunnel
    let session: Session?
    let state: SSHTunnelState
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: ApexStyle.s3) {
            // Status Indicator Circle
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(state.isRunning ? 0.7 : 0.2), radius: state.isRunning ? 3 : 1)
                .help(statusText)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tunnel.name)
                        .font(.system(size: 13, weight: .semibold))
                    
                    Text(typeBadgeText)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(typeBadgeColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundColor(typeBadgeColor)
                    
                    if tunnel.autoStart {
                        Text("自启")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundColor(ApexStyle.secondary)
                    }
                }
                
                HStack(spacing: 8) {
                    Text(forwardingSummary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                    
                    if let s = session {
                        Text("• 通过 \(s.name) (\(s.host))")
                            .font(.system(size: 11))
                            .foregroundColor(ApexStyle.secondary.opacity(0.8))
                    }
                }
                
                if case .failed(let reason) = state {
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(ApexStyle.error)
                }
            }
            
            Spacer()
            
            // Toggle Start / Stop Button
            ApexActionButton(
                state.isRunning ? "停止" : "启动",
                icon: state.isRunning ? "stop.fill" : "play.fill",
                tint: state.isRunning ? ApexStyle.error : ApexStyle.success
            ) {
                onToggle()
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
        case .local: return .blue
        case .remote: return .purple
        case .dynamic: return .teal
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
        case .stopped: return .gray.opacity(0.6)
        case .starting: return .orange
        case .active: return .green
        case .failed: return .red
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
private struct AddOrEditTunnelSheet: View {
    let existingTunnel: SSHTunnel?
    let sessions: [Session]
    let onSave: (SSHTunnel) -> Void
    let onCancel: () -> Void
    
    @State private var name: String = ""
    @State private var selectedSessionId: UUID = UUID()
    @State private var type: SSHTunnelType = .local
    @State private var bindHost: String = "127.0.0.1"
    @State private var bindPortString: String = "3306"
    @State private var targetHost: String = "localhost"
    @State private var targetPortString: String = "3306"
    @State private var autoStart: Bool = false
    
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
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                
                Text(type.shortDescription)
                    .font(.caption2)
                    .foregroundColor(ApexStyle.secondary)
            }
            
            // Forwarding Ports Configuration
            HStack(spacing: ApexStyle.s4) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(type == .remote ? "远程绑定地址与端口" : "本地监听地址与端口")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(ApexStyle.secondary)
                    HStack {
                        TextField("地址", text: $bindHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Text(":")
                        TextField("端口", text: $bindPortString)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
                
                if type != .dynamic {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(type == .remote ? "本地目标地址与端口" : "远程目标地址与端口")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(ApexStyle.secondary)
                        HStack {
                            TextField("目标地址", text: $targetHost)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            Text(":")
                            TextField("端口", text: $targetPortString)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }
                }
            }
            
            Toggle("连接会话时自动启动此隧道", isOn: $autoStart)
                .font(.caption)
            
            Divider()
            
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    let bPort = Int(bindPortString) ?? 0
                    let tPort = Int(targetPortString) ?? 0
                    let tunnel = SSHTunnel(
                        id: existingTunnel?.id ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(bindHost):\(bPort)" : name,
                        type: type,
                        sessionId: selectedSessionId,
                        bindHost: bindHost,
                        bindPort: bPort,
                        targetHost: targetHost,
                        targetPort: tPort,
                        autoStart: autoStart
                    )
                    onSave(tunnel)
                }
                .apexProminentButton()
                .controlSize(.regular)
                .disabled(sessions.isEmpty || Int(bindPortString) == nil || (type != .dynamic && Int(targetPortString) == nil))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ApexStyle.s5)
        .frame(width: 520)
        .onAppear {
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
