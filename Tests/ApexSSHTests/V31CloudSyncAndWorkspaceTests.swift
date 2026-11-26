import XCTest
import Darwin
import os
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

final class V31CloudSyncAndWorkspaceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "icloud.sync.conflictStrategy")
        UserDefaults.standard.removeObject(forKey: "icloud.sync.autoEnabled")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("V31CloudSyncTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "icloud.sync.conflictStrategy")
        UserDefaults.standard.removeObject(forKey: "icloud.sync.autoEnabled")
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - TC-V31-22: iCloud v2 Tombstone Deletion Propagation, Newest-Wins & v1 Backwards-Compatible Decoding

    @MainActor
    func testTC_V31_22_iCloudV2TombstonesNewestWinsAndV1BackwardsCompatibility() async throws {
        // 1. Backwards-compatible decoding of legacy v1 payload JSON without `updatedAt`, `deletedTombstones`, `itemUpdatedAt`
        let v1JSON = """
        {
          "version": 1,
          "lastModified": "2025-12-01T10:00:00Z",
          "deviceId": "legacy-mac",
          "deviceName": "Legacy Mac",
          "appVersion": "1.20.0",
          "sessions": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "Legacy-Node",
              "host": "192.0.2.10",
              "port": 22,
              "username": "ops",
              "authMethod": { "agent": {} },
              "sessionType": "ssh",
              "tags": ["legacy"],
              "agentlessMonitorEnabled": true,
              "sftpAutoSyncEnabled": true,
              "keepAliveIntervalSeconds": 30,
              "createdAt": "2025-12-01T10:00:00Z"
            }
          ],
          "snippets": [],
          "triggers": [],
          "bookmarks": [],
          "tunnels": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedV1 = try decoder.decode(iCloudSyncPayload.self, from: Data(v1JSON.utf8))
        XCTAssertEqual(decodedV1.version, 1)
        XCTAssertNil(decodedV1.updatedAt)
        XCTAssertNil(decodedV1.deletedTombstones)
        XCTAssertNil(decodedV1.itemUpdatedAt)
        XCTAssertEqual(decodedV1.sessions.count, 1)
        XCTAssertNil(decodedV1.sessions.first?.environmentTier)
        XCTAssertNil(decodedV1.sessions.first?.updatedAt)

        // 2. Two-device tombstone deletion propagation + timestamped newest-wins
        let cloudDir = tempDir.appendingPathComponent("cloud", isDirectory: true)
        let backend = FileSystemCloudStorageBackend(cloudDirectory: cloudDir)

        let baseTime = Date().addingTimeInterval(-300)
        let sharedId = UUID()
        let toDeleteId = UUID()

        let storeA = SessionStore(baseDirectory: tempDir.appendingPathComponent("MacA"))
        storeA.addSession(Session(id: sharedId, name: "API-Edge", host: "198.51.100.1", username: "ops", authMethod: .agent, updatedAt: baseTime))
        storeA.addSession(Session(id: toDeleteId, name: "Temp-Box", host: "198.51.100.2", username: "ops", authMethod: .agent, updatedAt: baseTime))

        let managerA = iCloudSyncManager(storageBackend: backend, sessionStore: storeA, deviceId: "mac-a", deviceName: "Mac A")
        _ = try await managerA.syncNow()

        let storeB = SessionStore(baseDirectory: tempDir.appendingPathComponent("MacB"))
        let managerB = iCloudSyncManager(storageBackend: backend, sessionStore: storeB, deviceId: "mac-b", deviceName: "Mac B")
        _ = try await managerB.syncNow()
        XCTAssertEqual(storeB.sessions.count, 2)

        // Mac A updates API-Edge with newer timestamp and deletes Temp-Box
        let newerTime = baseTime.addingTimeInterval(60)
        var updatedShared = storeA.sessions.first(where: { $0.id == sharedId })!
        updatedShared.host = "198.51.100.99"
        updatedShared.environmentTier = .prod
        updatedShared.updatedAt = newerTime
        storeA.updateSession(updatedShared)
        storeA.deleteSession(id: toDeleteId)
        managerA.recordDeletion(id: toDeleteId, at: newerTime)
        _ = try await managerA.syncNow()

        // Mac B syncs: must receive updated host/tier and propagate deletion of Temp-Box
        _ = try await managerB.syncNow()
        XCTAssertEqual(storeB.sessions.count, 1)
        XCTAssertEqual(storeB.sessions.first?.id, sharedId)
        XCTAssertEqual(storeB.sessions.first?.host, "198.51.100.99")
        XCTAssertEqual(storeB.sessions.first?.environmentTier, .prod)
        XCTAssertFalse(storeB.sessions.contains(where: { $0.id == toDeleteId }))
    }

    // MARK: - TC-V31-23: NSFileCoordinator & .icloud Placeholder Handling

    func testTC_V31_23_UbiquityBackendNSFileCoordinatorAndPlaceholderDetection() async throws {
        let containerDir = tempDir.appendingPathComponent("ubiquity", isDirectory: true)
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)

        let placeholderURL = containerDir.appendingPathComponent(".cloud_vault.json.icloud")
        try Data("bplist00-placeholder".utf8).write(to: placeholderURL)

        let triggeredURLs = OSAllocatedUnfairLock<[URL]>(initialState: [])

        let backend = UbiquityCloudStorageBackend(
            customContainerURL: containerDir,
            downloadTrigger: { url in
                triggeredURLs.withLock { $0.append(url) }
            }
        )

        // 1. Placeholder present without materialized cloud_vault.json -> must NOT return nil (prevents empty overwrite!)
        do {
            _ = try await backend.readPayloadDataAsync()
            XCTFail("Expected cloudDownloadingPlaceholder when .cloud_vault.json.icloud exists without cloud_vault.json")
        } catch let error as iCloudSyncError {
            guard case .cloudDownloadingPlaceholder = error else {
                return XCTFail("Expected .cloudDownloadingPlaceholder, got \(error)")
            }
        }
        XCTAssertEqual(triggeredURLs.withLock { $0.count }, 1)

        // 2. Once materialized, remove placeholder and write/read through NSFileCoordinator off-MainActor
        try FileManager.default.removeItem(at: placeholderURL)
        let sampleData = Data("{\"version\":2}".utf8)
        try await backend.writePayloadDataAsync(sampleData)
        let readBack = try await backend.readPayloadDataAsync()
        XCTAssertEqual(readBack, sampleData)
    }

    // MARK: - TC-V31-24: previewDiff() Added / Modified / Deleted Computation

    @MainActor
    func testTC_V31_24_PreviewDiffComputesAddedModifiedDeletedWithoutMutation() async throws {
        let cloudDir = tempDir.appendingPathComponent("diff_cloud", isDirectory: true)
        let backend = FileSystemCloudStorageBackend(cloudDirectory: cloudDir)

        let t0 = Date(timeIntervalSince1970: 1_760_100_000)
        let t1 = t0.addingTimeInterval(120)

        let modId = UUID()
        let delId = UUID()
        let localOnlyId = UUID()
        let remoteOnlyId = UUID()

        let localStore = SessionStore(baseDirectory: tempDir.appendingPathComponent("DiffLocal"))
        localStore.addSession(Session(id: modId, name: "Shared-API", host: "10.0.0.1", username: "ops", authMethod: .agent, updatedAt: t0))
        localStore.addSession(Session(id: delId, name: "Stale-Worker", host: "10.0.0.2", username: "ops", authMethod: .agent, updatedAt: t0))
        localStore.addSession(Session(id: localOnlyId, name: "Local-New", host: "10.0.0.3", username: "ops", authMethod: .agent, updatedAt: t1))

        let remotePayload = iCloudSyncPayload(
            version: 2,
            lastModified: t1,
            updatedAt: t1,
            deviceId: "remote-mac",
            deviceName: "Remote Studio",
            sessions: [
                Session(id: modId, name: "Shared-API", host: "10.0.0.99", username: "ops", authMethod: .agent, updatedAt: t1),
                Session(id: remoteOnlyId, name: "Remote-DB", host: "10.0.0.4", username: "db", authMethod: .agent, updatedAt: t1)
            ],
            deletedTombstones: [delId: t1]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try backend.writePayloadData(try encoder.encode(remotePayload))

        let manager = iCloudSyncManager(storageBackend: backend, sessionStore: localStore)
        let diff = try await manager.previewDiff()

        XCTAssertTrue(diff.hasChanges)
        XCTAssertEqual(diff.remoteDeviceName, "Remote Studio")
        XCTAssertTrue(diff.added.contains(where: { $0.entityId == localOnlyId && $0.source == .local && $0.kind == .added }))
        XCTAssertTrue(diff.added.contains(where: { $0.entityId == remoteOnlyId && $0.source == .remote && $0.kind == .added }))
        XCTAssertTrue(diff.modified.contains(where: { $0.entityId == modId && $0.source == .remote && $0.kind == .modified }))
        XCTAssertTrue(diff.deleted.contains(where: { $0.entityId == delId && $0.source == .remote && $0.kind == .deleted }))

        // Read-only guarantee: local store must remain untouched
        XCTAssertEqual(localStore.sessions.count, 3)
        XCTAssertFalse(localStore.sessions.contains(where: { $0.id == remoteOnlyId }))
    }

    // MARK: - TC-V31-25: .aetherkeyvault Passphrase Encrypt/Decrypt & Wrong Passphrase Rejection

    @MainActor
    func testTC_V31_25_KeyVaultBackupEncryptDecryptAndWrongPassphraseRejection() throws {
        let vaultDir1 = tempDir.appendingPathComponent("vault1", isDirectory: true)
        let vaultDir2 = tempDir.appendingPathComponent("vault2", isDirectory: true)
        let vault1 = SSHKeyVaultManager(baseDirectory: vaultDir1)
        let vault2 = SSHKeyVaultManager(baseDirectory: vaultDir2)

        var keychain1: [String: String] = [:]
        var keychain2: [String: String] = [:]

        let samplePub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH6jK6t+n6R5v+q1U6qW4yG6tH4x8W2x+JkL7Z9P0ABC ops@v31"
        let samplePriv = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHI=\n-----END OPENSSH PRIVATE KEY-----"

        _ = try vault1.importKey(
            name: "Prod Bastion Key",
            privateKeyPEM: samplePriv,
            publicKeyOpenSSH: samplePub,
            passphrase: "key-inner-passphrase",
            secretSaver: { key, secret in
                keychain1[key] = secret
                return key
            },
            secretDeleter: { keychain1.removeValue(forKey: $0) }
        )

        // Empty passphrase rejected
        XCTAssertThrowsError(try vault1.exportEncryptedVaultBackup(
            passphrase: "  ",
            secretReader: { keychain1[$0] ?? "" }
        )) { error in
            XCTAssertEqual(error as? SharePackCryptoError, .emptyPassphraseNotAllowed)
        }

        // Export with strong backup passphrase
        let bundleData = try vault1.exportEncryptedVaultBackup(
            passphrase: "Vault-Backup-Pass-2026!",
            secretReader: {
                guard let val = keychain1[$0] else { throw KeychainError.itemNotFound }
                return val
            }
        )
        let bundleText = String(decoding: bundleData, as: UTF8.self)
        XCTAssertFalse(bundleText.contains("OPENSSH PRIVATE KEY"), "Plaintext PEM must never appear in encrypted .aetherkeyvault")
        XCTAssertFalse(bundleText.contains("key-inner-passphrase"), "Inner passphrase must never appear in plaintext")

        // Header inspection works without passphrase
        let header = try SSHKeyVaultManager.inspectEncryptedVaultBackup(bundleData)
        XCTAssertEqual(header.keyCount, 1)
        XCTAssertEqual(header.keyNames, ["Prod Bastion Key"])

        // Wrong passphrase must fail with .invalidPassphrase
        XCTAssertThrowsError(try vault2.importEncryptedVaultBackup(
            bundleData,
            passphrase: "Wrong-Password",
            secretSaver: { k, v in keychain2[k] = v; return k },
            secretDeleter: { keychain2.removeValue(forKey: $0) }
        )) { error in
            XCTAssertEqual(error as? SharePackCryptoError, .invalidPassphrase)
        }
        XCTAssertTrue(vault2.keys.isEmpty)

        // Correct passphrase restores key + private PEM + inner passphrase
        let report = try vault2.importEncryptedVaultBackup(
            bundleData,
            passphrase: "Vault-Backup-Pass-2026!",
            secretSaver: { k, v in keychain2[k] = v; return k },
            secretDeleter: { keychain2.removeValue(forKey: $0) }
        )
        XCTAssertEqual(report.importedCount, 1)
        XCTAssertEqual(report.skippedDuplicateCount, 0)
        XCTAssertEqual(vault2.keys.count, 1)
        let restored = try XCTUnwrap(vault2.keys.first)
        XCTAssertEqual(restored.name, "Prod Bastion Key")
        XCTAssertTrue(restored.hasPassphrase)
        XCTAssertEqual(keychain2[restored.keychainPrivateKeyRef], samplePriv)
        XCTAssertEqual(keychain2[try XCTUnwrap(restored.keychainPassphraseRef)], "key-inner-passphrase")

        // Re-importing same backup skips duplicates cleanly
        let repeatReport = try vault2.importEncryptedVaultBackup(
            bundleData,
            passphrase: "Vault-Backup-Pass-2026!",
            secretSaver: { k, v in keychain2[k] = v; return k },
            secretDeleter: { keychain2.removeValue(forKey: $0) }
        )
        XCTAssertEqual(repeatReport.importedCount, 0)
        XCTAssertEqual(repeatReport.skippedDuplicateCount, 1)
    }

    // MARK: - TC-V31-26: SessionLogger Secret Redaction & AuditLogViewer Helpers

    @MainActor
    func testTC_V31_26_SessionLoggerSecretRedactionAndAuditViewerHelpers() throws {
        let logDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        let session = Session(name: "AuditNode", host: "192.0.2.88", username: "secops")
        let config = SessionLogConfig(
            autoLoggingEnabled: true,
            logDirectoryPath: logDir.path,
            format: .plainText,
            maxFileSizeMB: 10,
            redactSecrets: true
        )

        let logger = SessionLogger(session: session, config: config)
        let chunk1 = """
        [sudo] password for secops: SuperSecretSudoPass!
        Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.topsecret.signature
        Authorization: Basic dXNlcjpwYXNzd29yZA==
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        """
        let chunk2 = """
        QyNTUxOQAAACBmockPrivateKeyBodyChunk2
        -----END OPENSSH PRIVATE KEY-----
        Normal command output: service nginx active (running)
        """
        logger.appendData(Data(chunk1.utf8))
        logger.appendData(Data(chunk2.utf8))

        let logURL = try XCTUnwrap(logger.activeFileURL)
        logger.close()

        let diskContent = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(diskContent.contains("SuperSecretSudoPass"))
        XCTAssertFalse(diskContent.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertFalse(diskContent.contains("dXNlcjpwYXNzd29yZA"))
        XCTAssertFalse(diskContent.contains("b3BlbnNzaC1rZXktdjE"))
        XCTAssertFalse(diskContent.contains("mockPrivateKeyBodyChunk2"))
        XCTAssertTrue(diskContent.contains("[REDACTED]"))
        XCTAssertTrue(diskContent.contains("[REDACTED PRIVATE KEY BLOCK]"))
        XCTAssertTrue(diskContent.contains("service nginx active (running)"))

        let perms = (try FileManager.default.attributesOfItem(atPath: logURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual((perms ?? 0) & 0o777, 0o600)

        // AuditLogViewerSheet helpers
        let listed = AuditLogViewerSheet.listLogFiles(in: logDir)
        XCTAssertEqual(listed.count, 1)
        let tail = AuditLogViewerSheet.readTail(of: logURL)
        XCTAssertTrue(tail.contains("service nginx active (running)"))
        let filtered = AuditLogViewerSheet.filterLines(in: tail, query: "nginx")
        XCTAssertTrue(filtered.contains("nginx"))
        XCTAssertFalse(filtered.contains("AetherTerm Session Log"))

        // Legacy SessionLogConfig JSON without redactSecrets defaults to true
        let legacyConfigJSON = """
        {"autoLoggingEnabled":true,"logDirectoryPath":"/tmp/logs","format":"纯文本 (过滤控制字符)","maxFileSizeMB":25}
        """
        let decodedConfig = try JSONDecoder().decode(SessionLogConfig.self, from: Data(legacyConfigJSON.utf8))
        XCTAssertTrue(decodedConfig.redactSecrets)
    }

    // MARK: - TC-V31-27: EnvironmentTier Codable Compatibility & WorkspaceSnapshotStore Roundtrip

    @MainActor
    func testTC_V31_27_EnvironmentTierCompatibilityAndWorkspaceSnapshotRoundtrip() throws {
        // 1. Legacy Session JSON without environmentTier + unknown tier value fallback
        let legacyJSON = """
        {
            "id": "A1B2C3D4-E5F6-7A8B-9C0D-1E2F3A4B5C6D",
            "name": "Legacy",
            "host": "10.0.0.1",
            "port": 22,
            "username": "ops",
            "authMethod": { "agent": {} },
            "environmentTier": "future_unknown_tier"
        }
        """
        let decodedLegacy = try JSONDecoder().decode(Session.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decodedLegacy.environmentTier, "Unknown environmentTier must safely decode to nil")

        let prodSession = Session(name: "Core DB", host: "db.prod", username: "dba", environmentTier: .prod)
        let stagingSession = Session(name: "Stage Web", host: "web.stage", username: "ops", environmentTier: .staging)
        let encoded = try JSONEncoder().encode(prodSession)
        let decodedProd = try JSONDecoder().decode(Session.self, from: encoded)
        XCTAssertEqual(decodedProd.environmentTier, .prod)
        XCTAssertEqual(decodedProd.environmentTier?.badgeText, "PROD")

        // 2. WorkspaceSnapshotStore persistence & orphan tab filtering (zero credentials)
        let snapshotDir = tempDir.appendingPathComponent("snapshots", isDirectory: true)
        let store1 = WorkspaceSnapshotStore(baseDirectory: snapshotDir)
        let deletedSessionID = UUID()

        let snap = store1.createSnapshot(
            name: "双活巡检工作区",
            tabs: [
                WorkspaceTabSnapshot(
                    sessionID: prodSession.id,
                    isLocal: false,
                    customTitle: "核心库主节点",
                    splitMode: .vertical,
                    paneCount: 2,
                    paneSplitRatio: 0.6,
                    isPaneMaximized: false,
                    currentRemotePath: "/var/lib/postgresql",
                    isDirectoryLinkageEnabled: true
                ),
                WorkspaceTabSnapshot(
                    sessionID: deletedSessionID,
                    isLocal: false,
                    customTitle: "已删除主机",
                    splitMode: .single
                ),
                WorkspaceTabSnapshot(
                    sessionID: nil,
                    isLocal: true,
                    customTitle: "本机终端",
                    splitMode: .horizontal,
                    paneCount: 2,
                    currentRemotePath: "~/projects"
                )
            ],
            selectedTabIndex: 0,
            isSFTPVisible: true,
            filesSplitRatio: 0.65
        )

        let rawFile = try String(contentsOf: store1.snapshotsFileURL, encoding: .utf8)
        XCTAssertFalse(rawFile.contains("password"))
        XCTAssertFalse(rawFile.contains("PRIVATE KEY"))

        let store2 = WorkspaceSnapshotStore(baseDirectory: snapshotDir)
        XCTAssertEqual(store2.snapshots.count, 1)
        let loaded = try XCTUnwrap(store2.snapshot(id: snap.id))
        XCTAssertEqual(loaded.name, "双活巡检工作区")
        XCTAssertEqual(loaded.tabs.count, 3)
        XCTAssertEqual(loaded.tabs[0].customTitle, "核心库主节点")
        XCTAssertEqual(loaded.tabs[0].splitMode, .vertical)
        XCTAssertEqual(loaded.tabs[0].currentRemotePath, "/var/lib/postgresql")
        XCTAssertEqual(loaded.filesSplitRatio, 0.65, accuracy: 0.001)

        // resolvedTabs filters out deletedSessionID while keeping prodSession and local tab
        let restorable = loaded.resolvedTabs(using: [prodSession, stagingSession])
        XCTAssertEqual(restorable.count, 2)
        XCTAssertEqual(restorable[0].sessionID, prodSession.id)
        XCTAssertTrue(restorable[1].isLocal)
    }

    // MARK: - TC-V31-28: Broadcast Selective Target & Snippet Preview Interpolation

    @MainActor
    func testTC_V31_28_BroadcastSelectiveTargetsAndSnippetPreviewInterpolation() {
        let tabA = UUID()
        let tabB = UUID()
        let tabC = UUID()

        var items = [
            BroadcastTargetItem(tabID: tabA, title: "prod-api-1", environmentTier: .prod, isSelected: false),
            BroadcastTargetItem(tabID: tabB, title: "staging-api-1", environmentTier: .staging, isSelected: true),
            BroadcastTargetItem(tabID: tabC, title: "dev-api-1", environmentTier: .dev, isSelected: true)
        ]

        XCTAssertEqual(BroadcastBar.selectedTargetIDs(from: items), Set([tabB, tabC]))
        XCTAssertEqual(BroadcastBar.effectiveTargetCount(targetCount: 3, targetTabs: items), 2)

        items = BroadcastBar.togglingTarget(tabA, in: items)
        items = BroadcastBar.togglingTarget(tabC, in: items)
        XCTAssertEqual(BroadcastBar.selectedTargetIDs(from: items), Set([tabA, tabB]))
        XCTAssertEqual(BroadcastBar.effectiveTargetCount(targetCount: 3, targetTabs: items), 2)

        // Snippet live preview interpolation + duplication
        let snippet = Snippet(
            title: "重启服务",
            command: "ssh {{user}}@{{host}} sudo systemctl restart {{service}}",
            category: "运维",
            autoExecute: false
        )
        let previewPartial = QuickCommandBarView.livePreviewText(
            for: snippet,
            variableValues: ["user": "ops", "host": "10.0.1.5", "service": ""]
        )
        XCTAssertEqual(previewPartial, "ssh ops@10.0.1.5 sudo systemctl restart ")

        let previewReady = QuickCommandBarView.livePreviewText(
            for: snippet,
            variableValues: ["user": "ops", "host": "10.0.1.5", "service": "nginx"]
        )
        XCTAssertEqual(previewReady, "ssh ops@10.0.1.5 sudo systemctl restart nginx")

        let manualPayload = QuickCommandBarView.executionPayload(
            for: snippet,
            context: ["user": "ops", "host": "10.0.1.5", "service": "nginx"]
        )
        XCTAssertEqual(manualPayload, "ssh ops@10.0.1.5 sudo systemctl restart nginx")

        let immediatePayload = QuickCommandBarView.executionPayload(
            for: snippet,
            context: ["user": "ops", "host": "10.0.1.5", "service": "nginx"],
            executeImmediately: true
        )
        XCTAssertEqual(immediatePayload, "ssh ops@10.0.1.5 sudo systemctl restart nginx\n")

        let duplicated = QuickCommandBarView.duplicatedSnippet(from: snippet)
        XCTAssertNotEqual(duplicated.id, snippet.id)
        XCTAssertEqual(duplicated.title, "重启服务 (副本)")
        XCTAssertEqual(duplicated.command, snippet.command)
        XCTAssertEqual(duplicated.category, snippet.category)
        XCTAssertEqual(duplicated.autoExecute, snippet.autoExecute)
    }

    // MARK: - Step 2 Integration Wiring: Settings, Multi-Pane Presets, PROD Broadcast Guard, Snapshots, Path Resolution & Trigger Lifecycle

    @MainActor
    func testV31IntegrationWiring_SettingsLayoutsSnapshotsTriggersAndProdGuard() async throws {
        let settings = AppSettings.shared
        let prevPool = settings.controlMasterPoolEnabled
        let prevAutoResp = settings.triggerAutoResponseEnabled
        let prevRestore = settings.restoreWorkspaceOnLaunch
        let prevRedact = settings.redactSecrets
        let prevPoolStatic = SSHControlMasterPool.isPoolEnabled
        defer {
            settings.controlMasterPoolEnabled = prevPool
            settings.triggerAutoResponseEnabled = prevAutoResp
            settings.restoreWorkspaceOnLaunch = prevRestore
            settings.redactSecrets = prevRedact
            SSHControlMasterPool.isPoolEnabled = prevPoolStatic
        }

        // 1. AppSettings <-> NativeTerminalView trigger opt-in & defaults
        settings.triggerAutoResponseEnabled = false
        XCTAssertFalse(NativeTerminalView.isTriggerAutoResponseEnabled())
        XCTAssertFalse(AppSettings.isTriggerAutoResponseEnabledSync)
        settings.triggerAutoResponseEnabled = true
        XCTAssertTrue(NativeTerminalView.isTriggerAutoResponseEnabled())
        XCTAssertTrue(AppSettings.isTriggerAutoResponseEnabledSync)
        settings.triggerAutoResponseEnabled = false

        // 2. Multi-pane layout presets (1x2, 2x1, 1+2, 2x2 up to 4 panes) & close fallback
        let sProd = Session(name: "prod-web", host: "10.0.10.1", username: "ops", environmentTier: .prod)
        let tab = TerminalTabItem(session: sProd, sshClient: MockSSHSession(session: sProd))
        defer { tab.tearDown() }

        tab.applyLayoutPreset(.mainPlusTwo) { MockSSHSession(session: sProd) }
        XCTAssertEqual(tab.panes.count, 3)
        XCTAssertEqual(tab.layoutPreset, .mainPlusTwo)
        XCTAssertFalse(tab.isPaneMaximized)

        tab.applyLayoutPreset(.grid2x2) { MockSSHSession(session: sProd) }
        XCTAssertEqual(tab.panes.count, 4)
        XCTAssertEqual(tab.layoutPreset, .grid2x2)

        tab.toggleMaximizeActivePane()
        XCTAssertTrue(tab.isPaneMaximized)
        XCTAssertEqual(tab.panes.count, 4, "Maximize must remain non-destructive")

        tab.closePane(id: tab.panes[3].id)
        XCTAssertEqual(tab.panes.count, 3)
        XCTAssertEqual(tab.layoutPreset, .mainPlusTwo)

        // 3. PROD broadcast confirmation guard
        let prodTarget = BroadcastTargetItem(tabID: tab.id, title: "prod-web", environmentTier: .prod, isSelected: true)
        let devTarget = BroadcastTargetItem(tabID: UUID(), title: "dev-web", environmentTier: .dev, isSelected: true)
        XCTAssertTrue(BroadcastBar.hasProdTarget(in: [prodTarget, devTarget]))
        XCTAssertTrue(BroadcastBar.requiresEnableConfirmation(remoteTargetCount: 1, hasProdTarget: true))
        XCTAssertFalse(BroadcastBar.hasProdTarget(in: [devTarget]))
        XCTAssertFalse(BroadcastBar.requiresEnableConfirmation(remoteTargetCount: 1, hasProdTarget: false))

        // 4. Detected file path resolution
        XCTAssertEqual(
            WorkspaceView.resolveDetectedPath("Sources/Foo.swift", workingDirectory: "/srv/app", fallbackDirectory: "/tmp", isLocal: false),
            "/srv/app/Sources/Foo.swift"
        )
        XCTAssertEqual(
            WorkspaceView.resolveDetectedPath("./main.py", workingDirectory: nil, fallbackDirectory: "/srv/app/", isLocal: false),
            "/srv/app/main.py"
        )
        XCTAssertEqual(
            WorkspaceView.resolveDetectedPath("/etc/nginx/nginx.conf", workingDirectory: "/srv/app", fallbackDirectory: "/tmp", isLocal: false),
            "/etc/nginx/nginx.conf"
        )

        // 5. Trigger .sendResponse gated callback & tearDown cleanup
        let mockClient = MockSSHSession(session: sProd)
        let trigTab = TerminalTabItem(session: sProd, sshClient: mockClient)
        try await mockClient.connect()
        trigTab.panes[0].connectionState = .connected
        let sendTrigger = Trigger(name: "Prompt", regexPattern: "Proceed\\?", action: .sendResponse(text: "yes\n"), cooldownSeconds: 0)
        trigTab.panes[0].ringBuffer.setTriggers([sendTrigger])

        settings.triggerAutoResponseEnabled = false
        trigTab.panes[0].ringBuffer.appendStream("Proceed?\r\n")
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(mockClient.sentInputs.isEmpty, "Trigger auto-response must not send when disabled")

        settings.triggerAutoResponseEnabled = true
        trigTab.panes[0].ringBuffer.appendStream("Proceed?\r\n")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(mockClient.sentInputs, [Data("yes\n".utf8)])

        trigTab.tearDown()
        XCTAssertNil(trigTab.panes[0].ringBuffer.onTriggerSendResponse)
        XCTAssertNil(trigTab.panes[0].ringBuffer.isTriggerAutoResponseEnabled)
        XCTAssertNil(trigTab.panes[0].ringBuffer.onDesktopNotification)

        // 6. WorkspaceSnapshot makeSnapshot & restoreSnapshot roundtrip (zero credentials)
        let storeDir = tempDir.appendingPathComponent("ws_restore", isDirectory: true)
        let sessionStore = SessionStore(baseDirectory: storeDir)
        sessionStore.addSession(sProd)

        let snapTab = TerminalTabItem(session: sProd, sshClient: MockSSHSession(session: sProd))
        snapTab.customTitle = "主库面板"
        snapTab.currentRemotePath = "/var/log/app"
        snapTab.applyLayoutPreset(.grid2x2) { MockSSHSession(session: sProd) }
        snapTab.paneSplitRatio = 0.62
        let snapshot = WorkspaceView.makeSnapshot(
            name: "核心巡检",
            tabs: [snapTab],
            selectedTabId: snapTab.id,
            isSFTPVisible: false,
            filesSplitRatio: 0.72
        )
        snapTab.tearDown()

        var restoredTabs: [TerminalTabItem] = []
        var restoredSelected: UUID?
        let restoredLayout = WorkspaceView.restoreSnapshot(
            snapshot,
            store: sessionStore,
            activeTabs: &restoredTabs,
            selectedTabId: &restoredSelected
        )
        defer { restoredTabs.forEach { $0.tearDown() } }
        XCTAssertEqual(restoredLayout.restoredCount, 1)
        XCTAssertFalse(restoredLayout.isSFTPVisible)
        XCTAssertEqual(restoredLayout.filesSplitRatio, 0.72, accuracy: 0.001)
        XCTAssertEqual(restoredTabs.first?.customTitle, "主库面板")
        XCTAssertEqual(restoredTabs.first?.panes.count, 4)
        XCTAssertEqual(restoredTabs.first?.layoutPreset, .grid2x2)
        XCTAssertEqual(restoredTabs.first?.currentRemotePath, "/var/log/app")
        XCTAssertEqual(restoredSelected, restoredTabs.first?.id)

        // 7. SettingsView keeps >= 700pt width for 6 tabs
        XCTAssertGreaterThanOrEqual(SettingsView.contentWidth, 700)
    }
}
