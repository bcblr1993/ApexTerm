import Foundation

/// Helper for copying session credentials and connection info to clipboard
public enum SessionCopyHelper {
    /// Formats username and password in labeled key-value format.
    /// Example:
    /// 用户名: root
    /// 密码: 123456
    public static func formatUserAndPassword(username: String, password: String?) -> String {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = (password?.isEmpty == false) ? password! : "(未配置)"
        return "用户名: \(cleanUser)\n密码: \(pw)"
    }
    
    /// Formats the complete session info in labeled format.
    /// Example:
    /// 会话: 生产环境主库 (when name differs from host)
    /// 主机: 10.8.8.71
    /// 端口: 22
    /// 用户名: root
    /// 密码: 123456
    public static func formatSessionInfo(session: Session, password: String?) -> String {
        var lines: [String] = []
        let trimmedName = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = session.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty && trimmedName != trimmedHost {
            lines.append("会话: \(trimmedName)")
        }
        lines.append("主机: \(trimmedHost)")
        lines.append("端口: \(session.port)")
        lines.append("用户名: \(session.username.trimmingCharacters(in: .whitespacesAndNewlines))")
        let pw = (password?.isEmpty == false) ? password! : "(未配置)"
        lines.append("密码: \(pw)")
        return lines.joined(separator: "\n")
    }
    
    /// Resolves the password or passphrase for the given session.
    public static func resolveSecret(
        for session: Session,
        lookup: @Sendable (String) async -> String? = { try? await KeychainStore.shared.get(key: $0) }
    ) async -> String? {
        await SSHTunnelManager.resolveSecret(for: session, lookup: lookup)
    }
}
