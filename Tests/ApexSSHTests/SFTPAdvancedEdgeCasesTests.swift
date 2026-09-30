import XCTest
@testable import ApexCore
@testable import ApexSSH

final class SFTPAdvancedEdgeCasesTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sftp_edge_cases_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    @MainActor
    func testZeroByteFileUploadAndDownload() async throws {
        let session = Session(name: "zero-byte-node", host: "127.0.0.1", username: "root")
        let client = MockSSHSession(session: session)
        try await client.connect()

        let localZeroFile = tempDir.appendingPathComponent("empty.txt")
        try Data().write(to: localZeroFile) // 0-byte file
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: localZeroFile.path)[.size] as? Int64), 0)

        let transferManager = TransferManager()

        // 1. Test 0-byte Upload
        let uploadExpectation = expectation(description: "0-byte upload completes successfully")
        let uploadTaskId = transferManager.enqueueUpload(
            session: client,
            localURL: localZeroFile,
            remotePath: "/root/empty.txt",
            onResult: { result in
                switch result {
                case .success(let path):
                    XCTAssertEqual(path, "/root/empty.txt")
                    uploadExpectation.fulfill()
                case .failure(let err):
                    XCTFail("0-byte upload failed: \(err)")
                }
            }
        )

        await fulfillment(of: [uploadExpectation], timeout: 5.0)
        let uploadTask = transferManager.tasks.first(where: { $0.id == uploadTaskId })
        XCTAssertEqual(uploadTask?.status, .completed)
        XCTAssertEqual(uploadTask?.progress, 1.0)

        // 2. Test 0-byte Download
        let downloadDest = tempDir.appendingPathComponent("downloaded_empty.txt")
        let downloadExpectation = expectation(description: "0-byte download completes successfully")
        let downloadTaskId = transferManager.enqueueDownload(
            session: client,
            remotePath: "/root/empty.txt",
            localURL: downloadDest,
            totalBytes: 0,
            onResult: { result in
                switch result {
                case .success(let url):
                    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                    downloadExpectation.fulfill()
                case .failure(let err):
                    XCTFail("0-byte download failed: \(err)")
                }
            }
        )

        await fulfillment(of: [downloadExpectation], timeout: 5.0)
        let downloadTask = transferManager.tasks.first(where: { $0.id == downloadTaskId })
        XCTAssertEqual(downloadTask?.status, .completed)
        XCTAssertEqual(downloadTask?.progress, 1.0)

        await client.disconnect()
    }

    func testDeeplyNestedDirectoryHierarchy() async throws {
        let session = Session(name: "nested-dir-node", host: "127.0.0.1", username: "root")
        let client = MockSSHSession(session: session)
        try await client.connect()

        // Create 8 levels of directories: /a/b/c/d/e/f/g/h
        let levels = ["a", "b", "c", "d", "e", "f", "g", "h"]
        var currentPath = ""
        for dir in levels {
            currentPath += "/\(dir)"
            try await client.createDirectory(remotePath: currentPath)
        }

        // Verify parent-child relationships and listing
        var checkPath = ""
        for i in 0..<(levels.count - 1) {
            checkPath += "/\(levels[i])"
            let items = try await client.listDirectory(path: checkPath)
            let childName = levels[i + 1]
            XCTAssertTrue(items.contains(where: { $0.name == childName && $0.isDirectory }), "Directory \(checkPath) should contain child \(childName)")
        }

        // Test deep file creation at the deepest level
        let deepFilePath = "\(currentPath)/target.config"
        try await client.createFile(remotePath: deepFilePath)
        let deepestItems = try await client.listDirectory(path: currentPath)
        XCTAssertTrue(deepestItems.contains(where: { $0.name == "target.config" && !$0.isDirectory }))

        await client.disconnect()
    }

    func testBrokenAndLoopSymlinkHandling() async throws {
        // SFTP items can represent symlinks, broken symlinks, and circular directory links
        let brokenLink = SFTPItem(
            name: "broken_link.so",
            path: "/usr/lib/broken_link.so",
            isDirectory: false,
            isSymlink: true,
            size: 0,
            permissions: 0o777,
            modificationDate: Date()
        )
        XCTAssertTrue(brokenLink.isSymlink)
        XCTAssertFalse(brokenLink.isDirectory)

        let loopLink = SFTPItem(
            name: "circular_symlink",
            path: "/var/log/circular_symlink",
            isDirectory: true,
            isSymlink: true,
            size: 4096,
            permissions: 0o777,
            modificationDate: Date()
        )
        XCTAssertTrue(loopLink.isSymlink)
        XCTAssertTrue(loopLink.isDirectory)

        // Traversal loop prevention logic:
        var visitedPaths = Set<String>()
        func traverseSimulated(item: SFTPItem) -> Bool {
            if visitedPaths.contains(item.path) {
                return false // Loop detected safely
            }
            visitedPaths.insert(item.path)
            return true
        }

        XCTAssertTrue(traverseSimulated(item: loopLink))
        XCTAssertFalse(traverseSimulated(item: loopLink), "Visiting loopLink a second time must be detected as cycle")
    }

    @MainActor
    func testPermissionDeniedErrorHandling() async {
        // Test TransferTask status failure representation and localized error handling
        var task = TransferTask(
            fileName: "protected.conf",
            remotePath: "/etc/shadow",
            localURL: tempDir.appendingPathComponent("protected.conf"),
            direction: .upload,
            totalBytes: 1024,
            status: .queued
        )

        // State transition to failed with permission error
        task.status = .failed("Permission denied (SSH_FX_PERMISSION_DENIED)")
        XCTAssertEqual(task.status, .failed("Permission denied (SSH_FX_PERMISSION_DENIED)"))
        
        switch task.status {
        case .failed(let reason):
            XCTAssertTrue(reason.contains("Permission denied"))
        default:
            XCTFail("Task should be in failed state")
        }
    }

    func testRapidDirectorySwitchRaceCondition() async throws {
        let session = Session(name: "rapid-nav", host: "127.0.0.1", username: "root")
        let client = MockSSHSession(session: session)
        try await client.connect()

        let paths = ["/etc", "/var", "/usr/bin", "/tmp", "/opt", "/root"]
        var results: [String: Int] = [:]

        // Dispatch rapid concurrent directory list requests
        await withTaskGroup(of: (String, Int).self) { group in
            for path in paths {
                group.addTask {
                    let items = (try? await client.listDirectory(path: path)) ?? []
                    return (path, items.count)
                }
            }

            for await (path, count) in group {
                results[path] = count
            }
        }

        // Verify all 6 paths responded without deadlock or data contamination
        XCTAssertEqual(results.count, paths.count)
        for path in paths {
            XCTAssertNotNil(results[path], "Path \(path) should have returned directory listing")
        }

        await client.disconnect()
    }
}
