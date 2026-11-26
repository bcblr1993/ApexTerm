import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ApexCore
import ApexSSH

/// Multi-host batch command execution & file distribution sheet.
public struct BatchOperationsSheet: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject private var templateStore = BatchCommandTemplateStore.shared
    @ObservedObject public var manager: BatchOperationsManager
    @Environment(\.dismiss) private var dismiss

    public let availableSessions: [Session]
    public let initialSelectedIDs: Set<UUID>
    public let initialFolder: String?
    public let activeConnectionStates: [UUID: SSHConnectionState]

    private enum ResultFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case failed = "失败"
        case succeeded = "成功"

        var id: String { rawValue }
    }

    @State private var selectedSessionIDs: Set<UUID>
    @State private var selectedFolders: Set<String> = []
    @State private var selectedTags: Set<String> = []
    @State private var hostSearchText: String = ""
    @State private var mode: BatchOperationMode
    @State private var commandText: String
    @State private var templateVariables: [String: String] = [:]
    @State private var selectedTemplateID: UUID? = nil
    @State private var showingSaveTemplateSheet: Bool = false
    @State private var newTemplateName: String = ""
    @State private var newTemplateCategory: String = "自定义"
    @State private var showingVariablePromptSheet: Bool = false
    @State private var pendingLaunchAfterVarPrompt: Bool = false
    @State private var selectedLocalURLs: [URL]
    @State private var remoteDirectory: String
    @State private var createRemoteDirectory: Bool = true
    @State private var showProdConfirmation: Bool = false
    @State private var expandedResultIDs: Set<UUID> = []
    @State private var resultFilter: ResultFilter = .all
    @State private var toastMessage: String?
    @State private var toastIsError: Bool = false
    @State private var showCloseConfirmation: Bool = false

    public init(
        availableSessions: [Session],
        initialSelectedIDs: Set<UUID> = [],
        initialFolder: String? = nil,
        activeConnectionStates: [UUID: SSHConnectionState] = [:],
        manager: BatchOperationsManager = .shared
    ) {
        let remotes = availableSessions.filter { !$0.isLocal }
        self.availableSessions = remotes
        self.initialSelectedIDs = initialSelectedIDs
        self.initialFolder = initialFolder
        self.activeConnectionStates = activeConnectionStates
        self.manager = manager

        let validIDs = Set(remotes.map(\.id))
        let initialSelection: Set<UUID>
        if !initialSelectedIDs.isEmpty {
            initialSelection = initialSelectedIDs.intersection(validIDs)
        } else if let targetFolder = initialFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !targetFolder.isEmpty {
            let matched = remotes.filter {
                SidebarView.normalizedFolder(of: $0).caseInsensitiveCompare(targetFolder) == .orderedSame
            }
            initialSelection = Set(matched.map(\.id))
        } else if manager.isRunning || !manager.results.isEmpty {
            initialSelection = Set(manager.results.map(\.sessionID)).intersection(validIDs)
        } else {
            initialSelection = []
        }

        self._selectedSessionIDs = State(initialValue: initialSelection)
        if let targetFolder = initialFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetFolder.isEmpty {
            let folders = SidebarView.folderNames(sessions: remotes, extraFolders: [], searchFilter: "")
            if let canonical = folders.first(where: { $0.caseInsensitiveCompare(targetFolder) == .orderedSame }) {
                self._selectedFolders = State(initialValue: [canonical])
            }
        }

        if manager.isRunning || !manager.results.isEmpty {
            self._mode = State(initialValue: manager.currentMode)
            self._commandText = State(initialValue: manager.lastCommand.isEmpty ? "uname -a && uptime" : manager.lastCommand)
            self._selectedLocalURLs = State(initialValue: manager.lastUploadURLs)
            self._remoteDirectory = State(initialValue: manager.lastRemoteDirectory.isEmpty ? "/tmp" : manager.lastRemoteDirectory)
        } else {
            self._mode = State(initialValue: .command)
            self._commandText = State(initialValue: "uname -a && uptime")
            self._selectedLocalURLs = State(initialValue: [])
            self._remoteDirectory = State(initialValue: "/tmp")
        }
    }

    public init(
        store: SessionStore,
        initialSelectedIDs: Set<UUID> = [],
        initialFolder: String? = nil,
        activeConnectionStates: [UUID: SSHConnectionState] = [:],
        manager: BatchOperationsManager = .shared
    ) {
        self.init(
            availableSessions: store.sessions,
            initialSelectedIDs: initialSelectedIDs,
            initialFolder: initialFolder,
            activeConnectionStates: activeConnectionStates,
            manager: manager
        )
    }

    private var folderOptions: [String] {
        SidebarView.folderNames(sessions: availableSessions, extraFolders: [], searchFilter: "")
    }

    private var tagOptions: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for session in availableSessions {
            for rawTag in session.tags {
                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tag.isEmpty && seen.insert(tag.lowercased()).inserted {
                    result.append(tag)
                }
            }
        }
        return result.sorted()
    }

    private var filteredSessions: [Session] {
        availableSessions.filter { session in
            let matchesFolder = selectedFolders.isEmpty
                || selectedFolders.contains(where: { SidebarView.normalizedFolder(of: session).caseInsensitiveCompare($0) == .orderedSame })
            let matchesTags = selectedTags.isEmpty
                || session.tags.contains(where: { tag in
                    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    return selectedTags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
                })
            let matchesQuery = hostSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || SidebarView.matchesSearch(session, filter: hostSearchText)
            return matchesFolder && matchesTags && matchesQuery
        }
    }

    public static func isProductionSession(_ session: Session) -> Bool {
        if let hex = session.colorHex?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           hex == "#FF453A" {
            return true
        }
        let hasProdTag = session.tags.contains { raw in
            let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return upper == "PROD" || upper == "[PROD]" || upper == "PRODUCTION" || upper.contains("生产")
        }
        if hasProdTag { return true }
        let folderUpper = (session.folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return folderUpper == "PROD" || folderUpper == "PRODUCTION" || folderUpper == "生产环境"
    }

    private var selectedProductionSessions: [Session] {
        selectedSessions.filter { Self.isProductionSession($0) }
    }

    private var detectedCommandVariables: [String] {
        BatchCommandTemplate.extractVariables(from: commandText)
    }

    private var resolvedCommandPreview: String {
        BatchCommandTemplate.interpolate(commandText, context: templateVariables)
    }

    private var filteredResults: [BatchHostResult] {
        switch resultFilter {
        case .all:
            return manager.results
        case .failed:
            return manager.results.filter { $0.status.isFailed }
        case .succeeded:
            return manager.results.filter { $0.status == .succeeded }
        }
    }

    private var selectedSessions: [Session] {
        availableSessions.filter { selectedSessionIDs.contains($0.id) }
    }

    private var canStartBatch: Bool {
        guard !manager.isRunning, !selectedSessions.isEmpty else { return false }
        switch mode {
        case .command:
            return !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .fileDistribution:
            return !selectedLocalURLs.isEmpty && !remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            HSplitView {
                hostSelectionPane
                    .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)

                executionAndResultsPane
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(ApexStyle.surface)

            Divider()
            footerBar
        }
        .frame(width: 860, height: 640)
        .background(ApexStyle.surface)
        .apexTheme()
        .confirmationDialog(
            "批量任务仍在执行中",
            isPresented: $showCloseConfirmation
        ) {
            Button("停止任务并关闭", role: .destructive) {
                manager.cancelCurrentBatch()
                dismiss()
            }
            Button("后台继续并关闭", role: .none) {
                dismiss()
            }
            Button("继续等待", role: .cancel) {}
        } message: {
            Text("当前仍有 \(manager.runningCount + manager.pendingCount) 台主机尚未完成，确定要关闭窗口吗？")
        }
        .confirmationDialog(
            "即将对生产环境 ([PROD] / 红色标记) 主机执行操作",
            isPresented: $showProdConfirmation
        ) {
            Button("确认执行 (\(selectedProductionSessions.count) 台生产主机)", role: .destructive) {
                executeBatchNow()
            }
            Button("取消", role: .cancel) {}
        } message: {
            let names = selectedProductionSessions.prefix(5).map(\.name).joined(separator: "、")
            let suffix = selectedProductionSessions.count > 5 ? " 等 \(selectedProductionSessions.count) 台" : ""
            Text("目标包含生产标记主机：\(names)\(suffix)。请确认操作安全后继续。")
        }
        .sheet(isPresented: $showingSaveTemplateSheet) {
            saveTemplateSheet
                .apexTheme()
        }
        .sheet(isPresented: $showingVariablePromptSheet) {
            variablePromptSheet
                .apexTheme()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: ApexStyle.s3) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(ApexStyle.accent)
                .frame(width: 36, height: 36)
                .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))

            VStack(alignment: .leading, spacing: 2) {
                Text("多主机批量命令执行与文件分发")
                    .font(.headline)
                    .foregroundColor(ApexStyle.primary)
                    .lineLimit(1)

                Text("支持按并发上限向多台主机并发执行 SSH 命令或通过 SCP 分发本地文件")
                    .font(.caption)
                    .foregroundColor(ApexStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: ApexStyle.s3)

            Picker("", selection: $mode) {
                ForEach(BatchOperationMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .disabled(manager.isRunning)

            ApexIconButton(icon: "xmark", label: "关闭 (Esc)", size: 26, iconSize: 11) {
                requestClose()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, ApexStyle.s3)
        .background(ApexStyle.surface)
    }

    // MARK: - Left Host Selection Pane

    private var hostSelectionPane: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s2) {
            HStack(spacing: ApexStyle.s2) {
                Text("目标主机")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(ApexStyle.primary)
                Text("\(selectedSessionIDs.count)/\(availableSessions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(ApexStyle.secondary)
                Spacer()
                ApexActionButton("全选", icon: "checkmark.circle", tint: ApexStyle.accent, size: .small) {
                    selectedSessionIDs.formUnion(filteredSessions.map(\.id))
                }
                .disabled(filteredSessions.isEmpty || manager.isRunning)

                ApexActionButton("清空", icon: "circle", tint: ApexStyle.secondary, size: .small) {
                    selectedSessionIDs.subtract(filteredSessions.map(\.id))
                }
                .disabled(selectedSessionIDs.isEmpty || manager.isRunning)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(ApexStyle.secondary)
                TextField("筛选主机名、IP 或标签", text: $hostSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !hostSearchText.isEmpty {
                    ApexIconButton(icon: "xmark.circle.fill", label: "清空筛选", size: 16, iconSize: 10) {
                        hostSearchText = ""
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .stroke(ApexStyle.border.opacity(0.6), lineWidth: 0.75)
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ApexPillButton(
                        title: "全部",
                        isSelected: selectedFolders.isEmpty && selectedTags.isEmpty
                    ) {
                        selectedFolders.removeAll()
                        selectedTags.removeAll()
                    }
                    ForEach(folderOptions, id: \.self) { folder in
                        ApexPillButton(
                            title: folder,
                            icon: "folder",
                            isSelected: selectedFolders.contains(folder)
                        ) {
                            if selectedFolders.contains(folder) {
                                selectedFolders.remove(folder)
                            } else {
                                selectedFolders.insert(folder)
                            }
                        }
                    }
                    if !tagOptions.isEmpty {
                        Divider().frame(height: 14)
                        ForEach(tagOptions, id: \.self) { tag in
                            ApexPillButton(
                                title: "#\(tag)",
                                isSelected: selectedTags.contains(tag)
                            ) {
                                if selectedTags.contains(tag) {
                                    selectedTags.remove(tag)
                                } else {
                                    selectedTags.insert(tag)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if filteredSessions.isEmpty {
                VStack(spacing: ApexStyle.s2) {
                    Spacer()
                    Image(systemName: "server.rack")
                        .font(.system(size: 28))
                        .foregroundColor(ApexStyle.secondary.opacity(0.6))
                    Text("没有匹配的远程 SSH 主机")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .apexPanel()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredSessions) { session in
                            hostCheckboxRow(session)
                        }
                    }
                    .padding(6)
                }
                .apexPanel()
            }
        }
        .padding(ApexStyle.s4)
        .background(ApexStyle.surface)
    }

    private func hostCheckboxRow(_ session: Session) -> some View {
        let isSelected = selectedSessionIDs.contains(session.id)
        let state = activeConnectionStates[session.id] ?? .disconnected
        let isProd = Self.isProductionSession(session)

        return Button {
            guard !manager.isRunning else { return }
            if isSelected {
                selectedSessionIDs.remove(session.id)
            } else {
                selectedSessionIDs.insert(session.id)
            }
        } label: {
            HStack(spacing: ApexStyle.s2) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? (isProd ? ApexStyle.error : ApexStyle.accent) : ApexStyle.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(ApexStyle.primary)
                            .lineLimit(1)
                        if isProd {
                            Text("PROD")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(ApexStyle.error)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(ApexStyle.error.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                                .fixedSize()
                        }
                    }
                    Text("\(session.username)@\(session.host):\(session.port)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                connectionBadge(for: state)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .fill(isSelected ? (isProd ? ApexStyle.error.opacity(0.10) : ApexStyle.accent.opacity(0.10)) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .stroke(isSelected && isProd ? ApexStyle.error.opacity(0.45) : Color.clear, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isRunning)
    }

    private func connectionBadge(for state: SSHConnectionState) -> some View {
        let (label, color): (String, Color) = {
            switch state {
            case .connected: return ("已连接", ApexStyle.success)
            case .connecting: return ("连接中", ApexStyle.warning)
            case .failed: return ("异常", ApexStyle.error)
            case .disconnected: return ("独立通道", ApexStyle.secondary)
            }
        }()

        return Text(label)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius))
            .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Right Execution & Results Pane

    private var executionAndResultsPane: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s3) {
            configurationCard
            resultsSection
        }
        .padding(ApexStyle.s4)
        .background(ApexStyle.surface)
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s2) {
            HStack(spacing: ApexStyle.s3) {
                Text(mode == .command ? "待执行命令" : "待分发文件与远端目录")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(ApexStyle.primary)

                Spacer()

                HStack(spacing: 6) {
                    Text("并发主机上限")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                    Stepper(value: $manager.maxConcurrency, in: 1...16) {
                        Text("\(manager.maxConcurrency)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundColor(ApexStyle.primary)
                            .frame(minWidth: 20, alignment: .trailing)
                    }
                    .controlSize(.small)
                    .disabled(manager.isRunning)
                }
            }

            if mode == .command {
                HStack(spacing: ApexStyle.s2) {
                    Menu {
                        ForEach(templateStore.templates) { tpl in
                            Button {
                                applyTemplate(tpl)
                            } label: {
                                Text("[\(tpl.category)] \(tpl.name)")
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.badge.star")
                                .font(.system(size: 10, weight: .semibold))
                            Text(selectedTemplateTitle)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(ApexStyle.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                                .stroke(ApexStyle.border, lineWidth: 0.75)
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(manager.isRunning)

                    ApexActionButton("保存为模板", icon: "square.and.arrow.down", tint: ApexStyle.accent, size: .small) {
                        newTemplateName = ""
                        newTemplateCategory = "自定义"
                        showingSaveTemplateSheet = true
                    }
                    .disabled(commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isRunning)

                    Spacer()

                    if !detectedCommandVariables.isEmpty {
                        ApexActionButton("填写变量 (\(detectedCommandVariables.count))", icon: "slider.horizontal.3", tint: ApexStyle.warning, size: .small) {
                            pendingLaunchAfterVarPrompt = false
                            showingVariablePromptSheet = true
                        }
                        .disabled(manager.isRunning)
                    }
                }

                TextEditor(text: $commandText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 74)
                    .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                            .stroke(ApexStyle.border, lineWidth: 1)
                    )
                    .disabled(manager.isRunning)

                if !detectedCommandVariables.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(detectedCommandVariables, id: \.self) { varName in
                                    HStack(spacing: 4) {
                                        Text("{{\(varName)}}")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundColor(ApexStyle.accent)
                                        TextField(varName, text: Binding(
                                            get: { templateVariables[varName] ?? "" },
                                            set: { templateVariables[varName] = $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(width: 110)
                                    }
                                }
                            }
                        }
                        Text("预览: \(resolvedCommandPreview)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(ApexStyle.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(ApexStyle.subtleSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                }

                HStack(spacing: ApexStyle.s2) {
                    Text("常用:")
                        .font(.caption2)
                        .foregroundColor(ApexStyle.secondary)
                    ForEach(["uname -a", "df -h", "free -m", "uptime"], id: \.self) { preset in
                        ApexPillButton(title: preset, isSelected: commandText == preset) {
                            commandText = preset
                            selectedTemplateID = nil
                        }
                        .disabled(manager.isRunning)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: ApexStyle.s2) {
                    HStack(spacing: ApexStyle.s2) {
                        ApexActionButton("选择文件或目录...", icon: "doc.badge.plus", tint: ApexStyle.accent, size: .small) {
                            chooseLocalFiles()
                        }
                        .disabled(manager.isRunning)

                        if !selectedLocalURLs.isEmpty {
                            ApexActionButton("清空文件", icon: "trash", tint: ApexStyle.secondary, size: .small) {
                                selectedLocalURLs = []
                            }
                            .disabled(manager.isRunning)
                        }

                        Spacer()

                        Text(selectedLocalURLs.isEmpty ? "未选择文件或目录" : "已选 \(selectedLocalURLs.count) 项")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(ApexStyle.secondary)
                    }

                    if !selectedLocalURLs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(selectedLocalURLs, id: \.path) { url in
                                    let isDir = Self.isDirectoryURL(url)
                                    HStack(spacing: 4) {
                                        Image(systemName: isDir ? "folder.fill" : "doc.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(isDir ? ApexStyle.warning : ApexStyle.accent)
                                        Text(url.lastPathComponent)
                                            .font(.caption)
                                            .foregroundColor(ApexStyle.primary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: ApexStyle.badgeRadius)
                                            .stroke(ApexStyle.border.opacity(0.6), lineWidth: 0.75)
                                    )
                                }
                            }
                        }
                    }

                    HStack(spacing: ApexStyle.s2) {
                        Text("目标远端目录")
                            .font(.caption)
                            .foregroundColor(ApexStyle.secondary)
                            .frame(width: 84, alignment: .leading)
                        TextField("例如 /tmp 或 ~/deploy", text: $remoteDirectory)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .disabled(manager.isRunning)
                    }

                    Toggle("上传前自动创建远端目录 (mkdir -p)", isOn: $createRemoteDirectory)
                        .font(.caption)
                        .disabled(manager.isRunning)
                }
            }

            HStack(spacing: ApexStyle.s2) {
                if manager.isRunning {
                    ApexActionButton("取消执行", icon: "stop.circle.fill", tint: ApexStyle.error, size: .regular, isProminent: true) {
                        manager.cancelCurrentBatch()
                    }
                } else {
                    ApexActionButton(
                        mode == .command ? "批量执行 (\(selectedSessions.count))" : "开始分发 (\(selectedSessions.count))",
                        icon: mode == .command ? "play.fill" : "paperplane.fill",
                        tint: ApexStyle.accent,
                        size: .regular,
                        isProminent: true
                    ) {
                        startBatch()
                    }
                    .disabled(!canStartBatch)
                }

                if manager.hasFailedHosts && !manager.isRunning {
                    ApexActionButton(
                        "重试失败主机 (\(manager.failedCount))",
                        icon: "arrow.clockwise",
                        tint: ApexStyle.warning,
                        size: .regular
                    ) {
                        manager.startRetryFailedHosts()
                    }
                }

                Spacer()

                if let toast = toastMessage {
                    HStack(spacing: 4) {
                        Image(systemName: toastIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption)
                        Text(toast)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundColor(toastIsError ? ApexStyle.error : ApexStyle.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((toastIsError ? ApexStyle.error : ApexStyle.success).opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(ApexStyle.s3)
        .apexPanel()
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s2) {
            HStack(spacing: ApexStyle.s2) {
                Text("执行结果")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(ApexStyle.primary)

                if manager.totalCount > 0 {
                    Text("成功 \(manager.succeededCount) · 失败 \(manager.failedCount) · 取消 \(manager.cancelledCount) / 共 \(manager.totalCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(ApexStyle.secondary)
                }

                Spacer()

                if !manager.results.isEmpty {
                    Picker("筛选", selection: $resultFilter) {
                        ForEach(ResultFilter.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)

                    ProgressView(value: manager.overallProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                }
            }

            if manager.results.isEmpty {
                VStack(spacing: ApexStyle.s2) {
                    Spacer()
                    Image(systemName: "terminal")
                        .font(.system(size: 30))
                        .foregroundColor(ApexStyle.secondary.opacity(0.5))
                    Text("在左侧勾选目标主机并点击执行后，各主机的实时状态与输出将显示在此处")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .apexPanel()
            } else if filteredResults.isEmpty {
                VStack(spacing: ApexStyle.s2) {
                    Spacer()
                    Text("当前筛选条件下暂无主机结果")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .apexPanel()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredResults) { item in
                            resultRowCard(item)
                        }
                    }
                    .padding(8)
                }
                .apexPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRowCard(_ item: BatchHostResult) -> some View {
        let isExpanded = expandedResultIDs.contains(item.id)
        let hasOutput = !item.stdout.isEmpty || !item.stderr.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: ApexStyle.s2) {
                statusBadge(for: item.status)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.hostName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(ApexStyle.primary)
                        .lineLimit(1)
                    Text(item.hostAddress)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if item.status == .running {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 72)
                }

                if let exitCode = item.exitCode {
                    Text("exit \(exitCode)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(exitCode == 0 ? ApexStyle.success : ApexStyle.error)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((exitCode == 0 ? ApexStyle.success : ApexStyle.error).opacity(0.12), in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius))
                }

                if let ms = item.durationMs {
                    Text(String(format: "%.0f ms", ms))
                        .font(.system(size: 10.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(ApexStyle.secondary)
                }

                if hasOutput {
                    ApexIconButton(
                        icon: "doc.on.doc",
                        label: "复制主机输出",
                        size: 22,
                        iconSize: 10
                    ) {
                        copyHostOutput(item)
                    }

                    ApexIconButton(
                        icon: isExpanded ? "chevron.up" : "chevron.down",
                        label: isExpanded ? "收起输出" : "展开输出",
                        size: 22,
                        iconSize: 10
                    ) {
                        if isExpanded {
                            expandedResultIDs.remove(item.id)
                        } else {
                            expandedResultIDs.insert(item.id)
                        }
                    }
                }
            }

            if isExpanded && hasOutput {
                VStack(alignment: .leading, spacing: 6) {
                    if !item.stdout.isEmpty {
                        outputBlock(title: "STDOUT", text: item.stdout, tint: ApexStyle.primary)
                    }
                    if !item.stderr.isEmpty {
                        outputBlock(title: "STDERR", text: item.stderr, tint: ApexStyle.error)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(ApexStyle.surface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                .stroke(ApexStyle.border.opacity(0.6), lineWidth: 0.75)
        )
    }

    private static let previewCharacterLimit = 16_384

    private func outputBlock(title: String, text: String, tint: Color) -> some View {
        let previewText: String = {
            if text.count > Self.previewCharacterLimit {
                return String(text.prefix(Self.previewCharacterLimit)) + "\n... [预览已截断，完整内容可通过复制或导出获取]"
            }
            return text
        }()

        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(ApexStyle.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(previewText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(tint)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius))
        }
    }

    private func statusBadge(for status: BatchHostStatus) -> some View {
        let (icon, label, color): (String, String, Color) = {
            switch status {
            case .pending: return ("clock", "等待", ApexStyle.secondary)
            case .running: return ("arrow.triangle.2.circlepath", "执行中", ApexStyle.accent)
            case .succeeded: return ("checkmark.circle.fill", "成功", ApexStyle.success)
            case .failed: return ("xmark.octagon.fill", "失败", ApexStyle.error)
            case .cancelled: return ("slash.circle", "已取消", ApexStyle.warning)
            }
        }()

        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius))
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: ApexStyle.s2) {
            ApexActionButton("导出 CSV", icon: "tablecells", tint: ApexStyle.secondary, size: .small) {
                exportReport(content: manager.exportResultsCSV(), defaultName: "batch-results.csv", contentType: .commaSeparatedText)
            }
            .disabled(manager.results.isEmpty)

            ApexActionButton("导出 Markdown", icon: "doc.richtext", tint: ApexStyle.secondary, size: .small) {
                exportReport(content: manager.exportResultsMarkdown(), defaultName: "batch-results.md", contentType: .plainText)
            }
            .disabled(manager.results.isEmpty)

            ApexActionButton("复制 Markdown", icon: "doc.on.doc", tint: ApexStyle.secondary, size: .small) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(manager.exportResultsMarkdown(), forType: .string)
                showToast("已复制 Markdown 报告")
            }
            .disabled(manager.results.isEmpty)

            Spacer()

            ApexActionButton("关闭", tint: ApexStyle.secondary, size: .regular) {
                requestClose()
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, ApexStyle.s3)
        .background(ApexStyle.surface)
    }

    // MARK: - Helpers

    private func requestClose() {
        if manager.isRunning {
            showCloseConfirmation = true
        } else {
            dismiss()
        }
    }

    private var selectedTemplateTitle: String {
        if let id = selectedTemplateID,
           let found = templateStore.templates.first(where: { $0.id == id }) {
            return "模板: \(found.name)"
        }
        return "选择命令模板"
    }

    private func applyTemplate(_ template: BatchCommandTemplate) {
        selectedTemplateID = template.id
        commandText = template.command
        for name in template.extractVariables() where templateVariables[name] == nil {
            templateVariables[name] = ""
        }
    }

    private var saveTemplateSheet: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s3) {
            Text("保存批量命令模板")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("模板名称")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                TextField("例如：Nginx 配置校验与重载", text: $newTemplateName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("分类")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                TextField("例如：服务 / 巡检 / 自定义", text: $newTemplateCategory)
                    .textFieldStyle(.roundedBorder)
            }
            Text("命令内容: \(commandText)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ApexStyle.secondary)
                .lineLimit(3)
            HStack {
                Spacer()
                ApexActionButton("取消", tint: ApexStyle.secondary, size: .regular) {
                    showingSaveTemplateSheet = false
                }
                ApexActionButton("保存", icon: "checkmark", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    let saved = templateStore.addTemplate(
                        name: newTemplateName,
                        command: commandText,
                        category: newTemplateCategory
                    )
                    selectedTemplateID = saved.id
                    showingSaveTemplateSheet = false
                    showToast("已保存模板「\(saved.name)」")
                }
                .disabled(newTemplateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(ApexStyle.s4)
        .frame(width: 400)
    }

    private var variablePromptSheet: some View {
        let vars = detectedCommandVariables
        return VStack(alignment: .leading, spacing: ApexStyle.s3) {
            Text("填写命令模板变量")
                .font(.headline)
            ForEach(vars, id: \.self) { varName in
                VStack(alignment: .leading, spacing: 4) {
                    Text("{{\(varName)}}")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(ApexStyle.accent)
                    TextField("请输入 \(varName)", text: Binding(
                        get: { templateVariables[varName] ?? "" },
                        set: { templateVariables[varName] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("插值预览")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                Text(resolvedCommandPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
            }
            HStack {
                Spacer()
                ApexActionButton("取消", tint: ApexStyle.secondary, size: .regular) {
                    showingVariablePromptSheet = false
                    pendingLaunchAfterVarPrompt = false
                }
                ApexActionButton(pendingLaunchAfterVarPrompt ? "确认并继续" : "确定", icon: "checkmark", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    let shouldRun = pendingLaunchAfterVarPrompt
                    showingVariablePromptSheet = false
                    pendingLaunchAfterVarPrompt = false
                    if shouldRun {
                        startBatchAfterVariableCheck()
                    }
                }
                .disabled(vars.contains { (templateVariables[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
        .padding(ApexStyle.s4)
        .frame(width: 440)
    }

    private static func isDirectoryURL(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func startBatch() {
        if mode == .command {
            let missingVars = detectedCommandVariables.filter {
                (templateVariables[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if !missingVars.isEmpty {
                pendingLaunchAfterVarPrompt = true
                showingVariablePromptSheet = true
                return
            }
        }
        startBatchAfterVariableCheck()
    }

    private func startBatchAfterVariableCheck() {
        if !selectedProductionSessions.isEmpty {
            showProdConfirmation = true
            return
        }
        executeBatchNow()
    }

    private func executeBatchNow() {
        expandedResultIDs.removeAll()
        switch mode {
        case .command:
            let finalCmd = resolvedCommandPreview
            manager.startBatchCommand(finalCmd, on: selectedSessions)
        case .fileDistribution:
            manager.startBatchFileDistribution(
                selectedLocalURLs,
                toRemoteDirectory: remoteDirectory,
                on: selectedSessions,
                createRemoteDirectory: createRemoteDirectory
            )
        }
    }

    private func chooseLocalFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "选择文件或目录"
        if panel.runModal() == .OK {
            for url in panel.urls {
                try? FileAccessStore.shared.remember(url, readOnly: true)
            }
            selectedLocalURLs = panel.urls
        }
    }

    private func copyHostOutput(_ item: BatchHostResult) {
        var sections: [String] = []
        if !item.stdout.isEmpty {
            sections.append(item.stdout)
        }
        if !item.stderr.isEmpty {
            sections.append("[STDERR]\n\(item.stderr)")
        }
        let combined = sections.joined(separator: "\n")
        guard !combined.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
        showToast("已复制 \(item.hostName) 的执行输出")
    }

    private func exportReport(content: String, defaultName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [contentType]
        panel.prompt = "导出报告"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                showToast("已保存 \(url.lastPathComponent)")
            } catch {
                showToast("导出失败: \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastIsError = isError
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toastMessage == message {
                toastMessage = nil
                toastIsError = false
            }
        }
    }
}
