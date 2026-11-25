import SwiftUI
import ApexCore
import ApexSSH

/// Shared presentation state for the non-blocking transfer drawer across SFTP and Workspace status bar.
@MainActor
public final class TransferDrawerPresentation: ObservableObject {
    @Published public var isPresented: Bool = false

    public init() {}

    public func toggle() {
        isPresented.toggle()
    }

    public func open() {
        isPresented = true
    }

    public func close() {
        isPresented = false
    }
}

/// Adaptive embedding mode for the SFTP-docked transfer drawer.
public enum SFTPTransferDrawerMode: Equatable, Sendable {
    case collapsed
    case fillSFTPArea
    case dockedSplit(drawerHeight: CGFloat)
}

/// Computes whether the embedded transfer drawer splits SFTP height or replaces the file table area on compact screens.
public enum SFTPTransferDrawerLayout {
    nonisolated public static let splitThresholdHeight: CGFloat = 300
    nonisolated public static let minFileListHeightInSplit: CGFloat = 120
    nonisolated public static let minSplitDrawerHeight: CGFloat = 180
    nonisolated public static let maxSplitDrawerHeight: CGFloat = 240

    nonisolated public static func resolve(isExpanded: Bool, availableHeight: CGFloat) -> SFTPTransferDrawerMode {
        guard isExpanded, availableHeight > 0 else { return .collapsed }
        if availableHeight < splitThresholdHeight {
            return .fillSFTPArea
        }
        let ideal = floor(availableHeight * 0.48)
        let maxAllowed = max(minSplitDrawerHeight, availableHeight - minFileListHeightInSplit)
        let height = min(max(ideal, minSplitDrawerHeight), min(maxSplitDrawerHeight, maxAllowed))
        return .dockedSplit(drawerHeight: height)
    }
}

/// Pure summary snapshot driving the automatic inline live transfer progress strip.
public struct TransferProgressSummary: Equatable, Sendable {
    public let primaryTask: TransferTask
    public let activeCount: Int
    public let otherActiveCount: Int
    public let progressFraction: Double?
    public let percentText: String
    public let bytesText: String
    public let speedText: String

    public static func make(from tasks: [TransferTask], formattedTotalSpeed: String) -> TransferProgressSummary? {
        let activeTasks = tasks.filter { $0.status == .transferring || $0.status == .queued }
        guard !activeTasks.isEmpty else { return nil }

        let primary = activeTasks.first(where: { $0.status == .transferring }) ?? activeTasks[0]
        let otherActiveCount = max(0, activeTasks.count - 1)
        let progressFraction: Double? = primary.totalBytes > 0 ? primary.progress : nil

        let percentText: String
        if primary.totalBytes > 0 {
            percentText = primary.formattedProgress
        } else if primary.status == .queued {
            percentText = "等待中"
        } else if primary.transferredBytes > 0 {
            percentText = "传输中"
        } else {
            percentText = "准备中…"
        }

        let bytesText: String
        if primary.totalBytes > 0 {
            bytesText = "\(formatByteCount(primary.transferredBytes)) / \(formatByteCount(primary.totalBytes))"
        } else if primary.transferredBytes > 0 {
            bytesText = formatByteCount(primary.transferredBytes)
        } else {
            bytesText = ""
        }

        let speedText = activeTasks.count > 1 ? formattedTotalSpeed : primary.formattedSpeed

        return TransferProgressSummary(
            primaryTask: primary,
            activeCount: activeTasks.count,
            otherActiveCount: otherActiveCount,
            progressFraction: progressFraction,
            percentText: percentText,
            bytesText: bytesText,
            speedText: speedText
        )
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Reusable smooth linear progress bar supporting determinate capsule fill and indeterminate pulse.
public struct ApexTransferProgressTrack: View {
    public let fraction: Double?
    public let tint: Color
    public let height: CGFloat

    public init(fraction: Double?, tint: Color = ApexStyle.accent, height: CGFloat = 6) {
        self.fraction = fraction
        self.tint = tint
        self.height = height
    }

    public var body: some View {
        if let fraction {
            let clamped = CGFloat(min(max(fraction, 0), 1))
            GeometryReader { geo in
                let fullWidth = max(0, geo.size.width)
                let fillWidth = clamped > 0 ? max(min(height, fullWidth), fullWidth * clamped) : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ApexStyle.primary.opacity(0.08))
                        .overlay(
                            Capsule()
                                .stroke(ApexStyle.border.opacity(0.45), lineWidth: 0.5)
                        )

                    if fillWidth > 0 {
                        Capsule()
                            .fill(tint)
                            .frame(width: min(fullWidth, fillWidth))
                    }
                }
            }
            .frame(height: height)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(tint)
                .frame(height: height)
        }
    }
}

/// Isolated single-row live progress bar docked inside SFTPView whenever transfers are active.
public struct TransferInlineProgressBar: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject private var manager: TransferManager
    @Binding var isDrawerExpanded: Bool
    @State private var barWidth: CGFloat = 640

    public init(isDrawerExpanded: Binding<Bool>, manager: TransferManager = .shared) {
        self._isDrawerExpanded = isDrawerExpanded
        self._manager = ObservedObject(wrappedValue: manager)
    }

    public var body: some View {
        if let summary = TransferProgressSummary.make(
            from: manager.tasks,
            formattedTotalSpeed: manager.formattedTotalSpeed
        ) {
            let directionTint = summary.primaryTask.direction == .upload ? ApexStyle.accent : ApexStyle.success
            let directionIcon = summary.primaryTask.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
            let detailParts = [summary.bytesText, summary.speedText].filter { !$0.isEmpty }.joined(separator: " · ")
            let showDetails = barWidth >= 480
            let showTrack = barWidth >= 280
            let isUltraCompact = barWidth < 330
            let mainLabel = summary.otherActiveCount > 0
                ? "展开传输任务列表，正在传输 \(summary.primaryTask.fileName) 等 \(summary.activeCount) 个任务，\(summary.percentText)"
                : "展开传输任务列表，\(summary.primaryTask.fileName)，\(summary.percentText)"

            VStack(spacing: 0) {
                Divider()

                HStack(spacing: isUltraCompact ? 6 : 8) {
                    Button {
                        withAnimation(ApexStyle.springSnappy) {
                            isDrawerExpanded = true
                        }
                    } label: {
                        HStack(spacing: isUltraCompact ? 6 : 8) {
                            Image(systemName: directionIcon)
                                .font(.system(size: 13))
                                .foregroundColor(directionTint)
                                .frame(width: 16, alignment: .center)

                            Text(summary.primaryTask.fileName)
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundColor(ApexStyle.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)

                            if summary.otherActiveCount > 0 {
                                Text("+\(summary.otherActiveCount) 项")
                                    .font(.system(size: 10, weight: .semibold))
                                    .monospacedDigit()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(ApexStyle.accent.opacity(0.14), in: Capsule())
                                    .foregroundColor(ApexStyle.accent)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            Spacer(minLength: isUltraCompact ? 4 : 8)

                            if showTrack {
                                ApexTransferProgressTrack(
                                    fraction: summary.progressFraction,
                                    tint: directionTint,
                                    height: 6
                                )
                                .frame(
                                    minWidth: showDetails ? 72 : 44,
                                    idealWidth: showDetails ? 112 : 76,
                                    maxWidth: showDetails ? 128 : 96
                                )
                            }

                            Text(summary.percentText)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(directionTint)
                                .frame(minWidth: isUltraCompact ? 28 : 36, alignment: .trailing)
                                .fixedSize(horizontal: true, vertical: false)

                            if showDetails, !detailParts.isEmpty {
                                Text(detailParts)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundColor(ApexStyle.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mainLabel)
                    .help("点击展开传输任务列表")

                    Divider().frame(height: 14)

                    HStack(spacing: 4) {
                        ApexIconButton(
                            icon: "xmark",
                            label: "取消传输 \(summary.primaryTask.fileName)",
                            size: 22,
                            iconSize: 9.5
                        ) {
                            manager.cancelTask(id: summary.primaryTask.id)
                        }

                        ApexIconButton(
                            icon: "chevron.up",
                            label: "展开传输任务列表",
                            size: 22,
                            iconSize: 9.5
                        ) {
                            withAnimation(ApexStyle.springSnappy) {
                                isDrawerExpanded = true
                            }
                        }
                    }
                    .fixedSize()
                }
                .padding(.horizontal, ApexStyle.s4)
                .frame(height: 34)
                .background(ApexStyle.subtleSurface)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transfer.inlineProgressBar")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Non-blocking transfer task list drawer with unified pinned header across all category filters.
public struct TransferDrawer: View {
    @ObservedObject private var themeSettings = AppSettings.shared

    public enum TransferFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case uploads = "上传"
        case downloads = "下载"
        public var id: String { rawValue }
    }

    @ObservedObject private var manager: TransferManager
    @Binding var isExpanded: Bool
    @State private var filter: TransferFilter
    @State private var drawerWidth: CGFloat = 600
    private let showsCollapsedPill: Bool

    public init(
        isExpanded: Binding<Bool>,
        manager: TransferManager = .shared,
        initialFilter: TransferFilter = .all,
        showsCollapsedPill: Bool = false
    ) {
        self._isExpanded = isExpanded
        self._manager = ObservedObject(wrappedValue: manager)
        self._filter = State(initialValue: initialFilter)
        self.showsCollapsedPill = showsCollapsedPill
    }

    private var filteredTasks: [TransferTask] {
        switch filter {
        case .all: return manager.tasks
        case .uploads: return manager.tasks.filter { $0.direction == .upload }
        case .downloads: return manager.tasks.filter { $0.direction == .download }
        }
    }

    private func count(for f: TransferFilter) -> Int {
        switch f {
        case .all: return manager.tasks.count
        case .uploads: return manager.tasks.filter { $0.direction == .upload }.count
        case .downloads: return manager.tasks.filter { $0.direction == .download }.count
        }
    }

    private var emptyStateIcon: String {
        guard !manager.tasks.isEmpty else { return "tray" }
        switch filter {
        case .all: return "tray"
        case .uploads: return "arrow.up.circle"
        case .downloads: return "arrow.down.circle"
        }
    }

    private var emptyStateMessage: String {
        guard !manager.tasks.isEmpty else {
            return "暂无传输任务（支持拖拽或点击上传与下载）"
        }
        switch filter {
        case .all: return "当前分类暂无任务"
        case .uploads: return "暂无上传任务"
        case .downloads: return "暂无下载任务"
        }
    }

    public var body: some View {
        if isExpanded {
            let isCompactHeader = drawerWidth < 460
            let isUltraCompactHeader = drawerWidth < 340
            let stacksHeader = drawerWidth < 280
            let hasTerminalTasks = manager.tasks.contains(where: { $0.status.isTerminal })

            VStack(spacing: 0) {
                // Pinned Header (identical height and alignment across all filters)
                Group {
                    if stacksHeader {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                drawerTitleView(compact: true)
                                Spacer(minLength: 4)
                                drawerClearButton(iconOnly: true, visible: hasTerminalTasks)
                                drawerCloseButton
                            }
                            drawerFilterPicker(compactLabels: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 8)
                    } else {
                        HStack(spacing: isCompactHeader ? 6 : 8) {
                            drawerTitleView(compact: isUltraCompactHeader)
                            Spacer(minLength: isCompactHeader ? 4 : 8)
                            drawerFilterPicker(compactLabels: isCompactHeader)
                            drawerClearButton(iconOnly: isCompactHeader, visible: hasTerminalTasks)
                            drawerCloseButton
                        }
                        .frame(height: 40)
                    }
                }
                .padding(.horizontal, ApexStyle.s4)
                .background(ApexStyle.surface)

                Divider()

                // Unified full-height task body so empty & non-empty categories share exact geometry
                ZStack {
                    if filteredTasks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: emptyStateIcon)
                                .font(.system(size: 22))
                                .foregroundColor(ApexStyle.secondary)
                            Text(emptyStateMessage)
                                .font(.system(size: 12))
                                .foregroundColor(ApexStyle.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, ApexStyle.s4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("transfer.emptyState")
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 8) {
                                ForEach(filteredTasks) { task in
                                    TransferTaskRow(task: task) {
                                        if task.status.isTerminal {
                                            manager.removeTask(id: task.id)
                                        } else {
                                            manager.cancelTask(id: task.id)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, ApexStyle.s4)
                            .padding(.vertical, 10)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .accessibilityIdentifier("transfer.taskList")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ApexStyle.surface)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { drawerWidth = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transfer.drawer")
        } else if showsCollapsedPill && (manager.activeCount > 0 || !manager.tasks.isEmpty) {
            Button {
                withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        TransferActivitySymbol(
                            isActive: manager.activeCount > 0,
                            inactiveSystemName: "checkmark.circle.fill"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(manager.activeCount > 0 ? ApexStyle.accent : ApexStyle.success)

                        Text(manager.activeCount > 0 ? "传输中 (\(manager.activeCount))" : "传输记录 (\(manager.tasks.count))")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                    }

                    if manager.activeCount > 0 {
                        Text("·")
                            .foregroundColor(ApexStyle.secondary)
                        Text(manager.formattedTotalSpeed)
                            .font(.system(size: 11, design: .monospaced))
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundColor(ApexStyle.accent)
                    }

                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(ApexStyle.secondary)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .apexGlassCard(cornerRadius: 16, material: .regularMaterial, borderColor: ApexStyle.border.opacity(0.8), shadowRadius: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展开传输任务")
            .padding(.trailing, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func drawerTitleView(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .foregroundColor(ApexStyle.accent)
                .font(.system(size: 14))
            Text(compact ? "传输 (\(manager.tasks.count))" : "传输任务 (\(manager.tasks.count))")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func drawerFilterPicker(compactLabels: Bool) -> some View {
        Picker("", selection: $filter) {
            ForEach(TransferFilter.allCases) { f in
                Text(compactLabels ? f.rawValue : "\(f.rawValue) (\(count(for: f)))")
                    .monospacedDigit()
                    .tag(f)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("transfer.filterPicker")
    }

    @ViewBuilder
    private func drawerClearButton(iconOnly: Bool, visible: Bool) -> some View {
        if visible {
            if iconOnly {
                ApexIconButton(
                    icon: "trash",
                    label: "清空记录",
                    size: 22,
                    iconSize: 10
                ) {
                    manager.clearCompleted()
                }
                .accessibilityLabel("清空记录")
            } else {
                ApexActionButton(
                    "清空记录",
                    icon: "trash",
                    tint: ApexStyle.secondary,
                    size: .small
                ) {
                    manager.clearCompleted()
                }
                .accessibilityLabel("清空记录")
            }
        }
    }

    private var drawerCloseButton: some View {
        ApexIconButton(
            icon: "xmark",
            label: "收起传输任务",
            size: 22,
            iconSize: 10
        ) {
            withAnimation(.spring(duration: 0.25)) { isExpanded = false }
        }
        .accessibilityIdentifier("transfer.closeButton")
    }
}

private struct TransferTaskRow: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    let task: TransferTask
    let onCancel: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Direction tag
                Text(task.direction == .upload ? "上传" : "下载")
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(task.direction == .upload ? ApexStyle.accent.opacity(0.18) : ApexStyle.success.opacity(0.18))
                    .foregroundColor(task.direction == .upload ? ApexStyle.accent : ApexStyle.success)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Image(systemName: task.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(task.direction == .upload ? ApexStyle.accent : ApexStyle.success)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.fileName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Path detail
                    Text(pathDescription)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        Text(statusLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(statusColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                            .help(statusLabel)

                        if task.status == .transferring {
                            Text("·")
                                .foregroundColor(ApexStyle.secondary)
                            Text(task.formattedSpeed)
                                .font(.system(size: 10, design: .monospaced))
                                .monospacedDigit()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundColor(ApexStyle.accent)
                            if task.totalBytes > 0 {
                                Text("·")
                                    .foregroundColor(ApexStyle.secondary)
                                Text("\(formattedBytes(task.transferredBytes)) / \(formattedBytes(task.totalBytes))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .foregroundColor(ApexStyle.secondary)
                            } else if task.transferredBytes > 0 {
                                Text("·")
                                    .foregroundColor(ApexStyle.secondary)
                                Text(formattedBytes(task.transferredBytes))
                                    .font(.system(size: 10, design: .monospaced))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .foregroundColor(ApexStyle.secondary)
                            }
                        } else {
                            let displayBytes = max(task.totalBytes, task.transferredBytes)
                            if displayBytes > 0 {
                                Text("·")
                                    .foregroundColor(ApexStyle.secondary)
                                Text(formattedBytes(displayBytes))
                                    .font(.system(size: 10, design: .monospaced))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundColor(ApexStyle.secondary)
                            }
                            if let date = task.completedAt ?? task.startedAt as Date? {
                                Text("·")
                                    .foregroundColor(ApexStyle.secondary)
                                Text(Self.timeFormatter.string(from: date))
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundColor(ApexStyle.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                if task.status == .transferring || task.status == .queued {
                    if task.totalBytes > 0 {
                        Text(task.formattedProgress)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(ApexStyle.accent)
                            .frame(minWidth: 36, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                    } else if task.transferredBytes > 0 {
                        Text(formattedBytes(task.transferredBytes))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(ApexStyle.accent)
                            .frame(minWidth: 36, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Text(task.status == .queued ? "等待中" : "准备中…")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(ApexStyle.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    ApexIconButton(
                        icon: "xmark",
                        label: "取消传输 \(task.fileName)",
                        size: 20,
                        iconSize: 9
                    ) {
                        onCancel()
                    }
                    .padding(.leading, 2)
                } else if task.status == .completed {
                    HStack(spacing: 6) {
                        // Reveal in Finder button for downloads
                        if task.direction == .download && FileManager.default.fileExists(atPath: task.localURL.path) {
                            ApexIconButton(
                                icon: "magnifyingglass",
                                label: "在访达中显示此文件",
                                size: 20,
                                iconSize: 10
                            ) {
                                NSWorkspace.shared.activateFileViewerSelecting([task.localURL])
                            }
                        }

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(ApexStyle.success)
                            .help("传输完成")
                            .accessibilityLabel("传输完成")

                        ApexIconButton(
                            icon: "xmark",
                            label: "移除已完成记录 \(task.fileName)",
                            size: 20,
                            iconSize: 9
                        ) {
                            onCancel()
                        }
                    }
                } else if case .failed = task.status {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(ApexStyle.error)
                            .help(statusLabel)
                            .accessibilityLabel(statusLabel)

                        ApexIconButton(
                            icon: "xmark",
                            label: "移除失败记录 \(task.fileName)",
                            size: 20,
                            iconSize: 9
                        ) {
                            onCancel()
                        }
                    }
                } else if task.status == .cancelled {
                    HStack(spacing: 6) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 13))
                            .foregroundColor(ApexStyle.secondary)
                            .help("已取消")
                            .accessibilityLabel("已取消")

                        ApexIconButton(
                            icon: "xmark",
                            label: "移除已取消记录 \(task.fileName)",
                            size: 20,
                            iconSize: 9
                        ) {
                            onCancel()
                        }
                    }
                }
            }

            if task.status == .transferring || task.status == .queued {
                ApexTransferProgressTrack(
                    fraction: task.totalBytes > 0 ? task.progress : nil,
                    tint: task.direction == .upload ? ApexStyle.accent : ApexStyle.success,
                    height: 5
                )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ApexStyle.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ApexStyle.border.opacity(0.45), lineWidth: 0.75)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var pathDescription: String {
        if task.direction == .upload {
            return "\(task.localURL.lastPathComponent) → \(task.remotePath)"
        } else {
            return "\(task.remotePath) → \(task.localURL.path)"
        }
    }

    private var statusLabel: String {
        switch task.status {
        case .queued: return "等待中"
        case .transferring: return task.direction == .upload ? "正在上传" : "正在下载"
        case .completed: return "传输完成"
        case .failed(let err): return "传输失败: \(err)"
        case .cancelled: return "已取消"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .queued: return ApexStyle.secondary
        case .transferring: return ApexStyle.accent
        case .completed: return ApexStyle.success
        case .failed: return ApexStyle.error
        case .cancelled: return ApexStyle.secondary
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
