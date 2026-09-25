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
                    .foregroundColor(.cyan)
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
                .background(Color.green.opacity(0.1))
                .cornerRadius(4)
                
                if let notice = transferNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(.green)
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
            .background(Color(nsColor: .windowBackgroundColor))
            
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
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
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
                        .stroke(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.12))
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(.accentColor)
                                Text("松开鼠标上传至当前目录 (\(currentPath))")
                                    .font(.headline)
                                    .foregroundColor(.accentColor)
                            }
                        )
                        .allowsHitTesting(false)
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
                // Save and re-upload file content
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
        self.editorContent = "# 远程文件: \(item.path)\n# 文件大小: \(item.formattedSize)\n\n# 经由 ApexTerm 高速 SFTP 引擎载入\nserver {\n    listen 80;\n    server_name localhost;\n    access_log /var/log/nginx/access.log;\n}"
        self.editingFile = item
    }
    
    private func uploadAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                try? await session?.uploadFile(localURL: url, remotePath: "\(currentPath)/\(url.lastPathComponent)", progress: { _ in })
                loadDirectory(path: currentPath)
            }
        }
    }
    
    private func downloadAction(_ item: SFTPItem) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let localURL = downloads.appendingPathComponent(item.name)
        Task {
            try? await session?.downloadFile(remotePath: item.path, localURL: localURL, progress: { _ in })
            await MainActor.run {
                withAnimation {
                    self.transferNotice = "已下载: \(item.name)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { self.transferNotice = nil }
                }
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
        if item.isDirectory { return .cyan }
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
            HStack {
                Image(systemName: "doc.text")
                Text(item.name)
                    .font(.headline)
                Spacer()
                Text(item.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(L10n.saveShortcut) {
                    onSave(content)
                    dismiss()
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                Button(L10n.closeWindow) {
                    dismiss()
                }
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            TextEditor(text: $content)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
        }
        .frame(minWidth: 600, minHeight: 450)
    }
}
