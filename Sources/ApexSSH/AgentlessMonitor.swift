import Foundation
import ApexCore

/// Zero-agent remote metrics parser for Linux and macOS
public final class AgentlessMonitor: Sendable {
    public init() {}
    
    /// Script payload sent to remote Linux host over lightweight SSH channel
    public static let linuxProbeCommand = """
    LC_ALL=C; export LC_ALL; cat /proc/stat /proc/meminfo /proc/net/dev 2>/dev/null; echo "---DF---"; df -kP / 2>/dev/null | tail -1; echo "---UPTIME---"; cat /proc/uptime 2>/dev/null; echo "---LOAD---"; cat /proc/loadavg 2>/dev/null; echo "---TOP---"; (ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null || ps -eo pid,user,%cpu,%mem,comm 2>/dev/null || ps -o pid,user,rss,comm 2>/dev/null) | head -6; echo "---CPUMODEL---"; (grep -m1 "model name" /proc/cpuinfo 2>/dev/null || grep -m1 "Hardware" /proc/cpuinfo 2>/dev/null || uname -m) | cut -d: -f2 | sed 's/^[ \t]*//'; echo "---DISKTYPE---"; ROOT_DEV=$(df -P / 2>/dev/null | tail -1 | awk '{print $1}' | sed 's|/dev/||'); PARENT_DEV=$(echo "$ROOT_DEV" | sed -E 's/p?[0-9]+$//'); if [ -f "/sys/block/$PARENT_DEV/queue/rotational" ]; then if [ "$(cat /sys/block/$PARENT_DEV/queue/rotational 2>/dev/null)" = "0" ]; then if echo "$ROOT_DEV" | grep -q "nvme"; then echo "NVMe SSD"; else echo "SSD"; fi; else echo "HDD"; fi; elif echo "$ROOT_DEV" | grep -q "nvme"; then echo "NVMe SSD"; elif lsblk -d -n -o rota "/dev/$PARENT_DEV" 2>/dev/null | grep -q "0"; then echo "SSD"; elif lsblk -d -n -o rota "/dev/$PARENT_DEV" 2>/dev/null | grep -q "1"; then echo "HDD"; else echo "SSD"; fi
    """
    
    /// Script payload sent to remote macOS host
    public static let macosProbeCommand = """
    LC_ALL=C; export LC_ALL; top -l 1 -n 0 -s 0 | grep -E "CPU usage|PhysMem"; echo "---SWAP---"; sysctl -n vm.swapusage 2>/dev/null; echo "---CORES---"; sysctl -n hw.ncpu 2>/dev/null || echo "8"; echo "---DF---"; df -kP / | tail -1; echo "---UPTIME---"; uptime; echo "---NET---"; netstat -ib -n 2>/dev/null | awk '$1 ~ /^en[0-9]+$/ && $3 ~ /^<Link#/ { rx += $(NF-4); tx += $(NF-1) } END { printf "en0 1500 <Link#1> 00:00:00:00:00:00 0 0 %.0f 0 0 %.0f 0\\n", rx, tx }'; echo "---TOP---"; ps -eo pid,user,%cpu,%mem,comm -r 2>/dev/null | head -6; echo "---CPUMODEL---"; sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model; echo "---DISKTYPE---"; if diskutil info / 2>/dev/null | grep -q "Solid State: *Yes"; then if diskutil info / 2>/dev/null | grep -E -q "Apple Fabric|PCI-Express|NVMe"; then echo "NVMe SSD"; else echo "SSD"; fi; else echo "HDD"; fi
    """
    
    /// Auto-detecting multi-OS probe command
    public static let autoProbeCommand = """
    LC_ALL=C; export LC_ALL
    if [ "$(uname)" = "Darwin" ]; then
        \(macosProbeCommand)
    else
        \(linuxProbeCommand)
    fi
    """
    
    /// Full process inspection command returning Top 45 processes with complete attributes (including BusyBox/POSIX fallbacks)
    public static let processInspectorProbeCommand = """
    LC_ALL=C; export LC_ALL
    if [ "$(uname)" = "Darwin" ]; then
        ps -eo pid,user,%cpu,%mem,rss,vsz,stat,comm,command -r 2>/dev/null | head -46
    else
        (ps -eo pid,user,%cpu,%mem,rss,vsz,stat,comm,args --sort=-%cpu 2>/dev/null || ps -eo pid,user,%cpu,%mem,rss,vsz,stat,comm,args 2>/dev/null || ps -o pid,user,rss,vsz,stat,comm,args 2>/dev/null || ps -o pid,user,vsz,stat,comm,args 2>/dev/null) | head -46
    fi
    """

    /// Listening TCP/UDP sockets probe command with automatic multi-OS fallback (`lsof` on Darwin, `ss` or `netstat` on Linux)
    public static let listeningPortsProbeCommand = """
    LC_ALL=C; export LC_ALL
    if [ "$(uname)" = "Darwin" ]; then
        lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | head -80
    elif command -v ss >/dev/null 2>&1; then
        ss -tulpnH 2>/dev/null | head -80
    else
        netstat -tulpn 2>/dev/null | head -80
    fi
    """
    
    /// Systemd service states query command (returns empty output on macOS/Alpine/BSD hosts without systemctl)
    public static func systemdServicesProbeCommand(services: [String] = ["nginx", "docker", "redis", "mysql", "sshd", "postgresql", "caddy"]) -> String {
        let safeServices = services
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isValidSystemdUnitName($0) }
            .map { posixSingleQuoted($0) }
        guard !safeServices.isEmpty else { return "" }
        let joined = safeServices.joined(separator: " ")
        return """
        LC_ALL=C; export LC_ALL
        if command -v systemctl >/dev/null 2>&1; then
            for s in \(joined); do
                systemctl is-active "$s" 2>/dev/null || echo "inactive"
            done
        fi
        """
    }

    // MARK: - Container & Dynamic Systemd Agentless Commands (v1.24.0)

    public struct ContainerProbeResult: Sendable, Equatable {
        public let runtime: ContainerRuntime?
        public let items: [ContainerItem]
        public let errorMessage: String?

        public init(runtime: ContainerRuntime?, items: [ContainerItem], errorMessage: String? = nil) {
            self.runtime = runtime
            self.items = items
            self.errorMessage = errorMessage
        }
    }

    public static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Strict whitelist for container IDs or names (`[A-Za-z0-9_.-]`, non-empty, never flag-prefixed).
    public static func isValidContainerID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128, !id.hasPrefix("-"), !id.hasPrefix(".") else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) // 0-9
                || (scalar.value >= 65 && scalar.value <= 90) // A-Z
                || (scalar.value >= 97 && scalar.value <= 122) // a-z
                || scalar == "_" || scalar == "." || scalar == "-"
        }
    }

    /// Strict whitelist for systemd unit names (`[A-Za-z0-9@_.:-]`, non-empty, never flag-prefixed).
    public static func isValidSystemdUnitName(_ unit: String) -> Bool {
        guard !unit.isEmpty, unit.count <= 128, !unit.hasPrefix("-"), !unit.hasPrefix(".") else { return false }
        return unit.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar == "@" || scalar == "_" || scalar == "." || scalar == ":" || scalar == "-"
        }
    }

    public static let noContainerRuntimeSentinel = "---NO-CONTAINER-RUNTIME---"

    /// Auto-detects Docker or Podman on remote hosts (falling back to Podman if Docker fails) and outputs tab-separated container rows.
    public static let containerListProbeCommand = """
    LC_ALL=C; export LC_ALL
    if command -v docker >/dev/null 2>&1; then
        DOCKER_OUT=$(docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' 2>&1)
        DOCKER_RC=$?
        if [ $DOCKER_RC -eq 0 ]; then
            echo "---RUNTIME:docker---"
            printf '%s\\n' "$DOCKER_OUT"
        elif command -v podman >/dev/null 2>&1; then
            PODMAN_OUT=$(podman ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' 2>&1)
            PODMAN_RC=$?
            if [ $PODMAN_RC -eq 0 ]; then
                echo "---RUNTIME:podman---"
                printf '%s\\n' "$PODMAN_OUT"
            else
                echo "---RUNTIME:docker---"
                printf '%s\\n' "$DOCKER_OUT"
            fi
        else
            echo "---RUNTIME:docker---"
            printf '%s\\n' "$DOCKER_OUT"
        fi
    elif command -v podman >/dev/null 2>&1; then
        echo "---RUNTIME:podman---"
        podman ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' 2>&1
    else
        echo "---NO-CONTAINER-RUNTIME---"
    fi
    """

    public static func parseContainerProbeResult(_ raw: String) -> ContainerProbeResult {
        var runtime: ContainerRuntime? = nil
        var items: [ContainerItem] = []
        var diagnosticLines: [String] = []

        for rawLine in raw.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == noContainerRuntimeSentinel {
                return ContainerProbeResult(runtime: nil, items: [], errorMessage: nil)
            }
            if trimmed == "---RUNTIME:docker---" {
                runtime = .docker
                continue
            }
            if trimmed == "---RUNTIME:podman---" {
                runtime = .podman
                continue
            }
            if rawLine.contains("\t") {
                let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if cols.count >= 5, !cols[0].isEmpty {
                    let item = ContainerItem(
                        id: cols[0],
                        name: cols[1].isEmpty ? cols[0] : cols[1],
                        image: cols[2],
                        state: cols[3],
                        status: cols[4],
                        ports: cols.count > 5 ? cols[5] : "",
                        runtime: runtime ?? .docker
                    )
                    items.append(item)
                    continue
                }
            }
            diagnosticLines.append(trimmed)
        }

        let errorMessage = (items.isEmpty && !diagnosticLines.isEmpty)
            ? diagnosticLines.joined(separator: "\n")
            : nil
        return ContainerProbeResult(runtime: runtime, items: items, errorMessage: errorMessage)
    }

    public static func parseContainerOutput(_ raw: String) -> (runtime: ContainerRuntime?, items: [ContainerItem]) {
        let parsed = parseContainerProbeResult(raw)
        return (parsed.runtime, parsed.items)
    }

    public static func containerActionCommand(runtime: ContainerRuntime, id: String, action: ContainerAction) -> String? {
        guard isValidContainerID(id) else { return nil }
        return "\(runtime.rawValue) \(action.rawValue) \(posixSingleQuoted(id)) 2>&1"
    }

    public static func containerLogsCommand(runtime: ContainerRuntime, id: String, tail: Int = 200) -> String? {
        guard isValidContainerID(id) else { return nil }
        let clampedTail = min(max(1, tail), 2000)
        return "\(runtime.rawValue) logs --tail \(clampedTail) \(posixSingleQuoted(id)) 2>&1"
    }

    public static func containerExecCommand(runtime: ContainerRuntime, id: String) -> String? {
        guard isValidContainerID(id) else { return nil }
        return "\(runtime.rawValue) exec -it \(posixSingleQuoted(id)) /bin/sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'"
    }

    /// Dynamically lists loaded systemd services on Linux hosts.
    public static let systemdDynamicProbeCommand = """
    LC_ALL=C; export LC_ALL
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-units --type=service --all --no-pager --no-legend --plain 2>/dev/null | head -120
    fi
    """

    public static func parseSystemdDynamicOutput(_ raw: String) -> [SystemdServiceItem] {
        var items: [SystemdServiceItem] = []
        var seen: Set<String> = []
        for rawLine in raw.components(separatedBy: .newlines) {
            var trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("●") {
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if trimmed.isEmpty || trimmed.hasPrefix("UNIT ") || trimmed.hasPrefix("---") { continue }
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 4 else { continue }
            var unit = String(parts[0])
            if unit.hasSuffix(".service") {
                unit = String(unit.dropLast(".service".count))
            }
            guard !unit.isEmpty, isValidSystemdUnitName(unit), seen.insert(unit).inserted else { continue }
            let activeState = String(parts[2]).lowercased()
            let subState = String(parts[3]).lowercased()
            items.append(SystemdServiceItem(name: unit, activeState: activeState, subState: subState))
        }
        return items.sorted { lhs, rhs in
            let lhsPriority = (lhs.activeState == "failed" ? 0 : (lhs.isRunning ? 1 : 2))
            let rhsPriority = (rhs.activeState == "failed" ? 0 : (rhs.isRunning ? 1 : 2))
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func systemdActionCommand(unit: String, action: SystemdServiceAction) -> String? {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSystemdUnitName(trimmed) else { return nil }
        let probeItem = SystemdServiceItem(name: trimmed, activeState: "active")
        if action == .stop && probeItem.isProtectedForStop {
            return nil
        }
        return "systemctl \(action.rawValue) \(posixSingleQuoted(trimmed)) 2>&1"
    }

    public static func systemdJournalCommand(unit: String, lines: Int = 100) -> String? {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSystemdUnitName(trimmed) else { return nil }
        let clamped = min(max(1, lines), 1000)
        return "journalctl -u \(posixSingleQuoted(trimmed)) -n \(clamped) --no-pager 2>&1"
    }

    // MARK: - Container Stats, Compose Stacks, Systemd Unit Status/Cat & OpenRC Fallback (v1.31.0)

    public static func systemdStatusCommand(unit: String) -> String? {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSystemdUnitName(trimmed) else { return nil }
        return "systemctl status \(posixSingleQuoted(trimmed)) --no-pager -n 30 2>&1"
    }

    public static func systemdCatCommand(unit: String) -> String? {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSystemdUnitName(trimmed) else { return nil }
        return "systemctl cat \(posixSingleQuoted(trimmed)) --no-pager 2>&1"
    }

    public static func containerStatsProbeCommand(runtime: ContainerRuntime) -> String {
        """
        LC_ALL=C; export LC_ALL
        \(runtime.rawValue) stats --no-stream --format '{{.ID}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' 2>/dev/null
        """
    }

    public static let containerStatsAutoProbeCommand = """
    LC_ALL=C; export LC_ALL
    if command -v docker >/dev/null 2>&1; then
        docker stats --no-stream --format '{{.ID}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' 2>/dev/null
    elif command -v podman >/dev/null 2>&1; then
        podman stats --no-stream --format '{{.ID}}\t{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' 2>/dev/null
    fi
    """

    public static func parseContainerStatsOutput(_ raw: String) -> [ContainerStatsItem] {
        var stats: [ContainerStatsItem] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, rawLine.contains("\t") else { continue }
            let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard cols.count >= 7 else { continue }
            let id = cols[0]
            let name = cols[1]
            if id.isEmpty && name.isEmpty { continue }
            if id.uppercased() == "CONTAINER ID" || id.uppercased() == "ID" { continue }

            let cpuText = cols[2]
            let memUsage = cols[3]
            let memPctText = cols[4]
            let netIO = cols[5]
            let blockIO = cols[6]
            let pids = cols.count > 7 ? cols[7] : ""

            let cpuVal = parsePercentValue(cpuText)
            let memVal = parsePercentValue(memPctText)
            stats.append(
                ContainerStatsItem(
                    containerIdOrName: id.isEmpty ? name : id,
                    name: name.isEmpty ? id : name,
                    cpuPercentText: cpuText,
                    cpuPercent: cpuVal,
                    memUsageText: memUsage,
                    memPercentText: memPctText,
                    memPercent: memVal,
                    netIOText: netIO,
                    blockIOText: blockIO,
                    pidsText: pids
                )
            )
        }
        return stats
    }

    public static func mergingStats(_ stats: [ContainerStatsItem], into containers: [ContainerItem]) -> [ContainerItem] {
        guard !stats.isEmpty else { return containers }
        return containers.map { container in
            var updated = container
            if let matched = stats.first(where: { stat in
                stat.containerIdOrName == container.id
                    || stat.containerIdOrName == container.shortId
                    || stat.name == container.name
                    || (!stat.containerIdOrName.isEmpty && (container.id.hasPrefix(stat.containerIdOrName) || stat.containerIdOrName.hasPrefix(container.shortId)))
            }) {
                updated.stats = matched
            }
            return updated
        }
    }

    private static func parsePercentValue(_ raw: String) -> Double {
        let clean = raw
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(clean) ?? 0.0
    }

    public static let dockerComposeStacksProbeCommand = """
    LC_ALL=C; export LC_ALL
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        docker compose ls -a --format json 2>/dev/null || docker compose ls -a 2>/dev/null
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose ls 2>/dev/null
    fi
    """

    public static func parseDockerComposeStacksOutput(_ raw: String) -> [DockerComposeStackItem] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            struct ComposeJSONRow: Decodable {
                let Name: String?
                let Status: String?
                let ConfigFiles: String?
                let name: String?
                let status: String?
                let configFiles: String?
            }
            if let data = trimmed.data(using: .utf8) {
                if let array = try? JSONDecoder().decode([ComposeJSONRow].self, from: data) {
                    return array.compactMap { row in
                        let name = (row.Name ?? row.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let status = (row.Status ?? row.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let configs = (row.ConfigFiles ?? row.configFiles ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return nil }
                        return DockerComposeStackItem(name: name, status: status, configFiles: configs)
                    }
                }
                if let single = try? JSONDecoder().decode(ComposeJSONRow.self, from: data),
                   let name = (single.Name ?? single.name)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    return [DockerComposeStackItem(
                        name: name,
                        status: (single.Status ?? single.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        configFiles: (single.ConfigFiles ?? single.configFiles ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    )]
                }
            }
        }

        // Fallback tabular output: NAME  STATUS  CONFIG FILES
        var stacks: [DockerComposeStackItem] = []
        var seen: Set<String> = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("NAME ") && upper.contains("STATUS") { continue }

            let cols: [String]
            if line.contains("\t") {
                cols = line.split(separator: "\t").map { String($0).trimmingCharacters(in: .whitespaces) }
            } else {
                cols = line.components(separatedBy: "  ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            guard cols.count >= 2, !cols[0].isEmpty, seen.insert(cols[0]).inserted else { continue }
            stacks.append(DockerComposeStackItem(
                name: cols[0],
                status: cols[1],
                configFiles: cols.count > 2 ? cols[2] : ""
            ))
        }
        return stacks
    }

    public static let openRCServicesProbeCommand = """
    LC_ALL=C; export LC_ALL
    if command -v rc-status >/dev/null 2>&1; then
        rc-status -a 2>/dev/null || rc-status 2>/dev/null
    fi
    """

    public static func parseOpenRCOutput(_ raw: String) -> [SystemdServiceItem] {
        var items: [SystemdServiceItem] = []
        var seen: Set<String> = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("Runlevel:") || trimmed.hasPrefix("Dynamic Runlevel:") {
                continue
            }
            guard let openBracket = trimmed.lastIndex(of: "["),
                  let closeBracket = trimmed.lastIndex(of: "]"),
                  openBracket < closeBracket else {
                continue
            }
            let serviceName = String(trimmed[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
            let stateText = String(trimmed[trimmed.index(after: openBracket)..<closeBracket])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !serviceName.isEmpty,
                  isValidSystemdUnitName(serviceName),
                  seen.insert(serviceName).inserted else {
                continue
            }

            let activeState: String
            switch stateText {
            case "started", "active", "running":
                activeState = "active"
            case "crashed", "failed", "error":
                activeState = "failed"
            case "starting":
                activeState = "activating"
            default:
                activeState = "inactive"
            }
            items.append(SystemdServiceItem(name: serviceName, activeState: activeState, subState: "openrc (\(stateText))"))
        }
        return items.sorted { lhs, rhs in
            let lhsPriority = (lhs.activeState == "failed" ? 0 : (lhs.isRunning ? 1 : 2))
            let rhsPriority = (rhs.activeState == "failed" ? 0 : (rhs.isRunning ? 1 : 2))
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func openRCActionCommand(unit: String, action: SystemdServiceAction) -> String? {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSystemdUnitName(trimmed) else { return nil }
        let probeItem = SystemdServiceItem(name: trimmed, activeState: "active")
        if action == .stop && probeItem.isProtectedForStop {
            return nil
        }
        return "rc-service \(posixSingleQuoted(trimmed)) \(action.rawValue) 2>&1"
    }
    
    // Previous CPU state for calculating deltas: (idle, total)
    public struct CpuTickState: Sendable {
        public let idle: UInt64
        public let total: UInt64
        public init(idle: UInt64 = 0, total: UInt64 = 0) {
            self.idle = idle
            self.total = total
        }
    }
    
    // Previous Network state for calculating deltas: (rxBytes, txBytes, timestamp, remoteUptime, smoothedRates)
    public struct NetTickState: Sendable {
        public let rx: UInt64
        public let tx: UInt64
        public let timestamp: Date
        public let remoteUptime: Double
        public let smoothedRxRate: Double
        public let smoothedTxRate: Double
        public init(
            rx: UInt64 = 0,
            tx: UInt64 = 0,
            timestamp: Date = Date(),
            remoteUptime: Double = 0,
            smoothedRxRate: Double = 0,
            smoothedTxRate: Double = 0
        ) {
            self.rx = rx
            self.tx = tx
            self.timestamp = timestamp
            self.remoteUptime = remoteUptime
            self.smoothedRxRate = smoothedRxRate
            self.smoothedTxRate = smoothedTxRate
        }
    }
    
    /// Auto-detects Linux vs macOS and parses accordingly
    public func parseOutput(
        _ raw: String,
        prevCpu: inout CpuTickState?,
        prevNet: inout NetTickState?
    ) -> ServerMetricsSnapshot {
        if raw.contains("CPU usage:") || raw.contains("PhysMem:") {
            return parseMacOSOutput(raw, prevNet: &prevNet)
        } else {
            return parseLinuxOutput(raw, prevCpu: &prevCpu, prevNet: &prevNet)
        }
    }
    
    /// Parse macOS probe stdout into ServerMetricsSnapshot
    public func parseMacOSOutput(
        _ raw: String,
        prevNet: inout NetTickState?
    ) -> ServerMetricsSnapshot {
        var cpuPercent = 0.0
        var cpuCores = 8
        var cpuModel = ""
        var memTotal: UInt64 = 0
        var memUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        var swapUsed: UInt64 = 0
        var netRxTotal: UInt64 = 0
        var netTxTotal: UInt64 = 0
        var diskTotal: UInt64 = 0
        var diskUsed: UInt64 = 0
        var diskDevice = ""
        var diskMountPoint = "/"
        var diskType = ""
        var isSSD = true
        var load1 = 0.0
        var load5 = 0.0
        var load15 = 0.0
        var uptime: UInt64 = 0
        var topProcesses: [ProcessMetricItem] = []
        
        let lines = raw.components(separatedBy: "\n")
        var currentSection = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            if trimmed.hasPrefix("---") && trimmed.hasSuffix("---") {
                currentSection = trimmed
                continue
            }
            
            if currentSection == "---CPUMODEL---" {
                if cpuModel.isEmpty && !trimmed.isEmpty {
                    cpuModel = trimmed
                }
                continue
            }
            
            if currentSection == "---DISKTYPE---" {
                if diskType.isEmpty && !trimmed.isEmpty {
                    diskType = trimmed
                    isSSD = !trimmed.contains("HDD")
                }
                continue
            }
            
            if trimmed.hasPrefix("CPU usage:") {
                // Example: CPU usage: 7.82% user, 11.38% sys, 80.78% idle
                if let idleRange = trimmed.range(of: "% idle") {
                    let beforeIdle = trimmed[..<idleRange.lowerBound]
                    if let lastSpace = beforeIdle.lastIndex(of: " ") {
                        let idleStr = String(beforeIdle[lastSpace...]).trimmingCharacters(in: .whitespaces)
                        if let idleVal = Double(idleStr) {
                            cpuPercent = max(0.0, min(100.0, 100.0 - idleVal))
                        }
                    }
                }
            } else if trimmed.hasPrefix("PhysMem:") {
                // Example: PhysMem: 15G used (1740M wired, 2732M compressor), 182M unused.
                memUsed = parseMemUnit(trimmed, keyword: "used")
                let unused = parseMemUnit(trimmed, keyword: "unused")
                memTotal = memUsed + unused
            } else if currentSection == "---SWAP---" || (trimmed.contains("total =") && trimmed.contains("used =")) {
                // Example: total = 2048.00M  used = 512.25M  free = 1535.75M  (encrypted)
                swapTotal = parseSwapKeyword(trimmed, keyword: "total =")
                swapUsed = parseSwapKeyword(trimmed, keyword: "used =")
            } else if currentSection == "---CORES---" {
                if let c = Int(trimmed), c > 0 {
                    cpuCores = c
                }
            } else if currentSection == "---DF---" {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 4 {
                    diskDevice = String(parts[0])
                    if parts.count >= 6 {
                        diskMountPoint = String(parts[5])
                    }
                    if let total1K = UInt64(parts[1]), let used1K = UInt64(parts[2]) {
                        diskTotal = total1K * 1024
                        diskUsed = used1K * 1024
                    }
                }
            } else if currentSection == "---UPTIME---" {
                // Example: 6:51 up 6 days, 22:50, 3 users, load averages: 1.16 1.13 1.15
                if let loadRange = trimmed.range(of: "load averages:") ?? trimmed.range(of: "load average:") {
                    let loadsStr = trimmed[loadRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    let loads = loadsStr.components(separatedBy: " ").filter { !$0.isEmpty }
                    if loads.count >= 3 {
                        load1 = Double(loads[0].replacingOccurrences(of: ",", with: "")) ?? 0.0
                        load5 = Double(loads[1].replacingOccurrences(of: ",", with: "")) ?? 0.0
                        load15 = Double(loads[2].replacingOccurrences(of: ",", with: "")) ?? 0.0
                    }
                }
                uptime = parseMacOSUptime(trimmed)
            } else if currentSection == "---NET---" {
                // Example: en0 1500 <Link#6> 14:98:77:5a:b4:d5 48176988 0 46142541246 20691726 0 5206320117 0
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 10 {
                    let rxIdx = parts.count >= 11 ? parts.count - 5 : 6
                    let txIdx = parts.count >= 11 ? parts.count - 2 : 9
                    netRxTotal = UInt64(parts[rxIdx]) ?? 0
                    netTxTotal = UInt64(parts[txIdx]) ?? 0
                }
            } else if currentSection == "---TOP---" {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 5 {
                    if parts[0] == "PID" || parts[0] == "pid" { continue }
                    if let pid = Int(parts[0]),
                       let cpu = Double(parts[2]),
                       let mem = Double(parts[3]) {
                        let user = String(parts[1])
                        let cmd = parts.dropFirst(4).joined(separator: " ")
                        topProcesses.append(ProcessMetricItem(pid: pid, user: user, cpuPercent: cpu, memPercent: mem, command: cmd))
                    }
                }
            }
        }
        
        // Calculate network rate with smooth EMA filter
        var rxRate = 0.0
        var txRate = 0.0
        let now = Date()
        if let prevN = prevNet {
            let dt = now.timeIntervalSince(prevN.timestamp)
            if dt > 0.1 && netRxTotal >= prevN.rx && netTxTotal >= prevN.tx {
                let rawRx = Double(netRxTotal - prevN.rx) / dt
                let rawTx = Double(netTxTotal - prevN.tx) / dt
                rxRate = prevN.smoothedRxRate > 0 ? (rawRx * 0.72 + prevN.smoothedRxRate * 0.28) : rawRx
                txRate = prevN.smoothedTxRate > 0 ? (rawTx * 0.72 + prevN.smoothedTxRate * 0.28) : rawTx
            }
        }
        prevNet = NetTickState(
            rx: netRxTotal,
            tx: netTxTotal,
            timestamp: now,
            remoteUptime: 0,
            smoothedRxRate: rxRate,
            smoothedTxRate: txRate
        )
        
        if cpuModel.isEmpty {
            cpuModel = "Apple Silicon"
        }
        if diskType.isEmpty {
            diskType = "NVMe SSD"
            isSSD = true
        }
        
        let rootPartition = DiskPartitionItem(
            filesystem: diskDevice.isEmpty ? "/dev/disk3s1s1" : diskDevice,
            mountPoint: diskMountPoint,
            totalBytes: diskTotal,
            usedBytes: diskUsed,
            isSSD: isSSD,
            diskType: diskType
        )
        
        return ServerMetricsSnapshot(
            timestamp: now,
            cpuUsagePercent: cpuPercent,
            cpuCores: cpuCores,
            cpuModel: cpuModel,
            memoryTotalBytes: memTotal,
            memoryUsedBytes: memUsed,
            memoryCachedBytes: 0,
            swapTotalBytes: swapTotal,
            swapUsedBytes: swapUsed,
            networkRxBytesPerSec: rxRate,
            networkTxBytesPerSec: txRate,
            diskTotalBytes: diskTotal,
            diskUsedBytes: diskUsed,
            diskDevice: diskDevice,
            diskMountPoint: diskMountPoint,
            diskType: diskType,
            isSSD: isSSD,
            disks: [rootPartition],
            loadAvg1m: load1,
            loadAvg5m: load5,
            loadAvg15m: load15,
            uptimeSeconds: uptime,
            topProcesses: topProcesses
        )
    }
    
    private func parseMemUnit(_ text: String, keyword: String) -> UInt64 {
        guard let range = text.range(of: keyword) else { return 0 }
        let sub = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        // Find digits before unit like 15G or 182M
        var numStr = ""
        var unit = "M"
        for char in sub.reversed() {
            if char.isWhitespace || char == "(" || char == "," {
                if !numStr.isEmpty { break }
            } else if char == "G" || char == "g" {
                unit = "G"
            } else if char == "M" || char == "m" {
                unit = "M"
            } else if char == "K" || char == "k" {
                unit = "K"
            } else if char.isNumber || char == "." {
                numStr.insert(char, at: numStr.startIndex)
            }
        }
        guard let val = Double(numStr) else { return 0 }
        switch unit {
        case "G": return UInt64(val * 1024 * 1024 * 1024)
        case "M": return UInt64(val * 1024 * 1024)
        case "K": return UInt64(val * 1024)
        default: return UInt64(val)
        }
    }
    
    private func parseMacOSUptime(_ text: String) -> UInt64 {
        guard let upRange = text.range(of: "up ") else { return 0 }
        let afterUp = text[upRange.upperBound...]
        let uptimeBody: Substring
        if let usersRange = afterUp.range(of: " user") {
            let beforeUsers = afterUp[..<usersRange.lowerBound]
            if let lastComma = beforeUsers.lastIndex(of: ",") {
                uptimeBody = beforeUsers[..<lastComma]
            } else {
                uptimeBody = beforeUsers
            }
        } else if let loadRange = afterUp.range(of: "load average") {
            uptimeBody = afterUp[..<loadRange.lowerBound]
        } else {
            uptimeBody = afterUp
        }
        var daysSec: UInt64 = 0
        var subDaySec: UInt64 = 0
        for rawPart in uptimeBody.split(separator: ",") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            if part.contains("day") {
                let d = part.split(whereSeparator: { !$0.isNumber }).compactMap { UInt64($0) }.first ?? 0
                daysSec += d * 86400
            } else if part.contains("hr") {
                let h = part.split(whereSeparator: { !$0.isNumber }).compactMap { UInt64($0) }.first ?? 0
                subDaySec += h * 3600
            } else if part.contains("min") {
                let m = part.split(whereSeparator: { !$0.isNumber }).compactMap { UInt64($0) }.first ?? 0
                subDaySec += m * 60
            } else if part.contains("sec") {
                let s = part.split(whereSeparator: { !$0.isNumber }).compactMap { UInt64($0) }.first ?? 0
                subDaySec += s
            } else if part.contains(":") {
                let hm = part.split(separator: ":").compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
                if hm.count == 2 {
                    subDaySec += hm[0] * 3600 + hm[1] * 60
                }
            }
        }
        return daysSec + subDaySec
    }
    
    /// Parse Linux probe stdout into ServerMetricsSnapshot
    public func parseLinuxOutput(
        _ raw: String,
        prevCpu: inout CpuTickState?,
        prevNet: inout NetTickState?
    ) -> ServerMetricsSnapshot {
        var cpuPercent = 0.0
        var cpuCores = 0
        var cpuModel = ""
        var memTotal: UInt64 = 0
        var memAvailable: UInt64 = 0
        var memFree: UInt64 = 0
        var memBuffers: UInt64 = 0
        var memCached: UInt64 = 0
        var swapTotal: UInt64 = 0
        var swapFree: UInt64 = 0
        var netRxTotal: UInt64 = 0
        var netTxTotal: UInt64 = 0
        var diskTotal: UInt64 = 0
        var diskUsed: UInt64 = 0
        var diskDevice = ""
        var diskMountPoint = "/"
        var diskType = ""
        var isSSD = true
        var load1 = 0.0
        var load5 = 0.0
        var load15 = 0.0
        var uptime: UInt64 = 0
        var uptimeExact: Double = 0.0
        var topProcesses: [ProcessMetricItem] = []
        
        let lines = raw.components(separatedBy: "\n")
        var currentSection = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            if trimmed.hasPrefix("---") && trimmed.hasSuffix("---") {
                currentSection = trimmed
                continue
            }
            
            if currentSection == "---CPUMODEL---" {
                if cpuModel.isEmpty && !trimmed.isEmpty {
                    cpuModel = trimmed
                }
                continue
            }
            
            if currentSection == "---DISKTYPE---" {
                if diskType.isEmpty && !trimmed.isEmpty {
                    diskType = trimmed
                    isSSD = !trimmed.contains("HDD")
                }
                continue
            }
            
            if currentSection == "---TOP---" {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 5 {
                    if parts[0] == "PID" || parts[0] == "pid" { continue }
                    if let pid = Int(parts[0]),
                       let cpu = Double(parts[2]),
                       let mem = Double(parts[3]) {
                        let user = String(parts[1])
                        let cmd = parts.dropFirst(4).joined(separator: " ")
                        topProcesses.append(ProcessMetricItem(pid: pid, user: user, cpuPercent: cpu, memPercent: mem, command: cmd))
                    }
                } else if parts.count == 4,
                          parts[0] != "PID", parts[0] != "pid",
                          let pid = Int(parts[0]),
                          Double(parts[2]) != nil {
                    // BusyBox fallback: pid,user,rss,comm
                    let user = String(parts[1])
                    let cmd = String(parts[3])
                    topProcesses.append(ProcessMetricItem(pid: pid, user: user, cpuPercent: 0.0, memPercent: 0.0, command: cmd))
                }
                continue
            }
            
            if currentSection == "---DF---" {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 4 {
                    // Filesystem 1K-blocks Used Available Use% Mounted on
                    diskDevice = String(parts[0])
                    if parts.count >= 6 {
                        diskMountPoint = String(parts[5])
                    }
                    if let total1K = UInt64(parts[1]), let used1K = UInt64(parts[2]) {
                        diskTotal = total1K * 1024
                        diskUsed = used1K * 1024
                    }
                }
                continue
            }
            
            if currentSection == "---UPTIME---" {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if let upSec = parts.first, let val = Double(upSec) {
                    uptime = UInt64(val)
                    uptimeExact = val
                }
                continue
            }
            
            if currentSection == "---LOAD---" {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 3 {
                    load1 = Double(parts[0]) ?? 0.0
                    load5 = Double(parts[1]) ?? 0.0
                    load15 = Double(parts[2]) ?? 0.0
                }
                continue
            }
            
            // Default section: /proc/stat, /proc/meminfo, /proc/net/dev
            if trimmed.hasPrefix("cpu ") {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 5 {
                    let user = UInt64(parts[1]) ?? 0
                    let nice = UInt64(parts[2]) ?? 0
                    let system = UInt64(parts[3]) ?? 0
                    let idle = UInt64(parts[4]) ?? 0
                    let iowait = parts.count > 5 ? (UInt64(parts[5]) ?? 0) : 0
                    let irq = parts.count > 6 ? (UInt64(parts[6]) ?? 0) : 0
                    let softirq = parts.count > 7 ? (UInt64(parts[7]) ?? 0) : 0
                    let steal = parts.count > 8 ? (UInt64(parts[8]) ?? 0) : 0
                    
                    let idleTime = idle + iowait
                    let nonIdleTime = user + nice + system + irq + softirq + steal
                    let totalTime = idleTime + nonIdleTime
                    
                    if let prev = prevCpu, totalTime > prev.total, idleTime >= prev.idle {
                        let totalDelta = totalTime - prev.total
                        let idleDelta = idleTime - prev.idle
                        if totalDelta > 0 && totalDelta >= idleDelta {
                            cpuPercent = Double(totalDelta - idleDelta) / Double(totalDelta) * 100.0
                        }
                    }
                    prevCpu = CpuTickState(idle: idleTime, total: totalTime)
                }
            } else if trimmed.hasPrefix("cpu") && trimmed.first(where: { $0.isNumber }) != nil {
                cpuCores += 1
            } else if trimmed.hasPrefix("MemTotal:") {
                memTotal = parseMeminfoKb(trimmed)
            } else if trimmed.hasPrefix("MemAvailable:") {
                memAvailable = parseMeminfoKb(trimmed)
            } else if trimmed.hasPrefix("MemFree:") {
                memFree = parseMeminfoKb(trimmed)
            } else if trimmed.hasPrefix("Buffers:") {
                memBuffers = parseMeminfoKb(trimmed)
            } else if trimmed.hasPrefix("Cached:") {
                memCached = parseMeminfoKb(trimmed)
            } else if trimmed.hasPrefix("SwapTotal:") {
                swapTotal = parseMeminfoKb(trimmed)
            } else if trimmed.hasPrefix("SwapFree:") {
                swapFree = parseMeminfoKb(trimmed)
            } else if trimmed.contains(":") && Self.isTrackedLinuxNetworkInterfaceLine(trimmed) {
                // Network interface line
                let parts = trimmed.split(whereSeparator: { $0 == ":" || $0.isWhitespace })
                if parts.count >= 10 {
                    let rx = UInt64(parts[1]) ?? 0
                    let tx = UInt64(parts[9]) ?? 0
                    netRxTotal += rx
                    netTxTotal += tx
                }
            }
        }
        
        let memUsed: UInt64
        if memAvailable > 0 && memTotal >= memAvailable {
            memUsed = memTotal - memAvailable
        } else {
            memUsed = memTotal > (memFree + memBuffers + memCached) ? (memTotal - memFree - memBuffers - memCached) : 0
        }
        let swapUsed: UInt64 = swapTotal >= swapFree ? (swapTotal - swapFree) : 0
        
        // Calculate network rate using remote monotonic kernel uptime delta when available to eliminate SSH RTT jitter
        var rxRate = 0.0
        var txRate = 0.0
        let now = Date()
        if let prevN = prevNet {
            let remoteDt = (uptimeExact > 0 && prevN.remoteUptime > 0) ? (uptimeExact - prevN.remoteUptime) : 0
            let dt = (remoteDt > 0.05 && remoteDt < 60.0) ? remoteDt : now.timeIntervalSince(prevN.timestamp)
            if dt > 0.05 && netRxTotal >= prevN.rx && netTxTotal >= prevN.tx {
                let rawRx = Double(netRxTotal - prevN.rx) / dt
                let rawTx = Double(netTxTotal - prevN.tx) / dt
                rxRate = prevN.smoothedRxRate > 0 ? (rawRx * 0.72 + prevN.smoothedRxRate * 0.28) : rawRx
                txRate = prevN.smoothedTxRate > 0 ? (rawTx * 0.72 + prevN.smoothedTxRate * 0.28) : rawTx
            }
        }
        prevNet = NetTickState(
            rx: netRxTotal,
            tx: netTxTotal,
            timestamp: now,
            remoteUptime: uptimeExact,
            smoothedRxRate: rxRate,
            smoothedTxRate: txRate
        )
        
        if cpuModel.isEmpty {
            cpuModel = "Linux Server"
        }
        if diskType.isEmpty {
            if diskDevice.contains("nvme") {
                diskType = "NVMe SSD"
                isSSD = true
            } else {
                diskType = "SSD"
                isSSD = true
            }
        }
        let rootPartition = DiskPartitionItem(
            filesystem: diskDevice.isEmpty ? "/dev/sda1" : diskDevice,
            mountPoint: diskMountPoint,
            totalBytes: diskTotal,
            usedBytes: diskUsed,
            isSSD: isSSD,
            diskType: diskType
        )
        
        return ServerMetricsSnapshot(
            timestamp: now,
            cpuUsagePercent: min(max(cpuPercent, 0.0), 100.0),
            cpuCores: max(cpuCores, 1),
            cpuModel: cpuModel,
            memoryTotalBytes: memTotal,
            memoryUsedBytes: memUsed,
            memoryCachedBytes: memCached,
            swapTotalBytes: swapTotal,
            swapUsedBytes: swapUsed,
            networkRxBytesPerSec: rxRate,
            networkTxBytesPerSec: txRate,
            diskTotalBytes: diskTotal,
            diskUsedBytes: diskUsed,
            diskDevice: diskDevice,
            diskMountPoint: diskMountPoint,
            diskType: diskType,
            isSSD: isSSD,
            disks: [rootPartition],
            loadAvg1m: load1,
            loadAvg5m: load5,
            loadAvg15m: load15,
            uptimeSeconds: uptime,
            topProcesses: topProcesses
        )
    }
    
    private func parseMeminfoKb(_ line: String) -> UInt64 {
        let parts = line.split(whereSeparator: { $0.isWhitespace })
        if parts.count >= 2, let kb = UInt64(parts[1]) {
            return kb * 1024
        }
        return 0
    }

    private func parseSwapKeyword(_ text: String, keyword: String) -> UInt64 {
        guard let range = text.range(of: keyword) else { return 0 }
        let after = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        var numStr = ""
        var unit = "M"
        for char in after {
            if char.isNumber || char == "." {
                numStr.append(char)
            } else if char == "G" || char == "g" {
                unit = "G"
                break
            } else if char == "M" || char == "m" {
                unit = "M"
                break
            } else if char == "K" || char == "k" {
                unit = "K"
                break
            } else if !numStr.isEmpty {
                break
            }
        }
        guard let val = Double(numStr) else { return 0 }
        switch unit {
        case "G": return UInt64(val * 1024 * 1024 * 1024)
        case "M": return UInt64(val * 1024 * 1024)
        case "K": return UInt64(val * 1024)
        default: return UInt64(val)
        }
    }

    private static func isTrackedLinuxNetworkInterfaceLine(_ trimmed: String) -> Bool {
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let iface = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        guard !iface.isEmpty else { return false }
        let isIndexedEn = iface.hasPrefix("en") && iface.dropFirst(2).first?.isASCII == true && iface.dropFirst(2).first?.isNumber == true
        return iface.hasPrefix("eth")
            || iface.hasPrefix("ens")
            || iface.hasPrefix("enp")
            || iface.hasPrefix("eno")
            || iface.hasPrefix("enx")
            || isIndexedEn
            || iface.hasPrefix("em")
            || iface.hasPrefix("bond")
            || iface.hasPrefix("wlan")
            || iface.hasPrefix("wlp")
            || iface.hasPrefix("venet")
            || iface.hasPrefix("vmbr")
            || iface.hasPrefix("ib")
            || iface.hasPrefix("br")
            || iface.hasPrefix("wg")
            || iface.hasPrefix("tun")
            || iface.hasPrefix("tap")
            || iface.hasPrefix("tailscale")
            || iface.hasPrefix("ppp")
    }
}
