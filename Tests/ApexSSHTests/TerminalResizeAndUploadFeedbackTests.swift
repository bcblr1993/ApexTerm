import XCTest
import AppKit
@testable import ApexTerminal
@testable import ApexSSH
@testable import ApexCore

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

private final class FailingMockSession: SSHSessionProtocol, @unchecked Sendable {
    let session = Session(name: "FailingTest", host: "127.0.0.1", port: 22, username: "ubuntu")
    var connectionState: SSHConnectionState = .connected
    
    func connect() async throws {}
    func disconnect() async {}
    func sendInput(_ data: Data) async throws {}
    func resizeTerminal(columns: Int, rows: Int) async throws {}
    func listDirectory(path: String) async throws -> [SFTPItem] { [] }
    func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {}
    func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {
        throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "scp: dest open \"/home/ubuntu/services/test.txt\": Permission denied"])
    }
    func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) {}
    func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) {}
    func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) {}
}

final class TerminalResizeAndUploadFeedbackTests: XCTestCase {
    
    @MainActor
    func testCalculateTerminalDimensions() {
        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: nil)
        let (cols, rows) = view.calculateTerminalDimensions()
        
        // At 800x600, with monospaced font ~7.8pt width and ~16pt height:
        // cols should be roughly ~80-120, rows should be roughly ~25-45
        XCTAssertGreaterThan(cols, 40, "Columns should be at least 40 for 800px width")
        XCTAssertLessThan(cols, 200, "Columns should be bounded reasonably")
        XCTAssertGreaterThan(rows, 15, "Rows should be at least 15 for 600px height")
        XCTAssertLessThan(rows, 80, "Rows should be bounded reasonably")
        
        // Small view test
        let smallView = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 80), textContainer: nil)
        let (smallCols, smallRows) = smallView.calculateTerminalDimensions()
        XCTAssertGreaterThanOrEqual(smallCols, 10, "Minimum columns constraint")
        XCTAssertGreaterThanOrEqual(smallRows, 3, "Minimum rows constraint")
    }
    
    @MainActor
    func testNotifyDimensionsChangedTriggersResize() async {
        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), textContainer: nil)
        
        let colsBox = ResultBox<Int>()
        let rowsBox = ResultBox<Int>()
        let exp = expectation(description: "onResize should be called")
        
        view.onResize = { cols, rows in
            colsBox.value = cols
            rowsBox.value = rows
            exp.fulfill()
        }
        
        view.notifyDimensionsChangedIfNeeded()
        
        await fulfillment(of: [exp], timeout: 2.0)
        XCTAssertNotNil(colsBox.value)
        XCTAssertNotNil(rowsBox.value)
        XCTAssertGreaterThan(colsBox.value!, 0)
        XCTAssertGreaterThan(rowsBox.value!, 0)
    }
    
    @MainActor
    func testTerminalFileDropHandler() {
        let view = NativeTerminalView()
        var droppedURL: URL?
        view.onFileDrop = { url in
            droppedURL = url
        }
        
        let testURL = URL(fileURLWithPath: "/tmp/sample_upload.txt")
        view.onFileDrop?(testURL)
        
        XCTAssertEqual(droppedURL, testURL)
    }
    
    @MainActor
    func testTransferManagerUploadResultSuccess() async throws {
        let manager = TransferManager.shared
        let session = MockSSHSession(session: Session(name: "Test", host: "127.0.0.1", port: 22, username: "user"))
        try await session.connect()
        
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_res_\(UUID().uuidString).txt")
        try "test payload".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let exp = expectation(description: "Upload onResult should be called with success")
        let box = ResultBox<Result<String, Error>>()
        
        manager.enqueueUpload(
            session: session,
            localURL: tempFile,
            remotePath: "/tmp/dest.txt",
            onResult: { res in
                box.value = res
                exp.fulfill()
            }
        )
        
        await fulfillment(of: [exp], timeout: 5.0)
        
        guard let res = box.value else {
            XCTFail("No result received")
            return
        }
        
        switch res {
        case .success(let path):
            XCTAssertEqual(path, "/tmp/dest.txt")
        case .failure(let error):
            XCTFail("Expected success but got error: \(error)")
        }
    }
    
    @MainActor
    func testTransferManagerUploadResultFailurePermissionDenied() async throws {
        let manager = TransferManager.shared
        let failingSession = FailingMockSession()
        try await failingSession.connect()
        
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_fail_\(UUID().uuidString).txt")
        try "test".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let exp = expectation(description: "Upload onResult should be called with failure")
        let box = ResultBox<Result<String, Error>>()
        
        manager.enqueueUpload(
            session: failingSession,
            localURL: tempFile,
            remotePath: "/home/ubuntu/services/test.txt",
            onResult: { res in
                box.value = res
                exp.fulfill()
            }
        )
        
        await fulfillment(of: [exp], timeout: 5.0)
        
        guard let res = box.value else {
            XCTFail("No result received")
            return
        }
        
        switch res {
        case .success:
            XCTFail("Expected failure but got success")
        case .failure(let error):
            XCTAssertTrue(error.localizedDescription.contains("Permission denied"), "Error should report permission denied: \(error)")
        }
    }
}
