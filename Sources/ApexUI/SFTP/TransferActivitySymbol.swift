import SwiftUI

/// The system spinner is removed when work ends, so no repeating animation
/// survives on the completed transfer control.
struct TransferActivitySymbol: View {
    let isActive: Bool
    let inactiveSystemName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isActive && !reduceMotion {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.75)
                .frame(width: 12, height: 12)
                .tint(ApexStyle.accent)
        } else {
            Image(systemName: isActive ? "arrow.triangle.2.circlepath" : inactiveSystemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 12, height: 12)
        }
    }
}
