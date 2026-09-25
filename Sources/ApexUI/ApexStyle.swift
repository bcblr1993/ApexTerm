import SwiftUI

enum ApexStyle {
    static let accent = Color.accentColor
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let subtleSurface = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.09)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
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
