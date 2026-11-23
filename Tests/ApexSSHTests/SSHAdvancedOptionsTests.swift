import XCTest
@testable import ApexCore
@testable import ApexSSH

/// RG-15: Professional SSH Options & Multi-Hop Jump Chains (`TC-V24-12 ~ TC-V24-16`).
final class SSHAdvancedOptionsTests: XCTestCase {

    // MARK: - TC-V24-12: Legacy Session JSON backward compatibility & jumpServerId -> jumpServerChain normalization
    func testTC_V24_12_LegacySessionJSONCompatibility() throws {
        let sessionId = UUID()
        let jumpId = UUID()
        let legacyJSON = """
        {
          "id": "\(sessionId.uuidString)",
          "name": "legacy-host",
          "host": "10.20.30.40",
          "port": 22,
          "username": "deploy",
          "authMethod": {"agent": {}},
          "jumpServerId": "\(jumpId.uuidString)"
        }
        """
        let decoded = try JSONDecoder().decode(Session.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.jumpServerId, jumpId)
        XCTAssertEqual(decoded.jumpServerChain, [jumpId])
        XCTAssertEqual(decoded.effectiveJumpServerChain, [jumpId])
        XCTAssertFalse(decoded.forwardAgent)
        XCTAssertFalse(decoded.compression)
        XCTAssertNil(decoded.proxyCommand)

        // Roundtrip encode/decode preserves multi-hop & advanced flags
        let multi = Session(
            name: "multi",
            host: "10.0.0.99",
            port: 2222,
            username: "ops",
            jumpServerChain: [jumpId, UUID()],
            forwardAgent: true,
            compression: true,
            proxyCommand: "nc -X 5 -x 127.0.0.1:1080 %h %p"
        )
        let data = try JSONEncoder().encode(multi)
        let roundtripped = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(roundtripped.jumpServerChain, multi.jumpServerChain)
        XCTAssertEqual(roundtripped.jumpServerId, multi.jumpServerChain.first)
        XCTAssertTrue(roundtripped.forwardAgent)
        XCTAssertTrue(roundtripped.compression)
        XCTAssertEqual(roundtripped.proxyCommand, multi.proxyCommand)
    }

    // MARK: - TC-V24-13: Multi-hop -J, -A (interactive only, never on scp), -C, ProxyCommand & cycle detection
    func testTC_V24_13_SSHArgumentBuilderAndCycleDetection() {
        let hop1 = Session(name: "bastion1", host: "bastion1.example.com", port: 2201, username: "jump1")
        let hop2 = Session(name: "bastion2", host: "::1", port: 2202, username: "jump2")
        let target = Session(
            name: "db",
            host: "10.0.5.10",
            port: 22,
            username: "dba",
            jumpServerChain: [hop1.id, hop2.id],
            forwardAgent: true,
            compression: true
        )

        let resolved = SSHArgumentBuilder.resolveJumpChain(for: target, availableSessions: [hop1, hop2, target])
        XCTAssertFalse(resolved.hasCycle)
        XCTAssertEqual(resolved.hops.map(\.id), [hop1.id, hop2.id])

        // Interactive SSH includes -A, -C, and multi-hop -J
        let interactiveArgs = SSHArgumentBuilder.buildAdvancedOptions(
            for: target,
            channel: .interactiveSSH,
            resolvedJumpHops: resolved.hops
        )
        XCTAssertEqual(interactiveArgs, ["-A", "-C", "-J", "jump1@bastion1.example.com:2201,jump2@[::1]:2202"])

        // SCP MUST NOT emit -A
        let scpArgs = SSHArgumentBuilder.buildAdvancedOptions(
            for: target,
            channel: .scp,
            resolvedJumpHops: resolved.hops
        )
        XCTAssertFalse(scpArgs.contains("-A"))
        XCTAssertEqual(scpArgs, ["-C", "-J", "jump1@bastion1.example.com:2201,jump2@[::1]:2202"])

        // ProxyCommand overrides -J
        var proxied = target
        proxied.proxyCommand = "nc -X 5 -x 127.0.0.1:1080 %h %p"
        let proxyArgs = SSHArgumentBuilder.buildAdvancedOptions(
            for: proxied,
            channel: .interactiveSSH,
            resolvedJumpHops: resolved.hops
        )
        XCTAssertEqual(proxyArgs, ["-A", "-C", "-o", "ProxyCommand=nc -X 5 -x 127.0.0.1:1080 %h %p"])

        // Cycle detection (A -> B -> A)
        var cycleA = Session(name: "A", host: "a.local", username: "u")
        let cycleB = Session(name: "B", host: "b.local", username: "u", jumpServerChain: [cycleA.id])
        cycleA.jumpServerChain = [cycleB.id]
        XCTAssertTrue(SSHArgumentBuilder.hasJumpCycle(startingAt: cycleA.id, jumpChain: [cycleB.id], allSessions: [cycleA, cycleB]))

        // SSHTunnelManager also supports multi-hop -J & -C
        let tunnel = SSHTunnel(name: "db-fwd", type: .local, sessionId: target.id, bindHost: "127.0.0.1", bindPort: 15432, targetHost: "127.0.0.1", targetPort: 5432)
        let tunnelArgs = SSHTunnelManager.buildSSHArguments(tunnel: tunnel, session: target, jumpChain: [hop1, hop2])
        XCTAssertTrue(tunnelArgs.contains("-C"))
        XCTAssertFalse(tunnelArgs.contains("-A"))
        XCTAssertTrue(tunnelArgs.contains("jump1@bastion1.example.com:2201,jump2@[::1]:2202"))

        // NativeSSHSession separates interactive SSH (-A allowed) vs SCP (-A forbidden)
        let client = NativeSSHSession(session: target)
        client.customJumpChain = [hop1, hop2]
        XCTAssertTrue(client.advancedConnectionArgs(channel: .interactiveSSH).contains("-A"))
        XCTAssertFalse(client.advancedConnectionArgs(channel: .scp).contains("-A"))
        XCTAssertTrue(client.advancedConnectionArgs(channel: .scp).contains("-C"))
        XCTAssertEqual(client.jumpServerArgs(), ["-J", "jump1@bastion1.example.com:2201,jump2@[::1]:2202"])
    }

    // MARK: - TC-V24-14: ~/.ssh/config first-value-wins parsing for ForwardAgent, Compression, ProxyCommand & ProxyJump
    func testTC_V24_14_SSHConfigParserAdvancedDirectives() {
        let config = """
        Host bastion
            HostName 1.2.3.4
            User ops
            Port 2222

        Host prod-app
            HostName 10.0.10.20
            User deploy
            ForwardAgent yes
            ForwardAgent no
            Compression yes
            Compression no
            ProxyJump bastion, 10.0.0.2:2200
            ProxyJump ignored-second-jump
            ProxyCommand nc -X 5 -x 127.0.0.1:1080 %h %p
            ProxyCommand ignored-second-proxy

        Match host *.internal
            ForwardAgent no
            Compression no
        """
        let hosts = SSHConfigParser.parse(content: config)
        XCTAssertEqual(hosts.count, 2)
        let prod = hosts[1]
        XCTAssertEqual(prod.hostPattern, "prod-app")
        XCTAssertTrue(prod.forwardAgent)
        XCTAssertTrue(prod.compression)
        XCTAssertEqual(prod.proxyCommand, "nc -X 5 -x 127.0.0.1:1080 %h %p")
        XCTAssertEqual(prod.proxyJump, ["bastion", "10.0.0.2:2200"])

        let sessions = hosts.map { $0.toSession(folder: "SSH Config") }
        let linked = SSHConfigParser.resolveProxyJumpChains(hosts: hosts, sessions: sessions)
        XCTAssertEqual(linked[1].jumpServerChain, [linked[0].id])
    }

    // MARK: - TC-V24-15: iCloud & .aetherpack sanitize ProxyCommand secrets and remap jumpServerChain UUIDs
    @MainActor
    func testTC_V24_15_SyncSanitizationAndSharePackJumpChainRemap() throws {
        let dirtyProxy = "https_proxy_cmd --token=supersecret999 --api-key abcdef123 http://alice:mypass@proxy.corp:8080 %h %p"
        let cleanProxy = SessionStartupHelper.sanitizeProxyCommand(dirtyProxy)
        XCTAssertNotNil(cleanProxy)
        XCTAssertFalse(cleanProxy!.contains("supersecret999"))
        XCTAssertFalse(cleanProxy!.contains("abcdef123"))
        XCTAssertFalse(cleanProxy!.contains("mypass"))
        XCTAssertTrue(cleanProxy!.contains("<REDACTED>"))

        let hopA = Session(name: "hopA", host: "hop-a.internal", port: 22, username: "u")
        let hopB = Session(name: "hopB", host: "hop-b.internal", port: 22, username: "u")
        let target = Session(
            name: "target",
            host: "10.9.9.9",
            port: 22,
            username: "u",
            jumpServerChain: [hopA.id, hopB.id],
            forwardAgent: true,
            compression: true,
            proxyCommand: dirtyProxy
        )

        // iCloud sanitization scrubs proxyCommand secrets
        let payload = iCloudSyncPayload(sessions: [hopA, hopB, target])
        let sanitizedCloud = iCloudSyncManager.sanitizeForCloud(payload: payload)
        XCTAssertFalse(sanitizedCloud.sessions[2].proxyCommand?.contains("supersecret999") ?? true)

        // OpenSSH Config export emits multi-hop & advanced directives
        let exportedSSH = SessionBundleExporter.generateOpenSSHConfig(from: [hopA, hopB, target])
        XCTAssertTrue(exportedSSH.contains("ForwardAgent yes"))
        XCTAssertTrue(exportedSSH.contains("Compression yes"))
        XCTAssertTrue(exportedSSH.contains("ProxyCommand "))
        XCTAssertFalse(exportedSSH.contains("supersecret999"))

        // .aetherpack import remaps jumpServerChain UUIDs to existing sessions
        let existingHopA = Session(id: UUID(), name: "hopA", host: "hop-a.internal", port: 22, username: "u")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SSHAdv_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = SessionStore(baseDirectory: tempDir)
        store.replaceAllSessions([existingHopA])

        let packData = try SessionBundleExporter.exportSharePackData(sessions: [hopA, hopB, target])
        let report = try SessionBundleExporter.importSharePackData(packData, into: store)
        XCTAssertEqual(report.skippedDuplicateSessions, 1) // hopA matched existingHopA
        let importedTarget = store.sessions.first(where: { $0.name == "target" })
        XCTAssertEqual(importedTarget?.jumpServerChain, [existingHopA.id, hopB.id])
        XCTAssertEqual(importedTarget?.jumpServerId, existingHopA.id)
    }

    // MARK: - TC-V24-16: App Store sandbox ProxyCommand validator warnings
    func testTC_V24_16_ProxyCommandSandboxValidator() {
        // System tools allowed in App Store sandbox
        XCTAssertNil(ProxyCommandValidator.sandboxWarning(for: "/usr/bin/nc -X 5 -x 127.0.0.1:1080 %h %p", isAppStore: true))
        XCTAssertNil(ProxyCommandValidator.sandboxWarning(for: "ssh -W %h:%p bastion", isAppStore: true))

        // External tools emit warning in App Store channel, silent in Direct channel
        let warn = ProxyCommandValidator.sandboxWarning(for: "/opt/homebrew/bin/cloudflared access ssh --hostname %h", isAppStore: true)
        XCTAssertNotNil(warn)
        XCTAssertTrue(warn!.contains("App Store"))
        XCTAssertNil(ProxyCommandValidator.sandboxWarning(for: "/opt/homebrew/bin/cloudflared access ssh --hostname %h", isAppStore: false))
    }
}
