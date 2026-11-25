import SwiftUI
import AppKit
import ApexCore

/// SecureCRT-style multi-session broadcast input bar with Chinese localization
public struct BroadcastBar: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Binding public var isBroadcastActive: Bool
    public let targetCount: Int
    public let onBroadcastSubmit: (String) -> Void
    
    @State private var broadcastText = ""
    
    public init(
        isBroadcastActive: Binding<Bool>,
        targetCount: Int,
        onBroadcastSubmit: @escaping (String) -> Void
    ) {
        self._isBroadcastActive = isBroadcastActive
        self.targetCount = targetCount
        self.onBroadcastSubmit = onBroadcastSubmit
    }

    private var activeToggleForeground: Color {
        guard let rgb = NSColor(ApexStyle.warning).usingColorSpace(.sRGB) else { return .white }
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent) + 0.0722 * channel(rgb.blueComponent)
        let contrastWithWhite = 1.05 / (luminance + 0.05)
        return contrastWithWhite >= 4.5 ? .white : Color.black.opacity(0.85)
    }
    
    public var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isBroadcastActive) {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
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
            .tint(ApexStyle.warning)
            .fixedSize()
            .disabled(targetCount == 0)
            .help(isBroadcastActive ? "关闭多终端命令广播模式" : "开启后将输入实时广播到所有 \(targetCount) 个已连接会话")
            
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
                .accessibilityLabel("发送到所有已打开的会话")
                
                ApexActionButton(
                    L10n.broadcastSend,
                    icon: "paperplane.fill",
                    tint: ApexStyle.warning,
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
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isBroadcastActive ? ApexStyle.warning.opacity(0.12) : ApexStyle.subtleSurface.opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
        .animation(ApexStyle.springSnappy, value: isBroadcastActive)
    }
}
