import Foundation
import AppKit
import CoreText

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
        if lower.contains("nerd") || lower.contains("powerline") {
            return true
        }
        let tokens = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if tokens.contains(where: { $0 == "nf" || $0 == "nfm" || $0 == "nfp" }) {
            return true
        }
        return name.hasSuffix("NF") || name.hasSuffix("NFM") || name.hasSuffix("NFP")
    }

    /// Resolves an `NSFont` by family name via `NSFontDescriptor`, preferring Regular weight,
    /// and falling back to PostScript name lookup if needed.
    public nonisolated static func resolveFont(familyName: String, size: CGFloat) -> NSFont? {
        if familyName == "SF Mono" || familyName == "System Monospaced" {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: familyName])
        let matches = descriptor.matchingFontDescriptors(withMandatoryKeys: [.family])
        if !matches.isEmpty {
            let preferred = matches.first(where: { desc in
                let traits = (desc.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]) ?? [:]
                let symbolic = (traits[.symbolic] as? UInt32).map(NSFontDescriptor.SymbolicTraits.init(rawValue:)) ?? []
                let weight = (traits[.weight] as? CGFloat) ?? 0
                return !symbolic.contains(.bold) && !symbolic.contains(.italic) && abs(weight) < 0.15
            }) ?? matches.first(where: { desc in
                let traits = (desc.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]) ?? [:]
                let symbolic = (traits[.symbolic] as? UInt32).map(NSFontDescriptor.SymbolicTraits.init(rawValue:)) ?? []
                return !symbolic.contains(.bold) && !symbolic.contains(.italic)
            }) ?? matches.first
            if let preferred, let font = NSFont(descriptor: preferred, size: size) {
                return font
            }
        }
        return NSFont(name: familyName, size: size)
    }

    /// Determines whether a given font family is monospace / fixed-pitch
    public nonisolated static func isMonospace(fontName: String) -> Bool {
        if curatedMonospaceFamilies.contains(fontName) { return true }
        if let font = resolveFont(familyName: fontName, size: 12) {
            return font.isFixedPitch
        }
        let lower = fontName.lowercased()
        return lower.contains("mono") || lower.contains("code") || detectNerdFont(fontName)
    }

    private var cachedFonts: [TerminalFontOption]? = nil

    public init() {}

    /// Fast candidate family keywords for monospace / coding fonts to avoid instantiating
    /// hundreds of CJK / decorative NSFont objects synchronously on the main thread.
    private nonisolated static let monospaceCandidateKeywords: [String] = [
        "mono", "code", "console", "courier", "term", "fixed", "typewriter",
        "inconsolata", "iosevka", "hack", "jetbrains", "fira", "cascadia",
        "meslo", "menlo", "monaco", "andale", "zed", "0xproto", "geist",
        "agave", "victor", "fantasque", "anonymous", "bitstream", "cousine",
        "droid sans", "go ", "input", "lekton", "luxi", "monofur", "monoid",
        "mononoki", "ocr", "overpass", "oxygen", "plex", "profont", "proggy",
        "pt ", "redhat", "roboto", "share tech", "space", "spleen", "ubuntu",
        "dejavu", "liberation"
    ]

    /// Determines whether a font family name is a likely candidate for fixed-pitch inspection.
    public nonisolated static func isLikelyMonospaceFamily(_ familyName: String) -> Bool {
        let lower = familyName.lowercased()
        return monospaceCandidateKeywords.contains { lower.contains($0) }
    }

    /// Returns list of available monospace and Nerd Fonts on this Mac
    public func availableFonts(forceRefresh: Bool = false) -> [TerminalFontOption] {
        if !forceRefresh, let cached = cachedFonts {
            return cached
        }

        let availableFamilies = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        let availableFamilySet = Set(availableFamilies)

        var fixedPitchFamilies = Set<String>()
        let traitsDict: [CFString: Any] = [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue]
        let attrs: [CFString: Any] = [kCTFontTraitsAttribute: traitsDict]
        let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let mandatoryKeys: Set<CFString> = [kCTFontTraitsAttribute]
        if let matched = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, mandatoryKeys as CFSet) as? [CTFontDescriptor] {
            for item in matched {
                if let family = CTFontDescriptorCopyAttribute(item, kCTFontFamilyNameAttribute) as? String {
                    fixedPitchFamilies.insert(family)
                }
            }
        }

        var result: [TerminalFontOption] = []
        var seenFamilies = Set<String>()

        // 1. Curated monospace fonts installed on the system
        for family in Self.curatedMonospaceFamilies {
            if availableFamilySet.contains(family) && !seenFamilies.contains(family) {
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

        // 3. Other detected monospace fonts on the system (pre-filtered by candidate keywords
        //    to avoid loading heavy CJK/Emoji/decorative font tables on the UI thread)
        for family in availableFamilies {
            if !seenFamilies.contains(family) && Self.isLikelyMonospaceFamily(family) && fixedPitchFamilies.contains(family) {
                seenFamilies.insert(family)
                result.append(TerminalFontOption(familyName: family))
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
