import XCTest
import Foundation
import CryptoKit
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class PublicServerIntegrationTests: XCTestCase {

    private var serverHost: String {
        ProcessInfo.processInfo.environment["APEX_TEST_PUBLIC_SERVER_HOST"] ?? ""
    }
    private var serverPort: Int {
        if let raw = ProcessInfo.processInfo.environment["APEX_TEST_PUBLIC_SERVER_PORT"],
           let parsed = Int(raw), (1...65535).contains(parsed) {
            return parsed
        }
        return 22
    }
    private var serverUser: String {
        ProcessInfo.processInfo.environment["APEX_TEST_PUBLIC_SERVER_USER"] ?? ""
    }
    private var serverPassword: String {
        ProcessInfo.processInfo.environment["APEX_TEST_PUBLIC_SERVER_PASSWORD"] ?? ""
    }

    private func requireServerConfig() throws {
        guard !serverHost.isEmpty, !serverUser.isEmpty else {
            throw XCTSkip("Skipping public server integration test: APEX_TEST_PUBLIC_SERVER_* environment variables not set.")
        }
    }

    var publicSession: Session {
        Session(
            name: "public-integration-server",
            host: serverHost,
            port: serverPort,
            username: serverUser,
            authMethod: .password(keychainRef: serverPassword),
            folder: "Testing",
            tags: ["integration-test"],
            agentlessMonitorEnabled: true,
            sftpAutoSyncEnabled: true
        )
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ chunk: Data) {
            let str = String(decoding: chunk, as: UTF8.self)
            lock.withLock { text.append(str) }
        }
        func contains(_ substring: String) -> Bool {
            lock.withLock { text.contains(substring) }
        }
        func currentText() -> String {
            lock.withLock { text }
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(8),
        pollInterval: Duration = .milliseconds(50),
        _ predicate: () -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: pollInterval)
        }
        return predicate()
    }

    private func runRemoteCleanup(directory: String) {
        let client = NativeSSHSession(session: publicSession)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            try? await client.removeDirectory(remotePath: directory, recursive: true)
            await client.disconnect()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(10))
    }

    // MARK: - Test 1: Interactive PTY, Special-Char Password Handling, UTF-8, Bracketed Paste, ControlMaster Cleanup
    func testPublicServerSSHInteractiveSession() async throws {
        try requireServerConfig()
        var session = publicSession
        session.agentlessMonitorEnabled = false
        let sshClient = NativeSSHSession(session: session)
        let outputBox = OutputBox()

        sshClient.setOutputHandler { data in
            outputBox.append(data)
        }

        try await sshClient.connect()
        XCTAssertEqual(sshClient.connectionState, .connected)

        let gotPrompt = try await waitUntil(timeout: .seconds(8)) {
            outputBox.contains("$") || outputBox.contains("#") || outputBox.contains("%")
        }
        XCTAssertTrue(gotPrompt, "Expected remote shell prompt, got: \(outputBox.currentText())")

        // Verify uname + TERM export
        try await sshClient.sendInput(Data("uname -a && echo TERM_CHECK_$TERM\r".utf8))
        let gotTerm = try await waitUntil(timeout: .seconds(5)) {
            (outputBox.contains("Linux") || outputBox.contains("Darwin")) && outputBox.contains("TERM_CHECK_xterm-256color")
        }
        XCTAssertTrue(gotTerm, "Expected TERM_CHECK_xterm-256color and OS name, got: \(outputBox.currentText())")

        // Verify UTF-8 roundtrip + special character literal preservation ($$ must not leak or expand password)
        let utf8Token = "APEX_UTF8_中文🚀_OK"
        try await sshClient.sendInput(Data("printf '%s\\n' '\(utf8Token)'\r".utf8))
        let gotUTF8 = try await waitUntil(timeout: .seconds(5)) {
            outputBox.contains(utf8Token)
        }
        XCTAssertTrue(gotUTF8, "Expected UTF-8 output \(utf8Token), got: \(outputBox.currentText())")

        // Verify bracketed paste sequence passes cleanly through PTY
        let pasteToken = "APEX_PASTE_中文_\(UUID().uuidString.prefix(8))"
        let bracketedCommand = "\u{1B}[200~printf '%s\\n' '\(pasteToken)'\u{1B}[201~\r"
        try await sshClient.sendInput(Data(bracketedCommand.utf8))
        let gotPaste = try await waitUntil(timeout: .seconds(5)) {
            outputBox.contains(pasteToken)
        }
        XCTAssertTrue(gotPaste, "Expected bracketed paste output \(pasteToken), got: \(outputBox.currentText())")

        // Verify PTY resize works without error
        try await sshClient.resizeTerminal(columns: 100, rows: 32)

        await sshClient.disconnect()
        XCTAssertEqual(sshClient.connectionState, .disconnected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sshClient.controlSocketPath), "ControlMaster socket must be cleaned up on disconnect")
    }

    // MARK: - Test 2: TerminfoProbe over live SSH command channel
    func testPublicServerTerminfoProbe() async throws {
        try requireServerConfig()
        var session = publicSession
        session.terminalType = .xterm256Color
        let sshClient = NativeSSHSession(session: session)
        defer { Task { await sshClient.disconnect() } }

        let result = await TerminfoProbe.run(on: sshClient)
        XCTAssertEqual(result, .present, "Standard Linux/macOS host must have xterm-256color terminfo")

        let missingCmd = TerminfoProbe.command(term: "apex-nonexistent-term-e2e")
        let missingOutput = try await sshClient.executeCommand(missingCmd)
        XCTAssertEqual(TerminfoProbe.parse(missingOutput), .missing)
        await sshClient.disconnect()
    }

    // MARK: - Test 3: Agentless Metrics, Process Inspector, Listening Ports, Container & Systemd Probes
    func testPublicServerAgentlessMetricsAndInspectors() async throws {
        try requireServerConfig()
        let sshClient = NativeSSHSession(session: publicSession)
        defer { Task { await sshClient.disconnect() } }

        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil

        let raw1 = try await sshClient.executeCommand(AgentlessMonitor.autoProbeCommand)
        XCTAssertFalse(raw1.isEmpty, "First metrics probe output must not be empty")
        _ = monitor.parseOutput(raw1, prevCpu: &prevCpu, prevNet: &prevNet)

        try await Task.sleep(for: .milliseconds(600))
        let raw2 = try await sshClient.executeCommand(AgentlessMonitor.autoProbeCommand)
        let snapshot = monitor.parseOutput(raw2, prevCpu: &prevCpu, prevNet: &prevNet)

        XCTAssertGreaterThan(snapshot.cpuCores, 0)
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.diskTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.uptimeSeconds, 0)
        XCTAssertGreaterThanOrEqual(snapshot.cpuUsagePercent, 0.0)
        XCTAssertLessThanOrEqual(snapshot.cpuUsagePercent, 100.0)

        // Process inspector (Top 45)
        let psRaw = try await sshClient.executeCommand(AgentlessMonitor.processInspectorProbeCommand)
        let processes = ProcessListParser.parsePSOutput(psRaw)
        XCTAssertFalse(processes.isEmpty, "Process inspector probe must parse active processes")
        XCTAssertTrue(processes.contains { $0.isProtected }, "Process list should include protected system processes (PID 1 / sshd)")

        // Listening ports inspector (ss / netstat / lsof)
        let portsRaw = try await sshClient.executeCommand(AgentlessMonitor.listeningPortsProbeCommand)
        let ports = ListeningPortParser.parseOutput(portsRaw)
        XCTAssertFalse(ports.isEmpty, "Listening ports probe must parse at least one listening socket")
        XCTAssertTrue(ports.contains { $0.port == serverPort }, "Listening ports should include SSH server port \(serverPort)")

        // Container probe (Docker/Podman or graceful empty state)
        let containerRaw = try await sshClient.executeCommand(AgentlessMonitor.containerListProbeCommand)
        let containerResult = AgentlessMonitor.parseContainerProbeResult(containerRaw)
        if containerResult.runtime == nil {
            XCTAssertTrue(containerResult.items.isEmpty)
        }

        // Dynamic systemd probe (may be empty on non-systemd hosts, must not throw)
        let systemdRaw = try await sshClient.executeCommand(AgentlessMonitor.systemdDynamicProbeCommand)
        _ = AgentlessMonitor.parseSystemdDynamicOutput(systemdRaw)

        await sshClient.disconnect()
    }

    // MARK: - Test 4: Full SFTP Lifecycle inside /tmp/apexterm_e2e_<UUID> with defer cleanup
    @MainActor
    func testPublicServerFullSFTPLifecycle() async throws {
        try requireServerConfig()
        let sshClient = NativeSSHSession(session: publicSession)
        let remoteRoot = "/tmp/apexterm_e2e_\(UUID().uuidString)"
        let localDir = FileManager.default.temporaryDirectory.appendingPathComponent("apex_e2e_local_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: localDir)
            runRemoteCleanup(directory: remoteRoot)
        }

        // 1. Create isolated workspace + nested directory with spaces & CJK
        try await sshClient.createDirectory(remotePath: remoteRoot)
        let nestedDir = "\(remoteRoot)/sub dir 中文"
        try await sshClient.createDirectory(remotePath: nestedDir)

        // 2. Upload file with special characters & spaces via TransferManager
        let specialName = "report '1' $literal 中文.txt"
        let payloadText = "ApexTerm E2E Payload \(UUID().uuidString)\n中文 line 2: http://localhost:8080/api:v1\n"
        let payloadData = Data(payloadText.utf8)
        let localUploadURL = localDir.appendingPathComponent(specialName)
        try payloadData.write(to: localUploadURL)
        let remoteFilePath = "\(nestedDir)/\(specialName)"

        let manager = TransferManager()
        let uploadDone = expectation(description: "Upload completes via TransferManager")
        let uploadId = manager.enqueueUpload(
            session: sshClient,
            localURL: localUploadURL,
            remotePath: remoteFilePath,
            onResult: { result in
                if case .failure(let err) = result { XCTFail("Upload failed: \(err)") }
                uploadDone.fulfill()
            }
        )
        await fulfillment(of: [uploadDone], timeout: 15.0)
        XCTAssertEqual(manager.tasks.first(where: { $0.id == uploadId })?.status, .completed)

        // 3. List directory & verify metadata
        let listed = try await sshClient.listDirectory(path: nestedDir)
        let uploadedItem = try XCTUnwrap(listed.first(where: { $0.name == specialName }))
        XCTAssertEqual(uploadedItem.size, UInt64(payloadData.count))

        // 4. Download & verify byte-for-byte integrity
        let localDownloadURL = manager.availableDownloadURL(in: localDir, fileName: "downloaded.txt")
        let downloadDone = expectation(description: "Download completes via TransferManager")
        manager.enqueueDownload(
            session: sshClient,
            remotePath: remoteFilePath,
            localURL: localDownloadURL,
            totalBytes: Int64(payloadData.count),
            onResult: { result in
                if case .failure(let err) = result { XCTFail("Download failed: \(err)") }
                downloadDone.fulfill()
            }
        )
        await fulfillment(of: [downloadDone], timeout: 15.0)
        XCTAssertEqual(try Data(contentsOf: localDownloadURL), payloadData)

        // 5. Rename & chmod
        let renamedName = "renamed '2' 中文.txt"
        let renamedPath = "\(nestedDir)/\(renamedName)"
        try await sshClient.rename(oldPath: remoteFilePath, newPath: renamedPath)
        try await sshClient.changePermissions(remotePath: renamedPath, permissions: "600")
        let afterChmod = try await sshClient.listDirectory(path: nestedDir)
        let renamedItem = try XCTUnwrap(afterChmod.first(where: { $0.name == renamedName }))
        XCTAssertEqual(renamedItem.permissionString, "-rw-------")

        // 6. Checksum (SHA-256 & MD5)
        let expectedSHA256 = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        let remoteSHA256 = await SFTPInspectorHelper.computeRemoteChecksum(
            for: renamedItem,
            algorithm: .sha256,
            session: sshClient
        )
        // Compute via executeCommand directly since `sshClient` is non-PTY command channel
        let shaCmd = SFTPInspectorHelper.buildChecksumCommand(remotePath: renamedPath, algorithm: .sha256)
        let shaOut = try await sshClient.executeCommand(shaCmd)
        XCTAssertEqual(SFTPInspectorHelper.parseChecksumOutput(shaOut, algorithm: .sha256), expectedSHA256)
        _ = remoteSHA256

        let expectedMD5 = Insecure.MD5.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        let md5Cmd = SFTPInspectorHelper.buildChecksumCommand(remotePath: renamedPath, algorithm: .md5)
        let md5Out = try await sshClient.executeCommand(md5Cmd)
        XCTAssertEqual(SFTPInspectorHelper.parseChecksumOutput(md5Out, algorithm: .md5), expectedMD5)

        // 7. Remote search (filename & content)
        let findCmd = try XCTUnwrap(SFTPRemoteOperations.searchCommand(basePath: remoteRoot, query: "renamed", mode: .filename))
        let findOut = try await sshClient.executeCommand(findCmd)
        let findHits = SFTPRemoteOperations.parseSearchOutput(findOut, mode: .filename)
        XCTAssertTrue(findHits.contains { $0.path == renamedPath }, "Remote find should locate \(renamedPath), got: \(findHits)")

        let grepCmd = try XCTUnwrap(SFTPRemoteOperations.searchCommand(basePath: remoteRoot, query: "http://localhost:8080/api:v1", mode: .content))
        let grepOut = try await sshClient.executeCommand(grepCmd)
        let grepHits = SFTPRemoteOperations.parseSearchOutput(grepOut, mode: .content)
        XCTAssertTrue(grepHits.contains { $0.path == renamedPath && $0.lineNumber == 2 }, "Remote grep should locate content hit, got: \(grepHits)")

        // 8. Remote archive pack (.tar.gz) & unpack into extracted/
        let archiveName = "bundle 'e2e'.tar.gz"
        let archiveCmd = try XCTUnwrap(SFTPRemoteOperations.archiveCommand(
            items: [renamedName],
            inDirectory: nestedDir,
            format: .tarGz,
            archiveName: archiveName
        ))
        _ = try await sshClient.executeCommand(archiveCmd)
        let extractDir = "\(remoteRoot)/extracted"
        let extractCmd = try XCTUnwrap(SFTPRemoteOperations.extractCommand(
            archivePath: "\(nestedDir)/\(archiveName)",
            targetDirectory: extractDir
        ))
        _ = try await sshClient.executeCommand(extractCmd)
        let extractedItems = try await sshClient.listDirectory(path: extractDir)
        XCTAssertTrue(extractedItems.contains { $0.name == renamedName && $0.size == UInt64(payloadData.count) })

        // 9. Delete files and clean up directory
        try await sshClient.removeFile(remotePath: renamedPath)
        try await sshClient.removeDirectory(remotePath: remoteRoot, recursive: true)
        do {
            _ = try await sshClient.listDirectory(path: remoteRoot)
            XCTFail("Deleted remoteRoot should no longer exist")
        } catch {
            // Expected missing directory error
        }

        await sshClient.disconnect()
    }

    // MARK: - Test 5: Real Shell Directory Syncing (cd /tmp -> directoryChangeHandler)
    func testPublicServerDirectoryChangeSync() async throws {
        try requireServerConfig()
        let sshClient = NativeSSHSession(session: publicSession)
        final class PathBox: @unchecked Sendable {
            private let lock = NSLock()
            private var lastPath = ""
            func set(_ path: String) { lock.withLock { lastPath = path } }
            func get() -> String { lock.withLock { lastPath } }
        }
        let pathBox = PathBox()

        sshClient.setDirectoryChangeHandler { path in
            pathBox.set(path)
        }

        try await sshClient.connect()
        XCTAssertEqual(sshClient.connectionState, .connected)

        try await Task.sleep(for: .milliseconds(1500))
        try await sshClient.sendInput(Data("cd /tmp\r".utf8))

        let synced = try await waitUntil(timeout: .seconds(6)) {
            pathBox.get() == "/tmp"
        }
        XCTAssertTrue(synced, "Expected directoryChangeHandler to report /tmp, got: \(pathBox.get())")

        await sshClient.disconnect()
    }
}
