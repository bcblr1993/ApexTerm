import Foundation
import AppKit
import ApexCore

/// Languages supported by `NativeCodeEditor`'s zero-dependency syntax highlighter.
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case yaml
    case json
    case toml
    case shell
    case nginx
    case dockerfile
    case ini
    case plain

    public static func detect(filename: String) -> SyntaxLanguage {
        let lowerName = (filename as NSString).lastPathComponent.lowercased()
        if lowerName == "dockerfile" || lowerName.hasPrefix("dockerfile.") {
            return .dockerfile
        }
        if lowerName == "nginx.conf" {
            return .nginx
        }
        if [".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile"].contains(lowerName) {
            return .shell
        }
        if lowerName == ".env" || lowerName.hasPrefix(".env.") {
            return .ini
        }
        let ext = (lowerName as NSString).pathExtension
        switch ext {
        case "yml", "yaml":
            return .yaml
        case "json", "jsonc":
            return .json
        case "toml":
            return .toml
        case "sh", "bash", "zsh", "ksh":
            return .shell
        case "conf":
            return .nginx
        case "ini", "cfg", "env", "properties":
            return .ini
        default:
            return .plain
        }
    }
}

/// Semantic token kinds mapped onto active `ThemePalette` ANSI colors.
public enum SyntaxTokenKind: Sendable, Equatable {
    case comment
    case string
    case variable
    case key
    case directive
    case keyword
    case number
}

/// UTF-16 token span for `NSLayoutManager.addTemporaryAttribute`.
public struct SyntaxToken: Sendable, Equatable {
    public let range: NSRange
    public let kind: SyntaxTokenKind

    public init(range: NSRange, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Zero-dependency, single-pass regex tokenizer for common DevOps configuration formats.
public enum SyntaxHighlighter: Sendable {
    public static let defaultMaxBytes = 512 * 1024

    private struct CompiledRule: @unchecked Sendable {
        let regex: NSRegularExpression
        let groupMapping: [(groupIndex: Int, kind: SyntaxTokenKind)]
    }

    private static let compiledRules: [SyntaxLanguage: CompiledRule] = {
        var table: [SyntaxLanguage: CompiledRule] = [:]

        func makeRule(pattern: String, mapping: [(Int, SyntaxTokenKind)]) -> CompiledRule? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
                return nil
            }
            return CompiledRule(regex: regex, groupMapping: mapping)
        }

        // YAML: comments, strings, variables, mapping keys, booleans/null, numbers
        if let r = makeRule(
            pattern: #"(#.*$)|("(?:\\.|[^"\\])*"|'(?:''|[^'])*')|(\$\{[A-Za-z0-9_.-]+\}|\$[A-Za-z_][A-Za-z0-9_]*)|(?:^\s*-?\s*)([A-Za-z0-9_./-]+)(?=\s*:)|(\b(?:true|false|null|yes|no|on|off)\b)|((?<![A-Za-z0-9_])-?\d+(?:\.\d+)?\b)"#,
            mapping: [(1, .comment), (2, .string), (3, .variable), (4, .key), (5, .keyword), (6, .number)]
        ) { table[.yaml] = r }

        // JSON / JSONC: comments, keys (quoted before colon), strings, keywords, numbers
        if let r = makeRule(
            pattern: #"(//.*$|/\*[\s\S]*?\*/)|("(?:\\.|[^"\\])*")(?=\s*:)|("(?:\\.|[^"\\])*")|(\b(?:true|false|null)\b)|((?<![A-Za-z0-9_])-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)"#,
            mapping: [(1, .comment), (2, .key), (3, .string), (4, .keyword), (5, .number)]
        ) { table[.json] = r }

        // TOML: comments, section headers [section], strings, keys, keywords, numbers
        if let r = makeRule(
            pattern: #"(#.*$)|(\[[^\r\n\]]+\])|("(?:\\.|[^"\\])*"|'[^'\r\n]*')|(?:^\s*)([A-Za-z0-9_.-]+)(?=\s*=)|(\b(?:true|false)\b)|((?<![A-Za-z0-9_])-?\d+(?:\.\d+)?\b)"#,
            mapping: [(1, .comment), (2, .directive), (3, .string), (4, .key), (5, .keyword), (6, .number)]
        ) { table[.toml] = r }

        // Shell scripts: comments, strings, variables, keywords, numbers
        if let r = makeRule(
            pattern: #"(#.*$)|("(?:\\.|[^"\\])*"|'[^']*')|(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?*!$])|(\b(?:if|then|elif|else|fi|for|while|until|do|done|case|esac|in|function|return|exit|export|local|readonly|set|unset|source|eval|exec|echo|printf|cd|sudo)\b)|((?<![A-Za-z0-9_])-?\d+\b)"#,
            mapping: [(1, .comment), (2, .string), (3, .variable), (4, .keyword), (5, .number)]
        ) { table[.shell] = r }

        // Nginx / .conf: comments, strings, variables ($host), directives, keywords/numbers
        if let r = makeRule(
            pattern: #"(#.*$)|("(?:\\.|[^"\\])*"|'[^']*')|(\$[A-Za-z_][A-Za-z0-9_]*)|(\b(?:server|location|http|events|upstream|stream|map|if|return|rewrite|proxy_pass|proxy_set_header|listen|server_name|root|index|ssl_certificate|ssl_certificate_key|include|error_page|access_log|error_log)\b)|(\b(?:on|off|default_server|ssl|http2|permanent|break|last)\b)|((?<![A-Za-z0-9_])\d+[kmgKMG]?\b)"#,
            mapping: [(1, .comment), (2, .string), (3, .variable), (4, .directive), (5, .keyword), (6, .number)]
        ) { table[.nginx] = r }

        // Dockerfile: comments, strings, variables, uppercase instructions, keywords
        if let r = makeRule(
            pattern: #"(#.*$)|("(?:\\.|[^"\\])*"|'[^']*')|(\$\{[A-Za-z0-9_.-]+\}|\$[A-Za-z_][A-Za-z0-9_]*)|(?:^\s*)(FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b|(\b(?:AS|as)\b)"#,
            mapping: [(1, .comment), (2, .string), (3, .variable), (4, .directive), (5, .keyword)]
        ) { table[.dockerfile] = r }

        // INI / .env: comments (# or ;), section headers, strings, keys, numbers
        if let r = makeRule(
            pattern: #"([#;].*$)|(\[[^\r\n\]]+\])|("(?:\\.|[^"\\])*"|'[^'\r\n]*')|(?:^\s*(?:export\s+)?)([A-Za-z0-9_.-]+)(?=\s*=)|((?<![A-Za-z0-9_])-?\d+(?:\.\d+)?\b)"#,
            mapping: [(1, .comment), (2, .directive), (3, .string), (4, .key), (5, .number)]
        ) { table[.ini] = r }

        return table
    }()

    public static func tokenize(
        _ text: String,
        language: SyntaxLanguage,
        maxBytes: Int = defaultMaxBytes
    ) -> [SyntaxToken] {
        guard language != .plain,
              !text.isEmpty,
              text.utf8.count <= maxBytes,
              let rule = compiledRules[language] else {
            return []
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = rule.regex.matches(in: text, options: [], range: fullRange)
        var tokens: [SyntaxToken] = []
        tokens.reserveCapacity(matches.count)

        for match in matches {
            for (groupIndex, kind) in rule.groupMapping {
                guard groupIndex < match.numberOfRanges else { continue }
                let range = match.range(at: groupIndex)
                if range.location != NSNotFound && range.length > 0 {
                    tokens.append(SyntaxToken(range: range, kind: kind))
                    break
                }
            }
        }
        return tokens
    }

    public static func color(for kind: SyntaxTokenKind, palette: ThemePalette, isDark: Bool) -> NSColor {
        switch kind {
        case .comment:
            return NSColor(hexHex: palette.secondary)?.withAlphaComponent(0.75) ?? .secondaryLabelColor
        case .string:
            return NSColor(hexHex: palette.terminalColor(at: 2)) ?? .systemGreen
        case .variable:
            return NSColor(hexHex: palette.terminalColor(at: 3)) ?? .systemOrange
        case .key:
            return NSColor(hexHex: palette.terminalColor(at: 4)) ?? (isDark ? .systemBlue : .systemIndigo)
        case .directive:
            return NSColor(hexHex: palette.terminalColor(at: 5)) ?? .systemPurple
        case .keyword:
            return NSColor(hexHex: palette.terminalColor(at: 1)) ?? .systemPink
        case .number:
            return NSColor(hexHex: palette.terminalColor(at: 6)) ?? .systemTeal
        }
    }
}

private extension NSColor {
    convenience init?(hexHex: String) {
        var clean = hexHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") { clean.removeFirst() }
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
