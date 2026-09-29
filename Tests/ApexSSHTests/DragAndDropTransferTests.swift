import XCTest
import UniformTypeIdentifiers
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

@MainActor
final class DragAndDropTransferTests: XCTestCase {
    
    private var mockSession: MockSSHSession!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        let session = Session(name: "DragDropTestSession", host: "127.0.0.1", port: 22, username: "tester")
        mockSession = MockSSHSession(session: session)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ApexDragDropTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        TransferManager.shared.clearCompleted()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        TransferManager.shared.clearCompleted()
        try await super.tearDown()
    }

    // MARK: - 1. Remote to Local Drag Export (Small File)
    
    func testRemoteToLocalSmallFileDragExport() async throws {
        let fileName = "sample_config.json"
        let remotePath = "/etc/\(fileName)"
        let sampleContent = "{\"version\": \"1.0\", \"status\": \"healthy\"}"
        
        let localPrep = tempDir.appendingPathComponent("prep_\(fileName)")
        try sampleContent.write(to: localPrep, atomically: true, encoding: .utf8)
        try await mockSession.uploadFile(localURL: localPrep, remotePath: remotePath, progress: { _ in })
        
        let item = SFTPItem(
            name: fileName,
            path: remotePath,
            isDirectory: false,
            size: UInt64(sampleContent.utf8.count),
            permissions: 0o644,
            modificationDate: Date()
        )
        
        let provider = SFTPDragExportHelper.makeItemProvider(for: item, session: mockSession)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        
        let exp = expectation(description: "Small file exported to Finder/Desktop representation")
        
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
            XCTAssertNil(error, "Export should succeed without error: \(String(describing: error))")
            XCTAssertNotNil(url, "Exported URL must not be nil")
            if let url = url {
                let readBack = try? String(contentsOf: url, encoding: .utf8)
                XCTAssertEqual(readBack, sampleContent)
            }
            exp.fulfill()
        }
        
        await fulfillment(of: [exp], timeout: 5.0)
        
        let matching = TransferManager.shared.tasks.filter { $0.fileName == fileName }
        XCTAssertFalse(matching.isEmpty, "TransferManager must track the drag export")
        XCTAssertTrue(matching.allSatisfy { $0.status == .completed }, "Drag export must mark completed")
    }

    // MARK: - 2. Remote to Local Drag Export (Large File)
    
    func testRemoteToLocalLargeFileDragExport() async throws {
        let fileName = "large_archive.bin"
        let remotePath = "/data/\(fileName)"
        let largeSize = 2 * 1024 * 1024 // 2MB binary payload for fast CI test
        let randomBytes = (0..<largeSize).map { _ in UInt8.random(in: 0...255) }
        let largeData = Data(randomBytes)
        
        let localPrep = tempDir.appendingPathComponent("prep_\(fileName)")
        try largeData.write(to: localPrep)
        try await mockSession.uploadFile(localURL: localPrep, remotePath: remotePath, progress: { _ in })
        
        let item = SFTPItem(
            name: fileName,
            path: remotePath,
            isDirectory: false,
            size: UInt64(largeSize),
            permissions: 0o644,
            modificationDate: Date()
        )
        
        let provider = SFTPDragExportHelper.makeItemProvider(for: item, session: mockSession)
        
        let exp = expectation(description: "Large file exported without deadlock or starvation")
        
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
            XCTAssertNil(error)
            XCTAssertNotNil(url)
            if let url = url {
                let readData = try? Data(contentsOf: url)
                XCTAssertEqual(readData?.count, largeSize)
                XCTAssertEqual(readData, largeData)
            }
            exp.fulfill()
        }
        
        await fulfillment(of: [exp], timeout: 10.0)
    }

    // MARK: - 3. Remote to Local Batch Multi-File Drag Export
    
    func testRemoteToLocalBatchMultiFileExport() async throws {
        let count = 6
        var items: [SFTPItem] = []
        
        for i in 1...count {
            let name = "batch_file_\(i).txt"
            let path = "/tmp/\(name)"
            let content = "Batch payload content for file index \(i) - timestamp: \(Date())"
            let prepURL = tempDir.appendingPathComponent("prep_\(name)")
            try content.write(to: prepURL, atomically: true, encoding: .utf8)
            try await mockSession.uploadFile(localURL: prepURL, remotePath: path, progress: { _ in })
            
            items.append(SFTPItem(
                name: name,
                path: path,
                isDirectory: false,
                size: UInt64(content.utf8.count),
                permissions: 0o644,
                modificationDate: Date()
            ))
        }
        
        let expectations = items.map { expectation(description: "Batch export of \($0.name)") }
        
        for (index, item) in items.enumerated() {
            let exp = expectations[index]
            let provider = SFTPDragExportHelper.makeItemProvider(for: item, session: mockSession)
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
                XCTAssertNil(error)
                XCTAssertNotNil(url)
                if let url = url {
                    let loaded = try? String(contentsOf: url, encoding: .utf8)
                    XCTAssertTrue(loaded?.contains("Batch payload") == true)
                }
                exp.fulfill()
            }
        }
        
        await fulfillment(of: expectations, timeout: 15.0)
        XCTAssertEqual(TransferManager.shared.activeCount, 0, "All batch drag export tasks must be finished with 0 active")
    }

    // MARK: - 4. Remote to Local Drag Export Cancellation
    
    func testRemoteToLocalExportCancellation() async throws {
        let fileName = "cancel_me.dat"
        let remotePath = "/tmp/\(fileName)"
        let prepURL = tempDir.appendingPathComponent("prep_\(fileName)")
        try "Content to cancel".write(to: prepURL, atomically: true, encoding: .utf8)
        try await mockSession.uploadFile(localURL: prepURL, remotePath: remotePath, progress: { _ in })
        
        let item = SFTPItem(
            name: fileName,
            path: remotePath,
            isDirectory: false,
            size: 1024,
            permissions: 0o644,
            modificationDate: Date()
        )
        
        let provider = SFTPDragExportHelper.makeItemProvider(for: item, session: mockSession)
        let exp = expectation(description: "Cancellation handled smoothly")
        
        let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { _, _ in
            exp.fulfill()
        }
        
        // Immediately cancel
        progress.cancel()
        
        await fulfillment(of: [exp], timeout: 5.0)
    }

    // MARK: - 5. Local to Remote Drag Upload (Single Small & Large File)
    
    func testLocalToRemoteSmallAndLargeFileUpload() async throws {
        // A. Small file (512 bytes)
        let smallFile = tempDir.appendingPathComponent("local_small.txt")
        try "Small local file for drop upload".write(to: smallFile, atomically: true, encoding: .utf8)
        
        let expSmall = expectation(description: "Small file upload completed")
        TransferManager.shared.enqueueUpload(
            session: mockSession,
            localURL: smallFile,
            remotePath: "/remote/local_small.txt",
            onResult: { result in
                switch result {
                case .success(let path):
                    XCTAssertEqual(path, "/remote/local_small.txt")
                case .failure(let error):
                    XCTFail("Small file upload failed: \(error)")
                }
                expSmall.fulfill()
            }
        )
        await fulfillment(of: [expSmall], timeout: 5.0)
        
        // B. Large file (5MB)
        let largeFile = tempDir.appendingPathComponent("local_large.bin")
        let largeData = Data(repeating: 0x42, count: 5 * 1024 * 1024)
        try largeData.write(to: largeFile)
        
        let expLarge = expectation(description: "Large file upload completed")
        TransferManager.shared.enqueueUpload(
            session: mockSession,
            localURL: largeFile,
            remotePath: "/remote/local_large.bin",
            onResult: { result in
                switch result {
                case .success(let path):
                    XCTAssertEqual(path, "/remote/local_large.bin")
                case .failure(let error):
                    XCTFail("Large file upload failed: \(error)")
                }
                expLarge.fulfill()
            }
        )
        await fulfillment(of: [expLarge], timeout: 10.0)
    }

    // MARK: - 6. Local to Remote Batch Drop Upload & Name Collision
    
    func testLocalToRemoteBatchUploadAndNameCollision() async throws {
        let count = 5
        var localFiles: [URL] = []
        let expectations = (1...count).map { expectation(description: "Drop item \($0) uploaded") }
        
        for i in 1...count {
            let file = tempDir.appendingPathComponent("drop_item_\(i).txt")
            try "Dropped file content \(i)".write(to: file, atomically: true, encoding: .utf8)
            localFiles.append(file)
        }
        
        for (index, file) in localFiles.enumerated() {
            let exp = expectations[index]
            TransferManager.shared.enqueueUpload(
                session: mockSession,
                localURL: file,
                remotePath: "/remote/\(file.lastPathComponent)",
                onResult: { result in
                    switch result {
                    case .success:
                        exp.fulfill()
                    case .failure(let err):
                        XCTFail("Batch upload item \(index) failed: \(err)")
                    }
                }
            )
        }
        
        await fulfillment(of: expectations, timeout: 10.0)
        
        // Test download URL collision avoidance
        let dlDir = tempDir.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: dlDir, withIntermediateDirectories: true)
        
        let original = dlDir.appendingPathComponent("report.pdf")
        try "original".write(to: original, atomically: true, encoding: .utf8)
        
        let c2 = TransferManager.shared.availableDownloadURL(in: dlDir, fileName: "report.pdf")
        XCTAssertEqual(c2.lastPathComponent, "report (2).pdf")
        
        try? "existing 2".write(to: c2, atomically: true, encoding: .utf8)
        let c3 = TransferManager.shared.availableDownloadURL(in: dlDir, fileName: "report.pdf")
        XCTAssertEqual(c3.lastPathComponent, "report (3).pdf")
    }

    // MARK: - 7. Path with Spaces and Special Characters
    
    func testPathsWithSpacesAndSpecialCharacters() async throws {
        let complexName = "Report (2026) #1 & Final [v2].txt"
        let remotePath = "/data/\(complexName)"
        let content = "Safe handling of spaces, brackets and symbols!"
        
        let localPrep = tempDir.appendingPathComponent(complexName)
        try content.write(to: localPrep, atomically: true, encoding: .utf8)
        try await mockSession.uploadFile(localURL: localPrep, remotePath: remotePath, progress: { _ in })
        
        let item = SFTPItem(
            name: complexName,
            path: remotePath,
            isDirectory: false,
            size: UInt64(content.utf8.count),
            permissions: 0o644,
            modificationDate: Date()
        )
        
        let provider = SFTPDragExportHelper.makeItemProvider(for: item, session: mockSession)
        let exp = expectation(description: "Export complex path with spaces")
        
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { url, error in
            XCTAssertNil(error)
            XCTAssertNotNil(url)
            if let url = url {
                let text = try? String(contentsOf: url, encoding: .utf8)
                XCTAssertEqual(text, content)
            }
            exp.fulfill()
        }
        
        await fulfillment(of: [exp], timeout: 5.0)
    }

    // MARK: - 8. Process Non-Blocking Async Suspension and Swift 6 Safety
    
    nonisolated func testAsyncProcessCancellationWithoutDeadlock() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let task = Task {
            try await NativeSSHSession.runTransferProcess(process)
        }
        
        // Wait 100ms for process to start, then cancel
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(process.isRunning)
        task.cancel()
        
        do {
            _ = try await task.value
            XCTFail("Should have thrown CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        
        // Allow kernel to reap killed process
        for _ in 0..<20 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(process.isRunning)
    }
}
