import XCTest
import os
@testable import ApexSSH
@testable import ApexCore
@testable import ApexUI

@MainActor
final class BatchOperationsTests: XCTestCase {

    private func makeSessions(count: Int, folder: String = "Prod") -> [Session] {
        (1...count).map { idx in
            Session(
                name: "node-\(idx)",
                host: "10.0.1.\(idx)",
                port: 22,
                username: "ops",
                authMethod: .agent,
                folder: folder
            )
        }
    }

    // MARK: - TC-V29-06: Bounded Concurrency Respected
    func testTC_V29_06_BoundedConcurrencyRespected() async {
        let sessions = makeSessions(count: 8)
        let activeCount = OSAllocatedUnfairLock(initialState: 0)
        let peakActiveCount = OSAllocatedUnfairLock(initialState: 0)

        let manager = BatchOperationsManager(maxConcurrency: 3) { session in
            let mock = MockSSHSession(session: session)
            mock.customExecuteCommandResultHandler = { _ in
                let now = activeCount.withLock { count -> Int in
                    count += 1
                    return count
                }
                peakActiveCount.withLock { peak in
                    if now > peak { peak = now }
                }
                try await Task.sleep(nanoseconds: 60_000_000)
                activeCount.withLock { $0 -= 1 }
                return SSHCommandResult(stdout: "ok \(session.name)", stderr: "", exitCode: 0, durationMs: 60)
            }
            return mock
        }

        await manager.executeBatchCommand("uptime", on: sessions)

        let peak = peakActiveCount.withLock { $0 }
        XCTAssertLessThanOrEqual(peak, 3, "Peak concurrent executions must never exceed maxConcurrency (3)")
        XCTAssertGreaterThanOrEqual(peak, 2, "Tasks should execute concurrently up to bound")
        XCTAssertEqual(manager.succeededCount, 8)
        XCTAssertEqual(manager.failedCount, 0)
        XCTAssertFalse(manager.isRunning)

        manager.maxConcurrency = 0
        XCTAssertEqual(manager.maxConcurrency, 1)
        manager.maxConcurrency = 99
        XCTAssertEqual(manager.maxConcurrency, 16)
    }

    // MARK: - TC-V29-07: Partial Host Failure / Non-Zero Exit Code Isolated
    func testTC_V29_07_PartialFailureAndNonZeroExitCodeIsolation() async {
        let sessions = makeSessions(count: 3)
        let s1 = sessions[0]
        let s2 = sessions[1]
        let s3 = sessions[2]

        let manager = BatchOperationsManager(maxConcurrency: 4) { session in
            let mock = MockSSHSession(session: session)
            mock.customExecuteCommandResultHandler = { _ in
                if session.id == s1.id {
                    return SSHCommandResult(stdout: "healthy-output\n", stderr: "", exitCode: 0, durationMs: 12.5)
                } else if session.id == s2.id {
                    return SSHCommandResult(stdout: "partial-out", stderr: "permission denied", exitCode: 2, durationMs: 18.0)
                } else {
                    throw NSError(domain: "TestSSH", code: 255, userInfo: [NSLocalizedDescriptionKey: "Connection timed out"])
                }
            }
            return mock
        }

        await manager.executeBatchCommand("systemctl status nginx", on: sessions)

        let r1 = manager.results.first(where: { $0.sessionID == s1.id })
        let r2 = manager.results.first(where: { $0.sessionID == s2.id })
        let r3 = manager.results.first(where: { $0.sessionID == s3.id })

        XCTAssertEqual(r1?.status, .succeeded)
        XCTAssertEqual(r1?.exitCode, 0)
        XCTAssertEqual(r1?.stdout, "healthy-output\n")
        XCTAssertEqual(r1?.stderr, "")

        XCTAssertEqual(r2?.status.isFailed, true)
        XCTAssertEqual(r2?.exitCode, 2)
        XCTAssertEqual(r2?.stdout, "partial-out")
        XCTAssertEqual(r2?.stderr, "permission denied")

        XCTAssertEqual(r3?.status.isFailed, true)
        XCTAssertNil(r3?.exitCode)
        XCTAssertTrue(r3?.stderr.contains("Connection timed out") == true)
        XCTAssertEqual(manager.succeededCount, 1)
        XCTAssertEqual(manager.failedCount, 2)
    }

    // MARK: - TC-V29-08: Cancellation Marks Remaining / In-Flight Cancelled Cleanly
    func testTC_V29_08_CancellationMarksRemainingCancelled() async {
        let sessions = makeSessions(count: 6)

        let manager = BatchOperationsManager(maxConcurrency: 2) { session in
            let mock = MockSSHSession(session: session)
            mock.customExecuteCommandResultHandler = { _ in
                try await Task.sleep(nanoseconds: 500_000_000)
                return SSHCommandResult(stdout: "done", stderr: "", exitCode: 0, durationMs: 500)
            }
            return mock
        }

        let task = manager.startBatchCommand("sleep 10", on: sessions)
        try? await Task.sleep(nanoseconds: 60_000_000)
        manager.cancelCurrentBatch()
        await task.value

        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(manager.pendingCount, 0)
        XCTAssertEqual(manager.runningCount, 0)
        XCTAssertEqual(manager.cancelledCount, 6)
        XCTAssertTrue(manager.results.allSatisfy { $0.status == .cancelled })
    }

    // MARK: - TC-V29-09: Retry Failed Hosts Only
    func testTC_V29_09_RetryFailedHostsOnly() async {
        let sessions = makeSessions(count: 3)
        let failID = sessions[1].id
        let callCounts = OSAllocatedUnfairLock(initialState: [UUID: Int]())
        let shouldFail = OSAllocatedUnfairLock(initialState: true)

        let manager = BatchOperationsManager(maxConcurrency: 3) { session in
            let mock = MockSSHSession(session: session)
            mock.customExecuteCommandResultHandler = { _ in
                let count = callCounts.withLock { map -> Int in
                    let next = (map[session.id] ?? 0) + 1
                    map[session.id] = next
                    return next
                }
                if session.id == failID && shouldFail.withLock({ $0 }) {
                    return SSHCommandResult(stdout: "", stderr: "temporary failure #\(count)", exitCode: 1, durationMs: 5)
                }
                return SSHCommandResult(stdout: "ok-\(session.name)", stderr: "", exitCode: 0, durationMs: 5)
            }
            return mock
        }

        await manager.executeBatchCommand("hostname", on: sessions)
        XCTAssertEqual(manager.succeededCount, 2)
        XCTAssertEqual(manager.failedCount, 1)

        shouldFail.withLock { $0 = false }
        await manager.retryFailedHosts()

        let counts = callCounts.withLock { $0 }
        XCTAssertEqual(counts[sessions[0].id], 1, "Previously succeeded host 0 must NOT be re-run")
        XCTAssertEqual(counts[sessions[1].id], 2, "Previously failed host 1 must be re-run")
        XCTAssertEqual(counts[sessions[2].id], 1, "Previously succeeded host 2 must NOT be re-run")
        XCTAssertEqual(manager.succeededCount, 3)
        XCTAssertEqual(manager.failedCount, 0)
    }

    // MARK: - TC-V29-10: Batch File Distribution
    func testTC_V29_10_BatchFileDistribution() async throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-dist-\(UUID().uuidString).conf")
        let payloadData = Data("server_port=8443\nworker_processes=auto\n".utf8)
        try payloadData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let sessions = makeSessions(count: 3)
        let failedHostID = sessions[2].id
        let uploadedTargets = OSAllocatedUnfairLock(initialState: [UUID: String]())

        let manager = BatchOperationsManager(maxConcurrency: 2) { session in
            let mock = MockSSHSession(session: session)
            mock.customUploadHandler = { localURL, remotePath, progress in
                XCTAssertEqual(localURL, tempFile)
                if session.id == failedHostID {
                    throw NSError(domain: "SFTP", code: 13, userInfo: [NSLocalizedDescriptionKey: "Disk quota exceeded"])
                }
                progress(0.5)
                try await Task.sleep(nanoseconds: 10_000_000)
                progress(1.0)
                uploadedTargets.withLock { $0[session.id] = remotePath }
            }
            return mock
        }

        await manager.uploadFile(tempFile, toRemoteDirectory: "/etc/aetherterm/", on: sessions)

        let expectedRemotePath = "/etc/aetherterm/\(tempFile.lastPathComponent)"
        let recorded = uploadedTargets.withLock { $0 }
        XCTAssertEqual(recorded[sessions[0].id], expectedRemotePath)
        XCTAssertEqual(recorded[sessions[1].id], expectedRemotePath)
        XCTAssertNil(recorded[failedHostID])

        let r0 = manager.results.first(where: { $0.sessionID == sessions[0].id })
        let r2 = manager.results.first(where: { $0.sessionID == failedHostID })
        XCTAssertEqual(r0?.status, .succeeded)
        XCTAssertEqual(r0?.progress, 1.0)
        XCTAssertEqual(r0?.remoteTargetPath, expectedRemotePath)
        XCTAssertEqual(r2?.status.isFailed, true)
        XCTAssertTrue(r2?.stderr.contains("Disk quota exceeded") == true)
    }

    // MARK: - TC-V29-11: CSV & Markdown Export Escaping and Summary
    func testTC_V29_11_CSVAndMarkdownExportEscaping() async {
        let sessions = makeSessions(count: 2)
        let specialOutput = "line1, with comma\nline2 \"quoted\" | pipe"

        let manager = BatchOperationsManager(maxConcurrency: 2) { session in
            let mock = MockSSHSession(session: session)
            mock.customExecuteCommandResultHandler = { _ in
                if session.id == sessions[0].id {
                    return SSHCommandResult(stdout: specialOutput, stderr: "", exitCode: 0, durationMs: 42.25)
                }
                return SSHCommandResult(stdout: "", stderr: "err, \"bad\"\nline", exitCode: 127, durationMs: 9.5)
            }
            return mock
        }

        await manager.executeBatchCommand("echo test", on: sessions)

        let csv = manager.exportResultsCSV()
        let expectedEscapedCSVOutput = "\"line1, with comma\nline2 \"\"quoted\"\" | pipe\""
        XCTAssertTrue(csv.contains("Host,Address,Status,ExitCode,DurationMs,OutputSummary,Stderr"))
        XCTAssertTrue(csv.contains("node-1"))
        XCTAssertTrue(csv.contains("0,42.25"))
        XCTAssertTrue(csv.contains(expectedEscapedCSVOutput))
        XCTAssertTrue(csv.contains("127,9.50"))
        XCTAssertTrue(csv.contains("\"err, \"\"bad\"\"\nline\""))

        let md = manager.exportResultsMarkdown()
        XCTAssertTrue(md.contains("# AetherTerm 批量执行报告"))
        XCTAssertTrue(md.contains("| node-1 |"))
        XCTAssertTrue(md.contains("| 0 | 42.25 |"))
        XCTAssertTrue(md.contains("line1, with comma<br>line2 \"quoted\" \\| pipe"))
        XCTAssertTrue(md.contains("| 127 | 9.50 |"))
        XCTAssertTrue(md.contains("err, \"bad\"<br>line"))
    }
}
