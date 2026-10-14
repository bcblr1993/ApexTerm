import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

final class LocalTerminalSessionTests: XCTestCase {
    
    func testFactoryInstantiatesLocalSession() {
        let local = Session.local()
        let client = SSHClientFactory.makeClient(for: local)
        XCTAssertTrue(client is LocalTerminalSession)
        XCTAssertEqual(client.session.sessionType, .local)
        XCTAssertTrue(client.session.isLocal)
    }
    
    func testShellResolutionReturnsExecutable() {
        let shell = LocalTerminalSession.resolveShellPath()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell), "Resolved shell must be executable: \(shell)")
    }
    
    func testLocalTerminalSessionConnectAndEcho() async throws {
        final class OutputCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) -> String {
                lock.withLock {
                    data.append(chunk)
                    return String(data: data, encoding: .utf8) ?? ""
                }
            }
        }
        
        let local = Session.local(name: "Test Local Terminal")
        let session = LocalTerminalSession(session: local)
        let collector = OutputCollector()
        let outputExpectation = expectation(description: "PTY Output received")
        outputExpectation.assertForOverFulfill = false
        
        session.setOutputHandler { data in
            let text = collector.append(data)
            if text.contains("APEX_LOCAL_PTY_OK") {
                outputExpectation.fulfill()
            }
        }
        
        try await session.connect()
        XCTAssertEqual(session.connectionState, .connected)
        
        // Give shell a tiny moment to initialize prompt
        try await Task.sleep(nanoseconds: 150_000_000)
        
        let testCmd = "echo 'APEX_LOCAL_PTY_OK'\n"
        try await session.sendInput(Data(testCmd.utf8))
        
        await fulfillment(of: [outputExpectation], timeout: 5.0)
        
        // Test resize
        try await session.resizeTerminal(columns: 140, rows: 45)
        
        // Test disconnect
        await session.disconnect()
        XCTAssertEqual(session.connectionState, .disconnected)
    }
    
    func testLocalDirectoryListing() async throws {
        let session = LocalTerminalSession()
        
        // List home directory
        let items = try await session.listDirectory(path: "~")
        XCTAssertFalse(items.isEmpty, "Home directory listing should not be empty")
        
        // Check attributes
        if let first = items.first {
            XCTAssertFalse(first.name.isEmpty)
            XCTAssertFalse(first.path.isEmpty)
            XCTAssertTrue(first.path.hasPrefix("/"))
        }
        
        // Check sort order: directories first
        let dirIndices = items.enumerated().filter { $0.element.isDirectory }.map { $0.offset }
        let fileIndices = items.enumerated().filter { !$0.element.isDirectory }.map { $0.offset }
        if let lastDir = dirIndices.last, let firstFile = fileIndices.first {
            XCTAssertLessThan(lastDir, firstFile, "Directories must be sorted before files")
        }
    }
    
    func testLocalFileOperationsCRUD() async throws {
        let session = LocalTerminalSession()
        let tempDir = NSTemporaryDirectory() + "ApexLocalTest_\(UUID().uuidString)"
        
        // 1. Create directory
        try await session.createDirectory(remotePath: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir))
        
        // 2. Create file
        let testFilePath = tempDir + "/sample.txt"
        try await session.createFile(remotePath: testFilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testFilePath))
        
        // 3. Rename file
        let renamedPath = tempDir + "/renamed.txt"
        try await session.rename(oldPath: testFilePath, newPath: renamedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedPath))
        
        // 4. List directory contents
        let items = try await session.listDirectory(path: tempDir)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "renamed.txt")
        
        // 5. Change permissions
        try await session.changePermissions(remotePath: renamedPath, permissions: "755")
        let attrs = try FileManager.default.attributesOfItem(atPath: renamedPath)
        let perms = (attrs[.posixPermissions] as? UInt32) ?? 0
        XCTAssertEqual(perms, 0o755)
        
        // 6. Delete file
        try await session.removeFile(remotePath: renamedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedPath))
        
        // 7. Delete directory
        try await session.removeDirectory(remotePath: tempDir, recursive: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir))
    }
    
    @MainActor
    func testLocalSessionSplitPaneCreationAndIndependence() async throws {
        let local = Session.local(name: "本机 Shell")
        let client = LocalTerminalSession(session: local)
        let tab = TerminalTabItem(session: local, sshClient: client)
        
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertEqual(tab.splitMode, .single)
        XCTAssertEqual(tab.activePane?.title, "本机 Shell")
        
        tab.split(mode: .vertical)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.splitMode, .vertical)
        XCTAssertTrue(tab.panes[1].title.contains("分屏"))
        XCTAssertTrue(tab.panes[1].sshClient is LocalTerminalSession)
        
        // Clean up
        tab.closePane(id: tab.panes[1].id)
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertEqual(tab.splitMode, .single)
    }
    
    @MainActor
    func testBroadcastWithMixedLocalAndRemoteSessions() async throws {
        let local = Session.local(name: "本机")
        let localClient = LocalTerminalSession(session: local)
        let localTab = TerminalTabItem(session: local, sshClient: localClient)
        
        let remote = Session(name: "远端", host: "192.0.2.10", username: "root")
        let remoteClient = MockSSHSession(session: remote)
        let remoteTab = TerminalTabItem(session: remote, sshClient: remoteClient)
        
        try await remoteClient.connect()
        
        let tabs = [localTab, remoteTab]
        XCTAssertEqual(tabs.count, 2)
        
        // Verify both can receive broadcast input safely
        let testData = Data("echo 'Broadcast_OK'\n".utf8)
        for t in tabs {
            for p in t.panes {
                try await p.sshClient.sendInput(testData)
            }
        }
        
        await remoteClient.disconnect()
    }
}
