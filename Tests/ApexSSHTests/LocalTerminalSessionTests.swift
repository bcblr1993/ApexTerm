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
    
    func testLocalTerminalEnvironmentAndOutput() async throws {
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
        
        let local = Session.local(name: "Env Test")
        let session = LocalTerminalSession(session: local)
        let collector = OutputCollector()
        let envExpectation = expectation(description: "Environment output received")
        envExpectation.assertForOverFulfill = false
        
        session.setOutputHandler { data in
            let text = collector.append(data)
            if text.contains("APEX_ENV_TERM=xterm-256color") && text.contains("APEX_ENV_COLORTERM=truecolor") {
                envExpectation.fulfill()
            }
        }
        
        try await session.connect()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let cmd = "echo \"APEX_ENV_TERM=$TERM APEX_ENV_COLORTERM=$COLORTERM\"\n"
        try await session.sendInput(Data(cmd.utf8))
        
        await fulfillment(of: [envExpectation], timeout: 5.0)
        await session.disconnect()
    }
    
    func testLocalTerminalWorkingDirectoryAndPathExpansion() async throws {
        // 1. Test expandPath
        let home = NSHomeDirectory()
        XCTAssertEqual(LocalTerminalSession.expandPath("~"), home)
        XCTAssertEqual(LocalTerminalSession.expandPath("~/Documents"), home + "/Documents")
        XCTAssertEqual(LocalTerminalSession.expandPath("/tmp"), "/tmp")
        
        // 2. Test directory listing of expanded path
        let session = LocalTerminalSession()
        let items = try await session.listDirectory(path: "~")
        XCTAssertFalse(items.isEmpty)
    }
    
    func testLocalTerminalInterruptSignal() async throws {
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
        
        let session = LocalTerminalSession()
        let collector = OutputCollector()
        let readyExp = expectation(description: "Prompt ready")
        readyExp.assertForOverFulfill = false
        
        session.setOutputHandler { data in
            let text = collector.append(data)
            if text.contains("WAITING_FOR_INTERRUPT") {
                readyExp.fulfill()
            }
        }
        
        try await session.connect()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Send a command that sleeps, then send Ctrl+C (0x03)
        let cmd = "echo 'WAITING_FOR_INTERRUPT'; sleep 10\n"
        try await session.sendInput(Data(cmd.utf8))
        await fulfillment(of: [readyExp], timeout: 5.0)
        
        // Send Ctrl+C
        try await session.sendInput(Data([0x03]))
        
        // Ensure session remains connected and responsive
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(session.connectionState, .connected)
        
        await session.disconnect()
    }
    
    func testLocalTerminalShellExitHandling() async throws {
        let session = LocalTerminalSession()
        let disconnectedExp = expectation(description: "Session disconnected after shell exit")
        disconnectedExp.assertForOverFulfill = false
        
        session.setStateChangeHandler { state in
            if state == .disconnected {
                disconnectedExp.fulfill()
            }
        }
        
        try await session.connect()
        XCTAssertEqual(session.connectionState, .connected)
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Send exit command to shell
        try await session.sendInput(Data("exit\n".utf8))
        
        await fulfillment(of: [disconnectedExp], timeout: 5.0)
        XCTAssertEqual(session.connectionState, .disconnected)
    }
    
    func testLocalSessionPropertiesAndDefaults() {
        let s1 = Session.local()
        XCTAssertEqual(s1.sessionType, .local)
        XCTAssertTrue(s1.isLocal)
        XCTAssertEqual(s1.host, "localhost")
        XCTAssertEqual(s1.port, 0)
        XCTAssertEqual(s1.username, NSUserName())
        XCTAssertEqual(s1.name, "本地终端")
        XCTAssertFalse(s1.id.uuidString.isEmpty)
        
        let customName = Session.local(name: "My Custom Local Shell")
        XCTAssertEqual(customName.name, "My Custom Local Shell")
        XCTAssertTrue(customName.isLocal)
        XCTAssertNotEqual(s1.id, customName.id, "Each Session.local() call must produce a unique UUID")
    }
    
    func testLocalMetricsCollection() async throws {
        let monitor = AgentlessMonitor()
        let command = AgentlessMonitor.macosProbeCommand
        
        // Execute the probe command locally
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(output.isEmpty, "macOS probe command should produce non-empty output")
        
        var net: AgentlessMonitor.NetTickState? = nil
        let snapshot = monitor.parseMacOSOutput(output, prevNet: &net)
        
        XCTAssertGreaterThanOrEqual(snapshot.cpuUsagePercent, 0.0, "CPU usage should be parsed from top")
        XCTAssertLessThanOrEqual(snapshot.cpuUsagePercent, 100.0, "CPU usage cannot exceed 100%")
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0, "Total memory must be greater than 0")
        XCTAssertGreaterThan(snapshot.memoryUsedBytes, 0, "Used memory must be greater than 0")
        XCTAssertGreaterThan(snapshot.diskTotalBytes, 0, "Total disk size must be greater than 0")
    }
    
    func testLocalFileSystemEdgeCases() async throws {
        let session = LocalTerminalSession()
        
        // 1. Listing non-existent directory must throw error
        do {
            _ = try await session.listDirectory(path: "/non_existent_dir_apex_12345")
            XCTFail("Listing non-existent directory must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("目录不存在") || (error as NSError).code == 2)
        }
        
        // 2. Invalid permissions octal string must throw error
        let tempFile = NSTemporaryDirectory() + "ApexPermTest_\(UUID().uuidString).txt"
        try await session.createFile(remotePath: tempFile)
        defer { try? FileManager.default.removeItem(atPath: tempFile) }
        
        do {
            try await session.changePermissions(remotePath: tempFile, permissions: "invalid_perm")
            XCTFail("Invalid octal permissions must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("无效的权限代码") || (error as NSError).code == 4)
        }
    }
    
    func testLocalTerminalHighThroughputPTY() async throws {
        final class ByteCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var totalBytes = 0
            func add(_ count: Int) -> Int {
                lock.withLock {
                    totalBytes += count
                    return totalBytes
                }
            }
        }
        
        let session = LocalTerminalSession()
        let counter = ByteCounter()
        let throughputExp = expectation(description: "Received at least 50KB through PTY")
        throughputExp.assertForOverFulfill = false
        
        session.setOutputHandler { data in
            if counter.add(data.count) >= 50_000 {
                throughputExp.fulfill()
            }
        }
        
        try await session.connect()
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Flood with ~1500 lines
        let floodCmd = "for i in $(seq 1 1500); do echo \"[ApexLocalThroughput-$i] abcdefghijklmnopqrstuvwxyz0123456789\"; done\n"
        try await session.sendInput(Data(floodCmd.utf8))
        
        await fulfillment(of: [throughputExp], timeout: 8.0)
        await session.disconnect()
    }
}
