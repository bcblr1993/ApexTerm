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
    @State private var selectedItem: SFTPItem?
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

                // Directory Linkage toggle button
                Button(action: {
                    isLinkageEnabled.toggle()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isLinkageEnabled ? "link" : "link.slash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isLinkageEnabled ? ApexStyle.success : .secondary)
                        Text(isLinkageEnabled ? L10n.linkageOn : L10n.linkageOff)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(isLinkageEnabled ? .primary : .secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(isLinkageEnabled ? ApexStyle.success.opacity(0.12) : Color.secondary.opacity(0.10), in: Capsule())
                    .overlay(
                        Capsule().stroke(isLinkageEnabled ? ApexStyle.success.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(isLinkageEnabled ? L10n.linkageHelpOn : L10n.linkageHelpOff)

                if let notice = transferNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(transferNotice?.contains("失败") == true ? .red : ApexStyle.success)
                        .transition(.opacity)
                }

                Divider().frame(height: 16)

                // Actions
                Button(action: {
                    navigateUp()
                }) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.plain)
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
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
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
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                TextField(L10n.filterFiles, text: $searchFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchFilter.isEmpty {
                    Button(action: { searchFilter = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(ApexStyle.subtleSurface.opacity(0.65))

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
                    List(filteredItems, id: \.path, selection: $selectedItem) { item in
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
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            handleDoubleClick(item)
                        }
                        // Drag remote file to download to desktop/finder
                        .onDrag {
                            handleDragDownload(for: item)
                        }
                        .contextMenu {
                            Button(L10n.downloadToDownloads) {
                                downloadAction(item)
                            }
                            if !item.isDirectory {
                                Button(L10n.quickViewEdit) {
                                    openEditor(item)
                                }
                            }
                            Divider()
                            Button(L10n.copyRemotePath) {
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

    private func uploadAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, let s = session {
            for url in panel.urls {
                let dest = currentPath.hasSuffix("/") ? "\(currentPath)\(url.lastPathComponent)" : "\(currentPath)/\(url.lastPathComponent)"
                TransferManager.shared.enqueueUpload(session: s, localURL: url, remotePath: dest) {
                    DispatchQueue.main.async {
                        self.loadDirectory(path: self.currentPath)
                    }
                }
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
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let localURL = url else { return }
                let dest = targetDirectory.hasSuffix("/") ? "\(targetDirectory)\(localURL.lastPathComponent)" : "\(targetDirectory)/\(localURL.lastPathComponent)"
                Task { @MainActor in
                    TransferManager.shared.enqueueUpload(session: s, localURL: localURL, remotePath: dest) {
                        DispatchQueue.main.async {
                            self.loadDirectory(path: targetDirectory)
                        }
                    }
                }
            }
        }
    }

    /// Handle dragging a remote file item to download
    private func handleDragDownload(for item: SFTPItem) -> NSItemProvider {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ApexTermTransfers")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let localURL = tempDir.appendingPathComponent(item.name)

        let provider = NSItemProvider()
        provider.suggestedName = item.name
        provider.registerFileRepresentation(forTypeIdentifier: UTType.item.identifier, fileOptions: [], visibility: .all) { completion in
            Task {
                do {
                    try await session?.downloadFile(remotePath: item.path, localURL: localURL, progress: { _ in })
                    completion(localURL, true, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    private func fileIcon(for item: SFTPItem) -> String {
        if item.name == ".." { return "arrow.turn.up.left" }
        if item.isDirectory { return "folder.fill" }
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
