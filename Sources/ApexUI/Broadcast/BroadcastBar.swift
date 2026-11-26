import SwiftUI
import AppKit
import ApexCore

/// SecureCRT-style multi-session broadcast input bar with Chinese localization
public struct BroadcastBar: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Binding public var isBroadcastActive: Bool
    public let targetCount: Int
    public let remoteTargetCount: Int
    public let onBroadcastSubmit: (String) -> Void
    
    @State private var broadcastText = ""
    @State private var isConfirmingEnable = false
    
    public init(
        isBroadcastActive: Binding<Bool>,
        targetCount: Int,
        remoteTargetCount: Int? = nil,
        onBroadcastSubmit: @escaping (String) -> Void
    ) {
        self._isBroadcastActive = isBroadcastActive
        self.targetCount = targetCount
        self.remoteTargetCount = remoteTargetCount ?? targetCount
        self.onBroadcastSubmit = onBroadcastSubmit
    }

    public static func requiresEnableConfirmation(remoteTargetCount: Int) -> Bool {
        remoteTargetCount >= 2
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
        HStack(spacing: 10) {
            Toggle(isOn: toggleBinding) {
                HStack(spacing: 4) {
                    Image(systemName: isBroadcastActive ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
                        .foregroundStyle(isBroadcastActive ? activeToggleForeground : ApexStyle.secondary)
                    Text(String(format: L10n.broadcastToTabs, targetCount))
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
            .disabled(targetCount == 0 && !isBroadcastActive)
            .help(isBroadcastActive ? "关闭多终端命令广播模式" : "开启后将输入实时广播到 \(targetCount) 个已连接会话")
            .accessibilityLabel(isBroadcastActive ? "关闭多终端命令广播模式，当前目标 \(targetCount) 个已连接会话" : "开启多终端命令广播模式，将广播至 \(targetCount) 个已连接会话")
            .accessibilityHint("开启后键盘输入与快捷命令将同步发送到所有已连接目标会话")
            
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
                .accessibilityLabel("广播命令输入框，发送到 \(targetCount) 个已连接会话")
                
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
                .disabled(broadcastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("将当前命令发送至所有已连接的终端会话")
                .accessibilityLabel("发送广播命令")
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
            Text("开启后，您在终端中的按键输入以及通过快捷命令/命令面板执行的操作，将同时发送到全部 \(targetCount) 个已连接终端（含 \(remoteTargetCount) 台远程主机）。请确认操作安全。")
        }
    }
}
