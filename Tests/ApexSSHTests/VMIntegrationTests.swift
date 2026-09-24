import XCTest
import Foundation
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class VMIntegrationTests: XCTestCase {
    
    let vmHost = "100.64.0.3"
    let vmUser = "chenxu"
    let vmPassword = "chenyn"
    
    var vmSession: Session {
        Session(
            name: "macmini-vm",
            host: vmHost,
            port: 22,
            username: vmUser,
            authMethod: .password(keychainRef: vmPassword),
            folder: "Production",
            tags: ["macmini", "vm", "m-series"],
            agentlessMonitorEnabled: true,
            sftpAutoSyncEnabled: true
        )
    }
    
    // MARK: - Test 1: Real Agentless Metrics Probe
    func testVMRealAgentlessMetricsCollection() async throws {
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
        
        print("📊 VM Metrics Snapshot: CPU=\(snapshot.cpuUsagePercent)%, Cores=\(snapshot.cpuCores), MemoryUsed=\(snapshot.memoryUsedBytes / (1024*1024))MB, DiskUsed=\(snapshot.diskUsedBytes / (1024*1024*1024))GB")
        
        XCTAssertGreaterThan(snapshot.cpuCores, 0)
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.memoryUsedBytes, 0)
        XCTAssertGreaterThan(snapshot.diskTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.uptimeSeconds, 0)
    }
    
    // MARK: - Test 2: Real SFTP Directory Listing & File Transfer Integrity
    func testVMRealSFTPDirectoryListingAndTransfer() async throws {
        let sshClient = NativeSSHSession(session: vmSession)
        
        // 1. List directory
        let items = try await sshClient.listDirectory(path: "/Users/chenxu")
        XCTAssertFalse(items.isEmpty, "Directory listing of /Users/chenxu should contain items")
        
        let hasExpectedDir = items.contains { $0.name == "Desktop" || $0.name == "Documents" || $0.name == "Downloads" || $0.name == "Library" }
        XCTAssertTrue(hasExpectedDir, "Listing should contain standard macOS user directories")
        
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
    
    // MARK: - Test 3: Real SSH Darwin PTY Interactive Session
    func testVMRealSSHPTYInteractiveSession() async throws {
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
                if outputBox.contains("chenxus-Mac-mini") || outputBox.contains("Darwin") || outputBox.contains("Last login") || outputBox.contains("%") || outputBox.contains("$") {
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
        try await Task.sleep(nanoseconds: 500_000_000)
        
        XCTAssertTrue(outputBox.contains("arm64") || outputBox.contains("Darwin") || outputBox.contains("Last login") || outputBox.contains("chenxu"))
        
        await sshClient.disconnect()
        XCTAssertEqual(sshClient.connectionState, .disconnected)
    }
    
    // MARK: - Test 4: Verify Remote Disk Space Cleanliness
    func testVMDiskCleanlinessVerification() throws {
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
        print("💾 Installed App Size on VM: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        XCTAssertTrue(output.contains("ApexTerm.app"))
        XCTAssertFalse(output.contains("G\t"), "Installed size should be in MBs, definitely not GBs!")
    }
}
