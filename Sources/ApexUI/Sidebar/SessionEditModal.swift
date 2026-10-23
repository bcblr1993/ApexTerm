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
    @State private var certificatePath: String = ""
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
        case certificate = "指定证书"
        public var id: String { rawValue }

        public static func availableTypes(for method: SSHAuthMethod?, channel: DistributionChannel) -> [Self] {
            return allCases
        }

        public func retainedPrivateKey(from method: SSHAuthMethod?) -> SSHAuthMethod? {
            guard self == .privateKey, let method, case .privateKey = method else { return nil }
            return method
        }

        public func retainedCertificate(from method: SSHAuthMethod?) -> SSHAuthMethod? {
            guard self == .certificate, let method, case .certificate = method else { return nil }
            return method
        }

        /// Blocks saving a key/certificate session that OpenSSH could never authenticate.
        public func validationMessage(privateKeyPath: String, certificatePath: String) -> String? {
            let key = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let cert = certificatePath.trimmingCharacters(in: .whitespacesAndNewlines)
            switch self {
            case .privateKey:
                return key.isEmpty ? "请指定私钥路径或从密钥保险库选择" : nil
            case .certificate:
                if key.isEmpty { return "证书认证需要同时指定对应的私钥" }
                if cert.isEmpty { return "请指定 OpenSSH 证书文件 (-cert.pub)" }
                return nil
            case .password, .agent:
                return nil
            }
        }
    }

    /// Splits user tags on ASCII or full-width commas, trimming blanks and duplicates.
    public static func parseTags(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Every group already in use (or created empty), normalized the same way the sidebar renders them.
    public static func existingFolders(sessions: [Session], extraFolders: [String]) -> [String] {
        SidebarView.folderNames(sessions: sessions, extraFolders: extraFolders, searchFilter: "")
    }

    /// Reuses an existing group's spelling when the typed name only differs by case or padding,
    /// so "prod " and "Prod" do not split one group into two sidebar entries.
    public static func canonicalFolder(_ input: String, existing: [String]) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.generalFolder }
        return existing.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
    }

    /// Sessions that may serve as this session's jump host: remote only, never itself.
    public static func jumpHostCandidates(from sessions: [Session], excluding id: UUID?) -> [Session] {
        sessions.filter { !$0.isLocal && $0.id != id }
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

                    let otherSessions = Self.jumpHostCandidates(from: SessionStore.shared.sessions, excluding: initialSession?.id)
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
                    } else if authType == .certificate {
                        VStack(alignment: .leading, spacing: 8) {
                            if !SSHKeyVaultManager.shared.keys.isEmpty {
                                Picker("密钥保险库", selection: $selectedVaultKeyId) {
                                    Text("手动指定私钥文件").tag(UUID?.none)
                                    ForEach(SSHKeyVaultManager.shared.keys) { vk in
                                        Text("\(vk.name) [\(vk.algorithm.rawValue)]").tag(UUID?.some(vk.id))
                                    }
                                }
                                .onChange(of: selectedVaultKeyId) { _, newId in
                                    if let newId = newId, let vk = SSHKeyVaultManager.shared.key(for: newId) {
                                        privateKeyPath = vk.keychainPrivateKeyRef
                                        autoDiscoverCertificateIfNeeded()
                                    }
                                }
                            }
                            
                            HStack {
                                TextField("私钥路径 (如 ~/.ssh/id_ed25519)", text: $privateKeyPath)
                                    .accessibilityLabel("私钥路径")
                                    .accessibilityIdentifier("session.privateKeyPath")
                                    .font(.system(.body, design: .monospaced))
                                    .onChange(of: privateKeyPath) { _, _ in
                                        autoDiscoverCertificateIfNeeded()
                                    }
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
                                            autoDiscoverCertificateIfNeeded()
                                        } catch {
                                            saveError = "无法保存私钥文件授权：\(error.localizedDescription)"
                                        }
                                    }
                                }
                                .controlSize(.small)
                            }
                            
                            HStack {
                                TextField("证书路径 (如 ~/.ssh/id_ed25519-cert.pub)", text: $certificatePath)
                                    .accessibilityLabel("证书路径")
                                    .accessibilityIdentifier("session.certificatePath")
                                    .font(.system(.body, design: .monospaced))
                                ApexActionButton(
                                    "浏览...",
                                    icon: "doc.badge.gearshape",
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
                                            certificatePath = url.path
                                        } catch {
                                            saveError = "无法保存证书文件授权：\(error.localizedDescription)"
                                        }
                                    }
                                }
                                .controlSize(.small)
                            }
                            
                            if !certificatePath.isEmpty {
                                certificateStatusBanner
                            }
                            
                            SecureField("私钥口令 Passphrase (可选)", text: $passphrase)
                                .font(.system(.body, design: .monospaced))
                            
                            Text("OpenSSH 证书通常由 CA 签发并以 -cert.pub 结尾，须与对应私钥配合使用。")
                                .font(.caption2)
                                .foregroundStyle(ApexStyle.secondary)
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
                    HStack(spacing: ApexStyle.sCompact) {
                        TextField(L10n.folderLabel, text: $folder, prompt: Text("选择已有分组或输入新分组"))
                            .accessibilityLabel(L10n.folderLabel)
                            .accessibilityIdentifier("session.folder")
                        ExistingFolderMenu(folder: $folder,
                                           folders: Self.existingFolders(sessions: SessionStore.shared.sessions, extraFolders: SessionStore.shared.folders))
                    }
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
                if let message = saveError ?? authValidationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(saveError != nil ? ApexStyle.error : ApexStyle.warning)
                        .lineLimit(2)
                        .accessibilityIdentifier("session.validationMessage")
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
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isValidPort || authValidationMessage != nil)
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
        .frame(width: 580, height: 600)
        .onAppear {
            // Populating the form flips the save button from disabled to enabled during the
            // sheet's first layout; suppress implicit animations so nothing visibly jumps.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { loadInitialSessionData() }
        }
    }

    @ViewBuilder
    private var certificateStatusBanner: some View {
        let certInfo: SSHCertificateInfo = {
            let expandedPath = (certificatePath as NSString).expandingTildeInPath
            if let content = try? String(contentsOfFile: expandedPath, encoding: .utf8) {
                return SSHCertificateHelper.inspectCertificate(certContent: content)
            }
            return SSHCertificateInfo(isValid: false, keyType: nil, comment: nil)
        }()
        
        HStack(spacing: 6) {
            Image(systemName: certInfo.isValid ? "checkmark.seal.fill" : "exclamationmark.triangle")
                .foregroundColor(certInfo.isValid ? ApexStyle.success : ApexStyle.warning)
                .font(.caption)
            if certInfo.isValid {
                Text("有效 OpenSSH 证书 (\(certInfo.keyType ?? "OpenSSH Cert"))\(certInfo.comment != nil ? " · \(certInfo.comment!)" : "")")
                    .font(.caption2)
                    .foregroundStyle(ApexStyle.success)
            } else {
                Text("证书文件暂未读取或非标准 OpenSSH 证书格式")
                    .font(.caption2)
                    .foregroundStyle(ApexStyle.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func autoDiscoverCertificateIfNeeded() {
        guard certificatePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let discovered = SSHCertificateHelper.discoverCertificate(forPrivateKeyPath: privateKeyPath) {
            certificatePath = discovered
        }
    }

    private var authValidationMessage: String? {
        authType.validationMessage(privateKeyPath: privateKeyPath, certificatePath: certificatePath)
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
                } else if !KeychainStore.isManagedReference(ref) {
                    // Legacy sessions stored the password inline.
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
                    } else if !KeychainStore.isManagedReference(ref) {
                        await MainActor.run { self.passphrase = ref }
                    }
                }
            }
        case .certificate(let keyPath, let certPath, let passRef):
            authType = .certificate
            privateKeyPath = keyPath
            certificatePath = certPath
            if let ref = passRef, !ref.isEmpty {
                Task {
                    if let saved = try? await KeychainStore.shared.get(key: ref) {
                        await MainActor.run { self.passphrase = saved }
                    } else if !KeychainStore.isManagedReference(ref) {
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
        
        if authType == .certificate {
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let certPath = certificatePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !passphrase.isEmpty {
                let key = "passphrase_\(sessionId.uuidString)"
                do {
                    try KeychainStore.shared.save(key: key, secret: passphrase)
                } catch {
                    saveError = "口令保存失败：\(error.localizedDescription)"
                    return
                }
                authMethod = .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: key)
            } else if case .certificate(_, _, let oldPassRef) = initialSession?.authMethod, passphrase.isEmpty {
                authMethod = .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: oldPassRef)
            } else {
                authMethod = .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: nil)
            }
        } else if authType == .privateKey {
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
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host.trimmingCharacters(in: .whitespaces) : name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 22,
            username: username.trimmingCharacters(in: .whitespaces).isEmpty ? "root" : username.trimmingCharacters(in: .whitespaces),
            authMethod: authMethod,
            folder: Self.canonicalFolder(folder, existing: Self.existingFolders(sessions: SessionStore.shared.sessions, extraFolders: SessionStore.shared.folders)),
            tags: Self.parseTags(tags),
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

/// Picks one of the groups already in use; free typing in the adjacent field still creates new ones.
struct ExistingFolderMenu: View {
    @Binding var folder: String
    let folders: [String]

    var body: some View {
        if !folders.isEmpty {
            Menu {
                ForEach(folders, id: \.self) { name in
                    Button {
                        folder = name
                    } label: {
                        if SessionEditModal.canonicalFolder(folder, existing: folders) == name {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                ApexMenuTrigger(icon: "folder.badge.gearshape", label: "选择已有分组", size: 24, iconSize: 11)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("选择已有分组")
            .accessibilityIdentifier("session.folderPicker")
            .help("选择已有分组")
        }
    }
}
