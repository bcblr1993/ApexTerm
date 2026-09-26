import XCTest
import AppKit
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class TerminalFindAndURLTests: XCTestCase {
    
    // MARK: - 1. Terminal Find Tests
    
    @MainActor
    func testTerminalFindExactAndCaseInsensitive() {
        let view = NativeTerminalView()
        let sample = "Error: connection timeout on port 8080.\nRe-trying ERROR handling for 8080.\nSuccess."
        view.textStorage?.setAttributedString(NSAttributedString(string: sample))
        
        // Search "error" (case-insensitive) -> should match 2 occurrences
        let count = view.performFind(query: "error")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(view.currentMatches.count, 2)
        XCTAssertEqual(view.currentMatchIndex, 0)
        
        // First match is at location 0 ("Error")
        XCTAssertEqual(view.currentMatches[0].location, 0)
        XCTAssertEqual(view.currentMatches[0].length, 5)
        
        // Second match is at location 50 ("ERROR")
        XCTAssertEqual(view.currentMatches[1].length, 5)
        
        // Cycle Next -> index becomes 1
        let nextMatch = view.findNext()
        XCTAssertNotNil(nextMatch)
        XCTAssertEqual(view.currentMatchIndex, 1)
        
        // Cycle Next again -> wraps around to 0
        let wrapMatch = view.findNext()
        XCTAssertNotNil(wrapMatch)
        XCTAssertEqual(view.currentMatchIndex, 0)
        
        // Cycle Previous from 0 -> wraps back to 1
        let prevMatch = view.findPrevious()
        XCTAssertNotNil(prevMatch)
        XCTAssertEqual(view.currentMatchIndex, 1)
        
        // Clear search
        view.clearFind()
        XCTAssertEqual(view.currentMatches.count, 0)
        XCTAssertEqual(view.currentMatchIndex, -1)
    }
    
    @MainActor
    func testTerminalFindNonExistentQuery() {
        let view = NativeTerminalView()
        view.textStorage?.setAttributedString(NSAttributedString(string: "All systems operational"))
        
        let count = view.performFind(query: "fatal_crash")
        XCTAssertEqual(count, 0)
        XCTAssertEqual(view.currentMatches.count, 0)
        XCTAssertEqual(view.currentMatchIndex, -1)
        XCTAssertNil(view.findNext())
        XCTAssertNil(view.findPrevious())
    }
    
    // MARK: - 2. URL Detection Tests
    
    func testURLDetectionVariousFormats() {
        let logLine = "Listening on http://localhost:3000 and https://api.apexterm.com/v1/metrics (see http://10.0.1.10:8080/dashboard?token=xyz)."
        let detected = NativeTerminalView.detectURLs(in: logLine)
        
        XCTAssertEqual(detected.count, 3)
        
        // First URL: http://localhost:3000
        XCTAssertEqual(detected[0].url.absoluteString, "http://localhost:3000")
        
        // Second URL: https://api.apexterm.com/v1/metrics
        XCTAssertEqual(detected[1].url.absoluteString, "https://api.apexterm.com/v1/metrics")
        
        // Third URL: should strip trailing parenthesis and period from http://10.0.1.10:8080/dashboard?token=xyz
        XCTAssertEqual(detected[2].url.absoluteString, "http://10.0.1.10:8080/dashboard?token=xyz")
    }
    
    @MainActor
    func testGetSelectedURL() {
        let view = NativeTerminalView()
        let sample = "Visit https://www.aethernative.com for live releases"
        view.textStorage?.setAttributedString(NSAttributedString(string: sample))
        
        // Select "https://www.aethernative.com" (loc: 6, len: 28)
        view.setSelectedRange(NSRange(location: 6, length: 28))
        let url = view.getSelectedURL()
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://www.aethernative.com")
        
        // Select non-URL text
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertNil(view.getSelectedURL())
    }
    
    // MARK: - 3. Top 5 Processes Metric Parsing
    
    func testTopProcessesParsingLinux() {
        let mockOutput = """
        Linux 6.6.0
        ---UPTIME---
        123456
        ---LOAD---
        0.42 0.55 0.60
        ---CPU---
        12.5 4
        ---MEM---
        16000000 8000000 2000000
        ---NET---
        1000000 2000000
        ---DISK---
        100000000 40000000
        ---TOP---
          PID USER      %CPU %MEM COMMAND
         1234 root      45.2  3.1 /usr/bin/dockerd
         5678 www-data  12.0  8.5 nginx: worker process
         9101 ubuntu     5.4  1.2 python3 app.py
         1122 redis      1.1  0.5 redis-server
         3344 node       0.8  4.0 node server.js
        """
        
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil
        let snapshot = monitor.parseLinuxOutput(mockOutput, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertEqual(snapshot.topProcesses.count, 5)
        XCTAssertEqual(snapshot.topProcesses[0].pid, 1234)
        XCTAssertEqual(snapshot.topProcesses[0].user, "root")
        XCTAssertEqual(snapshot.topProcesses[0].cpuPercent, 45.2)
        XCTAssertEqual(snapshot.topProcesses[0].memPercent, 3.1)
        XCTAssertEqual(snapshot.topProcesses[0].command, "/usr/bin/dockerd")
        
        XCTAssertEqual(snapshot.topProcesses[1].pid, 5678)
        XCTAssertEqual(snapshot.topProcesses[1].user, "www-data")
        XCTAssertEqual(snapshot.topProcesses[1].command, "nginx: worker process")
    }
}
