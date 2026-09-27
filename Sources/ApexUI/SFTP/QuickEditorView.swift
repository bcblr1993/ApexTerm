import SwiftUI
import ApexCore
import ApexSSH

/// Native remote-file editor with undo, search, synchronized line numbers and safe asynchronous save.
public struct QuickEditorView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    public let item: SFTPItem
    @Binding public var content: String
    public let onSave: (String) async throws -> Void
    public let onReload: () async throws -> String
    @Environment(\.dismiss) private var dismiss
    
    @State private var isSaving = false
    @State private var isReloading = false
    @State private var saveNotice: String?
    @State private var saveNoticeIsError = false
    @State private var isSearchVisible = false
        @State private var hasUnsavedChanges = false
    @State private var initialContent = ""
    @State private var pendingDiscard: DiscardAction?

    private enum DiscardAction: String, Identifiable {
        case close, reload
        var id: String { rawValue }
    }
    
    public init(
        item: SFTPItem,
        content: Binding<String>,
        onSave: @escaping (String) async throws -> Void,
        onReload: @escaping () async throws -> String
    ) {
        self.item = item
        self._content = content
        self.onSave = onSave
        self.onReload = onReload
    }
    
    @State private var lineCount = 1
    @State private var contentByteCount = 0

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                Image(systemName: fileIcon(for: item.name))
                    .font(.system(size: 16))
                    .foregroundColor(ApexStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        
                        if hasUnsavedChanges {
                            Circle()
                                .fill(ApexStyle.warning)
                                .frame(width: 7, height: 7)
                                .help("包含未保存更改 (按 ⌘S 保存)")
                        }
                    }
                    
                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // File specs pill
                HStack(spacing: 6) {
                    Text(fileTypeTag(for: item.name))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    
                    Text("\(lineCount) 行 · \(ByteCountFormatter.string(fromByteCount: Int64(contentByteCount), countStyle: .file))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                }
                
                Divider().frame(height: 18)
                
                // Search toggle
                Button(action: { withAnimation { isSearchVisible.toggle() } }) {
                    Label("查找", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("查找 (⌘F)")
                .keyboardShortcut("f", modifiers: .command)
                
                // Reload button
                Button(action: requestReload) {
                    if isReloading {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    } else {
                        Label("重新加载", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("从服务器重新加载")
                .disabled(isReloading || isSaving)
                
                Button(action: requestClose) {
                    Label("关闭编辑器", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ApexStyle.surface)
            
            Divider()
            
            NativeCodeEditor(text: $content, showsFindBar: $isSearchVisible, isReloading: isReloading)
                .onChange(of: content) { _, newValue in
                    hasUnsavedChanges = newValue != initialContent
                    lineCount = 1 + newValue.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                    contentByteCount = newValue.utf8.count
                }

            Divider()

            // Bottom Status & Action Bar
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(ApexStyle.success).frame(width: 6, height: 6)
                    Text("UTF-8 · 远程文件")
                        .font(.caption.monospaced())
                        .foregroundColor(ApexStyle.secondary)
                }
                
                if let notice = saveNotice {
                    HStack(spacing: 4) {
                        Image(systemName: saveNoticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                        Text(notice)
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(saveNoticeIsError ? ApexStyle.error : ApexStyle.success)
                    .transition(.opacity)
                }
                
                Spacer()
                
                Button("关闭", action: requestClose)
                    .controlSize(.small)
                
                Button(action: saveChanges) {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11))
                        }
                        Text("保存 (⌘S)")
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .apexProminentButton()
                .tint(ApexStyle.accent)
                .controlSize(.small)
                .disabled(isSaving || isReloading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ApexStyle.surface)
        }
        .frame(minWidth: 720, minHeight: 520)
        .interactiveDismissDisabled(hasUnsavedChanges || isSaving || isReloading)
        .alert(item: $pendingDiscard) { action in
            Alert(title: Text("放弃未保存的更改？"),
                  message: Text(action == .close ? "关闭后，尚未上传的更改将丢失。" : "重新加载会用服务器上的内容替换当前更改。"),
                  primaryButton: .destructive(Text("放弃更改")) {
                      if action == .close { dismiss() } else { reloadContent() }
                  }, secondaryButton: .cancel(Text("继续编辑")))
        }
        .onAppear {
            initialContent = content
            lineCount = 1 + content.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            contentByteCount = content.utf8.count
        }
    }
    
    private func requestClose() {
        guard !isSaving && !isReloading else { return }
        if hasUnsavedChanges { pendingDiscard = .close } else { dismiss() }
    }

    private func requestReload() {
        guard !isSaving && !isReloading else { return }
        if hasUnsavedChanges { pendingDiscard = .reload } else { reloadContent() }
    }

    private func saveChanges() {
        guard !isSaving else { return }
        isSaving = true
        let savedContent = content
        saveNotice = nil
        Task {
            do {
                try await onSave(savedContent)
                await MainActor.run {
                    self.isSaving = false
                    self.initialContent = savedContent
                    self.hasUnsavedChanges = self.content != savedContent
                    self.saveNoticeIsError = false
                    let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                    self.saveNotice = self.hasUnsavedChanges
                        ? "已上传保存时的内容；仍有新更改待保存 (\(time))"
                        : "已保存并上传至服务器 (\(time))"
                }
            } catch {
                await MainActor.run {
                    self.isSaving = false
                    self.saveNoticeIsError = true
                    self.saveNotice = "保存失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func reloadContent() {
        guard !isReloading else { return }
        isReloading = true
        Task {
            do {
                let reloaded = try await onReload()
                await MainActor.run {
                    self.content = reloaded
                    self.initialContent = reloaded
                    self.hasUnsavedChanges = false
                    self.isReloading = false
                    self.saveNotice = "已重新拉取远端最新内容"
                    self.saveNoticeIsError = false
                }
            } catch {
                await MainActor.run {
                    self.isReloading = false
                    self.saveNoticeIsError = true
                    self.saveNotice = "拉取失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func fileTypeTag(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh": return "SHELL"
        case "yaml", "yml": return "YAML"
        case "json": return "JSON"
        case "conf", "ini", "toml": return "CONFIG"
        case "py": return "PYTHON"
        case "swift": return "SWIFT"
        case "go": return "GO"
        case "js", "ts": return "JAVASCRIPT"
        case "log": return "LOG"
        case "md": return "MARKDOWN"
        default: return "TEXT"
        }
    }
    
    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh": return "terminal.fill"
        case "yaml", "yml", "json", "toml", "conf", "ini": return "slider.horizontal.3"
        case "log": return "doc.text.fill"
        default: return "doc.text"
        }
    }
}
