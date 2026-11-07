import XCTest
@testable import ApexCore

@MainActor
final class SessionBundleExportImportTests: XCTestCase {

    /// TC-PACK-01: Full AetherSharePack export & JSON roundtrip serialization, excluding local sessions
    func testSharePackExportAndRoundtripExcludesLocalSessions() throws {
        let remoteId = UUID()
        let localSession = Session.local()
        let remoteSession = Session(
            id: remoteId,
            name: "Prod API",
            host: "10.0.10.12",
            port: 2222,
            username: "deploy",
            authMethod: .privateKey(keychainRef: "~/.ssh/id_ed25519", passphraseRef: nil),
            folder: "Production"
        )
        let snippet = Snippet(title: "Check Nginx", command: "systemctl status nginx", category: "System")
        let trigger = Trigger(name: "Error Highlight", regexPattern: "FATAL", action: .highlight(colorHex: "#FF453A"))
        let bookmark = SFTPBookmark(name: "Logs", path: "/var/log/nginx", isPreset: false)
        let presetBookmark = SFTPBookmark(name: "PresetTmp", path: "/tmp", isPreset: true)
        let tunnel = SSHTunnel(name: "Redis Local", type: .local, sessionId: remoteId, bindHost: "127.0.0.1", bindPort: 16379, targetHost: "127.0.0.1", targetPort: 6379)
        let orphanTunnel = SSHTunnel(name: "Local Orphan", type: .local, sessionId: localSession.id, bindHost: "127.0.0.1", bindPort: 16380, targetHost: "127.0.0.1", targetPort: 6380)

        let data = try SessionBundleExporter.exportSharePackData(
            sessions: [localSession, remoteSession],
            snippets: [snippet],
            triggers: [trigger],
            bookmarks: [bookmark, presetBookmark],
            tunnels: [tunnel, orphanTunnel]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AetherSharePack.self, from: data)

        XCTAssertEqual(decoded.formatVersion, AetherSharePack.currentFormatVersion)
        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.sessions[0].name, "Prod API")
        XCTAssertEqual(decoded.snippets.count, 1)
        XCTAssertEqual(decoded.triggers.count, 1)
        XCTAssertEqual(decoded.bookmarks.count, 1, "Preset bookmarks must be filtered out from custom share packs")
        XCTAssertEqual(decoded.tunnels.count, 1, "Orphan tunnels for excluded local sessions must be filtered out")
    }

    /// TC-PACK-02: Zero-credential security sanitization (passwords, passphrases, PEM blocks, vault refs, home paths, env secrets)
    func testZeroCredentialSanitizationAndPortablePaths() throws {
        let s1 = Session(
            name: "Password Host",
            host: "192.168.1.10",
            username: "root",
            authMethod: .password(keychainRef: "super-secret-password-ref"),
            environmentVariables: [
                "APP_ENV": "production",
                "AWS_SECRET_ACCESS_KEY": "leaked-secret"
            ]
        )
        let s2 = Session(
            name: "Cert Host",
            host: "192.168.1.11",
            username: "ubuntu",
            authMethod: .certificate(
                keychainRef: "/Users/alice/.ssh/id_ed25519",
                certificatePath: "/Users/alice/.ssh/id_ed25519-cert.pub",
                passphraseRef: "passphrase-uuid-123"
            )
        )
        let s3 = Session(
            name: "Raw PEM Host",
            host: "192.168.1.12",
            username: "admin",
            authMethod: .privateKey(
                keychainRef: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA...",
                passphraseRef: "pass-ref"
            )
        )

        let data = try SessionBundleExporter.exportSharePackData(sessions: [s1, s2, s3])
        let rawJSON = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AetherSharePack.self, from: data)

        XCTAssertFalse(rawJSON.contains("super-secret-password-ref"))
        XCTAssertFalse(rawJSON.contains("passphrase-uuid-123"))
        XCTAssertFalse(rawJSON.contains("PRIVATE KEY"))
        XCTAssertFalse(rawJSON.contains("leaked-secret"))
        XCTAssertFalse(rawJSON.contains("alice"))
        XCTAssertEqual(decoded.sessions[1].privateKeyPath, "~/.ssh/id_ed25519")
        XCTAssertEqual(decoded.sessions[1].certificatePath, "~/.ssh/id_ed25519-cert.pub")
    }

    /// TC-PACK-03: Folder-scoped export only exports sessions in the target folder and their tunnels
    func testFolderScopedExportFiltersSessionsAndAttachments() throws {
        let prodSession = Session(name: "Prod-1", host: "10.0.1.1", username: "root", authMethod: .agent, folder: "Production")
        let stageSession = Session(name: "Stage-1", host: "10.0.2.1", username: "root", authMethod: .agent, folder: "Staging")
        let prodTunnel = SSHTunnel(name: "Prod DB Tunnel", type: .local, sessionId: prodSession.id, bindHost: "127.0.0.1", bindPort: 15432, targetHost: "127.0.0.1", targetPort: 5432)
        let stageTunnel = SSHTunnel(name: "Stage DB Tunnel", type: .local, sessionId: stageSession.id, bindHost: "127.0.0.1", bindPort: 15433, targetHost: "127.0.0.1", targetPort: 5432)

        let data = try SessionBundleExporter.exportSharePackData(
            sessions: [prodSession, stageSession],
            tunnels: [prodTunnel, stageTunnel],
            onlyFolder: "production"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pack = try decoder.decode(AetherSharePack.self, from: data)

        XCTAssertEqual(pack.sessions.count, 1)
        XCTAssertEqual(pack.sessions[0].name, "Prod-1")
        XCTAssertEqual(pack.tunnels.count, 1)
        XCTAssertEqual(pack.tunnels[0].name, "Prod DB Tunnel")
    }

    /// TC-PACK-04: Deduplicating smart merge import skips existing sessions and merges new items
    func testDeduplicatingSmartMergeImport() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(baseDirectory: tempDir)
        let existing = Session(name: "Core DB", host: "10.0.5.10", port: 22, username: "postgres", authMethod: .agent, folder: "DB")
        store.addSession(existing)
        let initialSnippetCount = store.snippets.count
        let initialTriggerCount = store.triggers.count

        let duplicateIncoming = Session(name: "Core DB", host: "10.0.5.10", port: 22, username: "postgres", authMethod: .agent, folder: "UpdatedFolder")
        let brandNewIncoming = Session(name: "Replica DB", host: "10.0.5.11", port: 22, username: "postgres", authMethod: .agent, folder: "DB")
        let newSnippet = Snippet(title: "Vacuum Analyze", command: "psql -c 'VACUUM ANALYZE;'", category: "DB")
        let newTrigger = Trigger(name: "Deadlock Alert", regexPattern: "deadlock detected", action: .highlight(colorHex: "#FF453A"))

        let data = try SessionBundleExporter.exportSharePackData(
            sessions: [duplicateIncoming, brandNewIncoming],
            snippets: [newSnippet],
            triggers: [newTrigger]
        )

        let report = try SessionBundleExporter.importSharePackData(data, into: store, overwriteExisting: false)
        XCTAssertEqual(report.importedSessions, 1)
        XCTAssertEqual(report.skippedDuplicateSessions, 1)
        XCTAssertEqual(report.importedSnippets, 1)
        XCTAssertEqual(report.importedTriggers, 1)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(store.snippets.count, initialSnippetCount + 1)
        XCTAssertEqual(store.triggers.count, initialTriggerCount + 1)
    }

    /// TC-PACK-05: Overwrite-mode import updates existing matched sessions while preserving local ID
    func testOverwriteModeImportUpdatesExistingSessionAndPreservesID() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-overwrite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(baseDirectory: tempDir)
        let original = Session(name: "Gateway", host: "10.0.8.1", port: 22, username: "ubuntu", authMethod: .agent, folder: "OldGroup")
        store.addSession(original)

        let updatedIncoming = Session(
            name: "Gateway",
            host: "10.0.8.1",
            port: 22,
            username: "ubuntu",
            authMethod: .agent,
            folder: "NewGroup",
            initialWorkingDirectory: "/etc/nginx"
        )
        let data = try SessionBundleExporter.exportSharePackData(sessions: [updatedIncoming])
        let report = try SessionBundleExporter.importSharePackData(data, into: store, overwriteExisting: true)

        XCTAssertEqual(report.importedSessions, 1)
        XCTAssertEqual(report.skippedDuplicateSessions, 0)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].id, original.id, "Local session UUID must be preserved when overwriting")
        XCTAssertEqual(store.sessions[0].folder, "NewGroup")
        XCTAssertEqual(store.sessions[0].initialWorkingDirectory, "/etc/nginx")
    }

    /// TC-PACK-06: Legacy [Session] JSON array backward-compatible import
    func testLegacySessionArrayBackwardCompatibleImport() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(baseDirectory: tempDir)
        let legacySessions = [
            Session(name: "Legacy-Node", host: "172.16.0.9", port: 2200, username: "admin", authMethod: .password(keychainRef: "secret-ref"))
        ]
        let legacyData = try JSONEncoder().encode(legacySessions)

        let report = try SessionBundleExporter.importSharePackData(legacyData, into: store)
        XCTAssertEqual(report.importedSessions, 1)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].name, "Legacy-Node")
        XCTAssertEqual(store.sessions[0].authMethod, .password(keychainRef: ""), "Imported legacy sessions must also be credential-sanitized")
    }

    /// TC-PACK-07: OpenSSH ~/.ssh/config text generation with IdentityFile, CertificateFile, ProxyJump, SetEnv, and RemoteCommand
    func testGenerateOpenSSHConfigFormatting() {
        let bastion = Session(
            name: "Corp Bastion",
            host: "bastion.corp.io",
            port: 2222,
            username: "ops",
            authMethod: .privateKey(keychainRef: "/Users/dev/.ssh/id_ed25519", passphraseRef: nil),
            folder: "Infra"
        )
        let appNode = Session(
            name: "App Server 01",
            host: "10.20.30.40",
            port: 22,
            username: "ubuntu",
            authMethod: .certificate(
                keychainRef: "/Users/dev/.ssh/id_ed25519",
                certificatePath: "/Users/dev/.ssh/id_ed25519-cert.pub",
                passphraseRef: nil
            ),
            folder: "Production",
            jumpServerId: bastion.id,
            startupCommand: "tmux attach || tmux new",
            environmentVariables: ["APP_STAGE": "prod"]
        )

        let config = SessionBundleExporter.generateOpenSSHConfig(from: [bastion, appNode])
        XCTAssertTrue(config.contains("Host Corp-Bastion"))
        XCTAssertTrue(config.contains("HostName bastion.corp.io"))
        XCTAssertTrue(config.contains("Port 2222"))
        XCTAssertTrue(config.contains("IdentityFile ~/.ssh/id_ed25519"))
        XCTAssertTrue(config.contains("Host App-Server-01"))
        XCTAssertTrue(config.contains("CertificateFile ~/.ssh/id_ed25519-cert.pub"))
        XCTAssertTrue(config.contains("ProxyJump Corp-Bastion"))
        XCTAssertTrue(config.contains("SetEnv APP_STAGE=\"prod\""))
        XCTAssertTrue(config.contains("RemoteCommand tmux attach || tmux new"))
    }

    /// TC-PACK-08: OpenSSH config export -> SSHConfigParser.parse roundtrip verification
    func testOpenSSHConfigExportAndParserRoundtrip() {
        let session = Session(
            name: "k8s-master",
            host: "10.90.0.10",
            port: 22022,
            username: "sre",
            authMethod: .certificate(
                keychainRef: "~/.ssh/k8s_ed25519",
                certificatePath: "~/.ssh/k8s_ed25519-cert.pub",
                passphraseRef: nil
            ),
            startupCommand: "kubectl get pods -A",
            environmentVariables: ["KUBECONFIG": "/etc/rancher/k3s/k3s.yaml"]
        )

        let exportedConfig = SessionBundleExporter.generateOpenSSHConfig(from: [session])
        let parsedHosts = SSHConfigParser.parse(content: exportedConfig)
        XCTAssertEqual(parsedHosts.count, 1)

        let roundtripped = parsedHosts[0].toSession()
        XCTAssertEqual(roundtripped.name, "k8s-master")
        XCTAssertEqual(roundtripped.host, "10.90.0.10")
        XCTAssertEqual(roundtripped.port, 22022)
        XCTAssertEqual(roundtripped.username, "sre")
        XCTAssertEqual(SessionBundleExporter.portablePath(roundtripped.privateKeyPath ?? ""), "~/.ssh/k8s_ed25519")
        XCTAssertEqual(SessionBundleExporter.portablePath(roundtripped.certificatePath ?? ""), "~/.ssh/k8s_ed25519-cert.pub")
        XCTAssertEqual(roundtripped.startupCommand, "kubectl get pods -A")
        XCTAssertEqual(roundtripped.environmentVariables["KUBECONFIG"], "/etc/rancher/k3s/k3s.yaml")
    }
}
