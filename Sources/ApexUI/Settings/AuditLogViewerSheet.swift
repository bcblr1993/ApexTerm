import SwiftUI
import AppKit
import ApexCore

/// Metadata entry representing a persisted terminal session audit log file.
public struct AuditLogFileItem: Identifiable, Equatable, Sendable {
    public let url: URL
    public let fileName: String
    public let sizeBytes: UInt64
    public let modifiedAt: Date

    public var id: String { url.path }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// In-app audit log viewer sheet with filename/content search, bounded tail preview, copy, and clear actions.
public struct AuditLogViewerSheet: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    public let logDirectoryPath: String

    @State private var files: [AuditLogFileItem] = []
    @State private var selectedFileID: String?
    @State private var fileFilter: String = ""
    @State private var contentSearch: String = ""
    @State private var tailPreviewText: String = ""
    @State private var toastMessage: String?
    @State private var toastToken = UUID()
    @State private var confirmingClearAll = false
    @State private var fileToDelete: AuditLogFileItem?

    public init(logDirectoryPath: String? = nil) {
        self.logDirectoryPath = logDirectoryPath ?? AppSettings.shared.sessionLogDirectory
    }

    private var expandedDirectoryURL: URL {
        let expanded = (logDirectoryPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private var filteredFiles: [AuditLogFileItem] {
        let q = fileFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return files }
        return files.filter { $0.fileName.localizedCaseInsensitiveContains(q) }
    }

    private var selectedFile: AuditLogFileItem? {
        filteredFiles.first(where: { $0.id == selectedFileID }) ?? filteredFiles.first
    }

    private var displayedPreview: String {
        Self.filterLines(in: tailPreviewText, query: contentSearch)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: ApexStyle.s3) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ApexStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("会话审计日志查看器")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ApexStyle.primary)
                    Text("\(files.count) 个日志文件 · 存储于 \(logDirectoryPath)")
                        .font(.caption)
                        .foregroundStyle(ApexStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                ApexActionButton("打开目录", icon: "folder", tint: ApexStyle.secondary, size: .small) {
                    let dir = expandedDirectoryURL
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }

                ApexActionButton("清空全部", icon: "trash", tint: ApexStyle.error, size: .small) {
                    confirmingClearAll = true
                }
                .disabled(files.isEmpty)

                ApexIconButton(icon: "arrow.clockwise", label: "刷新日志列表", size: 26, iconSize: 11) {
                    reloadFiles()
                }

                ApexIconButton(icon: "xmark", label: "关闭 (Esc)", size: 26, iconSize: 11) {
                    dismiss()
                }
            }
            .padding(ApexStyle.s4)
            .background(ApexStyle.surface)

            Divider()

            HSplitView {
                // Left file list
                VStack(spacing: ApexStyle.s2) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(ApexStyle.secondary)
                        TextField("筛选日志文件名...", text: $fileFilter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                            .stroke(ApexStyle.border.opacity(0.7), lineWidth: 0.75)
                    )
                    .padding(.horizontal, ApexStyle.s3)
                    .padding(.top, ApexStyle.s3)

                    if filteredFiles.isEmpty {
                        ContentUnavailableView(
                            "暂无审计日志",
                            systemImage: "doc.text",
                            description: Text(files.isEmpty ? "开启会话自动审计日志后，终端记录将保存于此。" : "未找到匹配的日志文件。")
                        )
                    } else {
                        List(filteredFiles, selection: $selectedFileID) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.fileName)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(ApexStyle.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack {
                                    Text(item.formattedSize)
                                    Spacer()
                                    Text(item.modifiedAt.formatted(date: .numeric, time: .shortened))
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(ApexStyle.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(item.id)
                            .contextMenu {
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                }
                                Button("删除此日志", role: .destructive) {
                                    fileToDelete = item
                                }
                            }
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                .background(ApexStyle.surface)

                // Right tail preview
                VStack(spacing: 0) {
                    HStack(spacing: ApexStyle.s2) {
                        HStack(spacing: 6) {
                            Image(systemName: "text.magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(ApexStyle.secondary)
                            TextField("过滤日志内容关键词...", text: $contentSearch)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11.5))
                            if !contentSearch.isEmpty {
                                ApexIconButton(icon: "xmark.circle.fill", label: "清除关键词", size: 16, iconSize: 10) {
                                    contentSearch = ""
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                                .stroke(ApexStyle.border.opacity(0.7), lineWidth: 0.75)
                        )

                        if let current = selectedFile {
                            ApexActionButton("复制预览", icon: "doc.on.doc", tint: ApexStyle.accent, size: .small) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(displayedPreview, forType: .string)
                                showToast("已复制日志内容到剪贴板")
                            }
                            .disabled(displayedPreview.isEmpty)

                            ApexIconButton(icon: "trash", label: "删除选中日志", size: 24, iconSize: 11, tint: ApexStyle.error) {
                                fileToDelete = current
                            }
                        }
                    }
                    .padding(.horizontal, ApexStyle.s3)
                    .padding(.vertical, ApexStyle.s2)
                    .background(ApexStyle.subtleSurface.opacity(0.6))

                    Divider()

                    if selectedFile == nil {
                        ContentUnavailableView(
                            "请选择一个日志文件",
                            systemImage: "doc.plaintext",
                            description: Text("支持尾部预览最近 500 行内容，敏感密钥与凭据在写入时已自动脱敏。")
                        )
                    } else {
                        ScrollView([.vertical, .horizontal]) {
                            Text(displayedPreview.isEmpty ? "（无匹配日志行）" : displayedPreview)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ApexStyle.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(ApexStyle.s3)
                                .textSelection(.enabled)
                        }
                        .background(ApexStyle.surface)
                    }
                }
                .frame(minWidth: 360)
            }

            if let toast = toastMessage {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ApexStyle.success)
                    Text(toast)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ApexStyle.primary)
                    Spacer()
                }
                .padding(.horizontal, ApexStyle.s4)
                .padding(.vertical, 6)
                .background(ApexStyle.subtleSurface)
            }
        }
        .frame(minWidth: 660, idealWidth: 780, maxWidth: 980, minHeight: 420, idealHeight: 540, maxHeight: 740)
        .onAppear {
            reloadFiles()
        }
        .onChange(of: selectedFileID) { _, _ in
            loadSelectedTail()
        }
        .onExitCommand { dismiss() }
        .background(
            Button("") { dismiss() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .confirmationDialog("确认清空所有审计日志？", isPresented: $confirmingClearAll) {
            Button("永久删除全部 \(files.count) 个日志", role: .destructive) {
                clearAllLogs()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从目录 \(logDirectoryPath) 永久删除全部会话审计日志文件，不可恢复。")
        }
        .confirmationDialog(
            "删除日志文件「\(fileToDelete?.fileName ?? "")」？",
            isPresented: Binding(
                get: { fileToDelete != nil },
                set: { if !$0 { fileToDelete = nil } }
            ),
            presenting: fileToDelete
        ) { item in
            Button("永久删除", role: .destructive) {
                try? FileManager.default.removeItem(at: item.url)
                fileToDelete = nil
                reloadFiles()
                showToast("已删除日志：\(item.fileName)")
            }
            Button("取消", role: .cancel) {
                fileToDelete = nil
            }
        }
    }

    // MARK: - Helpers

    private func reloadFiles() {
        files = Self.listLogFiles(in: expandedDirectoryURL)
        if selectedFileID == nil || !files.contains(where: { $0.id == selectedFileID }) {
            selectedFileID = files.first?.id
        }
        loadSelectedTail()
    }

    private func loadSelectedTail() {
        guard let file = selectedFile else {
            tailPreviewText = ""
            return
        }
        tailPreviewText = Self.readTail(of: file.url)
    }

    private func clearAllLogs() {
        for item in files {
            try? FileManager.default.removeItem(at: item.url)
        }
        reloadFiles()
        showToast("已清空全部审计日志")
    }

    private func showToast(_ msg: String) {
        let token = UUID()
        toastToken = token
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.toastToken == token {
                self.toastMessage = nil
            }
        }
    }

    public static func listLogFiles(in directory: URL) -> [AuditLogFileItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [AuditLogFileItem] = []
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasSuffix(".log") || name.contains(".log.") else { continue }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            items.append(AuditLogFileItem(
                url: url,
                fileName: name,
                sizeBytes: UInt64(max(0, values.fileSize ?? 0)),
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return items.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public static func readTail(of fileURL: URL, maxLines: Int = 500, maxBytes: UInt64 = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return ""
        }
        defer { try? handle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        if offset > 0 {
            try? handle.seek(toOffset: offset)
        }
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        let lines = text.components(separatedBy: .newlines)
        if lines.count > maxLines {
            return lines.suffix(maxLines).joined(separator: "\n")
        }
        return text
    }

    public static func filterLines(in text: String, query: String) -> String {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return text }
        return text
            .components(separatedBy: .newlines)
            .filter { $0.localizedCaseInsensitiveContains(clean) }
            .joined(separator: "\n")
    }
}
