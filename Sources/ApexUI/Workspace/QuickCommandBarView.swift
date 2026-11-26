import SwiftUI
import ApexCore

/// Horizontal collapsible quick command action bar docked at the bottom of the terminal workspace
public struct QuickCommandBarView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject public var store: SessionStore
    public let sessionContext: [String: String]
    public let onExecuteCommand: (String) -> Void
    @Binding public var isVisible: Bool
    
    @State private var selectedCategory: String = "全部"
    @State private var snippetWithVariables: Snippet? = nil
    @State private var variableValues: [String: String] = [:]
    @State private var isAddSheetPresented: Bool = false
    @State private var editingSnippet: Snippet? = nil
    
    // Snippet form state
    @State private var draftTitle: String = ""
    @State private var draftCommand: String = ""
    @State private var draftCategory: String = "自定义"
    @State private var draftAutoExecute: Bool = false
    
    public init(
        store: SessionStore,
        isVisible: Binding<Bool>,
        sessionContext: [String: String] = [:],
        onExecuteCommand: @escaping (String) -> Void
    ) {
        self.store = store
        self._isVisible = isVisible
        self.sessionContext = sessionContext
        self.onExecuteCommand = onExecuteCommand
    }

    public static func context(for session: Session?) -> [String: String] {
        guard let session else { return [:] }
        var ctx: [String: String] = [:]
        let host = session.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = session.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty { ctx["host"] = host }
        if !user.isEmpty { ctx["user"] = user }
        return ctx
    }

    public static func executionPayload(
        for snippet: Snippet,
        context: [String: String],
        executeImmediately: Bool? = nil
    ) -> String {
        let resolved = snippet.resolvedCommand(context: context)
        let shouldExecute = executeImmediately ?? snippet.autoExecute
        return shouldExecute ? (resolved + "\n") : resolved
    }

    /// Computes live pre-flight interpolated command text for display inside `VariableInputSheet`.
    public static func livePreviewText(for snippet: Snippet, variableValues: [String: String]) -> String {
        snippet.resolvedCommand(context: variableValues)
    }

    /// Creates a duplicated `Snippet` ready to be inserted into `SessionStore`.
    public static func duplicatedSnippet(from snippet: Snippet) -> Snippet {
        Snippet(
            title: "\(snippet.title) (副本)",
            command: snippet.command,
            category: snippet.category,
            autoExecute: snippet.autoExecute
        )
    }
    
    private var allCategories: [String] {
        var set = Set<String>()
        for s in store.snippets {
            set.insert(s.category)
        }
        var list = Array(set).sorted()
        // Ensure standard categories come first
        let priority = ["系统", "进程", "Docker", "网络", "日志"]
        list.sort { a, b in
            let idxA = priority.firstIndex(of: a) ?? 999
            let idxB = priority.firstIndex(of: b) ?? 999
            if idxA != idxB { return idxA < idxB }
            return a < b
        }
        return ["全部"] + list
    }
    
    private var filteredSnippets: [Snippet] {
        if selectedCategory == "全部" {
            return store.snippets
        }
        return store.snippets.filter { $0.category == selectedCategory }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: ApexStyle.s2) {
                // Category Selector & Snippet Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ApexStyle.sCompact) {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(ApexStyle.accent)
                            Text("快捷命令")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(ApexStyle.primary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .padding(.trailing, 4)
                        .accessibilityElement(children: .combine)
                        
                        ForEach(allCategories, id: \.self) { cat in
                            ApexPillButton(
                                title: cat,
                                isSelected: selectedCategory == cat,
                                action: { selectedCategory = cat }
                            )
                            .accessibilityLabel("分类 \(cat)")
                        }
                        
                        Divider().frame(height: 14)
                        
                        // Snippet Action Pills
                        ForEach(filteredSnippets) { snippet in
                            QuickSnippetPill(
                                snippet: snippet,
                                onTrigger: {
                                    triggerSnippet(snippet)
                                },
                                onAlternateRun: {
                                    triggerSnippet(snippet, overrideAutoExecute: !snippet.autoExecute)
                                },
                                onEdit: {
                                    editingSnippet = snippet
                                    draftTitle = snippet.title
                                    draftCommand = snippet.command
                                    draftCategory = snippet.category
                                    draftAutoExecute = snippet.autoExecute
                                    isAddSheetPresented = true
                                },
                                onDuplicate: {
                                    store.addSnippet(Self.duplicatedSnippet(from: snippet))
                                },
                                onDelete: {
                                    store.deleteSnippet(id: snippet.id)
                                }
                            )
                        }
                        
                        // + Add Custom Snippet Button
                        ApexPillButton(
                            title: "添加",
                            icon: "plus"
                        ) {
                            editingSnippet = nil
                            draftTitle = ""
                            draftCommand = ""
                            draftCategory = selectedCategory == "全部" ? "自定义" : selectedCategory
                            draftAutoExecute = false
                            isAddSheetPresented = true
                        }
                        .help("添加新的常用快捷命令")
                        .accessibilityLabel("添加快捷命令")
                    }
                    .padding(.leading, ApexStyle.s4)
                    .padding(.trailing, ApexStyle.s1)
                    .padding(.vertical, 6)
                }
                
                // Hide bar button
                ApexIconButton(
                    icon: "xmark",
                    label: "隐藏快捷命令栏 (⌘⇧B)",
                    size: 22,
                    iconSize: 9
                ) {
                    withAnimation(ApexStyle.hoverTransition) {
                        isVisible = false
                    }
                }
                .padding(.trailing, ApexStyle.s4)
            }
            .frame(height: 38)
            .background(ApexStyle.subtleSurface.opacity(0.65))
        }
        .sheet(item: $snippetWithVariables) { snippet in
            VariableInputSheet(
                snippet: snippet,
                variableValues: $variableValues,
                onConfirm: { resolved in
                    onExecuteCommand(resolved + "\n")
                    snippetWithVariables = nil
                },
                onInsertCommand: { resolved in
                    onExecuteCommand(resolved)
                    snippetWithVariables = nil
                },
                onCancel: {
                    snippetWithVariables = nil
                }
            )
            .apexTheme()
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AddSnippetSheet(
                isEditing: editingSnippet != nil,
                title: $draftTitle,
                command: $draftCommand,
                category: $draftCategory,
                autoExecute: $draftAutoExecute,
                onSave: {
                    let trimmedCategory = draftCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedCommand = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedCat = trimmedCategory.isEmpty ? "自定义" : trimmedCategory
                    if var existing = editingSnippet {
                        existing.title = trimmedTitle
                        existing.command = trimmedCommand
                        existing.category = resolvedCat
                        existing.autoExecute = draftAutoExecute
                        store.updateSnippet(existing)
                    } else {
                        let s = Snippet(
                            title: trimmedTitle,
                            command: trimmedCommand,
                            category: resolvedCat,
                            autoExecute: draftAutoExecute
                        )
                        store.addSnippet(s)
                    }
                    editingSnippet = nil
                    isAddSheetPresented = false
                },
                onCancel: {
                    editingSnippet = nil
                    isAddSheetPresented = false
                }
            )
            .apexTheme()
        }
    }
    
    private func triggerSnippet(_ snippet: Snippet, overrideAutoExecute: Bool? = nil) {
        let unresolved = snippet.unresolvedVariables(context: sessionContext)
        if unresolved.isEmpty {
            let payload = Self.executionPayload(
                for: snippet,
                context: sessionContext,
                executeImmediately: overrideAutoExecute
            )
            onExecuteCommand(payload)
        } else {
            var initialDict = sessionContext
            for v in unresolved {
                initialDict[v] = ""
            }
            variableValues = initialDict
            snippetWithVariables = snippet
        }
    }
}

/// Modal dialog for prompting variable values in dynamic snippets like `{{service}}` or `{{container}}`
public struct VariableInputSheet: View {
    public let snippet: Snippet
    @Binding public var variableValues: [String: String]
    public let onConfirm: (String) -> Void
    public let onInsertCommand: ((String) -> Void)?
    public let onCancel: () -> Void
    @State private var formContentHeight: CGFloat = 0
    
    public init(
        snippet: Snippet,
        variableValues: Binding<[String: String]>,
        onConfirm: @escaping (String) -> Void,
        onInsertCommand: ((String) -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.snippet = snippet
        self._variableValues = variableValues
        self.onConfirm = onConfirm
        self.onInsertCommand = onInsertCommand
        self.onCancel = onCancel
    }
    
    private var variables: [String] {
        snippet.extractVariables()
    }

    private var maxScrollableHeight: CGFloat { 260 }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s4) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("请为以下变量输入参数值")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
                Spacer()
                ApexIconButton(icon: "xmark", label: "关闭", size: 22, iconSize: 10) {
                    onCancel()
                }
            }
            
            ScrollView(.vertical, showsIndicators: formContentHeight > maxScrollableHeight) {
                VStack(alignment: .leading, spacing: ApexStyle.s3) {
                    VStack(alignment: .leading, spacing: 4) {
                        let previewText = QuickCommandBarView.livePreviewText(for: snippet, variableValues: variableValues)
                        let remaining = snippet.unresolvedVariables(context: variableValues)
                        HStack {
                            Text("实时命令预览：")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(ApexStyle.secondary)
                            Spacer()
                            if !remaining.isEmpty {
                                Text("待填写 \(remaining.count) 项")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(ApexStyle.warning)
                            } else {
                                Text("已就绪")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(ApexStyle.success)
                            }
                        }
                        Text(previewText)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(ApexStyle.primary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                            .overlay(RoundedRectangle(cornerRadius: ApexStyle.controlRadius).stroke(ApexStyle.border, lineWidth: 1))
                    }
                    
                    VStack(spacing: ApexStyle.s3) {
                        ForEach(variables, id: \.self) { v in
                            HStack(spacing: ApexStyle.s2) {
                                Text(v)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(ApexStyle.accent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(v)
                                    .frame(width: 120, alignment: .trailing)
                                
                                TextField("输入 \(v)...", text: Binding(
                                    get: { variableValues[v] ?? "" },
                                    set: { variableValues[v] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("变量 \(v)")
                                .onSubmit {
                                    submitDefault()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formContentHeight = $0 }
            }
            .frame(height: formContentHeight > 0 ? min(formContentHeight, maxScrollableHeight) : nil)
            .frame(maxHeight: maxScrollableHeight)
            
            HStack(spacing: ApexStyle.s2) {
                Spacer()
                ApexActionButton("取消", tint: ApexStyle.secondary, size: .regular) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                if snippet.autoExecute {
                    ApexActionButton("发送至命令行", icon: "text.insert", tint: ApexStyle.secondary, size: .regular) {
                        (onInsertCommand ?? onConfirm)(QuickCommandBarView.livePreviewText(for: snippet, variableValues: variableValues))
                    }
                    ApexActionButton("立即执行 ↵", icon: "play.fill", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                        onConfirm(QuickCommandBarView.livePreviewText(for: snippet, variableValues: variableValues))
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    ApexActionButton("立即执行 ↵", icon: "play.fill", tint: ApexStyle.warning, size: .regular) {
                        onConfirm(QuickCommandBarView.livePreviewText(for: snippet, variableValues: variableValues))
                    }
                    ApexActionButton("发送至命令行", icon: "text.insert", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                        (onInsertCommand ?? onConfirm)(QuickCommandBarView.livePreviewText(for: snippet, variableValues: variableValues))
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(ApexStyle.s4)
        .frame(minWidth: 380, idealWidth: 480, maxWidth: 560)
        .onExitCommand { onCancel() }
        .background(
            Button("") { onCancel() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
    
    private func submitDefault() {
        let resolved = snippet.resolvedCommand(context: variableValues)
        if snippet.autoExecute {
            onConfirm(resolved)
        } else {
            (onInsertCommand ?? onConfirm)(resolved)
        }
    }
}

/// Sheet to add or edit a command snippet
private struct AddSnippetSheet: View {
    let isEditing: Bool
    @Binding var title: String
    @Binding var command: String
    @Binding var category: String
    @Binding var autoExecute: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s4) {
            HStack {
                Image(systemName: isEditing ? "pencil.circle.fill" : "plus.square.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                    .accessibilityHidden(true)
                Text(isEditing ? "编辑快捷命令" : "新建快捷命令")
                    .font(.headline)
                Spacer()
                ApexIconButton(icon: "xmark", label: "关闭", size: 22, iconSize: 10) {
                    onCancel()
                }
            }
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: ApexStyle.s3) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("标题")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(ApexStyle.secondary)
                        TextField("例如：查看 Docker 容器日志", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("快捷命令标题")
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shell 命令 (支持 {{var}}、{{host}}、{{user}}、{{date}})")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(ApexStyle.secondary)
                        TextField("例如：docker logs -f --tail 100 {{container}}", text: $command)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Shell 命令内容")
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("分类")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(ApexStyle.secondary)
                        TextField("例如：Docker、系统、运维", text: $category)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("快捷命令分类")
                    }

                    Toggle("发送后自动回车执行 (Auto-Execute)", isOn: $autoExecute)
                        .font(.caption)
                        .foregroundColor(ApexStyle.primary)
                }
            }
            
            HStack(spacing: ApexStyle.s2) {
                Spacer()
                ApexActionButton("取消", tint: ApexStyle.secondary, size: .regular) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                ApexActionButton("保存", icon: "checkmark", tint: ApexStyle.accent, size: .regular, isProminent: true) { onSave() }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ApexStyle.s4)
        .frame(minWidth: 380, idealWidth: 460, maxWidth: 560, minHeight: 280, idealHeight: 350, maxHeight: 480)
        .onExitCommand { onCancel() }
        .background(
            Button("") { onCancel() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

private struct QuickSnippetPill: View {
    let snippet: Snippet
    let onTrigger: () -> Void
    let onAlternateRun: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTrigger) {
            HStack(spacing: 4) {
                if !snippet.extractVariables().isEmpty {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9))
                        .foregroundColor(ApexStyle.accent)
                }
                Text(snippet.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .fill(isHovered ? ApexStyle.surface : ApexStyle.subtleSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .stroke(isHovered ? ApexStyle.accent.opacity(0.4) : ApexStyle.border.opacity(0.7), lineWidth: 0.75)
            )
            .shadow(color: isHovered ? Color.black.opacity(0.06) : Color.clear, radius: 2, x: 0, y: 1)
            .foregroundColor(isHovered ? ApexStyle.primary : ApexStyle.primary.opacity(0.85))
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(ApexStyle.springSnappy, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("\(snippet.title)\n命令：\(snippet.command)\n\(snippet.autoExecute ? "点击立即执行" : "点击填入命令行（需确认回车）")")
        .accessibilityLabel("\(snippet.title)，\(snippet.autoExecute ? "点击立即执行" : "点击填入命令行")")
        .accessibilityHint(snippet.extractVariables().isEmpty ? "执行命令 \(snippet.command)" : "将弹出变量填写窗口")
        .contextMenu {
            Button(snippet.autoExecute ? "仅填入命令行 (不自动回车)" : "立即执行 (附带回车)") {
                onAlternateRun()
            }
            Button("编辑快捷命令...") {
                onEdit()
            }
            Button("复制快捷命令 (副本)") {
                onDuplicate()
            }
            Divider()
            Button("删除快捷命令", role: .destructive) {
                onDelete()
            }
        }
    }
}

