import SwiftUI
import AppKit
import ApexCore

/// Interactive wizard for exporting one or more connection groups (or individual hosts)
/// into a portable `.aetherpack` share bundle with optional encrypted credentials.
public struct GroupShareExportSheet: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject public var store: SessionStore
    @ObservedObject private var tunnelManager: SSHTunnelManager
    @ObservedObject private var bookmarkManager: SFTPBookmarkManager
    @ObservedObject private var vaultManager: SSHKeyVaultManager
    @Environment(\.dismiss) private var dismiss

    public let initialFolder: String?
    public let initialSessionIDs: Set<UUID>?
    public let onExported: ((String) -> Void)?

    @State private var selectedSessionIDs: Set<UUID>
    @State private var includeCrossGroupJumps = true
    @State private var includeCredentials = true
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var showPassphrase = false
    @State private var generatedPassphraseHint: String?
    @State private var lastGeneratedPassphrase: String?
    @State private var includeTunnels = true
    @State private var includeSnippets = false
    @State private var includeBookmarks = false
    @State private var includeTriggers = false
    @State private var isExporting = false
    @State private var exportError: String?

    public init(
        store: SessionStore,
        tunnelManager: SSHTunnelManager = .shared,
        bookmarkManager: SFTPBookmarkManager = .shared,
        vaultManager: SSHKeyVaultManager = .shared,
        initialFolder: String? = nil,
        initialSessionIDs: Set<UUID>? = nil,
        onExported: ((String) -> Void)? = nil
    ) {
        self.store = store
        self._tunnelManager = ObservedObject(wrappedValue: tunnelManager)
        self._bookmarkManager = ObservedObject(wrappedValue: bookmarkManager)
        self._vaultManager = ObservedObject(wrappedValue: vaultManager)
        self.initialFolder = initialFolder
        self.initialSessionIDs = initialSessionIDs
        self.onExported = onExported

        let remoteSessions = store.sessions.filter { !$0.isLocal }
        let initialSelection: Set<UUID>
        if let explicitIDs = initialSessionIDs {
            let validIDs = Set(remoteSessions.map(\.id))
            initialSelection = explicitIDs.intersection(validIDs)
        } else if let targetFolder = initialFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !targetFolder.isEmpty {
            let matched = remoteSessions.filter {
                SidebarView.normalizedFolder(of: $0).caseInsensitiveCompare(targetFolder) == .orderedSame
            }
            initialSelection = Set(matched.map(\.id))
        } else {
            initialSelection = Set(remoteSessions.map(\.id))
        }
        self._selectedSessionIDs = State(initialValue: initialSelection)
    }

    private var remoteSessions: [Session] {
        store.sessions.filter { !$0.isLocal }
    }

    private var folderNames: [String] {
        SidebarView.folderNames(sessions: remoteSessions, extraFolders: [], searchFilter: "")
    }

    private var crossGroupJumpHosts: [Session] {
        SessionBundleExporter.crossGroupJumpHosts(for: selectedSessionIDs, allSessions: store.sessions)
    }

    private var resolvedSelection: (sessions: [Session], addedJumpHostIDs: [UUID]) {
        SessionBundleExporter.resolveExportSelection(
            selectedSessionIDs: selectedSessionIDs,
            allSessions: store.sessions,
            includeCrossGroupJumpHosts: includeCrossGroupJumps
        )
    }

    private var scopedTunnelCount: Int {
        let ids = Set(resolvedSelection.sessions.map(\.id))
        return tunnelManager.tunnels.filter { ids.contains($0.sessionId) }.count
    }

    private var hasPassphraseMismatch: Bool {
        includeCredentials && !passphrase.isEmpty && passphrase != confirmPassphrase
    }

    private var protectionMode: SharePackProtectionMode {
        guard includeCredentials else { return .zeroCredential }
        return passphrase.isEmpty ? .appSealed : .passphrase
    }

    private var canExport: Bool {
        !resolvedSelection.sessions.isEmpty && !hasPassphraseMismatch && !isExporting
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: ApexStyle.s3) {
                    sessionSelectionCard

                    if !crossGroupJumpHosts.isEmpty {
                        crossGroupJumpBanner
                    }

                    credentialProtectionCard
                    attachmentsCard
                }
                .padding(ApexStyle.s4)
            }
            .background(ApexStyle.surface)

            Divider()
            footerBar
        }
        .frame(minWidth: 460, idealWidth: 600, maxWidth: 720, minHeight: 340, idealHeight: 580, maxHeight: 720)
        .background(ApexStyle.surface)
        .onExitCommand {
            dismiss()
        }
        .background(
            Button("") { dismiss() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack(spacing: ApexStyle.s3) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 20))
                .foregroundColor(ApexStyle.accent)
                .frame(width: 40, height: 40)
                .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: ApexStyle.radius))

            VStack(alignment: .leading, spacing: 2) {
                Text("导出连接分组 (.aetherpack)")
                    .font(.headline)
                    .foregroundColor(ApexStyle.primary)
                    .lineLimit(1)
                Text("打包发给他人后，对方在 AetherTerm 中导入或双击文件即可直接使用")
                    .font(.subheadline)
                    .foregroundColor(ApexStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            ApexIconButton(icon: "xmark", label: "关闭 (Esc)", size: 24, iconSize: 11) {
                dismiss()
            }
        }
        .padding(ApexStyle.s4)
        .background(ApexStyle.surface)
    }

    private var sessionSelectionCard: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s2) {
            HStack(spacing: ApexStyle.s2) {
                Text("选择导出范围")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(ApexStyle.primary)

                Text("已选 \(selectedSessionIDs.count) / \(remoteSessions.count) 台")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(ApexStyle.secondary)

                Spacer()

                ApexActionButton("全选", icon: "checkmark.circle", tint: ApexStyle.accent, size: .small) {
                    selectedSessionIDs = Set(remoteSessions.map(\.id))
                }
                .disabled(remoteSessions.isEmpty || selectedSessionIDs.count == remoteSessions.count)

                ApexActionButton("清空", icon: "circle", tint: ApexStyle.secondary, size: .small) {
                    selectedSessionIDs.removeAll()
                }
                .disabled(selectedSessionIDs.isEmpty)
            }

            if remoteSessions.isEmpty {
                HStack {
                    Spacer()
                    Text("当前没有可导出的远程 SSH 会话。")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                        .padding(.vertical, ApexStyle.s5)
                    Spacer()
                }
                .apexPanel()
            } else {
                VStack(alignment: .leading, spacing: ApexStyle.s2) {
                    ForEach(folderNames, id: \.self) { folder in
                        let members = remoteSessions.filter { SidebarView.normalizedFolder(of: $0) == folder }
                        let memberIDs = Set(members.map(\.id))
                        let selectedInFolder = selectedSessionIDs.intersection(memberIDs).count
                        let allSelected = !members.isEmpty && selectedInFolder == members.count

                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                if allSelected {
                                    selectedSessionIDs.subtract(memberIDs)
                                } else {
                                    selectedSessionIDs.formUnion(memberIDs)
                                }
                            } label: {
                                HStack(spacing: ApexStyle.s2) {
                                    Image(systemName: allSelected ? "checkmark.square.fill" : (selectedInFolder > 0 ? "minus.square.fill" : "square"))
                                        .font(.system(size: 13))
                                        .foregroundColor(selectedInFolder > 0 ? ApexStyle.accent : ApexStyle.secondary)
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(ApexStyle.secondary)
                                    Text(folder)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(ApexStyle.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(selectedInFolder)/\(members.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundColor(ApexStyle.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(ApexStyle.primary.opacity(0.06), in: Capsule())
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            ForEach(members) { session in
                                HStack(spacing: ApexStyle.s2) {
                                    Toggle("", isOn: Binding(
                                        get: { selectedSessionIDs.contains(session.id) },
                                        set: { isOn in
                                            if isOn { selectedSessionIDs.insert(session.id) }
                                            else { selectedSessionIDs.remove(session.id) }
                                        }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .accessibilityLabel("选择会话 \(session.name)")

                                    Text(session.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(ApexStyle.primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    Text("\(session.username)@\(session.host):\(session.port)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(ApexStyle.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer()

                                    Text(authBadgeTitle(for: session.authMethod))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(ApexStyle.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(ApexStyle.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius))
                                        .fixedSize()
                                }
                                .padding(.leading, 20)
                                .padding(.vertical, 2)
                            }
                        }

                        if folder != folderNames.last {
                            Divider()
                                .padding(.vertical, 2)
                        }
                    }
                }
                .padding(ApexStyle.s3)
                .apexPanel()
            }
        }
    }

    private var crossGroupJumpBanner: some View {
        VStack(alignment: .leading, spacing: ApexStyle.sCompact) {
            HStack(spacing: ApexStyle.sCompact) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ApexStyle.warning)
                Text("检测到 \(crossGroupJumpHosts.count) 台跨分组跳板机：\(crossGroupJumpHosts.map(\.name).joined(separator: "、"))")
                    .font(.caption.weight(.medium))
                    .foregroundColor(ApexStyle.primary)
                    .lineLimit(2)
            }

            Toggle("一并附带跨分组跳板机（推荐，避免导入后跳板链断裂）", isOn: $includeCrossGroupJumps)
                .font(.caption)
                .foregroundColor(ApexStyle.primary)
        }
        .padding(ApexStyle.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ApexStyle.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: ApexStyle.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ApexStyle.cardRadius)
                .stroke(ApexStyle.warning.opacity(0.35), lineWidth: 0.75)
        )
    }

    private var credentialProtectionCard: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s2) {
            Toggle("包含密码与密钥凭据（对方导入后可直接双击连接）", isOn: $includeCredentials)
                .font(.subheadline.weight(.medium))
                .foregroundColor(ApexStyle.primary)

            if includeCredentials {
                VStack(alignment: .leading, spacing: ApexStyle.sCompact) {
                    HStack(spacing: ApexStyle.s2) {
                        Group {
                            if showPassphrase {
                                TextField("可选分享口令（留空则无口令一键含凭据导入）", text: $passphrase)
                            } else {
                                SecureField("可选分享口令（留空则无口令一键含凭据导入）", text: $passphrase)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("分享口令")
                        .onChange(of: passphrase) { _, newValue in
                            if newValue != lastGeneratedPassphrase {
                                generatedPassphraseHint = nil
                                lastGeneratedPassphrase = nil
                            }
                        }

                        ApexIconButton(
                            icon: showPassphrase ? "eye.slash" : "eye",
                            label: showPassphrase ? "隐藏口令" : "显示口令",
                            size: 24,
                            iconSize: 11
                        ) {
                            showPassphrase.toggle()
                        }

                        ApexActionButton("随机口令", icon: "dice", tint: ApexStyle.accent, size: .small) {
                            let generated = SharePackCrypto.generateReadablePassphrase()
                            lastGeneratedPassphrase = generated
                            passphrase = generated
                            confirmPassphrase = generated
                            showPassphrase = true
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(generated, forType: .string)
                            generatedPassphraseHint = "已生成并复制口令：\(generated)"
                        }
                    }

                    if !passphrase.isEmpty {
                        Group {
                            if showPassphrase {
                                TextField("再次输入分享口令确认", text: $confirmPassphrase)
                            } else {
                                SecureField("再次输入分享口令确认", text: $confirmPassphrase)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("确认分享口令")

                        if hasPassphraseMismatch {
                            Text("两次输入的分享口令不一致")
                                .font(.caption2)
                                .foregroundColor(ApexStyle.error)
                        }
                    }

                    if let hint = generatedPassphraseHint, !passphrase.isEmpty {
                        Text(hint)
                            .font(.caption2.monospaced())
                            .foregroundColor(ApexStyle.success)
                    }

                    Text(
                        passphrase.isEmpty
                            ? "加密方式：内置加密封装（AES-256-GCM，仅防明文直读，跨团队分发请设独立口令），可在另一台 AetherTerm 直接导入。"
                            : "加密方式：口令强加密（PBKDF2 20万次 + AES-256-GCM），适合公网群聊或邮件发送。"
                    )
                    .font(.caption)
                    .foregroundColor(ApexStyle.secondary)
                }
                .padding(.leading, 20)
            } else {
                Text("零凭据导出：仅保留主机、端口、用户名、密钥路径、跳板机与隧道拓扑，不包含密码、私钥口令或保险库私钥。")
                    .font(.caption)
                    .foregroundColor(ApexStyle.secondary)
                    .padding(.leading, 20)
            }
        }
        .padding(ApexStyle.s3)
        .apexPanel()
    }

    private var attachmentsCard: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s2) {
            Text("附带配置")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(ApexStyle.primary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: ApexStyle.s3, alignment: .leading)],
                alignment: .leading,
                spacing: ApexStyle.s2
            ) {
                Toggle("关联隧道 (\(scopedTunnelCount))", isOn: $includeTunnels)
                Toggle("快捷命令 (\(store.snippets.count))", isOn: $includeSnippets)
                Toggle("SFTP 书签 (\(bookmarkManager.customBookmarks.count))", isOn: $includeBookmarks)
                Toggle("触发器 (\(store.triggers.count))", isOn: $includeTriggers)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundColor(ApexStyle.primary)
        }
        .padding(ApexStyle.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .apexPanel()
    }

    private var footerBar: some View {
        HStack(spacing: ApexStyle.sCompact) {
            if let error = exportError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(ApexStyle.error)
                Text(error)
                    .font(.caption)
                    .foregroundColor(ApexStyle.error)
                    .lineLimit(2)
            } else {
                Text("共导出 \(resolvedSelection.sessions.count) 台主机 · \(includeTunnels ? scopedTunnelCount : 0) 条隧道")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(ApexStyle.secondary)
            }

            Spacer()

            ApexActionButton("取消", tint: ApexStyle.secondary, size: .regular) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            ApexActionButton(
                "导出 .aetherpack",
                icon: "square.and.arrow.up",
                tint: ApexStyle.accent,
                size: .regular,
                isProminent: true,
                isLoading: isExporting
            ) {
                startExport()
            }
            .disabled(!canExport)
            .keyboardShortcut(.defaultAction)
        }
        .padding(ApexStyle.s4)
        .background(ApexStyle.surface)
        .onExitCommand {
            dismiss()
        }
    }

    // MARK: - Actions

    private func startExport() {
        exportError = nil
        let resolution = resolvedSelection
        guard !resolution.sessions.isEmpty else {
            exportError = "请至少选择一台远程主机。"
            return
        }
        guard !hasPassphraseMismatch else {
            exportError = "两次输入的分享口令不一致。"
            return
        }

        if includeCredentials && AppLockManager.shared.requireAuthForSensitiveActions {
            isExporting = true
            Task { @MainActor in
                let authorized = await AppLockManager.shared.authorizeSensitiveAction(
                    reason: "验证身份以导出包含密码与密钥凭据的连接分享包"
                )
                guard authorized else {
                    isExporting = false
                    exportError = AppLockManager.shared.lastErrorMessage ?? "未通过身份验证，已取消含凭据导出"
                    return
                }
                isExporting = false
                performExportAfterAuthorization(resolution: resolution)
            }
        } else {
            performExportAfterAuthorization(resolution: resolution)
        }
    }

    private func performExportAfterAuthorization(resolution: (sessions: [Session], addedJumpHostIDs: [UUID])) {
        let groups = SessionBundleExporter.normalizedGroupNames(for: resolution.sessions)
        let folderHint = initialFolder ?? (groups.count == 1 ? groups.first : nil)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.aetherPack]
        savePanel.allowsOtherFileTypes = true
        savePanel.nameFieldStringValue = SessionBundleExporter.suggestedFilename(
            forFolder: folderHint,
            sessionCount: resolution.sessions.count
        )
        savePanel.prompt = "导出"
        savePanel.message = "选择连接分享包 (.aetherpack) 的保存位置"

        guard savePanel.runModal() == .OK, let targetURL = savePanel.url else { return }

        let exportSessions = resolution.sessions
        let mode = protectionMode
        let enteredPass = mode == .passphrase ? passphrase : nil
        let snippetsToExport = includeSnippets ? store.snippets : []
        let triggersToExport = includeTriggers ? store.triggers : []
        let bookmarksToExport = includeBookmarks ? bookmarkManager.customBookmarks : []
        let tunnelsToExport = includeTunnels ? tunnelManager.tunnels : []
        let vaultKeysSnapshot = vaultManager.keys
        let appVersion = UpdateManager.shared.currentVersion

        isExporting = true
        Task { @MainActor in
            do {
                let data = try await SessionBundleExporter.exportEnvelopeData(
                    sessions: exportSessions,
                    snippets: snippetsToExport,
                    triggers: triggersToExport,
                    bookmarks: bookmarksToExport,
                    tunnels: tunnelsToExport,
                    protectionMode: mode,
                    passphrase: enteredPass,
                    appVersion: appVersion,
                    vaultKeys: vaultKeysSnapshot
                )
                try data.write(to: targetURL, options: .atomic)
                isExporting = false
                let modeLabel = includeCredentials ? (mode == .passphrase ? "（口令加密含凭据）" : "（内置加密含凭据）") : "（零凭据）"
                onExported?("已导出 \(exportSessions.count) 台主机\(modeLabel)：\(targetURL.lastPathComponent)")
                dismiss()
            } catch {
                isExporting = false
                exportError = error.localizedDescription
            }
        }
    }

    private func authBadgeTitle(for auth: SSHAuthMethod) -> String {
        switch auth {
        case .password: return "密码"
        case .privateKey: return "私钥"
        case .certificate: return "证书"
        case .agent: return "Agent"
        case .none: return "免密"
        }
    }
}
