import XCTest
@testable import ApexCore
@testable import ApexSSH

final class TransferManagerTests: XCTestCase {
    
    @MainActor
    func testDuplicateDownloadNamesPreserveExistingAndQueuedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("payload.bin")
        let content = Data("existing data".utf8)
        try content.write(to: original)
        let manager = TransferManager()
        let second = manager.availableDownloadURL(in: directory, fileName: "payload.bin")
        XCTAssertEqual(second.lastPathComponent, "payload (2).bin")
        let session = MockSSHSession(session: Session(name: "test", host: "192.0.2.1", username: "demo"))
        let id = manager.enqueueDownload(session: session, remotePath: "/payload.bin", localURL: second, totalBytes: 1)
        XCTAssertEqual(manager.availableDownloadURL(in: directory, fileName: "payload.bin").lastPathComponent, "payload (3).bin")
        manager.cancelTask(id: id)
        XCTAssertEqual(try Data(contentsOf: original), content)
    }

    @MainActor
    func testTransferTaskFormatting() {
        let task = TransferTask(
            fileName: "archive.tar.gz",
            remotePath: "/var/www/archive.tar.gz",
            localURL: URL(fileURLWithPath: "/tmp/archive.tar.gz"),
            direction: .upload,
            totalBytes: 10 * 1024 * 1024,
            transferredBytes: 5 * 1024 * 1024,
            speedBytesPerSec: 2.5 * 1024 * 1024,
            status: .transferring
        )
        
        XCTAssertEqual(task.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(task.formattedProgress, "50%")
        XCTAssertEqual(task.formattedSpeed, "2.5 MB/s")
    }
    
    @MainActor
    func testTransferManagerLifecycle() async throws {
        let manager = TransferManager()
        XCTAssertEqual(manager.tasks.count, 0)
        XCTAssertEqual(manager.activeCount, 0)
        
        let session = MockSSHSession(session: Session(name: "mock-server", host: "127.0.0.1", username: "tester"))
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_upload_\(UUID().uuidString).txt")
        try "ApexTerm Transfer Test Payload".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let exp = expectation(description: "Upload completed")
        let taskId = manager.enqueueUpload(session: session, localURL: tempFile, remotePath: "/tmp/test_upload.txt") {
            exp.fulfill()
        }
        XCTAssertEqual(manager.tasks.count, 1)
        XCTAssertEqual(manager.tasks[0].id, taskId)
        
        await fulfillment(of: [exp], timeout: 2.0)
        
        XCTAssertTrue(manager.tasks[0].status == .completed)
        XCTAssertEqual(manager.activeCount, 0)
        
        manager.clearCompleted()
        XCTAssertEqual(manager.tasks.count, 0)
    }

    @MainActor
    func testCurrentTransferredBytesCalculation() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let fileA = tempDir.appendingPathComponent("fileA.bin")
        let dataA = Data(repeating: 0x01, count: 1024)
        try dataA.write(to: fileA)
        
        let nonExistent = tempDir.appendingPathComponent("doesNotExist.bin")
        XCTAssertEqual(TransferManager.currentTransferredBytes(at: nonExistent), 0)
        XCTAssertEqual(TransferManager.currentTransferredBytes(at: fileA), 1024)
        
        let subDir = tempDir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let fileB = subDir.appendingPathComponent("fileB.bin")
        let dataB = Data(repeating: 0x02, count: 2048)
        try dataB.write(to: fileB)
        
        // Recursive directory size should sum fileA (1024) + fileB (2048) = 3072
        XCTAssertEqual(TransferManager.currentTransferredBytes(at: tempDir), 3072)
    }

    @MainActor
    func testDownloadRealtimeProgressTracking() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let localURL = tempDir.appendingPathComponent("stream_download.bin")
        let manager = TransferManager()
        let session = MockSSHSession(session: Session(name: "mock", host: "127.0.0.1", username: "tester"))
        session.customDownloadHandler = { remotePath, destURL, progress in
            FileManager.default.createFile(atPath: destURL.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: destURL) else { return }
            defer { try? handle.close() }
            let chunk = Data(repeating: 0x42, count: 64 * 1024) // 64 KB
            for _ in 1...4 {
                try? await Task.sleep(nanoseconds: 180_000_000)
                try? handle.write(contentsOf: chunk)
            }
            progress(1.0)
        }
        
        let exp = expectation(description: "Download completes")
        let totalExpectedBytes: Int64 = 256 * 1024 // 256 KB
        
        let taskId = manager.enqueueDownload(
            session: session,
            remotePath: "/stream.bin",
            localURL: localURL,
            totalBytes: totalExpectedBytes,
            onCompleted: {
                exp.fulfill()
            }
        )
        
        // Wait while downloading to sample intermediate progress
        var sawIntermediateProgress = false
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let task = manager.tasks.first(where: { $0.id == taskId }),
               task.status == .transferring,
               task.transferredBytes > 0 {
                sawIntermediateProgress = true
                XCTAssertGreaterThan(task.progress, 0.0)
                break
            }
        }
        
        await fulfillment(of: [exp], timeout: 5.0)
        
        guard let finalTask = manager.tasks.first(where: { $0.id == taskId }) else {
            XCTFail("Task should exist")
            return
        }
        XCTAssertTrue(sawIntermediateProgress, "Should observe intermediate transferred bytes > 0 while transferring")
        XCTAssertEqual(finalTask.status, .completed)
        XCTAssertEqual(finalTask.transferredBytes, totalExpectedBytes)
        XCTAssertEqual(finalTask.progress, 1.0)
    }

    @MainActor
    func testZeroByteDownloadProgressHandling() {
        let task = TransferTask(
            fileName: "zero.txt",
            remotePath: "/tmp/zero.txt",
            localURL: URL(fileURLWithPath: "/tmp/zero.txt"),
            direction: .download,
            totalBytes: 0,
            transferredBytes: 1024,
            speedBytesPerSec: 1024,
            status: .transferring
        )
        XCTAssertEqual(task.progress, 0.0)
        XCTAssertEqual(task.formattedProgress, "0%")
        XCTAssertEqual(task.formattedSpeed, "1 KB/s")
    }

    @MainActor
    func testMaxConcurrentSlotAccountingAndCancelCompletedGuard() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = TransferManager(maxConcurrentTransfers: 2)
        let session = MockSSHSession(session: Session(name: "slot-test", host: "192.0.2.10", username: "qa"))
        final class ActiveCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var current = 0
            var maxObserved = 0
            func enter() {
                lock.withLock {
                    current += 1
                    maxObserved = max(maxObserved, current)
                }
            }
            func leave() {
                lock.withLock { current -= 1 }
            }
            var peak: Int { lock.withLock { maxObserved } }
        }
        let counter = ActiveCounter()
        session.customUploadHandler = { _, _, progress in
            counter.enter()
            try await Task.sleep(nanoseconds: 80_000_000)
            progress(1.0)
            counter.leave()
        }

        let payload = tempDir.appendingPathComponent("slot.bin")
        try Data("slot-data".utf8).write(to: payload)

        var expectations: [XCTestExpectation] = []
        var ids: [UUID] = []
        for i in 0..<5 {
            let exp = expectation(description: "Upload \(i)")
            expectations.append(exp)
            let id = manager.enqueueUpload(session: session, localURL: payload, remotePath: "/tmp/slot_\(i).bin") {
                exp.fulfill()
            }
            ids.append(id)
        }

        await fulfillment(of: expectations, timeout: 5.0)
        XCTAssertLessThanOrEqual(counter.peak, 2, "Concurrent running transfers must never exceed maxConcurrentTransfers=2")
        XCTAssertEqual(manager.activeCount, 0)

        // Calling cancelTask on an already completed task must not revert it to .cancelled
        manager.cancelTask(id: ids[0])
        XCTAssertEqual(manager.tasks.first(where: { $0.id == ids[0] })?.status, .completed)
    }

    @MainActor
    func testRetryFailedAndCancelledTransfers() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = TransferManager(maxConcurrentTransfers: 1)
        let session = MockSSHSession(session: Session(name: "retry-test", host: "192.0.2.10", username: "qa"))
        final class RetryState: @unchecked Sendable {
            private let lock = NSLock()
            var shouldFail = true
            var attempt = 0
            func checkShouldFail() -> Bool { lock.withLock { shouldFail } }
            func setShouldFail(_ v: Bool) { lock.withLock { shouldFail = v } }
            func nextAttempt() -> Int {
                lock.withLock {
                    attempt += 1
                    return attempt
                }
            }
        }
        let state = RetryState()
        session.customUploadHandler = { _, _, progress in
            if state.checkShouldFail() {
                throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "simulated failure"])
            }
            progress(1.0)
        }

        let file = tempDir.appendingPathComponent("retry.txt")
        try Data("retry payload".utf8).write(to: file)

        let failExp = expectation(description: "Initial upload fails")
        let successExp = expectation(description: "Retried upload succeeds")
        let firstId = manager.enqueueUpload(session: session, localURL: file, remotePath: "/tmp/retry.txt", onResult: { result in
            if state.nextAttempt() == 1 {
                if case .success = result { XCTFail("First attempt should fail") }
                failExp.fulfill()
            } else {
                if case .failure(let err) = result { XCTFail("Retry should succeed: \(err)") }
                successExp.fulfill()
            }
        })

        await fulfillment(of: [failExp], timeout: 3.0)
        if case .failed = manager.tasks.first(where: { $0.id == firstId })?.status {} else {
            XCTFail("Expected failed status before retry")
        }

        state.setShouldFail(false)
        let retriedId = try XCTUnwrap(manager.retryTask(id: firstId))
        XCTAssertNotEqual(retriedId, firstId)
        await fulfillment(of: [successExp], timeout: 3.0)
        XCTAssertEqual(manager.tasks.first(where: { $0.id == retriedId })?.status, .completed)
        XCTAssertNil(manager.retryTask(id: retriedId), "Completed task cannot be retried")
    }

    @MainActor
    func testCancelAllTasksAndHistoryPruningPreservesActive() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = TransferManager(maxConcurrentTransfers: 1, maxCompletedHistory: 2)
        let session = MockSSHSession(session: Session(name: "cancel-all", host: "192.0.2.10", username: "qa"))
        session.customUploadHandler = { _, _, progress in
            try await Task.sleep(nanoseconds: 500_000_000)
            progress(1.0)
        }

        let file = tempDir.appendingPathComponent("bulk.bin")
        try Data("bulk".utf8).write(to: file)
        for i in 0..<4 {
            manager.enqueueUpload(session: session, localURL: file, remotePath: "/tmp/bulk_\(i).bin")
        }
        manager.cancelAllTasks()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertLessThanOrEqual(manager.tasks.count, 2, "Pruning should keep at most maxCompletedHistory terminal records")
    }
}
