import XCTest
import Foundation
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class PublicServerIntegrationTests: XCTestCase {
    
    let serverHost = "43.155.167.224"
    let serverUser = "ubuntu"
    let serverPassword = "Chen6185$$"
    
    var publicSession: Session {
        Session(
            name: "ubuntu-public-server",
            host: serverHost,
            port: 22,
            username: serverUser,
            authMethod: .password(keychainRef: serverPassword),
            folder: "生产环境",
            tags: ["ubuntu", "tencent-cloud", "public"],
            agentlessMonitorEnabled: true,
            sftpAutoSyncEnabled: true
        )
    }
    
    // MARK: - Test 1: Real SSH PTY Interactive Session to 43.155.167.224
    func testPublicServerSSHInteractiveSession() async throws {
        let sshClient = NativeSSHSession(session: publicSession)
        
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
            func currentText() -> String {
                lock.lock()
                defer { lock.unlock() }
                return text
            }
        }
        
        let outputBox = OutputBox()
        let promptExpectation = expectation(description: "Receive shell banner and prompt from 43.155.167.224")
        
        sshClient.setOutputHandler { data in
            if let str = String(data: data, encoding: .utf8) {
                outputBox.append(str)
                if outputBox.contains("ubuntu") || outputBox.contains("Linux") || outputBox.contains("$") || outputBox.contains("Welcome") {
                    if outputBox.markFulfilled() {
                        promptExpectation.fulfill()
                    }
                }
            }
        }
        
        try await sshClient.connect()
        XCTAssertEqual(sshClient.connectionState, .connected)
        
        await fulfillment(of: [promptExpectation], timeout: 8.0)
        
        // Send remote command
        try await sshClient.sendInput("uname -a\r\n".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: 800_000_000)
        
        XCTAssertTrue(outputBox.contains("Linux") || outputBox.contains("ubuntu"))
        
        // Verify TERM environment variable is properly exported to remote shell
        try await sshClient.sendInput("echo TERM_CHECK_$TERM\r\n".data(using: .utf8)!)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(outputBox.contains("TERM_CHECK_xterm-256color"), "Expected remote TERM to be xterm-256color, output was: \(outputBox.currentText())")
        
        await sshClient.disconnect()
        XCTAssertEqual(sshClient.connectionState, .disconnected)
    }
    
    // MARK: - Test 2: Real Agentless Linux Server Metrics Collection
    func testPublicServerAgentlessMetrics() async throws {
        let monitor = AgentlessMonitor()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sshpass")
        process.arguments = [
            "-p", serverPassword,
            "/usr/bin/ssh",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=5",
            "-p", "22",
            "\(serverUser)@\(serverHost)",
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
        
        print("📊 43.155.167.224 Linux Metrics: CPU=\(snapshot.cpuUsagePercent)%, Cores=\(snapshot.cpuCores), MemoryTotal=\(snapshot.memoryTotalBytes / (1024*1024))MB, DiskUsed=\(snapshot.diskUsedBytes / (1024*1024*1024))GB")
        
        XCTAssertGreaterThan(snapshot.cpuCores, 0)
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.diskTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.uptimeSeconds, 0)
    }
    
    // MARK: - Test 3: Real SFTP Directory Listing on /home/ubuntu
    func testPublicServerSFTPListingAndTransfer() async throws {
        let sshClient = NativeSSHSession(session: publicSession)
        
        // 1. List /home/ubuntu
        let items = try await sshClient.listDirectory(path: "/home/ubuntu")
        XCTAssertFalse(items.isEmpty, "Directory listing of /home/ubuntu should contain items")
        
        // 2. Prepare test file
        let testString = "ApexTerm 43.155.167.224 Integration Test Payload - \(UUID().uuidString)\nTimestamp: \(Date())\n"
        let localTempURL = FileManager.default.temporaryDirectory.appendingPathComponent("apexterm_ubuntu_upload.txt")
        let localDownloadedURL = FileManager.default.temporaryDirectory.appendingPathComponent("apexterm_ubuntu_download.txt")
        let remotePath = "/tmp/apexterm_test_\(UUID().uuidString).txt"
        
        try testString.write(to: localTempURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: localTempURL)
            try? FileManager.default.removeItem(at: localDownloadedURL)
        }
        
        // 3. Upload file
        try await sshClient.uploadFile(localURL: localTempURL, remotePath: remotePath, progress: { _ in })
        
        // 4. Download file
        try await sshClient.downloadFile(remotePath: remotePath, localURL: localDownloadedURL, progress: { _ in })
        
        // 5. Verify payload matches
        let downloadedContent = try String(contentsOf: localDownloadedURL, encoding: .utf8)
        XCTAssertEqual(testString, downloadedContent, "Downloaded content must match uploaded payload")
        
        // 6. Remote cleanup
        let cleanupProcess = Process()
        cleanupProcess.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sshpass")
        cleanupProcess.arguments = [
            "-p", serverPassword,
            "/usr/bin/ssh",
            "\(serverUser)@\(serverHost)",
            "rm -f \(remotePath)"
        ]
        try cleanupProcess.run()
        cleanupProcess.waitUntilExit()
        XCTAssertEqual(cleanupProcess.terminationStatus, 0)
    }
    
    // MARK: - Test 4: Real Shell Directory Syncing (cd /tmp -> directoryChangeHandler)
    func testPublicServerDirectoryChangeSync() async throws {
        let sshClient = NativeSSHSession(session: publicSession)
        
        final class PathBox: @unchecked Sendable {
            private let lock = NSLock()
            private var lastPath = ""
            private var fulfilled = false
            func set(_ p: String) {
                lock.lock()
                defer { lock.unlock() }
                lastPath = p
            }
            func get() -> String {
                lock.lock()
                defer { lock.unlock() }
                return lastPath
            }
            func markFulfilled() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if fulfilled { return false }
                fulfilled = true
                return true
            }
        }
        
        let pathBox = PathBox()
        let tmpExpectation = expectation(description: "Directory sync to /tmp")
        
        sshClient.setDirectoryChangeHandler { path in
            pathBox.set(path)
            if path == "/tmp" {
                if pathBox.markFulfilled() {
                    tmpExpectation.fulfill()
                }
            }
        }
        
        try await sshClient.connect()
        XCTAssertEqual(sshClient.connectionState, .connected)
        
        // Wait 1.5s for initial shell prompt
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Send cd /tmp
        try await sshClient.sendInput("cd /tmp\r\n".data(using: .utf8)!)
        
        await fulfillment(of: [tmpExpectation], timeout: 6.0)
        XCTAssertEqual(pathBox.get(), "/tmp")
        
        await sshClient.disconnect()
    }
}
