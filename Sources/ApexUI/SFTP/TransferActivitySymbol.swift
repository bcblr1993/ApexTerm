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
                .frame(width: 14, height: 14)
                .tint(ApexStyle.accent)
        } else {
            Image(systemName: isActive ? "arrow.triangle.2.circlepath" : inactiveSystemName)
        }
    }
}
