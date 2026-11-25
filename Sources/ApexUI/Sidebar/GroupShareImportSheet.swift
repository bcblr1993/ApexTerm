import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ApexCore

/// Unified interactive wizard for inspecting, unlocking, previewing, and importing
/// `.aetherpack`, `.aetherpack.json`, and legacy `[Session]` JSON share files.
public struct GroupShareImportSheet: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject public var store: SessionStore
    @ObservedObject private var tunnelManager: SSHTunnelManager
    @ObservedObject private var bookmarkManager: SFTPBookmarkManager
    @ObservedObject private var vaultManager: SSHKeyVaultManager
    @Environment(\.dismiss) private var dismiss

    public let initialFileURL: URL?
    public let onImported: ((SharePackImportResult) -> Void)?

    private enum TargetFolderChoice: String, CaseIterable {
        case preserveOriginal = "保留原分组"
        case existingFolder = "导入到已有分组"
        case newFolder = "新建分组"
    }

    @State private var loadedURL: URL?
    @State private var fileData: Data?
    @State private var inspection: SharePackInspection?
    @State private var decryptedBundle: SharePackSecretBundle?

    @State private var passphraseInput = ""
    @State private var showPassphrase = false
    @State private var loadError: String?
    @State private var decryptError: String?
    @State private var isDropTargeted = false

    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var targetFolderChoice: TargetFolderChoice = .preserveOriginal
    @State private var selectedExistingFolder = ""
    @State private var customNewFolder = ""
    @State private var conflictStrategy: SharePackConflictStrategy = .skipExisting
    @State private var importCredentials = true
    @State private var includeTunnels = true
    @State private var includeSnippets = true
    @State private var includeTriggers = true
    @State private var includeBookmarks = true
    @State private var isImporting = false

    public init(
        store: SessionStore,
        tunnelManager: SSHTunnelManager = .shared,
        bookmarkManager: SFTPBookmarkManager = .shared,
        vaultManager: SSHKeyVaultManager = .shared,
        initialFileURL: URL? = nil,
        onImported: ((SharePackImportResult) -> Void)? = nil
    ) {
        self.store = store
        self._tunnelManager = ObservedObject(wrappedValue: tunnelManager)
        self._bookmarkManager = ObservedObject(wrappedValue: bookmarkManager)
        self._vaultManager = ObservedObject(wrappedValue: vaultManager)
        self.initialFileURL = initialFileURL
        self.onImported = onImported
    }

    private var existingFolders: [String] {
        SessionEditModal.existingFolders(sessions: store.sessions, extraFolders: store.folders)
    }

    private var effectiveTargetFolderMode: SharePackTargetFolderMode {
        switch targetFolderChoice {
        case .preserveOriginal:
            return .preserveOriginal
        case .existingFolder:
            let fallback = existingFolders.first ?? L10n.generalFolder
            return .assignToFolder(selectedExistingFolder.isEmpty ? fallback : selectedExistingFolder)
        case .newFolder:
            let trimmed = customNewFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            return .assignToFolder(trimmed.isEmpty ? "导入分组" : trimmed)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            Group {
                if let bundle = decryptedBundle {
                    previewAndOptionsView(bundle: bundle)
                } else if let inspection, inspection.requiresPassphrase {
                    passphrasePromptView(inspection: inspection)
                } else {
                    fileChooserView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ApexStyle.surface)

            Divider()
            footerBar
        }
        .frame(width: 600, height: 600)
        .background(ApexStyle.surface)
        .onAppear {
            if loadedURL == nil, let url = initialFileURL {
                loadShareFile(from: url)
            }
        }
    }

    // MARK: - Header & Footer

    private var headerBar: some View {
        HStack(spacing: ApexStyle.s3) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.system(size: 20))
                .foregroundColor(ApexStyle.accent)
                .frame(width: 40, height: 40)
                .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: ApexStyle.radius))

            VStack(alignment: .leading, spacing: 2) {
                Text("导入连接分组分享包")
                    .font(.headline)
                    .foregroundColor(ApexStyle.primary)
                    .lineLimit(1)
                Text(loadedURL?.lastPathComponent ?? "支持 .aetherpack 加密分享包、.aetherpack.json 与历史会话 JSON")
                    .font(.subheadline)
                    .foregroundColor(ApexStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            ApexIconButton(icon: "xmark", label: "关闭 (Esc)", size: 24, iconSize: 11) {
                dismiss()
            }
        }
        .padding(ApexStyle.s4)
        .background(ApexStyle.surface)
    }

    private var footerBar: some View {
        HStack(spacing: ApexStyle.sCompact) {
            if decryptedBundle != nil || inspection != nil {
                ApexActionButton("换个文件", icon: "folder", tint: ApexStyle.secondary, size: .regular) {
                    chooseFile()
                }
            }

            if let error = loadError ?? decryptError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(ApexStyle.error)
                    .lineLimit(2)
            }

            Spacer()

            ApexActionButton("取消", tint: ApexStyle.secondary, size: .regular) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if let bundle = decryptedBundle {
                ApexActionButton(
                    "导入选中的 \(selectedSessionIDs.count) 台主机",
                    icon: "square.and.arrow.down",
                    tint: ApexStyle.accent,
                    size: .regular,
                    isProminent: true,
                    isLoading: isImporting
                ) {
                    performImport(bundle: bundle)
                }
                .disabled(selectedSessionIDs.isEmpty || isImporting)
                .keyboardShortcut(.defaultAction)
            } else if inspection?.requiresPassphrase == true {
                ApexActionButton(
                    "解密并预览",
                    icon: "lock.open.fill",
                    tint: ApexStyle.accent,
                    size: .regular,
                    isProminent: true
                ) {
                    unlockPassphraseProtectedPack()
                }
                .disabled(passphraseInput.isEmpty)
                .keyboardShortcut(.defaultAction)
            } else {
                ApexActionButton("选择分享文件...", icon: "doc.badge.plus", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    chooseFile()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ApexStyle.s4)
        .background(ApexStyle.surface)
        .onExitCommand {
            dismiss()
        }
    }

    // MARK: - Stage 1: File Chooser & Dropzone

    private var fileChooserView: some View {
        VStack(spacing: ApexStyle.s4) {
            Spacer()

            VStack(spacing: ApexStyle.s3) {
                Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "shippingbox")
                    .font(.system(size: 40))
                    .foregroundColor(isDropTargeted ? ApexStyle.accent : ApexStyle.secondary)

                Text("将 .aetherpack 或会话 .json 文件拖到此处")
                    .font(.headline)
                    .foregroundColor(ApexStyle.primary)

                Text("支持加密含凭据分享包（可一键导入即连）、零凭据分享包及历史 JSON 备份")
                    .font(.caption)
                    .foregroundColor(ApexStyle.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, ApexStyle.s5)

                ApexActionButton("选择分享包文件...", icon: "folder", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    chooseFile()
                }
            }
            .padding(ApexStyle.s6)
            .frame(maxWidth: 460)
            .background(
                (isDropTargeted ? ApexStyle.accent.opacity(0.1) : ApexStyle.subtleSurface),
                in: RoundedRectangle(cornerRadius: ApexStyle.panelRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ApexStyle.panelRadius)
                    .strokeBorder(
                        isDropTargeted ? ApexStyle.accent : ApexStyle.border,
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4])
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }

            Spacer()
        }
        .padding(ApexStyle.s4)
    }

    // MARK: - Stage 2: Passphrase Unlock

    private func passphrasePromptView(inspection: SharePackInspection) -> some View {
        VStack(spacing: ApexStyle.s4) {
            Spacer()

            VStack(alignment: .leading, spacing: ApexStyle.s3) {
                HStack(spacing: ApexStyle.s2) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22))
                        .foregroundColor(ApexStyle.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("此分享包已启用口令加密")
                            .font(.headline)
                            .foregroundColor(ApexStyle.primary)
                        Text(summaryHeaderText(for: inspection.header))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(ApexStyle.secondary)
                    }
                }

                Divider()

                Text("请输入分享者提供的口令以解密连接信息与凭据：")
                    .font(.subheadline)
                    .foregroundColor(ApexStyle.primary)

                HStack(spacing: ApexStyle.s2) {
                    Group {
                        if showPassphrase {
                            TextField("输入分享口令", text: $passphraseInput)
                        } else {
                            SecureField("输入分享口令", text: $passphraseInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("解密口令")
                    .onSubmit {
                        unlockPassphraseProtectedPack()
                    }

                    ApexIconButton(
                        icon: showPassphrase ? "eye.slash" : "eye",
                        label: showPassphrase ? "隐藏口令" : "显示口令",
                        size: 24,
                        iconSize: 11
                    ) {
                        showPassphrase.toggle()
                    }
                }

                if let decryptError {
                    Label(decryptError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(ApexStyle.error)
                }
            }
            .padding(ApexStyle.s5)
            .frame(maxWidth: 460)
            .apexPanel()

            Spacer()
        }
        .padding(ApexStyle.s4)
    }

    // MARK: - Stage 3: Preview & Target Options

    private func previewAndOptionsView(bundle: SharePackSecretBundle) -> some View {
        let candidates = bundle.pack.sessions.filter { !$0.isLocal }
        let grouped = SidebarView.folderNames(sessions: candidates, extraFolders: [], searchFilter: "")
        let relevantTunnelCount = bundle.pack.tunnels.filter { selectedSessionIDs.contains($0.sessionId) }.count

        return ScrollView {
            VStack(alignment: .leading, spacing: ApexStyle.s3) {
                HStack(spacing: ApexStyle.s2) {
                    protectionBadge
                    Spacer()
                    Text("已选 \(selectedSessionIDs.count) / \(candidates.count) 台")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(ApexStyle.secondary)
                    ApexActionButton("全选", icon: "checkmark.circle", tint: ApexStyle.accent, size: .small) {
                        selectedSessionIDs = Set(candidates.map(\.id))
                    }
                    .disabled(selectedSessionIDs.count == candidates.count)
                    ApexActionButton("清空", icon: "circle", tint: ApexStyle.secondary, size: .small) {
                        selectedSessionIDs.removeAll()
                    }
                    .disabled(selectedSessionIDs.isEmpty)
                }

                VStack(alignment: .leading, spacing: ApexStyle.s2) {
                    if candidates.isEmpty {
                        ContentUnavailableView(
                            "分享包中暂无可导入的远程主机",
                            systemImage: "server.rack",
                            description: Text("该文件未包含非本地 SSH 会话，请检查分享源或选择其他文件。")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, ApexStyle.s4)
                    } else {
                        ForEach(grouped, id: \.self) { folder in
                        let members = candidates.filter { SidebarView.normalizedFolder(of: $0) == folder }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: ApexStyle.sCompact) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(ApexStyle.secondary)
                                Text(folder)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(ApexStyle.primary)
                                Spacer()
                                Text("\(members.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(ApexStyle.secondary)
                            }

                            ForEach(members) { session in
                                let hasCred = bundle.credentials.hasCredential(for: session.id)
                                let isDuplicate = matchesLocalSession(session)

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
                                    .accessibilityLabel("勾选导入 \(session.name)")

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: ApexStyle.sCompact) {
                                            Text(session.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(ApexStyle.primary)
                                                .lineLimit(1)
                                            if hasCred {
                                                badgePill(text: "含凭据", color: ApexStyle.success)
                                            }
                                            if isDuplicate {
                                                badgePill(text: "本地已存在", color: ApexStyle.warning)
                                            }
                                        }
                                        Text("\(session.username)@\(session.host):\(session.port)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(ApexStyle.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text(authBadgeTitle(for: session.authMethod))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(ApexStyle.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(ApexStyle.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius))
                                        .fixedSize()
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        if folder != grouped.last {
                            Divider().padding(.vertical, 2)
                        }
                        }
                    }
                }
                .padding(ApexStyle.s3)
                .apexPanel()

                // Import mapping & conflict strategy
                VStack(alignment: .leading, spacing: ApexStyle.sRow) {
                    Text("导入设置")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(ApexStyle.primary)

                    HStack(spacing: ApexStyle.s2) {
                        Text("目标分组:")
                            .font(.subheadline)
                            .foregroundColor(ApexStyle.secondary)
                            .frame(width: 72, alignment: .leading)

                        Picker("", selection: $targetFolderChoice) {
                            ForEach(TargetFolderChoice.allCases, id: \.self) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    if targetFolderChoice == .existingFolder {
                        HStack(spacing: ApexStyle.s2) {
                            Spacer().frame(width: 72)
                            if existingFolders.isEmpty {
                                Text("暂无已有分组（将导入到「\(L10n.generalFolder)」）")
                                    .font(.caption)
                                    .foregroundColor(ApexStyle.secondary)
                            } else {
                                Picker("已有分组", selection: $selectedExistingFolder) {
                                    ForEach(existingFolders, id: \.self) { folder in
                                        Text(folder).tag(folder)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    } else if targetFolderChoice == .newFolder {
                        HStack(spacing: ApexStyle.s2) {
                            Spacer().frame(width: 72)
                            TextField("输入新建分组名称", text: $customNewFolder)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    HStack(spacing: ApexStyle.s2) {
                        Text("重复主机:")
                            .font(.subheadline)
                            .foregroundColor(ApexStyle.secondary)
                            .frame(width: 72, alignment: .leading)

                        Picker("", selection: $conflictStrategy) {
                            ForEach(SharePackConflictStrategy.allCases, id: \.self) { strategy in
                                Text(strategy.title).tag(strategy)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 145), spacing: ApexStyle.s3, alignment: .leading)],
                        alignment: .leading,
                        spacing: ApexStyle.s2
                    ) {
                        if bundle.credentials.hasAnySecret {
                            Toggle("写入加密凭据", isOn: $importCredentials)
                        }
                        if !bundle.pack.tunnels.isEmpty {
                            Toggle("关联隧道 (\(relevantTunnelCount))", isOn: $includeTunnels)
                        }
                        if !bundle.pack.snippets.isEmpty {
                            Toggle("快捷命令 (\(bundle.pack.snippets.count))", isOn: $includeSnippets)
                        }
                        if !bundle.pack.bookmarks.isEmpty {
                            Toggle("书签 (\(bundle.pack.bookmarks.count))", isOn: $includeBookmarks)
                        }
                        if !bundle.pack.triggers.isEmpty {
                            Toggle("触发器 (\(bundle.pack.triggers.count))", isOn: $includeTriggers)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(ApexStyle.primary)
                }
                .padding(ApexStyle.s3)
                .apexPanel()
            }
            .padding(ApexStyle.s4)
        }
    }

    @ViewBuilder
    private var protectionBadge: some View {
        let (title, icon, tint): (String, String, Color) = {
            guard let format = inspection?.sourceFormat else {
                return ("分享包", "shippingbox", ApexStyle.accent)
            }
            switch format {
            case .envelopeV2(.appSealed):
                return ("内置加密 · 含凭据", "checkmark.shield.fill", ApexStyle.success)
            case .envelopeV2(.passphrase):
                return ("口令加密 · 已解密", "lock.open.fill", ApexStyle.success)
            case .envelopeV2(.zeroCredential):
                return ("零凭据分享包", "shippingbox", ApexStyle.secondary)
            case .legacySharePackV1:
                return ("零凭据分享包 (v1)", "shippingbox", ApexStyle.secondary)
            case .legacySessionArray:
                return ("历史会话 JSON", "doc.text", ApexStyle.secondary)
            }
        }()

        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func badgePill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.aetherPack, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "打开分享包"
        panel.message = "选择 AetherTerm .aetherpack 或会话 .json 文件"
        if panel.runModal() == .OK, let url = panel.url {
            loadShareFile(from: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let resolvedURL: URL?
            if let data = item as? Data {
                resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                resolvedURL = url
            } else {
                resolvedURL = nil
            }
            guard let fileURL = resolvedURL else { return }
            Task { @MainActor in
                loadShareFile(from: fileURL)
            }
        }
        return true
    }

    private func loadShareFile(from url: URL) {
        loadError = nil
        decryptError = nil
        passphraseInput = ""

        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: url)
            let result = try SessionBundleExporter.inspectSharePackData(data)
            self.loadedURL = url
            self.fileData = data
            self.inspection = result
            if let bundle = result.decryptedBundle {
                applyUnlockedBundle(bundle, header: result.header)
            } else {
                self.decryptedBundle = nil
            }
        } catch {
            self.loadedURL = nil
            self.fileData = nil
            self.inspection = nil
            self.decryptedBundle = nil
            self.selectedSessionIDs = []
            self.loadError = error.localizedDescription
        }
    }

    private func unlockPassphraseProtectedPack() {
        guard let data = fileData, let header = inspection?.header else { return }
        decryptError = nil
        do {
            let bundle = try SessionBundleExporter.decryptSharePackData(data, passphrase: passphraseInput)
            applyUnlockedBundle(bundle, header: header)
        } catch {
            decryptError = error.localizedDescription
        }
    }

    private func applyUnlockedBundle(_ bundle: SharePackSecretBundle, header: AetherShareEnvelopeHeader) {
        self.decryptedBundle = bundle
        self.selectedSessionIDs = Set(bundle.pack.sessions.filter { !$0.isLocal }.map(\.id))
        if selectedExistingFolder.isEmpty {
            selectedExistingFolder = existingFolders.first ?? L10n.generalFolder
        }
        if customNewFolder.isEmpty {
            customNewFolder = header.groupNames.first ?? "导入分组"
        }
        importCredentials = bundle.credentials.hasAnySecret
    }

    private func performImport(bundle: SharePackSecretBundle) {
        isImporting = true
        loadError = nil
        do {
            let options = SharePackImportOptions(
                selectedSessionIDs: selectedSessionIDs,
                includeTunnels: includeTunnels,
                includeSnippets: includeSnippets,
                includeTriggers: includeTriggers,
                includeBookmarks: includeBookmarks,
                conflictStrategy: conflictStrategy,
                targetFolderMode: effectiveTargetFolderMode,
                importCredentials: importCredentials
            )
            let result = try SessionBundleExporter.importDecryptedBundle(
                bundle,
                into: store,
                options: options,
                bookmarkManager: bookmarkManager,
                tunnelManager: tunnelManager,
                vaultManager: vaultManager
            )
            isImporting = false
            onImported?(result)
            dismiss()
        } catch {
            isImporting = false
            loadError = error.localizedDescription
        }
    }

    private func matchesLocalSession(_ incoming: Session) -> Bool {
        store.sessions.contains {
            $0.id == incoming.id || (
                $0.host.caseInsensitiveCompare(incoming.host) == .orderedSame &&
                $0.port == incoming.port &&
                $0.username.caseInsensitiveCompare(incoming.username) == .orderedSame &&
                $0.name.caseInsensitiveCompare(incoming.name) == .orderedSame
            )
        }
    }

    private func summaryHeaderText(for header: AetherShareEnvelopeHeader) -> String {
        let groupsText = header.groupNames.isEmpty ? "未命名分组" : header.groupNames.joined(separator: "、")
        return "分组：\(groupsText) · \(header.sessionCount) 台主机 · \(header.tunnelCount) 条隧道"
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
