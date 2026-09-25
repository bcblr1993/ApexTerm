import SwiftUI
import ApexCore

/// Native macOS Sidebar with session tree, folders, tags, quick snippets, and full Chinese localization
public struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @Binding var selectedSession: Session?
    let onConnect: (Session) -> Void
    let onRunSnippet: (Snippet) -> Void
    
    @State private var searchFilter = ""
    @State private var showingAddSheet = false
    @State private var editingSession: Session?
    
    public init(
        store: SessionStore,
        selectedSession: Binding<Session?>,
        onConnect: @escaping (Session) -> Void,
        onRunSnippet: @escaping (Snippet) -> Void
    ) {
        self.store = store
        self._selectedSession = selectedSession
        self.onConnect = onConnect
        self.onRunSnippet = onRunSnippet
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Search and header
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    TextField(L10n.searchPlaceholder, text: $searchFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                
                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help(L10n.addSessionHelp)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            
            Divider()
            
            // Session tree
            List {
                Section(header: Label(L10n.sessionsHeader, systemImage: "server.rack").font(.caption).fontWeight(.semibold)) {
                    ForEach(groupedFolders, id: \.self) { folder in
                        DisclosureGroup(
                            isExpanded: .constant(true),
                            content: {
                                ForEach(sessionsInFolder(folder)) { session in
                                    SessionRow(
                                        session: session,
                                        isSelected: selectedSession?.id == session.id,
                                        onConnect: { onConnect(session) }
                                    )
                                    .contextMenu {
                                        Button(L10n.connectAction) {
                                            onConnect(session)
                                        }
                                        Button(L10n.editSessionAction) {
                                            editingSession = session
                                        }
                                        Divider()
                                        Button(L10n.duplicateSessionAction) {
                                            var dup = session
                                            dup.id = UUID()
                                            dup.name += " \(L10n.copyTag)"
                                            store.addSession(dup)
                                        }
                                        Button(L10n.deleteSessionAction, role: .destructive) {
                                            store.deleteSession(id: session.id)
                                        }
                                    }
                                }
                            },
                            label: {
                                HStack {
                                    Image(systemName: folderIcon(for: folder))
                                        .foregroundColor(.secondary)
                                    Text(folder)
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text("\(sessionsInFolder(folder).count)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.06))
                                        .cornerRadius(4)
                                }
                            }
                        )
                    }
                }
                
                Section(header: Label(L10n.quickCommandsHeader, systemImage: "bolt.fill").font(.caption).fontWeight(.semibold)) {
                    ForEach(store.snippets) { snippet in
                        HStack {
                            Image(systemName: "terminal")
                                .font(.system(size: 10))
                                .foregroundColor(.cyan)
                            Text(snippet.title)
                                .font(.system(size: 11))
                            Spacer()
                            Button(L10n.runCommandAction) {
                                onRunSnippet(snippet)
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.mini)
                            .font(.system(size: 10))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(isPresented: $showingAddSheet) {
            SessionEditModal(session: nil) { newSession in
                store.addSession(newSession)
            }
        }
        .sheet(item: $editingSession) { session in
            SessionEditModal(session: session) { updated in
                store.updateSession(updated)
            }
        }
    }
    
    private var groupedFolders: [String] {
        var set = Set(store.folders)
        for s in store.sessions {
            if let f = s.folder, !f.isEmpty {
                set.insert(f)
            }
        }
        if set.isEmpty {
            set.insert(L10n.generalFolder)
        }
        return Array(set).sorted()
    }
    
    private func sessionsInFolder(_ folder: String) -> [Session] {
        store.sessions.filter {
            let matchesFolder = ($0.folder ?? L10n.generalFolder) == folder
            if searchFilter.isEmpty { return matchesFolder }
            let matchesSearch = $0.name.localizedCaseInsensitiveContains(searchFilter) ||
                                $0.host.localizedCaseInsensitiveContains(searchFilter) ||
                                $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(searchFilter) })
            return matchesFolder && matchesSearch
        }
    }
    
    private func folderIcon(for folder: String) -> String {
        switch folder {
        case "生产环境", "Production": return "flame.fill"
        case "测试环境", "Staging": return "testtube.2"
        case "数据库", "Database": return "cylinder.split.1x2.fill"
        default: return "folder.fill"
        }
    }
}

struct SessionRow: View {
    let session: Session
    let isSelected: Bool
    let onConnect: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: session.colorHex ?? "#0A84FF") ?? .blue)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                
                Text("\(session.username)@\(session.host)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if !session.tags.isEmpty {
                Text(session.tags[0])
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(3)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onConnect()
        }
    }
}

extension Color {
    init?(hex: String) {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") { clean.removeFirst() }
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
