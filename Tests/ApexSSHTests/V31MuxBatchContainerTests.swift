import XCTest
import Darwin
import os
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

final class V31MuxBatchContainerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("V31MuxBatchTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        SSHControlMasterPool.isPoolEnabled = true
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - TC-V31-01: SSHControlMasterPool key determinism & refcount teardown
    func testTC_V31_01_PoolKeyDeterminismAndRefcountTeardown() {
        let hop1 = Session(name: "bastion1", host: "bastion1.example.test", port: 2201, username: "jump")
        let hop2 = Session(name: "bastion2", host: "bastion2.example.test", port: 2202, username: "jump")

        let baseSession = Session(
            name: "app-prod",
            host: "10.0.5.20",
            port: 22,
            username: "deploy",
            authMethod: .privateKey(keychainRef: "/tmp/key_a", passphraseRef: nil),
            jumpServerChain: [hop1.id],
            proxyCommand: nil
        )
        let keyA1 = SSHControlMasterPool.makeKey(for: baseSession, resolvedJumpHops: [hop1])
        let keyA2 = SSHControlMasterPool.makeKey(for: baseSession, resolvedJumpHops: [hop1])
        XCTAssertEqual(keyA1, keyA2)
        XCTAssertEqual(keyA1.directSocketIdentifier, keyA2.directSocketIdentifier)
        XCTAssertTrue(keyA1.directSocketIdentifier.hasPrefix("s-"))
        XCTAssertEqual(keyA1.directSocketIdentifier.count, 10)
        XCTAssertEqual(keyA1.sandboxHexIdentifier.count, 6)

        // Any dimension change must yield a distinct connection key
        var diffUser = baseSession; diffUser.username = "root"
        var diffPort = baseSession; diffPort.port = 2222
        var diffKey = baseSession; diffKey.authMethod = .privateKey(keychainRef: "/tmp/key_b", passphraseRef: nil)
        var diffProxy = baseSession; diffProxy.proxyCommand = "nc -X 5 -x 127.0.0.1:1080 %h %p"
        let diffJump = SSHControlMasterPool.makeKey(for: baseSession, resolvedJumpHops: [hop1, hop2])

        XCTAssertNotEqual(keyA1, SSHControlMasterPool.makeKey(for: diffUser, resolvedJumpHops: [hop1]))
        XCTAssertNotEqual(keyA1, SSHControlMasterPool.makeKey(for: diffPort, resolvedJumpHops: [hop1]))
        XCTAssertNotEqual(keyA1, SSHControlMasterPool.makeKey(for: diffKey, resolvedJumpHops: [hop1]))
        XCTAssertNotEqual(keyA1, SSHControlMasterPool.makeKey(for: diffProxy, resolvedJumpHops: [hop1]))
        XCTAssertNotEqual(keyA1, diffJump)

        let tornDownPaths = OSAllocatedUnfairLock(initialState: [String]())
        let pool = SSHControlMasterPool(directSocketDirectory: tempDir) { socketPath, _, _, _, _, _, _ in
            tornDownPaths.withLock { $0.append(socketPath) }
        }

        let lease1 = pool.acquireSocket(for: baseSession, resolvedJumpHops: [hop1], distributionChannel: .direct)
        let lease2 = pool.acquireSocket(for: baseSession, resolvedJumpHops: [hop1], distributionChannel: .direct)
        XCTAssertEqual(lease1.socketPath, lease2.socketPath)
        XCTAssertEqual(pool.activeLeaseCount(for: keyA1), 2)
        XCTAssertEqual(pool.activeSocketCount, 1)

        // Release first lease -> socket stays alive
        pool.releaseSocket(lease1)
        XCTAssertEqual(pool.activeLeaseCount(for: keyA1), 1)
        XCTAssertTrue(tornDownPaths.withLock { $0.isEmpty })

        // Duplicate release of lease1 is idempotent and does not decrement lease2
        pool.releaseSocket(lease1)
        XCTAssertEqual(pool.activeLeaseCount(for: keyA1), 1)
        XCTAssertTrue(tornDownPaths.withLock { $0.isEmpty })

        // Release last lease -> teardown fires once
        pool.releaseSocket(lease2)
        XCTAssertEqual(pool.activeLeaseCount(for: keyA1), 0)
        XCTAssertEqual(pool.activeSocketCount, 0)
        XCTAssertEqual(tornDownPaths.withLock { $0 }, [lease1.socketPath])

        // closeAll() tears down all remaining sockets across keys
        _ = pool.acquireSocket(for: baseSession, resolvedJumpHops: [hop1], distributionChannel: .direct)
        _ = pool.acquireSocket(for: diffPort, resolvedJumpHops: [hop1], distributionChannel: .direct)
        XCTAssertEqual(pool.activeSocketCount, 2)
        pool.closeAll()
        XCTAssertEqual(pool.activeSocketCount, 0)
        XCTAssertEqual(pool.totalActiveLeaseCount, 0)
        XCTAssertEqual(tornDownPaths.withLock { $0.count }, 3)
    }

    // MARK: - TC-V31-02: NativeSSHSession mux arg wiring & SandboxSSHPaths short socket parity
    func testTC_V31_02_NativeSSHSessionMuxWiringAndSandboxSocketParity() async {
        // Preserve SandboxSSHPaths 86-byte boundary invariant
        let fitting = SandboxSSHPaths(
            home: tempDir,
            temporary: URL(fileURLWithPath: "/" + String(repeating: "a", count: 79)),
            identifier: "a"
        )
        XCTAssertEqual(fitting.controlSocket.path.utf8.count, 86)
        XCTAssertTrue(fitting.canUseControlSocket)

        let shortTempDir = URL(fileURLWithPath: "/tmp/v31_\(String(UUID().uuidString.prefix(6)))", isDirectory: true)
        try? FileManager.default.createDirectory(at: shortTempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shortTempDir) }

        let pooledSandbox = SandboxSSHPaths.pooled(home: tempDir, temporary: shortTempDir, hexIdentifier: "abcdef123456")
        XCTAssertEqual(pooledSandbox.controlSocket.lastPathComponent, "apx-abcdef")
        XCTAssertTrue(pooledSandbox.canUseControlSocket)

        let tornDownSockets = OSAllocatedUnfairLock(initialState: [String]())
        let pool = SSHControlMasterPool(directSocketDirectory: shortTempDir) { socketPath, _, _, _, _, _, _ in
            tornDownSockets.withLock { $0.append(socketPath) }
        }
        let session = Session(name: "mux-host", host: "10.10.10.5", port: 22, username: "ops")

        let tab1 = NativeSSHSession(
            session: session,
            distributionChannel: .direct,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: shortTempDir,
            controlPool: pool,
            useControlPool: true
        )
        let tab2 = NativeSSHSession(
            session: session,
            distributionChannel: .direct,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: shortTempDir,
            controlPool: pool,
            useControlPool: true
        )

        let lease1 = tab1.ensurePoolLeaseIfNeeded()
        let lease2 = tab2.ensurePoolLeaseIfNeeded()
        XCTAssertNotNil(lease1)
        XCTAssertEqual(lease1?.socketPath, lease2?.socketPath)
        XCTAssertEqual(tab1.controlSocketPath, tab2.controlSocketPath)
        XCTAssertEqual(pool.activeLeaseCount(for: session), 2)

        let connectMux = tab1.controlMuxConnectArguments()
        XCTAssertTrue(connectMux.contains("ControlMaster=auto"))
        XCTAssertTrue(connectMux.contains("ControlPersist=4h"))
        XCTAssertTrue(connectMux.contains(where: { $0.hasPrefix("ControlPath=") && $0.contains("s-") }))

        let scpMux = tab1.scpControlMasterArguments()
        XCTAssertTrue(scpMux.contains("ControlMaster=auto"))
        XCTAssertTrue(scpMux.contains("ControlPersist=4h"))
        XCTAssertTrue(scpMux.contains(where: { $0.hasPrefix("ControlPath=") && $0.contains("s-") }))

        // App Store sandbox pooled socket uses apx-<6hex>
        let storePool = SSHControlMasterPool(directSocketDirectory: shortTempDir) { socketPath, _, _, _, _, _, _ in
            tornDownSockets.withLock { $0.append(socketPath) }
        }
        let storeTab = NativeSSHSession(
            session: session,
            distributionChannel: .appStore,
            sandboxHomeURL: tempDir,
            sandboxTemporaryURL: shortTempDir,
            controlPool: storePool,
            useControlPool: true
        )
        let storeLease = storeTab.ensurePoolLeaseIfNeeded()
        XCTAssertTrue(storeLease?.shortID.hasPrefix("apx-") == true)
        XCTAssertEqual(storeLease?.shortID.count, 10)
        XCTAssertTrue(storeLease?.canUseControlSocket == true)
        await storeTab.disconnect()

        // Disconnecting tab1 retains tab2's pooled socket; disconnecting tab2 tears it down
        await tab1.disconnect()
        XCTAssertEqual(pool.activeLeaseCount(for: session), 1)
        XCTAssertTrue(tornDownSockets.withLock { $0 }.filter { $0 == lease1?.socketPath }.isEmpty)
        await tab2.disconnect()
        XCTAssertEqual(pool.activeLeaseCount(for: session), 0)
        XCTAssertEqual(tornDownSockets.withLock { $0 }.filter { $0 == lease1?.socketPath }.count, 1)

        // Disabled pool / disableControlPersist suppresses mux options
        let noMuxClient = NativeSSHSession(
            session: session,
            distributionChannel: .direct,
            disableControlPersist: true,
            controlPool: pool,
            useControlPool: true
        )
        XCTAssertNil(noMuxClient.ensurePoolLeaseIfNeeded())
        XCTAssertTrue(noMuxClient.controlMuxConnectArguments().contains("ControlMaster=no"))
        XCTAssertTrue(noMuxClient.scpControlMasterArguments().contains("ControlMaster=no"))
    }

    // MARK: - TC-V31-03: BatchCommandTemplate persistence, {{var}} interpolation & [PROD] detection
    @MainActor
    func testTC_V31_03_BatchCommandTemplatePersistenceAndInterpolation() throws {
        let suite = "v31-batch-tpl-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BatchCommandTemplateStore(defaults: defaults, storageKey: "test.batch.templates")
        XCTAssertGreaterThanOrEqual(store.templates.count, BatchCommandTemplate.curatedDefaults.count)

        let custom = store.addTemplate(
            name: "Rolling Reload",
            command: "systemctl reload {{service}} && echo \"{{date}} {{env}}\"",
            category: "Deploy"
        )
        XCTAssertEqual(custom.extractVariables(), ["service", "env"])

        // Reload from UserDefaults
        let reloaded = BatchCommandTemplateStore(defaults: defaults, storageKey: "test.batch.templates")
        let fetched = try XCTUnwrap(reloaded.templates.first(where: { $0.id == custom.id }))
        XCTAssertEqual(fetched.name, "Rolling Reload")

        let fixedDate = Date(timeIntervalSince1970: 1_764_115_200) // 2025-11-26 UTC
        let resolved = fetched.resolvedCommand(context: ["service": "nginx", "env": "prod"], date: fixedDate)
        XCTAssertTrue(resolved.hasPrefix("systemctl reload nginx && echo \""))
        XCTAssertTrue(resolved.contains("prod"))
        XCTAssertFalse(resolved.contains("{{service}}"))
        XCTAssertFalse(resolved.contains("{{date}}"))

        // Go template syntax inside docker ps --format must NOT trigger variable prompts
        let dockerTpl = BatchCommandTemplate(
            name: "Docker",
            command: "docker ps --format '{{.Names}}\\t{{.Status}}' | grep {{app}}"
        )
        XCTAssertEqual(dockerTpl.extractVariables(), ["app"])

        // [PROD] / #FF453A detection
        let prodTagSession = Session(name: "api-1", host: "10.0.1.1", username: "ops", tags: ["[PROD]", "web"])
        let redColorSession = Session(name: "db-1", host: "10.0.1.2", username: "ops", colorHex: "#FF453A")
        let devSession = Session(name: "dev-1", host: "10.0.1.3", username: "ops", tags: ["dev"], colorHex: "#0A84FF")
        XCTAssertTrue(BatchOperationsSheet.isProductionSession(prodTagSession))
        XCTAssertTrue(BatchOperationsSheet.isProductionSession(redColorSession))
        XCTAssertFalse(BatchOperationsSheet.isProductionSession(devSession))

        reloaded.deleteTemplate(id: custom.id)
        XCTAssertNil(reloaded.templates.first(where: { $0.id == custom.id }))
    }

    // MARK: - TC-V31-04: BatchOperationsManager mkdir -p preflight & directory distribution
    @MainActor
    func testTC_V31_04_BatchMkdirPreflightAndDirectoryDistribution() async throws {
        // Command builder checks
        XCTAssertEqual(
            BatchOperationsManager.makeRemoteDirectoryCommand(for: "/opt/my app/releases"),
            "mkdir -p '/opt/my app/releases'"
        )
        XCTAssertEqual(
            BatchOperationsManager.makeRemoteDirectoryCommand(for: "~/deploy/v1"),
            "mkdir -p \"$HOME/\"'deploy/v1'"
        )
        XCTAssertNil(BatchOperationsManager.makeRemoteDirectoryCommand(for: "/"))

        let localDir = tempDir.appendingPathComponent("dist-bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: localDir.appendingPathComponent("app.bin"))

        let s1 = Session(name: "web-1", host: "10.0.2.1", username: "deploy")
        let s2 = Session(name: "web-2", host: "10.0.2.2", username: "deploy")
        let events = OSAllocatedUnfairLock(initialState: [UUID: [String]]())

        let manager = BatchOperationsManager(maxConcurrency: 2) { session in
            let mock = MockSSHSession(session: session)
            mock.customExecuteCommandResultHandler = { cmd in
                events.withLock { $0[session.id, default: []].append("cmd:\(cmd)") }
                if session.id == s2.id {
                    return SSHCommandResult(stdout: "", stderr: "mkdir: permission denied", exitCode: 1, durationMs: 5)
                }
                return SSHCommandResult(stdout: "", stderr: "", exitCode: 0, durationMs: 5)
            }
            mock.customUploadHandler = { localURL, remotePath, progress in
                events.withLock { $0[session.id, default: []].append("upload:\(localURL.lastPathComponent)->\(remotePath)") }
                progress(1.0)
            }
            return mock
        }

        await manager.distributeFiles(
            [localDir],
            toRemoteDirectory: "/opt/app releases",
            on: [s1, s2],
            createRemoteDirectory: true
        )

        let s1Events = events.withLock { $0[s1.id] ?? [] }
        let s2Events = events.withLock { $0[s2.id] ?? [] }
        XCTAssertEqual(s1Events, [
            "cmd:mkdir -p '/opt/app releases'",
            "upload:dist-bundle->/opt/app releases/dist-bundle"
        ])
        XCTAssertEqual(s2Events, ["cmd:mkdir -p '/opt/app releases'"], "Upload must abort when mkdir -p preflight fails")
        XCTAssertEqual(manager.succeededCount, 1)
        XCTAssertEqual(manager.failedCount, 1)
    }

    // MARK: - TC-V31-05: docker stats, docker compose ls, OpenRC rc-status & systemctl status/cat
    func testTC_V31_05_ContainerStatsComposeStacksOpenRCAndSystemdViewCommands() {
        let containers = AgentlessMonitor.parseContainerOutput("""
        ---RUNTIME:docker---
        a1b2c3d4e5f6\tapi-gateway\tnginx:1.27\trunning\tUp 2h\t0.0.0.0:80->80/tcp
        112233445566\tworker\tpython:3.12\texited\tExited (0)\t
        """)
        let statsRaw = """
        a1b2c3d4e5f6\tapi-gateway\t3.45%\t42.5MiB / 1.95GiB\t2.13%\t12.4MB / 3.1MB\t820kB / 0B\t6
        """
        let parsedStats = AgentlessMonitor.parseContainerStatsOutput(statsRaw)
        XCTAssertEqual(parsedStats.count, 1)
        XCTAssertEqual(parsedStats[0].cpuPercent, 3.45, accuracy: 0.001)
        XCTAssertEqual(parsedStats[0].memUsageText, "42.5MiB / 1.95GiB")
        XCTAssertEqual(parsedStats[0].netIOText, "12.4MB / 3.1MB")
        XCTAssertEqual(parsedStats[0].blockIOText, "820kB / 0B")

        let merged = AgentlessMonitor.mergingStats(parsedStats, into: containers.items)
        XCTAssertNotNil(merged[0].stats)
        XCTAssertEqual(merged[0].stats?.cpuPercentText, "3.45%")
        XCTAssertNil(merged[1].stats)

        // Docker Compose JSON + tabular parsing
        let composeJSON = """
        [{"Name":"prod-stack","Status":"running(3)","ConfigFiles":"/srv/prod/compose.yaml"},{"Name":"staging","Status":"exited(1)","ConfigFiles":"/srv/staging/compose.yaml"}]
        """
        let jsonStacks = AgentlessMonitor.parseDockerComposeStacksOutput(composeJSON)
        XCTAssertEqual(jsonStacks.count, 2)
        XCTAssertEqual(jsonStacks[0].name, "prod-stack")
        XCTAssertTrue(jsonStacks[0].isRunning)
        XCTAssertFalse(jsonStacks[1].isRunning)

        let composeTable = """
        NAME                STATUS              CONFIG FILES
        core-infra          running(4)          /opt/core/docker-compose.yml
        """
        let tableStacks = AgentlessMonitor.parseDockerComposeStacksOutput(composeTable)
        XCTAssertEqual(tableStacks.count, 1)
        XCTAssertEqual(tableStacks[0].name, "core-infra")
        XCTAssertEqual(tableStacks[0].configFiles, "/opt/core/docker-compose.yml")

        // Alpine OpenRC rc-status parser + sshd stop guard
        let openRCRaw = """
        Runlevel: default
         sshd                                                              [  started  ]
         nginx                                                             [  started  ]
         redis                                                             [  stopped  ]
         worker                                                            [  crashed  ]
        Dynamic Runlevel: hotplugged
        """
        let openRCServices = AgentlessMonitor.parseOpenRCOutput(openRCRaw)
        XCTAssertEqual(openRCServices.count, 4)
        XCTAssertEqual(openRCServices[0].name, "worker")
        XCTAssertEqual(openRCServices[0].activeState, "failed")
        XCTAssertTrue(openRCServices.contains(where: { $0.name == "nginx" && $0.isRunning && $0.subState == "openrc (started)" }))
        XCTAssertNil(AgentlessMonitor.openRCActionCommand(unit: "sshd", action: .stop))
        XCTAssertEqual(AgentlessMonitor.openRCActionCommand(unit: "nginx", action: .restart), "rc-service 'nginx' restart 2>&1")

        // Systemd status & cat builders
        XCTAssertEqual(AgentlessMonitor.systemdStatusCommand(unit: "nginx"), "systemctl status 'nginx' --no-pager -n 30 2>&1")
        XCTAssertEqual(AgentlessMonitor.systemdCatCommand(unit: "nginx"), "systemctl cat 'nginx' --no-pager 2>&1")
        XCTAssertNil(AgentlessMonitor.systemdCatCommand(unit: "nginx;id"))
    }

    // MARK: - TC-V31-06: Tunnel autoReconnect backoff & live stderr ring buffer
    @MainActor
    func testTC_V31_06_TunnelAutoReconnectBackoffAndStderrRingBuffer() async throws {
        // Codable policy defaults autoReconnect to false
        let emptyPolicy = try JSONDecoder().decode(SSHTunnelPolicy.self, from: Data("{}".utf8))
        XCTAssertFalse(emptyPolicy.autoReconnect)

        // Exponential backoff progression capped at 30s
        XCTAssertEqual(SSHTunnelManager.reconnectBackoffDelaySeconds(attempt: 1), 2.0)
        XCTAssertEqual(SSHTunnelManager.reconnectBackoffDelaySeconds(attempt: 2), 4.0)
        XCTAssertEqual(SSHTunnelManager.reconnectBackoffDelaySeconds(attempt: 3), 8.0)
        XCTAssertEqual(SSHTunnelManager.reconnectBackoffDelaySeconds(attempt: 4), 16.0)
        XCTAssertEqual(SSHTunnelManager.reconnectBackoffDelaySeconds(attempt: 5), 30.0)
        XCTAssertEqual(SSHTunnelManager.reconnectBackoffDelaySeconds(attempt: 6), 30.0)

        let manager = SSHTunnelManager(
            baseDirectory: tempDir,
            baseReconnectDelaySeconds: 0.02,
            maxReconnectDelaySeconds: 0.05
        )
        let session = Session(name: "tun-host", host: "10.0.8.8", username: "ops")
        let tunnel = SSHTunnel(name: "RetryTun", type: .local, sessionId: session.id, bindPort: 18888, targetPort: 80)
        try manager.addTunnel(tunnel)
        manager.setAutoReconnect(true, for: tunnel.id)

        let countFile = tempDir.appendingPathComponent("run_count.txt")
        let script = tempDir.appendingPathComponent("fail255.sh")
        try """
        #!/bin/sh
        echo "run" >> "\(countFile.path)"
        echo "connection dropped unexpectedly" >&2
        exit 255
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        try manager.startCustomProcessForTesting(
            id: tunnel.id,
            executableURL: script,
            arguments: [],
            session: session
        )

        // Wait for initial launch + up to 5 capped retries (total < 400ms)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if case .failed(let msg) = manager.state(for: tunnel.id),
               msg.contains("自动重连已达上限") {
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let runsRaw = (try? String(contentsOf: countFile, encoding: .utf8)) ?? ""
        let runCount = runsRaw.split(separator: "\n").count
        XCTAssertEqual(runCount, 1 + SSHTunnelManager.maxAutoReconnectAttempts)
        XCTAssertTrue(manager.stderrLogText(for: tunnel.id).contains("connection dropped unexpectedly"))
        XCTAssertTrue(manager.stderrLogText(for: tunnel.id).contains("自动重连"))

        // Policy persists across reload
        let reloaded = SSHTunnelManager(baseDirectory: tempDir)
        XCTAssertTrue(reloaded.isAutoReconnectEnabled(for: tunnel.id))
        manager.stopAll()
    }

    // MARK: - TC-V31-07: Bastion/Route diagnostics port bind, SSH_AUTH_SOCK, hops & known_hosts cleanup
    @MainActor
    func testTC_V31_07_BastionRouteDiagnosticsAndKnownHostsRemoval() async throws {
        // Bind an ephemeral port to verify EADDRINUSE detection
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(sock, 0)
        defer { Darwin.close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindRC, 0)
        XCTAssertEqual(Darwin.listen(sock, 1), 0)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        let occupiedPort = Int(UInt16(bigEndian: bound.sin_port))
        let busyCheck = SSHTunnelManager.checkLocalPortAvailability(host: "127.0.0.1", port: occupiedPort)
        XCTAssertFalse(busyCheck.available)
        XCTAssertTrue(busyCheck.message.contains("已被占用"))

        // Prepare known_hosts with conflicting fingerprints for target host
        let khFile = tempDir.appendingPathComponent("known_hosts")
        try """
        bastion.internal ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBastionValidKeyMaterial111111111111111111
        [10.20.0.5]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFirstKeyFingerprint111111111111111111
        [10.20.0.5]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISecondConflictingFingerprint22222222222
        """.write(to: khFile, atomically: true, encoding: .utf8)
        let khManager = KnownHostsManager(fileURL: khFile)
        XCTAssertEqual(khManager.conflicts.count, 1)

        // Prepare fake SSH_AUTH_SOCK file
        let fakeSock = tempDir.appendingPathComponent("agent.sock")
        try Data().write(to: fakeSock)

        let jumpHop = Session(name: "bastion", host: "bastion.internal", port: 22, username: "jump")
        let target = Session(name: "db", host: "10.20.0.5", port: 2222, username: "dba", jumpServerChain: [jumpHop.id], forwardAgent: true)
        let tunnel = SSHTunnel(name: "DiagTun", type: .local, sessionId: target.id, bindHost: "127.0.0.1", bindPort: occupiedPort, targetPort: 5432)

        let manager = SSHTunnelManager(baseDirectory: tempDir)
        let report = await manager.diagnoseTunnel(
            tunnel,
            session: target,
            jumpChain: [jumpHop],
            knownHostsManager: khManager,
            environment: ["SSH_AUTH_SOCK": fakeSock.path],
            reachabilityProber: { host, _, _ in
                if host == "bastion.internal" {
                    return (true, 12, "TCP 可达 (12 ms)")
                }
                return (false, nil, "TCP 连接超时")
            }
        )

        XCTAssertFalse(report.isLocalPortAvailable)
        XCTAssertTrue(report.isSSHAuthSockAvailable)
        XCTAssertTrue(report.forwardAgentEnabled)
        XCTAssertEqual(report.hopResults.count, 2)
        XCTAssertTrue(report.hopResults[0].isReachable)
        XCTAssertEqual(report.hopResults[0].latencyMs, 12)
        XCTAssertFalse(report.hopResults[0].hasHostKeyConflict)
        XCTAssertFalse(report.hopResults[1].isReachable)
        XCTAssertTrue(report.hopResults[1].hasHostKeyConflict)
        XCTAssertTrue(report.hasHostKeyConflict)
        XCTAssertEqual(report.conflictHost, "10.20.0.5")
        XCTAssertEqual(report.conflictPort, 2222)

        // One-click removal clears conflict
        let removed = try SSHTunnelManager.clearHostKeyConflict(host: "10.20.0.5", port: 2222, knownHostsManager: khManager)
        XCTAssertEqual(removed, 2)
        XCTAssertTrue(khManager.conflicts.isEmpty)
    }
}
