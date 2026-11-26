import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ApexCore
import ApexSSH

/// Multi-host batch command execution & file distribution sheet.
public struct BatchOperationsSheet: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject public var manager: BatchOperationsManager
    @Environment(\.dismiss) private var dismiss

    public let availableSessions: [Session]
    public let initialSelectedIDs: Set<UUID>
    public let initialFolder: String?
    public let activeConnectionStates: [UUID: SSHConnectionState]

    @State private var selectedSessionIDs: Set<UUID>
    @State private var folderFilter: String = "全部"
    @State private var hostSearchText: String = ""
    @State private var mode: BatchOperationMode = .command
    @State private var commandText: String = "uname -a && uptime"
    @State private var selectedLocalURLs: [URL] = []
    @State private var remoteDirectory: String = "/tmp"
    @State private var expandedResultIDs: Set<UUID> = []
    @State private var toastMessage: String?

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
        } else {
            initialSelection = []
        }

        self._selectedSessionIDs = State(initialValue: initialSelection)
        if let targetFolder = initialFolder?.trimmingCharacters(in: .whitespacesAndNewlines),
           !targetFolder.isEmpty,
           remotes.contains(where: { SidebarView.normalizedFolder(of: $0) == targetFolder }) {
            self._folderFilter = State(initialValue: targetFolder)
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
        ["全部"] + SidebarView.folderNames(sessions: availableSessions, extraFolders: [], searchFilter: "")
    }

    private var filteredSessions: [Session] {
        availableSessions.filter { session in
            let matchesFolder = folderFilter == "全部" || SidebarView.normalizedFolder(of: session) == folderFilter
            let matchesQuery = hostSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || SidebarView.matchesSearch(session, filter: hostSearchText)
            return matchesFolder && matchesQuery
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
                dismiss()
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
                    ForEach(folderOptions, id: \.self) { folder in
                        ApexPillButton(
                            title: folder,
                            isSelected: folderFilter == folder
                        ) {
                            folderFilter = folder
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
                    .foregroundColor(isSelected ? ApexStyle.accent : ApexStyle.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ApexStyle.primary)
                        .lineLimit(1)
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
                    .fill(isSelected ? ApexStyle.accent.opacity(0.10) : Color.clear)
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
                TextEditor(text: $commandText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 82)
                    .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                            .stroke(ApexStyle.border, lineWidth: 1)
                    )
                    .disabled(manager.isRunning)

                HStack(spacing: ApexStyle.s2) {
                    Text("常用:")
                        .font(.caption2)
                        .foregroundColor(ApexStyle.secondary)
                    ForEach(["uname -a", "df -h", "free -m", "uptime"], id: \.self) { preset in
                        ApexPillButton(title: preset, isSelected: commandText == preset) {
                            commandText = preset
                        }
                        .disabled(manager.isRunning)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: ApexStyle.s2) {
                    HStack(spacing: ApexStyle.s2) {
                        ApexActionButton("选择本地文件...", icon: "doc.badge.plus", tint: ApexStyle.accent, size: .small) {
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

                        Text(selectedLocalURLs.isEmpty ? "未选择文件" : "已选 \(selectedLocalURLs.count) 个文件")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(ApexStyle.secondary)
                    }

                    if !selectedLocalURLs.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(selectedLocalURLs, id: \.path) { url in
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(ApexStyle.accent)
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
                    Text(toast)
                        .font(.caption)
                        .foregroundColor(ApexStyle.success)
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
                    ProgressView(value: manager.overallProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
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
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(manager.results) { item in
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

    private func outputBlock(title: String, text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(ApexStyle.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(text)
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
                dismiss()
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, ApexStyle.s3)
        .background(ApexStyle.surface)
    }

    // MARK: - Helpers

    private func startBatch() {
        expandedResultIDs.removeAll()
        switch mode {
        case .command:
            manager.startBatchCommand(commandText, on: selectedSessions)
        case .fileDistribution:
            manager.startBatchFileDistribution(selectedLocalURLs, toRemoteDirectory: remoteDirectory, on: selectedSessions)
        }
    }

    private func chooseLocalFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "选择分发文件"
        if panel.runModal() == .OK {
            selectedLocalURLs = panel.urls
        }
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
                showToast("导出失败: \(error.localizedDescription)")
            }
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
}
