import Foundation

/// Validation, shell-quoting, and iCloud sanitization utilities for session login startup scripts,
/// initial working directories, and environment variables.
public enum SessionStartupHelper: Sendable {

    /// Restricted dynamic linker / shell execution environment variables that must never be overridden.
    private static let restrictedKeys: Set<String> = [
        "LD_PRELOAD",
        "LD_LIBRARY_PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "BASH_ENV",
        "ENV",
        "PROMPT_COMMAND",
        "IFS"
    ]

    /// Sensitive key substrings that should be stripped before uploading session metadata to iCloud.
    private static let sensitiveKeySubstrings: [String] = [
        "PASSWORD",
        "PASSWD",
        "SECRET",
        "TOKEN",
        "PRIVATE_KEY",
        "API_KEY",
        "ACCESS_KEY",
        "CREDENTIAL",
        "AUTH"
    ]

    /// Validates that `key` is a legal POSIX environment variable identifier (`^[A-Za-z_][A-Za-z0-9_]*$`)
    /// and is not in the restricted dynamic-linker list.
    public static func isValidEnvKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !restrictedKeys.contains(trimmed.uppercased()) else {
            return false
        }
        guard let first = trimmed.unicodeScalars.first,
              (first == "_" || (first >= "A" && first <= "Z") || (first >= "a" && first <= "z")) else {
            return false
        }
        for scalar in trimmed.unicodeScalars.dropFirst() {
            let isAlphaNum = (scalar == "_")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9")
            if !isAlphaNum {
                return false
            }
        }
        return true
    }

    /// Parses multi-line `KEY=VALUE` text (supporting `#` comments and optional `export ` prefix).
    public static func parseEnvLines(_ text: String) -> (variables: [String: String], invalidKeys: [String]) {
        var variables: [String: String] = [:]
        var invalidKeys: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let body: String
            if trimmed.hasPrefix("export ") {
                body = String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            } else {
                body = trimmed
            }

            guard let eqIndex = body.firstIndex(of: "=") else {
                invalidKeys.append(body)
                continue
            }
            let key = String(body[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(body[body.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
               (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }

            if isValidEnvKey(key) {
                variables[key] = value
            } else {
                invalidKeys.append(key.isEmpty ? body : key)
            }
        }

        return (variables, invalidKeys)
    }

    /// Formats an environment variable dictionary as sorted `KEY=VALUE` lines.
    public static func formatEnvLines(_ variables: [String: String]) -> String {
        variables
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    /// Escapes a string for safe inclusion inside single-quoted POSIX shell arguments (`'...'`).
    public static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Quotes a remote/local working directory path for `cd`, preserving `$HOME` expansion when the path starts with `~`.
    public static func shellQuotedWorkingDirectory(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return "\"$HOME\""
        }
        if trimmed.hasPrefix("~/") {
            let subpath = String(trimmed.dropFirst(2))
            return subpath.isEmpty ? "\"$HOME\"" : "\"$HOME\"/\(shellSingleQuoted(subpath))"
        }
        return shellSingleQuoted(trimmed)
    }

    /// Builds a composite shell command (`export ... && cd ... && <startupCommand>`) to execute after PTY login.
    public static func buildBootstrapCommand(
        for session: Session,
        includeWorkingDirectory: Bool = true,
        includeEnvExports: Bool = true
    ) -> String? {
        var segments: [String] = []

        if includeEnvExports && !session.environmentVariables.isEmpty {
            let validPairs = session.environmentVariables
                .filter { isValidEnvKey($0.key) }
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\(shellSingleQuoted($0.value))" }
            if !validPairs.isEmpty {
                segments.append("export " + validPairs.joined(separator: " "))
            }
        }

        if includeWorkingDirectory,
           let rawDir = session.initialWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDir.isEmpty {
            segments.append("cd \(shellQuotedWorkingDirectory(rawDir))")
        }

        if let rawCmd = session.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawCmd.isEmpty {
            let normalizedCmd = rawCmd
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            if !normalizedCmd.isEmpty {
                segments.append(normalizedCmd)
            }
        }

        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: " && ")
    }

    /// Returns true if an environment variable key appears to hold a secret/token/password.
    public static func isSensitiveEnvKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        return sensitiveKeySubstrings.contains(where: { upper.contains($0) })
    }

    /// Strips sensitive environment variables before uploading session metadata to iCloud.
    public static func sanitizeEnvironmentForCloud(_ env: [String: String]) -> [String: String] {
        var safe: [String: String] = [:]
        for (key, value) in env {
            guard isValidEnvKey(key),
                  !isSensitiveEnvKey(key),
                  !value.contains("PRIVATE KEY") else {
                continue
            }
            safe[key] = value
        }
        return safe
    }
}
