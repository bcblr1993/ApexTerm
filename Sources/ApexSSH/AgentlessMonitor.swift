import Foundation
import ApexCore

/// Zero-agent remote metrics parser for Linux and macOS
public final class AgentlessMonitor: Sendable {
    public init() {}
    
    /// Script payload sent to remote Linux host over lightweight SSH channel
    public static let linuxProbeCommand = """
    cat /proc/stat /proc/meminfo /proc/net/dev 2>/dev/null; echo "---DF---"; df -k / 2>/dev/null | tail -1; echo "---UPTIME---"; cat /proc/uptime 2>/dev/null; echo "---LOAD---"; cat /proc/loadavg 2>/dev/null
    """
    
    /// Script payload sent to remote macOS host
    public static let macosProbeCommand = """
    top -l 1 -n 0 -s 0 | grep -E "CPU usage|PhysMem"; echo "---DF---"; df -k / | tail -1; echo "---UPTIME---"; uptime
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
    
    /// Parse Linux probe stdout into ServerMetricsSnapshot
    public func parseLinuxOutput(
        _ raw: String,
        prevCpu: inout CpuTickState?,
        prevNet: inout NetTickState?
    ) -> ServerMetricsSnapshot {
        var cpuPercent = 0.0
        var cpuCores = 0
        var memTotal: UInt64 = 0
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
        
        let lines = raw.components(separatedBy: "\n")
        var currentSection = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            if trimmed.hasPrefix("---") && trimmed.hasSuffix("---") {
                currentSection = trimmed
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
            } else if trimmed.hasPrefix("MemFree:") {
                memFree = parseMeminfoKb(trimmed)
            } else if trimmed.hasPrefix("Buffers:") {
                memBuffers = parseMeminfoKb(trimmed)
            } else if trimmed.hasPrefix("Cached:") {
                memCached = parseMeminfoKb(trimmed)
            } else if trimmed.contains(":") && (trimmed.contains("eth") || trimmed.contains("ens") || trimmed.contains("enp") || trimmed.contains("wlan")) {
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
        
        let memUsed = memTotal > (memFree + memBuffers + memCached) ? (memTotal - memFree - memBuffers - memCached) : 0
        
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
            uptimeSeconds: uptime
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
