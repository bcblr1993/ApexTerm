import SwiftUI
import AppKit
import ApexCore
import ApexSSH

// MARK: - Interactive Path Breadcrumb Model & View

/// Clickable path segment produced by `SFTPPathBreadcrumbParser`.
public struct SFTPPathSegment: Identifiable, Equatable, Sendable {
    public var id: String { targetPath }
    public let title: String
    public let targetPath: String

    public init(title: String, targetPath: String) {
        self.title = title
        self.targetPath = targetPath
    }
}

/// Pure path parser turning POSIX or `~`-prefixed paths into clickable breadcrumb segments.
public enum SFTPPathBreadcrumbParser: Sendable {
    public static func segments(for rawPath: String) -> [SFTPPathSegment] {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [SFTPPathSegment(title: "/", targetPath: "/")]
        }

        if trimmed == "~" || trimmed.hasPrefix("~/") {
            var result = [SFTPPathSegment(title: "~", targetPath: "~")]
            let rest = String(trimmed.dropFirst(1))
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var accumulated = "~"
            for part in parts {
                accumulated += "/\(part)"
                result.append(SFTPPathSegment(title: part, targetPath: accumulated))
            }
            return result
        }

        if trimmed.hasPrefix("/") {
            var result = [SFTPPathSegment(title: "/", targetPath: "/")]
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var accumulated = ""
            for part in parts {
                accumulated += "/\(part)"
                result.append(SFTPPathSegment(title: part, targetPath: accumulated))
            }
            return result
        }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var result: [SFTPPathSegment] = []
        var accumulated = ""
        for part in parts {
            accumulated = accumulated.isEmpty ? part : "\(accumulated)/\(part)"
            result.append(SFTPPathSegment(title: part, targetPath: accumulated))
        }
        return result.isEmpty ? [SFTPPathSegment(title: "/", targetPath: "/")] : result
    }
}

/// Interactive path bar displaying clickable breadcrumb chips with seamless switching to raw text editing.
public struct SFTPPathBreadcrumbBar: View {
    @Binding public var currentPath: String
    @Binding public var pathInput: String
    @Binding public var isEditingPath: Bool
    public var isFocused: FocusState<Bool>.Binding
    public let placeholder: String
    public let onCommitPath: (String) -> Void

    public init(
        currentPath: Binding<String>,
        pathInput: Binding<String>,
        isEditingPath: Binding<Bool>,
        isFocused: FocusState<Bool>.Binding,
        placeholder: String,
        onCommitPath: @escaping (String) -> Void
    ) {
        self._currentPath = currentPath
        self._pathInput = pathInput
        self._isEditingPath = isEditingPath
        self.isFocused = isFocused
        self.placeholder = placeholder
        self.onCommitPath = onCommitPath
    }

    public var body: some View {
        let showTextField = isEditingPath || isFocused.wrappedValue
        HStack(spacing: 4) {
            if showTextField {
                TextField(placeholder, text: $pathInput)
                    .onSubmit {
                        let target = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !target.isEmpty else {
                            pathInput = currentPath
                            isEditingPath = false
                            isFocused.wrappedValue = false
                            return
                        }
                        pathInput = target
                        if target != currentPath {
                            onCommitPath(target)
                        }
                        isEditingPath = false
                        isFocused.wrappedValue = false
                    }
                    .focused(isFocused)
                    .onExitCommand {
                        pathInput = currentPath
                        isEditingPath = false
                        isFocused.wrappedValue = false
                    }
                    .onChange(of: isFocused.wrappedValue) { _, focused in
                        if !focused && isEditingPath {
                            pathInput = currentPath
                            isEditingPath = false
                        }
                    }
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let segments = SFTPPathBreadcrumbParser.segments(for: currentPath)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(Array(segments.enumerated()), id: \.element.id) { idx, segment in
                                if idx > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(ApexStyle.secondary.opacity(0.7))
                                }
                                Button {
                                    pathInput = segment.targetPath
                                    if segment.targetPath != currentPath {
                                        onCommitPath(segment.targetPath)
                                    }
                                } label: {
                                    Text(segment.title)
                                        .font(.system(size: 11.5, weight: idx == segments.count - 1 ? .semibold : .regular, design: .monospaced))
                                        .foregroundStyle(idx == segments.count - 1 ? ApexStyle.primary : ApexStyle.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1.5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(idx == segments.count - 1 ? ApexStyle.accent.opacity(0.10) : Color.clear)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("跳转至 \(segment.targetPath)")
                                .id(segment.id)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .onChange(of: currentPath) { _, newPath in
                        if let last = SFTPPathBreadcrumbParser.segments(for: newPath).last {
                            proxy.scrollTo(last.id, anchor: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: 12, height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        beginEditing()
                    }

                ApexIconButton(
                    icon: "pencil",
                    label: "编辑路径",
                    size: 20,
                    iconSize: 10
                ) {
                    beginEditing()
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 80, maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                .fill(ApexStyle.subtleSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                .stroke(
                    showTextField ? ApexStyle.accent.opacity(0.85) : ApexStyle.border.opacity(0.65),
                    lineWidth: showTextField ? 1.25 : 0.75
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !showTextField {
                beginEditing()
            }
        }
    }

    private func beginEditing() {
        pathInput = currentPath
        isEditingPath = true
        isFocused.wrappedValue = true
    }
}

// MARK: - Directory Diff Model & Computation

public enum SFTPDirectoryDiffKind: String, CaseIterable, Identifiable, Sendable {
    case newLocal = "仅本地"
    case newRemote = "仅远端"
    case modified = "已变更"
    case identical = "一致"

    public var id: String { rawValue }
}

public enum SFTPDirectoryDiffReason: Equatable, Sendable {
    case onlyInLocal
    case onlyInRemote
    case typeMismatch
    case sizeChanged(localSize: UInt64, remoteSize: UInt64)
    case timestampChanged(localDate: Date, remoteDate: Date)
    case identical

    public var label: String {
        switch self {
        case .onlyInLocal: return "本地新增（远端缺失）"
        case .onlyInRemote: return "远端独有（本地缺失）"
        case .typeMismatch: return "类型不一致（文件/目录）"
        case .sizeChanged(let l, let r): return "大小不同 (\(l) B vs \(r) B)"
        case .timestampChanged(let l, let r):
            return l > r ? "本地更新" : "远端更新"
        case .identical: return "内容属性一致"
        }
    }
}

public struct SFTPDirectoryDiffEntry: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let kind: SFTPDirectoryDiffKind
    public let reason: SFTPDirectoryDiffReason
    public let localItem: SFTPItem?
    public let remoteItem: SFTPItem?

    public init(
        name: String,
        kind: SFTPDirectoryDiffKind,
        reason: SFTPDirectoryDiffReason,
        localItem: SFTPItem?,
        remoteItem: SFTPItem?
    ) {
        self.name = name
        self.kind = kind
        self.reason = reason
        self.localItem = localItem
        self.remoteItem = remoteItem
    }
}

public enum SFTPDirectoryDiffFilter: String, CaseIterable, Identifiable, Sendable {
    case allDifferences = "全部差异"
    case newLocal = "仅本地"
    case newRemote = "仅远端"
    case modified = "已变更"
    case allIncludingIdentical = "含一致"

    public var id: String { rawValue }
}

public enum SFTPDirectoryDiffComputer: Sendable {
    public static func computeDiff(
        localItems: [SFTPItem],
        remoteItems: [SFTPItem],
        includeHidden: Bool = true,
        timestampToleranceSeconds: TimeInterval = 2.0
    ) -> [SFTPDirectoryDiffEntry] {
        func normalize(_ items: [SFTPItem]) -> [String: SFTPItem] {
            var map: [String: SFTPItem] = [:]
            for item in items where !item.isParentNavigationEntry && item.name != "." {
                if !includeHidden && item.name.hasPrefix(".") { continue }
                map[item.name] = item
            }
            return map
        }

        let localByName = normalize(localItems)
        let remoteByName = normalize(remoteItems)
        let allNames = Set(localByName.keys).union(remoteByName.keys)

        var entries: [SFTPDirectoryDiffEntry] = []
        entries.reserveCapacity(allNames.count)

        for name in allNames {
            let local = localByName[name]
            let remote = remoteByName[name]
            switch (local, remote) {
            case (.some(let l), .none):
                entries.append(SFTPDirectoryDiffEntry(
                    name: name,
                    kind: .newLocal,
                    reason: .onlyInLocal,
                    localItem: l,
                    remoteItem: nil
                ))
            case (.none, .some(let r)):
                entries.append(SFTPDirectoryDiffEntry(
                    name: name,
                    kind: .newRemote,
                    reason: .onlyInRemote,
                    localItem: nil,
                    remoteItem: r
                ))
            case (.some(let l), .some(let r)):
                if l.isDirectory != r.isDirectory {
                    entries.append(SFTPDirectoryDiffEntry(
                        name: name,
                        kind: .modified,
                        reason: .typeMismatch,
                        localItem: l,
                        remoteItem: r
                    ))
                } else if !l.isDirectory && l.size != r.size {
                    entries.append(SFTPDirectoryDiffEntry(
                        name: name,
                        kind: .modified,
                        reason: .sizeChanged(localSize: l.size, remoteSize: r.size),
                        localItem: l,
                        remoteItem: r
                    ))
                } else if !l.isDirectory && abs(l.modificationDate.timeIntervalSince(r.modificationDate)) > timestampToleranceSeconds {
                    entries.append(SFTPDirectoryDiffEntry(
                        name: name,
                        kind: .modified,
                        reason: .timestampChanged(localDate: l.modificationDate, remoteDate: r.modificationDate),
                        localItem: l,
                        remoteItem: r
                    ))
                } else {
                    entries.append(SFTPDirectoryDiffEntry(
                        name: name,
                        kind: .identical,
                        reason: .identical,
                        localItem: l,
                        remoteItem: r
                    ))
                }
            case (.none, .none):
                break
            }
        }

        func sortRank(_ kind: SFTPDirectoryDiffKind) -> Int {
            switch kind {
            case .newLocal: return 0
            case .newRemote: return 1
            case .modified: return 2
            case .identical: return 3
            }
        }

        return entries.sorted { lhs, rhs in
            let r1 = sortRank(lhs.kind)
            let r2 = sortRank(rhs.kind)
            if r1 != r2 { return r1 < r2 }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public static func filter(
        _ entries: [SFTPDirectoryDiffEntry],
        by filter: SFTPDirectoryDiffFilter
    ) -> [SFTPDirectoryDiffEntry] {
        switch filter {
        case .allDifferences:
            return entries.filter { $0.kind != .identical }
        case .newLocal:
            return entries.filter { $0.kind == .newLocal }
        case .newRemote:
            return entries.filter { $0.kind == .newRemote }
        case .modified:
            return entries.filter { $0.kind == .modified }
        case .allIncludingIdentical:
            return entries
        }
    }
}

// MARK: - Directory Diff Preview Sheet

public struct SFTPDirectoryDiffSheet: View {
    public let localDirectory: String
    public let remoteDirectory: String
    public let entries: [SFTPDirectoryDiffEntry]
    public let onUploadItems: ([SFTPItem]) -> Void
    public let onDownloadItems: ([SFTPItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var filter: SFTPDirectoryDiffFilter = .allDifferences

    public init(
        localDirectory: String,
        remoteDirectory: String,
        entries: [SFTPDirectoryDiffEntry],
        onUploadItems: @escaping ([SFTPItem]) -> Void,
        onDownloadItems: @escaping ([SFTPItem]) -> Void
    ) {
        self.localDirectory = localDirectory
        self.remoteDirectory = remoteDirectory
        self.entries = entries
        self.onUploadItems = onUploadItems
        self.onDownloadItems = onDownloadItems
    }

    private var filteredEntries: [SFTPDirectoryDiffEntry] {
        SFTPDirectoryDiffComputer.filter(entries, by: filter)
    }

    private var newLocalCount: Int { entries.filter { $0.kind == .newLocal }.count }
    private var newRemoteCount: Int { entries.filter { $0.kind == .newRemote }.count }
    private var modifiedCount: Int { entries.filter { $0.kind == .modified }.count }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ApexStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("本地与远端目录差异预览")
                        .font(.system(size: 15, weight: .semibold))
                    Text("本地 \(localDirectory)  ⇄  远端 \(remoteDirectory)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ApexStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                ApexIconButton(icon: "xmark", label: "关闭差异预览", size: 24, iconSize: 11) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 10)
            .background(ApexStyle.surface)

            Divider()

            HStack(spacing: 10) {
                Picker("差异过滤", selection: $filter) {
                    ForEach(SFTPDirectoryDiffFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)

                Spacer()

                diffPill("仅本地 \(newLocalCount)", color: ApexStyle.accent)
                diffPill("仅远端 \(newRemoteCount)", color: ApexStyle.success)
                diffPill("已变更 \(modifiedCount)", color: ApexStyle.warning)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 8)
            .background(ApexStyle.subtleSurface.opacity(0.65))

            Divider()

            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "当前筛选下无差异项",
                    systemImage: "checkmark.seal",
                    description: Text("本地与远端目录在该分类下保持一致")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredEntries) { entry in
                            diffRow(entry)
                        }
                    }
                    .padding(.horizontal, ApexStyle.s4)
                    .padding(.vertical, 10)
                }
            }

            Divider()

            HStack(spacing: 8) {
                let uploadCandidates = entries.compactMap { entry -> SFTPItem? in
                    guard entry.kind == .newLocal || entry.kind == .modified else { return nil }
                    return entry.localItem
                }.filter { !$0.isDirectory }

                let downloadCandidates = entries.compactMap { entry -> SFTPItem? in
                    guard entry.kind == .newRemote || entry.kind == .modified else { return nil }
                    return entry.remoteItem
                }.filter { !$0.isDirectory }

                if !uploadCandidates.isEmpty {
                    ApexActionButton("上传新增/变更 (\(uploadCandidates.count))", icon: "arrow.up", tint: ApexStyle.accent, size: .small) {
                        onUploadItems(uploadCandidates)
                        dismiss()
                    }
                }

                if !downloadCandidates.isEmpty {
                    ApexActionButton("下载远端新增/变更 (\(downloadCandidates.count))", icon: "arrow.down", tint: ApexStyle.success, size: .small) {
                        onDownloadItems(downloadCandidates)
                        dismiss()
                    }
                }

                Spacer()

                ApexActionButton("关闭", tint: ApexStyle.secondary, size: .small) {
                    dismiss()
                }
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 8)
            .background(ApexStyle.surface)
        }
        .frame(minWidth: 720, idealWidth: 840, minHeight: 460, idealHeight: 540)
        .background(ApexStyle.surface)
    }

    private func diffPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    private func diffRow(_ entry: SFTPDirectoryDiffEntry) -> some View {
        let tint: Color = switch entry.kind {
        case .newLocal: ApexStyle.accent
        case .newRemote: ApexStyle.success
        case .modified: ApexStyle.warning
        case .identical: ApexStyle.secondary
        }
        return HStack(spacing: 10) {
            Image(systemName: (entry.localItem?.isDirectory ?? entry.remoteItem?.isDirectory ?? false) ? "folder.fill" : "doc.fill")
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(ApexStyle.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.kind.rawValue)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                }
                Text(entry.reason.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ApexStyle.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("本地: \(entry.localItem?.formattedSize ?? "—")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ApexStyle.secondary)
                Text("远端: \(entry.remoteItem?.formattedSize ?? "—")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(ApexStyle.secondary)
            }

            if let local = entry.localItem, !local.isDirectory, entry.kind != .identical {
                ApexIconButton(icon: "arrow.up.circle.fill", label: "上传 \(entry.name)", size: 22, iconSize: 12, tint: ApexStyle.accent) {
                    onUploadItems([local])
                }
            }
            if let remote = entry.remoteItem, !remote.isDirectory, entry.kind != .identical {
                ApexIconButton(icon: "arrow.down.circle.fill", label: "下载 \(entry.name)", size: 22, iconSize: 12, tint: ApexStyle.success) {
                    onDownloadItems([remote])
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(ApexStyle.subtleSurface.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(ApexStyle.border.opacity(0.45), lineWidth: 0.75)
        )
    }
}

// MARK: - Local Dual-Pane Browser View

/// Side-by-side local filesystem browser powered by `LocalTerminalSession.listDirectory(path:)`.
public struct LocalDualPaneView: View {
    @Binding public var localPath: String
    public let remotePath: String
    public let remoteItems: [SFTPItem]
    public let isRemoteConnected: Bool
    public let hasSelectedRemoteItems: Bool
    public let onUploadURLs: ([URL]) -> Void
    public let onDownloadSelectedRemoteToLocal: (URL) -> Void
    public let onDownloadRemoteItemsToLocal: ([SFTPItem], URL) -> Void

    @State private var localItems: [SFTPItem] = []
    @State private var selectedPaths: Set<String> = []
    @State private var pathInput: String = ""
    @State private var isEditingPath: Bool = false
    @FocusState private var isPathFocused: Bool
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var showHidden: Bool = false
    @State private var isShowingDiffSheet: Bool = false
    @State private var diffEntries: [SFTPDirectoryDiffEntry] = []

    private let localSession = LocalTerminalSession()

    public init(
        localPath: Binding<String>,
        remotePath: String,
        remoteItems: [SFTPItem],
        isRemoteConnected: Bool,
        hasSelectedRemoteItems: Bool,
        onUploadURLs: @escaping ([URL]) -> Void,
        onDownloadSelectedRemoteToLocal: @escaping (URL) -> Void,
        onDownloadRemoteItemsToLocal: @escaping ([SFTPItem], URL) -> Void
    ) {
        self._localPath = localPath
        self.remotePath = remotePath
        self.remoteItems = remoteItems
        self.isRemoteConnected = isRemoteConnected
        self.hasSelectedRemoteItems = hasSelectedRemoteItems
        self.onUploadURLs = onUploadURLs
        self.onDownloadSelectedRemoteToLocal = onDownloadSelectedRemoteToLocal
        self.onDownloadRemoteItemsToLocal = onDownloadRemoteItemsToLocal
    }

    private var visibleItems: [SFTPItem] {
        localItems.filter { showHidden || !$0.name.hasPrefix(".") }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ApexStyle.accent)
                Text("本地")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ApexStyle.primary)
                    .fixedSize(horizontal: true, vertical: false)

                SFTPPathBreadcrumbBar(
                    currentPath: $localPath,
                    pathInput: $pathInput,
                    isEditingPath: $isEditingPath,
                    isFocused: $isPathFocused,
                    placeholder: "本地路径..."
                ) { target in
                    navigate(to: target)
                }

                ApexIconButton(icon: "arrow.up", label: "本地上级目录", size: 22, iconSize: 10) {
                    navigateUp()
                }
                ApexIconButton(icon: "house", label: "前往主目录 (~)", size: 22, iconSize: 10) {
                    navigate(to: "~")
                }
                ApexIconButton(icon: "arrow.clockwise", label: "刷新本地目录", size: 22, iconSize: 10) {
                    loadLocalDirectory(localPath)
                }
                ApexIconButton(
                    icon: showHidden ? "eye.fill" : "eye.slash",
                    label: showHidden ? "隐藏本地点文件" : "显示本地点文件",
                    size: 22,
                    iconSize: 10,
                    isSelected: showHidden
                ) {
                    showHidden.toggle()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ApexStyle.subtleSurface.opacity(0.7))

            Divider()

            HStack(spacing: 6) {
                let selectedLocalURLs = visibleItems
                    .filter { selectedPaths.contains($0.path) }
                    .map { URL(fileURLWithPath: $0.path) }

                ApexActionButton(
                    "上传选中 (\(selectedLocalURLs.count))",
                    icon: "arrow.right.circle",
                    tint: ApexStyle.accent,
                    size: .small
                ) {
                    onUploadURLs(selectedLocalURLs)
                }
                .disabled(!isRemoteConnected || selectedLocalURLs.isEmpty)

                ApexActionButton(
                    "下载到此目录",
                    icon: "arrow.left.circle",
                    tint: ApexStyle.success,
                    size: .small
                ) {
                    let expanded = LocalTerminalSession.expandPath(localPath)
                    onDownloadSelectedRemoteToLocal(URL(fileURLWithPath: expanded, isDirectory: true))
                }
                .disabled(!isRemoteConnected || !hasSelectedRemoteItems)

                Spacer()

                ApexActionButton(
                    "目录对比",
                    icon: "arrow.left.arrow.right",
                    tint: ApexStyle.secondary,
                    size: .small
                ) {
                    diffEntries = SFTPDirectoryDiffComputer.computeDiff(
                        localItems: visibleItems,
                        remoteItems: remoteItems,
                        includeHidden: showHidden
                    )
                    isShowingDiffSheet = true
                }
                .disabled(!isRemoteConnected)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(ApexStyle.surface)

            Divider()

            if isLoading && localItems.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("正在读取本地目录…")
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView {
                    Label("无法读取本地目录", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(loadError).lineLimit(2)
                } actions: {
                    Button("重试") { loadLocalDirectory(localPath) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleItems.isEmpty {
                ContentUnavailableView("本地文件夹为空", systemImage: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visibleItems) { item in
                            localRow(item)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ApexStyle.surface)
        .onAppear {
            pathInput = localPath
            loadLocalDirectory(localPath)
        }
        .onChange(of: localPath) { _, newPath in
            if !isEditingPath {
                pathInput = newPath
            }
            loadLocalDirectory(newPath)
        }
        .sheet(isPresented: $isShowingDiffSheet) {
            SFTPDirectoryDiffSheet(
                localDirectory: localPath,
                remoteDirectory: remotePath,
                entries: diffEntries,
                onUploadItems: { items in
                    let urls = items.map { URL(fileURLWithPath: $0.path) }
                    onUploadURLs(urls)
                },
                onDownloadItems: { items in
                    let expanded = LocalTerminalSession.expandPath(localPath)
                    onDownloadRemoteItemsToLocal(items, URL(fileURLWithPath: expanded, isDirectory: true))
                }
            )
            .apexTheme()
        }
    }

    private func localRow(_ item: SFTPItem) -> some View {
        let isSelected = selectedPaths.contains(item.path)
        return HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(item.isDirectory ? ApexStyle.accent : ApexStyle.secondary)
                .frame(width: 15, alignment: .center)

            Text(item.name)
                .font(.system(size: 12))
                .foregroundStyle(ApexStyle.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            Text(item.formattedSize)
                .font(.caption.monospacedDigit())
                .foregroundStyle(ApexStyle.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? ApexStyle.accent.opacity(0.16) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isDirectory {
                navigate(to: item.path)
            } else if isRemoteConnected {
                onUploadURLs([URL(fileURLWithPath: item.path)])
            }
        }
        .onTapGesture(count: 1) {
            let cmdPressed = NSEvent.modifierFlags.contains(.command)
            if cmdPressed {
                if isSelected {
                    selectedPaths.remove(item.path)
                } else {
                    selectedPaths.insert(item.path)
                }
            } else {
                selectedPaths = [item.path]
            }
        }
        .contextMenu {
            if item.isDirectory {
                Button("打开目录") {
                    navigate(to: item.path)
                }
            }
            if isRemoteConnected {
                Button("上传至远端当前目录") {
                    onUploadURLs([URL(fileURLWithPath: item.path)])
                }
            }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        }
    }

    private func navigate(to path: String) {
        let expanded = LocalTerminalSession.expandPath(path)
        localPath = expanded
        pathInput = expanded
    }

    private func navigateUp() {
        let expanded = LocalTerminalSession.expandPath(localPath)
        let parent = (expanded as NSString).deletingLastPathComponent
        navigate(to: parent.isEmpty ? "/" : parent)
    }

    private func loadLocalDirectory(_ path: String) {
        isLoading = true
        loadError = nil
        selectedPaths = []
        let expanded = LocalTerminalSession.expandPath(path)
        Task {
            do {
                let fetched = try await localSession.listDirectory(path: expanded)
                await MainActor.run {
                    self.localItems = fetched
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.localItems = []
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}
