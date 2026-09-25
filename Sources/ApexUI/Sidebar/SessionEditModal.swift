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
    @State private var folder: String = "生产环境"
    @State private var tags: String = "生产, k8s"
    @State private var colorHex: String = "#0A84FF"
    @State private var agentlessMonitor: Bool = true
    @State private var sftpAutoSync: Bool = true
    
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
            // Header
            HStack {
                Label(initialSession == nil ? L10n.newSessionTitle : L10n.editSessionTitle, systemImage: "server.rack")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button(L10n.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                
                Button(L10n.save) {
                    saveSession()
                }
                .buttonStyle(.borderedProminent)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            
            Divider()
            
            Form {
                // 1. 主机与连接信息
                Section(L10n.hostDetailsSection) {
                    TextField(L10n.sessionNameLabel, text: $name, prompt: Text(L10n.sessionNamePlaceholder))
                    
                    HStack(spacing: 12) {
                        TextField(L10n.hostLabel, text: $host, prompt: Text(L10n.hostPlaceholder))
                        
                        TextField(L10n.portLabel, text: $port)
                            .frame(width: 80)
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
                                Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                    .foregroundColor(.secondary)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
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
                }
                
                // 4. 特性与监控
                Section(L10n.performanceSection) {
                    Toggle(L10n.agentlessMonitorToggle, isOn: $agentlessMonitor)
                    Toggle(L10n.sftpAutoSyncToggle, isOn: $sftpAutoSync)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 490)
        .onAppear {
            loadInitialSessionData()
        }
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
            try? KeychainStore.shared.save(key: key, secret: password)
            authMethod = .password(keychainRef: password)
        } else if authType == .password {
            authMethod = .password(keychainRef: "")
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
