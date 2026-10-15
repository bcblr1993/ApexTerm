import Foundation

/// Process execution state (Linux / Darwin standard)
public enum ProcessState: String, Codable, Sendable {
    case running = "R"      // Running or runnable on run queue
    case sleeping = "S"     // Interruptible sleep (waiting for event)
    case diskSleep = "D"    // Uninterruptible sleep (usually I/O)
    case zombie = "Z"       // Defunct / zombie process
    case stopped = "T"      // Stopped by job control signal
    case unknown = "?"
    
    public var displayName: String {
        switch self {
        case .running: return "运行中 (R)"
        case .sleeping: return "睡眠 (S)"
        case .diskSleep: return "磁盘等待 (D)"
        case .zombie: return "僵死 (Z)"
        case .stopped: return "已暂停 (T)"
        case .unknown: return "未知"
        }
    }
}

/// Standard UNIX signal for process management
public enum ProcessSignal: Int, Codable, Sendable, CaseIterable {
    case sigterm = 15   // Graceful termination (default)
    case sigkill = 9    // Force kill (cannot be caught or ignored)
    case sighup  = 1    // Hangup / reload configuration
    
    public var name: String {
        switch self {
        case .sigterm: return "SIGTERM (15: 优雅退出)"
        case .sigkill: return "SIGKILL (9: 强制结束)"
        case .sighup:  return "SIGHUP (1: 重新加载配置)"
        }
    }
}

/// Rich process-level detail information parsed from remote Linux/macOS host
public struct ProcessDetailItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: Int { pid }
    public let pid: Int
    public let user: String
    public let cpuPercent: Double
    public let memPercent: Double
    public let rssBytes: UInt64       // Resident Set Size (physical memory)
    public let vszBytes: UInt64       // Virtual Memory Size
    public let state: ProcessState
    public let command: String        // Short command name
    public let fullCommandLine: String // Complete command line with arguments
    
    public init(
        pid: Int,
        user: String,
        cpuPercent: Double,
        memPercent: Double,
        rssBytes: UInt64 = 0,
        vszBytes: UInt64 = 0,
        state: ProcessState = .running,
        command: String,
        fullCommandLine: String? = nil
    ) {
        self.pid = pid
        self.user = user
        self.cpuPercent = cpuPercent
        self.memPercent = memPercent
        self.rssBytes = rssBytes
        self.vszBytes = vszBytes
        self.state = state
        self.command = command
        self.fullCommandLine = fullCommandLine ?? command
    }
    
    /// Formatted human-readable memory string (e.g. "128.5 MB")
    public var formattedRSS: String {
        ByteCountFormatter.string(fromByteCount: Int64(rssBytes), countStyle: .memory)
    }
    
    /// Critical system processes that are strictly prohibited from killing to avoid crashing OS or SSH
    public var isProtected: Bool {
        if pid <= 1 { return true }
        let lower = command.lowercased()
        let protectedCommands = [
            "systemd", "init", "sshd", "kthreadd", "launchd", "kernel_task",
            "dbus-daemon", "systemd-journald", "systemd-udevd", "login"
        ]
        return protectedCommands.contains(where: { lower == $0 || lower.hasPrefix($0) })
    }
    
    /// Validates whether this process can be safely killed
    public func canKill(sessionPid: Int? = nil) -> (allowed: Bool, reason: String?) {
        if isProtected {
            return (false, "系统核心受保护进程 (PID \(pid): \(command)) 禁止终止")
        }
        if let current = sessionPid, current > 0 && pid == current {
            return (false, "无法终止当前 SSH 会话自身的 Shell 进程 (PID \(pid))")
        }
        return (true, nil)
    }
}

/// Linux Systemd core service status item
public struct SystemdServiceItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { name }
    public let name: String           // e.g. "nginx", "docker", "redis", "mysql", "sshd"
    public let activeState: String    // e.g. "active", "inactive", "failed"
    public let subState: String       // e.g. "running", "dead", "exited"
    public let isRunning: Bool
    
    public init(name: String, activeState: String, subState: String = "") {
        self.name = name
        self.activeState = activeState
        self.subState = subState
        self.isRunning = activeState.lowercased() == "active"
    }
}

/// Zero-dependency parser for process lines from `ps -eo pid,user,%cpu,%mem,rss,vsz,stat,comm,args`
public enum ProcessListParser {
    
    public static func parsePSOutput(_ raw: String) -> [ProcessDetailItem] {
        var items: [ProcessDetailItem] = []
        let lines = raw.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("PID") || trimmed.hasPrefix("---") { continue }
            
            // Format: PID USER %CPU %MEM RSS VSZ STAT COMM ARGS
            let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard tokens.count >= 8, let pid = Int(tokens[0]) else { continue }
            
            let user = tokens[1]
            let cpu = Double(tokens[2]) ?? 0.0
            let mem = Double(tokens[3]) ?? 0.0
            let rssKB = UInt64(tokens[4]) ?? 0
            let vszKB = UInt64(tokens[5]) ?? 0
            
            // Stat first character
            let statRaw = tokens[6]
            let stateChar = statRaw.prefix(1)
            let state = ProcessState(rawValue: String(stateChar)) ?? .running
            
            let comm = tokens[7]
            let args = tokens.count > 8 ? tokens.dropFirst(8).joined(separator: " ") : comm
            
            let item = ProcessDetailItem(
                pid: pid,
                user: user,
                cpuPercent: cpu,
                memPercent: mem,
                rssBytes: rssKB * 1024,
                vszBytes: vszKB * 1024,
                state: state,
                command: comm,
                fullCommandLine: args
            )
            items.append(item)
        }
        
        return items
    }
    
    public static func parseSystemdServices(_ raw: String, monitoredServices: [String]) -> [SystemdServiceItem] {
        var items: [SystemdServiceItem] = []
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        
        for (index, svc) in monitoredServices.enumerated() {
            if index < lines.count {
                let state = lines[index].lowercased()
                items.append(SystemdServiceItem(name: svc, activeState: state))
            } else {
                items.append(SystemdServiceItem(name: svc, activeState: "unknown"))
            }
        }
        return items
    }
}
