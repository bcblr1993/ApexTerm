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

    // MARK: - Fluid Spring Animations
    public static let springDefault = Animation.spring(response: 0.32, dampingFraction: 0.80)
    public static let springSnappy = Animation.spring(response: 0.24, dampingFraction: 0.76)
    public static let springSmooth = Animation.spring(response: 0.38, dampingFraction: 0.85)
    public static let hoverTransition = Animation.easeInOut(duration: 0.14)

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
    
    func apexGlassCard(
        cornerRadius: CGFloat = ApexStyle.radius,
        material: Material = .regularMaterial,
        borderColor: Color = Color.primary.opacity(0.08),
        shadowRadius: CGFloat = 8
    ) -> some View {
        modifier(ApexGlassCardModifier(cornerRadius: cornerRadius, material: material, borderColor: borderColor, shadowRadius: shadowRadius))
    }
    
    func apexKeycap() -> some View {
        self.font(.caption2.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(ApexStyle.subtleSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(ApexStyle.border.opacity(0.6), lineWidth: 0.75)
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
            )
            .foregroundColor(ApexStyle.secondary)
    }
}

public struct ApexGlassCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var material: Material
    public var borderColor: Color
    public var shadowRadius: CGFloat
    
    public init(
        cornerRadius: CGFloat = ApexStyle.radius,
        material: Material = .regularMaterial,
        borderColor: Color = Color.primary.opacity(0.08),
        shadowRadius: CGFloat = 8
    ) {
        self.cornerRadius = cornerRadius
        self.material = material
        self.borderColor = borderColor
        self.shadowRadius = shadowRadius
    }
    
    public func body(content: Content) -> some View {
        content
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: shadowRadius, x: 0, y: shadowRadius > 0 ? 2 : 0)
    }
}

/// Standardized tactile icon button conforming to macOS Liquid Class HIG
public struct ApexIconButton: View {
    let icon: String
    let label: String?
    let size: CGFloat
    let iconSize: CGFloat
    let isSelected: Bool
    let tint: Color?
    let action: () -> Void
    
    @State private var isHovered = false
    
    public init(
        icon: String,
        label: String? = nil,
        size: CGFloat = 26,
        iconSize: CGFloat = 11,
        isSelected: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.size = size
        self.iconSize = iconSize
        self.isSelected = isSelected
        self.tint = tint
        self.action = action
    }
    
    private var effectiveColor: Color {
        if let tint = tint {
            return isHovered ? tint : tint.opacity(0.85)
        }
        return isSelected ? ApexStyle.accent : (isHovered ? ApexStyle.primary : ApexStyle.secondary)
    }
    
    public var body: some View {
        Button(action: action) {
            ZStack {
                let activeTint = tint ?? (isSelected ? ApexStyle.accent : ApexStyle.primary)
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .fill(isSelected ? activeTint.opacity(0.18) : (isHovered ? activeTint.opacity(0.08) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                            .stroke(isSelected ? activeTint.opacity(0.35) : (isHovered ? (tint?.opacity(0.3) ?? ApexStyle.border.opacity(0.4)) : Color.clear), lineWidth: 0.75)
                    )
                
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(effectiveColor)
            }
            .frame(width: size, height: size)
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .animation(ApexStyle.springSnappy, value: isHovered)
            .animation(ApexStyle.springSnappy, value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(ApexStyle.hoverTransition) {
                isHovered = hovering
            }
        }
        .help(label ?? "")
    }
}

/// Tactile pill button with smooth spring selection indicator and hover lift
public struct ApexPillButton: View {
    let title: String
    let icon: String?
    let isSelected: Bool
    let count: Int?
    let action: () -> Void
    
    @State private var isHovered = false
    
    public init(
        title: String,
        icon: String? = nil,
        isSelected: Bool = false,
        count: Int? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isSelected = isSelected
        self.count = count
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                
                if let count = count {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(isSelected ? ApexStyle.accent.opacity(0.2) : ApexStyle.subtleSurface, in: Capsule())
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSelected ? ApexStyle.accent.opacity(0.18) : (isHovered ? ApexStyle.primary.opacity(0.06) : ApexStyle.surface.opacity(0.6)))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? ApexStyle.accent.opacity(0.4) : (isHovered ? ApexStyle.border : ApexStyle.border.opacity(0.5)), lineWidth: 0.75)
            )
            .foregroundColor(isSelected ? ApexStyle.accent : (isHovered ? ApexStyle.primary : ApexStyle.secondary))
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(ApexStyle.springSnappy, value: isSelected)
            .animation(ApexStyle.hoverTransition, value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Standardized tactile action button for list rows, card views, modals, and toolbars conforming to macOS Liquid Class HIG
public struct ApexActionButton: View {
    let title: String
    let icon: String?
    let tint: Color
    let size: ControlSize
    let isProminent: Bool
    let isLoading: Bool
    let action: () -> Void
    
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    
    public init(
        _ title: String,
        icon: String? = nil,
        tint: Color = ApexStyle.accent,
        size: ControlSize = .small,
        isProminent: Bool = false,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.size = size
        self.isProminent = isProminent
        self.isLoading = isLoading
        self.action = action
    }
    
    public var body: some View {
        Button(action: {
            if !isLoading && isEnabled {
                action()
            }
        }) {
            HStack(spacing: size == .small ? 4 : 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(size == .small ? .mini : .small)
                        .scaleEffect(size == .small ? 0.7 : 0.85)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: size == .small ? 9.5 : 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: size == .small ? 11 : 12.5, weight: isProminent ? .semibold : .medium))
            }
            .padding(.horizontal, size == .small ? 8 : 12)
            .padding(.vertical, size == .small ? 4 : 6.5)
            .background(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .fill(
                        isProminent
                            ? (isHovered && isEnabled ? tint.opacity(0.88) : tint)
                            : (isHovered && isEnabled ? tint.opacity(0.18) : tint.opacity(0.10))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                    .stroke(
                        isProminent
                            ? Color.white.opacity(isHovered && isEnabled ? 0.35 : 0.15)
                            : (isHovered && isEnabled ? tint.opacity(0.48) : tint.opacity(0.22)),
                        lineWidth: 0.75
                    )
            )
            .foregroundColor(isProminent ? .white : tint)
            .scaleEffect(isHovered && isEnabled ? 1.025 : 1.0)
            .shadow(
                color: (isHovered && isEnabled)
                    ? tint.opacity(isProminent ? 0.35 : 0.18)
                    : (isProminent ? tint.opacity(0.18) : Color.clear),
                radius: isProminent ? 4 : 3,
                x: 0,
                y: 1
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .animation(ApexStyle.springSnappy, value: isHovered)
            .animation(ApexStyle.springSnappy, value: isEnabled)
            .animation(ApexStyle.springSnappy, value: isLoading)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isLoading)
        .onHover { hovering in
            if isEnabled {
                withAnimation(ApexStyle.hoverTransition) {
                    isHovered = hovering
                }
            }
        }
    }
}

/// Standardized trigger view for native SwiftUI Menus adhering to macOS Liquid Class HIG
public struct ApexMenuTrigger: View {
    let icon: String
    let label: String?
    let size: CGFloat
    let iconSize: CGFloat
    let tint: Color?
    
    @State private var isHovered = false
    
    public init(
        icon: String,
        label: String? = nil,
        size: CGFloat = 24,
        iconSize: CGFloat = 11,
        tint: Color? = nil
    ) {
        self.icon = icon
        self.label = label
        self.size = size
        self.iconSize = iconSize
        self.tint = tint
    }
    
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                .fill(isHovered ? ApexStyle.primary.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                        .stroke(isHovered ? ApexStyle.border.opacity(0.4) : Color.clear, lineWidth: 0.75)
                )
            
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(tint ?? (isHovered ? ApexStyle.primary : ApexStyle.secondary))
        }
        .frame(width: size, height: size)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(ApexStyle.springSnappy, value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(ApexStyle.hoverTransition) {
                isHovered = hovering
            }
        }
        .help(label ?? "")
    }
}

/// Tactile split divider handle with smooth hover expansion and accent glow conforming to macOS Liquid Class HIG
public struct ApexSplitDividerHandle: View {
    public let isVertical: Bool
    
    @State private var isHovered = false
    
    public init(isVertical: Bool) {
        self.isVertical = isVertical
    }
    
    public var body: some View {
        Group {
            if isVertical {
                VStack {
                    Spacer()
                    Capsule()
                        .fill(isHovered ? ApexStyle.accent : ApexStyle.secondary.opacity(0.45))
                        .frame(width: isHovered ? 4 : 3, height: isHovered ? 38 : 30)
                        .shadow(color: isHovered ? ApexStyle.accent.opacity(0.5) : Color.clear, radius: 4)
                    Spacer()
                }
                .frame(width: 8)
            } else {
                HStack {
                    Spacer()
                    Capsule()
                        .fill(isHovered ? ApexStyle.accent : ApexStyle.secondary.opacity(0.45))
                        .frame(width: isHovered ? 42 : 34, height: isHovered ? 4 : 3)
                        .shadow(color: isHovered ? ApexStyle.accent.opacity(0.5) : Color.clear, radius: 4)
                    Spacer()
                }
                .frame(height: 8)
            }
        }
        .background(ApexStyle.surface)
        .contentShape(Rectangle())
        .animation(ApexStyle.springSnappy, value: isHovered)
        .onHover { hovering in
            withAnimation(ApexStyle.hoverTransition) {
                isHovered = hovering
            }
        }
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
