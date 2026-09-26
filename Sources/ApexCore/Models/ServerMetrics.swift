import Foundation

/// Real-time server performance snapshot
public struct ServerMetricsSnapshot: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    
    // CPU
    public var cpuUsagePercent: Double // 0.0 - 100.0
    public var cpuCores: Int
    
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
    
    // Disk root partition
    public var diskTotalBytes: UInt64
    public var diskUsedBytes: UInt64
    
    public var diskUsagePercent: Double {
        guard diskTotalBytes > 0 else { return 0.0 }
        return Double(diskUsedBytes) / Double(diskTotalBytes) * 100.0
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
        memoryTotalBytes: UInt64 = 0,
        memoryUsedBytes: UInt64 = 0,
        memoryCachedBytes: UInt64 = 0,
        networkRxBytesPerSec: Double = 0.0,
        networkTxBytesPerSec: Double = 0.0,
        diskTotalBytes: UInt64 = 0,
        diskUsedBytes: UInt64 = 0,
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
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryCachedBytes = memoryCachedBytes
        self.networkRxBytesPerSec = networkRxBytesPerSec
        self.networkTxBytesPerSec = networkTxBytesPerSec
        self.diskTotalBytes = diskTotalBytes
        self.diskUsedBytes = diskUsedBytes
        self.loadAvg1m = loadAvg1m
        self.loadAvg5m = loadAvg5m
        self.loadAvg15m = loadAvg15m
        self.uptimeSeconds = uptimeSeconds
        self.topProcesses = topProcesses
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
