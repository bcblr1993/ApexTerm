import SwiftUI
import AppKit
import ApexCore

@MainActor
enum ApexStyle {
    private static var palette: ThemePalette {
        if AppSettings.shared.followsSystemAppearance {
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (dark ? TerminalThemePreset.modern : .nativeLight).palette
        }
        return AppSettings.shared.themePreset.palette
    }
    static var accent: Color { color(palette.accent) }
    static var surface: Color { AppSettings.shared.followsSystemAppearance ? Color(nsColor: .windowBackgroundColor) : color(palette.surface) }
    static var subtleSurface: Color { AppSettings.shared.followsSystemAppearance ? Color(nsColor: .controlBackgroundColor) : color(palette.sidebar) }
    static var primary: Color { AppSettings.shared.followsSystemAppearance ? .primary : color(palette.foreground) }
    static var secondary: Color { AppSettings.shared.followsSystemAppearance ? .secondary : color(palette.secondary) }
    static var border: Color { color(palette.border) }
    static var success: Color { color(palette.success) }
    static var warning: Color { color(palette.warning) }
    static var error: Color { color(palette.error) }
    static var buttonAccent: Color { color(ThemePalette.readable(palette.accent, on: ["#FFFFFF"])) }
    static var selection: Color { color(palette.selection) }
    static let radius: CGFloat = 10
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
