import SwiftUI
import ApexCore

/// Preview sheet displaying added, modified, and deleted items before applying an iCloud sync strategy.
public struct iCloudConflictDiffSheet: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    public let diff: iCloudSyncDiff?
    public let isLoading: Bool
    public let errorMessage: String?
    public let onRefresh: (() -> Void)?
    public let onApplyStrategy: (iCloudConflictStrategy) -> Void

    @State private var selectedDomain: iCloudSyncDiffDomain? = nil

    public init(
        diff: iCloudSyncDiff?,
        isLoading: Bool = false,
        errorMessage: String? = nil,
        onRefresh: (() -> Void)? = nil,
        onApplyStrategy: @escaping (iCloudConflictStrategy) -> Void
    ) {
        self.diff = diff
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRefresh = onRefresh
        self.onApplyStrategy = onApplyStrategy
    }

    private var filteredAdded: [iCloudSyncDiffItem] {
        filterByDomain(diff?.added ?? [])
    }

    private var filteredModified: [iCloudSyncDiffItem] {
        filterByDomain(diff?.modified ?? [])
    }

    private var filteredDeleted: [iCloudSyncDiffItem] {
        filterByDomain(diff?.deleted ?? [])
    }

    private func filterByDomain(_ items: [iCloudSyncDiffItem]) -> [iCloudSyncDiffItem] {
        guard let selectedDomain else { return items }
        return items.filter { $0.domain == selectedDomain }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: ApexStyle.s3) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ApexStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud 同步差异预览")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ApexStyle.primary)

                    if let diff, let device = diff.remoteDeviceName {
                        Text("远端设备：\(device)\(diff.remoteLastModified.map { " · 更新于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(ApexStyle.secondary)
                    } else {
                        Text("比对本机配置与 iCloud 云端文档的新增、变更及墓碑删除项")
                            .font(.caption)
                            .foregroundStyle(ApexStyle.secondary)
                    }
                }

                Spacer()

                if let onRefresh {
                    ApexIconButton(icon: "arrow.clockwise", label: "重新比对差异", size: 26, iconSize: 11) {
                        onRefresh()
                    }
                    .disabled(isLoading)
                }

                ApexIconButton(icon: "xmark", label: "关闭 (Esc)", size: 26, iconSize: 11) {
                    dismiss()
                }
            }
            .padding(ApexStyle.s4)
            .background(ApexStyle.surface)

            Divider()

            // Domain filter + summary pills
            if let diff {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ApexStyle.s2) {
                        ApexPillButton(
                            title: "全部",
                            isSelected: selectedDomain == nil,
                            count: diff.totalCount
                        ) {
                            selectedDomain = nil
                        }

                        ForEach(iCloudSyncDiffDomain.allCases) { domain in
                            let count = countForDomain(domain, in: diff)
                            if count > 0 {
                                ApexPillButton(
                                    title: domain.rawValue,
                                    icon: domain.iconName,
                                    isSelected: selectedDomain == domain,
                                    count: count
                                ) {
                                    selectedDomain = domain
                                }
                            }
                        }
                    }
                    .padding(.horizontal, ApexStyle.s4)
                    .padding(.vertical, ApexStyle.s2)
                }
                .background(ApexStyle.subtleSurface.opacity(0.6))

                Divider()
            }

            // Content
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取 iCloud 云端状态并比对差异...")
                            .font(.caption)
                            .foregroundStyle(ApexStyle.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "无法获取云端差异",
                        systemImage: "exclamationmark.icloud",
                        description: Text(errorMessage)
                    )
                } else if let diff, !diff.hasChanges {
                    ContentUnavailableView(
                        "本地与云端完全一致",
                        systemImage: "checkmark.icloud.fill",
                        description: Text("未检测到新增、修改或待传播的删除项目。")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: ApexStyle.s3) {
                            if !filteredAdded.isEmpty {
                                diffSection(title: "新增项目", items: filteredAdded, badgeTint: ApexStyle.success)
                            }
                            if !filteredModified.isEmpty {
                                diffSection(title: "变更项目 (按最新时间戳胜出)", items: filteredModified, badgeTint: ApexStyle.warning)
                            }
                            if !filteredDeleted.isEmpty {
                                diffSection(title: "待同步删除 (墓碑传播)", items: filteredDeleted, badgeTint: ApexStyle.error)
                            }
                        }
                        .padding(ApexStyle.s4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ApexStyle.surface)

            Divider()

            // Footer Actions
            HStack(spacing: ApexStyle.s2) {
                ApexActionButton("取消", tint: ApexStyle.secondary, size: .regular) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                ApexActionButton("本地覆盖云端", icon: "arrow.up.circle", tint: ApexStyle.warning, size: .regular) {
                    onApplyStrategy(.overwriteCloud)
                    dismiss()
                }
                .disabled(isLoading)

                ApexActionButton("云端覆盖本地", icon: "arrow.down.circle", tint: ApexStyle.error, size: .regular) {
                    onApplyStrategy(.overwriteLocal)
                    dismiss()
                }
                .disabled(isLoading)

                ApexActionButton("应用智能双向合并", icon: "arrow.triangle.2.circlepath", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    onApplyStrategy(.smartMerge)
                    dismiss()
                }
                .disabled(isLoading)
                .keyboardShortcut(.defaultAction)
            }
            .padding(ApexStyle.s4)
            .background(ApexStyle.surface)
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 760, minHeight: 380, idealHeight: 500, maxHeight: 680)
        .onExitCommand { dismiss() }
        .background(
            Button("") { dismiss() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }

    private func countForDomain(_ domain: iCloudSyncDiffDomain, in diff: iCloudSyncDiff) -> Int {
        diff.added.filter { $0.domain == domain }.count
            + diff.modified.filter { $0.domain == domain }.count
            + diff.deleted.filter { $0.domain == domain }.count
    }

    @ViewBuilder
    private func diffSection(title: String, items: [iCloudSyncDiffItem], badgeTint: Color) -> some View {
        VStack(alignment: .leading, spacing: ApexStyle.s2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ApexStyle.primary)
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(badgeTint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(badgeTint.opacity(0.14), in: Capsule())
            }

            ForEach(items) { item in
                HStack(spacing: ApexStyle.s2) {
                    Image(systemName: item.domain.iconName)
                        .font(.system(size: 12))
                        .foregroundStyle(badgeTint)
                        .frame(width: 24, height: 24)
                        .background(badgeTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(ApexStyle.primary)
                                .lineLimit(1)

                            Text(item.domain.rawValue)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(ApexStyle.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(ApexStyle.surface, in: RoundedRectangle(cornerRadius: 3))
                        }

                        if !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(ApexStyle.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: ApexStyle.s2)

                    Text("\(item.source.rawValue)\(item.kind.rawValue)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(badgeTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(badgeTint.opacity(0.12), in: Capsule())
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                        .stroke(ApexStyle.border.opacity(0.7), lineWidth: 0.75)
                )
            }
        }
    }
}
