import XCTest
import os
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

final class V30SSHBatchAndMonitorTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("V30SSHTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeSession(name: String, host: String = "10.0.1.10") -> Session {
        Session(name: name, host: host, port: 22, username: "ops", authMethod: .agent)
    }

    // MARK: - TC-V30-14: Batch per-host timeout cancellation & drain on cancel-relaunch
    @MainActor
    func testTC_V30_14_BatchPerHostTimeoutCancelsHangingHost() async {
        let hangingSession = makeSession(name: "hang-host", host: "10.0.1.1")
        let fastSession = makeSession(name: "fast-host", host: "10.0.1.2")
        let cancelledFlag = OSAllocatedUnfairLock(initialState: false)

        let manager = BatchOperationsManager(maxConcurrency: 2, commandTimeoutSeconds: 0.15) { session in
            let mock = MockSSHSession(session: session)
            mock.customExecuteCommandResultHandler = { _ in
                if session.id == hangingSession.id {
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    } catch {
                        cancelledFlag.withLock { $0 = true }
                        throw error
                    }
                    return SSHCommandResult(stdout: "never", stderr: "", exitCode: 0, durationMs: 5000)
                }
                try await Task.sleep(nanoseconds: 20_000_000)
                return SSHCommandResult(stdout: "fast-ok", stderr: "", exitCode: 0, durationMs: 20)
            }
            return mock
        }

        await manager.executeBatchCommand("sleep 10", on: [hangingSession, fastSession])

        XCTAssertFalse(manager.isRunning)
        XCTAssertTrue(cancelledFlag.withLock { $0 }, "Timed-out host task must be cancelled promptly")

        let hangResult = manager.results.first(where: { $0.sessionID == hangingSession.id })
        let fastResult = manager.results.first(where: { $0.sessionID == fastSession.id })
        XCTAssertEqual(hangResult?.status, .failed("执行超时"))
        XCTAssertEqual(fastResult?.status, .succeeded)
        XCTAssertEqual(fastResult?.stdout, "fast-ok")

        // Verify cancel followed by immediate relaunch drains prior activeBatchTask cleanly
        let activeCount = OSAllocatedUnfairLock(initialState: 0)
        let peakOverlap = OSAllocatedUnfairLock(initialState: 0)
        let serialManager = BatchOperationsManager(maxConcurrency: 1, commandTimeoutSeconds: 2.0) { session in
            let mock = MockSSHSession(session: session)
            mock.customExecuteCommandResultHandler = { _ in
                let cur = activeCount.withLock { val -> Int in
                    val += 1
                    return val
                }
                peakOverlap.withLock { peak in
                    if cur > peak { peak = cur }
                }
                defer { activeCount.withLock { $0 -= 1 } }
                try await Task.sleep(nanoseconds: 80_000_000)
                return SSHCommandResult(stdout: "ok", stderr: "", exitCode: 0, durationMs: 80)
            }
            return mock
        }
        _ = serialManager.startBatchCommand("first", on: [fastSession])
        try? await Task.sleep(nanoseconds: 20_000_000)
        serialManager.cancelCurrentBatch()
        await serialManager.executeBatchCommand("second", on: [fastSession])
        XCTAssertEqual(peakOverlap.withLock { $0 }, 1, "Relaunch must drain cancelled batch before spawning new work")
        XCTAssertEqual(serialManager.succeededCount, 1)
    }

    // MARK: - TC-V30-15: NativeSSHSession.runProcessWithOutput stream memory cap
    func testTC_V30_15_RunProcessWithOutputStreamCap() async throws {
        XCTAssertEqual(NativeSSHSession.defaultMaxOutputBytesPerStream, 512 * 1024)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Emit 96 KB on stdout and 64 KB on stderr (both exceeding 16 KB cap)
        process.arguments = [
            "-c",
            "head -c 98304 /dev/zero | tr '\\0' 'A'; head -c 65536 /dev/zero | tr '\\0' 'E' >&2"
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let (outData, errData) = try await NativeSSHSession.runProcessWithOutput(
            process,
            outPipe: outPipe,
            errPipe: errPipe,
            maxBytesPerStream: 16 * 1024
        )
        XCTAssertEqual(process.terminationStatus, 0)

        let outText = String(decoding: outData, as: UTF8.self)
        let errText = String(decoding: errData, as: UTF8.self)
        XCTAssertLessThan(outData.count, 17 * 1024)
        XCTAssertLessThan(errData.count, 17 * 1024)
        XCTAssertTrue(outText.contains("输出已截断"))
        XCTAssertTrue(errText.contains("输出已截断"))
    }

    // MARK: - TC-V30-16: Batch disconnect cleanup & jump-chain snapshot without MainActor timeout
    @MainActor
    func testTC_V30_16_BatchDisconnectCleanupAndJumpChainSnapshot() async {
        final class TrackingSession: SSHSessionProtocol, @unchecked Sendable {
            let session: Session
            private let lock = NSLock()
            private var _state: SSHConnectionState = .disconnected
            var connectionState: SSHConnectionState { lock.withLock { _state } }
            private(set) var disconnectCount = 0
            let shouldThrow: Bool

            init(session: Session, shouldThrow: Bool = false) {
                self.session = session
                self.shouldThrow = shouldThrow
            }

            func connect() async throws {}
            func disconnect() async {
                lock.withLock { disconnectCount += 1 }
            }
            func sendInput(_ data: Data) async throws {}
            func resizeTerminal(columns: Int, rows: Int) async throws {}
            func listDirectory(path: String) async throws -> [SFTPItem] { [] }
            func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {}
            func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {}
            func executeCommandWithResult(_ command: String) async throws -> SSHCommandResult {
                if shouldThrow {
                    throw NSError(domain: "Test", code: 255, userInfo: [NSLocalizedDescriptionKey: "boom"])
                }
                return SSHCommandResult(stdout: "ok", stderr: "", exitCode: 0, durationMs: 5)
            }
            func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) {}
            func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) {}
            func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) {}
        }

        let s1 = makeSession(name: "ok-node", host: "10.0.2.1")
        let s2 = makeSession(name: "fail-node", host: "10.0.2.2")
        let created = OSAllocatedUnfairLock(initialState: [TrackingSession]())

        let manager = BatchOperationsManager(maxConcurrency: 2) { session in
            let client = TrackingSession(session: session, shouldThrow: session.id == s2.id)
            created.withLock { $0.append(client) }
            return client
        }

        await manager.executeBatchCommand("id", on: [s1, s2])
        let tracked = created.withLock { $0 }
        XCTAssertEqual(tracked.count, 2)
        for client in tracked {
            XCTAssertEqual(client.disconnectCount, 1, "Every ephemeral batch client must disconnect() in cleanup")
        }

        // Off-main-thread NativeSSHSession construction with availableSessions snapshot resolves -J immediately
        let hop1 = Session(name: "bastion-1", host: "bastion1.example.test", port: 2201, username: "jump1")
        let hop2 = Session(name: "bastion-2", host: "bastion2.example.test", port: 2202, username: "jump2")
        let target = Session(
            name: "db-target",
            host: "10.9.9.10",
            port: 22,
            username: "dba",
            jumpServerChain: [hop1.id, hop2.id]
        )

        let offMainResult = await Task.detached { () -> (jumpArgs: [String], ctrlArgs: [String]) in
            let client = NativeSSHSession(
                session: target,
                distributionChannel: .direct,
                availableSessions: [hop1, hop2, target],
                disableControlPersist: true
            )
            return (client.jumpServerArgs(), client.controlMasterArguments)
        }.value

        XCTAssertEqual(offMainResult.jumpArgs, ["-J", "jump1@bastion1.example.test:2201,jump2@bastion2.example.test:2202"])
        XCTAssertTrue(offMainResult.ctrlArgs.contains("ControlMaster=no"))
        XCTAssertTrue(offMainResult.ctrlArgs.contains("ControlPersist=no"))
        XCTAssertFalse(offMainResult.ctrlArgs.contains("ControlPersist=4h"))
    }

    // MARK: - TC-V30-17: SSHTunnelManager canStop, App Store bridge args, quoting & 2FA prompt safety
    @MainActor
    func testTC_V30_17_SSHTunnelCanStopBridgeArgsQuotingAnd2FAGuard() throws {
        // Preserve TC-TUN-06 isRunning while exposing canStop for Stop button during .starting
        XCTAssertFalse(SSHTunnelState.starting.isRunning)
        XCTAssertTrue(SSHTunnelState.starting.canStop)
        XCTAssertTrue(SSHTunnelState.active.isRunning)
        XCTAssertTrue(SSHTunnelState.active.canStop)
        XCTAssertFalse(SSHTunnelState.stopped.canStop)
        XCTAssertFalse(SSHTunnelState.failed("err").canStop)

        // CertificateFile with spaces is quoted & ConnectTimeout=10 is present
        let spacedSession = Session(
            name: "CertTunnel",
            host: "10.0.3.4",
            port: 2222,
            username: "ops",
            authMethod: .certificate(
                keychainRef: "/tmp/My Keys/id_ed25519",
                certificatePath: "/tmp/My Keys/id_ed25519-cert.pub",
                passphraseRef: "pass_ref"
            )
        )
        let tunnel = SSHTunnel(name: "DB", type: .local, sessionId: spacedSession.id, bindPort: 13306, targetPort: 3306)
        let sshArgs = SSHTunnelManager.buildSSHArguments(tunnel: tunnel, session: spacedSession)
        XCTAssertTrue(sshArgs.contains("ConnectTimeout=10"))
        XCTAssertTrue(sshArgs.contains("CertificateFile=\"/tmp/My Keys/id_ed25519-cert.pub\""))

        // App Store bridge command construction for SSHTunnelManager
        let keyFile = tempDir.appendingPathComponent("id_ed25519")
        let certFile = tempDir.appendingPathComponent("id_ed25519-cert.pub")
        try Data("key-fixture".utf8).write(to: keyFile)
        try Data("cert-fixture".utf8).write(to: certFile)

        let fakeBridge = tempDir.appendingPathComponent("ApexSSHBridge")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeBridge)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBridge.path)

        let suite = "v30-tunnel-bridge-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fileStore = FileAccessStore(defaults: defaults)
        let storeSession = Session(
            name: "StoreTunnel",
            host: "bastion.example.test",
            port: 22,
            username: "qa",
            authMethod: .certificate(keychainRef: keyFile.path, certificatePath: certFile.path, passphraseRef: "pass_ref")
        )

        let prepared = try SSHTunnelManager.prepareStoreTunnelCommand(
            tunnel: tunnel,
            session: storeSession,
            password: "key-passphrase-fixture",
            privateKeyPath: keyFile.path,
            jumpChain: [],
            fileAccessStore: fileStore,
            bridgeExecutableURL: fakeBridge,
            sandboxHomeURL: tempDir
        )
        defer {
            prepared.grants.close()
            prepared.leases.forEach { $0.close() }
        }

        XCTAssertEqual(prepared.binaryPath, fakeBridge.path)
        XCTAssertEqual(Array(prepared.arguments.prefix(4)), ["--tool", "ssh", "-F", "/dev/null"])
        XCTAssertTrue(prepared.arguments.contains(where: { $0.hasPrefix("UserKnownHostsFile=") }))
        XCTAssertNotNil(prepared.environment[ChildProcessFileGrants.environmentKey])
        let decodedPayload = try ChildProcessFileGrants.read(from: prepared.grants.fileURL)
        XCTAssertEqual(decodedPayload.files.count, 2)
        XCTAssertEqual(decodedPayload.authentication?.kind, .passphrase)

        // Tunnel log readiness detection
        XCTAssertTrue(SSHTunnelManager.isTunnelLogLineReady("debug1: Local forwarding listening on 127.0.0.1 port 13306."))
        XCTAssertTrue(SSHTunnelManager.isTunnelLogLineReady("debug1: Entering interactive session."))
        XCTAssertFalse(SSHTunnelManager.isTunnelLogLineReady("debug1: Connecting to bastion.example.test [192.0.2.1] port 22."))

        // 2FA / TOTP prompt must NOT be accepted as a login password
        let pwAuth = ChildProcessAuthentication(kind: .password, secret: "login-pw")
        XCTAssertTrue(pwAuth.accepts(prompt: "qa@example.test's password: ", hint: nil))
        XCTAssertFalse(pwAuth.accepts(prompt: "One-time password (OATH) for `qa': ", hint: nil))
        XCTAssertFalse(pwAuth.accepts(prompt: "Verification code: ", hint: nil))
        XCTAssertFalse(pwAuth.accepts(prompt: "Enter 2FA passcode: ", hint: nil))

        XCTAssertEqual(NativeSSHSession.classifyPTYPrompt("Verification code:"), .twoFactor)
        XCTAssertEqual(NativeSSHSession.classifyPTYPrompt("One-time password (OATH) for ops:"), .twoFactor)
        XCTAssertEqual(NativeSSHSession.classifyPTYPrompt("ops@host's password: "), .password)

        let hostKeyErr = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "Host key verification failed."
        )
        XCTAssertTrue(hostKeyErr.contains("Host key verification failed"))
        XCTAssertTrue(hostKeyErr.contains("主机指纹"))
    }

    // MARK: - TC-V30-18: AgentlessMonitor LC_ALL=C, BusyBox ps, macOS >1d uptime, wg0/br0 & ProcessDetailItem
    func testTC_V30_18_AgentlessMonitorCrossDistroAndProcessParsing() {
        for cmd in [
            AgentlessMonitor.linuxProbeCommand,
            AgentlessMonitor.macosProbeCommand,
            AgentlessMonitor.autoProbeCommand,
            AgentlessMonitor.processInspectorProbeCommand,
            AgentlessMonitor.listeningPortsProbeCommand,
            AgentlessMonitor.containerListProbeCommand,
            AgentlessMonitor.systemdDynamicProbeCommand,
            AgentlessMonitor.systemdServicesProbeCommand()
        ] {
            XCTAssertTrue(cmd.contains("LC_ALL=C"), "Probe command must force LC_ALL=C: \(cmd.prefix(60))")
        }

        // Container probe falls back from failed docker to podman
        XCTAssertTrue(AgentlessMonitor.containerListProbeCommand.contains("DOCKER_RC"))
        XCTAssertTrue(AgentlessMonitor.containerListProbeCommand.contains("PODMAN_OUT"))

        // macOS >1d uptime sums daysSec + subDaySec and never fabricates 3600 on invalid input
        let monitor = AgentlessMonitor()
        var net: AgentlessMonitor.NetTickState? = nil
        let macRaw = """
        CPU usage: 10.0% user, 5.0% sys, 85.0% idle
        PhysMem: 8G used (2048M wired), 8G unused.
        ---UPTIME---
        10:15  up 3 days,  4:25, 2 users, load averages: 1.20 1.10 1.05
        """
        let macSnap = monitor.parseMacOSOutput(macRaw, prevNet: &net)
        XCTAssertEqual(macSnap.uptimeSeconds, 3 * 86400 + 4 * 3600 + 25 * 60)

        let invalidUptimeRaw = """
        CPU usage: 5.0% user, 5.0% sys, 90.0% idle
        PhysMem: 4G used, 4G unused.
        ---UPTIME---
        unknown uptime output
        """
        let invalidSnap = monitor.parseMacOSOutput(invalidUptimeRaw, prevNet: &net)
        XCTAssertEqual(invalidSnap.uptimeSeconds, 0)

        // Linux wg0/br0/tailscale0 interfaces + BusyBox TOP fallback
        let linuxRaw = """
        cpu  100 0 50 850 0 0 0 0 0 0
        cpu0 100 0 50 850 0 0 0 0 0 0
        MemTotal:        8000000 kB
        MemAvailable:    4000000 kB
           wg0:  1000 10 0 0 0 0 0 0  2000 20 0 0 0 0 0 0
           br0:   500  5 0 0 0 0 0 0   500  5 0 0 0 0 0 0
        tailscale0: 200 2 0 0 0 0 0 0  300  3 0 0 0 0 0 0
        ---TOP---
        PID USER VSZ COMMAND
        101 root 1234 busybox-app
        """
        var cpu: AgentlessMonitor.CpuTickState? = nil
        var netLinux: AgentlessMonitor.NetTickState? = nil
        let linuxSnap = monitor.parseLinuxOutput(linuxRaw, prevCpu: &cpu, prevNet: &netLinux)
        XCTAssertEqual(linuxSnap.topProcesses.first?.command, "busybox-app")
        XCTAssertEqual(netLinux?.rx, 1700)
        XCTAssertEqual(netLinux?.tx, 2800)

        // BusyBox ps output & macOS I-state + spaced comm
        let busyBoxPS = """
          PID USER     RSS    VSZ STAT COMMAND ARGS
            1 root    2048   4096 S    /sbin/init /sbin/init
           42 app    16384  32768 I    /usr/bin/worker /usr/bin/worker --daemon
        """
        let bbParsed = ProcessListParser.parsePSOutput(busyBoxPS)
        XCTAssertEqual(bbParsed.count, 2)
        XCTAssertEqual(bbParsed[1].pid, 42)
        XCTAssertEqual(bbParsed[1].rssBytes, 16384 * 1024)
        XCTAssertEqual(bbParsed[1].state, .sleeping)
        XCTAssertEqual(bbParsed[1].command, "worker")
        XCTAssertEqual(bbParsed[1].fullCommandLine, "/usr/bin/worker --daemon")

        let macPS = """
          PID USER     %CPU %MEM   RSS    VSZ STAT COMM                                                      COMMAND
          501 qa        2.5  1.0 65536 512000 I    /Applications/My App.app/Contents/MacOS/My App            /Applications/My App.app/Contents/MacOS/My App --port 8080
        """
        let macParsed = ProcessListParser.parsePSOutput(macPS)
        XCTAssertEqual(macParsed.count, 1)
        XCTAssertEqual(macParsed[0].state, .sleeping)
        XCTAssertEqual(macParsed[0].command, "My App")
        XCTAssertEqual(macParsed[0].fullCommandLine, "/Applications/My App.app/Contents/MacOS/My App --port 8080")
    }

    // MARK: - TC-V30-19: parseDirectoryListing leading whitespace, non-epoch dates & short control socket ID
    func testTC_V30_19_ParseDirectoryListingLeadingWhitespaceDatesAndShortSocket() throws {
        let listing = [
            "-rw-r--r-- 1 qa staff 42 946684800  leading.txt",
            "-rw-r--r-- 1 qa staff 84 2026-11-25 14:30   two_leading.txt",
            "-rw-r--r-- 1 qa staff 99 Nov 25 2024  bsd_space.log",
            "lrwxrwxrwx 1 qa staff 15 1700000000  spaced link -> /opt/target"
        ].joined(separator: "\n")

        let items = NativeSSHSession.parseDirectoryListing(listing, path: "/srv")
        XCTAssertEqual(items.count, 4)

        XCTAssertEqual(items[0].name, " leading.txt")
        XCTAssertEqual(items[0].path, "/srv/ leading.txt")
        XCTAssertEqual(items[0].modificationDate.timeIntervalSince1970, 946684800)

        XCTAssertEqual(items[1].name, "  two_leading.txt")
        let isoComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: items[1].modificationDate)
        XCTAssertEqual(isoComponents.year, 2026)
        XCTAssertEqual(isoComponents.month, 11)
        XCTAssertEqual(isoComponents.day, 25)
        XCTAssertEqual(isoComponents.hour, 14)
        XCTAssertEqual(isoComponents.minute, 30)

        XCTAssertEqual(items[2].name, " bsd_space.log")
        let bsdComponents = Calendar.current.dateComponents([.year, .month, .day], from: items[2].modificationDate)
        XCTAssertEqual(bsdComponents.year, 2024)
        XCTAssertEqual(bsdComponents.month, 11)
        XCTAssertEqual(bsdComponents.day, 25)

        XCTAssertEqual(items[3].name, " spaced link")
        XCTAssertTrue(items[3].isSymlink)

        // Short socket filename in App Store sandbox container
        let client = NativeSSHSession(
            session: makeSession(name: "sandbox"),
            distributionChannel: .appStore,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: tempDir
        )
        let socketName = URL(fileURLWithPath: client.controlSocketPath).lastPathComponent
        XCTAssertTrue(socketName.hasPrefix("apx-"))
        XCTAssertEqual(socketName.count, 12, "Shortened socket filename apx-<8hex> saves sun_path budget")
    }
}
