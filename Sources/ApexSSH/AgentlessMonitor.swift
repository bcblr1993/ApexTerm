import Foundation
import ApexCore

/// Zero-agent remote metrics parser for Linux and macOS
public final class AgentlessMonitor: Sendable {
    public init() {}
    
    /// Script payload sent to remote Linux host over lightweight SSH channel
    public static let linuxProbeCommand = """
    cat /proc/stat /proc/meminfo /proc/net/dev 2>/dev/null; echo "---DF---"; df -k / 2>/dev/null | tail -1; echo "---UPTIME---"; cat /proc/uptime 2>/dev/null; echo "---LOAD---"; cat /proc/loadavg 2>/dev/null; echo "---TOP---"; ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -6
    """
    
    /// Script payload sent to remote macOS host
    public static let macosProbeCommand = """
    top -l 1 -n 0 -s 0 | grep -E "CPU usage|PhysMem"; echo "---CORES---"; sysctl -n hw.ncpu 2>/dev/null || echo "8"; echo "---DF---"; df -k / | tail -1; echo "---UPTIME---"; uptime; echo "---NET---"; netstat -ib -n -I en0 2>/dev/null | grep -E "en0" | head -1; echo "---TOP---"; ps -eo pid,user,%cpu,%mem,comm -r 2>/dev/null | head -6
    """
    
    /// Auto-detecting multi-OS probe command
    public static let autoProbeCommand = """
    if [ "$(uname)" = "Darwin" ]; then
        \(macosProbeCommand)
    else
        \(linuxProbeCommand)
    fi
    """
    
    // Previous CPU state for calculating deltas: (idle, total)
    public struct CpuTickState: Sendable {
        public let idle: UInt64
        public let total: UInt64
        public init(idle: UInt64 = 0, total: UInt64 = 0) {
            self.idle = idle
            self.total = total
        }
    }
    
    // Previous Network state for calculating deltas: (rxBytes, txBytes, timestamp)
    public struct NetTickState: Sendable {
        public let rx: UInt64
        public let tx: UInt64
        public let timestamp: Date
        public init(rx: UInt64 = 0, tx: UInt64 = 0, timestamp: Date = Date()) {
            self.rx = rx
            self.tx = tx
            self.timestamp = timestamp
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
        var memTotal: UInt64 = 0
        var memUsed: UInt64 = 0
        var netRxTotal: UInt64 = 0
        var netTxTotal: UInt64 = 0
        var diskTotal: UInt64 = 0
        var diskUsed: UInt64 = 0
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
            } else if currentSection == "---CORES---" {
                if let c = Int(trimmed), c > 0 {
                    cpuCores = c
                }
            } else if currentSection == "---DF---" {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 4 {
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
                    netRxTotal = UInt64(parts[6]) ?? 0
                    netTxTotal = UInt64(parts[9]) ?? 0
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
        
        // Calculate network rate
        var rxRate = 0.0
        var txRate = 0.0
        let now = Date()
        if let prevN = prevNet {
            let dt = now.timeIntervalSince(prevN.timestamp)
            if dt > 0.1 && netRxTotal >= prevN.rx && netTxTotal >= prevN.tx {
                rxRate = Double(netRxTotal - prevN.rx) / dt
                txRate = Double(netTxTotal - prevN.tx) / dt
            }
        }
        prevNet = NetTickState(rx: netRxTotal, tx: netTxTotal, timestamp: now)
        
        return ServerMetricsSnapshot(
            timestamp: now,
            cpuUsagePercent: cpuPercent,
            cpuCores: cpuCores,
            memoryTotalBytes: memTotal,
            memoryUsedBytes: memUsed,
            memoryCachedBytes: 0,
            networkRxBytesPerSec: rxRate,
            networkTxBytesPerSec: txRate,
            diskTotalBytes: diskTotal,
            diskUsedBytes: diskUsed,
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
        var totalSec: UInt64 = 0
        if let upRange = text.range(of: "up ") {
            let afterUp = text[upRange.upperBound...]
            if let comma = afterUp.firstIndex(of: ",") {
                let part = String(afterUp[..<comma])
                if part.contains("day") {
                    let d = part.components(separatedBy: " ").compactMap { UInt64($0) }.first ?? 0
                    totalSec += d * 86400
                }
            }
        }
        return totalSec > 0 ? totalSec : 3600
    }
    
    /// Parse Linux probe stdout into ServerMetricsSnapshot
    public func parseLinuxOutput(
        _ raw: String,
        prevCpu: inout CpuTickState?,
        prevNet: inout NetTickState?
    ) -> ServerMetricsSnapshot {
        var cpuPercent = 0.0
        var cpuCores = 0
        var memTotal: UInt64 = 0
        var memAvailable: UInt64 = 0
        var memFree: UInt64 = 0
        var memBuffers: UInt64 = 0
        var memCached: UInt64 = 0
        var netRxTotal: UInt64 = 0
        var netTxTotal: UInt64 = 0
        var diskTotal: UInt64 = 0
        var diskUsed: UInt64 = 0
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
                }
                continue
            }
            
            if currentSection == "---DF---" {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 4 {
                    // Filesystem 1K-blocks Used Available Use% Mounted on
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
                    
                    if let prev = prevCpu, totalTime > prev.total {
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
            } else if trimmed.contains(":") && (trimmed.contains("eth") || trimmed.contains("ens") || trimmed.contains("enp") || trimmed.contains("eno") || trimmed.contains("bond") || trimmed.contains("wlan")) {
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
        
        // Calculate network rate
        var rxRate = 0.0
        var txRate = 0.0
        let now = Date()
        if let prevN = prevNet {
            let dt = now.timeIntervalSince(prevN.timestamp)
            if dt > 0.1 && netRxTotal >= prevN.rx && netTxTotal >= prevN.tx {
                rxRate = Double(netRxTotal - prevN.rx) / dt
                txRate = Double(netTxTotal - prevN.tx) / dt
            }
        }
        prevNet = NetTickState(rx: netRxTotal, tx: netTxTotal, timestamp: now)
        
        return ServerMetricsSnapshot(
            timestamp: now,
            cpuUsagePercent: min(max(cpuPercent, 0.0), 100.0),
            cpuCores: max(cpuCores, 1),
            memoryTotalBytes: memTotal,
            memoryUsedBytes: memUsed,
            memoryCachedBytes: memCached,
            networkRxBytesPerSec: rxRate,
            networkTxBytesPerSec: txRate,
            diskTotalBytes: diskTotal,
            diskUsedBytes: diskUsed,
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
}
