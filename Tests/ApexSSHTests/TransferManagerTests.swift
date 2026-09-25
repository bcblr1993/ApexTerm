import XCTest
@testable import ApexCore
@testable import ApexSSH

final class TransferManagerTests: XCTestCase {
    
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
}
