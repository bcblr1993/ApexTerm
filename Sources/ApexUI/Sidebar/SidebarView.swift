import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ApexCore

private struct GroupShareExportRequest: Identifiable {
    let id = UUID()
    let folder: String?
    let sessionIDs: Set<UUID>?
}

private struct GroupShareImportRequest: Identifiable {
    let id = UUID()
    let fileURL: URL?
}

/// Native macOS Sidebar with session tree, folders, tags, quick snippets, and full Chinese localization
public struct SidebarView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject private var shareCoordinator = IncomingShareCoordinator.shared
    @ObservedObject private var lockManager = AppLockManager.shared
    @ObservedObject var store: SessionStore
    @Binding var selectedSession: Session?
    let onConnect: (Session) -> Void
    let onRunSnippet: ((Snippet) -> Void)?
    
    @State private var searchFilter = ""
    @State private var showingAddSheet = false
    @State private var showingImportSheet = false
    @State private var exportRequest: GroupShareExportRequest?
    @State private var shareImportRequest: GroupShareImportRequest?
    @State private var isDropTargeted = false
    @State private var editingSession: Session?
    @State private var cloningSession: Session?
    @State private var sessionToDelete: Session?
    @State private var collapsedFolders: Set<String> = []
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var isToastSuccess = true

    /// Stable identity for the virtual local-terminal row in `List(selection:)`.
    public static let sidebarLocalRowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    
    public init(
        store: SessionStore,
        selectedSession: Binding<Session?>,
        onConnect: @escaping (Session) -> Void,
        onRunSnippet: ((Snippet) -> Void)? = nil
    ) {
        self.store = store
        self._selectedSession = selectedSession
        self.onConnect = onConnect
        self.onRunSnippet = onRunSnippet
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("会话")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(ApexStyle.primary)
                Spacer()
                Text("\(store.sessions.count) 台主机")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(ApexStyle.secondary)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.top, ApexStyle.s3)
            .padding(.bottom, ApexStyle.sRow)

            HStack(spacing: ApexStyle.sCompact) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(ApexStyle.secondary)
                    TextField(L10n.searchPlaceholder, text: $searchFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .accessibilityLabel(L10n.searchPlaceholder)
                    if !searchFilter.isEmpty {
                        ApexIconButton(
                            icon: "xmark.circle.fill",
                            label: "清空搜索",
                            size: 16,
                            iconSize: 10
                        ) {
                            searchFilter = ""
                        }
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                        .stroke(ApexStyle.border.opacity(0.7), lineWidth: 0.75)
                )
                
                Menu {
                    Button {
                        shareImportRequest = GroupShareImportRequest(fileURL: nil)
                    } label: {
                        Label("导入连接分享包 (.aetherpack / .json)...", systemImage: "shippingbox")
                    }

                    Button {
                        showingImportSheet = true
                    } label: {
                        Label("从 ~/.ssh/config 导入主机...", systemImage: "doc.text")
                    }

                    Divider()

                    Button {
                        exportRequest = GroupShareExportRequest(folder: nil, sessionIDs: nil)
                    } label: {
                        Label("导出连接分组 (.aetherpack)...", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!store.sessions.contains(where: { !$0.isLocal }))
                } label: {
                    ApexMenuTrigger(
                        icon: "square.and.arrow.down",
                        label: "导入与导出连接",
                        size: 24,
                        iconSize: 11
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("导入或导出连接分组")
                .accessibilityLabel("导入与导出连接")
                
                ApexIconButton(
                    icon: "plus",
                    label: L10n.addSessionHelp,
                    size: 24,
                    iconSize: 11,
                    tint: ApexStyle.accent
                ) {
                    showingAddSheet = true
                }
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.bottom, ApexStyle.s3)
            
            Divider()
                .padding(.horizontal, ApexStyle.s4)
                .padding(.bottom, ApexStyle.s1)
            
            if store.sessions.isEmpty && searchFilter.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "server.rack")
                        .font(.system(size: 38))
                        .foregroundStyle(.tertiary)
                    
                    VStack(spacing: 6) {
                        Text(L10n.emptySessionTitle)
                            .font(.headline)
                            .foregroundColor(ApexStyle.primary)
                        
                        Text(L10n.emptySessionSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(ApexStyle.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, ApexStyle.s4)
                    }
                    
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            emptyStateButtons
                        }
                        VStack(spacing: 8) {
                            emptyStateButtons
                        }
                    }
                    .padding(.horizontal, ApexStyle.s4)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Session tree
                let matchesLocalRow = searchFilter.isEmpty || "本地终端".localizedCaseInsensitiveContains(searchFilter) || "local".localizedCaseInsensitiveContains(searchFilter)
                List(selection: selectedSessionID) {
                    if matchesLocalRow {
                        Section(header: Label("本地环境", systemImage: "laptopcomputer").font(.caption).fontWeight(.semibold)) {
                            let local = Session.local(id: Self.sidebarLocalRowID)
                            SessionRow(
                                session: local,
                                isSelected: selectedSession?.id == local.id,
                                onConnect: { onConnect(Session.local()) }
                            )
                            .tag(local.id)
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    selectedSession = local
                                    onConnect(Session.local())
                                }
                            )
                        }
                    }
                    
                    Section(header: Label(L10n.sessionsHeader, systemImage: "server.rack").font(.caption).fontWeight(.semibold)) {
                        ForEach(groupedFolders, id: \.self) { folder in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { !collapsedFolders.contains(folder) || !searchFilter.isEmpty },
                                    set: { expanded in
                                        if expanded { collapsedFolders.remove(folder) }
                                        else { collapsedFolders.insert(folder) }
                                    }
                                ),
                                content: {
                                    ForEach(sessionsInFolder(folder)) { session in
                                        let rowSelected = selectedSession?.id == session.id
                                        SessionRow(
                                            session: session,
                                            isSelected: rowSelected,
                                            onConnect: { onConnect(session) }
                                        )
                                        .fontWeight(rowSelected ? .semibold : .regular)
                                        .tag(session.id)
                                        .simultaneousGesture(
                                            TapGesture(count: 2).onEnded {
                                                selectedSession = session
                                                onConnect(session)
                                            }
                                        )
                                        .contextMenu {
                                            Button(L10n.connectAction) {
                                                onConnect(session)
                                            }
                                            Button(L10n.editSessionAction) {
                                                editingSession = session
                                            }
                                            Divider()
                                            Button(L10n.copySessionInfoAction) {
                                                copySessionInfo(session)
                                            }
                                            Button(L10n.cloneSessionAction) {
                                                cloningSession = session
                                            }
                                            Button("导出此会话...") {
                                                exportRequest = GroupShareExportRequest(folder: Self.normalizedFolder(of: session), sessionIDs: [session.id])
                                            }
                                            Divider()
                                            Button(L10n.deleteSessionAction, role: .destructive) {
                                                sessionToDelete = session
                                            }
                                        }
                                    }
                                },
                                label: {
                                    HStack {
                                        Image(systemName: folderIcon(for: folder))
                                            .foregroundColor(ApexStyle.secondary)
                                        Text(folder)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(ApexStyle.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: ApexStyle.s1)
                                        Text("\(sessionsInFolder(folder).count)")
                                            .font(.system(size: 10, weight: .medium))
                                            .monospacedDigit()
                                            .foregroundColor(ApexStyle.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(ApexStyle.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius))
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button("向该分组批量执行 / 分发...") {
                                            let targetIDs = sessionsInFolder(folder)
                                                .filter { !$0.isLocal }
                                                .map(\.id)
                                            CommandPaletteItem.postOpenBatchOperations(sessionIDs: targetIDs, folder: folder)
                                        }
                                        .disabled(sessionsInFolder(folder).allSatisfy { $0.isLocal })

                                        Divider()

                                        Button("导出该分组...") {
                                            exportRequest = GroupShareExportRequest(folder: folder, sessionIDs: nil)
                                        }
                                        .disabled(sessionsInFolder(folder).isEmpty)

                                        Button("导出为 OpenSSH Config...") {
                                            exportFolderOpenSSHConfig(folder)
                                        }
                                        .disabled(sessionsInFolder(folder).isEmpty)
                                    }
                                }
                            )
                        }
                    }

                    if !searchFilter.isEmpty && !matchesLocalRow && !store.sessions.contains(where: { Self.matchesSearch($0, filter: searchFilter) }) {
                        ContentUnavailableView("未找到匹配会话", systemImage: "magnifyingglass",
                                               description: Text("检查会话名称、标签或主机地址，或清空搜索重试。"))
                    }
                }
                .listStyle(.sidebar)
                .foregroundStyle(Color.primary)
                .tint(ApexStyle.buttonAccent)
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            SessionEditModal(session: nil) { newSession in
                store.addSession(newSession)
            }
            .apexTheme()
        }
        .sheet(isPresented: $showingImportSheet) {
            SSHConfigImportSheet(store: store)
                .apexTheme()
        }
        .sheet(item: $exportRequest) { request in
            GroupShareExportSheet(
                store: store,
                initialFolder: request.folder,
                initialSessionIDs: request.sessionIDs
            ) { summary in
                showToast(summary, isSuccess: true)
            }
            .id(request.id)
            .apexTheme()
        }
        .sheet(item: $shareImportRequest) { request in
            GroupShareImportSheet(
                store: store,
                initialFileURL: request.fileURL
            ) { result in
                collapsedFolders.subtract(result.importedFolderNames)
                showToast(result.summaryText, isSuccess: true)
            }
            .id(request.id)
            .apexTheme()
        }
        .sheet(item: $editingSession) { session in
            SessionEditModal(session: session) { updated in
                store.updateSession(updated)
            }
            .apexTheme()
        }
        .sheet(item: $cloningSession) { sourceSession in
            SessionEditModal(session: sourceSession, isCloning: true) { clonedSession in
                store.addSession(clonedSession)
                selectedSession = clonedSession
                showToast("已克隆会话：\(clonedSession.name)", isSuccess: true)
            }
            .apexTheme()
        }
        .confirmationDialog("删除会话？", isPresented: Binding(
            get: { sessionToDelete != nil },
            set: { if !$0 { sessionToDelete = nil } }
        )) {
            Button("删除 \(sessionToDelete?.name ?? "会话")", role: .destructive) {
                if let sessionToDelete {
                    store.deleteSession(id: sessionToDelete.id)
                    if selectedSession?.id == sessionToDelete.id { selectedSession = nil }
                }
                sessionToDelete = nil
            }
        } message: {
            Text("删除后无法从应用内恢复。")
        }
        .overlay(alignment: .bottom) {
            if let toast = toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: isToastSuccess ? "checkmark.circle.fill" : "info.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isToastSuccess ? ApexStyle.success : ApexStyle.warning)
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ApexStyle.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .apexGlassCard(cornerRadius: 14, material: .regularMaterial, borderColor: ApexStyle.border.opacity(0.55), shadowRadius: 8)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toastMessage)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: ApexStyle.radius)
                    .strokeBorder(ApexStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(ApexStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: ApexStyle.radius))
                    .overlay(alignment: .bottom) {
                        Text("释放以导入 .aetherpack 连接分享包")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(ApexStyle.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .apexGlassCard(cornerRadius: 12, material: .regularMaterial, shadowRadius: 4)
                            .padding(.bottom, 16)
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleSidebarDrop(providers: providers)
        }
        .task {
            if !lockManager.isLocked, let pendingURL = shareCoordinator.consumePendingImportURL() {
                shareImportRequest = GroupShareImportRequest(fileURL: pendingURL)
            }
        }
        .onChange(of: lockManager.isLocked) { _, isLocked in
            if isLocked {
                showingAddSheet = false
                showingImportSheet = false
                exportRequest = nil
                shareImportRequest = nil
                editingSession = nil
                cloningSession = nil
                sessionToDelete = nil
            } else if let pendingURL = shareCoordinator.consumePendingImportURL() {
                shareImportRequest = GroupShareImportRequest(fileURL: pendingURL)
            }
        }
        .onChange(of: shareCoordinator.openImportTrigger) { _, _ in
            guard !lockManager.isLocked else { return }
            let url = shareCoordinator.consumePendingImportURL()
            shareImportRequest = GroupShareImportRequest(fileURL: url)
        }
        .onChange(of: shareCoordinator.openExportTrigger) { _, _ in
            guard !lockManager.isLocked else { return }
            exportRequest = GroupShareExportRequest(folder: nil, sessionIDs: nil)
        }
    }

    // MARK: - Group Share Helpers

    private func handleSidebarDrop(providers: [NSItemProvider]) -> Bool {
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
            guard let fileURL = resolvedURL, SessionBundleExporter.isSupportedShareFileURL(fileURL) else {
                return
            }
            Task { @MainActor in
                shareImportRequest = GroupShareImportRequest(fileURL: fileURL)
            }
        }
        return true
    }

    private func exportFolderOpenSSHConfig(_ folder: String) {
        let groupSessions = sessionsInFolder(folder)
        guard !groupSessions.isEmpty else { return }

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "\(folder)-ssh_config"
        savePanel.prompt = "导出 OpenSSH Config"
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                let text = SessionBundleExporter.generateOpenSSHConfig(from: groupSessions)
                try text.write(to: url, atomically: true, encoding: .utf8)
                showToast("已导出分组 [\(folder)] 的 OpenSSH Config", isSuccess: true)
            } catch {
                showToast("导出失败：\(error.localizedDescription)", isSuccess: false)
            }
        }
    }

    // MARK: - Credential & Info Copy Actions

    private func copySessionInfo(_ session: Session) {
        Task {
            let secret = await SessionCopyHelper.resolveSecret(for: session)
            if let secret, !secret.isEmpty, AppLockManager.shared.requireAuthForSensitiveActions {
                let authorized = await AppLockManager.shared.authorizeSensitiveAction(
                    reason: "验证身份以复制包含密码或私钥口令的会话信息"
                )
                guard authorized else {
                    await MainActor.run {
                        showToast(AppLockManager.shared.lastErrorMessage ?? "未通过身份验证，已取消复制会话信息", isSuccess: false)
                    }
                    return
                }
            }
            let formatted = SessionCopyHelper.formatSessionInfo(session: session, password: secret)
            await MainActor.run {
                if let secret, !secret.isEmpty {
                    SensitivePasteboardHelper.shared.copySecret(formatted)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(formatted, forType: .string)
                }
                showToast(L10n.copiedSessionInfoToast, isSuccess: true)
            }
        }
    }

    private func showToast(_ message: String, isSuccess: Bool = true) {
        let token = UUID()
        toastToken = token
        toastMessage = message
        isToastSuccess = isSuccess
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.toastToken == token {
                withAnimation(.easeOut(duration: 0.2)) {
                    self.toastMessage = nil
                }
            }
        }
    }

    private var selectedSessionID: Binding<UUID?> {
        Binding(
            get: { selectedSession?.id },
            set: { id in
                if id == Self.sidebarLocalRowID {
                    selectedSession = Session.local(id: Self.sidebarLocalRowID)
                } else {
                    selectedSession = store.sessions.first(where: { $0.id == id })
                }
            }
        )
    }
    
    private var groupedFolders: [String] {
        Self.folderNames(sessions: store.sessions, extraFolders: store.folders, searchFilter: searchFilter)
    }
    
    private func sessionsInFolder(_ folder: String) -> [Session] {
        Self.sessions(in: folder, from: store.sessions, searchFilter: searchFilter)
    }

    /// Blank or padded folder names group under the same trimmed key the tree renders.
    public static func normalizedFolder(of session: Session) -> String {
        let trimmed = (session.folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.generalFolder : trimmed
    }

    public static func matchesSearch(_ session: Session, filter: String) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return session.name.localizedCaseInsensitiveContains(query) ||
            session.host.localizedCaseInsensitiveContains(query) ||
            session.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
    }

    /// While searching, folders without a matching session are hidden instead of rendering empty groups.
    public static func folderNames(sessions: [Session], extraFolders: [String], searchFilter: String) -> [String] {
        var set = Set(sessions.filter { matchesSearch($0, filter: searchFilter) }.map(normalizedFolder(of:)))
        if searchFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for f in extraFolders {
                let trimmed = f.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { set.insert(trimmed) }
            }
        }
        return Array(set).sorted()
    }

    public static func sessions(in folder: String, from sessions: [Session], searchFilter: String) -> [Session] {
        sessions.filter { normalizedFolder(of: $0) == folder && matchesSearch($0, filter: searchFilter) }
    }
    
    @ViewBuilder
    private var emptyStateButtons: some View {
        ApexActionButton(
            L10n.openLocalTerminal,
            icon: "laptopcomputer",
            tint: ApexStyle.secondary,
            size: .regular
        ) {
            onConnect(Session.local())
        }

        ApexActionButton(
            L10n.addFirstSessionButton,
            icon: "plus",
            tint: ApexStyle.accent,
            size: .regular,
            isProminent: true
        ) {
            showingAddSheet = true
        }
    }

    private func folderIcon(for folder: String) -> String {
        switch folder {
        case "生产环境", "Production": return "flame.fill"
        case "测试环境", "Staging": return "testtube.2"
        case "数据库", "Database": return "cylinder.split.1x2.fill"
        default: return "folder.fill"
        }
    }
}

struct SessionRow: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    let session: Session
    let isSelected: Bool
    let onConnect: () -> Void
    
    @State private var isHovered = false
    
    private var dotColor: Color {
        Color(hex: session.colorHex ?? (session.isLocal ? "#34C759" : "#0A84FF")) ?? .blue
    }
    
    var body: some View {
        HStack(spacing: ApexStyle.s2) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(isSelected ? 0.5 : 0), lineWidth: 1)
                )
                .shadow(color: dotColor.opacity(isHovered ? 0.6 : 0.35), radius: isHovered ? 3.5 : 2)
                .scaleEffect(isHovered ? 1.15 : 1.0)
            
            VStack(alignment: .leading, spacing: ApexStyle.sMicro) {
                Text(session.name)
                    .font(.subheadline)
                    .foregroundColor(isSelected ? .primary : ApexStyle.primary)
                    .lineLimit(1)
                
                Text(session.isLocal ? "\(L10n.localTerminalSubtitle) (\(session.username))" : "\(session.username)@\(session.host)")
                    .font(.caption.monospaced())
                    .foregroundColor(isSelected ? .secondary : ApexStyle.secondary)
                    .lineLimit(1)
            }
            
            Spacer(minLength: ApexStyle.s1)

            ApexIconButton(
                icon: "arrow.up.right",
                label: "连接到 \(session.name)",
                size: 22,
                iconSize: 10,
                tint: isSelected ? .primary : (isHovered ? ApexStyle.accent : nil)
            ) {
                onConnect()
            }
            .opacity(isSelected || isHovered ? 1.0 : 0.75)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: ApexStyle.badgeRadius)
                .fill(isSelected ? Color.clear : (isHovered ? ApexStyle.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(ApexStyle.hoverTransition) {
                isHovered = h
            }
        }
    }
}

extension Color {
    init?(hex: String) {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") { clean.removeFirst() }
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
