import XCTest
import AppKit
import SwiftUI
@testable import ApexCore
@testable import ApexUI

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

    // MARK: - v2 Encrypted / App-Sealed Group Share Tests (TC-PACK-09 ~ TC-PACK-18)

    private final class InMemorySecretStore: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: String]

        init(_ initial: [String: String] = [:]) {
            self.entries = initial
        }

        func get(_ key: String) -> String? {
            lock.withLock { entries[key] }
        }

        func save(_ key: String, secret: String) -> String {
            lock.withLock { entries[key] = secret }
            return key
        }

        func allEntries() -> [String: String] {
            lock.withLock { entries }
        }
    }

    /// TC-PACK-09: App-sealed passwordless credential export & import roundtrip without plaintext leaks on disk
    func testAppSealedCredentialExportAndImportRoundtrip() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-appsealed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pwRef = "ssh_\(UUID().uuidString)"
        let keyPassRef = "passphrase_\(UUID().uuidString)"
        let certPassRef = "passphrase_\(UUID().uuidString)"
        let sourceSecrets = InMemorySecretStore([
            pwRef: "ProdPassword!987",
            keyPassRef: "KeyPassphrase#456",
            certPassRef: "CertPassphrase@321"
        ])

        let sPw = Session(name: "DB-Primary", host: "10.10.1.10", port: 22, username: "postgres", authMethod: .password(keychainRef: pwRef), folder: "业务A")
        let sKey = Session(name: "App-Node", host: "10.10.1.11", port: 2222, username: "deploy", authMethod: .privateKey(keychainRef: "~/.ssh/deploy_ed25519", passphraseRef: keyPassRef), folder: "业务A")
        let sCert = Session(name: "Edge-GW", host: "10.10.1.12", port: 22, username: "ops", authMethod: .certificate(keychainRef: "~/.ssh/edge_ed25519", certificatePath: "~/.ssh/edge_ed25519-cert.pub", passphraseRef: certPassRef), folder: "业务A")

        let data = try await SessionBundleExporter.exportEnvelopeData(
            sessions: [sPw, sKey, sCert],
            protectionMode: .appSealed,
            passphrase: nil,
            appVersion: "1.26.0",
            secretLookup: { key in sourceSecrets.get(key) }
        )

        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"app_sealed\""))
        XCTAssertFalse(raw.contains("ProdPassword!987"), "Raw .aetherpack must never contain plaintext passwords")
        XCTAssertFalse(raw.contains("KeyPassphrase#456"))
        XCTAssertFalse(raw.contains("CertPassphrase@321"))
        XCTAssertFalse(raw.contains(pwRef))

        let inspection = try SessionBundleExporter.inspectSharePackData(data)
        XCTAssertEqual(inspection.sourceFormat, .envelopeV2(.appSealed))
        XCTAssertFalse(inspection.requiresPassphrase)
        XCTAssertEqual(inspection.header.groupNames, ["业务A"])
        XCTAssertEqual(inspection.header.sessionCount, 3)
        XCTAssertTrue(inspection.header.includesCredentials)

        let bundle = try XCTUnwrap(inspection.decryptedBundle)
        XCTAssertTrue(bundle.credentials.hasCredential(for: sPw.id))
        XCTAssertTrue(bundle.credentials.hasCredential(for: sKey.id))
        XCTAssertTrue(bundle.credentials.hasCredential(for: sCert.id))

        let destStore = SessionStore(baseDirectory: tempDir)
        let destSecrets = InMemorySecretStore()
        let result = try SessionBundleExporter.importDecryptedBundle(
            bundle,
            into: destStore,
            options: SharePackImportOptions(),
            secretSaver: { key, secret in destSecrets.save(key, secret: secret) }
        )

        XCTAssertEqual(result.importedSessions, 3)
        XCTAssertEqual(result.importedCredentials, 3)
        XCTAssertEqual(destStore.sessions.count, 3)

        let importedPw = try XCTUnwrap(destStore.sessions.first(where: { $0.name == "DB-Primary" }))
        guard case .password(let newPwRef) = importedPw.authMethod else {
            return XCTFail("Expected password auth method")
        }
        XCTAssertTrue(KeychainStore.isSessionSecretReference(newPwRef))
        XCTAssertEqual(destSecrets.get(newPwRef), "ProdPassword!987")

        let importedKey = try XCTUnwrap(destStore.sessions.first(where: { $0.name == "App-Node" }))
        XCTAssertEqual(destSecrets.get(importedKey.passphraseRef ?? ""), "KeyPassphrase#456")

        let importedCert = try XCTUnwrap(destStore.sessions.first(where: { $0.name == "Edge-GW" }))
        XCTAssertEqual(importedCert.certificatePath, "~/.ssh/edge_ed25519-cert.pub")
        XCTAssertEqual(destSecrets.get(importedCert.passphraseRef ?? ""), "CertPassphrase@321")
    }

    /// TC-PACK-10: Passphrase-encrypted share bundle enforces passphrase lock, rejects wrong passphrases & tampered ciphertext
    func testPassphraseProtectedSharePackUnlockAndTamperDetection() async throws {
        let pwRef = "ssh_\(UUID().uuidString)"
        let sourceSecrets = InMemorySecretStore([pwRef: "TopSecret#2026"])
        let session = Session(name: "Finance-Core", host: "10.88.99.5", port: 22, username: "finops", authMethod: .password(keychainRef: pwRef), folder: "财务核心")
        let tunnel = SSHTunnel(name: "Ledger-Tunnel", type: .local, sessionId: session.id, bindHost: "127.0.0.1", bindPort: 15432, targetHost: "127.0.0.1", targetPort: 5432)

        let data = try await SessionBundleExporter.exportEnvelopeData(
            sessions: [session],
            tunnels: [tunnel],
            protectionMode: .passphrase,
            passphrase: "Strong-Share-Pass!",
            secretLookup: { sourceSecrets.get($0) }
        )

        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"passphrase\""))
        XCTAssertFalse(raw.contains("10.88.99.5"), "Host IP must remain encrypted inside passphrase payload")
        XCTAssertFalse(raw.contains("TopSecret#2026"))

        let inspection = try SessionBundleExporter.inspectSharePackData(data)
        XCTAssertEqual(inspection.sourceFormat, .envelopeV2(.passphrase))
        XCTAssertTrue(inspection.requiresPassphrase)
        XCTAssertNil(inspection.decryptedBundle)
        XCTAssertEqual(inspection.header.groupNames, ["财务核心"])
        XCTAssertEqual(inspection.header.sessionCount, 1)
        XCTAssertEqual(inspection.header.tunnelCount, 1)

        XCTAssertThrowsError(try SessionBundleExporter.decryptSharePackData(data, passphrase: "wrong-password")) { error in
            XCTAssertEqual(error as? SharePackCryptoError, .invalidPassphrase)
        }

        // Tamper with ciphertext
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var envelope = try decoder.decode(AetherShareEnvelope.self, from: data)
        var blob = try XCTUnwrap(envelope.encryptedPayload)
        var cipherBytes = try XCTUnwrap(Data(base64Encoded: blob.ciphertextBase64))
        cipherBytes[0] ^= 0xFF
        blob.ciphertextBase64 = cipherBytes.base64EncodedString()
        envelope.encryptedPayload = blob
        let tamperedEncoder = JSONEncoder()
        tamperedEncoder.dateEncodingStrategy = .iso8601
        let tamperedData = try tamperedEncoder.encode(envelope)

        XCTAssertThrowsError(try SessionBundleExporter.decryptSharePackData(tamperedData, passphrase: "Strong-Share-Pass!")) { error in
            XCTAssertEqual(error as? SharePackCryptoError, .invalidPassphrase)
        }

        let unlocked = try SessionBundleExporter.decryptSharePackData(data, passphrase: "Strong-Share-Pass!")
        XCTAssertEqual(unlocked.pack.sessions.count, 1)
        XCTAssertEqual(unlocked.credentials.sessionPasswords[session.id], "TopSecret#2026")
    }

    /// TC-PACK-11: Zero-credential v2 envelope omits all passwords, passphrases, and managed Key Vault references
    func testZeroCredentialEnvelopeV2SanitizesAllSecrets() async throws {
        let vaultPrivRef = "vault.priv.\(UUID().uuidString)"
        let vaultPassRef = "vault.pass.\(UUID().uuidString)"
        let sPw = Session(name: "Zero-PW", host: "192.168.50.1", username: "root", authMethod: .password(keychainRef: "ssh_\(UUID().uuidString)"), folder: "测试")
        let sVault = Session(name: "Zero-Vault", host: "192.168.50.2", username: "ubuntu", authMethod: .privateKey(keychainRef: vaultPrivRef, passphraseRef: vaultPassRef), folder: "测试")

        let sourceSecrets = InMemorySecretStore([
            sPw.authMethod == .agent ? "" : "unused": "none",
            vaultPrivRef: "SECRET_VAULT_MATERIAL",
            vaultPassRef: "SECRET_VAULT_PASS"
        ])

        let data = try await SessionBundleExporter.exportEnvelopeData(
            sessions: [sPw, sVault],
            protectionMode: .zeroCredential,
            secretLookup: { sourceSecrets.get($0) }
        )

        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(raw.contains(vaultPrivRef))
        XCTAssertFalse(raw.contains(vaultPassRef))
        XCTAssertFalse(raw.contains("SECRET_VAULT_MATERIAL"))

        let inspection = try SessionBundleExporter.inspectSharePackData(data)
        XCTAssertEqual(inspection.sourceFormat, .envelopeV2(.zeroCredential))
        XCTAssertFalse(inspection.header.includesCredentials)
        let bundle = try XCTUnwrap(inspection.decryptedBundle)
        XCTAssertFalse(bundle.credentials.hasAnySecret)
        XCTAssertEqual(bundle.pack.sessions[0].authMethod, .password(keychainRef: ""))
        XCTAssertEqual(bundle.pack.sessions[1].authMethod, .privateKey(keychainRef: "", passphraseRef: nil))
    }

    /// TC-PACK-12: Vault key (vault.priv.<UUID> + passphrase) export & SHA-256 fingerprint-deduplicated import
    func testVaultKeyExportAndFingerprintDeduplicatedImport() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyURL = tempDir.appendingPathComponent("team_ed25519")
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", keyURL.path]
        keygen.standardInput = FileHandle.nullDevice
        keygen.standardOutput = FileHandle.nullDevice
        keygen.standardError = FileHandle.nullDevice
        try keygen.run()
        keygen.waitUntilExit()
        XCTAssertEqual(keygen.terminationStatus, 0)

        let privPEM = try String(contentsOf: keyURL, encoding: .utf8)
        let pubOpenSSH = try String(contentsOfFile: keyURL.path + ".pub", encoding: .utf8)

        let sourceSecrets = InMemorySecretStore()
        let sourceVault = SSHKeyVaultManager(baseDirectory: tempDir.appendingPathComponent("src_vault"))
        let identity = try sourceVault.importKey(
            name: "Team Deploy Key",
            privateKeyPEM: privPEM,
            publicKeyOpenSSH: pubOpenSSH,
            passphrase: "VaultKeyPass#1",
            secretSaver: { key, secret in sourceSecrets.save(key, secret: secret) }
        )

        let session = Session(
            name: "K8s Node",
            host: "10.60.1.5",
            username: "k8s",
            authMethod: .privateKey(keychainRef: identity.keychainPrivateKeyRef, passphraseRef: identity.keychainPassphraseRef),
            folder: "集群"
        )

        let data = try await SessionBundleExporter.exportEnvelopeData(
            sessions: [session],
            protectionMode: .appSealed,
            vaultKeys: sourceVault.keys,
            secretLookup: { sourceSecrets.get($0) }
        )

        let bundle = try XCTUnwrap(try SessionBundleExporter.inspectSharePackData(data).decryptedBundle)
        XCTAssertEqual(bundle.credentials.embeddedVaultKeys.count, 1)

        let destSecrets = InMemorySecretStore()
        let destStore = SessionStore(baseDirectory: tempDir.appendingPathComponent("dst_store"))
        let destVault = SSHKeyVaultManager(baseDirectory: tempDir.appendingPathComponent("dst_vault"))

        let firstResult = try SessionBundleExporter.importDecryptedBundle(
            bundle,
            into: destStore,
            options: SharePackImportOptions(),
            vaultManager: destVault,
            secretSaver: { key, secret in destSecrets.save(key, secret: secret) }
        )
        XCTAssertEqual(firstResult.importedVaultKeys, 1)
        XCTAssertEqual(destVault.keys.count, 1)
        XCTAssertNotEqual(destVault.keys[0].keychainPrivateKeyRef, identity.keychainPrivateKeyRef)
        XCTAssertEqual(destStore.sessions[0].privateKeyPath, destVault.keys[0].keychainPrivateKeyRef)
        XCTAssertEqual(destSecrets.get(destVault.keys[0].keychainPrivateKeyRef)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       privPEM.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(destSecrets.get(destVault.keys[0].keychainPassphraseRef ?? ""), "VaultKeyPass#1")

        // Second import into same vault (with .keepBoth) reuses existing key by fingerprint without duplicating
        let secondResult = try SessionBundleExporter.importDecryptedBundle(
            bundle,
            into: destStore,
            options: SharePackImportOptions(conflictStrategy: .keepBoth),
            vaultManager: destVault,
            secretSaver: { key, secret in destSecrets.save(key, secret: secret) }
        )
        XCTAssertEqual(secondResult.importedVaultKeys, 0)
        XCTAssertEqual(destVault.keys.count, 1)
        XCTAssertEqual(destStore.sessions.count, 2)
        XCTAssertEqual(destStore.sessions[1].privateKeyPath, destVault.keys[0].keychainPrivateKeyRef)
    }

    /// TC-PACK-13: Cross-group jump-host dependency resolution & UUID chain remapping under keepBoth
    func testCrossGroupJumpHostDiscoveryAndChainRemapping() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-jump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bastion = Session(name: "Shared-Bastion", host: "bastion.internal", username: "ops", authMethod: .agent, folder: "跳板机组")
        let appNode = Session(name: "App-Backend", host: "10.0.2.10", username: "app", authMethod: .agent, folder: "业务组", jumpServerChain: [bastion.id])
        let dbNode = Session(name: "DB-Private", host: "10.0.2.20", username: "db", authMethod: .agent, folder: "业务组", jumpServerChain: [appNode.id])
        let unrelated = Session(name: "Other", host: "10.0.9.9", username: "other", authMethod: .agent, folder: "其他")

        let all = [bastion, appNode, dbNode, unrelated]
        let extra = SessionBundleExporter.crossGroupJumpHosts(for: [appNode.id, dbNode.id], allSessions: all)
        XCTAssertEqual(extra.map(\.id), [bastion.id])

        // Cycle protection test
        var cyclicA = Session(name: "CycleA", host: "10.1.1.1", username: "u", authMethod: .agent, folder: "G1")
        let cyclicB = Session(name: "CycleB", host: "10.1.1.2", username: "u", authMethod: .agent, folder: "G2", jumpServerChain: [cyclicA.id])
        cyclicA.jumpServerChain = [cyclicB.id]
        XCTAssertEqual(SessionBundleExporter.crossGroupJumpHosts(for: [cyclicA.id], allSessions: [cyclicA, cyclicB]).map(\.id), [cyclicB.id])

        let resolved = SessionBundleExporter.resolveExportSelection(selectedSessionIDs: [dbNode.id], allSessions: all, includeCrossGroupJumpHosts: true)
        XCTAssertEqual(Set(resolved.sessions.map(\.id)), Set([bastion.id, appNode.id, dbNode.id]))
        XCTAssertEqual(Set(resolved.addedJumpHostIDs), Set([bastion.id, appNode.id]))

        let data = try await SessionBundleExporter.exportEnvelopeData(sessions: resolved.sessions, protectionMode: .appSealed)
        let bundle = try XCTUnwrap(try SessionBundleExporter.inspectSharePackData(data).decryptedBundle)

        // Pre-populate store with same sessions, then import with keepBoth
        let store = SessionStore(baseDirectory: tempDir)
        store.addSession(bastion)
        store.addSession(appNode)
        store.addSession(dbNode)

        let result = try SessionBundleExporter.importDecryptedBundle(
            bundle,
            into: store,
            options: SharePackImportOptions(conflictStrategy: .keepBoth),
            secretSaver: { k, _ in k }
        )
        XCTAssertEqual(result.importedSessions, 3)

        let clonedBastion = try XCTUnwrap(store.sessions.first(where: { $0.name == "Shared-Bastion (导入)" }))
        let clonedApp = try XCTUnwrap(store.sessions.first(where: { $0.name == "App-Backend (导入)" }))
        let clonedDb = try XCTUnwrap(store.sessions.first(where: { $0.name == "DB-Private (导入)" }))

        XCTAssertNotEqual(clonedBastion.id, bastion.id)
        XCTAssertEqual(clonedApp.effectiveJumpServerChain, [clonedBastion.id], "Cloned app must jump through cloned bastion rather than original")
        XCTAssertEqual(clonedDb.effectiveJumpServerChain, [clonedApp.id])
    }

    /// TC-PACK-14: Target folder override and skip/overwrite/keepBoth conflict strategies
    func testTargetFolderOverrideAndConflictStrategies() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(baseDirectory: tempDir)
        let existingSecrets = InMemorySecretStore(["ssh_existing": "KeepLocalPW"])
        let existingId = UUID()
        let localSession = Session(
            id: existingId,
            name: "Web-01",
            host: "10.20.1.5",
            port: 22,
            username: "www",
            authMethod: .password(keychainRef: "ssh_existing"),
            folder: "Production",
            tags: ["old"]
        )
        store.addSession(localSession)

        // Incoming session matches by (name, host, port, username) with different UUID and case-variant folder
        let incomingMatch = Session(
            name: "Web-01",
            host: "10.20.1.5",
            port: 22,
            username: "www",
            authMethod: .password(keychainRef: ""),
            folder: "production",
            tags: ["updated"]
        )
        let incomingBrandNew = Session(
            name: "Web-02",
            host: "10.20.1.6",
            port: 22,
            username: "www",
            authMethod: .agent,
            folder: "SourceOnlyGroup"
        )
        let bundle = SharePackSecretBundle(pack: AetherSharePack(sessions: [incomingMatch, incomingBrandNew]))

        // 1. Skip duplicates + preserveOriginal canonical folder spelling
        let skipResult = try SessionBundleExporter.importDecryptedBundle(
            bundle,
            into: store,
            options: SharePackImportOptions(
                conflictStrategy: .skipExisting,
                targetFolderMode: .preserveOriginal
            ),
            secretSaver: { k, v in existingSecrets.save(k, secret: v) }
        )
        XCTAssertEqual(skipResult.importedSessions, 1)
        XCTAssertEqual(skipResult.skippedDuplicateSessions, 1)
        XCTAssertEqual(store.sessions.first(where: { $0.id == existingId })?.tags, ["old"])

        // 2. Overwrite existing while preserving existing secret ref & overriding target folder
        let overwriteResult = try SessionBundleExporter.importDecryptedBundle(
            bundle,
            into: store,
            options: SharePackImportOptions(
                selectedSessionIDs: [incomingMatch.id],
                conflictStrategy: .overwriteExisting,
                targetFolderMode: .assignToFolder("production ")
            ),
            secretSaver: { k, v in existingSecrets.save(k, secret: v) }
        )
        XCTAssertEqual(overwriteResult.updatedSessions, 1)
        let overwritten = try XCTUnwrap(store.sessions.first(where: { $0.id == existingId }))
        XCTAssertEqual(overwritten.tags, ["updated"])
        XCTAssertEqual(overwritten.folder, "Production", "Case-insensitive folder match must canonicalize to existing spelling")
        XCTAssertEqual(overwritten.authMethod, .password(keychainRef: "ssh_existing"), "Existing secret ref preserved when zero-cred import overwrites metadata")

        // 3. KeepBoth into brand new group
        let keepBothResult = try SessionBundleExporter.importDecryptedBundle(
            bundle,
            into: store,
            options: SharePackImportOptions(
                selectedSessionIDs: [incomingMatch.id],
                conflictStrategy: .keepBoth,
                targetFolderMode: .assignToFolder("同事分享")
            ),
            secretSaver: { k, v in existingSecrets.save(k, secret: v) }
        )
        XCTAssertEqual(keepBothResult.importedSessions, 1)
        XCTAssertEqual(keepBothResult.importedFolderNames, ["同事分享"])
        let copy = try XCTUnwrap(store.sessions.first(where: { $0.name == "Web-01 (导入)" }))
        XCTAssertEqual(copy.folder, "同事分享")
        XCTAssertNotEqual(copy.id, existingId)
    }

    /// TC-PACK-15: Selective subset import + tunnel filtering + v1/legacy backward compatibility via inspectSharePackData
    func testSelectiveSubsetImportAndLegacyInspectCompatibility() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-subset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let s1 = Session(name: "PickMe", host: "10.1.1.10", username: "u1", authMethod: .agent, folder: "A")
        let s2 = Session(name: "SkipMe", host: "10.1.1.11", username: "u2", authMethod: .agent, folder: "A")
        let t1 = SSHTunnel(name: "T1", type: .local, sessionId: s1.id, bindPort: 18081, targetPort: 8081)
        let t2 = SSHTunnel(name: "T2", type: .local, sessionId: s2.id, bindPort: 18082, targetPort: 8082)

        let v1Data = try SessionBundleExporter.exportSharePackData(sessions: [s1, s2], tunnels: [t1, t2])
        let v1Inspect = try SessionBundleExporter.inspectSharePackData(v1Data)
        XCTAssertEqual(v1Inspect.sourceFormat, .legacySharePackV1)
        XCTAssertFalse(v1Inspect.requiresPassphrase)

        let store = SessionStore(baseDirectory: tempDir)
        let tunManager = SSHTunnelManager(baseDirectory: tempDir)
        let res = try SessionBundleExporter.importDecryptedBundle(
            try XCTUnwrap(v1Inspect.decryptedBundle),
            into: store,
            options: SharePackImportOptions(selectedSessionIDs: [s1.id], includeTunnels: true),
            tunnelManager: tunManager
        )
        XCTAssertEqual(res.importedSessions, 1)
        XCTAssertEqual(res.importedTunnels, 1)
        XCTAssertEqual(tunManager.tunnels.map(\.name), ["T1"])

        let legacyArrayData = try JSONEncoder().encode([s2])
        let legacyInspect = try SessionBundleExporter.inspectSharePackData(legacyArrayData)
        XCTAssertEqual(legacyInspect.sourceFormat, .legacySessionArray)
        XCTAssertEqual(legacyInspect.header.sessionCount, 1)
    }

    /// TC-PACK-16: IncomingShareCoordinator, suggestedFilename, file extension filter, and readable passphrase generator
    func testIncomingShareCoordinatorAndFileHelpers() {
        let coordinator = IncomingShareCoordinator()
        let url = URL(fileURLWithPath: "/tmp/team-prod.aetherpack")
        XCTAssertNil(coordinator.pendingImportURL)

        coordinator.requestImport(url: url)
        XCTAssertEqual(coordinator.openImportTrigger, 1)
        XCTAssertEqual(coordinator.consumePendingImportURL(), url)
        XCTAssertNil(coordinator.consumePendingImportURL())

        coordinator.requestExport()
        XCTAssertEqual(coordinator.openExportTrigger, 1)

        XCTAssertEqual(SessionBundleExporter.suggestedFilename(forFolder: "生产/核心:集群", sessionCount: 3), "生产-核心-集群.aetherpack")
        XCTAssertEqual(SessionBundleExporter.suggestedFilename(forFolder: nil, sessionCount: 5), "aetherterm-sessions.aetherpack")
        XCTAssertTrue(SessionBundleExporter.isSupportedShareFileURL(URL(fileURLWithPath: "/tmp/foo.AETHERPACK")))
        XCTAssertTrue(SessionBundleExporter.isSupportedShareFileURL(URL(fileURLWithPath: "/tmp/foo.aetherpack.json")))
        XCTAssertFalse(SessionBundleExporter.isSupportedShareFileURL(URL(fileURLWithPath: "/tmp/notes.txt")))

        let randomPass = SharePackCrypto.generateReadablePassphrase()
        XCTAssertEqual(randomPass.count, 14) // 12 chars + 2 dashes
        XCTAssertEqual(randomPass.filter { $0 == "-" }.count, 2)
    }

    /// TC-PACK-17: GroupShareExportSheet and GroupShareImportSheet render cleanly across themes & apply .apexTheme()
    func testGroupShareSheetsRenderAcrossThemesAndApplyThemeModifier() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(baseDirectory: tempDir)
        let bastion = Session(name: "Bastion", host: "10.0.0.1", username: "ops", folder: "Infra")
        let app = Session(name: "App", host: "10.0.0.2", username: "app", folder: "Production", jumpServerChain: [bastion.id])
        store.addSession(bastion)
        store.addSession(app)

        let originalPreset = AppSettings.shared.themePreset
        let originalFollow = AppSettings.shared.followsSystemAppearance
        defer {
            AppSettings.shared.themePreset = originalPreset
            AppSettings.shared.followsSystemAppearance = originalFollow
        }
        AppSettings.shared.followsSystemAppearance = false

        for preset in [TerminalThemePreset.modern, .solarized] {
            AppSettings.shared.themePreset = preset
            let exportHost = NSHostingView(rootView: GroupShareExportSheet(store: store, initialFolder: "Production").apexTheme())
            exportHost.frame = NSRect(x: 0, y: 0, width: 600, height: 610)
            exportHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(exportHost.fittingSize.height, 200)

            let importHost = NSHostingView(rootView: GroupShareImportSheet(store: store).apexTheme())
            importHost.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
            importHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(importHost.fittingSize.height, 200)
        }

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sidebarSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Sidebar/SidebarView.swift"), encoding: .utf8)
        for sheetName in ["$exportRequest", "$shareImportRequest"] {
            let range = try XCTUnwrap(sidebarSource.range(of: ".sheet(item: \(sheetName))"), sheetName)
            let snippet = String(sidebarSource[range.upperBound...].prefix(400))
            XCTAssertTrue(snippet.contains(".apexTheme()"), "Sidebar share sheet \(sheetName) must apply .apexTheme()")
        }

        let settingsSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Settings/SettingsView.swift"), encoding: .utf8)
        for sheetName in ["$showingGroupExportSheet", "$showingGroupImportSheet"] {
            let range = try XCTUnwrap(settingsSource.range(of: ".sheet(isPresented: \(sheetName))"), sheetName)
            let snippet = String(settingsSource[range.upperBound...].prefix(300))
            XCTAssertTrue(snippet.contains(".apexTheme()"), "Settings share sheet \(sheetName) must apply .apexTheme()")
        }
    }

    /// TC-PACK-18: Production packaging scripts register .aetherpack CFBundleDocumentTypes & UTExportedTypeDeclarations
    func testPackagingScriptsRegisterAetherPackDocumentType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let buildScript = try String(contentsOf: root.appendingPathComponent("scripts/build_app.sh"), encoding: .utf8)
        XCTAssertTrue(buildScript.contains("CFBundleDocumentTypes"))
        XCTAssertTrue(buildScript.contains("UTExportedTypeDeclarations"))
        XCTAssertTrue(buildScript.contains("com.apexterm.aetherpack"))
        XCTAssertTrue(buildScript.contains("<string>aetherpack</string>"))

        let storeScript = try String(contentsOf: root.appendingPathComponent("scripts/prepare_app_store_candidate.py"), encoding: .utf8)
        XCTAssertTrue(storeScript.contains("CFBundleDocumentTypes"))
        XCTAssertTrue(storeScript.contains("UTExportedTypeDeclarations"))
        XCTAssertTrue(storeScript.contains("com.apexterm.aetherpack"))
    }

    /// TC-PACK-19: Special-char ($$, $PATH, quotes, backslashes) & Unicode passwords/passphrases roundtrip in appSealed & passphrase modes
    func testSpecialCharAndUnicodeCredentialsRoundtrip() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-special-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let specialPW = "p@$$w0rd'$PATH\"\\中文🔐!"
        let specialSharePass = "口令$$#2026'\"\\🔑"
        let pwRef = "ssh_\(UUID().uuidString)"
        let sourceSecrets = InMemorySecretStore([pwRef: specialPW])
        let session = Session(
            name: "Special-Char Host",
            host: "192.0.2.77",
            port: 22,
            username: "ops",
            authMethod: .password(keychainRef: pwRef),
            folder: "测试组"
        )

        for mode in [SharePackProtectionMode.appSealed, .passphrase] {
            let data = try await SessionBundleExporter.exportEnvelopeData(
                sessions: [session],
                protectionMode: mode,
                passphrase: mode == .passphrase ? specialSharePass : nil,
                secretLookup: { sourceSecrets.get($0) }
            )
            let bundle: SharePackSecretBundle
            if mode == .passphrase {
                bundle = try SessionBundleExporter.decryptSharePackData(data, passphrase: specialSharePass)
            } else {
                bundle = try XCTUnwrap(SessionBundleExporter.inspectSharePackData(data).decryptedBundle)
            }
            let destStore = SessionStore(baseDirectory: tempDir.appendingPathComponent(mode.rawValue))
            let destSecrets = InMemorySecretStore()
            _ = try SessionBundleExporter.importDecryptedBundle(
                bundle,
                into: destStore,
                secretSaver: { key, secret in destSecrets.save(key, secret: secret) }
            )
            guard case .password(let importedRef) = destStore.sessions.first?.authMethod else {
                return XCTFail("Expected password authMethod")
            }
            XCTAssertEqual(destSecrets.get(importedRef), specialPW)
        }
    }

    /// TC-PACK-20: Raw PEM keys, fallback vault keys without publicKeyOpenSSH/vaultManager, and dangling jump UUID sanitization on import
    func testRawPEMFallbackVaultKeyRestoreAndDanglingJumpSanitization() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pack-pem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakePEM = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE=\n-----END OPENSSH PRIVATE KEY-----"
        let vaultPrivRef = "vault.priv.\(UUID().uuidString)"
        let vaultPassRef = "vault.pass.\(UUID().uuidString)"
        let missingJumpId = UUID()

        let pemSession = Session(
            name: "RawPEM",
            host: "192.0.2.88",
            username: "root",
            authMethod: .privateKey(keychainRef: fakePEM, passphraseRef: nil),
            jumpServerChain: [missingJumpId]
        )
        let vaultFallbackSession = Session(
            name: "VaultFallback",
            host: "192.0.2.89",
            username: "deploy",
            authMethod: .privateKey(keychainRef: vaultPrivRef, passphraseRef: vaultPassRef)
        )

        let sourceSecrets = InMemorySecretStore([
            vaultPrivRef: fakePEM,
            vaultPassRef: "vault-$$-pass"
        ])
        let data = try await SessionBundleExporter.exportEnvelopeData(
            sessions: [pemSession, vaultFallbackSession],
            protectionMode: .appSealed,
            vaultKeys: [], // Intentionally omit vaultKeys metadata so publicKeyOpenSSH is empty
            secretLookup: { sourceSecrets.get($0) }
        )

        let bundle = try XCTUnwrap(SessionBundleExporter.inspectSharePackData(data).decryptedBundle)
        let destStore = SessionStore(baseDirectory: tempDir)
        let destSecrets = InMemorySecretStore()
        let result = try SessionBundleExporter.importDecryptedBundle(
            bundle,
            into: destStore,
            vaultManager: nil,
            secretSaver: { k, v in destSecrets.save(k, secret: v) }
        )

        XCTAssertEqual(result.importedSessions, 2)
        XCTAssertEqual(result.importedCredentials, 2)

        let importedPEM = try XCTUnwrap(destStore.sessions.first(where: { $0.name == "RawPEM" }))
        XCTAssertEqual(importedPEM.privateKeyPath, fakePEM)
        XCTAssertTrue(importedPEM.jumpServerChain.isEmpty, "Dangling jump UUID must be sanitized on import")
        XCTAssertNil(importedPEM.jumpServerId)

        let importedVault = try XCTUnwrap(destStore.sessions.first(where: { $0.name == "VaultFallback" }))
        XCTAssertEqual(importedVault.privateKeyPath, fakePEM)
        XCTAssertEqual(destSecrets.get(importedVault.passphraseRef ?? ""), "vault-$$-pass")
    }
}
