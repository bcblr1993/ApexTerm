import SwiftUI
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
    
    public var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isBroadcastActive) {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(isBroadcastActive ? ApexStyle.warning : ApexStyle.secondary)
                    Text(String(format: L10n.broadcastToTabs, targetCount))
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(targetCount == 0)
            
            if isBroadcastActive {
                TextField(L10n.broadcastPlaceholder, text: $broadcastText, onCommit: {
                    if !broadcastText.isEmpty {
                        onBroadcastSubmit(broadcastText + "\n")
                        broadcastText = ""
                    }
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
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
                .disabled(broadcastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
