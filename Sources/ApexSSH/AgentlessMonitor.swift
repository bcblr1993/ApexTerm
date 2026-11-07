import Foundation
import ApexCore

/// Zero-agent remote metrics parser for Linux and macOS
public final class AgentlessMonitor: Sendable {
    public init() {}
    
    /// Script payload sent to remote Linux host over lightweight SSH channel
    public static let linuxProbeCommand = """
    cat /proc/stat /proc/meminfo /proc/net/dev 2>/dev/null; echo "---DF---"; df -k / 2>/dev/null | tail -1; echo "---UPTIME---"; cat /proc/uptime 2>/dev/null; echo "---LOAD---"; cat /proc/loadavg 2>/dev/null; echo "---TOP---"; ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -6; echo "---CPUMODEL---"; (grep -m1 "model name" /proc/cpuinfo 2>/dev/null || grep -m1 "Hardware" /proc/cpuinfo 2>/dev/null || uname -m) | cut -d: -f2 | sed 's/^[ \t]*//'; echo "---DISKTYPE---"; ROOT_DEV=$(df / 2>/dev/null | tail -1 | awk '{print $1}' | sed 's|/dev/||'); PARENT_DEV=$(echo "$ROOT_DEV" | sed -E 's/p?[0-9]+$//'); if [ -f "/sys/block/$PARENT_DEV/queue/rotational" ]; then if [ "$(cat /sys/block/$PARENT_DEV/queue/rotational 2>/dev/null)" = "0" ]; then if echo "$ROOT_DEV" | grep -q "nvme"; then echo "NVMe SSD"; else echo "SSD"; fi; else echo "HDD"; fi; elif echo "$ROOT_DEV" | grep -q "nvme"; then echo "NVMe SSD"; elif lsblk -d -n -o rota "/dev/$PARENT_DEV" 2>/dev/null | grep -q "0"; then echo "SSD"; elif lsblk -d -n -o rota "/dev/$PARENT_DEV" 2>/dev/null | grep -q "1"; then echo "HDD"; else echo "SSD"; fi
    """
    
    /// Script payload sent to remote macOS host
    public static let macosProbeCommand = """
    top -l 1 -n 0 -s 0 | grep -E "CPU usage|PhysMem"; echo "---SWAP---"; sysctl -n vm.swapusage 2>/dev/null; echo "---CORES---"; sysctl -n hw.ncpu 2>/dev/null || echo "8"; echo "---DF---"; df -k / | tail -1; echo "---UPTIME---"; uptime; echo "---NET---"; netstat -ib -n 2>/dev/null | awk '$1 ~ /^en[0-9]+$/ && $3 ~ /^<Link#/ { rx += $(NF-4); tx += $(NF-1) } END { printf "en0 1500 <Link#1> 00:00:00:00:00:00 0 0 %.0f 0 0 %.0f 0\\n", rx, tx }'; echo "---TOP---"; ps -eo pid,user,%cpu,%mem,comm -r 2>/dev/null | head -6; echo "---CPUMODEL---"; sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model; echo "---DISKTYPE---"; if diskutil info / 2>/dev/null | grep -q "Solid State: *Yes"; then if diskutil info / 2>/dev/null | grep -E -q "Apple Fabric|PCI-Express|NVMe"; then echo "NVMe SSD"; else echo "SSD"; fi; else echo "HDD"; fi
    """
    
    /// Auto-detecting multi-OS probe command
    public static let autoProbeCommand = """
    if [ "$(uname)" = "Darwin" ]; then
        \(macosProbeCommand)
    else
        \(linuxProbeCommand)
    fi
    """
    
    /// Full process inspection command returning Top 45 processes with complete attributes
    public static let processInspectorProbeCommand = """
    if [ "$(uname)" = "Darwin" ]; then
        ps -eo pid,user,%cpu,%mem,rss,vsz,stat,comm,command -r 2>/dev/null | head -46
    else
        ps -eo pid,user,%cpu,%mem,rss,vsz,stat,comm,args --sort=-%cpu 2>/dev/null | head -46
    fi
    """
    
    /// Systemd service states query command (returns empty output on macOS/Alpine/BSD hosts without systemctl)
    public static func systemdServicesProbeCommand(services: [String] = ["nginx", "docker", "redis", "mysql", "sshd", "postgresql", "caddy"]) -> String {
        let joined = services.joined(separator: " ")
        return """
        if command -v systemctl >/dev/null 2>&1; then
            for s in \(joined); do
                systemctl is-active "$s" 2>/dev/null || echo "inactive"
            done
        fi
        """
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
        return iface.hasPrefix("eth")
            || iface.hasPrefix("ens")
            || iface.hasPrefix("enp")
            || iface.hasPrefix("eno")
            || iface.hasPrefix("enx")
            || iface.hasPrefix("em")
            || iface.hasPrefix("bond")
            || iface.hasPrefix("wlan")
            || iface.hasPrefix("wlp")
            || iface.hasPrefix("venet")
            || iface.hasPrefix("vmbr")
            || iface.hasPrefix("ib")
    }
}
