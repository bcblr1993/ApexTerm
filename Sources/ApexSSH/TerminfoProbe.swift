import Foundation
import ApexCore

/// Detects whether the remote host ships a terminfo entry for the session's TERM.
/// Without one, bash/readline falls back to horizontal scrolling and long
/// command lines lose their head and tail instead of wrapping.
public enum TerminfoProbe {
    public enum Result: Sendable, Equatable {
        case present
        case missing
        /// The probe could not decide (no output, no terminfo database found, probe failed)
        case unknown
    }

    static let marker = "APEX_TERMINFO="

    /// Single-line POSIX sh script, wrapped in `sh -c` so csh/fish login shells run it too.
    /// Prefers `infocmp`; minimal distros often lack ncurses-bin, so it falls back to
    /// scanning the standard terminfo directories (letter and hex subdirectory layouts).
    public static func command(for type: TerminalType) -> String {
        command(term: type.rawValue)
    }

    /// `term` must be a plain terminfo name; only enum values reach this in production.
    static func command(term: String) -> String {
        let letter = String(term.prefix(1))
        let hex = String(format: "%02x", term.utf8.first ?? 0)
        let dirs = "\"$TERMINFO\" \"$HOME/.terminfo\" $(echo \"$TERMINFO_DIRS\" | tr : \" \") /etc/terminfo /lib/terminfo /usr/share/terminfo /usr/lib/terminfo /usr/share/lib/terminfo"
        let script = [
            "if command -v infocmp >/dev/null 2>&1; then if infocmp \(term) >/dev/null 2>&1; then echo \(marker)OK; else echo \(marker)MISSING; fi; exit 0; fi",
            "seen=0",
            "for d in \(dirs); do [ -n \"$d\" ] && [ -d \"$d\" ] || continue; seen=1; if [ -e \"$d/\(letter)/\(term)\" ] || [ -e \"$d/\(hex)/\(term)\" ]; then echo \(marker)OK; exit 0; fi; done",
            "if [ $seen = 1 ]; then echo \(marker)MISSING; else echo \(marker)UNKNOWN; fi",
        ].joined(separator: "; ")
        return "sh -c '\(script)'"
    }

    /// Parses probe output; motd noise and CRLF line endings are tolerated.
    public static func parse(_ output: String) -> Result {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(marker) else { continue }
            switch line.dropFirst(marker.count) {
            case "OK": return .present
            case "MISSING": return .missing
            default: return .unknown
            }
        }
        return .unknown
    }

    /// Runs the probe over the client's one-shot command channel; failures map to `.unknown`.
    public static func run(on client: SSHSessionProtocol) async -> Result {
        guard !client.session.isLocal else { return .present }
        let type = client.terminalType
        guard let output = try? await client.executeCommand(command(for: type)) else { return .unknown }
        return parse(output)
    }
}
