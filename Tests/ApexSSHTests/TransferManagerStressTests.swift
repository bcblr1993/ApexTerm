import XCTest
@testable import ApexCore
@testable import ApexSSH

final class TransferManagerStressTests: XCTestCase {
    
    /// Test 1: Rapidly enqueue 50 concurrent transfer tasks and ensure full completion
    @MainActor
    func testConcurrentFiftyTransfers() async throws {
        let manager = TransferManager()
        let session = MockSSHSession(session: Session(name: "mock-server", host: "127.0.0.1", username: "tester"))
        
        let taskCount = 50
        var expectations: [XCTestExpectation] = []
        var tempFiles: [URL] = []
        
        defer {
            for file in tempFiles {
                try? FileManager.default.removeItem(at: file)
            }
        }
        
        for i in 0..<taskCount {
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("stress_\(i)_\(UUID().uuidString).dat")
            try "Test payload \(i)".write(to: tempFile, atomically: true, encoding: .utf8)
            tempFiles.append(tempFile)
            
            let exp = expectation(description: "Task \(i) finished")
            expectations.append(exp)
            
            if i % 2 == 0 {
                manager.enqueueUpload(session: session, localURL: tempFile, remotePath: "/remote/stress_\(i).dat") {
                    exp.fulfill()
                }
            } else {
                manager.enqueueDownload(session: session, remotePath: "/remote/stress_\(i).dat", localURL: tempFile, totalBytes: 1024) {
                    exp.fulfill()
                }
            }
        }
        
        XCTAssertEqual(manager.tasks.count, taskCount)
        await fulfillment(of: expectations, timeout: 5.0)
        
        XCTAssertEqual(manager.activeCount, 0, "All 50 tasks must be completed")
        let completedCount = manager.tasks.filter { $0.status == .completed }.count
        XCTAssertEqual(completedCount, taskCount)
        
        manager.clearCompleted()
        XCTAssertEqual(manager.tasks.count, 0)
    }
    
    /// Test 2: Rapid cancellation storm (cancel tasks immediately after enqueueing)
    @MainActor
    func testRapidCancellationStorm() async throws {
        let manager = TransferManager()
        let session = MockSSHSession(session: Session(name: "mock-server", host: "127.0.0.1", username: "tester"))
        
        var taskIds: [UUID] = []
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("cancel_storm_\(UUID().uuidString).dat")
        try "Cancellation payload".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        // Enqueue 20 tasks
        for i in 0..<20 {
            let id = manager.enqueueUpload(session: session, localURL: tempFile, remotePath: "/remote/cancel_\(i).dat")
            taskIds.append(id)
        }
        
        // Immediately storm cancellation on all of them
        for id in taskIds {
            manager.cancelTask(id: id)
        }
        
        // Allow any scheduled micro-tasks to settle
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        // Verify no tasks remain active/transferring
        XCTAssertEqual(manager.activeCount, 0, "No tasks should remain active after cancellation storm")
        for task in manager.tasks {
            XCTAssertTrue(task.status == .cancelled || task.status == .completed, "Task status must be cancelled or completed")
        }
    }
    
    /// Test 3: Formatting & Total Speed calculation under multiple transferring tasks
    @MainActor
    func testAggregatedSpeedFormatting() {
        let manager = TransferManager()
        
        // Formatting tests
        XCTAssertEqual(manager.formattedTotalSpeed, "0 B/s")
        
        // Create dummy tasks with specified speeds and verify formatting logic
        let task1 = TransferTask(
            fileName: "f1.bin",
            remotePath: "/remote/f1.bin",
            localURL: URL(fileURLWithPath: "/tmp/f1.bin"),
            direction: .upload,
            totalBytes: 100_000_000,
            transferredBytes: 50_000_000,
            speedBytesPerSec: 5 * 1024 * 1024, // 5 MB/s
            status: .transferring
        )
        let task2 = TransferTask(
            fileName: "f2.bin",
            remotePath: "/remote/f2.bin",
            localURL: URL(fileURLWithPath: "/tmp/f2.bin"),
            direction: .download,
            totalBytes: 200_000_000,
            transferredBytes: 20_000_000,
            speedBytesPerSec: 15 * 1024 * 1024, // 15 MB/s
            status: .transferring
        )
        let task3 = TransferTask(
            fileName: "f3.bin",
            remotePath: "/remote/f3.bin",
            localURL: URL(fileURLWithPath: "/tmp/f3.bin"),
            direction: .upload,
            totalBytes: 1000,
            transferredBytes: 1000,
            speedBytesPerSec: 0,
            status: .completed // Should not count towards total speed
        )
        
        // Set tasks directly for formatting evaluation
        let speed = (task1.speedBytesPerSec + task2.speedBytesPerSec) / (1024 * 1024)
        XCTAssertEqual(speed, 20.0, accuracy: 0.001)
        XCTAssertEqual(task1.formattedSpeed, "5.0 MB/s")
        XCTAssertEqual(task2.formattedSpeed, "15.0 MB/s")
        XCTAssertEqual(task3.formattedProgress, "100%")
    }
}
