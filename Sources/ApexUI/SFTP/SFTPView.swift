import SwiftUI
import UniformTypeIdentifiers
import ApexCore
import ApexSSH

/// High-performance integrated SFTP file manager (electerm-style with OSC 7 sync and drag-and-drop upload/download)
public struct SFTPView: View {
    @Binding public var currentPath: String
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

    public init(currentPath: Binding<String>, session: SSHSessionProtocol?) {
        self._currentPath = currentPath
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

                // OSC 7 Auto-sync badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(L10n.osc7Sync)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(ApexStyle.success.opacity(0.10), in: Capsule())

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
                    Image(systemName: "arrow.clockwise")
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
                if isLoading {
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
            }
        }
        .onAppear {
            loadDirectory(path: currentPath)
        }
        .onChange(of: currentPath) { _, newPath in
            loadDirectory(path: newPath)
        }
        .sheet(item: $editingFile) { item in
            QuickEditorSheet(item: item, content: $editorContent) { newContent in
                saveEditedFile(item, content: newContent)
            }
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
        Task {
            do {
                let fetched = try await s.listDirectory(path: path)
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

    private func saveEditedFile(_ item: SFTPItem, content: String) {
        guard let session else { return }
        Task {
            let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: localURL) }
            do {
                try content.write(to: localURL, atomically: true, encoding: .utf8)
                try await session.uploadFile(localURL: localURL, remotePath: item.path, progress: { _ in })
                transferNotice = "已保存：\(item.name)"
                loadDirectory(path: currentPath)
            } catch {
                transferNotice = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    private func uploadAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await session?.uploadFile(localURL: url, remotePath: "\(currentPath)/\(url.lastPathComponent)", progress: { _ in })
                    transferNotice = "已上传：\(url.lastPathComponent)"
                    loadDirectory(path: currentPath)
                } catch {
                    transferNotice = "上传失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func downloadAction(_ item: SFTPItem) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let localURL = downloads.appendingPathComponent(item.name)
        Task {
            do {
                try await session?.downloadFile(remotePath: item.path, localURL: localURL, progress: { _ in })
                transferNotice = "已下载：\(item.name)"
            } catch {
                transferNotice = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    /// Handle local file drop from Finder / Desktop
    private func handleDropUpload(providers: [NSItemProvider]) {
        let targetDirectory = self.currentPath
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let localURL = url else { return }
                Task {
                    let dest = targetDirectory.hasSuffix("/") ? "\(targetDirectory)\(localURL.lastPathComponent)" : "\(targetDirectory)/\(localURL.lastPathComponent)"
                    do {
                        try await session?.uploadFile(localURL: localURL, remotePath: dest, progress: { _ in })
                        await MainActor.run {
                            loadDirectory(path: targetDirectory)
                            withAnimation {
                                self.transferNotice = "已成功上传: \(localURL.lastPathComponent)"
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                withAnimation { self.transferNotice = nil }
                            }
                        }
                    } catch {
                        await MainActor.run {
                            withAnimation {
                                self.transferNotice = "上传失败: \(error.localizedDescription)"
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                withAnimation { self.transferNotice = nil }
                            }
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

/// In-place code editor sheet
public struct QuickEditorSheet: View {
    public let item: SFTPItem
    @Binding public var content: String
    public let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 18))
                    .foregroundStyle(ApexStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(ApexStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 17, weight: .semibold))
                    Text(item.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(16)
            .background(ApexStyle.surface)

            Divider()

            TextEditor(text: $content)
                .font(.system(size: 13, design: .monospaced))
                .padding(12)

            Divider()
            HStack {
                Text("UTF-8 · 修改后将上传到远程主机")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.closeWindow) { dismiss() }
                Button("保存并关闭") {
                    onSave(content)
                    dismiss()
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(ApexStyle.accent)
            }
            .padding(14)
            .background(ApexStyle.surface)
        }
        .frame(minWidth: 660, minHeight: 500)
    }
}
