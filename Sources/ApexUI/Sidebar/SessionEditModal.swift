import SwiftUI
import ApexCore

/// Modal sheet for creating or editing an SSH session with password/key authentication and Chinese localization
public struct SessionEditModal: View {
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
    @State private var folder: String = "常用会话"
    @State private var tags: String = ""
    @State private var colorHex: String = "#0A84FF"
    @State private var agentlessMonitor: Bool = true
    @State private var sftpAutoSync: Bool = true
    @State private var saveError: String?
    
    public enum AuthType: String, CaseIterable, Identifiable {
        case password = "密码认证"
        case agent = "SSH 密钥 / Agent"
        public var id: String { rawValue }
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
                        .foregroundStyle(.secondary)
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
                    
                    TextField(L10n.hostLabel, text: $host, prompt: Text(L10n.hostPlaceholder))
                    TextField(L10n.portLabel, text: $port)
                    if !port.isEmpty && !isValidPort {
                        Text("端口请输入 1–65535 之间的数字")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    
                    TextField(L10n.usernameLabel, text: $username)
                }
                
                // 2. 身份认证 (密码 / 密钥)
                Section(L10n.authMethodSection) {
                    Picker("认证类型", selection: $authType) {
                        ForEach(AuthType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    if authType == .password {
                        HStack {
                            if isPasswordVisible {
                                TextField(L10n.passwordLabel, text: $password, prompt: Text(L10n.passwordPlaceholder))
                                    .font(.system(.body, design: .monospaced))
                            } else {
                                SecureField(L10n.passwordLabel, text: $password, prompt: Text(L10n.passwordPlaceholder))
                                    .font(.system(.body, design: .monospaced))
                            }
                            
                            Button(action: { isPasswordVisible.toggle() }) {
                                Label(isPasswordVisible ? "隐藏密码" : "显示密码",
                                      systemImage: isPasswordVisible ? "eye.slash" : "eye")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help(isPasswordVisible ? "隐藏密码" : "显示明文密码")
                        }
                    } else {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundColor(.secondary)
                            Text("使用 macOS 本机 SSH Agent 或 ~/.ssh 默认私钥自动鉴权")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                
                // 3. 分组与组织
                Section(L10n.organizationSection) {
                    TextField(L10n.folderLabel, text: $folder)
                    TextField(L10n.tagsLabel, text: $tags, prompt: Text(L10n.tagsPlaceholder))
                    HStack(spacing: 9) {
                        Text("标识颜色")
                        Spacer()
                        ForEach(["#0A84FF", "#30D158", "#FF9F0A", "#FF453A", "#BF5AF2"], id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? ApexStyle.accent)
                                    .frame(width: 18, height: 18)
                                    .padding(3)
                                    .overlay(Circle().stroke(colorHex == hex ? Color.primary : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("选择标识颜色 \(hex)")
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
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button(L10n.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.save) { saveSession() }
                    .buttonStyle(.borderedProminent)
                    .tint(ApexStyle.accent)
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isValidPort)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(ApexStyle.surface)
        }
        .frame(width: 560, height: 560)
        .onAppear {
            loadInitialSessionData()
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
        case .agent, .none, .privateKey:
            authType = .agent
        }
    }
    
    private func saveSession() {
        let sessionId = initialSession?.id ?? UUID()
        let authMethod: SSHAuthMethod
        
        if authType == .password && !password.isEmpty {
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
            agentlessMonitorEnabled: agentlessMonitor,
            sftpAutoSyncEnabled: sftpAutoSync
        )
        onSave(newSession)
        dismiss()
    }
}
