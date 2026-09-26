import SwiftUI
import UniformTypeIdentifiers
import ApexCore
import ApexSSH

/// High-performance integrated SFTP file manager (electerm-style with OSC 7 sync and drag-and-drop upload/download)
public struct SFTPView: View {
    @Binding public var currentPath: String
    @Binding public var isLinkageEnabled: Bool
    public let session: SSHSessionProtocol?

    @State private var items: [SFTPItem] = []
    @State private var isLoading = false
    @State private var selectedPath: String?
    @State private var searchFilter = ""
    @State private var editingFile: SFTPItem?
    @State private var editorContent = ""
    @State private var isDropTargeted = false
    @State private var transferNotice: String?
    @State private var loadError: String?
    @State private var isOpeningEditor = false
    @State private var isTransferDrawerExpanded = false
    @State private var loadTask: Task<Void, Never>?

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
                Image(systemName: "folder.fill")
                    .foregroundColor(ApexStyle.accent)
                    .font(.system(size: 13))

                TextField(L10n.remotePath, text: $currentPath, onCommit: {
                    loadDirectory(path: currentPath)
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

                Toggle(isOn: $isLinkageEnabled) {
                    Label(isLinkageEnabled ? L10n.linkageOn : L10n.linkageOff,
                          systemImage: isLinkageEnabled ? "link" : "link.slash")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(isLinkageEnabled ? L10n.linkageHelpOn : L10n.linkageHelpOff)

                if let notice = transferNotice {
                    HStack(spacing: 5) {
                        Image(systemName: notice.contains("失败") ? "exclamationmark.triangle.fill" : (notice.contains("正在") ? "arrow.up.circle" : "checkmark.circle.fill"))
                            .foregroundColor(notice.contains("失败") ? .red : (notice.contains("正在") ? ApexStyle.accent : ApexStyle.success))
                            .font(.system(size: 11))
                        Text(notice)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(notice.contains("失败") ? .red : (notice.contains("正在") ? ApexStyle.accent : ApexStyle.success))
                        if notice.contains("失败") {
                            Button(action: { transferNotice = nil }) {
                                Label("关闭传输提示", systemImage: "xmark.circle")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        notice.contains("失败") ? Color.red.opacity(0.12) : (notice.contains("正在") ? ApexStyle.accent.opacity(0.12) : ApexStyle.success.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .transition(.opacity)
                }

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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ApexStyle.surface)

            Divider()

            // Search filter bar
            HStack {
                TextField(L10n.filterFiles, text: $searchFilter)
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
                    List(filteredItems, id: \.path, selection: $selectedPath) { item in
                        HStack(spacing: 10) {
                            Image(systemName: fileIcon(for: item))
                                .foregroundColor(fileColor(for: item))
                                .frame(width: 18)

                            Text(item.name)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)

                            Spacer()

                            Text(item.permissionString)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 80, alignment: .trailing)

                            Text(item.formattedSize)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 70, alignment: .trailing)

                            Text(formatDate(item.modificationDate))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 110, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                selectedPath = item.path
                            }
                        )
                        .onTapGesture(count: 2) {
                            handleDoubleClick(item)
                        }
                        // Drag remote file to download to desktop/finder
                        .onDrag {
                            handleDragDownload(for: item)
                        }
                        .contextMenu {
                            Button(L10n.downloadToDownloads) {
                                selectedPath = item.path
                                downloadAction(item)
                            }
                            if !item.isDirectory {
                                Button(L10n.quickViewEdit) {
                                    selectedPath = item.path
                                    openEditor(item)
                                }
                            }
                            Divider()
                            Button(L10n.copyRemotePath) {
                                selectedPath = item.path
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.path, forType: .string)
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .opacity(isLoading ? 0.65 : 1.0)
                    // Drag local file from Finder/Desktop to upload into current remote directory
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDropUpload(providers: providers)
                        return true
                    }
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

                // Floating Transfer Task Drawer
                VStack {
                    Spacer()
                    TransferDrawer(isExpanded: $isTransferDrawerExpanded)
                }
            }
        }
        .onAppear {
            loadDirectory(path: currentPath)
        }
        .onChange(of: currentPath) { _, newPath in
            loadDirectory(path: newPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SFTPDirectoryRefreshNeeded"))) { _ in
            loadDirectory(path: currentPath)
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
    }

    private var filteredItems: [SFTPItem] {
        if searchFilter.isEmpty { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchFilter) }
    }

    private func loadDirectory(path: String) {
        guard let s = session else { return }
        isLoading = true
        loadError = nil
        selectedPath = nil
        loadTask?.cancel()
        loadTask = Task {
            do {
                let fetched = try await s.listDirectory(path: path)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.items = fetched.sorted {
                        if $0.isDirectory != $1.isDirectory {
                            return $0.isDirectory && !$1.isDirectory
                        }
                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    self.isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.items = []
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
                editorContent = try String(contentsOf: localURL, encoding: .utf8)
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
        return try String(contentsOf: localURL, encoding: .utf8)
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
        if panel.runModal() == .OK, let s = session {
            let targetDir = self.currentPath
            for url in panel.urls {
                let dest = targetDir.hasSuffix("/") ? "\(targetDir)\(url.lastPathComponent)" : "\(targetDir)/\(url.lastPathComponent)"
                self.transferNotice = "正在上传 \(url.lastPathComponent)..."
                TransferManager.shared.enqueueUpload(
                    session: s,
                    localURL: url,
                    remotePath: dest,
                    onResult: { result in
                        Task { @MainActor in
                            self.handleUploadResult(result, fileName: url.lastPathComponent, targetDirectory: targetDir)
                        }
                    }
                )
            }
        }
    }

    private func downloadAction(_ item: SFTPItem) {
        guard let s = session else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let localURL = downloads.appendingPathComponent(item.name)
        TransferManager.shared.enqueueDownload(session: s, remotePath: item.path, localURL: localURL, totalBytes: Int64(item.size))
    }

    /// Handle local file drop from Finder / Desktop
    private func handleDropUpload(providers: [NSItemProvider]) {
        guard let s = session else { return }
        let targetDirectory = self.currentPath
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var localURL: URL?
                    if let url = item as? URL {
                        localURL = url
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        localURL = url
                    } else if let str = item as? String, let url = URL(string: str) {
                        localURL = url
                    }
                    guard let fileURL = localURL else { return }
                    let dest = targetDirectory.hasSuffix("/") ? "\(targetDirectory)\(fileURL.lastPathComponent)" : "\(targetDirectory)/\(fileURL.lastPathComponent)"
                    Task { @MainActor in
                        self.transferNotice = "正在上传 \(fileURL.lastPathComponent)..."
                        TransferManager.shared.enqueueUpload(
                            session: s,
                            localURL: fileURL,
                            remotePath: dest,
                            onResult: { result in
                                Task { @MainActor in
                                    self.handleUploadResult(result, fileName: fileURL.lastPathComponent, targetDirectory: targetDirectory)
                                }
                            }
                        )
                    }
                }
            } else {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let localURL = url else { return }
                    let dest = targetDirectory.hasSuffix("/") ? "\(targetDirectory)\(localURL.lastPathComponent)" : "\(targetDirectory)/\(localURL.lastPathComponent)"
                    Task { @MainActor in
                        self.transferNotice = "正在上传 \(localURL.lastPathComponent)..."
                        TransferManager.shared.enqueueUpload(
                            session: s,
                            localURL: localURL,
                            remotePath: dest,
                            onResult: { result in
                                Task { @MainActor in
                                    self.handleUploadResult(result, fileName: localURL.lastPathComponent, targetDirectory: targetDirectory)
                                }
                            }
                        )
                    }
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
        case "sh": return .green
        case "log": return .yellow
        case "tar", "gz", "zip": return .orange
        case "conf", "yaml", "json": return .purple
        default: return .secondary
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
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ApexTermTransfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let localURL = tempDir.appendingPathComponent(item.name)

        let provider = NSItemProvider()
        provider.suggestedName = item.name

        // Determine specific UTType based on file extension
        let ext = (item.name as NSString).pathExtension
        let specificType: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: ext) ?? .data)

        // Show immediate visual feedback
        if let onStatusChange {
            Task { @MainActor in
                onStatusChange("正在下载并导出: \(item.name)...")
            }
        }

        // Asynchronously start pre-fetching download as soon as user begins dragging
        let downloadTask = Task.detached(priority: .userInitiated) { [session] () -> Bool in
            guard let session = session else { return false }
            do {
                try await session.downloadFile(remotePath: item.path, localURL: localURL, progress: { _ in })
                return true
            } catch {
                return false
            }
        }

        let loadHandler: @Sendable (@escaping @Sendable (URL?, Bool, (any Error)?) -> Void) -> Progress? = { completion in
            let progress = Progress(totalUnitCount: Int64(max(item.size, 1)))
            Task {
                let success = await downloadTask.value
                if !success || !FileManager.default.fileExists(atPath: localURL.path) {
                    do {
                        if let session = session {
                            try await session.downloadFile(remotePath: item.path, localURL: localURL, progress: { p in
                                progress.completedUnitCount = Int64(Double(item.size) * p)
                            })
                        } else {
                            throw NSError(domain: "SFTPDragExport", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active SSH session"])
                        }
                    } catch {
                        if let onStatusChange {
                            Task { @MainActor in
                                onStatusChange("拖拽下载失败: \(error.localizedDescription)")
                            }
                        }
                        completion(nil, false, error)
                        return
                    }
                }
                
                progress.completedUnitCount = Int64(max(item.size, 1))
                if let onStatusChange {
                    Task { @MainActor in
                        onStatusChange("拖拽导出完成: \(item.name)")
                    }
                }
                // Coordinated: false allows standard filesystem destination copying by Finder/Desktop
                completion(localURL, false, nil)
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

