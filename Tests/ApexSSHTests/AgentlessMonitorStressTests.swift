import XCTest
@testable import ApexCore
@testable import ApexSSH

final class AgentlessMonitorStressTests: XCTestCase {
    
    /// Test 1: 64-core enterprise Linux cluster with MemAvailable and bond0 network
    func testEnterpriseLinuxClusterParsing() {
        var lines: [String] = []
        // Aggregated cpu line
        lines.append("cpu  50000 2000 40000 900000 1000 500 200 0 0 0")
        // 64 individual cpu lines: cpu0 ... cpu63
        for c in 0..<64 {
            lines.append("cpu\(c) 800 30 600 14000 15 8 3 0 0 0")
        }
        lines.append("MemTotal:      264144000 kB") // ~256 GB
        lines.append("MemFree:        32000000 kB")
        lines.append("MemAvailable:  180000000 kB") // Modern Linux MemAvailable
        lines.append("Buffers:         2000000 kB")
        lines.append("Cached:         50000000 kB")
        // Enterprise bonded interface bond0 and eno1
        lines.append("bond0: 5000000000 3500000 0 0 0 0 0 0 2500000000 1800000 0 0 0 0 0 0")
        lines.append("eno1:  5000000000 3500000 0 0 0 0 0 0 2500000000 1800000 0 0 0 0 0 0")
        lines.append("---DF---")
        lines.append("/dev/nvme0n1p2 1953525168 586057550 1367467618 30% /")
        lines.append("---UPTIME---")
        lines.append("2592000.50 165888000.00") // 30 days
        lines.append("---LOAD---")
        lines.append("12.45 8.32 4.10 4/1250 89234")
        
        let sample = lines.joined(separator: "\n")
        let monitor = AgentlessMonitor()
        
        var prevCpu: AgentlessMonitor.CpuTickState? = AgentlessMonitor.CpuTickState(idle: 850000, total: 900000)
        var prevNet: AgentlessMonitor.NetTickState? = AgentlessMonitor.NetTickState(
            rx: 9000000000,
            tx: 4000000000,
            timestamp: Date().addingTimeInterval(-1.0)
        )
        
        let snapshot = monitor.parseLinuxOutput(sample, prevCpu: &prevCpu, prevNet: &prevNet)
        
        // Assertions
        XCTAssertEqual(snapshot.cpuCores, 64, "Should correctly detect 64 CPU cores")
        XCTAssertGreaterThan(snapshot.cpuUsagePercent, 0)
        XCTAssertLessThanOrEqual(snapshot.cpuUsagePercent, 100)
        
        // MemAvailable based usage: 264144000 - 180000000 = 84144000 kB
        let expectedMemUsed = UInt64(264144000 - 180000000) * 1024
        XCTAssertEqual(snapshot.memoryUsedBytes, expectedMemUsed)
        XCTAssertEqual(snapshot.memoryTotalBytes, UInt64(264144000) * 1024)
        
        // Network rates: 10GB total rx vs 9GB prev = 1GB/s
        XCTAssertGreaterThan(snapshot.networkRxBytesPerSec, 900_000_000)
        
        // 2TB NVMe Disk
        XCTAssertEqual(snapshot.diskTotalBytes, 1953525168 * 1024)
        XCTAssertEqual(snapshot.diskUsedBytes, 586057550 * 1024)
        
        // Load & Uptime
        XCTAssertEqual(snapshot.loadAvg1m, 12.45)
        XCTAssertEqual(snapshot.loadAvg5m, 8.32)
        XCTAssertEqual(snapshot.loadAvg15m, 4.10)
        XCTAssertEqual(snapshot.uptimeSeconds, 2592000)
    }
    
    /// Test 2: Malformed, truncated, or empty input resilience
    func testMalformedLinuxOutputResilience() {
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil
        
        // Empty output
        let emptySnapshot = monitor.parseLinuxOutput("", prevCpu: &prevCpu, prevNet: &prevNet)
        XCTAssertEqual(emptySnapshot.cpuCores, 1)
        XCTAssertEqual(emptySnapshot.cpuUsagePercent, 0)
        
        // Truncated garbage output
        let garbage = "Kernel panic - not syncing: Fatal exception\nSome corrupted binary data \u{0000}\u{0001}"
        let garbageSnapshot = monitor.parseLinuxOutput(garbage, prevCpu: &prevCpu, prevNet: &prevNet)
        XCTAssertEqual(garbageSnapshot.cpuCores, 1)
        XCTAssertEqual(garbageSnapshot.memoryTotalBytes, 0)
    }
    
    /// Test 3: macOS top output format variations
    func testMacOSTopVariations() {
        let monitor = AgentlessMonitor()
        var prevNet: AgentlessMonitor.NetTickState? = nil
        
        let macOutput = """
        CPU usage: 15.4% user, 22.1% sys, 62.5% idle
        PhysMem: 24G used (3100M wired, 4200M compressor), 8192M unused.
        ---CORES---
        12
        ---DF---
        /dev/disk1s1s1 494384128 35000000 450000000 8% /
        ---UPTIME---
        12:30 up 14 days, 3:15, 2 users, load averages: 2.10 1.85 1.50
        ---NET---
        en0 1500 <Link#6> 10000000 0 8500000000 8000000 0 4500000000 0
        """
        
        let snapshot = monitor.parseMacOSOutput(macOutput, prevNet: &prevNet)
        
        XCTAssertEqual(snapshot.cpuUsagePercent, 37.5, accuracy: 0.5)
        XCTAssertEqual(snapshot.cpuCores, 12)
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0)
        XCTAssertEqual(snapshot.diskTotalBytes, 494384128 * 1024)
        XCTAssertEqual(snapshot.diskUsedBytes, 35000000 * 1024)
        XCTAssertEqual(snapshot.uptimeSeconds, 14 * 86400)
    }
}
