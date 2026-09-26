import Foundation

/// Shared UI and terminal tokens. Explicit TrueColor values are never remapped.
public struct ThemePalette: Sendable {
    public let surface: String
    public let sidebar: String
    public let terminal: String
    public let foreground: String
    public let secondary: String
    public let accent: String
    public let success: String
    public let warning: String
    public let border: String
    public let selection: String
    public let ansi: [String]
    private let terminalANSI: [String]
    public init(surface: String, sidebar: String, terminal: String, foreground: String, secondary: String, accent: String, success: String, warning: String, border: String, selection: String, ansi: [String]) {
        self.surface = surface; self.sidebar = sidebar; self.terminal = terminal
        self.border = border; self.selection = selection
        let backgrounds = [surface, sidebar, selection]
        self.foreground = Self.readable(foreground, on: backgrounds + [terminal])
        self.secondary = Self.readable(secondary, on: backgrounds)
        self.accent = Self.readable(accent, on: backgrounds)
        self.success = Self.readable(success, on: backgrounds)
        self.warning = Self.readable(warning, on: backgrounds)
        self.ansi = ansi.count == 16 ? ansi : ansi + ansi
        self.terminalANSI = self.ansi.map { Self.readable($0, on: [terminal]) }
    }
    public var error: String { Self.readable(ansi[1], on: [surface, sidebar, selection]) }
    public func terminalColor(at index: Int) -> String {
        terminalANSI[max(0, min(15, index))]
    }
    public static func contrast(_ foreground: String, _ background: String) -> Double {
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    /// Retain the source hue while correcting unreadable text on all UI surfaces.
    public static func readable(_ hex: String, on backgrounds: [String]) -> String {
        if backgrounds.allSatisfy({ contrast(hex, $0) >= 4.5 }) { return hex }
        let rgb = components(hex)
        let target = luminance(backgrounds[0]) < 0.25 ? 255.0 : 0.0
        for step in 1...100 {
            let amount = Double(step) / 100
            let c = rgb.map { Int(($0 + (target - $0) * amount).rounded()) }
            let candidate = String(format: "#%02X%02X%02X", c[0], c[1], c[2])
            if backgrounds.allSatisfy({ contrast(candidate, $0) >= 4.5 }) { return candidate }
        }
        return target == 255 ? "#FFFFFF" : "#000000"
    }
    private static func components(_ hex: String) -> [Double] {
        let n = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return [Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255)]
    }
    private static func luminance(_ hex: String) -> Double {
        let c = components(hex).map { v -> Double in
            let s = v / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    }
    private static let presets: [TerminalThemePreset: ThemePalette] = Dictionary(
        uniqueKeysWithValues: TerminalThemePreset.allCases.map { ($0, buildPreset($0)) }
    )
    public static func forPreset(_ preset: TerminalThemePreset) -> ThemePalette { presets[preset]! }
    private static func buildPreset(_ preset: TerminalThemePreset) -> ThemePalette {
        switch preset {
        case .solarized:
            return ThemePalette(surface: "#EEE8D5", sidebar: "#EEE8D5", terminal: "#FDF6E3", foreground: "#657B83", secondary: "#657B83", accent: "#268BD2", success: "#859900", warning: "#B58900", border: "#D7D1BF", selection: "#EEE8D5", ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5", "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"])
        case .rosepine:
            return ThemePalette(surface: "#1F1D2E", sidebar: "#191724", terminal: "#191724", foreground: "#E0DEF4", secondary: "#908CAA", accent: "#C4A7E7", success: "#9CCFD8", warning: "#F6C177", border: "#403D52", selection: "#403D52", ansi: ["#26233A", "#EB6F92", "#31748F", "#F6C177", "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4", "#6E6A86", "#EB6F92", "#31748F", "#F6C177", "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4"])
        case .everforest:
            return ThemePalette(surface: "#343F44", sidebar: "#232A2E", terminal: "#2D353B", foreground: "#D3C6AA", secondary: "#9DA9A0", accent: "#A7C080", success: "#A7C080", warning: "#DBBC7F", border: "#475258", selection: "#425047", ansi: ["#343F44", "#E67E80", "#A7C080", "#DBBC7F", "#7FBBB3", "#D699B6", "#83C092", "#D3C6AA"])
        case .gruvbox:
            return ThemePalette(surface: "#3C3836", sidebar: "#282828", terminal: "#282828", foreground: "#EBDBB2", secondary: "#BDAE93", accent: "#83A598", success: "#B8BB26", warning: "#FABD2F", border: "#504945", selection: "#504945", ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984", "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"])
        case .onedark:
            return ThemePalette(surface: "#21252B", sidebar: "#21252B", terminal: "#282C34", foreground: "#ABB2BF", secondary: "#9DA5B4", accent: "#61AFEF", success: "#98C379", warning: "#E5C07B", border: "#3E4451", selection: "#3E4451", ansi: ["#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF"])
        case .modern:
            return ThemePalette(surface: "#181818", sidebar: "#181818", terminal: "#1F1F1F", foreground: "#CCCCCC", secondary: "#9D9D9D", accent: "#4DAAFC", success: "#23D18B", warning: "#F5F543", border: "#2B2B2B", selection: "#24384B", ansi: ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5", "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#E5E5E5"])
        case .tokyo:
            return ThemePalette(surface: "#16161E", sidebar: "#16161E", terminal: "#1A1B26", foreground: "#C0CAF5", secondary: "#9AA5CE", accent: "#7AA2F7", success: "#9ECE6A", warning: "#E0AF68", border: "#292E42", selection: "#283457", ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6", "#414868", "#FF899D", "#9FE044", "#FABA4A", "#8DB0FF", "#C7A9FF", "#A4DAFF", "#C0CAF5"])
        case .mocha:
            return ThemePalette(surface: "#181825", sidebar: "#11111B", terminal: "#1E1E2E", foreground: "#CDD6F4", secondary: "#A6ADC8", accent: "#CBA6F7", success: "#A6E3A1", warning: "#F9E2AF", border: "#313244", selection: "#313244", ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE", "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"])
        case .nord:
            return ThemePalette(surface: "#3B4252", sidebar: "#2E3440", terminal: "#2E3440", foreground: "#D8DEE9", secondary: "#D8DEE9", accent: "#88C0D0", success: "#A3BE8C", warning: "#EBCB8B", border: "#434C5E", selection: "#434C5E", ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0"])
        case .dracula:
            return ThemePalette(surface: "#21222C", sidebar: "#21222C", terminal: "#282A36", foreground: "#F8F8F2", secondary: "#A6ACCD", accent: "#BD93F9", success: "#50FA7B", warning: "#F1FA8C", border: "#44475A", selection: "#44475A", ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2", "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"])
        case .latte:
            return ThemePalette(surface: "#E6E9EF", sidebar: "#DCE0E8", terminal: "#EFF1F5", foreground: "#4C4F69", secondary: "#5C5F77", accent: "#8839EF", success: "#40A02B", warning: "#DF8E1D", border: "#BCC0CC", selection: "#CCD0DA", ansi: ["#5C5F77", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#ACB0BE", "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#BCC0CC"])
        case .nativeLight:
            return ThemePalette(surface: "#F5F5F5", sidebar: "#F0F0F0", terminal: "#FFFFFF", foreground: "#262626", secondary: "#595959", accent: "#0066CC", success: "#287A49", warning: "#8A620B", border: "#D3D3D3", selection: "#DDEBFA", ansi: ["#262626", "#B42318", "#287A49", "#8A620B", "#0066CC", "#8A3DB8", "#007A85", "#595959"])
        case .apexDark:
            return ThemePalette(surface: "#161922", sidebar: "#161922", terminal: "#161922", foreground: "#F0F4F8", secondary: "#9D9D9D", accent: "#38BDF8", success: "#23D18B", warning: "#F5F543", border: "#2B2B2B", selection: "#24384B", ansi: ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5"])
        case .oledBlack:
            return ThemePalette(surface: "#000000", sidebar: "#000000", terminal: "#000000", foreground: "#FFFFFF", secondary: "#9D9D9D", accent: "#00FF66", success: "#23D18B", warning: "#F5F543", border: "#2B2B2B", selection: "#24384B", ansi: ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5"])
        case .solarizedDark:
            return ThemePalette(surface: "#002B36", sidebar: "#002B36", terminal: "#002B36", foreground: "#93A1A1", secondary: "#657B83", accent: "#268BD2", success: "#859900", warning: "#B58900", border: "#586E75", selection: "#073642", ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5", "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"])
        case .monokai:
            return ThemePalette(surface: "#2D2A2E", sidebar: "#2D2A2E", terminal: "#2D2A2E", foreground: "#FCFCFA", secondary: "#A6ACCD", accent: "#FFD866", success: "#50FA7B", warning: "#F1FA8C", border: "#44475A", selection: "#44475A", ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2"])
        case .oneDark:
            return ThemePalette(surface: "#282C34", sidebar: "#282C34", terminal: "#282C34", foreground: "#ABB2BF", secondary: "#9DA5B4", accent: "#528BFF", success: "#98C379", warning: "#E5C07B", border: "#3E4451", selection: "#3E4451", ansi: ["#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF"])
        }
    }
}
