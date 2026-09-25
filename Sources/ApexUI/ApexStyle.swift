import SwiftUI

enum ApexStyle {
    static let accent = Color(red: 0.12, green: 0.43, blue: 0.88)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let subtleSurface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.09)
    static let success = Color(red: 0.18, green: 0.62, blue: 0.40)
    static let warning = Color(red: 0.88, green: 0.48, blue: 0.12)
    static let radius: CGFloat = 10
}

extension View {
    func apexPanel() -> some View {
        self
            .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.radius))
            .overlay {
                RoundedRectangle(cornerRadius: ApexStyle.radius)
                    .stroke(ApexStyle.border, lineWidth: 1)
            }
    }
}
