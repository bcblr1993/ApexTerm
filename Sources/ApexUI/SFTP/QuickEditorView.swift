import SwiftUI
import ApexCore
import ApexSSH

/// In-place code and configuration editor with live ⌘S streaming save, line numbers, search and status indicators
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
    @State private var searchText = ""
    @State private var hasUnsavedChanges = false
    @State private var initialContent = ""
    
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
    
    private var lines: [String] {
        content.components(separatedBy: "\n")
    }
    
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
                    
                    Text("\(lines.count) 行 · \(item.formattedSize)")
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
                Button(action: reloadContent) {
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
                .disabled(isReloading)
                
                Button(action: { dismiss() }) {
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
            
            // Search Bar
            if isSearchVisible {
                HStack(spacing: 8) {
                    TextField("在文件中查找…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    
                    if !searchText.isEmpty {
                        let matches = countMatches()
                        Text("\(matches) 处匹配")
                            .font(.system(size: 11))
                            .foregroundColor(ApexStyle.secondary)
                        
                        Button(action: { searchText = "" }) {
                            Label("清除查找", systemImage: "xmark.circle.fill")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(ApexStyle.subtleSurface)
                
                Divider()
            }
            
            // Editor Body with Line Numbers
            HStack(spacing: 0) {
                // Line Number Gutter
                ScrollView([.vertical], showsIndicators: false) {
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(1...max(lines.count, 1), id: \.self) { lineNum in
                            Text("\(lineNum)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(ApexStyle.secondary.opacity(0.45))
                                .frame(height: 19)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                }
                .frame(width: 48)
                .background(ApexStyle.subtleSurface.opacity(0.35))
                .allowsHitTesting(false)
                
                Divider()
                
                // Native TextEditor
                TextEditor(text: $content)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(2)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .scrollContentBackground(.hidden)
                    .background(ApexStyle.surface)
                    .onChange(of: content) { _, newVal in
                        hasUnsavedChanges = (newVal != initialContent)
                    }
            }
            
            Divider()
            
            // Bottom Status & Action Bar
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(ApexStyle.success).frame(width: 6, height: 6)
                    Text("UTF-8 · 远程流式直连")
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
                
                Button("关闭") { dismiss() }
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
                .disabled(isSaving)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ApexStyle.surface)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            initialContent = content
        }
    }
    
    private func saveChanges() {
        guard !isSaving else { return }
        isSaving = true
        saveNotice = nil
        Task {
            do {
                try await onSave(content)
                await MainActor.run {
                    self.isSaving = false
                    self.initialContent = self.content
                    self.hasUnsavedChanges = false
                    self.saveNoticeIsError = false
                    let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                    self.saveNotice = "已保存并上传至服务器 (\(time))"
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
    
    private func countMatches() -> Int {
        guard !searchText.isEmpty else { return 0 }
        return content.components(separatedBy: searchText).count - 1
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
