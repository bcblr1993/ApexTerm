import SwiftUI
import ApexCore

/// Horizontal collapsible quick command action bar docked at the bottom of the terminal workspace
public struct QuickCommandBarView: View {
    @ObservedObject public var store: SessionStore
    public let onExecuteCommand: (String) -> Void
    @Binding public var isVisible: Bool
    
    @State private var selectedCategory: String = "全部"
    @State private var snippetWithVariables: Snippet? = nil
    @State private var variableValues: [String: String] = [:]
    @State private var isAddSheetPresented: Bool = false
    
    // New snippet form state
    @State private var newTitle: String = ""
    @State private var newCommand: String = ""
    @State private var newCategory: String = "自定义"
    
    public init(
        store: SessionStore,
        isVisible: Binding<Bool>,
        onExecuteCommand: @escaping (String) -> Void
    ) {
        self.store = store
        self._isVisible = isVisible
        self.onExecuteCommand = onExecuteCommand
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
                // Category Selector / Pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ApexStyle.sCompact) {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(ApexStyle.accent)
                            Text("快捷命令")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(ApexStyle.primary)
                        }
                        .padding(.trailing, 4)
                        
                        ForEach(allCategories, id: \.self) { cat in
                            Button {
                                selectedCategory = cat
                            } label: {
                                Text(cat)
                                    .font(.system(size: 11, weight: selectedCategory == cat ? .semibold : .regular))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        selectedCategory == cat
                                            ? ApexStyle.accent.opacity(0.18)
                                            : ApexStyle.surface,
                                        in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius)
                                    )
                                    .foregroundColor(selectedCategory == cat ? ApexStyle.accent : ApexStyle.secondary)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: ApexStyle.badgeRadius)
                                            .stroke(selectedCategory == cat ? ApexStyle.accent.opacity(0.4) : ApexStyle.border.opacity(0.5), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Divider().frame(height: 14)
                        
                        // Snippet Action Pills
                        ForEach(filteredSnippets) { snippet in
                            Button {
                                triggerSnippet(snippet)
                            } label: {
                                HStack(spacing: 4) {
                                    if !snippet.extractVariables().isEmpty {
                                        Image(systemName: "slider.horizontal.3")
                                            .font(.system(size: 9))
                                            .foregroundColor(ApexStyle.accent)
                                    }
                                    Text(snippet.title)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                                .overlay(
                                    RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                                        .stroke(ApexStyle.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("\(snippet.title)\n命令：\(snippet.command)")
                        }
                        
                        // + Add Custom Snippet Button
                        Button {
                            newTitle = ""
                            newCommand = ""
                            newCategory = selectedCategory == "全部" ? "自定义" : selectedCategory
                            isAddSheetPresented = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                Text("添加")
                                    .font(.system(size: 11))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundColor(ApexStyle.secondary)
                            .background(ApexStyle.surface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                                    .stroke(ApexStyle.border.opacity(0.6), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("添加新的常用快捷命令")
                    }
                    .padding(.horizontal, ApexStyle.s4)
                    .padding(.vertical, 6)
                }
                
                Spacer(minLength: 4)
                
                // Hide bar button
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isVisible = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(ApexStyle.secondary)
                        .padding(5)
                        .background(ApexStyle.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .help("隐藏快捷命令栏 (⌘⇧B)")
                .padding(.trailing, ApexStyle.s4)
            }
            .frame(height: 36)
            .background(ApexStyle.subtleSurface.opacity(0.6))
        }
        .sheet(item: $snippetWithVariables) { snippet in
            VariableInputSheet(
                snippet: snippet,
                variableValues: $variableValues,
                onConfirm: { resolved in
                    onExecuteCommand(resolved + "\n")
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
                title: $newTitle,
                command: $newCommand,
                category: $newCategory,
                onSave: {
                    let s = Snippet(
                        title: newTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                        command: newCommand.trimmingCharacters(in: .whitespacesAndNewlines),
                        category: newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "自定义" : newCategory
                    )
                    store.addSnippet(s)
                    isAddSheetPresented = false
                },
                onCancel: {
                    isAddSheetPresented = false
                }
            )
            .apexTheme()
        }
    }
    
    private func triggerSnippet(_ snippet: Snippet) {
        let vars = snippet.extractVariables()
        if vars.isEmpty {
            let resolved = snippet.resolvedCommand(context: [:])
            onExecuteCommand(resolved + "\n")
        } else {
            // Preset known variables or clear
            var initialDict: [String: String] = [:]
            for v in vars {
                initialDict[v] = ""
            }
            variableValues = initialDict
            snippetWithVariables = snippet
        }
    }
}

/// Modal dialog for prompting variable values in dynamic snippets like `{{service}}` or `{{container}}`
private struct VariableInputSheet: View {
    let snippet: Snippet
    @Binding var variableValues: [String: String]
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    
    private var variables: [String] {
        snippet.extractVariables()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s4) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.title)
                        .font(.headline)
                    Text("请为以下变量输入参数值")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("原始命令模板：")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                Text(snippet.command)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ApexStyle.surface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: ApexStyle.controlRadius).stroke(ApexStyle.border, lineWidth: 1))
            }
            
            VStack(spacing: ApexStyle.s3) {
                ForEach(variables, id: \.self) { v in
                    HStack(spacing: ApexStyle.s2) {
                        Text(v)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(ApexStyle.accent)
                            .frame(width: 120, alignment: .trailing)
                        
                        TextField("输入 \(v)...", text: Binding(
                            get: { variableValues[v] ?? "" },
                            set: { variableValues[v] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            submitIfValid()
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            
            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("执行 (↵)") {
                    submitIfValid()
                }
                .apexProminentButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ApexStyle.s5)
        .frame(width: 480)
    }
    
    private func submitIfValid() {
        let resolved = snippet.resolvedCommand(context: variableValues)
        onConfirm(resolved)
    }
}

/// Sheet to add a new command snippet
private struct AddSnippetSheet: View {
    @Binding var title: String
    @Binding var command: String
    @Binding var category: String
    let onSave: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: ApexStyle.s4) {
            HStack {
                Image(systemName: "plus.square.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                Text("新建快捷命令")
                    .font(.headline)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("标题")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                TextField("例如：查看 Docker 容器日志", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Shell 命令 (支持 {{var}} 动态占位符)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                TextField("例如：docker logs -f --tail 100 {{container}}", text: $command)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("分类")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(ApexStyle.secondary)
                TextField("例如：Docker、系统、运维", text: $category)
                    .textFieldStyle(.roundedBorder)
            }
            
            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { onSave() }
                    .apexProminentButton()
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ApexStyle.s5)
        .frame(width: 460)
    }
}
