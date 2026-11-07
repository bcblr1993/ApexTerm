import XCTest
@testable import ApexCore
@testable import ApexTerminal

final class ShellIntegrationTests: XCTestCase {

    /// TC-SHELL-01: OSC 133 A/B parsing with BEL (\u{07}) and ST (\e\\) terminators without leaking text or triggering bell
    func testOSC133PromptAndCommandMarkersWithBELAndST() {
        let ring = TerminalRingBuffer(maxLines: 500)
        // Line 0: prompt with BEL terminator
        ring.appendStream("\u{1B}]133;A\u{07}root@prod:~# \u{1B}]133;B\u{07}uptime\r\n")
        // Line 1: output
        ring.appendStream(" 00:30:00 up 42 days\r\n")
        // Line 2: finish + next prompt with ST (\e\\) terminator
        ring.appendStream("\u{1B}]133;D;0\u{1B}\\\u{1B}]133;A\u{1B}\\root@prod:~# \u{1B}]133;B\u{1B}\\")

        XCTAssertFalse(ring.consumeBellFlag(), "OSC 133 BEL terminator must not trigger terminal audible bell")
        let lines = ring.allLines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "root@prod:~# uptime")
        XCTAssertEqual(lines[1], " 00:30:00 up 42 days")
        XCTAssertEqual(lines[2], "root@prod:~# ")
        XCTAssertEqual(ring.shellIntegration.allPromptLines(), [0, 2])
    }

    /// TC-SHELL-02: OSC 133 C & D;0 full lifecycle, command text extraction, and duration calculation
    func testOSC133CommandLifecycleAndDurationCalculation() {
        let tracker = ShellIntegrationTracker()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000.0)
        let t1 = t0.addingTimeInterval(0.425) // 425 ms later

        tracker.handleOSCPayload("133;A", currentLineIndex: 0, activeLineText: "", timestamp: t0)
        tracker.handleOSCPayload("133;B", currentLineIndex: 0, activeLineText: "ubuntu@node1:~$ ", timestamp: t0)
        tracker.handleOSCPayload("133;C", currentLineIndex: 0, activeLineText: "ubuntu@node1:~$ kubectl get nodes", timestamp: t0)
        tracker.handleOSCPayload("133;D;0", currentLineIndex: 4, activeLineText: "", timestamp: t1)

        let records = tracker.allRecords()
        XCTAssertEqual(records.count, 1)
        let rec = records[0]
        XCTAssertEqual(rec.commandText, "kubectl get nodes")
        XCTAssertEqual(rec.promptStartLine, 0)
        XCTAssertEqual(rec.outputStartLine, 1)
        XCTAssertEqual(rec.outputEndLine, 4)
        XCTAssertEqual(rec.exitCode, 0)
        XCTAssertTrue(rec.isSuccess)
        XCTAssertFalse(rec.isFailed)
        XCTAssertEqual(rec.durationMs, 425)
        XCTAssertEqual(rec.formattedDuration, "425ms")
    }

    /// TC-SHELL-03: Non-zero exit code tracking (127, 1) and failedRecords() filter
    func testNonZeroExitCodeTrackingAndFailedFilter() {
        let tracker = ShellIntegrationTracker()
        let base = Date(timeIntervalSince1970: 1_700_000_100.0)

        // Command 1: success (0)
        tracker.handleOSCPayload("133;A", currentLineIndex: 0, timestamp: base)
        tracker.handleOSCPayload("133;C;echo ok", currentLineIndex: 0, timestamp: base)
        tracker.handleOSCPayload("133;D;0", currentLineIndex: 1, timestamp: base.addingTimeInterval(0.05))

        // Command 2: failed (127 command not found)
        tracker.handleOSCPayload("133;A", currentLineIndex: 2, timestamp: base)
        tracker.handleOSCPayload("133;C;nonexistent_bin --version", currentLineIndex: 2, timestamp: base)
        tracker.handleOSCPayload("133;D;127", currentLineIndex: 3, timestamp: base.addingTimeInterval(0.02))

        // Command 3: failed (1)
        tracker.handleOSCPayload("133;A", currentLineIndex: 4, timestamp: base)
        tracker.handleOSCPayload("133;C;grep -q missing /etc/hosts", currentLineIndex: 4, timestamp: base)
        tracker.handleOSCPayload("133;D;1", currentLineIndex: 5, timestamp: base.addingTimeInterval(0.01))

        XCTAssertEqual(tracker.allRecords().count, 3)
        let failed = tracker.failedRecords()
        XCTAssertEqual(failed.count, 2)
        XCTAssertEqual(failed[0].commandText, "nonexistent_bin --version")
        XCTAssertEqual(failed[0].exitCode, 127)
        XCTAssertEqual(failed[1].commandText, "grep -q missing /etc/hosts")
        XCTAssertEqual(failed[1].exitCode, 1)
        XCTAssertEqual(tracker.lastCompletedRecord?.exitCode, 1)
    }

    /// TC-SHELL-04: Prompt bookmark navigation (previousPromptLine / nextPromptLine)
    func testPromptBookmarkNavigation() {
        let tracker = ShellIntegrationTracker()
        for line in [0, 5, 14, 28, 40] {
            tracker.handleOSCPayload("133;A", currentLineIndex: line)
        }

        XCTAssertEqual(tracker.previousPromptLine(before: 40), 28)
        XCTAssertEqual(tracker.previousPromptLine(before: 30), 28)
        XCTAssertEqual(tracker.previousPromptLine(before: 14), 5)
        XCTAssertEqual(tracker.previousPromptLine(before: 0), nil)

        XCTAssertEqual(tracker.nextPromptLine(after: 0), 5)
        XCTAssertEqual(tracker.nextPromptLine(after: 6), 14)
        XCTAssertEqual(tracker.nextPromptLine(after: 28), 40)
        XCTAssertEqual(tracker.nextPromptLine(after: 40), nil)
    }

    /// TC-SHELL-05: Exact command output extraction via OSC 133 boundaries in TerminalRingBuffer
    func testExactCommandOutputExtractionFromRingBuffer() {
        let ring = TerminalRingBuffer(maxLines: 500)
        ring.appendStream("\u{1B}]133;A\u{07}user@host:~$ \u{1B}]133;B\u{07}cat /etc/hostname\u{1B}]133;C\u{07}\r\n")
        ring.appendStream("\u{1B}[32mapex-prod-db-01\u{1B}[0m\r\n")
        ring.appendStream("region=ap-east-1\r\n")
        ring.appendStream("\u{1B}]133;D;0\u{07}\u{1B}]133;A\u{07}user@host:~$ ")

        let output = ring.extractLastOSC133CommandOutput()
        XCTAssertEqual(output, "apex-prod-db-01\nregion=ap-east-1")
        XCTAssertEqual(ring.shellIntegration.lastCompletedRecord?.commandText, "cat /etc/hostname")
    }

    /// TC-SHELL-06: Bounded history cap (maxRecords) FIFO eviction
    func testBoundedHistoryCapFIFOEviction() {
        let tracker = ShellIntegrationTracker(maxRecords: 3)
        for idx in 0..<6 {
            let line = idx * 3
            tracker.handleOSCPayload("133;A", currentLineIndex: line)
            tracker.handleOSCPayload("133;C;cmd-\(idx)", currentLineIndex: line)
            tracker.handleOSCPayload("133;D;0", currentLineIndex: line + 1)
        }

        let records = tracker.allRecords()
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map { $0.commandText ?? "" }, ["cmd-3", "cmd-4", "cmd-5"])
        XCTAssertEqual(tracker.allPromptLines(), [9, 12, 15])
    }

    /// TC-SHELL-07: OSC 7 & OSC 1337 working directory tracking and attachment to records
    func testOSC7AndOSC1337WorkingDirectoryTracking() {
        let tracker = ShellIntegrationTracker()
        tracker.handleOSCPayload("7;file://prod-server/var/log/nginx%20logs", currentLineIndex: 0)
        XCTAssertEqual(tracker.workingDirectory, "/var/log/nginx logs")

        tracker.handleOSCPayload("133;A", currentLineIndex: 1)
        tracker.handleOSCPayload("133;C;ls -la", currentLineIndex: 1)
        tracker.handleOSCPayload("133;D;0", currentLineIndex: 3)
        XCTAssertEqual(tracker.lastCompletedRecord?.workingDirectory, "/var/log/nginx logs")

        tracker.handleOSCPayload("1337;CurrentDir=/srv/docker/compose", currentLineIndex: 4)
        XCTAssertEqual(tracker.workingDirectory, "/srv/docker/compose")
    }

    /// TC-SHELL-08: Human-readable duration formatting and ringBuffer.clear() state reset
    func testFormattedDurationAndRingBufferClearReset() {
        let fast = CommandExecutionRecord(promptStartLine: 0, commandStartLine: 0, outputStartLine: 1, durationMs: 85, exitCode: 0)
        let medium = CommandExecutionRecord(promptStartLine: 0, commandStartLine: 0, outputStartLine: 1, durationMs: 2_350, exitCode: 0)
        let slow = CommandExecutionRecord(promptStartLine: 0, commandStartLine: 0, outputStartLine: 1, durationMs: 135_000, exitCode: 0)

        XCTAssertEqual(fast.formattedDuration, "85ms")
        XCTAssertEqual(medium.formattedDuration, "2.35s")
        XCTAssertEqual(slow.formattedDuration, "2m 15s")

        let ring = TerminalRingBuffer(maxLines: 100)
        ring.appendStream("\u{1B}]133;A\u{07}$ \u{1B}]133;C;whoami\u{07}\r\nroot\r\n\u{1B}]133;D;0\u{07}")
        XCTAssertEqual(ring.shellIntegration.allRecords().count, 1)

        ring.clear()
        XCTAssertTrue(ring.shellIntegration.allRecords().isEmpty)
        XCTAssertTrue(ring.shellIntegration.allPromptLines().isEmpty)
    }
}
