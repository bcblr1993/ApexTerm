import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ApexCore
import ApexSSH
import os

public final class SFTPBatchTracker: @unchecked Sendable {
    public enum Outcome: Sendable {
        case succeeded
        case failed
        case cancelled
    }

    public struct Snapshot: Sendable {
        public let completed: Int
        public let succeeded: Int
        public let failed: Int
        public let cancelled: Int
        public let isDone: Bool
    }

    private let lock = NSLock()
    private var completed = 0
    private var succeeded = 0
    private var failed = 0
    private var cancelled = 0
    private var didFireCompletion = false
    private var completionHandlers: [@Sendable () -> Void] = []
    public let total: Int
    public init(total: Int) { self.total = total }
    public func addCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        var shouldRunImmediately = false
        lock.lock()
        if didFireCompletion || total <= 0 {
            shouldRunImmediately = true
        } else {
            completionHandlers.append(handler)
        }
        lock.unlock()
        if shouldRunImmediately {
            handler()
        }
    }
    public func record(_ outcome: Outcome) -> Snapshot {
        var handlersToRun: [@Sendable () -> Void] = []
        let snapshot: Snapshot = {
            lock.lock()
            defer { lock.unlock() }
            completed += 1
            switch outcome {
            case .succeeded: succeeded += 1
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            }
            let done = completed >= total
            if done && !didFireCompletion {
                didFireCompletion = true
                handlersToRun = completionHandlers
                completionHandlers.removeAll()
            }
            return Snapshot(
                completed: completed,
                succeeded: succeeded,
                failed: failed,
                cancelled: cancelled,
                isDone: done
            )
        }()
        for handler in handlersToRun {
            handler()
        }
        return snapshot
    }
    public func advance() -> (completed: Int, isDone: Bool) {
        let snapshot = record(.succeeded)
        return (snapshot.completed, snapshot.isDone)
    }
}

/// High-performance integrated SFTP file manager (electerm-style with OSC 7 sync and drag-and-drop upload/download)
public struct SFTPView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Binding public var currentPath: String
    @Binding public var isLinkageEnabled: Bool
    public let session: SSHSessionProtocol?
    public let connectionState: SSHConnectionState
    public let tabID: UUID?

    public enum SFTPSortField: String, CaseIterable, Sendable {
        case name
        case size
        case date
    }

    public enum SFTPSortOrder: String, CaseIterable, Sendable {
        case ascending
        case descending
    }

    public enum SFTPNoticeKind: Sendable, Equatable {
        case success
        case info
        case warning
        case error
        case cancelled
    }

    @State private var items: [SFTPItem] = []
    @State private var isLoading = false
    @State private var selectedPaths: Set<String> = []
    @State private var batchItemsToDelete: [SFTPItem]? = nil
    @State private var searchFilter = ""
    @State private var tableSortOrder = [KeyPathComparator(\SFTPItem.name)]
    @State private var displayItems: [SFTPItem] = []
    @State private var isFilterVisible = false
    @State private var pathInput = ""
    @State private var toolbarWidth: CGFloat = 0
    @State private var windowReference = WindowReference()
    @FocusState private var isPathFocused: Bool
    @FocusState private var isFilterFocused: Bool
    @State private var editingFile: SFTPItem?
    @State private var editorContent = ""
    @State private var isDropTargeted = false
    @State private var transferNotice: String?
    @State private var transferNoticeToken = UUID()
    @State private var transferNoticeKind: SFTPNoticeKind = .info
    @State private var transferNoticeIsTransferOutcome = false
    @State private var creationFailureDetails: String?
    @State private var creationFailureNotice: String?
    @State private var isShowingCreationFailure = false
    @State private var loadError: String?
    @State private var isOpeningEditor = false
    @State private var localTransferDrawerExpanded = false
    private let externalTransferDrawerExpanded: Binding<Bool>?
    private var transferDrawerExpandedBinding: Binding<Bool> {
        externalTransferDrawerExpanded ?? $localTransferDrawerExpanded
    }
    @State private var loadTask: Task<Void, Never>?
    @State private var loadGeneration: Int = 0
    
    // Sort and visibility
    @State private var showHiddenFiles = AppSettings.shared.showHiddenFiles
    @ObservedObject private var bookmarkManager = SFTPBookmarkManager.shared
    @ObservedObject private var externalEditManager = ExternalEditSessionManager.shared
    @State private var isShowingExternalEditPopover = false
    @State private var installedEditors: [ExternalEditorApp] = []
    
    // File operations state
    @State private var itemToDelete: SFTPItem?
    @State private var itemToRename: SFTPItem?
    @State private var renameText = ""
    @State private var isShowingRenameAlert = false
    @State private var itemToChmod: SFTPItem?
    @State private var chmodText = "755"
    @State private var isShowingChmodAlert = false
    @State private var newFolderName = ""
    @State private var isShowingNewFolderAlert = false
    @State private var newFileName = ""
    @State private var isShowingNewFileAlert = false
    @State private var inspectingItem: SFTPItem? = nil
    @State private var itemToSymlink: SFTPItem? = nil
    @State private var symlinkNameText = ""
    @State private var isShowingSymlinkAlert = false

    // Remote search (find / grep -F) & Archive / Extract (v1.24.0)
    @State private var isRemoteSearchVisible = false
    @State private var remoteSearchMode: SFTPSearchMode = .filename
    @State private var remoteSearchQuery = ""
    @State private var remoteSearchHits: [SFTPSearchHit] = []
    @State private var isSearchingRemote = false
    @State private var remoteSearchError: String? = nil
    @State private var remoteSearchDidReturnEmpty = false
    @State private var remoteSearchTask: Task<Void, Never>? = nil
    @FocusState private var isRemoteSearchFocused: Bool
    @State private var editorInitialLine: Int? = nil

    @State private var archiveTargetItems: [SFTPItem] = []
    @State private var archiveFormat: SFTPArchiveFormat = .tarGz
    @State private var archiveOutputName: String = ""
    @State private var isShowingArchiveAlert = false
    @State private var itemToExtract: SFTPItem? = nil
    @State private var isShowingExtractConfirm = false

    public init(
        currentPath: Binding<String>,
        isLinkageEnabled: Binding<Bool> = .constant(true),
        session: SSHSessionProtocol?,
        connectionState: SSHConnectionState = .connected,
        tabID: UUID? = nil,
        isTransferDrawerExpanded: Binding<Bool>? = nil
    ) {
        self._currentPath = currentPath
        self._isLinkageEnabled = isLinkageEnabled
        self.session = session
        self.connectionState = connectionState
        self.tabID = tabID
        self.externalTransferDrawerExpanded = isTransferDrawerExpanded
    }

    private var pathControls: some View {
        HStack(alignment: .center, spacing: 6) {
            // Folder icon & Path breadcrumbs
            ApexIconButton(
                icon: "folder.fill",
                label: "前往文件夹 (⌘L)",
                size: 24,
                iconSize: 12
            ) {
                pathInput = currentPath
                isPathFocused = true
            }
            .keyboardShortcut("l", modifiers: .command)

            TextField(L10n.remotePath, text: $pathInput)
                .onSubmit {
                    let target = pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !target.isEmpty else { pathInput = currentPath; return }
                    pathInput = target
                    if target != currentPath { currentPath = target }
                    isPathFocused = false
                }
                .focused($isPathFocused)
                .onExitCommand { pathInput = currentPath; isPathFocused = false }
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(minWidth: 80, maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                        .fill(ApexStyle.subtleSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                        .stroke(isPathFocused ? ApexStyle.accent.opacity(0.85) : ApexStyle.border.opacity(0.65), lineWidth: isPathFocused ? 1.25 : 0.75)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    isPathFocused = true
                }

            // SFTP Quick Bookmarks & Directory Presets Menu
            let trimmedCurrentPath = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCustomBookmarked = bookmarkManager.customBookmarks.contains(where: { $0.path == trimmedCurrentPath })
            Menu {
                Section("系统常用目录预设") {
                    ForEach(SFTPBookmarkManager.defaultPresets) { bookmark in
                        Button {
                            currentPath = bookmark.path
                            pathInput = bookmark.path
                        } label: {
                            Label(bookmark.name, systemImage: bookmark.iconName)
                        }
                    }
                }
                
                if !bookmarkManager.customBookmarks.isEmpty {
                    Section("我的书签收藏") {
                        ForEach(bookmarkManager.customBookmarks) { bookmark in
                            Button {
                                currentPath = bookmark.path
                                pathInput = bookmark.path
                            } label: {
                                Label(bookmark.name, systemImage: bookmark.iconName)
                            }
                        }
                    }
                }
                
                Divider()
                
                if isCustomBookmarked {
                    Button(role: .destructive) {
                        if let b = bookmarkManager.customBookmarks.first(where: { $0.path == trimmedCurrentPath }) {
                            bookmarkManager.removeCustomBookmark(id: b.id)
                        }
                    } label: {
                        Label("取消收藏当前路径", systemImage: "star.slash")
                    }
                } else if !trimmedCurrentPath.isEmpty {
                    Button {
                        bookmarkManager.addCustomBookmark(name: trimmedCurrentPath, path: trimmedCurrentPath)
                    } label: {
                        Label("收藏当前路径到书签", systemImage: "star")
                    }
                }
            } label: {
                ApexMenuTrigger(
                    icon: isCustomBookmarked ? "star.fill" : "bookmark",
                    label: "常用目录预设与书签快速跳转",
                    size: 24,
                    iconSize: 11,
                    tint: isCustomBookmarked ? ApexStyle.warning : nil
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("常用目录预设与书签快速跳转")

            ApexIconButton(
                icon: "doc.on.doc",
                label: "复制当前路径",
                size: 24,
                iconSize: 11
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(currentPath, forType: .string)
            }
            .disabled(currentPath.isEmpty)
        }
    }

    private func fileActions(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: compact ? 4 : 6) {
            SFTPToolbarChip(
                title: isLinkageEnabled ? L10n.linkageOn : L10n.linkageOff,
                compact: compact,
                isHighlighted: isLinkageEnabled
            ) {
                isLinkageEnabled.toggle()
            } icon: {
                Image(systemName: isLinkageEnabled ? "link" : "link.slash")
                    .font(.system(size: 11, weight: .medium))
            }
            .accessibilityLabel(isLinkageEnabled ? L10n.linkageOn : L10n.linkageOff)
            .accessibilityAddTraits(isLinkageEnabled ? .isSelected : [])
            .help(isLinkageEnabled ? L10n.linkageHelpOn : L10n.linkageHelpOff)

            Divider().frame(height: 14)

            // Actions
            ApexIconButton(
                icon: "arrow.up",
                label: L10n.parentDirectory,
                size: 24,
                iconSize: 11
            ) {
                navigateUp()
            }

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
                    .frame(width: 24, height: 24)
            } else {
                ApexIconButton(
                    icon: "arrow.clockwise",
                    label: L10n.refreshDirectory,
                    size: 24,
                    iconSize: 11
                ) {
                    loadDirectory(path: currentPath)
                }
            }

            Divider().frame(height: 14)

            SFTPToolbarChip(
                title: L10n.uploadFile,
                compact: compact,
                isHighlighted: false
            ) {
                uploadAction()
            } icon: {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .accessibilityLabel(L10n.uploadFile)
            .help(L10n.uploadFile)
            .disabled(connectionState != .connected)

            Menu {
                Button("新建文件夹", systemImage: "folder.badge.plus") {
                    newFolderName = ""
                    isShowingNewFolderAlert = true
                }
                .disabled(connectionState != .connected)
                Button("新建文件", systemImage: "doc.badge.plus") {
                    newFileName = ""
                    isShowingNewFileAlert = true
                }
                .disabled(connectionState != .connected)
                Toggle("显示隐藏文件", isOn: $showHiddenFiles)
            } label: {
                ApexMenuTrigger(
                    icon: "ellipsis",
                    label: "新建文件、文件夹及隐藏文件",
                    size: 24,
                    iconSize: 11
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("新建文件、文件夹及隐藏文件")
            .accessibilityIdentifier("ellipsis")

            ApexIconButton(
                icon: "line.3.horizontal.decrease",
                label: "筛选当前文件夹",
                size: 24,
                iconSize: 11,
                isSelected: isFilterVisible
            ) {
                isFilterVisible.toggle()
            }
            .accessibilityLabel("筛选文件")

            ApexIconButton(
                icon: "doc.text.magnifyingglass",
                label: "远端搜索 (⌘⇧F)",
                size: 24,
                iconSize: 11,
                isSelected: isRemoteSearchVisible
            ) {
                if isRemoteSearchVisible {
                    closeRemoteSearch()
                } else {
                    isRemoteSearchVisible = true
                    isRemoteSearchFocused = true
                }
            }
            .help("在远端目录按文件名或内容搜索 (⌘⇧F)")
            .disabled(connectionState != .connected)

            Divider().frame(height: 14)

            if !tabExternalEditSessions.isEmpty {
                externalEditToolbarButton(compact: compact)
            }

            // Transfer records drawer toggle button
            TransferToolbarButton(isExpanded: transferDrawerExpandedBinding, compact: compact)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var fileBrowser: some View {
        VStack(spacing: 0) {
            // AnyLayout preserves the editable path control and its focus as
            // the window crosses the single-row / two-row boundary.
            let layout = toolbarWidth < 680
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                pathControls
                if toolbarWidth > 0 && toolbarWidth < 320 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        fileActions(compact: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    fileActions(compact: toolbarWidth < 880)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 8)
            .background(ApexStyle.surface)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarWidth = $0 }
            .background {
                Group {
                    Button("") { showHiddenFiles.toggle() }
                        .keyboardShortcut(".", modifiers: [.command, .shift])
                        .accessibilityHidden(true)
                    Button("") {
                        if isRemoteSearchVisible {
                            closeRemoteSearch()
                        } else {
                            isRemoteSearchVisible = true
                            isRemoteSearchFocused = true
                        }
                    }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .accessibilityHidden(true)
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }

            Divider()

            if let notice = transferNotice {
                let isFailure = transferNoticeKind == .error
                let noticeTint: Color = {
                    switch transferNoticeKind {
                    case .success: return ApexStyle.success
                    case .info: return ApexStyle.accent
                    case .warning: return ApexStyle.warning
                    case .error: return ApexStyle.error
                    case .cancelled: return ApexStyle.secondary
                    }
                }()
                let noticeIcon: String = {
                    switch transferNoticeKind {
                    case .success: return "checkmark.circle.fill"
                    case .info: return "arrow.triangle.2.circlepath"
                    case .warning: return "exclamationmark.circle.fill"
                    case .error: return "exclamationmark.triangle.fill"
                    case .cancelled: return "minus.circle.fill"
                    }
                }()
                let isCreationFailure = (creationFailureNotice == notice && creationFailureDetails != nil)
                let isTransferOutcome = !isCreationFailure && transferNoticeIsTransferOutcome

                HStack(spacing: 8) {
                    Image(systemName: noticeIcon)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(noticeTint)
                        .frame(width: 14, alignment: .center)

                    Text(notice)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isFailure ? ApexStyle.error : ApexStyle.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(notice)

                    Spacer(minLength: 8)

                    if isCreationFailure {
                        Button("查看详情") {
                            isShowingCreationFailure = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ApexStyle.error)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("点击查看创建失败原因与完整远端错误")
                    } else if isTransferOutcome {
                        Button("查看传输记录") {
                            withAnimation(ApexStyle.springSnappy) {
                                transferDrawerExpandedBinding.wrappedValue = true
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ApexStyle.accent)
                        .fixedSize(horizontal: true, vertical: false)
                        .help("点击打开传输任务记录抽屉")
                    }

                    ApexIconButton(
                        icon: "xmark",
                        label: "关闭提示",
                        size: 20,
                        iconSize: 9.5
                    ) {
                        clearNotice()
                    }
                }
                .padding(.horizontal, ApexStyle.s4)
                .frame(height: 30)
                .background {
                    ZStack {
                        ApexStyle.subtleSurface
                        noticeTint.opacity(0.08)
                    }
                }
                .transition(.opacity)

                Divider()
            }

            // Search filter bar
            if isFilterVisible || !searchFilter.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        TextField(L10n.filterFiles, text: $searchFilter)
                            .focused($isFilterFocused)
                            .onExitCommand {
                                dismissFilterBar()
                            }
                            .task {
                                await Task.yield()
                                if isFilterVisible { isFilterFocused = true }
                            }
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)

                        if !searchFilter.isEmpty {
                            ApexIconButton(
                                icon: "xmark.circle.fill",
                                label: "清除文件筛选",
                                size: 18,
                                iconSize: 11
                            ) {
                                searchFilter = ""
                                isFilterFocused = true
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
                            .stroke(isFilterFocused ? ApexStyle.accent.opacity(0.85) : ApexStyle.border.opacity(0.65), lineWidth: isFilterFocused ? 1.25 : 0.75)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isFilterFocused = true
                    }

                    ApexIconButton(
                        icon: "xmark",
                        label: "关闭文件筛选",
                        size: 24,
                        iconSize: 10
                    ) {
                        dismissFilterBar()
                    }
                }
                .padding(.horizontal, ApexStyle.s4)
                .padding(.vertical, 6)
                .background(ApexStyle.subtleSurface)

                Divider()
            }

            if isRemoteSearchVisible {
                remoteSearchBar
            }
            // Files table with Drag & Drop upload & download + non-blocking embedded transfer drawer
            GeometryReader { contentGeo in
                let drawerMode = SFTPTransferDrawerLayout.resolve(
                    isExpanded: transferDrawerExpandedBinding.wrappedValue,
                    availableHeight: contentGeo.size.height
                )
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        fileTableContainer
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if case .dockedSplit(let drawerHeight) = drawerMode {
                            Divider()
                            TransferDrawer(isExpanded: transferDrawerExpandedBinding)
                                .frame(maxWidth: .infinity)
                                .frame(height: drawerHeight)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }

                    if case .fillSFTPArea = drawerMode {
                        TransferDrawer(isExpanded: transferDrawerExpandedBinding)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ApexStyle.surface)

            if !transferDrawerExpandedBinding.wrappedValue {
                TransferInlineProgressBar(isDrawerExpanded: transferDrawerExpandedBinding)
            }
        }
    }

    private var fileTableContainer: some View {
        ZStack {
                if connectionState != .connected {
                    Group {
                        if case .connecting = connectionState {
                            VStack {
                                Spacer()
                                ProgressView("正在等待会话连接…")
                                    .font(.caption)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ContentUnavailableView {
                                Label("会话尚未连接", systemImage: "network.slash")
                            } description: {
                                Text("SSH 连接建立后将自动加载远程目录")
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .contentShape(Rectangle())
                } else if items.isEmpty && isLoading {
                    VStack {
                        Spacer()
                        ProgressView(L10n.loadingFiles)
                            .font(.caption)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDropUpload(providers: providers)
                        return true
                    }
                } else if let loadError {
                    ContentUnavailableView {
                        Label("无法读取远程文件", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError).lineLimit(2)
                    } actions: {
                        Button("重试") { loadDirectory(path: currentPath) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDropUpload(providers: providers)
                        return true
                    }
                } else if filteredItems.isEmpty {
                    ContentUnavailableView(
                        searchFilter.isEmpty ? "文件夹为空" : "没有匹配的文件",
                        systemImage: searchFilter.isEmpty ? "folder" : "magnifyingglass"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                        handleDropUpload(providers: providers)
                        return true
                    }
                } else {
                    Table(of: SFTPItem.self, selection: $selectedPaths, sortOrder: $tableSortOrder) {
                        TableColumn("名称", value: \.name) { item in
                            HStack(spacing: 6) {
                                Image(systemName: fileIcon(for: item))
                                    .font(.system(size: 12))
                                    .frame(width: 16, alignment: .center)
                                    .foregroundStyle(selectedPaths.contains(item.path) ? Color.primary : fileColor(for: item))
                                Text(item.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }.help(item.path)
                        }
                        .width(min: 120, ideal: 280)
                        TableColumn("权限") { item in
                            Text(item.permissionString).font(.caption.monospaced())
                        }.width(min: 65, ideal: 90, max: 120)
                        TableColumn("大小", value: \.size) { item in
                            Text(item.formattedSize).font(.caption.monospacedDigit())
                        }.width(min: 55, ideal: 85, max: 120)
                        TableColumn("修改时间", value: \.modificationDate) { item in
                            Text(formatDate(item.modificationDate)).font(.caption.monospacedDigit())
                        }.width(min: 110, ideal: 145, max: 180)
                    } rows: {
                        ForEach(filteredItems) { item in
                            if item.name == ".." {
                                TableRow(item)
                            } else {
                                TableRow(item).itemProvider { handleDragDownload(for: item) }
                            }
                        }
                    }
                    // Keep the system's semantic selection foreground instead of inheriting a theme's fixed text color.
                    .foregroundStyle(Color.primary)
                    .background(
                        SFTPOutlineViewDragDropBridge(
                            items: filteredItems,
                            session: session,
                            acceptsDrops: connectionState == .connected,
                            onDropURLs: { urls in
                                requestBatchUpload(urls, targetDirectory: currentPath)
                            },
                            onStatusChange: { notice in
                                self.applyDragExportNotice(notice)
                            }
                        )
                        .frame(width: 0, height: 0)
                    )
                    .contextMenu(forSelectionType: String.self) { ids in
                        if ids.count == 1, let path = ids.first, let item = items.first(where: { $0.path == path }) {
                            fileContextActions(item)
                        } else if ids.count > 1 {
                            batchContextActions(for: ids)
                        }
                    } primaryAction: { ids in
                        if let path = ids.first, let item = items.first(where: { $0.path == path }) {
                            handleDoubleClick(item)
                        }
                    }
                    .contextMenu {
                        Button("新建文件夹") {
                            newFolderName = ""
                            isShowingNewFolderAlert = true
                        }
                        Button("新建文件") {
                            newFileName = ""
                            isShowingNewFileAlert = true
                        }
                        Divider()
                        Button("修改当前目录权限 (chmod)...") {
                            itemToChmod = nil
                            chmodText = "755"
                            isShowingChmodAlert = true
                        }
                        Divider()
                        Button(action: { showHiddenFiles.toggle() }) {
                            Label(showHiddenFiles ? "隐藏点文件 (⌘⇧.)" : "显示点文件 (⌘⇧.)", systemImage: showHiddenFiles ? "eye.fill" : "eye.slash")
                        }
                        Button(action: { loadDirectory(path: currentPath) }) {
                            Label("刷新目录", systemImage: "arrow.clockwise")
                        }
                    }
                    .opacity(isLoading ? 0.65 : 1.0)
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
                    ZStack {
                        Color.black.opacity(0.08)
                        ProgressView("正在读取远程文件…")
                            .padding(18)
                            .apexPanel()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }


            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ApexStyle.surface)
    }

    private var observedFileBrowser: some View {
        fileBrowser
        .background(WindowReferenceView(reference: windowReference).frame(width: 0, height: 0))
        .alert("创建失败", isPresented: $isShowingCreationFailure) {
            Button("好", role: .cancel) {}
        } message: {
            Text(creationFailureDetails ?? "")
        }
        .onChange(of: isFilterVisible) { _, visible in
            if !visible { isFilterFocused = false; searchFilter = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerSFTPFind"))) { _ in
            guard let window = windowReference.window, window === NSApp.keyWindow else { return }
            let tableHasFocus = (window.firstResponder as? NSTableView)?.tableColumns.count == 4
            guard isPathFocused || isFilterFocused || tableHasFocus else { return }
            let alreadyVisible = isFilterVisible
            isPathFocused = false
            isFilterVisible = true
            if alreadyVisible { isFilterFocused = true }
        }
        .onChange(of: items) { _, _ in updateDisplayItems() }
        .onChange(of: searchFilter) { _, _ in updateDisplayItems() }
        .onChange(of: showHiddenFiles) { _, newValue in
            if themeSettings.showHiddenFiles != newValue {
                themeSettings.showHiddenFiles = newValue
            }
            updateDisplayItems()
        }
        .onChange(of: themeSettings.showHiddenFiles) { _, newValue in
            if showHiddenFiles != newValue {
                showHiddenFiles = newValue
            }
        }
        .onChange(of: tableSortOrder) { _, _ in updateDisplayItems() }
        .onDisappear {
            loadGeneration &+= 1
            loadTask?.cancel()
            remoteSearchTask?.cancel()
            remoteSearchTask = nil
        }
        .onAppear {
            showHiddenFiles = themeSettings.showHiddenFiles
            pathInput = currentPath
            if installedEditors.isEmpty {
                installedEditors = ExternalEditSessionManager.installedEditors()
            }
            updateDisplayItems()
            loadDirectory(path: currentPath)
        }
        .onChange(of: tabExternalEditSessions.isEmpty) { _, isEmpty in
            if isEmpty {
                isShowingExternalEditPopover = false
            }
        }
        .onChange(of: currentPath) { oldPath, newPath in
            // Focus alone is not an edit: follow directory changes until a draft differs.
            if !isPathFocused || pathInput == oldPath { pathInput = newPath }
            loadDirectory(path: newPath)
        }
        .onChange(of: connectionState) { oldState, newState in
            if newState == .connected && oldState != .connected {
                loadDirectory(path: currentPath)
            } else if newState != .connected {
                loadGeneration &+= 1
                loadTask?.cancel()
                remoteSearchTask?.cancel()
                remoteSearchTask = nil
                isSearchingRemote = false
                remoteSearchHits = []
                remoteSearchError = nil
                remoteSearchDidReturnEmpty = false
                isLoading = false
                items = []
                displayItems = []
                selectedPaths = []
                isDropTargeted = false
                if case .connecting = newState {
                    loadError = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SFTPDirectoryRefreshNeeded"))) { notification in
            if let myTabID = tabID, let notifTabID = notification.userInfo?["tabId"] as? UUID {
                guard myTabID == notifTabID else { return }
            }
            if let path = notification.object as? String, !path.isEmpty {
                let parent = (path as NSString).deletingLastPathComponent
                let normalizedPath = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
                let normalizedCurrent = currentPath.hasSuffix("/") && currentPath.count > 1 ? String(currentPath.dropLast()) : currentPath
                let normalizedParent = parent.hasSuffix("/") && parent.count > 1 ? String(parent.dropLast()) : parent
                guard normalizedPath == normalizedCurrent || normalizedParent == normalizedCurrent || path == "~" else { return }
            }
            loadDirectory(path: currentPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isLinkageEnabled {
                loadDirectory(path: currentPath)
            }
        }
    }

    public var body: some View {
        observedFileBrowser
        .sheet(item: $editingFile) { item in
            QuickEditorView(
                item: item,
                content: $editorContent,
                initialLine: editorInitialLine,
                onSave: { newContent in
                    try await saveEditedFileAsync(item, content: newContent)
                },
                onReload: {
                    try await reloadFileContentAsync(item)
                }
            )
            .apexTheme()
        }
        .alert(archiveFormat.menuTitle, isPresented: $isShowingArchiveAlert) {
            TextField("归档文件名", text: $archiveOutputName)
                .autocorrectionDisabled()
            Button("压缩") {
                performArchive(items: archiveTargetItems, format: archiveFormat, archiveName: archiveOutputName)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将在 \(currentPath) 中把选中的 \(archiveTargetItems.count) 个项目打包为 \(archiveFormat.fileExtension)")
        }
        .confirmationDialog(
            "解压到当前目录？",
            isPresented: $isShowingExtractConfirm,
            presenting: itemToExtract
        ) { item in
            Button("解压「\(item.name)」到 \(currentPath)") {
                performExtract(item)
            }
            Button("取消", role: .cancel) {
                itemToExtract = nil
            }
        } message: { item in
            Text("将把「\(item.name)」解压至 \(currentPath)（同名文件可能被覆盖）。")
        }
        .sheet(item: $inspectingItem) { item in
            SFTPFileInspectorSheet(item: item, session: session)
                .apexTheme()
        }
        .alert("创建符号链接 (ln -s)", isPresented: $isShowingSymlinkAlert) {
            TextField("链接名称", text: $symlinkNameText)
                .autocorrectionDisabled()
            Button("创建") {
                if let item = itemToSymlink {
                    performCreateSymlink(targetItem: item, linkName: symlinkNameText)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在当前目录创建指向「\(itemToSymlink?.name ?? "")」的符号链接")
        }
        .confirmationDialog(
            "确定删除？",
            isPresented: isShowingDeleteConfirmation,
            presenting: itemToDelete
        ) { item in
            Button("永久删除「\(item.name)」", role: .destructive) {
                performDelete(item)
            }
            Button("取消", role: .cancel) {
                itemToDelete = nil
            }
        } message: { item in
            Text("将从远程服务器永久删除「\(item.name)」\(item.isDirectory ? "及其内部所有文件" : "")，此操作不可撤销。")
        }
        .confirmationDialog(
            "确定批量删除？",
            isPresented: isShowingBatchDeleteConfirmation,
            presenting: batchItemsToDelete
        ) { targetItems in
            Button("永久删除选中的 \(targetItems.count) 个项目", role: .destructive) {
                performBatchDelete(targetItems)
            }
            Button("取消", role: .cancel) {
                batchItemsToDelete = nil
            }
        } message: { targetItems in
            Text("将从远程服务器永久删除选中的 \(targetItems.count) 个项目及其内部所有内容，此操作不可撤销。")
        }
        .alert("新建文件夹", isPresented: $isShowingNewFolderAlert) {
            TextField("文件夹名称", text: $newFolderName)
                .autocorrectionDisabled()
            Button("创建") {
                performCreateFolder(name: newFolderName)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在当前目录 (\(currentPath)) 下创建新文件夹")
        }
        .alert("新建空白文件", isPresented: $isShowingNewFileAlert) {
            TextField("文件名 (例如 test.sh)", text: $newFileName)
                .autocorrectionDisabled()
            Button("创建") {
                performCreateFile(name: newFileName)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在当前目录 (\(currentPath)) 下创建空白文件")
        }
        .alert("重命名", isPresented: $isShowingRenameAlert) {
            TextField("新名称", text: $renameText)
                .autocorrectionDisabled()
            Button("确定") {
                if let item = itemToRename {
                    performRename(item: item, newName: renameText)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("输入「\(itemToRename?.name ?? "")」的新名称")
        }
        .alert("修改权限 (chmod)", isPresented: $isShowingChmodAlert) {
            TextField("权限代码 (如 755, 644, 777)", text: $chmodText)
            Button("确定") {
                let target = itemToChmod?.path ?? currentPath
                performChmod(targetPath: target, mode: chmodText)
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let item = itemToChmod {
                Text("修改「\(item.name)」的访问权限（例如：文件夹推荐 755，普通文件推荐 644）")
            } else {
                Text("修改当前目录 (\(currentPath)) 的访问权限（推荐 755 赋予读写与遍历权限）")
            }
        }
    }

    private var isShowingDeleteConfirmation: Binding<Bool> {
        Binding<Bool>(
            get: { itemToDelete != nil },
            set: { isPresented in if !isPresented { itemToDelete = nil } }
        )
    }

    private var isShowingBatchDeleteConfirmation: Binding<Bool> {
        Binding<Bool>(
            get: { batchItemsToDelete != nil },
            set: { isPresented in if !isPresented { batchItemsToDelete = nil } }
        )
    }

    private var filteredItems: [SFTPItem] { displayItems }

    private func updateDisplayItems() {
        displayItems = items.filter {
            (showHiddenFiles || !$0.name.hasPrefix(".") || $0.name == "..") &&
            (searchFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(searchFilter))
        }.sorted { a, b in
            if a.name == ".." || b.name == ".." { return a.name == ".." && b.name != ".." }
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            for comparator in tableSortOrder {
                let result = comparator.compare(a, b)
                if result != .orderedSame { return result == .orderedAscending }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func fileContextActions(_ item: SFTPItem) -> some View {
        if item.isParentNavigationEntry {
            Button("返回上级目录") {
                navigateUp()
            }
            Divider()
            Button(L10n.copyRemotePath) {
                selectedPaths = [item.path]
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        } else {
            Button(DistributionChannel.current == .appStore ? "下载并保存…" : L10n.downloadToDownloads) {
                selectedPaths = [item.path]
                downloadAction(item)
            }
            if !item.isDirectory {
                Button(L10n.quickViewEdit) {
                    selectedPaths = [item.path]
                    openEditor(item)
                }
                Menu("使用外部编辑器打开") {
                    Button {
                        selectedPaths = [item.path]
                        openInExternalEditor(item, editorBundleID: "", editorAppURL: nil)
                    } label: {
                        Label("系统默认应用", systemImage: "arrow.up.forward.app")
                    }

                    let editors = installedEditors.isEmpty ? ExternalEditSessionManager.installedEditors() : installedEditors
                    if !editors.isEmpty {
                        Divider()
                        ForEach(editors) { editor in
                            let isPreferred = externalEditManager.preferredEditorBundleID == editor.bundleID
                            Button {
                                selectedPaths = [item.path]
                                openInExternalEditor(item, editorBundleID: editor.bundleID, editorAppURL: editor.appURL)
                            } label: {
                                Label(
                                    isPreferred ? "\(editor.name)（首选）" : editor.name,
                                    systemImage: isPreferred ? "checkmark.circle" : "app"
                                )
                            }
                        }
                    }

                    Divider()
                    Button {
                        selectedPaths = [item.path]
                        chooseExternalEditorAndOpen(item)
                    } label: {
                        Label("选择应用...", systemImage: "folder")
                    }
                }
                .disabled(connectionState != .connected)
            }
            Button("属性与校验和 (SHA-256)...") {
                selectedPaths = [item.path]
                inspectingItem = item
            }
            if item.isModifiableRemoteItem {
                Divider()
                Button("重命名...") {
                    selectedPaths = [item.path]
                    itemToRename = item
                    renameText = item.name
                    isShowingRenameAlert = true
                }
                Button("修改权限 (chmod)...") {
                    selectedPaths = [item.path]
                    itemToChmod = item
                    chmodText = item.isDirectory ? "755" : "644"
                    isShowingChmodAlert = true
                }
                Button("在服务器端创建副本 (快速克隆)") {
                    selectedPaths = [item.path]
                    performServerSideDuplicate(item)
                }
                Button("创建符号链接 (ln -s)...") {
                    selectedPaths = [item.path]
                    itemToSymlink = item
                    symlinkNameText = "\(item.name)-link"
                    isShowingSymlinkAlert = true
                }
                Divider()
                Menu("压缩 / 解压") {
                    Button(SFTPArchiveFormat.tarGz.menuTitle) {
                        archiveTargetItems = [item]
                        archiveFormat = .tarGz
                        archiveOutputName = "\(item.name).tar.gz"
                        isShowingArchiveAlert = true
                    }
                    Button(SFTPArchiveFormat.zip.menuTitle) {
                        archiveTargetItems = [item]
                        archiveFormat = .zip
                        archiveOutputName = "\(item.name).zip"
                        isShowingArchiveAlert = true
                    }
                    if !item.isDirectory && SFTPRemoteOperations.isSupportedArchiveName(item.name) {
                        Divider()
                        Button("解压到当前目录...") {
                            itemToExtract = item
                            isShowingExtractConfirm = true
                        }
                    }
                }
                Button(role: .destructive) {
                    selectedPaths = [item.path]
                    itemToDelete = item
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            Divider()
            Button(L10n.copyRemotePath) {
                selectedPaths = [item.path]
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }

    @ViewBuilder
    private func batchContextActions(for ids: Set<String>) -> some View {
        let selectedItems = SFTPItem.modifiableSelection(from: items, selectedPaths: ids)
        if !selectedItems.isEmpty {
            Button("下载选中的 \(selectedItems.count) 个项目") {
                downloadBatchAction(selectedItems)
            }
            Menu("压缩选中的 \(selectedItems.count) 个项目") {
                Button(SFTPArchiveFormat.tarGz.menuTitle) {
                    archiveTargetItems = selectedItems
                    archiveFormat = .tarGz
                    archiveOutputName = "archive.tar.gz"
                    isShowingArchiveAlert = true
                }
                Button(SFTPArchiveFormat.zip.menuTitle) {
                    archiveTargetItems = selectedItems
                    archiveFormat = .zip
                    archiveOutputName = "archive.zip"
                    isShowingArchiveAlert = true
                }
            }
            Divider()
            Button(role: .destructive) {
                batchItemsToDelete = selectedItems
            } label: {
                Label("删除选中的 \(selectedItems.count) 个项目", systemImage: "trash")
            }
            Divider()
        }
        Button("复制所有选中远程路径") {
            let paths = items.filter { ids.contains($0.path) && !$0.isParentNavigationEntry }.map(\.path)
            let joined = paths.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
        }
    }

    /// Resolve a configured destination and retain its grant through queue construction.
    private func downloadDirectoryAccess() throws -> FileAccessLease {
        let configured = URL(fileURLWithPath: NativeSSHSession.expandPath(AppSettings.shared.defaultDownloadDirectory))
        if DistributionChannel.current != .appStore {
            let access = try FileAccessStore.shared.acquire(configured)
            guard FileManager.default.isWritableFile(atPath: access.url.path) else {
                access.close()
                throw CocoaError(.fileWriteNoPermission)
            }
            return access
        }
        // A writable Downloads URL in App Sandbox can be inside the hidden
        // container. User documents must always have an explicit destination.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择下载文件的保存目录"
        panel.prompt = "选择目录"
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        try FileAccessStore.shared.remember(url, isDirectory: true)
        let access = try FileAccessStore.shared.acquire(url)
        guard FileManager.default.isWritableFile(atPath: access.url.path) else {
            access.close()
            throw CocoaError(.fileWriteNoPermission)
        }
        AppSettings.shared.defaultDownloadDirectory = access.url.path
        return access
    }

    private func downloadDestinationAccess(_ item: SFTPItem) throws -> FileAccessLease {
        if DistributionChannel.current == .appStore && !item.isDirectory {
            let panel = NSSavePanel()
            panel.title = "保存下载文件"
            panel.message = "选择下载文件的保存位置"
            panel.nameFieldStringValue = item.name
            panel.canCreateDirectories = true
            panel.prompt = "保存"
            guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
            // A new file has no persistent bookmark yet. Retain the panel's
            // transient grant until the asynchronous transfer has finished.
            return try FileAccessStore.shared.prepareSelectedSave(url)
        }
        let directory = try downloadDirectoryAccess()
        defer { directory.close() }
        let destination = TransferManager.shared.availableDownloadURL(in: directory.url, fileName: item.name)
        return try FileAccessStore.shared.acquire(destination)
    }

    private func dismissFilterBar() {
        isFilterFocused = false
        isFilterVisible = false
        searchFilter = ""
        Task { @MainActor in
            await Task.yield()
            guard let window = windowReference.window else { return }
            @MainActor func fileTable(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView, table.tableColumns.count == 4 { return table }
                for child in view.subviews {
                    if let table = fileTable(in: child) { return table }
                }
                return nil
            }
            if let content = window.contentView, let table = fileTable(in: content) {
                window.makeFirstResponder(table)
            }
        }
    }

    private func clearNotice() {
        transferNotice = nil
        transferNoticeKind = .info
        transferNoticeIsTransferOutcome = false
        creationFailureNotice = nil
    }

    private func setNotice(
        _ message: String,
        kind: SFTPNoticeKind,
        isTransferOutcome: Bool = false,
        autoDismissAfter seconds: TimeInterval? = nil
    ) {
        if creationFailureNotice != message {
            creationFailureNotice = nil
        }
        let token = UUID()
        transferNoticeToken = token
        transferNotice = message
        transferNoticeKind = kind
        transferNoticeIsTransferOutcome = isTransferOutcome
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if self.transferNoticeToken == token {
                    self.clearNotice()
                }
            }
        }
    }

    private func downloadBatchAction(_ targetItems: [SFTPItem]) {
        guard let s = session, Self.shouldLoadDirectory(for: connectionState), !targetItems.isEmpty else { return }
        let access: FileAccessLease
        do { access = try downloadDirectoryAccess() }
        catch is CancellationError { return }
        catch {
            setNotice("无法访问下载目录：\(error.localizedDescription)", kind: .error)
            return
        }
        let downloads = access.url
        clearNotice()
        let tracker = SFTPBatchTracker(total: targetItems.count)
        tracker.addCompletionHandler {
            access.close()
        }
        for item in targetItems {
            let localURL = TransferManager.shared.availableDownloadURL(in: downloads, fileName: item.name)
            TransferManager.shared.enqueueDownload(
                session: s,
                remotePath: item.path,
                localURL: localURL,
                totalBytes: Int64(item.size),
                onCompleted: nil,
                onResult: { result in
                    let outcome: SFTPBatchTracker.Outcome = switch result {
                    case .success: .succeeded
                    case .failure(let error): error is CancellationError ? .cancelled : .failed
                    }
                    let snapshot = tracker.record(outcome)
                    Task { @MainActor in
                        if snapshot.isDone {
                            if snapshot.failed > 0 {
                                let cancelSuffix = snapshot.cancelled > 0 ? "，取消 \(snapshot.cancelled)" : ""
                                self.setNotice(
                                    "批量下载部分失败（成功 \(snapshot.succeeded)，失败 \(snapshot.failed)\(cancelSuffix)）",
                                    kind: .error,
                                    isTransferOutcome: true
                                )
                            } else if snapshot.cancelled > 0 {
                                self.setNotice(
                                    snapshot.succeeded > 0
                                        ? "批量下载已取消部分项目（成功 \(snapshot.succeeded)，取消 \(snapshot.cancelled)）"
                                        : "已取消下载: \(item.name)",
                                    kind: snapshot.succeeded > 0 ? .warning : .cancelled,
                                    isTransferOutcome: true
                                )
                            } else {
                                self.setNotice(
                                    "批量下载完成 (\(tracker.total) 个文件)",
                                    kind: .success,
                                    isTransferOutcome: true,
                                    autoDismissAfter: 3.0
                                )
                            }
                        } else if case .failure(let error) = result {
                            self.setNotice(
                                error is CancellationError
                                    ? "已取消下载: \(item.name)"
                                    : "下载失败: \(error.localizedDescription)",
                                kind: error is CancellationError ? .cancelled : .error,
                                isTransferOutcome: true
                            )
                        }
                    }
                }
            )
        }
    }

    private func performBatchDelete(_ targetItems: [SFTPItem]) {
        let safeItems = targetItems.filter(\.isModifiableRemoteItem)
        guard let s = session, Self.shouldLoadDirectory(for: connectionState), !safeItems.isEmpty else { return }
        let pathsToRemove = Set(safeItems.map(\.path))
        withAnimation {
            self.items.removeAll { pathsToRemove.contains($0.path) && $0.isModifiableRemoteItem }
            self.updateDisplayItems()
        }
        Task {
            var failed: [String] = []
            for item in safeItems {
                do {
                    if item.isDirectory {
                        try await s.removeDirectory(remotePath: item.path, recursive: true)
                    } else {
                        try await s.removeFile(remotePath: item.path)
                    }
                } catch {
                    failed.append(item.name)
                }
            }
            await MainActor.run {
                if failed.isEmpty {
                    self.setNotice("已成功删除 \(safeItems.count) 个项目", kind: .success, autoDismissAfter: 3.0)
                } else {
                    self.setNotice("部分项目删除失败 (\(failed.joined(separator: ", ")))", kind: .error)
                }
                self.loadDirectory(path: self.currentPath)
            }
        }
    }

    private func performDelete(_ item: SFTPItem) {
        guard let s = session, Self.shouldLoadDirectory(for: connectionState), item.isModifiableRemoteItem else { return }
        withAnimation {
            self.items.removeAll { $0.path == item.path }
            self.updateDisplayItems()
        }
        Task {
            do {
                if item.isDirectory {
                    try await s.removeDirectory(remotePath: item.path, recursive: true)
                } else {
                    try await s.removeFile(remotePath: item.path)
                }
                await MainActor.run {
                    self.setNotice("已删除: \(item.name)", kind: .success, autoDismissAfter: 3.0)
                    self.loadDirectory(path: self.currentPath)
                }
            } catch {
                await MainActor.run {
                    self.setNotice("删除失败: \(error.localizedDescription)", kind: .error)
                    self.loadDirectory(path: self.currentPath)
                }
            }
        }
    }
    
    private func showCreationFailure(operation: String, target: String, error: Error) {
        let remoteError = error.localizedDescription
        let reason: String
        if remoteError.localizedCaseInsensitiveContains("Permission denied") {
            reason = "当前用户没有目标文件或目录的写入权限，请联系管理员授权或选择可写目录。"
        } else if remoteError.localizedCaseInsensitiveContains("Read-only file system") {
            reason = "目标文件系统为只读，请选择可写目录。"
        } else {
            reason = remoteError
        }
        let notice = "\(operation)失败：\(reason)"
        creationFailureNotice = notice
        creationFailureDetails = "\(reason)\n\n目标：\(target)\n\n远端错误：\(remoteError)"
        setNotice(notice, kind: .error)
    }

    private func performCreateFolder(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session, Self.shouldLoadDirectory(for: connectionState) else { return }
        let target = currentPath.hasSuffix("/") ? "\(currentPath)\(trimmed)" : "\(currentPath)/\(trimmed)"
        Task {
            do {
                try await s.createDirectory(remotePath: target)
                await MainActor.run {
                    self.setNotice("已新建文件夹: \(trimmed)", kind: .success, autoDismissAfter: 3.0)
                    self.loadDirectory(path: self.currentPath)
                }
            } catch {
                await MainActor.run {
                    self.showCreationFailure(operation: "新建文件夹", target: target, error: error)
                }
            }
        }
    }
    
    private func performCreateFile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session, Self.shouldLoadDirectory(for: connectionState) else { return }
        let target = currentPath.hasSuffix("/") ? "\(currentPath)\(trimmed)" : "\(currentPath)/\(trimmed)"
        Task {
            do {
                try await s.createFile(remotePath: target)
                await MainActor.run {
                    self.setNotice("已新建文件: \(trimmed)", kind: .success, autoDismissAfter: 3.0)
                    self.loadDirectory(path: self.currentPath)
                }
            } catch {
                await MainActor.run {
                    self.showCreationFailure(operation: "新建文件", target: target, error: error)
                }
            }
        }
    }
    
    private func performRename(item: SFTPItem, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name, let s = session, Self.shouldLoadDirectory(for: connectionState) else { return }
        let parent = (item.path as NSString).deletingLastPathComponent
        let target = parent == "/" ? "/\(trimmed)" : "\(parent)/\(trimmed)"
        Task {
            do {
                try await s.rename(oldPath: item.path, newPath: target)
                await MainActor.run {
                    self.setNotice("已重命名为: \(trimmed)", kind: .success, autoDismissAfter: 3.0)
                    self.loadDirectory(path: self.currentPath)
                }
            } catch {
                await MainActor.run {
                    self.setNotice("重命名失败: \(error.localizedDescription)", kind: .error)
                }
            }
        }
    }

    private func performChmod(targetPath: String, mode: String) {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session, Self.shouldLoadDirectory(for: connectionState) else { return }
        Task {
            do {
                try await s.changePermissions(remotePath: targetPath, permissions: trimmed)
                await MainActor.run {
                    self.setNotice("已修改权限为: \(trimmed)", kind: .success, autoDismissAfter: 3.0)
                    self.loadDirectory(path: self.currentPath)
                }
            } catch {
                await MainActor.run {
                    self.setNotice("修改权限失败: \(error.localizedDescription)", kind: .error)
                }
            }
        }
    }

    private func performCreateSymlink(targetItem: SFTPItem, linkName: String) {
        let trimmed = linkName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let s = session, Self.shouldLoadDirectory(for: connectionState) else { return }
        let parent = (targetItem.path as NSString).deletingLastPathComponent
        let linkPath = parent == "/" ? "/\(trimmed)" : "\(parent)/\(trimmed)"
        let cmd = SFTPInspectorHelper.buildSymlinkCommand(targetPath: targetItem.path, linkPath: linkPath)
        Task {
            do {
                _ = try await s.executeCommand(cmd)
                await MainActor.run {
                    self.setNotice("已创建符号链接: \(trimmed)", kind: .success, autoDismissAfter: 3.0)
                    self.loadDirectory(path: self.currentPath)
                }
            } catch {
                await MainActor.run {
                    self.setNotice("创建符号链接失败: \(error.localizedDescription)", kind: .error)
                }
            }
        }
    }

    private func performServerSideDuplicate(_ item: SFTPItem) {
        guard item.isModifiableRemoteItem, let s = session, Self.shouldLoadDirectory(for: connectionState) else { return }
        let existingNames = Set(items.map(\.name))
        let dupName = SFTPInspectorHelper.defaultDuplicateName(
            for: item.name,
            isDirectory: item.isDirectory,
            existingNames: existingNames
        )
        let parent = (item.path as NSString).deletingLastPathComponent
        let destPath = parent == "/" ? "/\(dupName)" : "\(parent)/\(dupName)"
        let cmd = SFTPInspectorHelper.buildServerSideDuplicateCommand(
            sourcePath: item.path,
            destinationPath: destPath,
            isDirectory: item.isDirectory
        )
        Task {
            do {
                _ = try await s.executeCommand(cmd)
                await MainActor.run {
                    self.setNotice("已创建副本: \(dupName)", kind: .success, autoDismissAfter: 3.0)
                    self.loadDirectory(path: self.currentPath)
                }
            } catch {
                await MainActor.run {
                    self.setNotice("创建副本失败: \(error.localizedDescription)", kind: .error)
                }
            }
        }
    }

    static func shouldLoadDirectory(for state: SSHConnectionState) -> Bool {
        state == .connected
    }

    private func loadDirectory(path: String) {
        guard let s = session else { return }
        guard Self.shouldLoadDirectory(for: connectionState) else {
            loadGeneration &+= 1
            loadTask?.cancel()
            isLoading = false
            if case .connecting = connectionState {
                loadError = nil
            }
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        loadError = nil
        selectedPaths = []
        loadTask?.cancel()
        loadTask = Task {
            do {
                let fetched = try await s.listDirectory(path: path)
                await MainActor.run {
                    guard !Task.isCancelled,
                          generation == self.loadGeneration,
                          Self.shouldLoadDirectory(for: self.connectionState) else { return }
                    self.items = fetched
                    self.updateDisplayItems()
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled,
                          generation == self.loadGeneration,
                          Self.shouldLoadDirectory(for: self.connectionState) else { return }
                    self.items = []
                    self.updateDisplayItems()
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
        if item.isParentNavigationEntry {
            navigateUp()
        } else if item.isDirectory {
            currentPath = item.path
        } else if item.isSymlink {
            Task {
                if let s = session, (try? await s.listDirectory(path: item.path)) != nil {
                    await MainActor.run {
                        currentPath = item.path
                    }
                } else {
                    await MainActor.run {
                        openEditor(item)
                    }
                }
            }
        } else {
            openEditor(item)
        }
    }

    private var tabExternalEditSessions: [ExternalEditSessionManager.ActiveEditSession] {
        externalEditManager.sessions(forTabID: tabID)
    }

    @ViewBuilder
    private func externalEditToolbarButton(compact: Bool) -> some View {
        let sessions = tabExternalEditSessions
        let hasError = sessions.contains(where: { $0.status.isError })
        let isBusy = sessions.contains(where: { $0.status.isBusy })
        let chipTint: Color = hasError ? ApexStyle.error : ApexStyle.accent
        let iconName = hasError
            ? "exclamationmark.triangle.fill"
            : (isBusy ? "arrow.triangle.2.circlepath" : "square.and.pencil")
        let title = "外编 (\(sessions.count))"

        SFTPToolbarChip(
            title: title,
            compact: compact,
            isHighlighted: isShowingExternalEditPopover || isBusy || hasError,
            tint: chipTint
        ) {
            isShowingExternalEditPopover.toggle()
        } icon: {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
        }
        .accessibilityLabel("外部编辑同步状态，当前 \(sessions.count) 个文件")
        .accessibilityAddTraits(isShowingExternalEditPopover ? .isSelected : [])
        .help("查看或管理当前标签页的外部编辑器实时同步任务")
        .popover(isPresented: $isShowingExternalEditPopover, arrowEdge: .bottom) {
            SFTPExternalEditPopover(
                manager: externalEditManager,
                sessions: sessions,
                onClose: { isShowingExternalEditPopover = false }
            )
            .apexTheme()
            .onExitCommand { isShowingExternalEditPopover = false }
        }
    }

    private func openInExternalEditor(
        _ item: SFTPItem,
        editorBundleID: String?,
        editorAppURL: URL?
    ) {
        guard let session, Self.shouldLoadDirectory(for: connectionState) else { return }
        let sessionName = session.session.name
        let currentTabID = tabID
        Task {
            do {
                let active = try await externalEditManager.openInExternalEditor(
                    session: session,
                    tabID: currentTabID,
                    sessionName: sessionName,
                    remotePath: item.path,
                    editorBundleID: editorBundleID,
                    editorAppURL: editorAppURL
                )
                self.setNotice(
                    "已在 \(active.editorName) 中打开「\(item.name)」，保存将自动同步",
                    kind: .info,
                    autoDismissAfter: 3.0
                )
            } catch {
                self.setNotice(
                    "外部编辑器打开失败：\(error.localizedDescription)",
                    kind: .error
                )
            }
        }
    }

    private func chooseExternalEditorAndOpen(_ item: SFTPItem) {
        let panel = NSOpenPanel()
        panel.title = "选择外部编辑器"
        panel.message = "选择用于编辑「\(item.name)」的应用程序"
        panel.allowedContentTypes = [.applicationBundle, .application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let appURL = panel.url {
            let bundleID = Bundle(url: appURL)?.bundleIdentifier
            openInExternalEditor(item, editorBundleID: bundleID, editorAppURL: appURL)
        }
    }

    private func openEditor(_ item: SFTPItem, lineNumber: Int? = nil) {
        guard !isOpeningEditor else { return }
        guard item.size <= 1_000_000 else {
            setNotice("文件超过 1 MB，请先下载后编辑", kind: .warning)
            return
        }
        guard let session, Self.shouldLoadDirectory(for: connectionState) else { return }
        isOpeningEditor = true
        editorInitialLine = lineNumber
        Task {
            let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: localURL) }
            do {
                try await session.downloadFile(remotePath: item.path, localURL: localURL, progress: { _ in })
                let data = try Data(contentsOf: localURL)
                let text = String(data: data, encoding: .utf8) ??
                           String(data: data, encoding: .windowsCP1252) ??
                           String(data: data, encoding: .isoLatin1) ??
                           String(decoding: data, as: UTF8.self)
                editorContent = text
                editingFile = item
            } catch {
                setNotice("读取失败：\(error.localizedDescription)", kind: .error)
            }
            isOpeningEditor = false
        }
    }

    // MARK: - Remote Search & Archive Operations (v1.24.0)

    @ViewBuilder
    private func remoteSearchActionControls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            if isSearchingRemote {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
                    .frame(width: 16, height: 16)
                if compact {
                    ApexIconButton(icon: "stop.circle", label: "取消搜索", size: 24, iconSize: 11) {
                        remoteSearchTask?.cancel()
                        remoteSearchTask = nil
                        isSearchingRemote = false
                    }
                } else {
                    ApexActionButton("取消", tint: ApexStyle.secondary, size: .small) {
                        remoteSearchTask?.cancel()
                        remoteSearchTask = nil
                        isSearchingRemote = false
                    }
                }
            } else if compact {
                ApexIconButton(icon: "magnifyingglass", label: "搜索", size: 24, iconSize: 11, tint: ApexStyle.accent) {
                    performRemoteSearch()
                }
                .disabled(remoteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connectionState != .connected)
            } else {
                ApexActionButton("搜索", icon: "magnifyingglass", tint: ApexStyle.accent, size: .small) {
                    performRemoteSearch()
                }
                .disabled(remoteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connectionState != .connected)
            }

            ApexIconButton(icon: "xmark", label: "关闭远端搜索", size: 24, iconSize: 10) {
                closeRemoteSearch()
            }
        }
        .fixedSize()
    }

    private var remoteSearchBar: some View {
        let isNarrow = toolbarWidth > 0 && toolbarWidth < 460
        let isUltraNarrow = toolbarWidth > 0 && toolbarWidth < 270
        let searchLayout = isNarrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 8))

        return VStack(spacing: 0) {
            searchLayout {
                HStack(spacing: 6) {
                    Picker("搜索模式", selection: $remoteSearchMode) {
                        ForEach(SFTPSearchMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .pickerStyle(.segmented)
                    .fixedSize(horizontal: true, vertical: false)

                    if isNarrow {
                        Spacer(minLength: 4)
                        remoteSearchActionControls(compact: isUltraNarrow)
                    }
                }

                HStack(spacing: 4) {
                    TextField(
                        remoteSearchMode == .filename ? "在 \(currentPath) 搜索文件名 (find)..." : "在 \(currentPath) 搜索文件内容 (grep -F)...",
                        text: $remoteSearchQuery
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isRemoteSearchFocused)
                    .frame(maxWidth: .infinity)
                    .onSubmit {
                        performRemoteSearch()
                    }
                    .onExitCommand {
                        closeRemoteSearch()
                    }

                    if !remoteSearchQuery.isEmpty {
                        ApexIconButton(
                            icon: "xmark.circle.fill",
                            label: "清除远端搜索内容",
                            size: 18,
                            iconSize: 11
                        ) {
                            remoteSearchQuery = ""
                            isRemoteSearchFocused = true
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
                        .stroke(isRemoteSearchFocused ? ApexStyle.accent.opacity(0.85) : ApexStyle.border.opacity(0.65), lineWidth: isRemoteSearchFocused ? 1.25 : 0.75)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    isRemoteSearchFocused = true
                }

                if !isNarrow {
                    remoteSearchActionControls(compact: false)
                }
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 6)
            .background(ApexStyle.subtleSurface)

            if let err = remoteSearchError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ApexStyle.error)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(ApexStyle.error)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    ApexIconButton(icon: "xmark", label: "关闭错误提示", size: 18, iconSize: 8.5, tint: ApexStyle.error) {
                        remoteSearchError = nil
                    }
                }
                .padding(.horizontal, ApexStyle.s4)
                .padding(.bottom, 6)
                .background(ApexStyle.subtleSurface)
            } else if remoteSearchDidReturnEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(ApexStyle.secondary)
                    Text("未找到匹配结果（深度上限 5 层，最多 200 条）")
                        .font(.caption)
                        .foregroundStyle(ApexStyle.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    ApexIconButton(icon: "xmark", label: "关闭空结果提示", size: 18, iconSize: 8.5) {
                        remoteSearchDidReturnEmpty = false
                    }
                }
                .padding(.horizontal, ApexStyle.s4)
                .padding(.bottom, 6)
                .background(ApexStyle.subtleSurface)
            } else if !remoteSearchHits.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(remoteSearchHits.enumerated()), id: \.element.id) { index, hit in
                            if index > 0 {
                                Divider()
                            }
                            Button {
                                handleRemoteSearchHitClick(hit)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: hit.lineNumber != nil ? "doc.text" : "doc.viewfinder")
                                        .font(.system(size: 11))
                                        .foregroundColor(ApexStyle.accent)
                                    Text(hit.path)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(ApexStyle.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let line = hit.lineNumber {
                                        Text(":\(line)")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .monospacedDigit()
                                            .foregroundColor(ApexStyle.accent)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                                    }
                                    if let snippet = hit.snippet, !snippet.isEmpty {
                                        Text(snippet)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(ApexStyle.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, ApexStyle.s4)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 165)
                .background(ApexStyle.surface)
            }
            Divider()
        }
    }

    private func closeRemoteSearch() {
        remoteSearchTask?.cancel()
        remoteSearchTask = nil
        isSearchingRemote = false
        remoteSearchError = nil
        remoteSearchDidReturnEmpty = false
        isRemoteSearchFocused = false
        isRemoteSearchVisible = false
    }

    private func performRemoteSearch() {
        let query = remoteSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let s = session,
              Self.shouldLoadDirectory(for: connectionState),
              let cmd = SFTPRemoteOperations.searchCommand(basePath: currentPath, query: query, mode: remoteSearchMode) else {
            return
        }
        remoteSearchTask?.cancel()
        isSearchingRemote = true
        remoteSearchError = nil
        remoteSearchDidReturnEmpty = false
        let mode = remoteSearchMode
        remoteSearchTask = Task {
            do {
                let raw = try await s.executeCommand(cmd)
                guard !Task.isCancelled else { return }
                let hits = SFTPRemoteOperations.parseSearchOutput(raw, mode: mode)
                await MainActor.run {
                    self.remoteSearchHits = hits
                    self.isSearchingRemote = false
                    self.remoteSearchDidReturnEmpty = hits.isEmpty
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isSearchingRemote = false
                    self.remoteSearchError = "搜索失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func handleRemoteSearchHitClick(_ hit: SFTPSearchHit) {
        let parentDir = hit.parentDirectory
        if parentDir != currentPath {
            currentPath = parentDir
        }
        let targetItem = items.first(where: { $0.path == hit.path })
            ?? SFTPItem(name: hit.fileName, path: hit.path, isDirectory: false, isSymlink: false, size: 0, permissions: 0o644, modificationDate: Date())
        if hit.lineNumber != nil {
            openEditor(targetItem, lineNumber: hit.lineNumber)
        } else {
            selectedPaths = [hit.path]
        }
    }

    private func performArchive(items targetItems: [SFTPItem], format: SFTPArchiveFormat, archiveName: String) {
        guard let s = session, Self.shouldLoadDirectory(for: connectionState) else { return }
        let names = targetItems.map(\.name)
        guard let cmd = SFTPRemoteOperations.archiveCommand(
            items: names,
            inDirectory: currentPath,
            format: format,
            archiveName: archiveName
        ) else {
            setNotice("归档名称或选中项无效", kind: .warning)
            return
        }
        setNotice("正在压缩 \(archiveName)...", kind: .info)
        Task {
            do {
                let output = try await s.executeCommand(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    if output.localizedCaseInsensitiveContains("not found") || output.localizedCaseInsensitiveContains("error") {
                        self.setNotice("压缩失败: \(output)", kind: .error)
                    } else {
                        self.setNotice("已压缩生成 \(archiveName)", kind: .success, autoDismissAfter: 3.0)
                        self.loadDirectory(path: self.currentPath)
                    }
                }
            } catch {
                await MainActor.run {
                    self.setNotice("压缩失败: \(error.localizedDescription)", kind: .error)
                }
            }
        }
    }

    private func performExtract(_ item: SFTPItem) {
        guard let s = session, Self.shouldLoadDirectory(for: connectionState) else { return }
        guard let cmd = SFTPRemoteOperations.extractCommand(archivePath: item.path, targetDirectory: currentPath) else {
            setNotice("不支持该压缩包格式", kind: .warning)
            return
        }
        setNotice("正在解压 \(item.name)...", kind: .info)
        Task {
            do {
                let output = try await s.executeCommand(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    if output.localizedCaseInsensitiveContains("not found") || output.localizedCaseInsensitiveContains("cannot open") {
                        self.setNotice("解压失败: \(output)", kind: .error)
                    } else {
                        self.setNotice("已解压 \(item.name) 至当前目录", kind: .success, autoDismissAfter: 3.0)
                        self.loadDirectory(path: self.currentPath)
                    }
                }
            } catch {
                await MainActor.run {
                    self.setNotice("解压失败: \(error.localizedDescription)", kind: .error)
                }
            }
        }
    }

    private func saveEditedFileAsync(_ item: SFTPItem, content: String) async throws {
        guard let session else { return }
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: localURL) }
        try content.write(to: localURL, atomically: true, encoding: .utf8)
        try await session.uploadFile(localURL: localURL, remotePath: item.path, progress: { _ in })
        await MainActor.run {
            self.loadDirectory(path: self.currentPath)
        }
    }

    private func reloadFileContentAsync(_ item: SFTPItem) async throws -> String {
        guard let session else { return "" }
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: localURL) }
        try await session.downloadFile(remotePath: item.path, localURL: localURL, progress: { _ in })
        let data = try Data(contentsOf: localURL)
        return String(data: data, encoding: .utf8) ??
               String(data: data, encoding: .windowsCP1252) ??
               String(data: data, encoding: .isoLatin1) ??
               String(decoding: data, as: UTF8.self)
    }

    private func handleUploadResult(_ result: Result<String, Error>, fileName: String, targetDirectory: String) {
        DispatchQueue.main.async {
            switch result {
            case .success:
                self.setNotice("上传成功: \(fileName)", kind: .success, isTransferOutcome: true, autoDismissAfter: 3.0)
                self.loadDirectory(path: self.currentPath)
            case .failure(let error):
                if error is CancellationError {
                    self.setNotice("已取消上传: \(fileName)", kind: .cancelled, isTransferOutcome: true)
                    return
                }
                let desc = error.localizedDescription
                if desc.localizedCaseInsensitiveContains("Permission denied") || desc.contains("dest open") {
                    self.setNotice("上传失败：权限不足 (Permission denied)，当前目录无写入权限", kind: .error, isTransferOutcome: true)
                } else {
                    self.setNotice("上传失败: \(desc)", kind: .error, isTransferOutcome: true)
                }
            }
        }
    }

    private func uploadAction() {
        guard Self.shouldLoadDirectory(for: connectionState) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            requestBatchUpload(panel.urls, targetDirectory: currentPath)
        }
    }

    private func requestBatchUpload(_ urls: [URL], targetDirectory: String) {
        guard let session, Self.shouldLoadDirectory(for: connectionState), !urls.isEmpty else { return }
        Task { @MainActor in
            var accesses: [FileAccessLease] = []
            var handedOffToTracker = false
            defer {
                if !handedOffToTracker {
                    accesses.forEach { $0.close() }
                }
            }
            do {
                if DistributionChannel.current == .appStore {
                    for url in urls { accesses.append(try FileAccessStore.shared.acquire(url)) }
                }
                let urls = accesses.isEmpty ? urls : accesses.map(\.url)
                let existing = (try? await session.listDirectory(path: targetDirectory)) ?? []
                let existingNames = Set(existing.map(\.name))
                let conflicts = urls.filter { existingNames.contains($0.lastPathComponent) }
                
                var filesToUpload = urls
                if !conflicts.isEmpty, let window = windowReference.window ?? NSApp.keyWindow ?? NSApp.mainWindow {
                    let alert = NSAlert()
                    alert.messageText = "目标目录已存在同名文件"
                    if conflicts.count == 1 {
                        alert.informativeText = "「\(conflicts[0].lastPathComponent)」已存在于目标目录。替换会覆盖远端内容。"
                        alert.addButton(withTitle: "取消")
                        alert.addButton(withTitle: "替换")
                    } else {
                        alert.informativeText = "检测到 \(conflicts.count) 个同名文件（如「\(conflicts[0].lastPathComponent)」等）。是否覆盖替换？"
                        alert.addButton(withTitle: "取消")
                        alert.addButton(withTitle: "全部替换")
                        alert.addButton(withTitle: "跳过同名文件")
                    }
                    let response = await withCheckedContinuation { continuation in
                        alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                    }
                    if conflicts.count == 1 {
                        guard response == .alertSecondButtonReturn else { return }
                    } else {
                        if response == .alertFirstButtonReturn {
                            return // 取消
                        } else if response == .alertThirdButtonReturn {
                            filesToUpload = urls.filter { !existingNames.contains($0.lastPathComponent) }
                        }
                    }
                }
                
                guard !filesToUpload.isEmpty else { return }

                clearNotice()
                
                let tracker = SFTPBatchTracker(total: filesToUpload.count)
                let retainedAccesses = accesses
                handedOffToTracker = true
                tracker.addCompletionHandler {
                    retainedAccesses.forEach { $0.close() }
                }
                for localURL in filesToUpload {
                    let destination = targetDirectory.hasSuffix("/")
                        ? "\(targetDirectory)\(localURL.lastPathComponent)"
                        : "\(targetDirectory)/\(localURL.lastPathComponent)"
                    
                    TransferManager.shared.enqueueUpload(session: session, localURL: localURL, remotePath: destination, onResult: { result in
                        let outcome: SFTPBatchTracker.Outcome = switch result {
                        case .success: .succeeded
                        case .failure(let error): error is CancellationError ? .cancelled : .failed
                        }
                        let snapshot = tracker.record(outcome)
                        Task { @MainActor in
                            if snapshot.isDone {
                                if snapshot.succeeded > 0 {
                                    self.loadDirectory(path: self.currentPath)
                                }
                                if snapshot.failed > 0 {
                                    let cancelSuffix = snapshot.cancelled > 0 ? "，取消 \(snapshot.cancelled)" : ""
                                    if tracker.total == 1, case .failure(let error) = result {
                                        self.setNotice("上传失败: \(error.localizedDescription)", kind: .error, isTransferOutcome: true)
                                    } else {
                                        self.setNotice("批量上传部分失败（成功 \(snapshot.succeeded)，失败 \(snapshot.failed)\(cancelSuffix)）", kind: .error, isTransferOutcome: true)
                                    }
                                } else if snapshot.cancelled > 0 {
                                    self.setNotice(
                                        snapshot.succeeded > 0
                                            ? "批量上传已取消部分项目（成功 \(snapshot.succeeded)，取消 \(snapshot.cancelled)）"
                                            : "已取消上传: \(localURL.lastPathComponent)",
                                        kind: snapshot.succeeded > 0 ? .warning : .cancelled,
                                        isTransferOutcome: true
                                    )
                                } else {
                                    self.setNotice(
                                        tracker.total == 1
                                            ? "上传成功: \(localURL.lastPathComponent)"
                                            : "批量上传完成 (\(tracker.total) 个文件)",
                                        kind: .success,
                                        isTransferOutcome: true,
                                        autoDismissAfter: 3.0
                                    )
                                }
                            } else if case .failure(let error) = result {
                                if error is CancellationError {
                                    self.setNotice("已取消上传: \(localURL.lastPathComponent)", kind: .cancelled, isTransferOutcome: true)
                                } else {
                                    self.setNotice("上传失败: \(error.localizedDescription)", kind: .error, isTransferOutcome: true)
                                }
                            }
                        }
                    })
                }
            } catch {
                setNotice("上传失败：\(error.localizedDescription)", kind: .error, isTransferOutcome: true)
            }
        }
    }


    private func downloadAction(_ item: SFTPItem) {
        guard let s = session else { return }
        let access: FileAccessLease
        do { access = try downloadDestinationAccess(item) }
        catch is CancellationError { return }
        catch {
            setNotice("无法访问保存位置：\(error.localizedDescription)", kind: .error)
            return
        }
        let localURL = access.url
        clearNotice()
        TransferManager.shared.enqueueDownload(
            session: s,
            remotePath: item.path,
            localURL: localURL,
            totalBytes: Int64(item.size),
            onCompleted: nil,
            onResult: { result in
                access.close()
                Task { @MainActor in
                    switch result {
                    case .success:
                        self.setNotice("下载完成: \(item.name)", kind: .success, isTransferOutcome: true, autoDismissAfter: 3.0)
                    case .failure(let error):
                        self.setNotice(
                            error is CancellationError ? "已取消下载: \(item.name)" : "下载失败: \(error.localizedDescription)",
                            kind: error is CancellationError ? .cancelled : .error,
                            isTransferOutcome: true
                        )
                    }
                }
            }
        )
    }

    /// Handle local file drop from Finder / Desktop
    private func handleDropUpload(providers: [NSItemProvider]) {
        guard session != nil, Self.shouldLoadDirectory(for: connectionState) else { return }
        let targetDirectory = currentPath
        Task {
            var droppedURLs: [URL] = []
            for provider in providers {
                if let url = await loadDroppedURL(from: provider) {
                    droppedURLs.append(url)
                }
            }
            guard !droppedURLs.isEmpty else { return }
            await MainActor.run {
                requestBatchUpload(droppedURLs, targetDirectory: targetDirectory)
            }
        }
    }

    private func loadDroppedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else if let str = item as? String, let url = URL(string: str) {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            } else {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
        }
    }

    /// Returns true for active transfer progress notices already surfaced by TransferInlineProgressBar / TransferDrawer.
    public static func shouldSuppressInlineNotice(_ notice: String) -> Bool {
        notice.hasPrefix("正在上传") ||
        notice.hasPrefix("正在批量上传") ||
        notice.hasPrefix("正在下载")
    }

    private func applyDragExportNotice(_ notice: String) {
        if Self.shouldSuppressInlineNotice(notice) {
            clearNotice()
            return
        }
        if notice.hasPrefix("拖拽导出完成:") {
            setNotice(notice, kind: .success, isTransferOutcome: true, autoDismissAfter: 3.0)
        } else if notice.hasPrefix("拖拽下载已取消:") {
            setNotice(notice, kind: .cancelled, isTransferOutcome: true)
        } else if notice.hasPrefix("拖拽下载失败:") {
            setNotice(notice, kind: .error, isTransferOutcome: true)
        } else {
            setNotice(notice, kind: .info, isTransferOutcome: true)
        }
    }

    /// Handle dragging a remote file item to download to Finder / Desktop / Any local directory
    private func handleDragDownload(for item: SFTPItem) -> NSItemProvider {
        SFTPDragExportHelper.makeItemProvider(for: item, session: session) { [self] notice in
            self.applyDragExportNotice(notice)
        }
    }

    private func fileIcon(for item: SFTPItem) -> String {
        if item.name == ".." { return "arrow.turn.up.left" }
        if item.isDirectory { return "folder.fill" }
        if item.isSymlink { return "arrow.triangle.turn.up.right.diamond.fill" }
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

    private var activeThemePalette: ThemePalette {
        if themeSettings.followsSystemAppearance {
            let isDark: Bool
            if let scheme = ApexStyle.systemColorScheme {
                isDark = (scheme == .dark)
            } else {
                isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
            return (isDark ? TerminalThemePreset.modern : .nativeLight).palette
        }
        return themeSettings.themePreset.palette
    }

    private func calibratedThemeColor(ansiIndex: Int, fallback: Color) -> Color {
        let palette = activeThemePalette
        let index = max(0, min(palette.ansi.count - 1, ansiIndex))
        let hex = ThemePalette.readable(palette.ansi[index], on: [palette.surface, palette.selection])
        return Color(hex: hex) ?? fallback
    }

    private func fileColor(for item: SFTPItem) -> Color {
        if item.isDirectory { return ApexStyle.accent }
        if item.isSymlink { return calibratedThemeColor(ansiIndex: 6, fallback: ApexStyle.accent) }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh": return ApexStyle.success
        case "log": return ApexStyle.warning
        case "tar", "gz", "zip", "bz2": return ApexStyle.warning
        case "conf", "yaml", "yml", "json", "toml", "ini": return calibratedThemeColor(ansiIndex: 5, fallback: ApexStyle.accent)
        default: return ApexStyle.secondary
        }
    }

    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    public static func formatRowDate(_ date: Date) -> String {
        rowDateFormatter.string(from: date)
    }

    private func formatDate(_ date: Date) -> String {
        Self.formatRowDate(date)
    }
}

// MARK: - Native AppKit OutlineView Drag & Drop Bridge
public final class SFTPFilePromiseProvider: NSFilePromiseProvider {
    public let sftpItem: SFTPItem
    private var strongDelegate: SFTPFilePromiseDelegate?

    public init(fileType: String, sftpItem: SFTPItem, delegate: SFTPFilePromiseDelegate) {
        self.sftpItem = sftpItem
        self.strongDelegate = delegate
        super.init()
        self.fileType = fileType
        self.delegate = delegate
        self.userInfo = sftpItem.path
    }
}

public final class SFTPFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    public let item: SFTPItem
    public let session: (any SSHSessionProtocol)?
    public let onStatusChange: (@Sendable @MainActor (String) -> Void)?
    public let onPromiseStarted: (@Sendable @MainActor () -> Void)?
    public let onPromiseFinished: (@Sendable @MainActor () -> Void)?
    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.apexterm.sftp.filepromise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    public init(
        item: SFTPItem,
        session: (any SSHSessionProtocol)?,
        onStatusChange: (@Sendable @MainActor (String) -> Void)? = nil,
        onPromiseStarted: (@Sendable @MainActor () -> Void)? = nil,
        onPromiseFinished: (@Sendable @MainActor () -> Void)? = nil
    ) {
        self.item = item
        self.session = session
        self.onStatusChange = onStatusChange
        self.onPromiseStarted = onPromiseStarted
        self.onPromiseFinished = onPromiseFinished
        super.init()
    }

    public func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.name
    }

    public func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.promiseQueue
    }

    public func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let item = self.item
        let session = self.session
        let onStatusChange = self.onStatusChange
        let onPromiseStarted = self.onPromiseStarted
        let onPromiseFinished = self.onPromiseFinished
        nonisolated(unsafe) let completion = completionHandler
        if let onPromiseStarted {
            Task { @MainActor in onPromiseStarted() }
        }
        Task.detached(priority: .userInitiated) {
            defer {
                if let onPromiseFinished {
                    Task { @MainActor in onPromiseFinished() }
                }
            }
            do {
                _ = try await SFTPDragExportHelper.exportItemToDestination(
                    item: item,
                    session: session,
                    destinationURL: url,
                    onStatusChange: onStatusChange
                )
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}

@MainActor
public final class SFTPOutlineDataSourceProxy: NSObject, NSOutlineViewDataSource {
    nonisolated(unsafe) public weak var originalDataSource: (any NSOutlineViewDataSource)?
    public var items: [SFTPItem] = []
    public var session: (any SSHSessionProtocol)?
    public var acceptsDrops: Bool = true
    public var onDropURLs: (([URL]) -> Void)?
    public var onStatusChange: (@Sendable @MainActor (String) -> Void)?
    private var retainedPromiseProviders: [UUID: SFTPFilePromiseProvider] = [:]
    private var startedPromiseIDs: Set<UUID> = []
    private var pendingSessionProviderIDs: [UUID] = []
    private var activeSessionProviderIDs: [ObjectIdentifier: [UUID]] = [:]

    nonisolated override public func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return originalDataSource?.responds(to: aSelector) ?? false
    }

    nonisolated override public func forwardingTarget(for aSelector: Selector!) -> Any? {
        originalDataSource
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        originalDataSource?.outlineView?(outlineView, numberOfChildrenOfItem: item) ?? (item == nil ? items.count : 0)
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        originalDataSource?.outlineView?(outlineView, isItemExpandable: item) ?? false
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let child = originalDataSource?.outlineView?(outlineView, child: index, ofItem: item) {
            return child
        }
        return index < items.count ? items[index] : NSNull()
    }

    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        let row = outlineView.row(forItem: item)
        guard row >= 0, row < items.count else {
            return originalDataSource?.outlineView?(outlineView, pasteboardWriterForItem: item)
        }
        let sftpItem = items[row]
        guard sftpItem.name != ".." else { return nil }
        let providerID = UUID()
        let provider = SFTPDragExportHelper.makeFilePromiseProvider(
            for: sftpItem,
            session: session,
            onStatusChange: onStatusChange,
            onPromiseStarted: { [weak self] in
                self?.startedPromiseIDs.insert(providerID)
            },
            onPromiseFinished: { [weak self] in
                self?.retainedPromiseProviders.removeValue(forKey: providerID)
                self?.startedPromiseIDs.remove(providerID)
            }
        )
        retainedPromiseProviders[providerID] = provider
        pendingSessionProviderIDs.append(providerID)
        return provider
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        if !pendingSessionProviderIDs.isEmpty {
            activeSessionProviderIDs[ObjectIdentifier(session), default: []].append(contentsOf: pendingSessionProviderIDs)
            pendingSessionProviderIDs.removeAll()
        }
        originalDataSource?.outlineView?(outlineView, draggingSession: session, willBeginAt: screenPoint, forItems: draggedItems)
    }

    public static func clearRowDropTargets(in outlineView: NSOutlineView) {
        outlineView.enumerateAvailableRowViews { rowView, _ in
            if rowView.isTargetForDropOperation {
                rowView.isTargetForDropOperation = false
            }
        }
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        originalDataSource?.outlineView?(outlineView, draggingSession: session, endedAt: screenPoint, operation: operation)
        Self.clearRowDropTargets(in: outlineView)
        var sessionIDs = activeSessionProviderIDs.removeValue(forKey: ObjectIdentifier(session)) ?? []
        if !pendingSessionProviderIDs.isEmpty {
            sessionIDs.append(contentsOf: pendingSessionProviderIDs)
            pendingSessionProviderIDs.removeAll()
        }
        guard !sessionIDs.isEmpty else { return }
        if operation == [] {
            for id in sessionIDs where !startedPromiseIDs.contains(id) {
                retainedPromiseProviders.removeValue(forKey: id)
            }
        } else {
            // Safety cleanup ONLY for this session's providers that never received writePromiseTo.
            // In-flight transfers (startedPromiseIDs) stay retained until their completionHandler finishes.
            let idsToClean = sessionIDs
            DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) { [weak self] in
                guard let self else { return }
                for id in idsToClean where !self.startedPromiseIDs.contains(id) {
                    self.retainedPromiseProviders.removeValue(forKey: id)
                }
            }
        }
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard acceptsDrops else { return [] }
        // Ignore outgoing drags originating from this SFTP outline view itself
        if let sourceOutline = info.draggingSource as? NSOutlineView, sourceOutline === outlineView {
            return []
        }
        if info.draggingPasteboard.types?.contains(NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")) == true {
            return []
        }
        guard info.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else {
            return []
        }
        // NSOutlineView requires setDropItem(_:dropChildIndex:) rather than NSTableView's
        // setDropRow(_:dropOperation:). Calling setDropRow(-1, ...) corrupts _dropRow while
        // leaving _dropItem pointing at the hovered row, leaving rowView.isTargetForDropOperation
        // permanently stuck in bright blue even after drop completion or directory refresh.
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        defer { Self.clearRowDropTargets(in: outlineView) }
        guard acceptsDrops else { return false }
        if let sourceOutline = info.draggingSource as? NSOutlineView, sourceOutline === outlineView {
            return false
        }
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }
        onDropURLs?(urls)
        return true
    }
}

private struct SFTPOutlineViewDragDropBridge: NSViewRepresentable {
    let items: [SFTPItem]
    let session: (any SSHSessionProtocol)?
    let acceptsDrops: Bool
    let onDropURLs: ([URL]) -> Void
    let onStatusChange: @Sendable @MainActor (String) -> Void

    final class BridgeNSView: NSView {
        let proxy = SFTPOutlineDataSourceProxy()
        weak var attachedOutlineView: NSOutlineView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        override func layout() {
            super.layout()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            if let ov = attachedOutlineView, ov.window != nil {
                configure(outlineView: ov)
                return
            }
            var ancestor: NSView? = superview
            for _ in 0..<6 {
                guard let current = ancestor else { break }
                if let ov = Self.findSFTPOutlineView(in: current) {
                    attachedOutlineView = ov
                    configure(outlineView: ov)
                    return
                }
                ancestor = current.superview
            }
        }

        func clearRowDropTargetsIfAttached() {
            if let ov = attachedOutlineView {
                SFTPOutlineDataSourceProxy.clearRowDropTargets(in: ov)
            }
        }

        private func configure(outlineView: NSOutlineView) {
            if outlineView.dataSource !== proxy {
                if let existingProxy = outlineView.dataSource as? SFTPOutlineDataSourceProxy {
                    proxy.originalDataSource = existingProxy.originalDataSource
                } else {
                    proxy.originalDataSource = outlineView.dataSource
                }
                outlineView.dataSource = proxy
            }
            outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
            outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
            if !outlineView.registeredDraggedTypes.contains(.fileURL) {
                outlineView.registerForDraggedTypes([.fileURL])
            }
        }

        private static func findSFTPOutlineView(in view: NSView) -> NSOutlineView? {
            if let ov = view as? NSOutlineView, ov.tableColumns.count == 4 {
                return ov
            }
            for subview in view.subviews {
                if let found = findSFTPOutlineView(in: subview) {
                    return found
                }
            }
            return nil
        }
    }

    func makeNSView(context: Context) -> BridgeNSView {
        let view = BridgeNSView(frame: .zero)
        view.proxy.items = items
        view.proxy.session = session
        view.proxy.acceptsDrops = acceptsDrops
        view.proxy.onDropURLs = onDropURLs
        view.proxy.onStatusChange = onStatusChange
        DispatchQueue.main.async {
            view.attachIfNeeded()
        }
        return view
    }

    func updateNSView(_ nsView: BridgeNSView, context: Context) {
        nsView.proxy.items = items
        nsView.proxy.session = session
        nsView.proxy.acceptsDrops = acceptsDrops
        nsView.proxy.onDropURLs = onDropURLs
        nsView.proxy.onStatusChange = onStatusChange
        nsView.attachIfNeeded()
        nsView.clearRowDropTargetsIfAttached()
        DispatchQueue.main.async {
            nsView.attachIfNeeded()
            nsView.clearRowDropTargetsIfAttached()
        }
    }

    static func dismantleNSView(_ nsView: BridgeNSView, coordinator: ()) {
        if let ov = nsView.attachedOutlineView, ov.dataSource === nsView.proxy {
            ov.dataSource = nsView.proxy.originalDataSource
        }
        nsView.attachedOutlineView = nil
    }
}

// MARK: - SFTP Drag & Drop Export Helper
public enum SFTPDragExportHelper {
    /// Removes stale temporary drag-export directories older than `maxAgeSeconds` (default 1 hour).
    @discardableResult
    public static func cleanupStaleDragExportDirectories(
        in rootDir: URL? = nil,
        olderThan maxAgeSeconds: TimeInterval = 3600,
        now: Date = Date()
    ) -> Int {
        let baseDir = rootDir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexTermTransfers", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var removedCount = 0
        for url in children {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let timestamp = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
            if now.timeIntervalSince(timestamp) >= maxAgeSeconds {
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    removedCount += 1
                }
            }
        }
        return removedCount
    }

    /// Creates a native AppKit `NSFilePromiseProvider` for dragging a remote file or directory
    /// from the SFTP browser to any local folder in Finder / Desktop.
    public static func makeFilePromiseProvider(
        for item: SFTPItem,
        session: (any SSHSessionProtocol)?,
        onStatusChange: (@Sendable @MainActor (String) -> Void)? = nil,
        onPromiseStarted: (@Sendable @MainActor () -> Void)? = nil,
        onPromiseFinished: (@Sendable @MainActor () -> Void)? = nil
    ) -> SFTPFilePromiseProvider {
        let fileType = item.isDirectory ? UTType.folder.identifier : UTType.data.identifier
        let delegate = SFTPFilePromiseDelegate(
            item: item,
            session: session,
            onStatusChange: onStatusChange,
            onPromiseStarted: onPromiseStarted,
            onPromiseFinished: onPromiseFinished
        )
        return SFTPFilePromiseProvider(
            fileType: fileType,
            sftpItem: item,
            delegate: delegate
        )
    }

    /// Downloads `item` from `session` and places it at `destinationURL` (or inside a temporary
    /// staging directory when `destinationURL` is nil), updating `TransferManager` throughout.
    @discardableResult
    public static func exportItemToDestination(
        item: SFTPItem,
        session: (any SSHSessionProtocol)?,
        destinationURL: URL? = nil,
        onStatusChange: (@Sendable @MainActor (String) -> Void)? = nil
    ) async throws -> URL {
        guard let session else {
            throw NSError(
                domain: "SFTPDragExport",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No active SSH session"]
            )
        }
        let transfersRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexTermTransfers", isDirectory: true)
        _ = cleanupStaleDragExportDirectories(in: transfersRoot)
        let tempDir = transfersRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagingURL = tempDir.appendingPathComponent(item.name)
        let recordedLocalURL = destinationURL ?? stagingURL
        let taskId = UUID()

        await Self.dispatchMainActorNonBlocking {
            TransferManager.shared.beginExternalTransfer(
                id: taskId,
                fileName: item.name,
                remotePath: item.path,
                localURL: recordedLocalURL,
                direction: .download,
                totalBytes: Int64(item.size)
            )
            onStatusChange?("正在下载并导出: \(item.name)...")
        }
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let expectedBytes = Int64(clamping: item.size)
            let progressMonitor = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    let bytes = TransferManager.currentTransferredBytes(at: stagingURL)
                    if bytes > 0 {
                        Task { @MainActor in
                            TransferManager.shared.updateExternalProgress(
                                taskId: taskId,
                                fraction: expectedBytes > 0 ? min(Double(bytes) / Double(expectedBytes), 1) : 0,
                                transferredBytes: bytes
                            )
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { progressMonitor.cancel() }
            try await session.downloadFile(remotePath: item.path, localURL: stagingURL) { fraction in
                Task { @MainActor in
                    TransferManager.shared.updateExternalProgress(taskId: taskId, fraction: fraction)
                }
            }
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: stagingURL.path) else {
                throw NSError(
                    domain: "SFTPDragExport",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "导出临时文件不存在: \(item.name)"]
                )
            }
            let finalURL: URL
            if let destinationURL {
                let parentDir = destinationURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
                try? FileManager.default.removeItem(at: tempDir)
                guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw NSError(
                        domain: "SFTPDragExport",
                        code: 501,
                        userInfo: [NSLocalizedDescriptionKey: "目标目录写入失败: \(destinationURL.path)"]
                    )
                }
                finalURL = destinationURL
            } else {
                finalURL = stagingURL
            }
            await Self.dispatchMainActorNonBlocking {
                TransferManager.shared.completeExternalTransfer(taskId: taskId)
                onStatusChange?("拖拽导出完成: \(item.name)")
            }
            return finalURL
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: tempDir)
            await Self.dispatchMainActorNonBlocking {
                if error is CancellationError {
                    TransferManager.shared.cancelExternalTransfer(taskId: taskId)
                    onStatusChange?("拖拽下载已取消: \(item.name)")
                } else {
                    TransferManager.shared.failExternalTransfer(taskId: taskId, error: error)
                    onStatusChange?("拖拽下载失败: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    public static func makeItemProvider(
        for item: SFTPItem,
        session: (any SSHSessionProtocol)?,
        onStatusChange: (@Sendable @MainActor (String) -> Void)? = nil
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name

        let export = SFTPExportDownload {
            try await exportItemToDestination(
                item: item,
                session: session,
                destinationURL: nil,
                onStatusChange: onStatusChange
            )
        }
        let loadHandler: @Sendable (@escaping @Sendable (URL?, Bool, (any Error)?) -> Void) -> Progress? = { completion in
            let progress = Progress(totalUnitCount: Int64(max(item.size, 1)))
            progress.cancellationHandler = {
                Task { await export.cancel() }
            }
            Task {
                do {
                    guard !progress.isCancelled else { throw CancellationError() }
                    let url = try await export.value()
                    guard !progress.isCancelled else { throw CancellationError() }
                    progress.completedUnitCount = progress.totalUnitCount
                    completion(url, false, nil)
                } catch { completion(nil, false, error) }
            }
            return progress
        }

        let ext = (item.name as NSString).pathExtension
        let specificType: UTType = item.isDirectory ? .folder : (UTType(filenameExtension: ext) ?? .data)
        if item.isDirectory {
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.folder.identifier,
                fileOptions: [],
                visibility: .all,
                loadHandler: loadHandler
            )
        } else {
            provider.registerFileRepresentation(
                forTypeIdentifier: UTType.data.identifier,
                fileOptions: [],
                visibility: .all,
                loadHandler: loadHandler
            )
            if specificType != .data && specificType != .fileURL && !specificType.conforms(to: .url) {
                provider.registerFileRepresentation(
                    forTypeIdentifier: specificType.identifier,
                    fileOptions: [],
                    visibility: .all,
                    loadHandler: loadHandler
                )
            }
        }

        return provider
    }

    /// Dispatches a `@MainActor` closure in FIFO order without deadlocking when AppKit/SwiftUI
    /// synchronously blocks the main thread inside `NSItemProvider.loadURLSynchronously(for:)`.
    /// When the main actor is free (e.g., async file promise loading or unit tests), this awaits
    /// completion deterministically; when the main thread is blocked on a semaphore waiting for
    /// the `NSItemProvider` load handler, the timeout expires so the export finishes and unblocks
    /// the main thread semaphore, after which the queued `@MainActor` task runs immediately.
    private static func dispatchMainActorNonBlocking(
        _ operation: @escaping @Sendable @MainActor () -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce() {
                let shouldResume = resumed.withLock { state -> Bool in
                    guard !state else { return false }
                    state = true
                    return true
                }
                if shouldResume {
                    continuation.resume()
                }
            }
            Task { @MainActor in
                operation()
                resumeOnce()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(25)) {
                resumeOnce()
            }
        }
    }
}


/// Shares a single lazy download across the representations requested by Finder.
private actor SFTPExportDownload {
    private let operation: @Sendable () async throws -> URL
    private var task: Task<URL, Error>?
    private var isCancelled = false

    init(operation: @escaping @Sendable () async throws -> URL) { self.operation = operation }

    func value() async throws -> URL {
        guard !isCancelled else { throw CancellationError() }
        if task == nil { task = Task { try await operation() } }
        return try await task!.value
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }
}

// MARK: - Unified 24pt Toolbar Chip & Transfer Trigger
private struct SFTPToolbarChip<Icon: View>: View {
    let title: String?
    let compact: Bool
    let isHighlighted: Bool
    let tint: Color
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    init(
        title: String?,
        compact: Bool = false,
        isHighlighted: Bool = false,
        tint: Color = ApexStyle.accent,
        action: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.title = title
        self.compact = compact
        self.isHighlighted = isHighlighted
        self.tint = tint
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon()
                if !compact, let title {
                    Text(title)
                        .font(.system(size: 11, weight: isHighlighted ? .semibold : .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isHighlighted ? tint : ApexStyle.primary)
            .padding(.horizontal, compact ? 6 : 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .fill(
                        isHighlighted
                            ? tint.opacity(isHovered && isEnabled ? 0.20 : 0.14)
                            : (isHovered && isEnabled ? ApexStyle.primary.opacity(0.06) : ApexStyle.subtleSurface)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .stroke(
                        isHighlighted
                            ? tint.opacity(isHovered && isEnabled ? 0.55 : 0.40)
                            : ApexStyle.border.opacity(isHovered && isEnabled ? 0.95 : 0.70),
                        lineWidth: 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
            .opacity(isEnabled ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(ApexStyle.hoverTransition) {
                isHovered = hovering
            }
        }
    }
}

private struct SFTPExternalEditPopover: View {
    @ObservedObject var manager: ExternalEditSessionManager
    let sessions: [ExternalEditSessionManager.ActiveEditSession]
    let onClose: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ApexStyle.accent)
                Text("外部编辑实时同步 (\(sessions.count))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 8)
                Toggle("自动上传", isOn: $manager.autoUploadOnSave)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .help("开启后，外部编辑器保存文件且内容变化时将自动回传至服务器")
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 10)
            .background(ApexStyle.subtleSurface)

            Divider()

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, editSession in
                        if index > 0 {
                            Divider()
                        }
                        sessionRow(editSession)
                    }
                }
            }
            .frame(maxHeight: 240)

            Divider()

            HStack(spacing: 8) {
                Text("SHA-256 校验 · 保存后自动同步")
                    .font(.caption2)
                    .foregroundStyle(ApexStyle.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if sessions.count > 1 {
                    ApexActionButton("全部停止", tint: ApexStyle.error, size: .small) {
                        for item in sessions {
                            manager.stopSession(id: item.id)
                        }
                        onClose()
                    }
                }
                ApexActionButton("关闭", tint: ApexStyle.secondary, size: .small) {
                    onClose()
                }
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 8)
            .background(ApexStyle.subtleSurface)
        }
        .frame(width: 360)
        .background(ApexStyle.surface)
    }

    @ViewBuilder
    private func sessionRow(_ editSession: ExternalEditSessionManager.ActiveEditSession) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(editSession.fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ApexStyle.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(editSession.editorName) · \(editSession.remotePath)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ApexStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(editSession.remotePath)

                statusLabel(for: editSession)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                ApexIconButton(
                    icon: "arrow.up.circle",
                    label: "立即上传同步",
                    size: 24,
                    iconSize: 12,
                    tint: editSession.status.isError ? ApexStyle.error : ApexStyle.accent
                ) {
                    Task {
                        await manager.triggerManualUpload(id: editSession.id)
                    }
                }
                .disabled(editSession.status.isBusy)

                ApexIconButton(
                    icon: "arrow.up.forward.app",
                    label: "在外部编辑器中打开",
                    size: 24,
                    iconSize: 11
                ) {
                    Task {
                        try? await manager.reopenInEditor(id: editSession.id)
                    }
                }

                ApexIconButton(
                    icon: "stop.circle",
                    label: "停止监听并清理临时文件",
                    size: 24,
                    iconSize: 12,
                    tint: ApexStyle.secondary
                ) {
                    manager.stopSession(id: editSession.id)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusLabel(for editSession: ExternalEditSessionManager.ActiveEditSession) -> some View {
        switch editSession.status {
        case .downloading:
            Text("正在下载到本地临时区…")
                .font(.caption2)
                .foregroundStyle(ApexStyle.accent)
        case .watching:
            Text(manager.autoUploadOnSave ? "监听修改中" : "已暂停自动上传（可手动同步）")
                .font(.caption2)
                .foregroundStyle(manager.autoUploadOnSave ? ApexStyle.secondary : ApexStyle.warning)
        case .uploading:
            Text("正在同步上传…")
                .font(.caption2)
                .foregroundStyle(ApexStyle.accent)
        case .synced:
            let timeText = editSession.lastSyncedAt.map { " · \(Self.timeFormatter.string(from: $0))" } ?? ""
            Text("已同步\(timeText)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(ApexStyle.success)
        case .error(let message):
            Text("同步失败：\(message)")
                .font(.caption2)
                .foregroundStyle(ApexStyle.error)
                .lineLimit(2)
                .help(message)
        }
    }
}

struct TransferToolbarButton: View {
    @ObservedObject private var transferManager = TransferManager.shared
    @Binding var isExpanded: Bool
    var compact = false

    private var title: String {
        if transferManager.activeCount > 0 { return "传输中 (\(transferManager.activeCount))" }
        if !transferManager.tasks.isEmpty { return "传输记录 (\(transferManager.tasks.count))" }
        return "传输记录"
    }

    var body: some View {
        let isHighlighted = isExpanded || transferManager.activeCount > 0
        SFTPToolbarChip(
            title: title,
            compact: compact,
            isHighlighted: isHighlighted
        ) {
            withAnimation(ApexStyle.springSnappy) {
                isExpanded.toggle()
            }
        } icon: {
            TransferActivitySymbol(
                isActive: transferManager.activeCount > 0,
                inactiveSystemName: "arrow.up.arrow.down.circle"
            )
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
        .help(isExpanded ? "收起传输记录面板" : "展开传输记录面板")
    }
}
