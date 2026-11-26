import SwiftUI
import AppKit
import ApexCore

/// Selectable target tab chip descriptor used by `BroadcastBar`.
public struct BroadcastTargetItem: Identifiable, Equatable, Sendable {
    public let tabID: UUID
    public let title: String
    public let environmentTier: EnvironmentTier?
    public var isSelected: Bool

    public var id: UUID { tabID }

    public init(
        tabID: UUID,
        title: String,
        environmentTier: EnvironmentTier? = nil,
        isSelected: Bool = true
    ) {
        self.tabID = tabID
        self.title = title
        self.environmentTier = environmentTier
        self.isSelected = isSelected
    }
}

/// SecureCRT-style multi-session broadcast input bar with per-tab targeting and Chinese localization
public struct BroadcastBar: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Binding public var isBroadcastActive: Bool
    public let targetCount: Int
    public let remoteTargetCount: Int
    public let targetTabs: [BroadcastTargetItem]
    public let onToggleTargetTab: ((UUID) -> Void)?
    public let onSelectAllTargets: (() -> Void)?
    public let onDeselectAllTargets: (() -> Void)?
    public let onBroadcastSubmit: (String) -> Void
    
    @State private var broadcastText = ""
    @State private var isConfirmingEnable = false
    
    public init(
        isBroadcastActive: Binding<Bool>,
        targetCount: Int,
        remoteTargetCount: Int? = nil,
        targetTabs: [BroadcastTargetItem] = [],
        onToggleTargetTab: ((UUID) -> Void)? = nil,
        onSelectAllTargets: (() -> Void)? = nil,
        onDeselectAllTargets: (() -> Void)? = nil,
        onBroadcastSubmit: @escaping (String) -> Void
    ) {
        self._isBroadcastActive = isBroadcastActive
        self.targetCount = targetCount
        self.remoteTargetCount = remoteTargetCount ?? targetCount
        self.targetTabs = targetTabs
        self.onToggleTargetTab = onToggleTargetTab
        self.onSelectAllTargets = onSelectAllTargets
        self.onDeselectAllTargets = onDeselectAllTargets
        self.onBroadcastSubmit = onBroadcastSubmit
    }

    public static func requiresEnableConfirmation(remoteTargetCount: Int) -> Bool {
        remoteTargetCount >= 2
    }

    public static func selectedTargetIDs(from items: [BroadcastTargetItem]) -> Set<UUID> {
        Set(items.filter(\.isSelected).map(\.tabID))
    }

    public static func togglingTarget(_ tabID: UUID, in items: [BroadcastTargetItem]) -> [BroadcastTargetItem] {
        items.map { item in
            guard item.tabID == tabID else { return item }
            var updated = item
            updated.isSelected.toggle()
            return updated
        }
    }

    public static func effectiveTargetCount(targetCount: Int, targetTabs: [BroadcastTargetItem]) -> Int {
        targetTabs.isEmpty ? targetCount : targetTabs.filter(\.isSelected).count
    }

    private var resolvedTargetCount: Int {
        Self.effectiveTargetCount(targetCount: targetCount, targetTabs: targetTabs)
    }

    private var activeToggleForeground: Color {
        guard let rgb = NSColor(ApexStyle.error).usingColorSpace(.sRGB) else { return .white }
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
        let contrastWithWhite = 1.05 / (luminance + 0.05)
        return contrastWithWhite >= 4.5 ? .white : Color.black.opacity(0.85)
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { isBroadcastActive },
            set: { nextValue in
                if nextValue && !isBroadcastActive && Self.requiresEnableConfirmation(remoteTargetCount: remoteTargetCount) {
                    isConfirmingEnable = true
                } else {
                    isBroadcastActive = nextValue
                }
            }
        )
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(isOn: toggleBinding) {
                    HStack(spacing: 4) {
                        Image(systemName: isBroadcastActive ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
                            .foregroundStyle(isBroadcastActive ? activeToggleForeground : ApexStyle.secondary)
                        Text(String(format: L10n.broadcastToTabs, resolvedTargetCount))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundStyle(isBroadcastActive ? activeToggleForeground : ApexStyle.primary)
                    }
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .tint(isBroadcastActive ? ApexStyle.error : ApexStyle.warning)
                .fixedSize()
                .disabled(resolvedTargetCount == 0 && !isBroadcastActive)
                .help(isBroadcastActive ? "关闭多终端命令广播模式" : "开启后将输入实时广播到 \(resolvedTargetCount) 个已选会话")
                .accessibilityLabel(isBroadcastActive ? "关闭多终端命令广播模式，当前目标 \(resolvedTargetCount) 个会话" : "开启多终端命令广播模式，将广播至 \(resolvedTargetCount) 个会话")
                .accessibilityHint("开启后键盘输入与快捷命令将同步发送到所有选中的已连接目标会话")
                
                if isBroadcastActive {
                    TextField(L10n.broadcastPlaceholder, text: $broadcastText, onCommit: {
                        if !broadcastText.isEmpty {
                            onBroadcastSubmit(broadcastText + "\n")
                            broadcastText = ""
                        }
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 100)
                    .accessibilityLabel("广播命令输入框，发送到 \(resolvedTargetCount) 个已选会话")
                    
                    ApexActionButton(
                        L10n.broadcastSend,
                        icon: "paperplane.fill",
                        tint: ApexStyle.error,
                        size: .small,
                        isProminent: true
                    ) {
                        if !broadcastText.isEmpty {
                            onBroadcastSubmit(broadcastText + "\n")
                            broadcastText = ""
                        }
                    }
                    .fixedSize()
                    .disabled(broadcastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedTargetCount == 0)
                    .help("将当前命令发送至所有已选中的终端会话")
                    .accessibilityLabel("发送广播命令")
                }
            }

            if !targetTabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ApexStyle.sCompact) {
                        Text("目标标签:")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(ApexStyle.secondary)

                        ForEach(targetTabs) { item in
                            targetChip(item)
                        }

                        if targetTabs.count > 1 {
                            if let onSelectAllTargets {
                                Button("全选") { onSelectAllTargets() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(ApexStyle.accent)
                            }
                            if let onDeselectAllTargets {
                                Button("全不选") { onDeselectAllTargets() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(ApexStyle.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isBroadcastActive ? ApexStyle.error.opacity(0.12) : ApexStyle.subtleSurface.opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
        .animation(ApexStyle.springSnappy, value: isBroadcastActive)
        .confirmationDialog("开启多终端命令广播模式？", isPresented: $isConfirmingEnable) {
            Button("确认开启广播（影响 \(remoteTargetCount) 台远程主机）", role: .destructive) {
                isBroadcastActive = true
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后，您在终端中的按键输入以及通过快捷命令/命令面板执行的操作，将同时发送到全部 \(resolvedTargetCount) 个已选终端（含 \(remoteTargetCount) 台远程主机）。请确认操作安全。")
        }
    }

    @ViewBuilder
    private func targetChip(_ item: BroadcastTargetItem) -> some View {
        let tierColor: Color = item.environmentTier.flatMap { Color(hex: $0.colorHex) } ?? ApexStyle.accent
        let chipTint: Color = item.isSelected ? (item.environmentTier == .prod ? ApexStyle.error : ApexStyle.accent) : ApexStyle.secondary

        Button {
            onToggleTargetTab?(item.tabID)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.isSelected ? chipTint : ApexStyle.secondary)

                if let tier = item.environmentTier {
                    Text(tier.badgeText)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(tierColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(tierColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
                        .fixedSize()
                }

                Text(item.title)
                    .font(.system(size: 11, weight: item.isSelected ? .semibold : .regular))
                    .foregroundStyle(item.isSelected ? ApexStyle.primary : ApexStyle.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(item.isSelected ? chipTint.opacity(0.14) : ApexStyle.surface.opacity(0.65))
            )
            .overlay(
                Capsule()
                    .stroke(item.isSelected ? chipTint.opacity(0.45) : ApexStyle.border.opacity(0.6), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title)\(item.environmentTier.map { " [\($0.badgeText)]" } ?? "")，\(item.isSelected ? "已选为广播目标" : "未选中")")
    }
}
