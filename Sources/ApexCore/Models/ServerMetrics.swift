import Foundation

/// Real-time server performance snapshot
public struct ServerMetricsSnapshot: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    
    // CPU
    public var cpuUsagePercent: Double // 0.0 - 100.0
    public var cpuCores: Int
    public var cpuModel: String // e.g. "Apple M1 Max", "Intel Xeon E5-2680", etc.
    
    // Memory
    public var memoryTotalBytes: UInt64
    public var memoryUsedBytes: UInt64
    public var memoryCachedBytes: UInt64
    
    public var memoryUsagePercent: Double {
        guard memoryTotalBytes > 0 else { return 0.0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100.0
    }
    
    // Network (instantaneous rate in bytes per second)
    public var networkRxBytesPerSec: Double
    public var networkTxBytesPerSec: Double
    
    // Disk root partition & hardware attributes
    public var diskTotalBytes: UInt64
    public var diskUsedBytes: UInt64
    public var diskDevice: String // e.g. "/dev/nvme0n1p2" or "/dev/sda1"
    public var diskMountPoint: String // e.g. "/"
    public var diskType: String // e.g. "NVMe SSD", "SSD", "HDD"
    public var isSSD: Bool // true = SSD / NVMe, false = HDD
    public var disks: [DiskPartitionItem]
    
    public var diskUsagePercent: Double {
        guard diskTotalBytes > 0 else { return 0.0 }
        return Double(diskUsedBytes) / Double(diskTotalBytes) * 100.0
    }
    
    public var diskFreeBytes: UInt64 {
        diskTotalBytes > diskUsedBytes ? (diskTotalBytes - diskUsedBytes) : 0
    }
    
    public var diskBadgeText: String {
        if diskType.contains("NVMe") {
            return "NVMe 固态"
        } else if isSSD {
            return "SSD 固态"
        } else {
            return "HDD 机械"
        }
    }
    
    // Load average (1m, 5m, 15m)
    public var loadAvg1m: Double
    public var loadAvg5m: Double
    public var loadAvg15m: Double
    
    // Uptime
    public var uptimeSeconds: UInt64
    
    // Top resource consuming processes
    public var topProcesses: [ProcessMetricItem]
    
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        cpuUsagePercent: Double = 0.0,
        cpuCores: Int = 1,
        cpuModel: String = "",
        memoryTotalBytes: UInt64 = 0,
        memoryUsedBytes: UInt64 = 0,
        memoryCachedBytes: UInt64 = 0,
        networkRxBytesPerSec: Double = 0.0,
        networkTxBytesPerSec: Double = 0.0,
        diskTotalBytes: UInt64 = 0,
        diskUsedBytes: UInt64 = 0,
        diskDevice: String = "",
        diskMountPoint: String = "/",
        diskType: String = "SSD",
        isSSD: Bool = true,
        disks: [DiskPartitionItem] = [],
        loadAvg1m: Double = 0.0,
        loadAvg5m: Double = 0.0,
        loadAvg15m: Double = 0.0,
        uptimeSeconds: UInt64 = 0,
        topProcesses: [ProcessMetricItem] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cpuUsagePercent = cpuUsagePercent
        self.cpuCores = cpuCores
        self.cpuModel = cpuModel
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryCachedBytes = memoryCachedBytes
        self.networkRxBytesPerSec = networkRxBytesPerSec
        self.networkTxBytesPerSec = networkTxBytesPerSec
        self.diskTotalBytes = diskTotalBytes
        self.diskUsedBytes = diskUsedBytes
        self.diskDevice = diskDevice
        self.diskMountPoint = diskMountPoint
        self.diskType = diskType
        self.isSSD = isSSD
        self.disks = disks
        self.loadAvg1m = loadAvg1m
        self.loadAvg5m = loadAvg5m
        self.loadAvg15m = loadAvg15m
        self.uptimeSeconds = uptimeSeconds
        self.topProcesses = topProcesses
    }
}

/// Partition-level disk metric item
public struct DiskPartitionItem: Sendable, Codable, Equatable, Identifiable {
    public var id: String { mountPoint }
    public let filesystem: String
    public let mountPoint: String
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let isSSD: Bool
    public let diskType: String // e.g. "NVMe SSD", "SSD", "HDD"
    
    public var usagePercent: Double {
        guard totalBytes > 0 else { return 0.0 }
        return Double(usedBytes) / Double(totalBytes) * 100.0
    }
    
    public var freeBytes: UInt64 {
        totalBytes > usedBytes ? (totalBytes - usedBytes) : 0
    }
    
    public var badgeText: String {
        if diskType.contains("NVMe") {
            return "NVMe 固态"
        } else if isSSD {
            return "SSD 固态"
        } else {
            return "HDD 机械"
        }
    }
    
    public init(filesystem: String, mountPoint: String, totalBytes: UInt64, usedBytes: UInt64, isSSD: Bool, diskType: String) {
        self.filesystem = filesystem
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.isSSD = isSSD
        self.diskType = diskType
    }
}

/// Process-level resource metric item
public struct ProcessMetricItem: Sendable, Codable, Equatable, Identifiable {
    public var id: Int { pid }
    public let pid: Int
    public let user: String
    public let cpuPercent: Double
    public let memPercent: Double
    public let command: String
    
    public init(pid: Int, user: String, cpuPercent: Double, memPercent: Double, command: String) {
        self.pid = pid
        self.user = user
        self.cpuPercent = cpuPercent
        self.memPercent = memPercent
        self.command = command
    }
}

/// Historical timeseries ring buffer for dynamic Swift Charts rendering
public final class MetricsHistoryStore: @unchecked Sendable {
    private let maxEntries: Int
    private var snapshots: [ServerMetricsSnapshot] = []
    private let lock = NSLock()
    
    public init(maxEntries: Int = 60) {
        self.maxEntries = maxEntries
    }
    
    public func append(_ snapshot: ServerMetricsSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshots.append(snapshot)
        if snapshots.count > maxEntries {
            snapshots.removeFirst(snapshots.count - maxEntries)
        }
    }
    
    public var allSnapshots: [ServerMetricsSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }
    
    public var latest: ServerMetricsSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last
    }
    
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        snapshots.removeAll()
    }
}
