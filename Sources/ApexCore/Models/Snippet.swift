import Foundation

/// Represents a reusable command snippet with templating
public struct Snippet: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var command: String
    public var category: String
    public var autoExecute: Bool
    
    public init(
        id: UUID = UUID(),
        title: String,
        command: String,
        category: String = "General",
        autoExecute: Bool = false
    ) {
        self.id = id
        self.title = title
        self.command = command
        self.category = category
        self.autoExecute = autoExecute
    }
    
    /// Interpolates variables like {{host}}, {{user}}, {{date}} into command
    public func resolvedCommand(context: [String: String]) -> String {
        var result = command
        for (key, val) in context {
            let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanKey.isEmpty {
                result = result.replacingOccurrences(of: "{{\(cleanKey)}}", with: val)
            }
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        result = result.replacingOccurrences(of: "{{date}}", with: formatter.string(from: Date()))
        return result
    }
    
    /// Extracts all variable placeholder names in `{{var_name}}`, excluding `{{date}}`
    public func extractVariables() -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{([a-zA-Z0-9_-]+)\\}\\}", options: []) else {
            return []
        }
        let nsString = command as NSString
        let matches = regex.matches(in: command, options: [], range: NSRange(location: 0, length: nsString.length))
        var vars: [String] = []
        for match in matches {
            if match.numberOfRanges > 1 {
                let varName = nsString.substring(with: match.range(at: 1))
                if varName.lowercased() != "date" && !vars.contains(varName) {
                    vars.append(varName)
                }
            }
        }
        return vars
    }
    
    /// Curated ops snippets built for quick terminal productivity
    public static let defaultCuratedSnippets: [Snippet] = [
        // System
        Snippet(title: "系统资源概览", command: "top -b -n 1 | head -n 25", category: "系统", autoExecute: true),
        Snippet(title: "磁盘剩余空间", command: "df -h", category: "系统", autoExecute: true),
        Snippet(title: "物理内存占用", command: "free -m", category: "系统", autoExecute: true),
        Snippet(title: "运行时间与负载", command: "uptime", category: "系统", autoExecute: true),
        // Process & Service
        Snippet(title: "查找特定进程", command: "ps aux | grep {{service}}", category: "进程", autoExecute: false),
        Snippet(title: "查看服务状态", command: "systemctl status {{service}}", category: "进程", autoExecute: false),
        Snippet(title: "重启系统服务", command: "sudo systemctl restart {{service}}", category: "进程", autoExecute: false),
        Snippet(title: "强行结束进程 PID", command: "kill -9 {{pid}}", category: "进程", autoExecute: false),
        // Docker
        Snippet(title: "列出全部容器", command: "docker ps -a", category: "Docker", autoExecute: true),
        Snippet(title: "跟踪容器日志 (尾部 100 行)", command: "docker logs --tail 100 -f {{container}}", category: "Docker", autoExecute: false),
        Snippet(title: "重启指定容器", command: "docker restart {{container}}", category: "Docker", autoExecute: false),
        Snippet(title: "进入容器交互 Shell", command: "docker exec -it {{container}} /bin/sh", category: "Docker", autoExecute: false),
        // Network
        Snippet(title: "监听端口审查 (netstat)", command: "netstat -tulpn", category: "网络", autoExecute: true),
        Snippet(title: "检查指定端口占用 (ss)", command: "ss -tulpn | grep {{port}}", category: "网络", autoExecute: false),
        Snippet(title: "抓取 HTTP 响应头", command: "curl -I -sS {{url}}", category: "网络", autoExecute: false),
        // Logs
        Snippet(title: "跟踪系统日志 (/var/log/syslog)", command: "tail -n 100 -f /var/log/syslog", category: "日志", autoExecute: true),
        Snippet(title: "跟踪服务 Journal 日志", command: "journalctl -u {{service}} -f -n 100", category: "日志", autoExecute: false)
    ]
}
