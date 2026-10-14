import SwiftUI
import AppKit
import ApexCore

@MainActor
public enum ApexStyle {
    private static var palette: ThemePalette {
        if AppSettings.shared.followsSystemAppearance {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (dark ? TerminalThemePreset.modern : .nativeLight).palette
        }
        return AppSettings.shared.themePreset.palette
    }
    public static var accent: Color { color(palette.accent) }
    public static var surface: Color { AppSettings.shared.followsSystemAppearance ? Color(nsColor: .windowBackgroundColor) : color(palette.surface) }
    public static var subtleSurface: Color { AppSettings.shared.followsSystemAppearance ? Color(nsColor: .controlBackgroundColor) : color(palette.sidebar) }
    public static var primary: Color { AppSettings.shared.followsSystemAppearance ? .primary : color(palette.foreground) }
    public static var secondary: Color { AppSettings.shared.followsSystemAppearance ? .secondary : color(palette.secondary) }
    public static var border: Color { color(palette.border) }
    public static var success: Color { color(palette.success) }
    public static var warning: Color { color(palette.warning) }
    public static var error: Color { color(palette.error) }
    public static var buttonAccent: Color { color(ThemePalette.readable(palette.accent, on: ["#FFFFFF"])) }
    public static var selection: Color { color(palette.selection) }
    
    // MARK: - Spacing Grid (4pt / 8pt standard system)
    public static let sMicro: CGFloat = 2
    public static let s1: CGFloat = 4
    public static let sCompact: CGFloat = 6
    public static let s2: CGFloat = 8
    public static let sRow: CGFloat = 10
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16  // Standard page & component horizontal axis padding
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24

    // MARK: - Corner Radii
    public static let badgeRadius: CGFloat = 4
    public static let controlRadius: CGFloat = 6
    public static let cardRadius: CGFloat = 8
    public static let radius: CGFloat = 10
    public static let panelRadius: CGFloat = 12

    // MARK: - Window Layout & Half-Screen Tiling Metrics
    public static let minWindowWidth: CGFloat = 600
    public static let minWindowHeight: CGFloat = 400
    public static let defaultWindowWidth: CGFloat = 1000
    public static let defaultWindowHeight: CGFloat = 680
    public static let minSidebarWidth: CGFloat = 200
    public static let idealSidebarWidth: CGFloat = 260
    public static let maxSidebarWidth: CGFloat = 360

    private static func color(_ hex: String) -> Color { Color(hex: hex) ?? .primary }
}

public extension View {
    func apexTheme() -> some View { modifier(ApexThemeModifier()) }
    func apexProminentButton() -> some View { modifier(ApexProminentModifier()) }
    func apexPanel() -> some View {
        self.background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.radius))
            .overlay { RoundedRectangle(cornerRadius: ApexStyle.radius).stroke(ApexStyle.border, lineWidth: 1) }
    }
}

private struct ApexThemeModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var settings = AppSettings.shared
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(settings.followsSystemAppearance ? nil : (settings.themePreset.isDark ? .dark : .light))
            .tint(ApexStyle.accent)
            .accentColor(ApexStyle.accent)
            .foregroundStyle(ApexStyle.primary)
            .background(ApexStyle.surface)
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
    }
}

private struct ApexProminentModifier: ViewModifier {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent)
            .tint(ApexStyle.buttonAccent)
            .foregroundStyle(isEnabled ? Color.white : ApexStyle.secondary)
    }
}
