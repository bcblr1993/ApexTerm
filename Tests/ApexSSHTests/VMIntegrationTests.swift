import XCTest
import Foundation
import Darwin
import CryptoKit
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

final class VMIntegrationTests: XCTestCase {
    
    private var vmHost: String {
        ProcessInfo.processInfo.environment["APEX_TEST_VM_HOST"] ?? ""
    }
    private var vmUser: String {
        ProcessInfo.processInfo.environment["APEX_TEST_VM_USER"] ?? ""
    }
    private var vmPassword: String {
        ProcessInfo.processInfo.environment["APEX_TEST_VM_PASSWORD"] ?? ""
    }
    
    private func requireVMConfig() throws {
        guard !vmHost.isEmpty, !vmUser.isEmpty else {
            throw XCTSkip("Skipping live VM integration test: APEX_TEST_VM_* environment variables not set.")
        }
    }
    
    var vmSession: Session {
        Session(
            name: "vm-integration-target",
            host: vmHost,
            port: 22,
            username: vmUser,
            authMethod: .password(keychainRef: vmPassword),
            folder: "Testing",
            tags: ["vm", "integration-test"],
            agentlessMonitorEnabled: true,
            sftpAutoSyncEnabled: true
        )
    }
    
    func testVMVimEditingResizeAndSavedFileContents() async throws {
        try requireVMConfig()
        var config = vmSession
        config.agentlessMonitorEnabled = false
        let client = NativeSSHSession(session: config)
        let buffer = TerminalRingBuffer()
        buffer.setDimensions(columns: 80, rows: 24)
        client.setOutputHandler { buffer.appendData($0) }
        let directory = "/tmp/apex-vim-" + UUID().uuidString
        let path = directory + "/vim.txt"
        func waitFor(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !predicate() && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(predicate(), "Remote Vim did not reach the expected state")
        }
        do {
            try await client.createDirectory(remotePath: directory)
            try await client.connect()
            try await client.sendInput(Data("printf '\\nAPEX_VIM_READY\\n'\r".utf8))
            try await waitFor { buffer.allLines().contains("APEX_VIM_READY") }
            try await client.sendInput(Data("vim -Nu NONE -n '\(path)'\r".utf8))
            try await waitFor { buffer.isInAlternateScreen }
            XCTAssertFalse(buffer.isCursorHidden)
            try await client.sendInput(Data("i中文\rtwo\rthree\u{1B}".utf8))
            try await waitFor { buffer.screenLines?.contains(where: { $0.contains("three") }) == true }
            // Exercise the application-cursor arrow encoding used by the AppKit key path.
            let left = buffer.isApplicationCursorKeys ? "\u{1B}OD" : "\u{1B}[D"
            try await client.sendInput(Data((left + "rx").utf8))
            // Verify the remote acknowledgement, not just the local buffer size.
            for (columns, rows) in [(60, 18), (90, 32), (70, 21)] {
                buffer.setDimensions(columns: columns, rows: rows)
                try await client.resizeTerminal(columns: columns, rows: rows)
                try await Task.sleep(for: .milliseconds(300))
                try await client.sendInput(Data("\u{1B}:set lines? columns?\r".utf8))
                try await waitFor {
                    let screen = buffer.screenLines?.joined(separator: "\n") ?? ""
                    return screen.contains("lines=\(rows)") && screen.contains("columns=\(columns)")
                }
                try await client.sendInput(Data("\r".utf8))
            }
            try await client.sendInput(Data("\r\u{1B}:wq\r".utf8))
            try await waitFor { !buffer.isInAlternateScreen }
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: local) }
            try await client.downloadFile(remotePath: path, localURL: local, progress: { _ in })
            XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "中文\ntwo\nthrxe\n")
            await client.disconnect()
            try await client.removeFile(remotePath: path)
            try await client.removeDirectory(remotePath: directory, recursive: false)
        } catch {
            await client.disconnect()
            try? await client.removeFile(remotePath: path)
            try? await client.removeDirectory(remotePath: directory, recursive: false)
            throw error
        }
    }

    func testVMUnicodeSpacesQuotesAndShellMetacharacterFileTransfer() async throws {
        try requireVMConfig()
        let client = NativeSSHSession(session: vmSession)
        let directory = "/tmp/apex-transfer-" + UUID().uuidString
        try await client.createDirectory(remotePath: directory)
        let localDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let name = "中文  'single' \"double\" $literal ; end.txt"
        let source = localDirectory.appendingPathComponent(name)
        let downloaded = localDirectory.appendingPathComponent("downloaded.txt")
        let payload = Data("Unicode file transfer \n中文🚀\n".utf8)
        try payload.write(to: source)
        let path = directory + "/" + name
        do {
            try await client.uploadFile(localURL: source, remotePath: path, progress: { _ in })
            let entries = try await client.listDirectory(path: directory)
            XCTAssertTrue(entries.contains(where: { $0.name == name }))
            try await client.downloadFile(remotePath: path, localURL: downloaded, progress: { _ in })
            XCTAssertEqual(try Data(contentsOf: downloaded), payload)
        } catch {
            try? await client.removeFile(remotePath: path)
            try? await client.removeDirectory(remotePath: directory, recursive: false)
            throw error
        }
        try await client.removeFile(remotePath: path)
        try await client.removeDirectory(remotePath: directory, recursive: false)
    }

    // MARK: - Test 1: Real Agentless Metrics Probe
    func testVMRealAgentlessMetricsCollection() async throws {
        try requireVMConfig()
        let monitor = AgentlessMonitor()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sshpass")
        process.arguments = [
            "-p", vmPassword,
            "/usr/bin/ssh",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=5",
            "-p", "22",
            "\(vmUser)@\(vmHost)",
            AgentlessMonitor.autoProbeCommand
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        
        XCTAssertEqual(process.terminationStatus, 0, "SSH probe should execute with exit code 0")
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(output.isEmpty, "Probe output should not be empty")
        
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil
        let snapshot = monitor.parseOutput(output, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertGreaterThan(snapshot.cpuCores, 0)
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.memoryUsedBytes, 0)
        XCTAssertGreaterThan(snapshot.diskTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.uptimeSeconds, 0)
    }
    
    func testVMHomeListingResolvesTildeToActualAbsoluteDirectory() async throws {
        try requireVMConfig()
        let client = NativeSSHSession(session: vmSession)
        let probedHome = await client.probeRemoteHome()
        let home = try XCTUnwrap(probedHome)
        XCTAssertTrue(home.hasPrefix("/"))
        let absolute = try await client.listDirectory(path: home)
        let shorthand = try await client.listDirectory(path: "~")
        XCTAssertEqual(Set(absolute.map(\.path)), Set(shorthand.map(\.path)))
        XCTAssertTrue(shorthand.allSatisfy { $0.path.hasPrefix(home + "/") })
        let trailingSlash = try await client.listDirectory(path: "~/")
        XCTAssertEqual(Set(absolute.map(\.path)), Set(trailingSlash.map(\.path)))
    }

    // MARK: - Test 2: Real SFTP Directory Listing & File Transfer Integrity
    func testVMRealSFTPDirectoryListingAndTransfer() async throws {
        try requireVMConfig()
        let sshClient = NativeSSHSession(session: vmSession)
        
        // 1. List directory
        let items = try await sshClient.listDirectory(path: "/tmp")
        XCTAssertFalse(items.isEmpty, "Directory listing of /tmp should contain items")
        
        // 2. Prepare test payload
        let testString = "ApexTerm Real VM Integration Test Payload - \(UUID().uuidString)\nApple Silicon Native SSH Client & Metrics Engine\nTimestamp: \(Date())\n"
        let localTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("apexterm_upload_test.txt")
        let localDownloadedURL = FileManager.default.temporaryDirectory.appendingPathComponent("apexterm_download_test.txt")
        let remotePath = "/tmp/apexterm_test_payload_\(UUID().uuidString).txt"
        
        try testString.write(to: localTempURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: localTempURL)
            try? FileManager.default.removeItem(at: localDownloadedURL)
        }
        
        // 3. Upload file
        try await sshClient.uploadFile(localURL: localTempURL, remotePath: remotePath, progress: { _ in })
        
        // 4. Download file
        try await sshClient.downloadFile(remotePath: remotePath, localURL: localDownloadedURL, progress: { _ in })
        
        // 5. Verify contents & integrity
        let downloadedContent = try String(contentsOf: localDownloadedURL, encoding: .utf8)
        XCTAssertEqual(testString, downloadedContent, "Downloaded content must match uploaded payload exactly")
        
        // 6. Clean up remote file on VM to avoid disk bloat
        let cleanupProcess = Process()
        cleanupProcess.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sshpass")
        cleanupProcess.arguments = [
            "-p", vmPassword,
            "/usr/bin/ssh",
            "\(vmUser)@\(vmHost)",
            "rm -f \(remotePath)"
        ]
        try cleanupProcess.run()
        cleanupProcess.waitUntilExit()
        XCTAssertEqual(cleanupProcess.terminationStatus, 0)
    }

    @MainActor
    func testVMLargeRemoteFileDragExportCompletesWithMatchingHash() async throws {
        try requireVMConfig()
        let client = NativeSSHSession(session: vmSession)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        let remote = "/tmp/apexterm-large-drag-\(UUID().uuidString).bin"
        let bytes = 64 * 1024 * 1024
        let block = Data(repeating: 0x5a, count: 1024 * 1024)
        _ = FileManager.default.createFile(atPath: local.path, contents: nil)
        let writer = try FileHandle(forWritingTo: local)
        for _ in 0..<64 { try writer.write(contentsOf: block) }
        try writer.close()
        defer { try? FileManager.default.removeItem(at: local) }

        try await client.uploadFile(localURL: local, remotePath: remote) { _ in }
        defer { Task { try? await client.removeFile(remotePath: remote) } }

        let item = SFTPItem(name: (remote as NSString).lastPathComponent, path: remote,
                            isDirectory: false, size: UInt64(bytes))
        let provider = SFTPDragExportHelper.makeItemProvider(for: item, session: client)
        let completed = expectation(description: "64 MiB drag export finishes")
        let expectedHash = try Self.sha256(of: local)
        let loadProgress = provider.loadFileRepresentation(forTypeIdentifier: "public.file-url") { url, error in
            defer { completed.fulfill() }
            XCTAssertNil(error)
            guard let url else { XCTFail("Finder file representation was empty"); return }
            do {
                let actualHash = try Self.sha256(of: url)
                XCTAssertEqual(actualHash, expectedHash)
            } catch { XCTFail("Cannot hash exported file: \(error)") }
        }
        await fulfillment(of: [completed], timeout: 120)
        if !loadProgress.isFinished { loadProgress.cancel() }
        let record = try XCTUnwrap(TransferManager.shared.tasks.first { $0.remotePath == remote })
        XCTAssertEqual(record.status, .completed)
        try await client.removeFile(remotePath: remote)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    
    func testVMFileOperationsPreserveLiteralNamesAndReportMissingDirectory() async throws {
        try requireVMConfig()
        let client = NativeSSHSession(session: vmSession)
        let root = "/tmp/apexterm-literal-" + UUID().uuidString
        let name = "引号' $() ; 文件.txt"
        let original = root + "/" + name
        let renamed = root + "/重命名' $() .txt"
        try await client.createDirectory(remotePath: root)
        do {
            try await client.createFile(remotePath: original)
            let created = try await client.listDirectory(path: root)
            XCTAssertTrue(created.contains { $0.name == name })
            try await client.rename(oldPath: original, newPath: renamed)
            try await client.changePermissions(remotePath: renamed, permissions: "600")
            let changed = try await client.listDirectory(path: root)
            XCTAssertTrue(changed.contains { $0.path == renamed && $0.permissionString == "-rw-------" })
            try await client.removeFile(remotePath: renamed)
            let empty = try await client.listDirectory(path: root)
            XCTAssertTrue(empty.isEmpty)
            do {
                _ = try await client.listDirectory(path: root + "/missing")
                XCTFail("Missing directories must surface a failure instead of an empty folder")
            } catch { XCTAssertNotEqual((error as NSError).code, 0) }
            try await client.removeDirectory(remotePath: root, recursive: false)
        } catch {
            try? await client.removeDirectory(remotePath: root, recursive: true)
            throw error
        }
    }

    // MARK: - Test 3: Real SSH Darwin PTY Interactive Session
    func testVMRealSSHPTYInteractiveSession() async throws {
        try requireVMConfig()
        let sshClient = NativeSSHSession(session: vmSession)
        
        final class OutputBox: @unchecked Sendable {
            private let lock = NSLock()
            private var text = ""
            private var fulfilled = false
            func append(_ str: String) {
                lock.lock()
                defer { lock.unlock() }
                text.append(str)
            }
            func contains(_ substring: String) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return text.contains(substring)
            }
            func markFulfilled() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if fulfilled { return false }
                fulfilled = true
                return true
            }
        }
        
        let outputBox = OutputBox()
        let outputExpectation = expectation(description: "Receive output from remote VM PTY")
        
        sshClient.setOutputHandler { data in
            if let str = String(data: data, encoding: .utf8) {
                outputBox.append(str)
                if outputBox.contains("Darwin") || outputBox.contains("Last login") || outputBox.contains("%") || outputBox.contains("$") {
                    if outputBox.markFulfilled() {
                        outputExpectation.fulfill()
                    }
                }
            }
        }
        
        try await sshClient.connect()
        XCTAssertEqual(sshClient.connectionState, .connected)
        
        await fulfillment(of: [outputExpectation], timeout: 8.0)
        
        // Send remote command via PTY
        try await sshClient.sendInput("uname -m\r\n".data(using: .utf8)!)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline && !(outputBox.contains("arm64") || outputBox.contains("Darwin") || outputBox.contains("x86_64")) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        
        XCTAssertTrue(outputBox.contains("arm64") || outputBox.contains("Darwin") || outputBox.contains("x86_64"))
        
        await sshClient.disconnect()
        XCTAssertEqual(sshClient.connectionState, .disconnected)
    }
    
    func testVMDisconnectReapsThePTYChildProcess() async throws {
        try requireVMConfig()
        func children() -> Set<pid_t> {
            var pids = [pid_t](repeating: 0, count: 64)
            let count = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
            return Set(pids.prefix(max(0, Int(count))).filter { $0 > 0 })
        }
        let before = children()
        let client = NativeSSHSession(session: vmSession)
        try await client.connect()
        let ptyChildren = children().subtracting(before)
        XCTAssertFalse(ptyChildren.isEmpty, "The real PTY must spawn a child before validating cleanup")
        await client.disconnect()
        await client.disconnect()
        for pid in ptyChildren {
            XCTAssertEqual(kill(pid, 0), -1, "Disconnected PTY child must not survive")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    // MARK: - Test 4: Verify Remote Disk Space Cleanliness
    func testVMDiskCleanlinessVerification() throws {
        try requireVMConfig()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sshpass")
        process.arguments = [
            "-p", vmPassword,
            "/usr/bin/ssh",
            "\(vmUser)@\(vmHost)",
            "du -sh /Applications/ApexTerm.app"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("ApexTerm.app"))
        XCTAssertFalse(output.contains("G\t"), "Installed size should be in MBs, definitely not GBs!")
    }
}
