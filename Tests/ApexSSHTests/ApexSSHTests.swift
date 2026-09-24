import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class ApexSSHTests: XCTestCase {
    
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
}
