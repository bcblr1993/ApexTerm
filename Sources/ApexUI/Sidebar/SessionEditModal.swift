import SwiftUI
import ApexCore
import ApexSSH

/// Modal sheet for creating or editing an SSH session with password/key authentication and Chinese localization
public struct SessionEditModal: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    public let initialSession: Session?
    public let isCloning: Bool
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
    @State private var isPassphraseVisible: Bool = false
    @State private var isAuthorizingSecretReveal: Bool = false
    @State private var didFinishLoadingInitialSecret: Bool = false
    @State private var didFinishLoadingInitialPassphrase: Bool = false
    @State private var didLoadInitialSecretValue: Bool = false
    @State private var didLoadInitialPassphraseValue: Bool = false
    @State private var selectedVaultKeyId: UUID? = nil
    @State private var jumpServerChain: [UUID] = []
    @State private var forwardAgent: Bool = false
    @State private var compression: Bool = false
    @State private var proxyCommand: String = ""
    @State private var isAdvancedSSHExpanded: Bool = false
    @State private var folder: String = "常用会话"
    @State private var tags: String = ""
    @State private var colorHex: String = "#0A84FF"
    @State private var agentlessMonitor: Bool = true
    @State private var sftpAutoSync: Bool = true
    @State private var keepAliveInterval: Int = 15
    @State private var terminalType: TerminalType = .default
    @State private var initialWorkingDirectory: String = ""
    @State private var startupCommand: String = ""
    @State private var environmentVariablesText: String = ""
    @State private var saveError: String?
    @State private var isTestingConnection: Bool = false
    @State private var testAttemptId: UUID = UUID()
    @State private var testResult: SSHTestConnectionResult?
    @State private var cachedCertificateInfo = SSHCertificateInfo(isValid: false, keyType: nil, comment: nil)
    
    public enum AuthType: String, CaseIterable, Identifiable, Sendable {
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

    /// Keeps writing to the session's current managed reference (which may have moved to a fresh
    /// `ssh_<UUID>` after a keychain ownership conflict) instead of always `ssh_<sessionId>`.
    nonisolated public static func secretReference(prefix: String, sessionId: UUID, existing: SSHAuthMethod?) -> String {
        let current: String?
        switch existing {
        case .password(let ref): current = ref
        case .privateKey(_, let ref), .certificate(_, _, let ref): current = ref
        default: current = nil
        }
        if let current, current.hasPrefix(prefix), KeychainStore.isManagedReference(current) { return current }
        return prefix + sessionId.uuidString
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

    /// Computes the initial session name shown in the modal for create, edit, or clone mode.
    nonisolated public static func initialDisplayName(for session: Session?, isCloning: Bool) -> String {
        guard let session else { return "" }
        guard isCloning else { return session.name }
        let trimmedName = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return "\(trimmedName) \(L10n.copyTag)"
        }
        let trimmedHost = session.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty {
            return "\(trimmedHost) \(L10n.copyTag)"
        }
        return ""
    }

    /// Builds an isolated `SSHAuthMethod` when saving a cloned session, preserving existing secrets
    /// even if saved before async Keychain loading finishes while respecting intentional clearing after load.
    nonisolated public static func cloneAuthMethodForSave(
        authType: AuthType,
        sessionId: UUID,
        typedPassword: String,
        typedPassphrase: String,
        privateKeyPath: String,
        certificatePath: String,
        sourceAuthMethod: SSHAuthMethod?,
        didFinishLoadingSecret: Bool,
        didFinishLoadingPassphrase: Bool,
        secretReader: (String) -> String?,
        secretWriter: (String, String) throws -> String
    ) throws -> SSHAuthMethod {
        switch authType {
        case .agent:
            return .agent

        case .password:
            if !typedPassword.isEmpty {
                let savedKey = try secretWriter("ssh_\(sessionId.uuidString)", typedPassword)
                return .password(keychainRef: savedKey)
            }
            if !didFinishLoadingSecret, case .password(let oldRef) = sourceAuthMethod, !oldRef.isEmpty {
                let fallbackSecret = secretReader(oldRef) ?? (!KeychainStore.isManagedReference(oldRef) ? oldRef : nil)
                if let fallbackSecret, !fallbackSecret.isEmpty {
                    let savedKey = try secretWriter("ssh_\(sessionId.uuidString)", fallbackSecret)
                    return .password(keychainRef: savedKey)
                }
            }
            return .password(keychainRef: "")

        case .privateKey:
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourcePassRef: String? = if case .privateKey(_, let oldPassRef) = sourceAuthMethod { oldPassRef } else { nil }
            let resolvedPassRef = try resolveClonedPassphraseRef(
                sessionId: sessionId,
                typedPassphrase: typedPassphrase,
                sourcePassRef: sourcePassRef,
                didFinishLoadingPassphrase: didFinishLoadingPassphrase,
                secretReader: secretReader,
                secretWriter: secretWriter
            )
            return .privateKey(keychainRef: keyPath, passphraseRef: resolvedPassRef)

        case .certificate:
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let certPath = certificatePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourcePassRef: String? = if case .certificate(_, _, let oldPassRef) = sourceAuthMethod { oldPassRef } else { nil }
            let resolvedPassRef = try resolveClonedPassphraseRef(
                sessionId: sessionId,
                typedPassphrase: typedPassphrase,
                sourcePassRef: sourcePassRef,
                didFinishLoadingPassphrase: didFinishLoadingPassphrase,
                secretReader: secretReader,
                secretWriter: secretWriter
            )
            return .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: resolvedPassRef)
        }
    }

    nonisolated private static func resolveClonedPassphraseRef(
        sessionId: UUID,
        typedPassphrase: String,
        sourcePassRef: String?,
        didFinishLoadingPassphrase: Bool,
        secretReader: (String) -> String?,
        secretWriter: (String, String) throws -> String
    ) throws -> String? {
        if !typedPassphrase.isEmpty {
            return try secretWriter("passphrase_\(sessionId.uuidString)", typedPassphrase)
        }
        if !didFinishLoadingPassphrase, let ref = sourcePassRef, !ref.isEmpty {
            let fallbackSecret = secretReader(ref) ?? (!KeychainStore.isManagedReference(ref) ? ref : nil)
            if let fallbackSecret, !fallbackSecret.isEmpty {
                return try secretWriter("passphrase_\(sessionId.uuidString)", fallbackSecret)
            }
        }
        return nil
    }

    /// Builds an updated `SSHAuthMethod` when saving an edited (or newly created) session.
    /// Respects intentional clearing once the initial Keychain secret has loaded while preserving
    /// unreadable or still-loading references.
    nonisolated public static func editAuthMethodForSave(
        authType: AuthType,
        sessionId: UUID,
        typedPassword: String,
        typedPassphrase: String,
        privateKeyPath: String,
        certificatePath: String,
        sourceAuthMethod: SSHAuthMethod?,
        didFinishLoadingSecret: Bool,
        didLoadInitialSecretValue: Bool,
        didFinishLoadingPassphrase: Bool,
        didLoadInitialPassphraseValue: Bool,
        secretWriter: (String, String) throws -> String
    ) throws -> SSHAuthMethod {
        switch authType {
        case .agent:
            return .agent

        case .password:
            if !typedPassword.isEmpty {
                let ref = secretReference(prefix: "ssh_", sessionId: sessionId, existing: sourceAuthMethod)
                let savedKey = try secretWriter(ref, typedPassword)
                return .password(keychainRef: savedKey)
            }
            if (!didFinishLoadingSecret || !didLoadInitialSecretValue),
               case .password(let ref) = sourceAuthMethod, !ref.isEmpty {
                return .password(keychainRef: ref)
            }
            return .password(keychainRef: "")

        case .privateKey:
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldPassRef: String? = if case .privateKey(_, let ref) = sourceAuthMethod { ref } else { nil }
            let passRef = try resolveEditedPassphraseRef(
                sessionId: sessionId,
                typedPassphrase: typedPassphrase,
                sourceAuthMethod: sourceAuthMethod,
                oldPassRef: oldPassRef,
                didFinishLoadingPassphrase: didFinishLoadingPassphrase,
                didLoadInitialPassphraseValue: didLoadInitialPassphraseValue,
                secretWriter: secretWriter
            )
            return .privateKey(keychainRef: keyPath, passphraseRef: passRef)

        case .certificate:
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let certPath = certificatePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldPassRef: String? = if case .certificate(_, _, let ref) = sourceAuthMethod { ref } else { nil }
            let passRef = try resolveEditedPassphraseRef(
                sessionId: sessionId,
                typedPassphrase: typedPassphrase,
                sourceAuthMethod: sourceAuthMethod,
                oldPassRef: oldPassRef,
                didFinishLoadingPassphrase: didFinishLoadingPassphrase,
                didLoadInitialPassphraseValue: didLoadInitialPassphraseValue,
                secretWriter: secretWriter
            )
            return .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: passRef)
        }
    }

    nonisolated private static func resolveEditedPassphraseRef(
        sessionId: UUID,
        typedPassphrase: String,
        sourceAuthMethod: SSHAuthMethod?,
        oldPassRef: String?,
        didFinishLoadingPassphrase: Bool,
        didLoadInitialPassphraseValue: Bool,
        secretWriter: (String, String) throws -> String
    ) throws -> String? {
        if !typedPassphrase.isEmpty {
            let ref = secretReference(prefix: "passphrase_", sessionId: sessionId, existing: sourceAuthMethod)
            return try secretWriter(ref, typedPassphrase)
        }
        if (!didFinishLoadingPassphrase || !didLoadInitialPassphraseValue),
           let oldPassRef, !oldPassRef.isEmpty {
            return oldPassRef
        }
        return nil
    }

    public enum TestCredentialResolution: Sendable {
        case resolved(authMethod: SSHAuthMethod, explicitSecret: String?)
        case invalid(SSHTestConnectionResult)
    }

    /// Resolves candidate `SSHAuthMethod` and explicit secret (verbatim, including `$$`/quotes)
    /// for "Test Connection", rejecting cleared passwords once loaded.
    nonisolated public static func resolveTestCredentials(
        authType: AuthType,
        typedPassword: String,
        typedPassphrase: String,
        privateKeyPath: String,
        certificatePath: String,
        sourceAuthMethod: SSHAuthMethod?,
        didFinishLoadingSecret: Bool,
        didLoadInitialSecretValue: Bool,
        didFinishLoadingPassphrase: Bool,
        didLoadInitialPassphraseValue: Bool
    ) -> TestCredentialResolution {
        switch authType {
        case .password:
            if !typedPassword.isEmpty {
                return .resolved(authMethod: .password(keychainRef: ""), explicitSecret: typedPassword)
            }
            if (!didFinishLoadingSecret || !didLoadInitialSecretValue),
               case .password(let ref) = sourceAuthMethod, !ref.isEmpty {
                return .resolved(authMethod: .password(keychainRef: ref), explicitSecret: nil)
            }
            return .invalid(SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: "请输入密码后再测试"))

        case .privateKey:
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typedPassphrase.isEmpty {
                return .resolved(authMethod: .privateKey(keychainRef: keyPath, passphraseRef: nil), explicitSecret: typedPassphrase)
            }
            let existingPassRef: String? = if (!didFinishLoadingPassphrase || !didLoadInitialPassphraseValue),
                                              case .privateKey(_, let passRef) = sourceAuthMethod { passRef } else { nil }
            return .resolved(authMethod: .privateKey(keychainRef: keyPath, passphraseRef: existingPassRef), explicitSecret: nil)

        case .certificate:
            let keyPath = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let certPath = certificatePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typedPassphrase.isEmpty {
                return .resolved(authMethod: .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: nil), explicitSecret: typedPassphrase)
            }
            let existingPassRef: String? = if (!didFinishLoadingPassphrase || !didLoadInitialPassphraseValue),
                                              case .certificate(_, _, let passRef) = sourceAuthMethod { passRef } else { nil }
            return .resolved(authMethod: .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: existingPassRef), explicitSecret: nil)

        case .agent:
            return .resolved(authMethod: .agent, explicitSecret: nil)
        }
    }
    
    public init(session: Session?, isCloning: Bool = false, onSave: @escaping (Session) -> Void) {
        self.initialSession = session
        self.isCloning = isCloning
        self.onSave = onSave
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: isCloning ? "doc.on.doc" : "server.rack")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ApexStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(ApexStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(isCloning ? L10n.cloneSessionTitle : (initialSession == nil ? L10n.newSessionTitle : L10n.editSessionTitle))
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                    Text(isCloning ? "已预填原会话的全部连接信息，修改后保存即可创建新会话" : "填写连接信息，保存后可从侧栏快速访问")
                        .font(.caption)
                        .foregroundStyle(ApexStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                ApexIconButton(
                    icon: "xmark",
                    label: "关闭 (Esc)",
                    size: 26,
                    iconSize: 11
                ) {
                    dismiss()
                }
            }
            .padding(ApexStyle.s4)
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

                    let otherSessions = Self.jumpHostCandidates(from: SessionStore.shared.sessions, excluding: isCloning ? nil : initialSession?.id)
                    if !otherSessions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("跳板机链 (ProxyJump)")
                                Spacer()
                                if jumpServerChain.count < SSHArgumentBuilder.maxJumpHops {
                                    let availableToAdd = otherSessions.filter { !jumpServerChain.contains($0.id) }
                                    if !availableToAdd.isEmpty {
                                        Menu {
                                            ForEach(availableToAdd) { s in
                                                Button("\(s.name) (\(s.host))") {
                                                    jumpServerChain.append(s.id)
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus")
                                                    .font(.system(size: 10, weight: .semibold))
                                                Text("添加跳板机…")
                                                    .font(.system(size: 11.5, weight: .medium))
                                                    .lineLimit(1)
                                            }
                                            .foregroundColor(ApexStyle.accent)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(ApexStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                                                    .stroke(ApexStyle.accent.opacity(0.25), lineWidth: 0.75)
                                            )
                                        }
                                        .menuStyle(.borderlessButton)
                                        .menuIndicator(.hidden)
                                        .fixedSize()
                                        .accessibilityLabel("添加跳板机")
                                        .accessibilityIdentifier("session.addJumpHostMenu")
                                    }
                                }
                            }

                            if jumpServerChain.isEmpty {
                                Text("直连目标主机（可按顺序添加最多 \(SSHArgumentBuilder.maxJumpHops) 级跳板机）")
                                    .font(.caption)
                                    .foregroundStyle(ApexStyle.secondary)
                            } else {
                                ForEach(Array(jumpServerChain.enumerated()), id: \.element) { index, hopId in
                                    let hopSession = SessionStore.shared.sessions.first(where: { $0.id == hopId })
                                    HStack(spacing: 6) {
                                        Text("\(index + 1).")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(ApexStyle.accent)
                                        Text(hopSession.map { "\($0.name) (\($0.username)@\($0.host):\($0.port))" } ?? "未知跳板机 (\(hopId.uuidString.prefix(8)))")
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .lineLimit(1)
                                        Spacer()
                                        if index > 0 {
                                            ApexIconButton(icon: "arrow.up", label: "上移跳板机", size: 20, iconSize: 10) {
                                                jumpServerChain.swapAt(index, index - 1)
                                            }
                                        }
                                        if index + 1 < jumpServerChain.count {
                                            ApexIconButton(icon: "arrow.down", label: "下移跳板机", size: 20, iconSize: 10) {
                                                jumpServerChain.swapAt(index, index + 1)
                                            }
                                        }
                                        ApexIconButton(icon: "xmark", label: "移除跳板机", size: 20, iconSize: 9, tint: ApexStyle.error) {
                                            jumpServerChain.removeAll(where: { $0 == hopId })
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
                                }
                            }

                            if let jumpCycleMessage {
                                Text(jumpCycleMessage)
                                    .font(.caption)
                                    .foregroundStyle(ApexStyle.error)
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
                    .labelsHidden()
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
                                togglePasswordVisibility()
                            }
                            .disabled(isAuthorizingSecretReveal)
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
                                    privateKeyPath = Self.resolvedPrivateKeyPathAfterPickerChange(
                                        selectedVaultKeyId: newId,
                                        currentPath: privateKeyPath,
                                        keys: SSHKeyVaultManager.shared.keys
                                    )
                                }
                            }
                            
                            HStack {
                                TextField("私钥路径 (如 ~/.ssh/id_ed25519 或保险库标识)", text: $privateKeyPath)
                                    .accessibilityLabel("私钥路径")
                                    .accessibilityIdentifier("session.privateKeyPath")
                                    .font(.system(.body, design: .monospaced))
                                    .onChange(of: privateKeyPath) { _, newValue in
                                        let matched = Self.matchedVaultKeyId(forPrivateKeyPath: newValue, keys: SSHKeyVaultManager.shared.keys)
                                        if selectedVaultKeyId != matched {
                                            selectedVaultKeyId = matched
                                        }
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
                                        } catch {
                                            saveError = "无法保存私钥文件授权：\(error.localizedDescription)"
                                        }
                                    }
                                }
                                .controlSize(.small)
                            }
                            passphraseFieldRow
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
                                    privateKeyPath = Self.resolvedPrivateKeyPathAfterPickerChange(
                                        selectedVaultKeyId: newId,
                                        currentPath: privateKeyPath,
                                        keys: SSHKeyVaultManager.shared.keys
                                    )
                                    if newId != nil {
                                        autoDiscoverCertificateIfNeeded()
                                    }
                                }
                            }
                            
                            HStack {
                                TextField("私钥路径 (如 ~/.ssh/id_ed25519)", text: $privateKeyPath)
                                    .accessibilityLabel("私钥路径")
                                    .accessibilityIdentifier("session.privateKeyPath")
                                    .font(.system(.body, design: .monospaced))
                                    .onChange(of: privateKeyPath) { _, newValue in
                                        let matched = Self.matchedVaultKeyId(forPrivateKeyPath: newValue, keys: SSHKeyVaultManager.shared.keys)
                                        if selectedVaultKeyId != matched {
                                            selectedVaultKeyId = matched
                                        }
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
                            
                            passphraseFieldRow
                            
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
                    Picker("心跳保活间隔 (Keep-Alive)", selection: $keepAliveInterval) {
                        Text("10 秒（高频防断连）").tag(10)
                        Text("15 秒（推荐）").tag(15)
                        Text("30 秒（标准）").tag(30)
                        Text("60 秒（宽松）").tag(60)
                    }
                    .accessibilityIdentifier("session.keepAlivePicker")
                    Picker("终端类型 (TERM)", selection: $terminalType) {
                        ForEach(TerminalType.allCases, id: \.self) { type in
                            Text(type == .default ? "\(type.rawValue)（默认）" : type.rawValue).tag(type)
                        }
                    }
                    .accessibilityIdentifier("session.terminalTypePicker")
                    Text("远端缺少终端描述导致长命令不换行时，改为 xterm")
                        .font(.caption)
                        .foregroundStyle(ApexStyle.secondary)

                    DisclosureGroup("高级 SSH 选项 (-A / -C / ProxyCommand)", isExpanded: $isAdvancedSSHExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("SSH Agent 转发 (-A)", isOn: $forwardAgent)
                                .accessibilityIdentifier("session.forwardAgentToggle")
                            Text("仅在受信任的远端主机启用，开启后远端可使用本机 SSH Agent 密钥认证。")
                                .font(.caption2)
                                .foregroundStyle(ApexStyle.secondary)

                            Toggle("启用链路压缩 (-C)", isOn: $compression)
                                .accessibilityIdentifier("session.compressionToggle")

                            TextField("自定义 ProxyCommand (如 nc -X 5 -x 127.0.0.1:1080 %h %p)", text: $proxyCommand)
                                .accessibilityLabel("自定义 ProxyCommand")
                                .accessibilityIdentifier("session.proxyCommand")
                                .font(.system(.body, design: .monospaced))

                            if let sandboxWarn = ProxyCommandValidator.sandboxWarning(for: proxyCommand, isAppStore: DistributionChannel.current == .appStore) {
                                Label(sandboxWarn, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(ApexStyle.warning)
                            }
                            if !proxyCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !jumpServerChain.isEmpty {
                                Text("已配置 ProxyCommand 时将优先使用 ProxyCommand，并自动忽略跳板机链 (-J)。")
                                    .font(.caption2)
                                    .foregroundStyle(ApexStyle.warning)
                            }
                        }
                        .padding(.top, 6)
                    }
                }

                // 5. 登录启动与环境变量
                Section("登录启动与环境变量") {
                    TextField("初始工作目录 (如 /var/www/app 或 ~/workspace)", text: $initialWorkingDirectory)
                        .accessibilityLabel("初始工作目录")
                        .accessibilityIdentifier("session.initialWorkingDirectory")
                        .font(.system(.body, design: .monospaced))
                    TextField("登录后自动执行命令 (如 tmux attach -t main || tmux new -s main)", text: $startupCommand)
                        .accessibilityLabel("登录后自动执行命令")
                        .accessibilityIdentifier("session.startupCommand")
                        .font(.system(.body, design: .monospaced))
                    TextField("自定义环境变量 (每行 KEY=VALUE，如 APP_ENV=production)", text: $environmentVariablesText, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityLabel("自定义环境变量")
                        .accessibilityIdentifier("session.environmentVariables")
                        .font(.system(.body, design: .monospaced))
                    Text("敏感变量名（含 SECRET / TOKEN / PASSWORD 等）仅在本地生效，iCloud 云同步时将自动脱敏剔除。")
                        .font(.caption2)
                        .foregroundStyle(ApexStyle.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(ApexStyle.surface)

            Divider()
            HStack(spacing: 10) {
                ApexActionButton(
                    isTestingConnection ? "正在测试..." : "测试连接",
                    icon: "bolt.horizontal.circle",
                    tint: ApexStyle.secondary,
                    size: .regular,
                    isLoading: isTestingConnection
                ) {
                    runConnectionTest()
                }
                .disabled(isTestingConnection || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isValidPort || authValidationMessage != nil || jumpCycleMessage != nil)
                .accessibilityLabel("测试连接")
                .accessibilityIdentifier("session.testConnectionButton")
                
                if let result = testResult {
                    HStack(spacing: 5) {
                        Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(result.isSuccess ? ApexStyle.success : ApexStyle.error)
                            .font(.system(size: 13))
                        
                        if result.isSuccess {
                            Text("连接成功 (\(result.latencyMs)ms)\(result.serverInfo != nil ? " · \(result.serverInfo!)" : "")")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(ApexStyle.success)
                        } else {
                            Text(result.errorMessage ?? "连接失败")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(ApexStyle.error)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading)
                    .help(result.isSuccess ? "连接正常" : (result.errorMessage ?? "连接失败"))
                    .accessibilityIdentifier("session.testResultBanner")
                    .transition(.opacity)
                } else if let message = saveError ?? jumpCycleMessage ?? authValidationMessage ?? envValidationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(saveError != nil ? ApexStyle.error : ApexStyle.warning)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(message)
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
                .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isValidPort || authValidationMessage != nil || envValidationMessage != nil || jumpCycleMessage != nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(ApexStyle.s4)
            .background(ApexStyle.surface)
        }
        .frame(width: 580, height: 600)
        .background(ApexStyle.surface)
        .onAppear {
            // Populating the form flips the save button from disabled to enabled during the
            // sheet's first layout; suppress implicit animations so nothing visibly jumps.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { loadInitialSessionData() }
        }
        .onChange(of: host) { _, _ in invalidateTestResult() }
        .onChange(of: port) { _, _ in invalidateTestResult() }
        .onChange(of: username) { _, _ in invalidateTestResult() }
        .onChange(of: password) { _, _ in invalidateTestResult() }
        .onChange(of: authType) { _, _ in invalidateTestResult() }
        .onChange(of: privateKeyPath) { _, _ in invalidateTestResult() }
        .onChange(of: passphrase) { _, _ in invalidateTestResult() }
        .onChange(of: certificatePath) { _, newValue in
            invalidateTestResult()
            cachedCertificateInfo = Self.inspectCertificateFile(atPath: newValue)
        }
        .onChange(of: jumpServerChain) { _, _ in invalidateTestResult() }
        .onChange(of: forwardAgent) { _, _ in invalidateTestResult() }
        .onChange(of: compression) { _, _ in invalidateTestResult() }
        .onChange(of: proxyCommand) { _, _ in invalidateTestResult() }
    }

    @ViewBuilder
    private var passphraseFieldRow: some View {
        HStack {
            if isPassphraseVisible {
                TextField("私钥口令 Passphrase (可选)", text: $passphrase)
                    .accessibilityLabel("私钥口令")
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField("私钥口令 Passphrase (可选)", text: $passphrase)
                    .accessibilityLabel("私钥口令")
                    .font(.system(.body, design: .monospaced))
            }

            ApexIconButton(
                icon: isPassphraseVisible ? "eye.slash" : "eye",
                label: isPassphraseVisible ? "隐藏私钥口令" : "显示明文私钥口令",
                size: 22,
                iconSize: 11
            ) {
                togglePassphraseVisibility()
            }
            .disabled(isAuthorizingSecretReveal)
        }
    }

    private func togglePasswordVisibility() {
        if isPasswordVisible {
            isPasswordVisible = false
            return
        }
        guard !isAuthorizingSecretReveal else { return }
        let hasStoredSecret = didLoadInitialSecretValue || (initialSession != nil && !password.isEmpty)
        if hasStoredSecret && AppLockManager.shared.requireAuthForSensitiveActions {
            isAuthorizingSecretReveal = true
            Task { @MainActor in
                let authorized = await AppLockManager.shared.authorizeSensitiveAction(
                    reason: "验证身份以查看已保存的服务器密码"
                )
                isAuthorizingSecretReveal = false
                if authorized {
                    isPasswordVisible = true
                } else {
                    saveError = AppLockManager.shared.lastErrorMessage ?? "未通过身份验证，无法查看明文密码"
                }
            }
        } else {
            isPasswordVisible = true
        }
    }

    private func togglePassphraseVisibility() {
        if isPassphraseVisible {
            isPassphraseVisible = false
            return
        }
        guard !isAuthorizingSecretReveal else { return }
        let hasStoredPassphrase = didLoadInitialPassphraseValue || (initialSession != nil && !passphrase.isEmpty)
        if hasStoredPassphrase && AppLockManager.shared.requireAuthForSensitiveActions {
            isAuthorizingSecretReveal = true
            Task { @MainActor in
                let authorized = await AppLockManager.shared.authorizeSensitiveAction(
                    reason: "验证身份以查看已保存的私钥口令"
                )
                isAuthorizingSecretReveal = false
                if authorized {
                    isPassphraseVisible = true
                } else {
                    saveError = AppLockManager.shared.lastErrorMessage ?? "未通过身份验证，无法查看明文口令"
                }
            }
        } else {
            isPassphraseVisible = true
        }
    }

    nonisolated public static func inspectCertificateFile(atPath rawPath: String) -> SSHCertificateInfo {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SSHCertificateInfo(isValid: false, keyType: nil, comment: nil)
        }
        let expandedPath = (trimmed as NSString).expandingTildeInPath
        if let content = try? String(contentsOfFile: expandedPath, encoding: .utf8) {
            return SSHCertificateHelper.inspectCertificate(certContent: content)
        }
        return SSHCertificateInfo(isValid: false, keyType: nil, comment: nil)
    }

    @ViewBuilder
    private var certificateStatusBanner: some View {
        let certInfo = cachedCertificateInfo
        
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

    private var envValidationMessage: String? {
        Self.environmentValidationMessage(for: environmentVariablesText)
    }

    private var jumpCycleMessage: String? {
        guard !jumpServerChain.isEmpty else { return nil }
        let sessionId = isCloning ? UUID() : (initialSession?.id ?? UUID())
        if SSHArgumentBuilder.hasJumpCycle(startingAt: sessionId, jumpChain: jumpServerChain, allSessions: SessionStore.shared.sessions) {
            return "跳板机链存在环形依赖，请移除冲突节点"
        }
        return nil
    }

    nonisolated public static func environmentValidationMessage(for text: String) -> String? {
        let parsed = SessionStartupHelper.parseEnvLines(text)
        guard !parsed.invalidKeys.isEmpty else { return nil }
        return "环境变量名格式无效：\(parsed.invalidKeys.joined(separator: ", "))"
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

    private func invalidateTestResult() {
        testAttemptId = UUID()
        testResult = nil
        isTestingConnection = false
    }

    private var isValidPort: Bool {
        guard let value = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return (1...65535).contains(value)
    }

    private func runConnectionTest() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            testResult = SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: "请输入主机地址")
            return
        }
        guard isValidPort else {
            testResult = SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: "端口请输入 1–65535 之间的数字")
            return
        }
        if let validation = authValidationMessage {
            testResult = SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: validation)
            return
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveUsername = trimmedUsername.isEmpty ? "root" : trimmedUsername
        let portInt = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22

        let resolvedCreds = Self.resolveTestCredentials(
            authType: authType,
            typedPassword: password,
            typedPassphrase: passphrase,
            privateKeyPath: privateKeyPath,
            certificatePath: certificatePath,
            sourceAuthMethod: initialSession?.authMethod,
            didFinishLoadingSecret: didFinishLoadingInitialSecret,
            didLoadInitialSecretValue: didLoadInitialSecretValue,
            didFinishLoadingPassphrase: didFinishLoadingInitialPassphrase,
            didLoadInitialPassphraseValue: didLoadInitialPassphraseValue
        )
        let candidateAuthMethod: SSHAuthMethod
        let effectiveSecret: String?
        switch resolvedCreds {
        case .resolved(let authMethod, let secret):
            candidateAuthMethod = authMethod
            effectiveSecret = secret
        case .invalid(let errorResult):
            testResult = errorResult
            return
        }

        let trimmedProxyCmd = proxyCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateSession = Session(
            id: isCloning ? UUID() : (initialSession?.id ?? UUID()),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedHost : name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: trimmedHost,
            port: portInt,
            username: effectiveUsername,
            authMethod: candidateAuthMethod,
            jumpServerId: jumpServerChain.first,
            jumpServerChain: jumpServerChain,
            forwardAgent: forwardAgent,
            compression: compression,
            proxyCommand: trimmedProxyCmd.isEmpty ? nil : trimmedProxyCmd
        )

        let attemptId = UUID()
        testAttemptId = attemptId
        isTestingConnection = true
        testResult = nil

        Task {
            let result = await NativeSSHSession.testConnection(
                session: candidateSession,
                explicitPassword: effectiveSecret
            )
            await MainActor.run {
                guard self.testAttemptId == attemptId else { return }
                withAnimation(ApexStyle.springSnappy) {
                    self.testResult = result
                    self.isTestingConnection = false
                }
            }
        }
    }
    
    private func loadInitialSessionData() {
        guard let s = initialSession else {
            didFinishLoadingInitialSecret = true
            didFinishLoadingInitialPassphrase = true
            didLoadInitialSecretValue = false
            didLoadInitialPassphraseValue = false
            return
        }
        name = Self.initialDisplayName(for: s, isCloning: isCloning)
        host = s.host
        port = "\(s.port)"
        username = s.username
        folder = SidebarView.normalizedFolder(of: s)
        tags = s.tags.joined(separator: ", ")
        colorHex = s.colorHex ?? "#0A84FF"
        agentlessMonitor = s.agentlessMonitorEnabled
        terminalType = s.terminalType
        sftpAutoSync = s.sftpAutoSyncEnabled
        keepAliveInterval = [10, 15, 30, 60].contains(s.keepAliveIntervalSeconds) ? s.keepAliveIntervalSeconds : 15
        initialWorkingDirectory = s.initialWorkingDirectory ?? ""
        startupCommand = s.startupCommand ?? ""
        environmentVariablesText = SessionStartupHelper.formatEnvLines(s.environmentVariables)
        
        jumpServerChain = s.effectiveJumpServerChain
        forwardAgent = s.forwardAgent
        compression = s.compression
        proxyCommand = s.proxyCommand ?? ""
        isAdvancedSSHExpanded = s.forwardAgent || s.compression || !(s.proxyCommand?.isEmpty ?? true)
        
        switch s.authMethod {
        case .password(let ref):
            authType = .password
            didFinishLoadingInitialSecret = false
            didFinishLoadingInitialPassphrase = true
            didLoadInitialSecretValue = false
            didLoadInitialPassphraseValue = false
            // If ref is the raw password or keychain key, load it
            Task {
                let loaded: String?
                if let saved = try? await KeychainStore.shared.get(key: ref) {
                    loaded = saved
                } else if !KeychainStore.isManagedReference(ref) {
                    // Legacy sessions stored the password inline.
                    loaded = ref
                } else {
                    loaded = nil
                }
                await MainActor.run {
                    if let loaded, !loaded.isEmpty {
                        self.didLoadInitialSecretValue = true
                        if self.password.isEmpty { self.password = loaded }
                    }
                    self.didFinishLoadingInitialSecret = true
                }
            }
        case .privateKey(let keyPath, let passRef):
            authType = .privateKey
            didFinishLoadingInitialSecret = true
            didLoadInitialSecretValue = false
            didLoadInitialPassphraseValue = false
            privateKeyPath = keyPath
            selectedVaultKeyId = Self.matchedVaultKeyId(forPrivateKeyPath: keyPath, keys: SSHKeyVaultManager.shared.keys)
            if let ref = passRef, !ref.isEmpty {
                didFinishLoadingInitialPassphrase = false
                Task {
                    let loaded: String?
                    if let saved = try? await KeychainStore.shared.get(key: ref) {
                        loaded = saved
                    } else if !KeychainStore.isManagedReference(ref) {
                        loaded = ref
                    } else {
                        loaded = nil
                    }
                    await MainActor.run {
                        if let loaded, !loaded.isEmpty {
                            self.didLoadInitialPassphraseValue = true
                            if self.passphrase.isEmpty { self.passphrase = loaded }
                        }
                        self.didFinishLoadingInitialPassphrase = true
                    }
                }
            } else {
                didFinishLoadingInitialPassphrase = true
            }
        case .certificate(let keyPath, let certPath, let passRef):
            authType = .certificate
            didFinishLoadingInitialSecret = true
            didLoadInitialSecretValue = false
            didLoadInitialPassphraseValue = false
            privateKeyPath = keyPath
            certificatePath = certPath
            cachedCertificateInfo = Self.inspectCertificateFile(atPath: certPath)
            selectedVaultKeyId = Self.matchedVaultKeyId(forPrivateKeyPath: keyPath, keys: SSHKeyVaultManager.shared.keys)
            if let ref = passRef, !ref.isEmpty {
                didFinishLoadingInitialPassphrase = false
                Task {
                    let loaded: String?
                    if let saved = try? await KeychainStore.shared.get(key: ref) {
                        loaded = saved
                    } else if !KeychainStore.isManagedReference(ref) {
                        loaded = ref
                    } else {
                        loaded = nil
                    }
                    await MainActor.run {
                        if let loaded, !loaded.isEmpty {
                            self.didLoadInitialPassphraseValue = true
                            if self.passphrase.isEmpty { self.passphrase = loaded }
                        }
                        self.didFinishLoadingInitialPassphrase = true
                    }
                }
            } else {
                didFinishLoadingInitialPassphrase = true
            }
        case .agent, .none:
            authType = .agent
            didFinishLoadingInitialSecret = true
            didFinishLoadingInitialPassphrase = true
            didLoadInitialSecretValue = false
            didLoadInitialPassphraseValue = false
        }
    }
    
    private func saveSession() {
        let trimmedInitDir = initialWorkingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStartupCmd = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProxyCmd = proxyCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jumpCycleMessage {
            saveError = jumpCycleMessage
            return
        }
        let parsedEnv = SessionStartupHelper.parseEnvLines(environmentVariablesText)
        if !parsedEnv.invalidKeys.isEmpty {
            saveError = "环境变量名无效：\(parsedEnv.invalidKeys.joined(separator: ", "))"
            return
        }

        let sessionId = isCloning ? UUID() : (initialSession?.id ?? UUID())
        let authMethod: SSHAuthMethod

        if isCloning {
            do {
                authMethod = try Self.cloneAuthMethodForSave(
                    authType: authType,
                    sessionId: sessionId,
                    typedPassword: password,
                    typedPassphrase: passphrase,
                    privateKeyPath: privateKeyPath,
                    certificatePath: certificatePath,
                    sourceAuthMethod: initialSession?.authMethod,
                    didFinishLoadingSecret: didFinishLoadingInitialSecret,
                    didFinishLoadingPassphrase: didFinishLoadingInitialPassphrase,
                    secretReader: { try? KeychainStore.shared.getSync(key: $0) },
                    secretWriter: { try KeychainStore.shared.save(key: $0, secret: $1) }
                )
            } catch {
                saveError = (authType == .password ? "密码保存失败：" : "口令保存失败：") + error.localizedDescription
                return
            }
        } else {
            do {
                authMethod = try Self.editAuthMethodForSave(
                    authType: authType,
                    sessionId: sessionId,
                    typedPassword: password,
                    typedPassphrase: passphrase,
                    privateKeyPath: privateKeyPath,
                    certificatePath: certificatePath,
                    sourceAuthMethod: initialSession?.authMethod,
                    didFinishLoadingSecret: didFinishLoadingInitialSecret,
                    didLoadInitialSecretValue: didLoadInitialSecretValue,
                    didFinishLoadingPassphrase: didFinishLoadingInitialPassphrase,
                    didLoadInitialPassphraseValue: didLoadInitialPassphraseValue,
                    secretWriter: { try KeychainStore.shared.save(key: $0, secret: $1) }
                )
            } catch {
                saveError = (authType == .password ? "密码保存失败：" : "口令保存失败：") + error.localizedDescription
                return
            }
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
            jumpServerId: jumpServerChain.first,
            jumpServerChain: jumpServerChain,
            forwardAgent: forwardAgent,
            compression: compression,
            proxyCommand: trimmedProxyCmd.isEmpty ? nil : trimmedProxyCmd,
            agentlessMonitorEnabled: agentlessMonitor,
            sftpAutoSyncEnabled: sftpAutoSync,
            keepAliveIntervalSeconds: keepAliveInterval,
            terminalType: terminalType,
            initialWorkingDirectory: trimmedInitDir.isEmpty ? nil : trimmedInitDir,
            startupCommand: trimmedStartupCmd.isEmpty ? nil : trimmedStartupCmd,
            environmentVariables: parsedEnv.variables,
            createdAt: isCloning ? Date() : (initialSession?.createdAt ?? Date()),
            lastConnectedAt: isCloning ? nil : initialSession?.lastConnectedAt
        )
        onSave(newSession)
        dismiss()
    }

    /// Finds the SSHKeyIdentity ID whose `keychainPrivateKeyRef` matches `path`.
    nonisolated public static func matchedVaultKeyId(forPrivateKeyPath path: String, keys: [SSHKeyIdentity]) -> UUID? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return keys.first(where: { $0.keychainPrivateKeyRef == trimmed })?.id
    }

    /// Resolves the updated `privateKeyPath` when the user changes the SSH Key Vault picker.
    /// Selecting "手动指定路径 / 文件" (`nil`) clears any stale `vault.priv.<UUID>` reference while keeping manual paths intact.
    nonisolated public static func resolvedPrivateKeyPathAfterPickerChange(
        selectedVaultKeyId: UUID?,
        currentPath: String,
        keys: [SSHKeyIdentity]
    ) -> String {
        if let id = selectedVaultKeyId, let vk = keys.first(where: { $0.id == id }) {
            return vk.keychainPrivateKeyRef
        }
        let trimmed = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if KeychainStore.isVaultPrivateKeyReference(trimmed) || keys.contains(where: { $0.keychainPrivateKeyRef == trimmed }) {
            return ""
        }
        return currentPath
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
