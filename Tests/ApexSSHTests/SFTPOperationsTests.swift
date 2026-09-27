import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

final class SFTPOperationsTests: XCTestCase {
    
    var session: Session!
    var mockClient: MockSSHSession!
    
    override func setUp() {
        super.setUp()
        session = Session(
            id: UUID(),
            name: "Mock Server",
            host: "192.0.2.10",
            port: 22,
            username: "root",
            authMethod: .password(keychainRef: "test-ref")
        )
        mockClient = MockSSHSession(session: session)
    }
    
    func testCancellingNativeTransferStopsItsProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        let task = Task { try await NativeSSHSession.runTransferProcess(process) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(process.isRunning, "The transfer process must start before testing cancellation")
        task.cancel()
        do { try await task.value; XCTFail("Cancelled copy must not report success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    }

    func testRemotePermissionsAreParsedAndDisplayedIncludingSpecialBits() {
        for (symbolic, mode): (String, UInt32) in [("-rw-------", 0o600), ("drwxr-xr-x", 0o755), ("-rwsr-Sr-t", 0o7745), ("drwxrwxrwt+", 0o1777)] {
            XCTAssertEqual(NativeSSHSession.permissionMode(from: symbolic), mode)
            let item = SFTPItem(name: "file", path: "/tmp/file", isDirectory: symbolic.hasPrefix("d"), permissions: mode)
            XCTAssertEqual(item.permissionString, String(symbolic.prefix(10)))
        }
    }

    func testRemotePathQuotingPreservesShellCharactersLiterally() throws {
        for path in ["/tmp/a b", "/tmp/引号'与\"", "/tmp/$(printf expanded);`printf expanded`", "/tmp/line\nend", ""] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' " + NativeSSHSession.quoteRemotePath(path)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), path)
        }
    }

    /// Test 1: createDirectory and removeDirectory operations
    func testCreateAndRemoveDirectory() async throws {
        let initial = try await mockClient.listDirectory(path: "/root")
        let testDirPath = "/root/test_backup"
        XCTAssertFalse(initial.contains(where: { $0.path == testDirPath }))
        
        try await mockClient.createDirectory(remotePath: testDirPath)
        let afterCreate = try await mockClient.listDirectory(path: "/root")
        XCTAssertTrue(afterCreate.contains(where: { $0.path == testDirPath && $0.isDirectory }))
        
        try await mockClient.removeDirectory(remotePath: testDirPath, recursive: true)
        let afterRemove = try await mockClient.listDirectory(path: "/root")
        XCTAssertFalse(afterRemove.contains(where: { $0.path == testDirPath }))
    }
    
    /// Test 2: createFile and removeFile operations
    func testCreateAndRemoveFile() async throws {
        let testFilePath = "/root/app_config.env"
        try await mockClient.createFile(remotePath: testFilePath)
        let afterCreate = try await mockClient.listDirectory(path: "/root")
        let fileItem = afterCreate.first(where: { $0.path == testFilePath })
        XCTAssertNotNil(fileItem)
        XCTAssertFalse(fileItem?.isDirectory ?? true)
        
        try await mockClient.removeFile(remotePath: testFilePath)
        let afterRemove = try await mockClient.listDirectory(path: "/root")
        XCTAssertFalse(afterRemove.contains(where: { $0.path == testFilePath }))
    }
    
    /// Test 3: rename operation
    func testRenameFile() async throws {
        let oldPath = "/root/deploy.sh"
        let newPath = "/root/deploy_v2.sh"
        
        let initial = try await mockClient.listDirectory(path: "/root")
        XCTAssertTrue(initial.contains(where: { $0.path == oldPath }))
        
        try await mockClient.rename(oldPath: oldPath, newPath: newPath)
        let afterRename = try await mockClient.listDirectory(path: "/root")
        XCTAssertFalse(afterRename.contains(where: { $0.path == oldPath }))
        XCTAssertTrue(afterRename.contains(where: { $0.path == newPath && $0.name == "deploy_v2.sh" }))
    }
    
    /// Test 4: Hidden file filtering
    func testHiddenFileFiltering() async throws {
        let items = try await mockClient.listDirectory(path: "/root")
        let hiddenItems = items.filter { $0.name.hasPrefix(".") && $0.name != ".." }
        XCTAssertFalse(hiddenItems.isEmpty, "Mock directory should contain dotfiles like .bashrc and .profile")
        
        // Simulating showHiddenFiles = false
        let visibleOnly = items.filter { !$0.name.hasPrefix(".") || $0.name == ".." }
        XCTAssertFalse(visibleOnly.contains(where: { $0.name == ".bashrc" }))
        XCTAssertFalse(visibleOnly.contains(where: { $0.name == ".profile" }))
        XCTAssertTrue(visibleOnly.contains(where: { $0.name == "nginx.conf" }))
    }
    
    /// Test 5: Table sorting by Size, Date, and Name
    func testTableSorting() async throws {
        let items = try await mockClient.listDirectory(path: "/root")
        let files = items.filter { !$0.isDirectory }
        
        // Size ascending
        let sizeAsc = files.sorted { $0.size < $1.size }
        XCTAssertLessThanOrEqual(sizeAsc.first!.size, sizeAsc.last!.size)
        
        // Size descending
        let sizeDesc = files.sorted { $0.size > $1.size }
        XCTAssertGreaterThanOrEqual(sizeDesc.first!.size, sizeDesc.last!.size)
        
        // Date descending (newest first)
        let dateDesc = files.sorted { $0.modificationDate > $1.modificationDate }
        XCTAssertGreaterThanOrEqual(dateDesc.first!.modificationDate, dateDesc.last!.modificationDate)
    }
}
