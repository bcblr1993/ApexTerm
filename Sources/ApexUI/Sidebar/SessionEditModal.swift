import SwiftUI
import ApexCore

/// Modal sheet for creating or editing an SSH session with password/key authentication and Chinese localization
public struct SessionEditModal: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    public let initialSession: Session?
    public let onSave: (Session) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = "root"
    @State private var authType: AuthType = .password
    @State private var password: String = ""
    @State private var isPasswordVisible: Bool = false
    @State private var privateKeyPath: String = ""
    @State private var passphrase: String = ""
    @State private var selectedVaultKeyId: UUID? = nil
    @State private var jumpServerId: UUID? = nil
    @State private var folder: String = "常用会话"
    @State private var tags: String = ""
    @State private var colorHex: String = "#0A84FF"
    @State private var agentlessMonitor: Bool = true
    @State private var sftpAutoSync: Bool = true
    @State private var saveError: String?
    
    public enum AuthType: String, CaseIterable, Identifiable {
        case password = "密码认证"
        case agent = "SSH 密钥 / Agent"
        case privateKey = "指定私钥"
        public var id: String { rawValue }

        public static func availableTypes(for method: SSHAuthMethod?, channel: DistributionChannel) -> [Self] {
            // Sandbox connections need a user-selected key file and its bookmark.
            if channel == .appStore { return allCases }
            if case .privateKey = method { return allCases }
            return [.password, .agent]
        }

        public func retainedPrivateKey(from method: SSHAuthMethod?) -> SSHAuthMethod? {
            guard self == .privateKey, let method, case .privateKey = method else { return nil }
            return method
        }
    }
    
    public init(session: Session?, onSave: @escaping (Session) -> Void) {
        self.initialSession = session
        self.onSave = onSave
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ApexStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(ApexStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(initialSession == nil ? L10n.newSessionTitle : L10n.editSessionTitle)
                        .font(.system(size: 18, weight: .semibold))
                    Text("填写连接信息，保存后可从侧栏快速访问")
                        .font(.caption)
                        .foregroundStyle(ApexStyle.secondary)
                }
                Spacer()
            }
            .padding(20)
            .background(ApexStyle.surface)
            
            Divider()
            
            Form {
                // 1. 主机与连接信息
                Section(L10n.hostDetailsSection) {
                    TextField(L10n.sessionNameLabel, text: $name, prompt: Text(L10n.sessionNamePlaceholder))
                    .accessibilityLabel(L10n.sessionNameLabel)
                    
                    TextField(L10n.hostLabel, text: $host, prompt: Text(L10n.hostPlaceholder))
                    .accessibilityLabel(L10n.hostLabel)
                    TextField(L10n.portLabel, text: $port)
                    .accessibilityLabel(L10n.portLabel)
                    if !port.isEmpty && !isValidPort {
                        Text("端口请输入 1–65535 之间的数字")
                            .font(.caption)
                            .foregroundStyle(ApexStyle.error)
                    }
                    
                    TextField(L10n.usernameLabel, text: $username)
                    .accessibilityLabel(L10n.usernameLabel)

                    let otherSessions = SessionStore.shared.sessions.filter { $0.id != initialSession?.id }
                    if !otherSessions.isEmpty {
                        Picker("跳板机 (Jump Host)", selection: $jumpServerId) {
                            Text("无 (直连)").tag(UUID?.none)
                            ForEach(otherSessions) { s in
                                Text("\(s.name) (\(s.host))").tag(UUID?.some(s.id))
                            }
                        }
                    }
                }
                
                // 2. 身份认证 (密码 / 密钥)
                Section(L10n.authMethodSection) {
                    Picker("认证类型", selection: $authType) {
                        ForEach(availableAuthTypes) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(ApexStyle.buttonAccent)
                    
                    if authType == .password {
                        HStack {
                            if isPasswordVisible {
                                TextField(L10n.passwordLabel, text: $password, prompt: Text(L10n.passwordPlaceholder))
                                .accessibilityLabel(L10n.passwordLabel)
                                    .font(.system(.body, design: .monospaced))
                            } else {
                                SecureField(L10n.passwordLabel, text: $password, prompt: Text(L10n.passwordPlaceholder))
                                .accessibilityLabel(L10n.passwordLabel)
                                    .font(.system(.body, design: .monospaced))
                            }
                            
                            ApexIconButton(
                                icon: isPasswordVisible ? "eye.slash" : "eye",
                                label: isPasswordVisible ? "隐藏密码" : "显示明文密码",
                                size: 22,
                                iconSize: 11
                            ) {
                                isPasswordVisible.toggle()
                            }
                        }
                    } else if authType == .privateKey {
                        VStack(alignment: .leading, spacing: 8) {
                            if !SSHKeyVaultManager.shared.keys.isEmpty {
                                Picker("密钥保险库", selection: $selectedVaultKeyId) {
                                    Text("手动指定路径 / 文件").tag(UUID?.none)
                                    ForEach(SSHKeyVaultManager.shared.keys) { vk in
                                        Text("\(vk.name) [\(vk.algorithm.rawValue)]").tag(UUID?.some(vk.id))
                                    }
                                }
                                .onChange(of: selectedVaultKeyId) { _, newId in
                                    if let newId = newId, let vk = SSHKeyVaultManager.shared.key(for: newId) {
                                        privateKeyPath = vk.keychainPrivateKeyRef
                                    }
                                }
                            }
                            
                            HStack {
                                TextField("私钥路径 (如 ~/.ssh/id_ed25519 或保险库标识)", text: $privateKeyPath)
                                    .accessibilityLabel("私钥路径")
                                    .accessibilityIdentifier("session.privateKeyPath")
                                    .font(.system(.body, design: .monospaced))
                                ApexActionButton(
                                    "浏览...",
                                    icon: "folder",
                                    tint: ApexStyle.secondary,
                                    size: .small
                                ) {
                                    let panel = NSOpenPanel()
                                    panel.canChooseFiles = true
                                    panel.canChooseDirectories = false
                                    panel.allowsMultipleSelection = false
                                    if panel.runModal() == .OK, let url = panel.url {
                                        do {
                                            if DistributionChannel.current == .appStore {
                                                try FileAccessStore.shared.remember(url, readOnly: true)
                                            }
                                            privateKeyPath = url.path
                                        } catch {
                                            saveError = "无法保存私钥文件授权：\(error.localizedDescription)"
                                        }
                                    }
                                }
                                .controlSize(.small)
                            }
                            SecureField("私钥口令 Passphrase (可选)", text: $passphrase)
                                .font(.system(.body, design: .monospaced))
                        }
                    } else {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundColor(ApexStyle.secondary)
                            Text("使用 macOS 本机 SSH Agent 或 ~/.ssh 默认私钥自动鉴权")
                                .font(.caption)
                                .foregroundColor(ApexStyle.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                
                // 3. 分组与组织
                Section(L10n.organizationSection) {
                    TextField(L10n.folderLabel, text: $folder)
                    .accessibilityLabel(L10n.folderLabel)
                    TextField(L10n.tagsLabel, text: $tags, prompt: Text(L10n.tagsPlaceholder))
                    .accessibilityLabel(L10n.tagsLabel)
                    HStack(spacing: 9) {
                        Text("标识颜色")
                        Spacer()
                        ForEach(["#0A84FF", "#30D158", "#FF9F0A", "#FF453A", "#BF5AF2"], id: \.self) { hex in
                            let isCur = colorHex == hex
                            let color = Color(hex: hex) ?? ApexStyle.accent
                            Button {
                                withAnimation(ApexStyle.springSnappy) {
                                    colorHex = hex
                                }
                            } label: {
                                Circle()
                                    .fill(color)
                                    .frame(width: 18, height: 18)
                                    .shadow(color: isCur ? color.opacity(0.6) : .clear, radius: 4)
                                    .padding(3)
                                    .overlay(
                                        Circle()
                                            .stroke(isCur ? ApexStyle.primary : Color.clear, lineWidth: 1.6)
                                    )
                                    .scaleEffect(isCur ? 1.08 : 1.0)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("选择标识颜色：\(colorName(for: hex))")
                            .accessibilityValue(isCur ? "已选中" : "未选中")
                            .accessibilityAddTraits(isCur ? .isSelected : [])
                        }
                    }
                }
                
                // 4. 特性与监控
                Section(L10n.performanceSection) {
                    Toggle(L10n.agentlessMonitorToggle, isOn: $agentlessMonitor)
                    Toggle(L10n.sftpAutoSyncToggle, isOn: $sftpAutoSync)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(ApexStyle.error)
                        .lineLimit(2)
                }
                Spacer()
                ApexActionButton(
                    L10n.cancel,
                    tint: ApexStyle.secondary,
                    size: .regular
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                ApexActionButton(
                    L10n.save,
                    icon: "checkmark",
                    tint: ApexStyle.accent,
                    size: .regular,
                    isProminent: true
                ) {
                    saveSession()
                }
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isValidPort)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(ApexStyle.surface)
            .overlay(
                Rectangle()
                    .frame(height: 0.75)
                    .foregroundColor(ApexStyle.border.opacity(0.5)),
                alignment: .top
            )
        }
        .frame(width: 560, height: 560)
        .onAppear {
            loadInitialSessionData()
        }
    }

    private var availableAuthTypes: [AuthType] {
        AuthType.availableTypes(for: initialSession?.authMethod, channel: .current)
    }

    private func colorName(for hex: String) -> String {
        switch hex {
        case "#0A84FF": return "蓝色"
        case "#30D158": return "绿色"
        case "#FF9F0A": return "橙色"
        case "#FF453A": return "红色"
        case "#BF5AF2": return "紫色"
        default: return hex
        }
    }

    private var isValidPort: Bool {
        guard let value = Int(port) else { return false }
        return (1...65535).contains(value)
    }
    
    private func loadInitialSessionData() {
        guard let s = initialSession else { return }
        name = s.name
        host = s.host
        port = "\(s.port)"
        username = s.username
        folder = s.folder ?? "常用会话"
        tags = s.tags.joined(separator: ", ")
        colorHex = s.colorHex ?? "#0A84FF"
        agentlessMonitor = s.agentlessMonitorEnabled
        sftpAutoSync = s.sftpAutoSyncEnabled
        
        jumpServerId = s.jumpServerId
        
        switch s.authMethod {
        case .password(let ref):
            authType = .password
            // If ref is the raw password or keychain key, load it
            Task {
                if let saved = try? await KeychainStore.shared.get(key: ref) {
                    await MainActor.run { self.password = saved }
                } else {
                    await MainActor.run { self.password = ref }
                }
            }
        case .privateKey(let keyPath, let passRef):
            authType = .privateKey
            privateKeyPath = keyPath
            if let ref = passRef, !ref.isEmpty {
                Task {
                    if let saved = try? await KeychainStore.shared.get(key: ref) {
                        await MainActor.run { self.passphrase = saved }
                    } else {
                        await MainActor.run { self.passphrase = ref }
                    }
                }
            }
        case .agent, .none:
            authType = .agent
        }
    }
    
    private func saveSession() {
        let sessionId = initialSession?.id ?? UUID()
        let authMethod: SSHAuthMethod
        
        if authType == .privateKey {
            let path = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !passphrase.isEmpty {
                let key = "passphrase_\(sessionId.uuidString)"
                do {
                    try KeychainStore.shared.save(key: key, secret: passphrase)
                } catch {
                    saveError = "口令保存失败：\(error.localizedDescription)"
                    return
                }
                authMethod = .privateKey(keychainRef: path, passphraseRef: key)
            } else if case .privateKey(_, let oldPassRef) = initialSession?.authMethod, passphrase.isEmpty {
                authMethod = .privateKey(keychainRef: path, passphraseRef: oldPassRef)
            } else {
                authMethod = .privateKey(keychainRef: path, passphraseRef: nil)
            }
        } else if authType == .password && !password.isEmpty {
            let key = "ssh_\(sessionId.uuidString)"
            do {
                try KeychainStore.shared.save(key: key, secret: password)
            } catch {
                saveError = "密码保存失败：\(error.localizedDescription)"
                return
            }
            authMethod = .password(keychainRef: key)
        } else if authType == .password {
            if case .password(let ref) = initialSession?.authMethod {
                authMethod = .password(keychainRef: ref)
            } else {
                authMethod = .password(keychainRef: "")
            }
        } else {
            authMethod = .agent
        }
        
        let newSession = Session(
            id: sessionId,
            name: name.isEmpty ? host : name,
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 22,
            username: username.trimmingCharacters(in: .whitespaces).isEmpty ? "root" : username.trimmingCharacters(in: .whitespaces),
            authMethod: authMethod,
            folder: folder.trimmingCharacters(in: .whitespaces).isEmpty ? "常用会话" : folder.trimmingCharacters(in: .whitespaces),
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            colorHex: colorHex,
            jumpServerId: jumpServerId,
            agentlessMonitorEnabled: agentlessMonitor,
            sftpAutoSyncEnabled: sftpAutoSync,
            keepAliveIntervalSeconds: initialSession?.keepAliveIntervalSeconds ?? 30,
            createdAt: initialSession?.createdAt ?? Date(),
            lastConnectedAt: initialSession?.lastConnectedAt
        )
        onSave(newSession)
        dismiss()
    }
}
