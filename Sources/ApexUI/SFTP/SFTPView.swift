import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ApexCore
import ApexSSH

private final class SFTPBatchTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    let total: Int
    init(total: Int) { self.total = total }
    func advance() -> (completed: Int, isDone: Bool) {
        lock.lock()
        defer { lock.unlock() }
        completed += 1
        return (completed, completed >= total)
    }
}

/// High-performance integrated SFTP file manager (electerm-style with OSC 7 sync and drag-and-drop upload/download)
public struct SFTPView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Binding public var currentPath: String
    @Binding public var isLinkageEnabled: Bool
    public let session: SSHSessionProtocol?

    public enum SFTPSortField: String, CaseIterable, Sendable {
        case name
        case size
        case date
    }

    public enum SFTPSortOrder: String, CaseIterable, Sendable {
        case ascending
        case descending
    }

    @State private var items: [SFTPItem] = []
    @State private var isLoading = false
    @State private var selectedPaths: Set<String> = []
    @State private var batchItemsToDelete: [SFTPItem]? = nil
    @State private var searchFilter = ""
    @State private var tableSortOrder = [KeyPathComparator(\SFTPItem.name)]
    @State private var displayItems: [SFTPItem] = []
    @State private var isFilterVisible = false
    @State private var pathInput = ""
    @State private var windowReference = WindowReference()
    @FocusState private var isPathFocused: Bool
    @FocusState private var isFilterFocused: Bool
    @State private var editingFile: SFTPItem?
    @State private var editorContent = ""
    @State private var isDropTargeted = false
    @State private var transferNotice: String?
    @State private var creationFailureDetails: String?
    @State private var creationFailureNotice: String?
    @State private var isShowingCreationFailure = false
    @State private var loadError: String?
    @State private var isOpeningEditor = false
    @State private var isTransferDrawerExpanded = false
    @State private var loadTask: Task<Void, Never>?
    
    // Sort and visibility
    @State private var showHiddenFiles = false
    
    // File operations state
    @State private var itemToDelete: SFTPItem?
    @State private var itemToRename: SFTPItem?
    @State private var renameText = ""
    @State private var isShowingRenameAlert = false
    @State private var itemToChmod: SFTPItem?
    @State private var chmodText = "755"
    @State private var isShowingChmodAlert = false
    @State private var newFolderName = ""
    @State private var isShowingNewFolderAlert = false
    @State private var newFileName = ""
    @State private var isShowingNewFileAlert = false

    public init(
        currentPath: Binding<String>,
        isLinkageEnabled: Binding<Bool> = .constant(true),
        session: SSHSessionProtocol?
    ) {
        self._currentPath = currentPath
        self._isLinkageEnabled = isLinkageEnabled
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Path and action toolbar
            HStack(spacing: 10) {
                // Folder icon & Path breadcrumbs
                Button {
                    pathInput = currentPath
                    isPathFocused = true
                } label: {
                    Label("前往文件夹", systemImage: "folder.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut("l", modifiers: .command)
                .help("前往文件夹 (⌘L)")

                TextField(L10n.remotePath, text: $pathInput)
                .onSubmit {
                    let target = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !target.isEmpty else { pathInput = currentPath; return }
                    pathInput = target
                    if target != currentPath { currentPath = target }
                }
                .focused($isPathFocused)
                .onExitCommand { pathInput = currentPath; isPathFocused = false }
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

                Button("复制当前路径", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentPath, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("复制当前浏览目录的路径")
                .disabled(currentPath.isEmpty)

                Toggle(isOn: $isLinkageEnabled) {
                    Label(isLinkageEnabled ? L10n.linkageOn : L10n.linkageOff,
                          systemImage: isLinkageEnabled ? "link" : "link.slash")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(isLinkageEnabled ? L10n.linkageHelpOn : L10n.linkageHelpOff)


                Divider().frame(height: 16)

                // Actions
                Button(action: navigateUp) {
                    Label(L10n.parentDirectory, systemImage: "arrow.up")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.parentDirectory)

                Button(action: {
                    loadDirectory(path: currentPath)
                }) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    } else {
                        Label(L10n.refreshDirectory, systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.refreshDirectory)

                Button(action: {
                    uploadAction()
                }) {
                    Label(L10n.uploadFile, systemImage: "arrow.up.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    Button("新建文件夹", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        isShowingNewFolderAlert = true
                    }
                    Button("新建文件", systemImage: "doc.badge.plus") {
                        newFileName = ""
                        isShowingNewFileAlert = true
                    }
                    Toggle("显示隐藏文件", isOn: $showHiddenFiles)
                } label: {
                    Label("更多文件操作", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
                .help("新建文件、文件夹及隐藏文件")

                Toggle(isOn: $isFilterVisible) {
                    Label("筛选文件", systemImage: "line.3.horizontal.decrease")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("筛选当前文件夹")

                Button("") { showHiddenFiles.toggle() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .frame(width: 0, height: 0)
                    .opacity(0)

                // Transfer records drawer toggle button
                TransferToolbarButton(isExpanded: $isTransferDrawerExpanded)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ApexStyle.surface)

            Divider()

            HStack {
                if let notice = transferNotice {
                    Button(action: {
                        if creationFailureNotice == notice, creationFailureDetails != nil {
                            isShowingCreationFailure = true
                        } else {
                            withAnimation(.spring(duration: 0.25)) {
                                isTransferDrawerExpanded = true
                            }
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: notice.contains("失败") ? "exclamationmark.triangle.fill" : (notice.contains("正在") ? "arrow.up.circle" : "checkmark.circle.fill"))
                                .foregroundColor(notice.contains("失败") ? ApexStyle.error : (notice.contains("正在") ? ApexStyle.accent : ApexStyle.success))
                                .font(.system(size: 11))
                            Text(notice)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(notice.contains("失败") ? ApexStyle.error : (notice.contains("正在") ? ApexStyle.accent : ApexStyle.success))

                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundColor(ApexStyle.secondary)

                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            notice.contains("失败") ? ApexStyle.error.opacity(0.12) : (notice.contains("正在") ? ApexStyle.accent.opacity(0.12) : ApexStyle.success.opacity(0.12)),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(creationFailureNotice == notice ? "点击查看创建失败原因与完整远端错误" : "点击打开传输任务记录抽屉")
                    .transition(.opacity)
                    if notice.contains("失败") {
                        Button(action: { transferNotice = nil }) {
                            Label("关闭传输提示", systemImage: "xmark.circle")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)

            // Search filter bar
            if isFilterVisible || !searchFilter.isEmpty {
            HStack {
                TextField(L10n.filterFiles, text: $searchFilter)
                    .focused($isFilterFocused)
                    .onExitCommand {
                        // Restore table focus after SwiftUI removes the search field.
                        isFilterFocused = false
                        isFilterVisible = false
                        searchFilter = ""
                        Task { @MainActor in
                            await Task.yield()
                            guard let window = windowReference.window else { return }
                            @MainActor func fileTable(in view: NSView) -> NSTableView? {
                                if let table = view as? NSTableView, table.tableColumns.count == 4 { return table }
                                for child in view.subviews {
                                    if let table = fileTable(in: child) { return table }
                                }
                                return nil
                            }
                            if let content = window.contentView, let table = fileTable(in: content) {
                                window.makeFirstResponder(table)
                            }
                        }
                    }
                    .task {
                        await Task.yield()
                        if isFilterVisible { isFilterFocused = true }
                    }
                    .textFieldStyle(.roundedBorder)
                if !searchFilter.isEmpty {
                    Button(action: { searchFilter = "" }) {
                        Label("清除文件筛选", systemImage: "xmark.circle.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(ApexStyle.subtleSurface)

            Divider()

            }
            // Files table with Drag & Drop upload & download
            ZStack {
                if items.isEmpty && isLoading {
                    VStack {
                        Spacer()
                        ProgressView(L10n.loadingFiles)
                            .font(.caption)
                        Spacer()
                    }
                } else if let loadError {
                    ContentUnavailableView {
                        Label("无法读取远程文件", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError).lineLimit(2)
                    } actions: {
                        Button("重试") { loadDirectory(path: currentPath) }
                    }
                } else if filteredItems.isEmpty {
                    ContentUnavailableView(
                        searchFilter.isEmpty ? "文件夹为空" : "没有匹配的文件",
                        systemImage: searchFilter.isEmpty ? "folder" : "magnifyingglass"
                    )
                } else {
                    Table(of: SFTPItem.self, selection: $selectedPaths, sortOrder: $tableSortOrder) {
                        TableColumn("名称", value: \.name) { item in
                            HStack {
                                Image(systemName: fileIcon(for: item)).foregroundStyle(selectedPaths.contains(item.path) ? Color.primary : fileColor(for: item))
                                Text(item.name).lineLimit(1)
                            }.help(item.path)
                        }
                        .width(min: 160, ideal: 280)
                        TableColumn("权限") { item in
                            Text(item.permissionString).font(.caption.monospaced())
                        }.width(min: 75, ideal: 90, max: 120)
                        TableColumn("大小", value: \.size) { item in
                            Text(item.formattedSize).font(.caption.monospacedDigit())
                        }.width(min: 65, ideal: 85, max: 120)
                        TableColumn("修改时间", value: \.modificationDate) { item in
                            Text(formatDate(item.modificationDate)).font(.caption.monospacedDigit())
                        }.width(min: 125, ideal: 145, max: 180)
                    } rows: {
                        ForEach(filteredItems) { item in
                            TableRow(item).itemProvider { handleDragDownload(for: item) }
                        }
                    }
                    // Keep the system's semantic selection foreground instead of inheriting a theme's fixed text color.
                    .foregroundStyle(Color.primary)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if ids.count == 1, let path = ids.first, let item = items.first(where: { $0.path == path }) {
                            fileContextActions(item)
                        } else if ids.count > 1 {
                            batchContextActions(for: ids)
                        }
                    } primaryAction: { ids in
                        if let path = ids.first, let item = items.first(where: { $0.path == path }) {
                            handleDoubleClick(item)
                        }
                    }
                    .contextMenu {
                        Button("新建文件夹") {
                            newFolderName = ""
                            isShowingNewFolderAlert = true
                        }
                        Button("新建文件") {
                            newFileName = ""
                            isShowingNewFileAlert = true
                        }
                        Divider()
                        Button("修改当前目录权限 (chmod)...") {
                            itemToChmod = nil
                            chmodText = "755"
                            isShowingChmodAlert = true
                        }
                        Divider()
                        Button(action: { showHiddenFiles.toggle() }) {
                            Label(showHiddenFiles ? "隐藏点文件 (⌘⇧.)" : "显示点文件 (⌘⇧.)", systemImage: showHiddenFiles ? "eye.fill" : "eye.slash")
                        }
                        Button(action: { loadDirectory(path: currentPath) }) {
                            Label("刷新目录", systemImage: "arrow.clockwise")
                        }
                    }
                    .opacity(isLoading ? 0.65 : 1.0)
                }

                // Visual overlay when dragging local file into SFTP panel
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ApexStyle.accent, lineWidth: 3)
                        .background(ApexStyle.accent.opacity(0.12))
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(ApexStyle.accent)
                                Text("松开鼠标上传至当前目录 (\(currentPath))")
                                    .font(.headline)
                                    .foregroundColor(ApexStyle.accent)
                            }
                        )
                        .allowsHitTesting(false)
                }
                if isOpeningEditor {
                    ProgressView("正在读取远程文件…")
                        .padding(18)
                        .apexPanel()
                }


            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDropUpload(providers: providers)
                return true
            }
        }
        .background(WindowReferenceView(reference: windowReference).frame(width: 0, height: 0))
        .alert("创建失败", isPresented: $isShowingCreationFailure) {
            Button("好", role: .cancel) {}
        } message: {
            Text(creationFailureDetails ?? "")
        }
        .sheet(isPresented: $isTransferDrawerExpanded) {
            TransferDrawer(isExpanded: $isTransferDrawerExpanded)
                .frame(width: 700, height: 360)
                .apexTheme()
        }
        .onChange(of: isFilterVisible) { _, visible in
            if !visible { isFilterFocused = false; searchFilter = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerSFTPFind"))) { _ in
            guard let window = windowReference.window, window === NSApp.keyWindow else { return }
            let tableHasFocus = (window.firstResponder as? NSTableView)?.tableColumns.count == 4
            guard isPathFocused || isFilterFocused || tableHasFocus else { return }
            let alreadyVisible = isFilterVisible
            isPathFocused = false
            isFilterVisible = true
            if alreadyVisible { isFilterFocused = true }
        }
        .onChange(of: items) { _, _ in updateDisplayItems() }
        .onChange(of: searchFilter) { _, _ in updateDisplayItems() }
        .onChange(of: showHiddenFiles) { _, _ in updateDisplayItems() }
        .onChange(of: tableSortOrder) { _, _ in updateDisplayItems() }
        .onDisappear { loadTask?.cancel() }
        .onAppear {
            pathInput = currentPath
            updateDisplayItems()
            loadDirectory(path: currentPath)
        }
        .onChange(of: currentPath) { oldPath, newPath in
            // Focus alone is not an edit: follow directory changes until a draft differs.
            if !isPathFocused || pathInput == oldPath { pathInput = newPath }
            loadDirectory(path: newPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SFTPDirectoryRefreshNeeded"))) { notification in
            if let path = notification.object as? String, !path.isEmpty {
                let parent = (path as NSString).deletingLastPathComponent
                let normalizedPath = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
                let normalizedCurrent = currentPath.hasSuffix("/") && currentPath.count > 1 ? String(currentPath.dropLast()) : currentPath
                let normalizedParent = parent.hasSuffix("/") && parent.count > 1 ? String(parent.dropLast()) : parent
                guard normalizedPath == normalizedCurrent || normalizedParent == normalizedCurrent || path == "~" else { return }
            }
            loadDirectory(path: currentPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isLinkageEnabled {
                loadDirectory(path: currentPath)
            }
        }
        .sheet(item: $editingFile) { item in
            QuickEditorView(
                item: item,
                content: $editorContent,
                onSave: { newContent in
                    try await saveEditedFileAsync(item, content: newContent)
                },
                onReload: {
                    try await reloadFileContentAsync(item)
                }
            )
        }
        .confirmationDialog(
            "确定删除？",
            isPresented: Binding(
                get: { itemToDelete != nil },
                set: { if !$0 { itemToDelete = nil } }
            ),
            presenting: itemToDelete
        ) { item in
            Button("永久删除「\(item.name)」", role: .destructive) {
                performDelete(item)
            }
            Button("取消", role: .cancel) {
                itemToDelete = nil
            }
        } message: { item in
            Text("将从远程服务器永久删除「\(item.name)」\(item.isDirectory ? "及其内部所有文件" : "")，此操作不可撤销。")
        }
        .confirmationDialog(
            "确定批量删除？",
            isPresented: Binding(
                get: { batchItemsToDelete != nil },
                set: { if !$0 { batchItemsToDelete = nil } }
            ),
            presenting: batchItemsToDelete
        ) { targetItems in
            Button("永久删除选中的 \(targetItems.count) 个项目", role: .destructive) {
                performBatchDelete(targetItems)
            }
            Button("取消", role: .cancel) {
                batchItemsToDelete = nil
            }
        } message: { targetItems in
            Text("将从远程服务器永久删除选中的 \(targetItems.count) 个项目及其内部所有内容，此操作不可撤销。")
        }
        .alert("新建文件夹", isPresented: $isShowingNewFolderAlert) {
            TextField("文件夹名称", text: $newFolderName)
                .autocorrectionDisabled()
            Button("创建") {
                performCreateFolder(name: newFolderName)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在当前目录 (\(currentPath)) 下创建新文件夹")
        }
        .alert("新建空白文件", isPresented: $isShowingNewFileAlert) {
            TextField("文件名 (例如 test.sh)", text: $newFileName)
                .autocorrectionDisabled()
            Button("创建") {
                performCreateFile(name: newFileName)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在当前目录 (\(currentPath)) 下创建空白文件")
        }
        .alert("重命名", isPresented: $isShowingRenameAlert) {
            TextField("新名称", text: $renameText)
                .autocorrectionDisabled()
            Button("确定") {
                if let item = itemToRename {
                    performRename(item: item, newName: renameText)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入「\(itemToRename?.name ?? "")」的新名称")
        }
        .alert("修改权限 (chmod)", isPresented: $isShowingChmodAlert) {
            TextField("权限代码 (如 755, 644, 777)", text: $chmodText)
            Button("确定") {
                let target = itemToChmod?.path ?? currentPath
                performChmod(targetPath: target, mode: chmodText)
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let item = itemToChmod {
                Text("修改「\(item.name)」的访问权限（例如：文件夹推荐 755，普通文件推荐 644）")
            } else {
                Text("修改当前目录 (\(currentPath)) 的访问权限（推荐 755 赋予读写与遍历权限）")
            }
        }
    }

    private var filteredItems: [SFTPItem] { displayItems }

    private func updateDisplayItems() {
        displayItems = items.filter {
            (showHiddenFiles || !$0.name.hasPrefix(".") || $0.name == "..") &&
            (searchFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(searchFilter))
        }.sorted { a, b in
            if a.name == ".." || b.name == ".." { return a.name == ".." && b.name != ".." }
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            for comparator in tableSortOrder {
                let result = comparator.compare(a, b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func fileContextActions(_ item: SFTPItem) -> some View {
        Button(L10n.downloadToDownloads) {
            selectedPaths = [item.path]
            downloadAction(item)
        }
        if !item.isDirectory {
            Button(L10n.quickViewEdit) {
                selectedPaths = [item.path]
                openEditor(item)
            }
        }
        Divider()
        Button("重命名...") {
            selectedPaths = [item.path]
            itemToRename = item
            renameText = item.name
            isShowingRenameAlert = true
        }
        Button("修改权限 (chmod)...") {
            selectedPaths = [item.path]
            itemToChmod = item
            chmodText = item.isDirectory ? "755" : "644"
            isShowingChmodAlert = true
        }
        Button(role: .destructive) {
            selectedPaths = [item.path]
            itemToDelete = item
        } label: {
            Label("删除", systemImage: "trash")
        }
        Divider()
        Button(L10n.copyRemotePath) {
            selectedPaths = [item.path]
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        }
    }

    @ViewBuilder
    private func batchContextActions(for ids: Set<String>) -> some View {
        let selectedItems = items.filter { ids.contains($0.path) }
        Button("下载选中的 \(selectedItems.count) 个项目到「下载」") {
            downloadBatchAction(selectedItems)
        }
        Divider()
        Button(role: .destructive) {
            batchItemsToDelete = selectedItems
        } label: {
            Label("删除选中的 \(selectedItems.count) 个项目", systemImage: "trash")
        }
        Divider()
        Button("复制所有选中远程路径") {
            let joined = selectedItems.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
        }
    }

    private func downloadBatchAction(_ targetItems: [SFTPItem]) {
        guard let s = session, !targetItems.isEmpty else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        transferNotice = "正在下载 \(targetItems.count) 个项目…"
        withAnimation(.spring(duration: 0.25)) {
            isTransferDrawerExpanded = true
        }
        let tracker = SFTPBatchTracker(total: targetItems.count)
        for item in targetItems {
            let localURL = TransferManager.shared.availableDownloadURL(in: downloads, fileName: item.name)
            TransferManager.shared.enqueueDownload(
                session: s,
                remotePath: item.path,
                localURL: localURL,
                totalBytes: Int64(item.size),
                onCompleted: {
                    let status = tracker.advance()
                    Task { @MainActor in
                        if status.isDone {
                            self.transferNotice = "批量下载完成 (\(tracker.total) 个文件)"
                        } else {
                            self.transferNotice = "下载完成: \(item.name)"
                        }
                    }
                },
                onResult: { result in
                    Task { @MainActor in
                        switch result {
                        case .success:
                            break
                        case .failure(let error):
                            self.transferNotice = error is CancellationError
                                ? "已取消下载: \(item.name)"
                                : "下载失败: \(error.localizedDescription)"
                            self.isTransferDrawerExpanded = true
                        }
                    }
                }
            )
        }
    }

    private func performBatchDelete(_ targetItems: [SFTPItem]) {
        guard let s = session, !targetItems.isEmpty else { return }
        let pathsToRemove = Set(targetItems.map(\.path))
        withAnimation {
            self.items.removeAll { pathsToRemove.contains($0.path) }
            self.updateDisplayItems()
        }
        Task {
            var failed: [String] = []
            for item in targetItems {
                do {
                    if item.isDirectory {
                        try await s.removeDirectory(remotePath: item.path, recursive: true)
                    } else {
                        try await s.removeFile(remotePath: item.path)
                    }
                } catch {
                    failed.append(item.name)
                }
            }
            await MainActor.run {
                if failed.isEmpty {
                    self.transferNotice = "已成功删除 \(targetItems.count) 个项目"
                } else {
                    self.transferNotice = "部分项目删除失败 (\(failed.joined(separator: ", ")))"
                }
                self.loadDirectory(path: self.currentPath)
            }
        }
    }

    private func performDelete(_ item: SFTPItem) {
        guard let s = session else { return }
        withAnimation {
            self.items.removeAll { $0.path == item.path }
            self.updateDisplayItems()
        }
        Task {
            do {
                if item.isDirectory {
                    try await s.removeDirectory(remotePath: item.path, recursive: true)
                } else {
                    try await s.removeFile(remotePath: item.path)
                }
                await MainActor.run {
                    self.transferNotice = "已删除: \(item.name)"
                    self.loadDirectory(path: self.currentPath)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if self.transferNotice?.hasPrefix("已删除") == true {
                            self.transferNotice = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.transferNotice = "删除失败: \(error.localizedDescription)"
                    self.loadDirectory(path: self.currentPath)
                }
            }
        }
    }
    
    private func showCreationFailure(operation: String, target: String, error: Error) {
        let remoteError = error.localizedDescription
        let reason: String
        if remoteError.localizedCaseInsensitiveContains("Permission denied") {
            reason = "当前用户没有目标文件或目录的写入权限，请联系管理员授权或选择可写目录。"
        } else if remoteError.localizedCaseInsensitiveContains("Read-only file system") {
            reason = "目标文件系统为只读，请选择可写目录。"
        } else {
            reason = remoteError
        }
        let notice = "\(operation)失败：\(reason)"
        creationFailureNotice = notice
        creationFailureDetails = "\(reason)\n\n目标：\(target)\n\n远端错误：\(remoteError)"
        transferNotice = notice
    }

    private func performCreateFolder(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session else { return }
        let target = currentPath.hasSuffix("/") ? "\(currentPath)\(trimmed)" : "\(currentPath)/\(trimmed)"
        Task {
            do {
                try await s.createDirectory(remotePath: target)
                await MainActor.run {
                    self.transferNotice = "已新建文件夹: \(trimmed)"
                    self.loadDirectory(path: self.currentPath)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if self.transferNotice?.hasPrefix("已新建") == true {
                            self.transferNotice = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.showCreationFailure(operation: "新建文件夹", target: target, error: error)
                }
            }
        }
    }
    
    private func performCreateFile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session else { return }
        let target = currentPath.hasSuffix("/") ? "\(currentPath)\(trimmed)" : "\(currentPath)/\(trimmed)"
        Task {
            do {
                try await s.createFile(remotePath: target)
                await MainActor.run {
                    self.transferNotice = "已新建文件: \(trimmed)"
                    self.loadDirectory(path: self.currentPath)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if self.transferNotice?.hasPrefix("已新建") == true {
                            self.transferNotice = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.showCreationFailure(operation: "新建文件", target: target, error: error)
                }
            }
        }
    }
    
    private func performRename(item: SFTPItem, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name, let s = session else { return }
        let parent = (item.path as NSString).deletingLastPathComponent
        let target = parent == "/" ? "/\(trimmed)" : "\(parent)/\(trimmed)"
        Task {
            do {
                try await s.rename(oldPath: item.path, newPath: target)
                await MainActor.run {
                    self.transferNotice = "已重命名为: \(trimmed)"
                    self.loadDirectory(path: self.currentPath)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if self.transferNotice?.hasPrefix("已重命名") == true {
                            self.transferNotice = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.transferNotice = "重命名失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func performChmod(targetPath: String, mode: String) {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session else { return }
        Task {
            do {
                try await s.changePermissions(remotePath: targetPath, permissions: trimmed)
                await MainActor.run {
                    self.transferNotice = "已修改权限为: \(trimmed)"
                    self.loadDirectory(path: self.currentPath)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if self.transferNotice?.hasPrefix("已修改") == true {
                            self.transferNotice = nil
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.transferNotice = "修改权限失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadDirectory(path: String) {
        guard let s = session else { return }
        isLoading = true
        loadError = nil
        selectedPaths = []
        loadTask?.cancel()
        loadTask = Task {
            do {
                let fetched = try await s.listDirectory(path: path)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.items = fetched
                    self.updateDisplayItems()
                    self.isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.items = []
                    self.updateDisplayItems()
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func navigateUp() {
        let p = (currentPath as NSString).deletingLastPathComponent
        currentPath = p.isEmpty ? "/" : p
    }

    private func handleDoubleClick(_ item: SFTPItem) {
        if item.isDirectory {
            currentPath = item.path
        } else if item.isSymlink {
            Task {
                if let s = session, (try? await s.listDirectory(path: item.path)) != nil {
                    await MainActor.run {
                        currentPath = item.path
                    }
                } else {
                    await MainActor.run {
                        openEditor(item)
                    }
                }
            }
        } else {
            openEditor(item)
        }
    }

    private func openEditor(_ item: SFTPItem) {
        guard item.size <= 1_000_000 else {
            transferNotice = "文件超过 1 MB，请先下载后编辑"
            return
        }
        guard let session else { return }
        isOpeningEditor = true
        Task {
            let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: localURL) }
            do {
                try await session.downloadFile(remotePath: item.path, localURL: localURL, progress: { _ in })
                let data = try Data(contentsOf: localURL)
                let text = String(data: data, encoding: .utf8) ??
                           String(data: data, encoding: .windowsCP1252) ??
                           String(data: data, encoding: .isoLatin1) ??
                           String(decoding: data, as: UTF8.self)
                editorContent = text
                editingFile = item
            } catch {
                transferNotice = "读取失败：\(error.localizedDescription)"
            }
            isOpeningEditor = false
        }
    }

    private func saveEditedFileAsync(_ item: SFTPItem, content: String) async throws {
        guard let session else { return }
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: localURL) }
        try content.write(to: localURL, atomically: true, encoding: .utf8)
        try await session.uploadFile(localURL: localURL, remotePath: item.path, progress: { _ in })
        await MainActor.run {
            self.loadDirectory(path: self.currentPath)
        }
    }

    private func reloadFileContentAsync(_ item: SFTPItem) async throws -> String {
        guard let session else { return "" }
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: localURL) }
        try await session.downloadFile(remotePath: item.path, localURL: localURL, progress: { _ in })
        let data = try Data(contentsOf: localURL)
        return String(data: data, encoding: .utf8) ??
               String(data: data, encoding: .windowsCP1252) ??
               String(data: data, encoding: .isoLatin1) ??
               String(decoding: data, as: UTF8.self)
    }

    private func handleUploadResult(_ result: Result<String, Error>, fileName: String, targetDirectory: String) {
        DispatchQueue.main.async {
            switch result {
            case .success:
                self.transferNotice = "上传成功: \(fileName)"
                self.loadDirectory(path: self.currentPath)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.transferNotice?.hasPrefix("上传成功") == true {
                        self.transferNotice = nil
                    }
                }
            case .failure(let error):
                if error is CancellationError {
                    self.transferNotice = "已取消上传: \(fileName)"
                    return
                }
                let desc = error.localizedDescription
                if desc.localizedCaseInsensitiveContains("Permission denied") || desc.contains("dest open") {
                    self.transferNotice = "上传失败：权限不足 (Permission denied)，当前目录无写入权限"
                } else {
                    self.transferNotice = "上传失败: \(desc)"
                }
                self.isTransferDrawerExpanded = true
            }
        }
    }

    private func uploadAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            requestBatchUpload(panel.urls, targetDirectory: currentPath)
        }
    }

    private func requestBatchUpload(_ urls: [URL], targetDirectory: String) {
        guard let session, !urls.isEmpty else { return }
        Task { @MainActor in
            do {
                let existing = try await session.listDirectory(path: targetDirectory)
                let existingNames = Set(existing.map(\.name))
                let conflicts = urls.filter { existingNames.contains($0.lastPathComponent) }
                
                var filesToUpload = urls
                if !conflicts.isEmpty {
                    guard let window = windowReference.window else { return }
                    let alert = NSAlert()
                    alert.messageText = "目标目录已存在同名文件"
                    if conflicts.count == 1 {
                        alert.informativeText = "「\(conflicts[0].lastPathComponent)」已存在于目标目录。替换会覆盖远端内容。"
                        alert.addButton(withTitle: "取消")
                        alert.addButton(withTitle: "替换")
                    } else {
                        alert.informativeText = "检测到 \(conflicts.count) 个同名文件（如「\(conflicts[0].lastPathComponent)」等）。是否覆盖替换？"
                        alert.addButton(withTitle: "取消")
                        alert.addButton(withTitle: "全部替换")
                        alert.addButton(withTitle: "跳过同名文件")
                    }
                    let response = await withCheckedContinuation { continuation in
                        alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                    }
                    if conflicts.count == 1 {
                        guard response == .alertSecondButtonReturn else { return }
                    } else {
                        if response == .alertFirstButtonReturn {
                            return // 取消
                        } else if response == .alertThirdButtonReturn {
                            filesToUpload = urls.filter { !existingNames.contains($0.lastPathComponent) }
                        }
                    }
                }
                
                guard !filesToUpload.isEmpty else { return }
                
                transferNotice = filesToUpload.count == 1
                    ? "正在上传 \(filesToUpload[0].lastPathComponent)…"
                    : "正在批量上传 \(filesToUpload.count) 个文件…"
                withAnimation(.spring(duration: 0.25)) {
                    isTransferDrawerExpanded = true
                }
                
                let tracker = SFTPBatchTracker(total: filesToUpload.count)
                for localURL in filesToUpload {
                    let destination = targetDirectory.hasSuffix("/")
                        ? "\(targetDirectory)\(localURL.lastPathComponent)"
                        : "\(targetDirectory)/\(localURL.lastPathComponent)"
                    
                    TransferManager.shared.enqueueUpload(session: session, localURL: localURL, remotePath: destination, onResult: { result in
                        let status = tracker.advance()
                        Task { @MainActor in
                            switch result {
                            case .success:
                                if status.isDone {
                                    self.transferNotice = tracker.total == 1
                                        ? "上传成功: \(localURL.lastPathComponent)"
                                        : "批量上传完成 (\(tracker.total) 个文件)"
                                    self.loadDirectory(path: self.currentPath)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                        if self.transferNotice?.hasPrefix("上传成功") == true || self.transferNotice?.hasPrefix("批量上传完成") == true {
                                            self.transferNotice = nil
                                        }
                                    }
                                }
                            case .failure(let error):
                                if error is CancellationError {
                                    self.transferNotice = "已取消上传: \(localURL.lastPathComponent)"
                                } else {
                                    self.transferNotice = "上传失败: \(error.localizedDescription)"
                                }
                                self.isTransferDrawerExpanded = true
                            }
                        }
                    })
                }
            } catch {
                transferNotice = "上传失败：\(error.localizedDescription)"
            }
        }
    }


    private func downloadAction(_ item: SFTPItem) {
        guard let s = session else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let localURL = TransferManager.shared.availableDownloadURL(in: downloads, fileName: item.name)
        self.transferNotice = "正在下载: \(item.name)..."
        withAnimation(.spring(duration: 0.25)) {
            self.isTransferDrawerExpanded = true
        }
        TransferManager.shared.enqueueDownload(
            session: s,
            remotePath: item.path,
            localURL: localURL,
            totalBytes: Int64(item.size),
            onCompleted: {
                Task { @MainActor in
                    self.transferNotice = "下载完成: \(item.name)"
                }
            },
            onResult: { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        self.transferNotice = "下载完成: \(item.name)"
                    case .failure(let error):
                        self.transferNotice = error is CancellationError ? "已取消下载: \(item.name)" : "下载失败: \(error.localizedDescription)"
                        self.isTransferDrawerExpanded = true
                    }
                }
            }
        )
    }

    /// Handle local file drop from Finder / Desktop
    private func handleDropUpload(providers: [NSItemProvider]) {
        guard session != nil else { return }
        let targetDirectory = currentPath
        Task {
            var droppedURLs: [URL] = []
            for provider in providers {
                if let url = await loadDroppedURL(from: provider) {
                    droppedURLs.append(url)
                }
            }
            guard !droppedURLs.isEmpty else { return }
            await MainActor.run {
                requestBatchUpload(droppedURLs, targetDirectory: targetDirectory)
            }
        }
    }

    private func loadDroppedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else if let str = item as? String, let url = URL(string: str) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            } else {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
        }
    }

    /// Handle dragging a remote file item to download to Finder / Desktop / Any local directory
    private func handleDragDownload(for item: SFTPItem) -> NSItemProvider {
        SFTPDragExportHelper.makeItemProvider(for: item, session: session) { [self] notice in
            self.transferNotice = notice
        }
    }

    private func fileIcon(for item: SFTPItem) -> String {
        if item.name == ".." { return "arrow.turn.up.left" }
        if item.isDirectory { return "folder.fill" }
        if item.isSymlink { return "arrow.triangle.turn.up.right.diamond.fill" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "log", "txt": return "doc.text.fill"
        case "sh", "bash", "zsh": return "terminal.fill"
        case "conf", "yaml", "yml", "json", "toml", "ini": return "slider.horizontal.3"
        case "tar", "gz", "zip", "bz2": return "doc.zipper"
        case "py", "swift", "rs", "go", "js", "ts", "c", "cpp": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }

    private func fileColor(for item: SFTPItem) -> Color {
        if item.isDirectory { return ApexStyle.accent }
        if item.isSymlink { return .cyan }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh": return ApexStyle.success
        case "log": return .yellow
        case "tar", "gz", "zip": return ApexStyle.warning
        case "conf", "yaml", "json": return .purple
        default: return ApexStyle.secondary
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - SFTP Drag & Drop Export Helper
public enum SFTPDragExportHelper {
    public static func makeItemProvider(
        for item: SFTPItem,
        session: (any SSHSessionProtocol)?,
        onStatusChange: (@Sendable @MainActor (String) -> Void)? = nil
    ) -> NSItemProvider {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexTermTransfers", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let localURL = tempDir.appendingPathComponent(item.name)

        let provider = NSItemProvider()
        let ext = (item.name as NSString).pathExtension
        let specificType: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: ext) ?? .data)
        // Finder preserves the supplied extension for text, but appends the
        // content type's extension for binary file representations.
        provider.suggestedName = item.isDirectory || ext.isEmpty || specificType.conforms(to: .text)
            ? item.name
            : (item.name as NSString).deletingPathExtension

        let taskId = UUID()
        let export = SFTPExportDownload {
            guard let session else {
                throw NSError(domain: "SFTPDragExport", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: "No active SSH session"])
            }
            Task { @MainActor in
                TransferManager.shared.beginExternalTransfer(
                    id: taskId, fileName: item.name, remotePath: item.path,
                    localURL: localURL, direction: .download, totalBytes: Int64(item.size))
                onStatusChange?("正在下载并导出: \(item.name)...")
            }
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                // scp does not report byte progress through SSHSessionProtocol. Sample the
                // destination file off the main actor while Finder waits for the file.
                let expectedBytes = Int64(clamping: item.size)
                let progressMonitor = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                           let size = attributes[.size] as? NSNumber {
                            let bytes = size.int64Value
                            Task { @MainActor in
                                TransferManager.shared.updateExternalProgress(
                                    taskId: taskId,
                                    fraction: expectedBytes > 0 ? min(Double(bytes) / Double(expectedBytes), 1) : 0,
                                    transferredBytes: bytes
                                )
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { progressMonitor.cancel() }
                try await session.downloadFile(remotePath: item.path, localURL: localURL) { fraction in
                    Task { @MainActor in
                        TransferManager.shared.updateExternalProgress(taskId: taskId, fraction: fraction)
                    }
                }
                try Task.checkCancellation()
                Task { @MainActor in
                    TransferManager.shared.completeExternalTransfer(taskId: taskId)
                    onStatusChange?("拖拽导出完成: \(item.name)")
                }
                return localURL
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                try? FileManager.default.removeItem(at: tempDir)
                Task { @MainActor in
                    if error is CancellationError {
                        TransferManager.shared.cancelExternalTransfer(taskId: taskId)
                        onStatusChange?("拖拽下载已取消: \(item.name)")
                    } else {
                        TransferManager.shared.failExternalTransfer(taskId: taskId, error: error)
                        onStatusChange?("拖拽下载失败: \(error.localizedDescription)")
                    }
                }
                throw error
            }
        }
        let loadHandler: @Sendable (@escaping @Sendable (URL?, Bool, (any Error)?) -> Void) -> Progress? = { completion in
            let progress = Progress(totalUnitCount: Int64(max(item.size, 1)))
            progress.cancellationHandler = { Task { await export.cancel() } }
            let progressMonitor = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
                       let size = attributes[.size] as? NSNumber {
                        progress.completedUnitCount = min(size.int64Value, progress.totalUnitCount)
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            Task {
                defer { progressMonitor.cancel() }
                do {
                    guard !progress.isCancelled else { throw CancellationError() }
                    let url = try await export.value()
                    guard !progress.isCancelled else { throw CancellationError() }
                    progress.completedUnitCount = progress.totalUnitCount
                    completion(url, false, nil)
                } catch { completion(nil, false, error) }
            }
            return progress
        }

        // 1. Finder & Desktop require public.file-url
        provider.registerFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier, fileOptions: [], visibility: .all, loadHandler: loadHandler)

        // 2. Specific file content type (e.g. public.plain-text, public.image, public.folder)
        if specificType != .fileURL {
            provider.registerFileRepresentation(forTypeIdentifier: specificType.identifier, fileOptions: [], visibility: .all, loadHandler: loadHandler)
        }

        // 3. Generic data fallback
        if specificType != .data {
            provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all, loadHandler: loadHandler)
        }

        return provider
    }
}


/// Shares a single lazy download across the representations requested by Finder.
private actor SFTPExportDownload {
    private let operation: @Sendable () async throws -> URL
    private var task: Task<URL, Error>?
    private var isCancelled = false

    init(operation: @escaping @Sendable () async throws -> URL) { self.operation = operation }

    func value() async throws -> URL {
        guard !isCancelled else { throw CancellationError() }
        if task == nil { task = Task { try await operation() } }
        return try await task!.value
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }
}

// MARK: - Isolated Transfer Toolbar Button
struct TransferToolbarButton: View {
    @ObservedObject private var transferManager = TransferManager.shared
    @Binding var isExpanded: Bool

    var body: some View {
        Button(action: {
            withAnimation(.spring(duration: 0.25)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 4) {
                TransferActivitySymbol(isActive: transferManager.activeCount > 0,
                                       inactiveSystemName: "arrow.up.arrow.down.circle")
                    .foregroundColor(transferManager.activeCount > 0 ? ApexStyle.accent : ApexStyle.primary)
                
                if transferManager.activeCount > 0 {
                    Text("传输中 (\(transferManager.activeCount))")
                        .foregroundColor(ApexStyle.accent)
                        .font(.system(size: 11, weight: .semibold))
                } else if !transferManager.tasks.isEmpty {
                    Text("传输记录 (\(transferManager.tasks.count))")
                        .font(.system(size: 11))
                } else {
                    Text("传输记录")
                        .font(.system(size: 11))
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("查看上传与下载记录 (快捷切换)")
    }
}
