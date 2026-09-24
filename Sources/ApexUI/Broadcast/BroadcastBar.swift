import SwiftUI

/// SecureCRT-style multi-session broadcast input bar
public struct BroadcastBar: View {
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
        HStack(spacing: 8) {
            Toggle(isOn: $isBroadcastActive) {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(isBroadcastActive ? .orange : .secondary)
                    Text("Broadcast to \(targetCount) Tabs")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .toggleStyle(.button)
            .controlSize(.small)
            
            if isBroadcastActive {
                TextField("Type command to broadcast simultaneously to all connected sessions...", text: $broadcastText, onCommit: {
                    if !broadcastText.isEmpty {
                        onBroadcastSubmit(broadcastText + "\n")
                        broadcastText = ""
                    }
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                
                Button("Send") {
                    if !broadcastText.isEmpty {
                        onBroadcastSubmit(broadcastText + "\n")
                        broadcastText = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isBroadcastActive ? Color.orange.opacity(0.08) : Color.clear)
    }
}
