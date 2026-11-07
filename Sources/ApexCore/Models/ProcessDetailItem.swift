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
        let baseLower = (command as NSString).lastPathComponent.lowercased()
        let protectedCommands = [
            "systemd", "init", "sshd", "kthreadd", "launchd", "kernel_task",
            "dbus-daemon", "systemd-journald", "systemd-udevd", "login"
        ]
        return protectedCommands.contains(where: {
            lower == $0 || lower.hasPrefix($0) || baseLower == $0 || baseLower.hasPrefix($0)
        })
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
            
            let rawComm = tokens[7]
            let comm: String
            if rawComm.hasPrefix("/") {
                let base = (rawComm as NSString).lastPathComponent
                comm = base.isEmpty ? rawComm : base
            } else {
                comm = rawComm
            }
            let args = tokens.count > 8 ? tokens.dropFirst(8).joined(separator: " ") : rawComm
            
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
    
    public static func parseSystemdServices(_ raw: String, monitoredServices: [String] = ["nginx", "docker", "redis", "mysql", "sshd", "postgresql", "caddy"]) -> [SystemdServiceItem] {
        var items: [SystemdServiceItem] = []
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        
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

/// Represents an active listening TCP/UDP socket on a remote Linux or macOS host
public struct ListeningPortItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { "\(proto.uppercased()):\(bindAddress):\(port)" }
    public let proto: String
    public let bindAddress: String
    public let port: Int
    public let pid: Int?
    public let processName: String

    public init(
        proto: String,
        bindAddress: String,
        port: Int,
        pid: Int? = nil,
        processName: String = ""
    ) {
        self.proto = proto.uppercased()
        self.bindAddress = bindAddress
        self.port = port
        self.pid = pid
        self.processName = processName
    }

    /// True when the listening address is bound to wildcard (`0.0.0.0`, `*`, `::`) or a non-loopback interface.
    public var isPubliclyExposed: Bool {
        let normalized = bindAddress
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .lowercased()
        if normalized == "localhost" || normalized == "::1" || normalized.hasPrefix("127.") || normalized.hasPrefix("::ffff:127.") {
            return false
        }
        return true
    }

    public var exposureBadgeText: String {
        isPubliclyExposed ? "公网/全网卡" : "本地回环"
    }

    public var endpointDisplay: String {
        if bindAddress.contains(":") && !bindAddress.hasPrefix("[") {
            return "[\(bindAddress)]:\(port)"
        }
        return "\(bindAddress):\(port)"
    }

    /// Generates a collision-free local SSH port forwarding (`-L`) tunnel targeting this remote listening port.
    public func toLocalForwardingTunnel(
        sessionId: UUID,
        preferredLocalPort: Int? = nil,
        existingTunnels: [SSHTunnel] = []
    ) -> SSHTunnel {
        var candidatePort = preferredLocalPort ?? (port < 1024 ? port + 10000 : port)
        candidatePort = min(max(candidatePort, 1024), 65535)
        let occupiedLocalPorts = Set(
            existingTunnels
                .filter { $0.type != .remote }
                .map(\.bindPort)
        )
        while occupiedLocalPorts.contains(candidatePort) && candidatePort < 65535 {
            candidatePort += 1
        }
        let label = processName.isEmpty ? proto : processName
        return SSHTunnel(
            name: "\(label)-\(port)",
            type: .local,
            sessionId: sessionId,
            bindHost: "127.0.0.1",
            bindPort: candidatePort,
            targetHost: "127.0.0.1",
            targetPort: port
        )
    }
}

/// Zero-dependency parser for Linux `ss -tulpn`, Linux `netstat -tulpn`, and macOS/BSD `lsof -iTCP -sTCP:LISTEN`
public enum ListeningPortParser {

    public static func parseOutput(_ raw: String) -> [ListeningPortItem] {
        var results: [ListeningPortItem] = []
        var seenKeys: Set<String> = []

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("Active ") || line.hasPrefix("Proto ") || line.hasPrefix("Netid ") || line.hasPrefix("COMMAND ") {
                continue
            }
            if let item = parseLine(line) {
                let dedupKey = "\(item.proto):\(item.bindAddress):\(item.port)"
                if seenKeys.insert(dedupKey).inserted {
                    results.append(item)
                }
            }
        }

        return results.sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.bindAddress < $1.bindAddress
        }
    }

    public static func filter(_ items: [ListeningPortItem], query: String) -> [ListeningPortItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            "\(item.port)".contains(trimmed) ||
            item.processName.lowercased().contains(trimmed) ||
            item.bindAddress.lowercased().contains(trimmed) ||
            item.proto.lowercased().contains(trimmed) ||
            (item.pid.map { "\($0)".contains(trimmed) } ?? false) ||
            item.exposureBadgeText.lowercased().contains(trimmed)
        }
    }

    private static func parseLine(_ line: String) -> ListeningPortItem? {
        let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 4 else { return nil }

        let firstLower = tokens[0].lowercased()
        if firstLower.hasPrefix("tcp") || firstLower.hasPrefix("udp") {
            let proto = firstLower.hasPrefix("udp") ? "UDP" : "TCP"
            // Detect `ss -tulpn`: token[1] is State (LISTEN / UNCONN)
            if tokens[1] == "LISTEN" || tokens[1] == "UNCONN" || tokens[1] == "ESTAB" {
                guard tokens.count >= 5,
                      let (addr, port) = splitHostPort(tokens[4]) else { return nil }
                let rest = tokens.dropFirst(5).joined(separator: " ")
                let (pid, proc) = parseSSUsersField(rest)
                return ListeningPortItem(proto: proto, bindAddress: addr, port: port, pid: pid, processName: proc)
            } else {
                // `netstat -tulpn`: Proto Recv-Q Send-Q LocalAddress ForeignAddress [State] PID/Program
                guard let (addr, port) = splitHostPort(tokens[3]) else { return nil }
                let lastToken = tokens.last ?? ""
                let (pid, proc) = parseNetstatPidProgram(lastToken)
                return ListeningPortItem(proto: proto, bindAddress: addr, port: port, pid: pid, processName: proc)
            }
        }

        // macOS / BSD `lsof -iTCP -sTCP:LISTEN -P -n`:
        // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [(LISTEN)]
        if let pid = Int(tokens[1]), tokens.count >= 9 {
            let command = tokens[0]
            let protoIndex = tokens.firstIndex(where: { $0.uppercased() == "TCP" || $0.uppercased() == "UDP" })
            guard let pIdx = protoIndex, pIdx + 1 < tokens.count else { return nil }
            let proto = tokens[pIdx].uppercased()
            let addrToken = tokens[pIdx + 1]
            guard let (addr, port) = splitHostPort(addrToken) else { return nil }
            return ListeningPortItem(proto: proto, bindAddress: addr, port: port, pid: pid, processName: command)
        }

        return nil
    }

    private static func splitHostPort(_ raw: String) -> (String, Int)? {
        guard let lastColon = raw.lastIndex(of: ":") else { return nil }
        let portStr = String(raw[raw.index(after: lastColon)...])
        guard let port = Int(portStr), (1...65535).contains(port) else { return nil }
        var hostPart = String(raw[..<lastColon])
        if hostPart.hasPrefix("[") && hostPart.hasSuffix("]") {
            hostPart = String(hostPart.dropFirst().dropLast())
        }
        // Strip interface scope suffix such as `127.0.0.53%lo` or `fe80::1%eth0`
        if let pct = hostPart.firstIndex(of: "%") {
            hostPart = String(hostPart[..<pct])
        }
        if hostPart.isEmpty {
            hostPart = "::"
        }
        return (hostPart, port)
    }

    private static func parseSSUsersField(_ text: String) -> (Int?, String) {
        // Matches users:(("nginx",pid=1234,fd=6))
        var procName = ""
        var pidValue: Int? = nil
        if let firstQuote = text.firstIndex(of: "\"") {
            let afterFirst = text[text.index(after: firstQuote)...]
            if let secondQuote = afterFirst.firstIndex(of: "\"") {
                procName = String(afterFirst[..<secondQuote])
            }
        }
        if let pidRange = text.range(of: "pid=") {
            let afterPid = text[pidRange.upperBound...]
            let digits = afterPid.prefix(while: { $0.isNumber })
            pidValue = Int(digits)
        }
        return (pidValue, procName)
    }

    private static func parseNetstatPidProgram(_ token: String) -> (Int?, String) {
        guard token.contains("/") else { return (nil, "") }
        let parts = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (nil, "") }
        let pid = Int(parts[0])
        let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return (pid, name)
    }
}
