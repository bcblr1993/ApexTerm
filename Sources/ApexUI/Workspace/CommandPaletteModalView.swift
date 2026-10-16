import SwiftUI
import ApexCore

/// Spotlight-style Command Palette modal overlay for quick fuzzy navigation and action triggering
public struct CommandPaletteModalView: View {
    @ObservedObject public var store: SessionStore
    @Binding public var isPresented: Bool
    public let onSelectAction: (CommandPaletteAction) -> Void
    
    @State private var searchQuery: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isInputFocused: Bool
    
    public init(
        store: SessionStore,
        isPresented: Binding<Bool>,
        onSelectAction: @escaping (CommandPaletteAction) -> Void
    ) {
        self.store = store
        self._isPresented = isPresented
        self.onSelectAction = onSelectAction
    }
    
    private var allItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        
        // 1. App Actions
        for action in CommandPaletteAppAction.allCases {
            items.append(
                CommandPaletteItem(
                    title: action.title,
                    subtitle: "功能操作",
                    category: .action,
                    iconName: action.iconName,
                    shortcutHint: action.shortcutHint,
                    action: .executeAppAction(action)
                )
            )
        }
        
        // 2. Sessions
        for s in store.sessions {
            let sub = s.isLocal ? "本机 Shell (\(s.username))" : "\(s.username)@\(s.host):\(s.port)"
            items.append(
                CommandPaletteItem(
                    title: s.name,
                    subtitle: sub,
                    category: .session,
                    iconName: s.isLocal ? "laptopcomputer" : "server.rack",
                    shortcutHint: nil,
                    action: .connectSession(s.id)
                )
            )
        }
        
        // 3. SFTP Bookmarks
        for b in SFTPBookmarkManager.shared.allBookmarks {
            items.append(
                CommandPaletteItem(
                    title: b.name,
                    subtitle: b.path,
                    category: .bookmark,
                    iconName: b.iconName,
                    shortcutHint: nil,
                    action: .openBookmark(b.path)
                )
            )
        }
        
        // 4. Snippets
        for snip in store.snippets {
            items.append(
                CommandPaletteItem(
                    title: snip.title,
                    subtitle: snip.command,
                    category: .snippet,
                    iconName: "terminal",
                    shortcutHint: nil,
                    action: .runSnippet(snip)
                )
            )
        }
        
        return items
    }
    
    private var filteredItems: [CommandPaletteItem] {
        CommandPaletteSearchEngine.search(items: allItems, query: searchQuery, maxResults: 40)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Search Input Header
            HStack(spacing: ApexStyle.s3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(ApexStyle.accent)
                
                TextField("搜索会话、SFTP路径、快捷命令或功能... (可输入 > @ / # 快速过滤)", text: $searchQuery)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .onChange(of: searchQuery) { _, _ in
                        selectedIndex = 0
                    }
                    .onSubmit {
                        executeCurrentSelection()
                    }
                
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(ApexStyle.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Text("⎋ ESC")
                    .apexKeycap()
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 12)
            .background(ApexStyle.surface.opacity(0.85))
            
            Divider()
            
            // Search Results List
            if filteredItems.isEmpty {
                VStack(spacing: ApexStyle.s2) {
                    Spacer()
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(ApexStyle.secondary.opacity(0.6))
                    Text("未找到匹配项")
                        .font(.subheadline)
                        .foregroundColor(ApexStyle.secondary)
                    Spacer()
                }
                .frame(height: 220)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                ItemRowView(
                                    item: item,
                                    isSelected: index == selectedIndex,
                                    onSelect: {
                                        selectedIndex = index
                                        executeCurrentSelection()
                                    }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selectedIndex) { _, newIndex in
                        if filteredItems.indices.contains(newIndex) {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                proxy.scrollTo(filteredItems[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            // Footer Hints
            HStack(spacing: ApexStyle.s4) {
                HStack(spacing: 4) {
                    Text("↑↓").font(.caption2.monospaced()).bold()
                    Text("选择").font(.caption2)
                }
                HStack(spacing: 4) {
                    Text("↵").font(.caption2.monospaced()).bold()
                    Text("确认执行").font(.caption2)
                }
                HStack(spacing: 4) {
                    Text("> 功能").font(.caption2.monospaced())
                    Text("@ 主机").font(.caption2.monospaced())
                    Text("/ 目录").font(.caption2.monospaced())
                    Text("# 命令").font(.caption2.monospaced())
                }
                .foregroundColor(ApexStyle.secondary.opacity(0.8))
                
                Spacer()
                
                Text("共 \(filteredItems.count) 条结果")
                    .font(.caption2)
                    .foregroundColor(ApexStyle.secondary)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 8)
            .background(ApexStyle.subtleSurface.opacity(0.5))
        }
        .frame(width: 620)
        .apexGlassCard(cornerRadius: 14, material: .regularMaterial, borderColor: Color.primary.opacity(0.12), shadowRadius: 28)
        .onAppear {
            isInputFocused = true
            selectedIndex = 0
        }
        .background(
            // Key listeners for Up / Down / Esc
            Group {
                Button("") { moveSelection(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { moveSelection(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
    }
    
    private func moveSelection(by delta: Int) {
        guard !filteredItems.isEmpty else { return }
        let next = selectedIndex + delta
        if next < 0 {
            selectedIndex = filteredItems.count - 1
        } else if next >= filteredItems.count {
            selectedIndex = 0
        } else {
            selectedIndex = next
        }
    }
    
    private func executeCurrentSelection() {
        guard filteredItems.indices.contains(selectedIndex) else { return }
        let item = filteredItems[selectedIndex]
        isPresented = false
        onSelectAction(item.action)
    }
}

private struct ItemRowView: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: ApexStyle.s3) {
                // Category Icon
                Image(systemName: item.iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 26, height: 26)
                    .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: ApexStyle.badgeRadius))
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(ApexStyle.primary)
                            .lineLimit(1)
                        
                        Text(item.category.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(categoryBadgeColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundColor(categoryBadgeColor)
                    }
                    
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(ApexStyle.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                if let hint = item.shortcutHint {
                    Text(hint)
                        .apexKeycap()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? ApexStyle.accent.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .stroke(isSelected ? ApexStyle.accent.opacity(0.4) : Color.clear, lineWidth: 0.75)
            )
            .animation(ApexStyle.springSnappy, value: isSelected)
        }
        .buttonStyle(.plain)
    }
    
    private var iconColor: Color {
        switch item.category {
        case .session: return .blue
        case .bookmark: return .orange
        case .snippet: return .green
        case .action: return ApexStyle.accent
        }
    }
    
    private var categoryBadgeColor: Color {
        switch item.category {
        case .session: return .blue
        case .bookmark: return .orange
        case .snippet: return .green
        case .action: return ApexStyle.accent
        }
    }
}
