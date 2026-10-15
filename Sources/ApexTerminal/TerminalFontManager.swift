import Foundation
import AppKit

/// Represents a selectable terminal font option with metadata
public struct TerminalFontOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let familyName: String
    public let displayName: String
    public let isNerdFont: Bool
    public let isMonospace: Bool

    public init(familyName: String, displayName: String? = nil, isNerdFont: Bool? = nil, isMonospace: Bool = true) {
        self.familyName = familyName
        let isNF = isNerdFont ?? TerminalFontManager.detectNerdFont(familyName)
        self.isNerdFont = isNF
        self.isMonospace = isMonospace
        if let displayName = displayName {
            self.displayName = displayName
        } else {
            self.displayName = isNF ? "\(familyName) [Nerd Font]" : familyName
        }
        self.id = familyName
    }
}

/// Dynamically discovers and manages monospace and Nerd Fonts on macOS
@MainActor
public final class TerminalFontManager {
    public static let shared = TerminalFontManager()

    /// Curated built-in monospace fonts that should always appear near the top if available
    public nonisolated static let curatedMonospaceFamilies: [String] = [
        "SF Mono",
        "Menlo",
        "Monaco",
        "JetBrains Mono",
        "Fira Code",
        "Hack",
        "Cascadia Code",
        "Source Code Pro",
        "Courier New",
        "Courier",
        "Inconsolata",
        "PT Mono"
    ]

    /// Detects if a font family name matches Nerd Font naming conventions
    public nonisolated static func detectNerdFont(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("nerd") || lower.contains("nf") || lower.contains("powerline")
    }

    /// Determines whether a given font family is monospace / fixed-pitch
    public nonisolated static func isMonospace(fontName: String) -> Bool {
        if curatedMonospaceFamilies.contains(fontName) { return true }
        if let font = NSFont(name: fontName, size: 12) {
            return font.isFixedPitch
        }
        let lower = fontName.lowercased()
        return lower.contains("mono") || lower.contains("code") || lower.contains("nf")
    }

    private var cachedFonts: [TerminalFontOption]? = nil

    public init() {}

    /// Returns list of available monospace and Nerd Fonts on this Mac
    public func availableFonts(forceRefresh: Bool = false) -> [TerminalFontOption] {
        if !forceRefresh, let cached = cachedFonts {
            return cached
        }

        let fontManager = NSFontManager.shared
        let availableFamilies = fontManager.availableFontFamilies

        var result: [TerminalFontOption] = []
        var seenFamilies = Set<String>()

        // 1. Curated monospace fonts installed on the system
        for family in Self.curatedMonospaceFamilies {
            if availableFamilies.contains(family) && !seenFamilies.contains(family) {
                seenFamilies.insert(family)
                result.append(TerminalFontOption(familyName: family))
            }
        }

        // 2. Installed Nerd Fonts (e.g. MesloLGS NF, FiraCode Nerd Font)
        for family in availableFamilies {
            if !seenFamilies.contains(family) && Self.detectNerdFont(family) {
                seenFamilies.insert(family)
                result.append(TerminalFontOption(familyName: family, isNerdFont: true))
            }
        }

        // 3. Other detected monospace fonts on the system
        for family in availableFamilies {
            if !seenFamilies.contains(family) {
                if let members = fontManager.availableMembers(ofFontFamily: family),
                   let firstMember = members.first,
                   let postScriptName = firstMember.first as? String {
                    if let font = NSFont(name: postScriptName, size: 12), font.isFixedPitch {
                        seenFamilies.insert(family)
                        result.append(TerminalFontOption(familyName: family))
                    }
                }
            }
        }

        // Fallback: If running in headless or restricted sandbox where availableFontFamilies is empty,
        // ensure standard macOS monospace fonts are still offered
        if result.isEmpty {
            for family in ["SF Mono", "Menlo", "Monaco", "Courier", "JetBrains Mono"] {
                result.append(TerminalFontOption(familyName: family))
            }
        }

        cachedFonts = result
        return result
    }
}
