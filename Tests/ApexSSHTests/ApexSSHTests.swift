import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class ApexSSHTests: XCTestCase {

    func testMockFileEditorRoundTrip() async throws {
        let session = Session(name: "UI Preview", host: "10.0.1.10", username: "root")
        let client = MockSSHSession(session: session)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: result)
        }

        try "updated configuration\n".write(to: source, atomically: true, encoding: .utf8)
        try await client.uploadFile(localURL: source, remotePath: "/root/example.conf", progress: { _ in })
        try await client.downloadFile(remotePath: "/root/example.conf", localURL: result, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "updated configuration\n")
    }
    
    func testAgentlessLinuxMetricsParsing() {
        let sampleLinuxOutput = """
        cpu  1000 200 800 8000 100 50 20 0 0 0
        cpu0 500 100 400 4000 50 25 10 0 0 0
        cpu1 500 100 400 4000 50 25 10 0 0 0
        MemTotal:       16384000 kB
        MemFree:         4096000 kB
        Buffers:          512000 kB
        Cached:          3072000 kB
        eth0: 104857600 50000 0 0 0 0 0 0 52428800 25000 0 0 0 0 0 0
        ---DF---
        /dev/sda1 104857600 26214400 78643200 25% /
        ---UPTIME---
        123456.78 987654.32
        ---LOAD---
        0.45 0.78 1.12 1/450 12345
        """
        
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = AgentlessMonitor.CpuTickState(idle: 7000, total: 8000)
        var prevNet: AgentlessMonitor.NetTickState? = AgentlessMonitor.NetTickState(rx: 100000000, tx: 50000000, timestamp: Date().addingTimeInterval(-1.0))
        
        let snapshot = monitor.parseLinuxOutput(sampleLinuxOutput, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertGreaterThan(snapshot.cpuUsagePercent, 0.0)
        XCTAssertEqual(snapshot.cpuCores, 2)
        XCTAssertEqual(snapshot.memoryTotalBytes, 16384000 * 1024)
        XCTAssertGreaterThan(snapshot.memoryUsedBytes, 0)
        XCTAssertEqual(snapshot.diskTotalBytes, 104857600 * 1024)
        XCTAssertEqual(snapshot.diskUsedBytes, 26214400 * 1024)
        XCTAssertEqual(snapshot.loadAvg1m, 0.45)
        XCTAssertEqual(snapshot.loadAvg5m, 0.78)
        XCTAssertEqual(snapshot.loadAvg15m, 1.12)
        XCTAssertEqual(snapshot.uptimeSeconds, 123456)
    }
    
    func testAgentlessMacOSMetricsParsing() {
        let sampleMacOSOutput = """
        CPU usage: 7.82% user, 11.38% sys, 80.78% idle 
        PhysMem: 15G used (1740M wired, 2732M compressor), 182M unused.
        ---CORES---
        8
        ---DF---
        /dev/disk3s3s1   239362496  13334368  78350232    15%  484014 783502320    0%   /
        ---UPTIME---
         6:51  up 6 days, 22:50, 3 users, load averages: 1.16 1.13 1.15
        ---NET---
        en0 1500 <Link#6> 14:98:77:5a:b4:d5 48176988 0 46142541246 20691726 0 5206320117 0
        """
        
        let monitor = AgentlessMonitor()
        var prevNet: AgentlessMonitor.NetTickState? = AgentlessMonitor.NetTickState(rx: 46100000000, tx: 5200000000, timestamp: Date().addingTimeInterval(-1.0))
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        
        let snapshot = monitor.parseOutput(sampleMacOSOutput, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertEqual(snapshot.cpuUsagePercent, 19.22, accuracy: 0.1)
        XCTAssertEqual(snapshot.cpuCores, 8)
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.memoryUsedBytes, 0)
        XCTAssertEqual(snapshot.diskTotalBytes, 239362496 * 1024)
        XCTAssertEqual(snapshot.diskUsedBytes, 13334368 * 1024)
        XCTAssertEqual(snapshot.loadAvg1m, 1.16)
        XCTAssertEqual(snapshot.loadAvg5m, 1.13)
        XCTAssertEqual(snapshot.loadAvg15m, 1.15)
        XCTAssertEqual(snapshot.uptimeSeconds, 6 * 86400)
    }
    
    func testVTParserANSISequence() {
        let parser = VTParser()
        let raw = "\u{001B}[1;31mERROR\u{001B}[0m: Database connection failed at \u{001B}[32m10.0.1.10\u{001B}[0m"
        let spans = parser.parseANSI(raw)
        
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].text, "ERROR")
        XCTAssertEqual(spans[0].foregroundColorHex, "#FF453A")
        XCTAssertTrue(spans[0].isBold)
        
        XCTAssertEqual(spans[1].text, ": Database connection failed at ")
        XCTAssertNil(spans[1].foregroundColorHex)
        XCTAssertFalse(spans[1].isBold)
        
        XCTAssertEqual(spans[2].text, "10.0.1.10")
        XCTAssertEqual(spans[2].foregroundColorHex, "#30D158")
    }
    
    func testKeywordHighlighter() {
        let trigger = Trigger(
            name: "Error",
            regexPattern: "(?i)error",
            action: .highlight(colorHex: "#FF0000")
        )
        let highlighter = KeywordHighlighter(triggers: [trigger])
        let text = "Critical Error occurred during boot"
        let matches = highlighter.findMatches(in: text)
        
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].colorHex, "#FF0000")
    }
    
    func testTerminalRingBufferWrapping() {
        let ringBuffer = TerminalRingBuffer(maxLines: 4)
        ringBuffer.appendLine("line 1")
        ringBuffer.appendLine("line 2")
        ringBuffer.appendLine("line 3")
        ringBuffer.appendLine("line 4")
        ringBuffer.appendLine("line 5") // wraps, overwrites line 1
        
        XCTAssertEqual(ringBuffer.lineCount, 4)
        let lines = ringBuffer.allLines()
        XCTAssertEqual(lines, ["line 2", "line 3", "line 4", "line 5"])
    }
    
    func testIncrementalRingBufferSlicing() {
        let ringBuffer = TerminalRingBuffer(maxLines: 100)
        ringBuffer.appendLines(["A", "B", "C", "D", "E"])
        
        // Slicing from index 2 to fetch 3 lines
        let slice = ringBuffer.lines(from: 2, count: 3)
        XCTAssertEqual(slice, ["C", "D", "E"])
        
        let sliceOver = ringBuffer.lines(from: 4, count: 10)
        XCTAssertEqual(sliceOver, ["E"])
        
        let emptySlice = ringBuffer.lines(from: 5, count: 2)
        XCTAssertEqual(emptySlice, [])
    }
    
    func testChineseVTParserParsing() {
        let parser = VTParser()
        let raw = "\u{001B}[32m[成功]\u{001B}[0m 远程服务器连接正常，欢迎使用 ApexTerm 纯原生终端！"
        let spans = parser.parseANSI(raw)
        
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].text, "[成功]")
        XCTAssertEqual(spans[0].foregroundColorHex, "#30D158")
        XCTAssertEqual(spans[1].text, " 远程服务器连接正常，欢迎使用 ApexTerm 纯原生终端！")
    }
    
    func testTerminalStreamLineBufferingAndEditing() {
        let ringBuffer = TerminalRingBuffer(maxLines: 100)
        
        // 1. Initial banner with CRLF and prompt without newline
        ringBuffer.appendStream("Welcome to Ubuntu 24.04\r\n")
        ringBuffer.appendStream("ubuntu@server:~$ ")
        
        XCTAssertEqual(ringBuffer.committedLineCount, 1)
        XCTAssertEqual(ringBuffer.currentActiveLine, "ubuntu@server:~$ ")
        
        // 2. Typing characters in stream: 'c', 'l', 'e', 'a', 'r'
        ringBuffer.appendStream("c")
        XCTAssertEqual(ringBuffer.currentActiveLine, "ubuntu@server:~$ c")
        ringBuffer.appendStream("l")
        XCTAssertEqual(ringBuffer.currentActiveLine, "ubuntu@server:~$ cl")
        ringBuffer.appendStream("e")
        ringBuffer.appendStream("a")
        ringBuffer.appendStream("r")
        XCTAssertEqual(ringBuffer.currentActiveLine, "ubuntu@server:~$ clear")
        
        // 3. Backspace deletes character from active line
        ringBuffer.appendStream("\u{08} \u{08}")
        XCTAssertEqual(ringBuffer.currentActiveLine, "ubuntu@server:~$ clea")
        
        // 4. Return commits the line
        ringBuffer.appendStream("\r\n")
        XCTAssertEqual(ringBuffer.committedLineCount, 2)
        XCTAssertEqual(ringBuffer.lines(from: 0, count: 2), ["Welcome to Ubuntu 24.04", "ubuntu@server:~$ clea"])
        XCTAssertEqual(ringBuffer.currentActiveLine, "")
        
        // 5. Clear screen ANSI sequence wipes history and active line
        ringBuffer.appendStream("\u{001B}[H\u{001B}[2Jubuntu@server:~$ ")
        XCTAssertEqual(ringBuffer.committedLineCount, 0)
        XCTAssertEqual(ringBuffer.currentActiveLine, "ubuntu@server:~$ ")
    }
    
    func testDiskAndHardwareTypeDetectionLinuxNVMe() {
        let sampleLinux = """
        cpu  1000 200 800 8000 100 50 20 0 0 0
        cpu0 500 100 400 4000 50 25 10 0 0 0
        MemTotal:       16384000 kB
        MemFree:         4096000 kB
        ---DF---
        /dev/nvme0n1p2 104857600 26214400 78643200 25% /
        ---UPTIME---
        123456.78 987654.32
        ---LOAD---
        0.45 0.78 1.12
        ---TOP---
        1234 root 2.5 1.0 nginx
        ---CPUMODEL---
        Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz
        ---DISKTYPE---
        NVMe SSD
        """
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = AgentlessMonitor.CpuTickState(idle: 7000, total: 8000)
        var prevNet: AgentlessMonitor.NetTickState? = nil
        let snapshot = monitor.parseLinuxOutput(sampleLinux, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertEqual(snapshot.cpuModel, "Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz")
        XCTAssertEqual(snapshot.diskDevice, "/dev/nvme0n1p2")
        XCTAssertEqual(snapshot.diskMountPoint, "/")
        XCTAssertEqual(snapshot.diskType, "NVMe SSD")
        XCTAssertTrue(snapshot.isSSD)
        XCTAssertEqual(snapshot.diskBadgeText, "NVMe 固态")
        XCTAssertEqual(snapshot.disks.count, 1)
        XCTAssertEqual(snapshot.disks[0].badgeText, "NVMe 固态")
        XCTAssertEqual(snapshot.disks[0].filesystem, "/dev/nvme0n1p2")
        XCTAssertEqual(snapshot.diskFreeBytes, 78643200 * 1024)
    }

    func testDiskAndHardwareTypeDetectionLinuxHDD() {
        let sampleLinux = """
        cpu  1000 200 800 8000 100 50 20 0 0 0
        MemTotal:       32768000 kB
        MemFree:        16384000 kB
        ---DF---
        /dev/sdb1 500000000 200000000 300000000 40% /data
        ---UPTIME---
        50000.00
        ---LOAD---
        1.0 1.0 1.0
        ---CPUMODEL---
        AMD EPYC 7742 64-Core Processor
        ---DISKTYPE---
        HDD
        """
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil
        let snapshot = monitor.parseLinuxOutput(sampleLinux, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertEqual(snapshot.cpuModel, "AMD EPYC 7742 64-Core Processor")
        XCTAssertEqual(snapshot.diskDevice, "/dev/sdb1")
        XCTAssertEqual(snapshot.diskMountPoint, "/data")
        XCTAssertEqual(snapshot.diskType, "HDD")
        XCTAssertFalse(snapshot.isSSD)
        XCTAssertEqual(snapshot.diskBadgeText, "HDD 机械")
        XCTAssertEqual(snapshot.disks.first?.badgeText, "HDD 机械")
    }

    func testDiskAndHardwareTypeDetectionMacOS() {
        let sampleMacOS = """
        CPU usage: 5.0% user, 5.0% sys, 90.0% idle
        PhysMem: 16G used, 16G unused.
        ---CORES---
        12
        ---DF---
        /dev/disk3s1s1 480000000 120000000 360000000 25% /
        ---UPTIME---
        12:00 up 2 days, 1 user, load averages: 1.0 1.0 1.0
        ---CPUMODEL---
        Apple M3 Max
        ---DISKTYPE---
        NVMe SSD
        """
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil
        let snapshot = monitor.parseOutput(sampleMacOS, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertEqual(snapshot.cpuModel, "Apple M3 Max")
        XCTAssertEqual(snapshot.diskDevice, "/dev/disk3s1s1")
        XCTAssertEqual(snapshot.diskType, "NVMe SSD")
        XCTAssertTrue(snapshot.isSSD)
        XCTAssertEqual(snapshot.diskBadgeText, "NVMe 固态")
    }
}
