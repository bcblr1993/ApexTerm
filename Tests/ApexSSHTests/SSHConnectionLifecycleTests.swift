import XCTest
import AppKit
import Combine
import SwiftUI
import Darwin
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

final class SSHConnectionLifecycleTests: XCTestCase {

    // MARK: - Ephemeral TCP / SSHD Helpers

    private var bridgeURL: URL {
        Bundle(for: SSHConnectionLifecycleTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("ApexSSHBridge")
    }

    private func allocateEphemeralTCPPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }

    private final class StalledTCPListener: @unchecked Sendable {
        let port: Int
        private let listenFd: Int32
        private let lock = NSLock()
        private var acceptedFds: [Int32] = []
        private var closed = false

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes == 0, listen(fd, 8) == 0 else {
                let err = errno
                close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }

            var boundAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &boundAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            self.port = Int(UInt16(bigEndian: boundAddr.sin_port))
            self.listenFd = fd

            DispatchQueue.global(qos: .utility).async { [weak self] in
                while let self {
                    let isDone = self.lock.withLock { self.closed }
                    if isDone { break }
                    let clientFd = accept(fd, nil, nil)
                    if clientFd >= 0 {
                        self.lock.withLock {
                            if self.closed {
                                close(clientFd)
                            } else {
                                self.acceptedFds.append(clientFd)
                            }
                        }
                    } else if errno != EINTR {
                        break
                    }
                }
            }
        }

        func stop() {
            let fdsToClose: [Int32] = lock.withLock {
                guard !closed else { return [] }
                closed = true
                let copy = acceptedFds
                acceptedFds.removeAll()
                return copy
            }
            close(listenFd)
            for fd in fdsToClose { close(fd) }
        }

        deinit {
            stop()
        }
    }

    private final class StateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [SSHConnectionState] = []

        func append(_ state: SSHConnectionState) {
            lock.withLock { states.append(state) }
        }

        var snapshot: [SSHConnectionState] {
            lock.withLock { states }
        }

        var everConnected: Bool {
            lock.withLock { states.contains(.connected) }
        }
    }

    private func generateEd25519Key(at url: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        proc.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", url.path]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0, "ssh-keygen must succeed at \(url.path)")
    }

    private func startLocalSSHD(
        tempDir: URL,
        authorizedKeyPubPath: String
    ) throws -> (process: Process, port: Int) {
        let hostKey = tempDir.appendingPathComponent("host_ed25519")
        try generateEd25519Key(at: hostKey)

        let port = try allocateEphemeralTCPPort()
        let sshdConfig = tempDir.appendingPathComponent("sshd_config")
        let pidFile = tempDir.appendingPathComponent("sshd.pid")
        let configText = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        AuthorizedKeysFile \(authorizedKeyPubPath)
        PasswordAuthentication no
        PubkeyAuthentication yes
        KbdInteractiveAuthentication no
        UsePAM no
        PidFile \(pidFile.path)
        """
        try configText.write(to: sshdConfig, atomically: true, encoding: .utf8)

        let sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-f", sshdConfig.path]
        sshd.standardInput = FileHandle.nullDevice
        sshd.standardOutput = FileHandle.nullDevice
        sshd.standardError = FileHandle.nullDevice
        try sshd.run()

        // Wait up to 3s for sshd to listen
        let deadline = Date().addingTimeInterval(3.0)
        var listening = false
        while Date() < deadline {
            let probeFd = socket(AF_INET, SOCK_STREAM, 0)
            if probeFd >= 0 {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let res = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(probeFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                close(probeFd)
                if res == 0 {
                    listening = true
                    break
                }
            }
            usleep(25_000)
        }
        XCTAssertTrue(listening, "Ephemeral sshd failed to start listening on port \(port)")
        return (sshd, port)
    }

    private func stopLocalSSHD(_ sshd: Process) {
        let pid = sshd.processIdentifier
        if pid > 0 {
            for child in childPIDs(of: pid) {
                _ = kill(child, SIGKILL)
            }
            _ = kill(pid, SIGKILL)
        }
        let deadline = Date().addingTimeInterval(2.0)
        while sshd.isRunning && Date() < deadline {
            usleep(10_000)
        }
    }

    private func childPIDs(of parent: pid_t) -> Set<pid_t> {
        var pids = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        return Set(pids.prefix(max(0, Int(count))).filter { $0 > 0 })
    }

    // MARK: - TC-CONN-01: Hanging TCP server stays in .connecting and never falsely shows .connected

    @MainActor
    func testHangingTCPServerStaysConnectingAndNeverFalselyReportsConnected() async throws {
        let listener = try StalledTCPListener()
        defer { listener.stop() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apex_conn_01_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = Session(name: "stalled", host: "127.0.0.1", port: listener.port, username: NSUserName(), authMethod: .agent)
        let client = NativeSSHSession(
            session: session,
            distributionChannel: .appStore,
            bridgeExecutableURL: bridgeURL,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: tempDir
        )
        client.connectTimeoutSeconds = 5

        let recorder = StateRecorder()
        let tab = TerminalTabItem(session: session, sshClient: client)
        let pane = try XCTUnwrap(tab.panes.first)
        let stateSub = pane.$connectionState.sink { recorder.append($0) }
        defer {
            stateSub.cancel()
            tab.tearDown()
            UserDefaults.standard.removeObject(forKey: "workspace.remotePath.\(session.id.uuidString)")
        }
        tab.connect(pane: pane)

        try await Task.sleep(nanoseconds: 450_000_000)

        XCTAssertFalse(recorder.everConnected, "Must NEVER emit .connected while TCP/SSH handshake is stalled")
        if case .connecting = client.connectionState {} else {
            XCTFail("Expected client.connectionState to remain .connecting, got \(client.connectionState)")
        }
        if case .connecting = pane.connectionState {} else {
            XCTFail("Expected pane.connectionState to remain .connecting, got \(pane.connectionState)")
        }
        if case .connecting = tab.connectionState {} else {
            XCTFail("Expected tab.connectionState to remain .connecting, got \(tab.connectionState)")
        }
        XCTAssertFalse(pane.hasEverConnected)

        pane.cancelCurrentConnection()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while client.connectionState != .disconnected && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertEqual(pane.connectionState, .disconnected)
        XCTAssertEqual(tab.connectionState, .disconnected)
        XCTAssertFalse(recorder.everConnected)
    }

    // MARK: - TC-CONN-02: Closed port transitions directly to .failed without .connected or auto-reconnect

    @MainActor
    func testClosedPortTransitionsDirectlyToFailedWithoutConnectedOrAutoReconnect() async throws {
        let closedPort = try allocateEphemeralTCPPort()
        let prevAutoReconnect = AppSettings.shared.isAutoReconnectEnabled
        AppSettings.shared.isAutoReconnectEnabled = true
        defer { AppSettings.shared.isAutoReconnectEnabled = prevAutoReconnect }

        let session = Session(name: "closed-port", host: "127.0.0.1", port: closedPort, username: NSUserName(), authMethod: .agent)
        let client = NativeSSHSession(session: session, distributionChannel: .direct)
        client.connectTimeoutSeconds = 3

        let recorder = StateRecorder()
        let tab = TerminalTabItem(session: session, sshClient: client)
        let pane = try XCTUnwrap(tab.panes.first)
        let stateSub = pane.$connectionState.sink { recorder.append($0) }
        defer {
            stateSub.cancel()
            tab.tearDown()
            UserDefaults.standard.removeObject(forKey: "workspace.remotePath.\(session.id.uuidString)")
        }
        tab.connect(pane: pane)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if case .failed = pane.connectionState { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(recorder.everConnected, "Closed port must NEVER visit .connected")
        XCTAssertFalse(pane.hasEverConnected)
        XCTAssertFalse(pane.isAutoReconnecting, "Initial connection failure must NOT trigger auto-reconnect")
        XCTAssertEqual(pane.autoReconnectAttempt, 0)

        guard case .failed(let message) = pane.connectionState else {
            return XCTFail("Expected .failed state, got \(pane.connectionState)")
        }
        XCTAssertTrue(message.contains("连接被拒绝"), "Expected Connection refused diagnostic, got: \(message)")
    }

    // MARK: - TC-CONN-03: ConnectTimeout transitions to .failed without ever connecting

    func testConnectTimeoutTransitionsToFailedWithoutEverConnecting() async throws {
        let listener = try StalledTCPListener()
        defer { listener.stop() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apex_conn_03_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = Session(name: "timeout", host: "127.0.0.1", port: listener.port, username: NSUserName(), authMethod: .agent)
        let client = NativeSSHSession(
            session: session,
            distributionChannel: .appStore,
            bridgeExecutableURL: bridgeURL,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: tempDir
        )
        client.connectTimeoutSeconds = 2

        let recorder = StateRecorder()
        client.setStateChangeHandler { recorder.append($0) }

        do {
            try await client.connect()
            XCTFail("connect() must throw on ConnectTimeout")
        } catch {
            // Expected timeout failure
        }

        XCTAssertFalse(recorder.everConnected)
        guard case .failed(let message) = client.connectionState else {
            return XCTFail("Expected .failed on timeout, got \(client.connectionState)")
        }
        XCTAssertTrue(message.contains("连接超时") || message.lowercased().contains("timed out"),
                      "Expected timeout diagnostic, got: \(message)")
    }

    // MARK: - TC-CONN-04: Ephemeral local sshd authenticates and emits .connected only after session open

    func testEphemeralLocalSSHDAuthenticatesAndTransitionsToConnectedOnlyAfterSessionOpen() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"), "Local /usr/sbin/sshd unavailable")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apex_conn_04_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suite = "apex_conn_04_\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let userKey = tempDir.appendingPathComponent("client_ed25519")
        try generateEd25519Key(at: userKey)

        let (sshd, port) = try startLocalSSHD(tempDir: tempDir, authorizedKeyPubPath: userKey.path + ".pub")
        defer { stopLocalSSHD(sshd) }

        let accessStore = FileAccessStore(defaults: defaults)
        try accessStore.remember(userKey, readOnly: true)

        let session = Session(
            name: "local-sshd",
            host: "127.0.0.1",
            port: port,
            username: NSUserName(),
            authMethod: .privateKey(keychainRef: userKey.path, passphraseRef: nil),
            agentlessMonitorEnabled: false
        )
        let client = NativeSSHSession(
            session: session,
            distributionChannel: .appStore,
            fileAccessStore: accessStore,
            bridgeExecutableURL: bridgeURL,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: tempDir
        )

        let recorder = StateRecorder()
        client.setStateChangeHandler { recorder.append($0) }

        final class OutputCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var text = ""
            func append(_ str: String) { lock.withLock { text.append(str) } }
            func contains(_ needle: String) -> Bool { lock.withLock { text.contains(needle) } }
        }
        let outputCollector = OutputCollector()
        client.setOutputHandler { data in
            outputCollector.append(String(decoding: data, as: UTF8.self))
        }

        let beforePids = childPIDs(of: getpid())
        try await client.connect()
        let activePids = childPIDs(of: getpid()).subtracting(beforePids)
        XCTAssertFalse(activePids.isEmpty, "Connected SSH session must have an active child process")

        XCTAssertEqual(client.connectionState, .connected)
        let history = recorder.snapshot
        XCTAssertTrue(history.contains { if case .connecting = $0 { return true }; return false },
                      "Expected .connecting states before .connected")
        XCTAssertEqual(history.last, .connected)

        // Verify no apx-conn-*.log remains on disk once connected
        let remainingLogs = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?.filter {
            $0.hasPrefix("apx-conn-") && $0.hasSuffix(".log")
        } ?? []
        XCTAssertTrue(remainingLogs.isEmpty, "Temp handshake log must be unlinked once established: \(remainingLogs)")

        // Verify live interactive PTY channel works
        try await client.sendInput("echo CONN_VERIFIED\r\n".data(using: .utf8)!)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !outputCollector.contains("CONN_VERIFIED") && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(outputCollector.contains("CONN_VERIFIED"), "Interactive PTY must work once .connected is emitted")

        await client.disconnect()
        XCTAssertEqual(client.connectionState, .disconnected)
        for pid in activePids {
            XCTAssertEqual(kill(pid, 0), -1, "Disconnected SSH child PID \(pid) must not survive")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    // MARK: - TC-CONN-05: Unauthorized key against ephemeral sshd fails with diagnostic and never hits .connected

    func testEphemeralLocalSSHDAuthFailureReportsFailedAndNeverSetsHasEverConnected() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"), "Local /usr/sbin/sshd unavailable")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apex_conn_05_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suite = "apex_conn_05_\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let authorizedKey = tempDir.appendingPathComponent("authorized_ed25519")
        let wrongKey = tempDir.appendingPathComponent("wrong_ed25519")
        try generateEd25519Key(at: authorizedKey)
        try generateEd25519Key(at: wrongKey)

        let (sshd, port) = try startLocalSSHD(tempDir: tempDir, authorizedKeyPubPath: authorizedKey.path + ".pub")
        defer { stopLocalSSHD(sshd) }

        let accessStore = FileAccessStore(defaults: defaults)
        try accessStore.remember(wrongKey, readOnly: true)

        let session = Session(
            name: "auth-fail",
            host: "127.0.0.1",
            port: port,
            username: NSUserName(),
            authMethod: .privateKey(keychainRef: wrongKey.path, passphraseRef: nil),
            agentlessMonitorEnabled: false
        )
        let client = NativeSSHSession(
            session: session,
            distributionChannel: .appStore,
            fileAccessStore: accessStore,
            bridgeExecutableURL: bridgeURL,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: tempDir
        )

        let recorder = StateRecorder()
        client.setStateChangeHandler { recorder.append($0) }

        do {
            try await client.connect()
            XCTFail("Unauthorized key must fail connect()")
        } catch {
            // Expected failure
        }

        XCTAssertFalse(recorder.everConnected, "Auth failure must NEVER report .connected")
        guard case .failed(let message) = client.connectionState else {
            return XCTFail("Expected .failed state, got \(client.connectionState)")
        }
        XCTAssertTrue(message.contains("认证失败"), "Expected authentication failure diagnostic, got: \(message)")
    }

    // MARK: - TC-CONN-06: Cancelling mid-handshake reaps child process, removes temp log, sets .disconnected

    @MainActor
    func testDisconnectMidHandshakeReapsChildProcessAndSetsDisconnectedNotFailed() async throws {
        let listener = try StalledTCPListener()
        defer { listener.stop() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apex_conn_06_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = Session(name: "cancel-mid", host: "127.0.0.1", port: listener.port, username: NSUserName(), authMethod: .agent)
        let client = NativeSSHSession(
            session: session,
            distributionChannel: .appStore,
            bridgeExecutableURL: bridgeURL,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: tempDir
        )
        client.connectTimeoutSeconds = 10

        let beforePids = childPIDs(of: getpid())
        let recorder = StateRecorder()
        let tab = TerminalTabItem(session: session, sshClient: client)
        let pane = try XCTUnwrap(tab.panes.first)
        let stateSub = pane.$connectionState.sink { recorder.append($0) }
        defer {
            stateSub.cancel()
            tab.tearDown()
            UserDefaults.standard.removeObject(forKey: "workspace.remotePath.\(session.id.uuidString)")
        }
        tab.connect(pane: pane)

        // Wait until the SSH child is actually spawned
        var spawnedPids: Set<pid_t> = []
        let spawnDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while spawnedPids.isEmpty && ContinuousClock.now < spawnDeadline {
            try await Task.sleep(for: .milliseconds(25))
            spawnedPids = childPIDs(of: getpid()).subtracting(beforePids)
        }
        XCTAssertFalse(spawnedPids.isEmpty, "SSH child process must be spawned before cancellation")

        pane.cancelCurrentConnection()

        let reapDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < reapDeadline {
            let alive = spawnedPids.filter { kill($0, 0) == 0 }
            if alive.isEmpty && client.connectionState == .disconnected {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        for pid in spawnedPids {
            XCTAssertEqual(kill(pid, 0), -1, "Cancelled handshake child PID \(pid) must be reaped")
            XCTAssertEqual(errno, ESRCH)
        }

        let remainingLogs = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?.filter {
            $0.hasPrefix("apx-conn-") && $0.hasSuffix(".log")
        } ?? []
        XCTAssertTrue(remainingLogs.isEmpty, "Temp handshake log must be deleted on cancel: \(remainingLogs)")

        XCTAssertEqual(client.connectionState, .disconnected)
        XCTAssertEqual(pane.connectionState, .disconnected)
        XCTAssertEqual(tab.connectionState, .disconnected)
        XCTAssertFalse(recorder.everConnected, "Cancelled handshake must never report .connected")
        XCTAssertFalse(
            recorder.snapshot.contains { if case .failed = $0 { return true }; return false },
            "Cancelled handshake must never transiently emit .failed, history: \(recorder.snapshot)"
        )
    }

    // MARK: - TC-CONN-07: OpenSSH log line classification covers direct, ProxyJump, and ControlMaster mux

    func testConnectionLogClassifierCoversDirectProxyJumpAndControlMasterMux() {
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("debug1: Connecting to 10.0.0.1 [10.0.0.1] port 22.", host: "10.0.0.1", port: 22),
            .step("正在建立连接 (10.0.0.1:22)...")
        )
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("debug1: Connection established.", host: "10.0.0.1", port: 22),
            .step("已建立 TCP 连接，正在握手与验证身份...")
        )
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("debug1: Offering public key: /path/key ED25519 SHA256:abc", host: "10.0.0.1", port: 22),
            .step("正在验证密钥凭证...")
        )
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("debug1: Next authentication method: password", host: "10.0.0.1", port: 22),
            .step("正在验证登录口令...")
        )
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("Authenticated to 10.0.0.1 (via proxy) using \"publickey\".", host: "10.0.0.1", port: 22),
            .step("身份验证通过，正在开启远程终端...")
        )
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("debug1: Entering interactive session.", host: "10.0.0.1", port: 22),
            .established
        )
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("debug1: auto-mux: Trying existing master at '/tmp/ctrl'", host: "10.0.0.1", port: 22),
            .step("正在复用已有 SSH 连接通道...")
        )
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("debug1: mux_client_request_session: master session id: 0", host: "10.0.0.1", port: 22),
            .established
        )
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("debug1: Reading configuration data /etc/ssh/ssh_config", host: "10.0.0.1", port: 22),
            .ignore
        )
        XCTAssertEqual(
            NativeSSHSession.classifyConnectionLogLine("ssh: connect to host 10.0.0.1 port 22: Operation timed out", host: "10.0.0.1", port: 22),
            .diagnostic("ssh: connect to host 10.0.0.1 port 22: Operation timed out")
        )
    }

    // MARK: - TC-CONN-08: Workspace startup bootstrap and SFTPView directory listing wait for .connected

    @MainActor
    func testSFTPAndWorkspaceRespectConnectingStateBeforeSessionEstablishes() async throws {
        final class SuspendedSession: SSHSessionProtocol, @unchecked Sendable {
            let session: Session
            private let lock = NSLock()
            private var storedState: SSHConnectionState = .disconnected
            private var stateHandler: (@Sendable (SSHConnectionState) -> Void)?
            private var connectContinuation: CheckedContinuation<Void, Error>?
            private var recordedInputs: [String] = []
            private var directoryListCount = 0

            var connectionState: SSHConnectionState {
                lock.withLock { storedState }
            }

            var sentInputs: [String] {
                lock.withLock { recordedInputs }
            }

            var listDirectoryCalls: Int {
                lock.withLock { directoryListCount }
            }

            init(session: Session) {
                self.session = session
            }

            func setStateChangeHandler(_ handler: @Sendable @escaping (SSHConnectionState) -> Void) {
                lock.withLock { stateHandler = handler }
            }

            func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) {}
            func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) {}
            func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) {}

            func connect() async throws {
                let handler = lock.withLock { () -> (@Sendable (SSHConnectionState) -> Void)? in
                    storedState = .connecting(step: "Handshaking...")
                    return stateHandler
                }
                handler?(.connecting(step: "Handshaking..."))
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    lock.withLock { connectContinuation = cont }
                }
            }

            func completeConnect() {
                let (cont, handler) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, (@Sendable (SSHConnectionState) -> Void)?) in
                    storedState = .connected
                    let c = connectContinuation
                    connectContinuation = nil
                    return (c, stateHandler)
                }
                handler?(.connected)
                cont?.resume()
            }

            func disconnect() async {
                let (cont, handler) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, (@Sendable (SSHConnectionState) -> Void)?) in
                    storedState = .disconnected
                    let c = connectContinuation
                    connectContinuation = nil
                    return (c, stateHandler)
                }
                handler?(.disconnected)
                cont?.resume(throwing: CancellationError())
            }

            func sendInput(_ data: Data) async throws {
                sendInputSync(data)
            }

            func sendInputSync(_ data: Data) {
                let text = String(decoding: data, as: UTF8.self)
                lock.withLock { recordedInputs.append(text) }
            }

            func resizeTerminal(columns: Int, rows: Int) async throws {}

            func listDirectory(path: String) async throws -> [SFTPItem] {
                lock.withLock { directoryListCount += 1 }
                return []
            }

            func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {}
            func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {}
        }

        struct HostedSFTPHarness: View {
            @ObservedObject var tab: TerminalTabItem
            var body: some View {
                SFTPView(
                    currentPath: $tab.currentRemotePath,
                    isLinkageEnabled: $tab.isDirectoryLinkageEnabled,
                    session: tab.sshClient,
                    connectionState: tab.connectionState
                )
            }
        }

        let session = Session(
            name: "bootstrap-wait",
            host: "example.test",
            port: 22,
            username: "qa",
            authMethod: .agent,
            initialWorkingDirectory: "/srv/app",
            startupCommand: "echo READY"
        )
        let suspended = SuspendedSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: suspended)
        defer {
            tab.tearDown()
            UserDefaults.standard.removeObject(forKey: "workspace.remotePath.\(session.id.uuidString)")
        }

        tab.connect()
        try await Task.sleep(nanoseconds: 150_000_000)

        if case .connecting = tab.connectionState {} else {
            XCTFail("Tab must remain .connecting while suspended, got \(tab.connectionState)")
        }
        XCTAssertTrue(suspended.sentInputs.isEmpty, "Startup bootstrap must NOT be sent before .connected")

        // Mount SFTPView in .connecting state and verify listDirectory is NOT invoked
        XCTAssertFalse(SFTPView.shouldLoadDirectory(for: .connecting(step: "正在连接")))
        XCTAssertFalse(SFTPView.shouldLoadDirectory(for: .disconnected))
        XCTAssertFalse(SFTPView.shouldLoadDirectory(for: .failed("err")))
        XCTAssertTrue(SFTPView.shouldLoadDirectory(for: .connected))

        let host = NSHostingView(rootView: HostedSFTPHarness(tab: tab).apexTheme())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(suspended.listDirectoryCalls, 0, "SFTPView must not query listDirectory while .connecting")

        // Complete connection and verify startup bootstrap + SFTP directory load both execute
        suspended.completeConnect()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (tab.connectionState != .connected || suspended.sentInputs.isEmpty || suspended.listDirectoryCalls == 0) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(tab.connectionState, .connected)
        XCTAssertTrue(suspended.sentInputs.joined().contains("cd '/srv/app' && echo READY"),
                      "Expected startup bootstrap once .connected, got: \(suspended.sentInputs)")
        XCTAssertGreaterThanOrEqual(suspended.listDirectoryCalls, 1,
                                    "SFTPView must automatically load directory once session transitions to .connected")
    }

    // MARK: - TC-CONN-09: Rapid cancel of attempt 1 followed by attempt 2 does not kill attempt 2

    func testNativeSSHRapidCancelThenReconnectDoesNotKillNewAttempt() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"), "Local /usr/sbin/sshd unavailable")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apex_conn_09_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let suite = "apex_conn_09_\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let userKey = tempDir.appendingPathComponent("client_ed25519")
        try generateEd25519Key(at: userKey)
        let (sshd, port) = try startLocalSSHD(tempDir: tempDir, authorizedKeyPubPath: userKey.path + ".pub")
        defer { stopLocalSSHD(sshd) }

        let accessStore = FileAccessStore(defaults: defaults)
        try accessStore.remember(userKey, readOnly: true)

        let session = Session(
            name: "rapid-reconnect",
            host: "127.0.0.1",
            port: port,
            username: NSUserName(),
            authMethod: .privateKey(keychainRef: userKey.path, passphraseRef: nil),
            agentlessMonitorEnabled: false
        )
        let client = NativeSSHSession(
            session: session,
            distributionChannel: .appStore,
            fileAccessStore: accessStore,
            bridgeExecutableURL: bridgeURL,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: tempDir
        )

        // Start attempt 1 and cancel it immediately, then launch attempt 2 right away.
        // Scoped onCancel must only cancel attempt 1 and never tear down attempt 2.
        let attempt1 = Task { try await client.connect() }
        attempt1.cancel()

        try await client.connect()
        _ = await attempt1.result

        // Allow any stray async cancellation handler from attempt 1 to settle
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(client.connectionState, .connected,
                       "Cancelled attempt 1 must never tear down a newer connected attempt 2")

        await client.disconnect()
        XCTAssertEqual(client.connectionState, .disconnected)
    }

    // MARK: - TC-CONN-10: Workspace cancel -> reconnect -> cancel serializes disconnectToken without flicker

    @MainActor
    func testWorkspaceCancelReconnectCancelSerializesDisconnectTokenWithoutFlicker() async throws {
        final class ControlledDisconnectSession: SSHSessionProtocol, @unchecked Sendable {
            let session: Session
            private let lock = NSLock()
            private var storedState: SSHConnectionState = .disconnected
            private var stateHandler: (@Sendable (SSHConnectionState) -> Void)?
            private var disconnectContinuations: [CheckedContinuation<Void, Never>] = []
            private var _connectCalls = 0
            private var _disconnectCalls = 0

            var connectionState: SSHConnectionState { lock.withLock { storedState } }
            var connectCalls: Int { lock.withLock { _connectCalls } }
            var disconnectCalls: Int { lock.withLock { _disconnectCalls } }

            init(session: Session) { self.session = session }
            func setStateChangeHandler(_ handler: @Sendable @escaping (SSHConnectionState) -> Void) {
                lock.withLock { stateHandler = handler }
            }
            func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) {}
            func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) {}
            func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) {}

            func connect() async throws {
                let handler = lock.withLock { () -> (@Sendable (SSHConnectionState) -> Void)? in
                    _connectCalls += 1
                    storedState = .connected
                    return stateHandler
                }
                handler?(.connected)
            }

            func disconnect() async {
                let handler = lock.withLock { () -> (@Sendable (SSHConnectionState) -> Void)? in
                    _disconnectCalls += 1
                    return stateHandler
                }
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    lock.withLock { disconnectContinuations.append(cont) }
                }
                lock.withLock { storedState = .disconnected }
                handler?(.disconnected)
            }

            func finishNextDisconnect() -> Bool {
                let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    guard !disconnectContinuations.isEmpty else { return nil }
                    return disconnectContinuations.removeFirst()
                }
                guard let next else { return false }
                next.resume()
                return true
            }

            func sendInput(_ data: Data) async throws {}
            func sendInputSync(_ data: Data) {}
            func resizeTerminal(columns: Int, rows: Int) async throws {}
            func listDirectory(path: String) async throws -> [SFTPItem] { [] }
            func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {}
            func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {}
        }

        let session = Session(name: "token-race", host: "10.0.0.9", username: "qa", authMethod: .agent)
        let mock = ControlledDisconnectSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: mock)
        let pane = try XCTUnwrap(tab.panes.first)
        defer {
            while mock.finishNextDisconnect() {}
            tab.tearDown()
            UserDefaults.standard.removeObject(forKey: "workspace.remotePath.\(session.id.uuidString)")
        }

        // Step 1: cancel -> starts D1 (suspended)
        pane.cancelCurrentConnection()
        let d1Deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mock.disconnectCalls < 1 && ContinuousClock.now < d1Deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(mock.disconnectCalls, 1)

        // Step 2: reconnect C2 (waits on D1) -> cancel D2 (queues behind D1)
        tab.connect(pane: pane)
        pane.cancelCurrentConnection()

        // Step 3: finish D1 -> C2 must stay cancelled, D2 starts and blocks
        XCTAssertTrue(mock.finishNextDisconnect())
        let d2Deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while mock.disconnectCalls < 2 && ContinuousClock.now < d2Deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(mock.connectCalls, 0, "Cancelled reconnect C2 must never call client.connect()")
        XCTAssertEqual(mock.disconnectCalls, 2)

        // Step 4: reconnect C3 while D2 is still running -> C3 must wait for D2,
        // and D2's .disconnected callback must NOT flicker pane.connectionState back to .disconnected.
        let recorder = StateRecorder()
        tab.connect(pane: pane)
        let stateSub = pane.$connectionState.sink { recorder.append($0) }
        defer { stateSub.cancel() }

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mock.connectCalls, 0, "C3 must wait for D2 because D1's completion must not clear D2's disconnectToken")

        XCTAssertTrue(mock.finishNextDisconnect())
        let c3Deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pane.connectionState != .connected && ContinuousClock.now < c3Deadline {
            try await Task.sleep(for: .milliseconds(15))
        }

        XCTAssertEqual(mock.connectCalls, 1)
        XCTAssertEqual(pane.connectionState, .connected)
        XCTAssertFalse(
            recorder.snapshot.contains(.disconnected),
            "Old disconnect D2 finishing while C3 is pending must not flicker .disconnected, history: \(recorder.snapshot)"
        )
    }

    // MARK: - TC-CONN-11: Closing primary pane migrates metrics handler and directory linkage respects active pane & ~/ subpath

    @MainActor
    func testWorkspaceClosePrimaryPaneMigratesMetricsAndRespectsActivePaneDirectoryLinkage() async throws {
        final class MetricMockSession: SSHSessionProtocol, @unchecked Sendable {
            let session: Session
            private let lock = NSLock()
            private var metricsHandler: (@Sendable (ServerMetricsSnapshot) -> Void)?
            private var dirHandler: (@Sendable (String) -> Void)?
            var connectionState: SSHConnectionState = .connected

            init(session: Session) { self.session = session }
            func setStateChangeHandler(_ handler: @Sendable @escaping (SSHConnectionState) -> Void) {}
            func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) {}
            func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) {
                lock.withLock { metricsHandler = handler }
            }
            func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) {
                lock.withLock { dirHandler = handler }
            }
            func emitMetrics(_ snapshot: ServerMetricsSnapshot) {
                let h = lock.withLock { metricsHandler }
                h?(snapshot)
            }
            func emitDirectory(_ path: String) {
                let h = lock.withLock { dirHandler }
                h?(path)
            }
            func connect() async throws {}
            func disconnect() async {}
            func sendInput(_ data: Data) async throws {}
            func sendInputSync(_ data: Data) {}
            func resizeTerminal(columns: Int, rows: Int) async throws {}
            func listDirectory(path: String) async throws -> [SFTPItem] { [] }
            func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {}
            func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {}
        }

        let session = Session(name: "split-metrics", host: "10.0.0.20", username: "qa", authMethod: .agent)
        let primaryClient = MetricMockSession(session: session)
        let secondaryClient = MetricMockSession(session: session)

        let tab = TerminalTabItem(session: session, sshClient: primaryClient)
        defer {
            tab.tearDown()
            UserDefaults.standard.removeObject(forKey: "workspace.remotePath.\(session.id.uuidString)")
        }
        let primaryPane = try XCTUnwrap(tab.panes.first)
        let secondaryPane = TerminalPaneItem(session: session, sshClient: secondaryClient, title: "split", initialState: .connected)
        tab.panes.append(secondaryPane)
        tab.registerDirectoryLinkage(for: secondaryClient, paneId: secondaryPane.id)
        tab.activePaneId = primaryPane.id
        tab.isDirectoryLinkageEnabled = true
        tab.currentRemotePath = "/srv/primary"

        // Inactive secondary pane directory change must NOT overwrite active primary pane's currentRemotePath
        secondaryClient.emitDirectory("/var/log/secondary")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(tab.currentRemotePath, "/srv/primary", "Inactive pane directory change must be ignored")

        // Close primary pane -> secondary becomes primary and inherits metrics handler
        tab.closePane(id: primaryPane.id)
        XCTAssertEqual(tab.panes.map(\.id), [secondaryPane.id])
        XCTAssertEqual(tab.activePaneId, secondaryPane.id)

        let expectedMetrics = ServerMetricsSnapshot(
            cpuUsagePercent: 42.5,
            memoryTotalBytes: 4096 * 1024 * 1024,
            memoryUsedBytes: 1024 * 1024 * 1024
        )
        secondaryClient.emitMetrics(expectedMetrics)
        let metricsDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while tab.metricsHistory.latest?.cpuUsagePercent != 42.5 && ContinuousClock.now < metricsDeadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(tab.metricsHistory.latest?.cpuUsagePercent, 42.5,
                       "Closing primary pane must migrate metricsHandler to the promoted remaining pane")

        // When directory linkage is disabled, ~/subpath should expand prefix once without losing subpath
        tab.isDirectoryLinkageEnabled = false
        tab.currentRemotePath = "~/projects/app"
        secondaryClient.emitDirectory("/home/qa")
        let expandDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while tab.currentRemotePath != "/home/qa/projects/app" && ContinuousClock.now < expandDeadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(tab.currentRemotePath, "/home/qa/projects/app",
                       "Unlinked ~/subpath must expand ~ prefix while preserving the subpath")
    }
}
