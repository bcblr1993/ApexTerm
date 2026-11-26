import Foundation

/// Reusable multi-host batch command template supporting `{{var}}` placeholders and persistence.
public struct BatchCommandTemplate: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var command: String
    public var category: String
    public var description: String
    public var isBuiltIn: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        command: String,
        category: String = "自定义",
        description: String = "",
        isBuiltIn: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.category = category
        self.description = description
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
    }

    /// Extracts ordered unique variable names in `{{var_name}}` placeholders, excluding `{{date}}`
    /// and Go-template dotted fields such as `{{.Names}}`.
    public static func extractVariables(from command: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{\\s*([a-zA-Z_][a-zA-Z0-9_-]*)\\s*\\}\\}", options: []) else {
            return []
        }
        let nsString = command as NSString
        let matches = regex.matches(in: command, options: [], range: NSRange(location: 0, length: nsString.length))
        var vars: [String] = []
        for match in matches where match.numberOfRanges > 1 {
            let name = nsString.substring(with: match.range(at: 1))
            if name.lowercased() != "date" && !vars.contains(name) {
                vars.append(name)
            }
        }
        return vars
    }

    /// Interpolates `{{var}}` and `{{date}}` in a single pass.
    public static func interpolate(_ command: String, context: [String: String], date: Date = Date()) -> String {
        var normalized: [String: String] = [:]
        for (k, v) in context {
            let clean = k.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                normalized[clean] = v
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: date)

        guard let regex = try? NSRegularExpression(pattern: "\\{\\{\\s*([a-zA-Z_][a-zA-Z0-9_-]*)\\s*\\}\\}", options: []) else {
            return command
        }
        let nsCommand = command as NSString
        let matches = regex.matches(in: command, options: [], range: NSRange(location: 0, length: nsCommand.length))
        guard !matches.isEmpty else { return command }

        var result = ""
        var cursor = 0
        for match in matches {
            let fullRange = match.range
            if fullRange.location > cursor {
                result += nsCommand.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
            }
            let key = nsCommand.substring(with: match.range(at: 1))
            if let value = normalized[key] {
                result += value
            } else if key.lowercased() == "date" {
                result += today
            } else {
                result += nsCommand.substring(with: fullRange)
            }
            cursor = fullRange.location + fullRange.length
        }
        if cursor < nsCommand.length {
            result += nsCommand.substring(from: cursor)
        }
        return result
    }

    public func extractVariables() -> [String] {
        Self.extractVariables(from: command)
    }

    public func resolvedCommand(context: [String: String], date: Date = Date()) -> String {
        Self.interpolate(command, context: context, date: date)
    }

    public func unresolvedVariables(context: [String: String] = [:]) -> [String] {
        extractVariables().filter { name in
            let val = context[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return val.isEmpty
        }
    }

    public static let curatedDefaults: [BatchCommandTemplate] = [
        BatchCommandTemplate(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!,
            name: "系统健康巡检",
            command: "hostname && uptime && df -h / && free -m",
            category: "巡检",
            description: "快速采集主机名、负载、根分区磁盘与内存",
            isBuiltIn: true
        ),
        BatchCommandTemplate(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000002")!,
            name: "Systemd 服务状态检查",
            command: "systemctl status {{service}} --no-pager -n 20",
            category: "服务",
            description: "查看指定服务的运行状态与近期日志",
            isBuiltIn: true
        ),
        BatchCommandTemplate(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000003")!,
            name: "平滑重载/重启服务",
            command: "sudo systemctl restart {{service}} && systemctl is-active {{service}}",
            category: "服务",
            description: "重启目标服务并校验 active 状态",
            isBuiltIn: true
        ),
        BatchCommandTemplate(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000004")!,
            name: "检索近期错误日志",
            command: "journalctl -u {{service}} -p err -n {{lines}} --no-pager",
            category: "日志",
            description: "过滤最近 N 行 error 及以上级别日志",
            isBuiltIn: true
        ),
        BatchCommandTemplate(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000005")!,
            name: "Docker 容器运行清单",
            command: "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'",
            category: "容器",
            description: "列出所有运行中容器的名称、状态与端口",
            isBuiltIn: true
        ),
        BatchCommandTemplate(
            id: UUID(uuidString: "A1000000-0000-4000-8000-000000000006")!,
            name: "按天数预览过期日志",
            command: "find {{log_dir}} -type f -name '*.log' -mtime +{{days}} -ls",
            category: "维护",
            description: "只读列出超过指定天数的旧日志文件",
            isBuiltIn: true
        )
    ]
}

/// UserDefaults-backed store managing built-in and custom batch command templates.
@MainActor
public final class BatchCommandTemplateStore: ObservableObject {
    public static let shared = BatchCommandTemplateStore()

    @Published public private(set) var templates: [BatchCommandTemplate] = []

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "aetherterm.batch.commandTemplates.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    public func load() {
        var custom: [BatchCommandTemplate] = []
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([BatchCommandTemplate].self, from: data) {
            custom = decoded.filter { !$0.isBuiltIn }
        }
        self.templates = BatchCommandTemplate.curatedDefaults + custom
    }

    public func saveTemplate(_ template: BatchCommandTemplate) {
        var item = template
        item.isBuiltIn = false
        if let idx = templates.firstIndex(where: { $0.id == item.id && !$0.isBuiltIn }) {
            templates[idx] = item
        } else {
            templates.append(item)
        }
        persistCustomTemplates()
    }

    @discardableResult
    public func addTemplate(
        name: String,
        command: String,
        category: String = "自定义",
        description: String = ""
    ) -> BatchCommandTemplate {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let tpl = BatchCommandTemplate(
            name: cleanName.isEmpty ? "未命名模板" : cleanName,
            command: cleanCommand,
            category: cleanCategory.isEmpty ? "自定义" : cleanCategory,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false
        )
        templates.append(tpl)
        persistCustomTemplates()
        return tpl
    }

    public func deleteTemplate(id: UUID) {
        templates.removeAll { $0.id == id && !$0.isBuiltIn }
        persistCustomTemplates()
    }

    public func resetCustomTemplates() {
        templates = BatchCommandTemplate.curatedDefaults
        defaults.removeObject(forKey: storageKey)
    }

    private func persistCustomTemplates() {
        let custom = templates.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
