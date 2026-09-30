import XCTest
@testable import ApexCore
@testable import ApexSSH

final class AgentlessHeterogeneousDistroTests: XCTestCase {
    private let monitor = AgentlessMonitor()

    func testAlpineBusyBoxProcAndTopParsing() {
        // Alpine Linux / BusyBox proc output where MemAvailable is missing in older kernels
        let alpineStdout = """
        cpu  10132 0 2156 182390 102 0 10 0
        cpu0 5000 0 1000 91000 50 0 5 0
        cpu1 5132 0 1156 91390 52 0 5 0
        MemTotal:        4048560 kB
        MemFree:         1200000 kB
        Buffers:          150000 kB
        Cached:           800000 kB
        eth0: 10485760 100 0 0 0 0 0 0 5242880 80 0 0 0 0 0 0
        ---DF---
        /dev/vda1 20971520 8388608 12582912 40% /
        ---UPTIME---
        123456.78 246913.56
        ---LOAD---
        0.15 0.25 0.30
        ---TOP---
        PID USER %CPU %MEM COMMAND
        1 root 0.1 0.2 /sbin/init
        123 nginx 1.5 2.0 nginx: worker
        456 redis 0.8 4.2 redis-server
        ---CPUMODEL---
        Intel Xeon Platinum
        ---DISKTYPE---
        SSD
        """

        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil

        let snapshot = monitor.parseLinuxOutput(alpineStdout, prevCpu: &prevCpu, prevNet: &prevNet)

        XCTAssertEqual(snapshot.cpuCores, 2)
        XCTAssertEqual(snapshot.cpuModel, "Intel Xeon Platinum")
        XCTAssertEqual(snapshot.uptimeSeconds, 123456)
        XCTAssertEqual(snapshot.loadAvg1m, 0.15)
        XCTAssertEqual(snapshot.loadAvg5m, 0.25)
        XCTAssertEqual(snapshot.loadAvg15m, 0.30)
        XCTAssertEqual(snapshot.isSSD, true)
        XCTAssertEqual(snapshot.diskType, "SSD")

        // In fallback when MemAvailable is missing: MemTotal - (MemFree + Buffers + Cached)
        // 4048560 - (1200000 + 150000 + 800000) = 1898560 kB = 1898560 * 1024 bytes
        let expectedUsed = UInt64(1898560) * 1024
        XCTAssertEqual(snapshot.memoryUsedBytes, expectedUsed)
        XCTAssertEqual(snapshot.memoryTotalBytes, UInt64(4048560) * 1024)

        // Top processes
        XCTAssertEqual(snapshot.topProcesses.count, 3)
        XCTAssertEqual(snapshot.topProcesses.first?.command, "/sbin/init")
        XCTAssertEqual(snapshot.topProcesses.first?.pid, 1)
    }

    func testHighCoreCountLinuxParsing() {
        // Construct 64-core proc/stat
        var statLines = ["cpu  250000 5000 120000 15000000 2000 0 500 0"]
        for core in 0..<64 {
            statLines.append("cpu\(core) 3900 78 1875 234375 31 0 7 0")
        }
        statLines.append("MemTotal:        264144000 kB")
        statLines.append("MemAvailable:    180000000 kB")
        statLines.append("---DF---")
        statLines.append("/dev/nvme0n1p2 960000000 320000000 640000000 33% /")
        statLines.append("---UPTIME---")
        statLines.append("9876543.21 632098765.43")
        statLines.append("---LOAD---")
        statLines.append("4.50 8.20 12.00")
        statLines.append("---CPUMODEL---")
        statLines.append("AMD EPYC 7763 64-Core Processor")
        statLines.append("---DISKTYPE---")
        statLines.append("NVMe SSD")

        let raw = statLines.joined(separator: "\n")
        var prevCpu: AgentlessMonitor.CpuTickState? = AgentlessMonitor.CpuTickState(idle: 14800000, total: 15000000)
        var prevNet: AgentlessMonitor.NetTickState? = nil

        let snapshot = monitor.parseLinuxOutput(raw, prevCpu: &prevCpu, prevNet: &prevNet)

        XCTAssertEqual(snapshot.cpuCores, 64)
        XCTAssertEqual(snapshot.cpuModel, "AMD EPYC 7763 64-Core Processor")
        XCTAssertEqual(snapshot.isSSD, true)
        XCTAssertEqual(snapshot.diskType, "NVMe SSD")
        XCTAssertTrue(snapshot.cpuUsagePercent > 0.0 && snapshot.cpuUsagePercent <= 100.0)
        XCTAssertEqual(snapshot.loadAvg1m, 4.50)
        XCTAssertEqual(snapshot.loadAvg15m, 12.00)
    }

    func testContainerCGroupLimitsAndOverlayFilesystem() {
        let containerStdout = """
        cpu  12000 0 3000 50000 0 0 0 0
        cpu0 6000 0 1500 25000 0 0 0 0
        cpu1 6000 0 1500 25000 0 0 0 0
        MemTotal:        8192000 kB
        MemAvailable:    4096000 kB
        eth0: 2048000 50 0 0 0 0 0 0 1024000 30 0 0 0 0 0 0
        ---DF---
        overlay 104857600 41943040 62914560 40% /
        ---UPTIME---
        3600.00 7200.00
        ---LOAD---
        1.05 1.10 0.95
        ---TOP---
        PID USER %CPU %MEM COMMAND
        1 root 5.0 1.2 node index.js
        ---CPUMODEL---
        Container (cgroup v2)
        ---DISKTYPE---
        SSD
        """

        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil

        let snapshot = monitor.parseLinuxOutput(containerStdout, prevCpu: &prevCpu, prevNet: &prevNet)

        XCTAssertEqual(snapshot.cpuCores, 2)
        XCTAssertEqual(snapshot.cpuModel, "Container (cgroup v2)")
        XCTAssertEqual(snapshot.disks.first?.filesystem, "overlay")
        XCTAssertEqual(snapshot.disks.first?.mountPoint, "/")
        XCTAssertEqual(snapshot.uptimeSeconds, 3600)
        XCTAssertEqual(snapshot.topProcesses.count, 1)
        XCTAssertEqual(snapshot.topProcesses.first?.command, "node index.js")
    }

    func testHeterogeneousDiskFilesystemsAndRotationalCheck() {
        let filesystems = [
            ("/dev/sdb1 500000000 250000000 250000000 50% /data", "HDD", false),
            ("/dev/nvme1n1p1 1000000000 100000000 900000000 10% /fast", "NVMe SSD", true),
            ("tank/dataset 2000000000 500000000 1500000000 25% /zfs", "SSD", true)
        ]

        for (dfLine, expectedType, expectedIsSSD) in filesystems {
            let output = """
            cpu 100 0 50 1000 0 0 0 0
            MemTotal: 1000000 kB
            MemAvailable: 500000 kB
            ---DF---
            \(dfLine)
            ---UPTIME---
            500.0
            ---LOAD---
            0.1 0.1 0.1
            ---CPUMODEL---
            Server
            ---DISKTYPE---
            \(expectedType)
            """

            var prevCpu: AgentlessMonitor.CpuTickState? = nil
            var prevNet: AgentlessMonitor.NetTickState? = nil

            let snapshot = monitor.parseLinuxOutput(output, prevCpu: &prevCpu, prevNet: &prevNet)
            XCTAssertEqual(snapshot.diskType, expectedType)
            XCTAssertEqual(snapshot.isSSD, expectedIsSSD)
        }
    }
}
