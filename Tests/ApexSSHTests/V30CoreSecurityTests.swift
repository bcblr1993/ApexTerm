import XCTest
import AppKit
import CryptoKit
import Darwin
import os
@testable import ApexCore
@testable import ApexUI

@MainActor
final class V30CoreSecurityTests: XCTestCase {

    // MARK: - Shared Test Doubles

    private final class MockBiometricAuthenticator: BiometricAuthenticating, @unchecked Sendable {
        private struct State {
            var nextResult: Result<Void, Error>
            var callCount: Int = 0
            var lastReason: String?
        }

        private let state: OSAllocatedUnfairLock<State>

        init(nextResult: Result<Void, Error> = .success(())) {
            self.state = OSAllocatedUnfairLock(initialState: State(nextResult: nextResult))
        }

        func setResult(_ result: Result<Void, Error>) {
            state.withLock { $0.nextResult = result }
        }

        var callCount: Int {
            state.withLock { $0.callCount }
        }

        func authenticate(reason: String) async -> Result<Void, Error> {
            state.withLock {
                $0.callCount += 1
                $0.lastReason = reason
                return $0.nextResult
            }
        }
    }

    @MainActor
    private final class MockPasteboard: SensitivePasteboardWriting {
        var changeCount: Int = 100
        var lastString: String?
        var writtenTypes: [NSPasteboard.PasteboardType: Data] = [:]
        var clearCalls: Int = 0

        func clearContents() {
            clearCalls += 1
            changeCount += 1
            lastString = nil
            writtenTypes.removeAll()
        }

        func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) {
            lastString = string
            writtenTypes[dataType] = Data(string.utf8)
        }

        func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) {
            if let data {
                writtenTypes[dataType] = data
            } else {
                writtenTypes.removeValue(forKey: dataType)
            }
        }
    }

    private final class MockNotificationDeliverer: DesktopNotificationDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var _delivered: [DesktopNotificationPayload] = []

        var delivered: [DesktopNotificationPayload] {
            lock.withLock { _delivered }
        }

        func deliver(_ payload: DesktopNotificationPayload) {
            lock.withLock { _delivered.append(payload) }
        }
    }

    private func makeIsolatedDefaults(prefix: String = "v30") -> (defaults: UserDefaults, suite: String) {
        let suite = "com.apexterm.tests.\(prefix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    // MARK: - TC-V30-01: AppLockManager Authenticated Downgrade Protection & Lock Hook

    func testTCV30_01_AppLockAuthenticatedDowngradeProtectionAndLockNotification() async {
        let (defaults, suite) = makeIsolatedDefaults(prefix: "applock")
        defer { defaults.removePersistentDomain(forName: suite) }

        let auth = MockBiometricAuthenticator(nextResult: .success(()))
        let manager = AppLockManager(userDefaults: defaults, authenticator: auth)

        var didLockCallbackCount = 0
        manager.onDidLock = { didLockCallbackCount += 1 }
        let notificationCount = OSAllocatedUnfairLock(initialState: 0)
        let token = NotificationCenter.default.addObserver(
            forName: AppLockManager.appDidLockNotification,
            object: manager,
            queue: nil
        ) { _ in
            notificationCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Enable protections
        let enabled = await manager.setAppLockEnabled(true)
        XCTAssertTrue(enabled)
        XCTAssertTrue(manager.appLockEnabled)
        let bgEnabled = await manager.setLockOnAppBackground(true)
        XCTAssertTrue(bgEnabled)
        XCTAssertTrue(manager.lockOnAppBackground)
        XCTAssertEqual(auth.callCount, 1)

        // Failing authentication prevents weakening any security control
        auth.setResult(.failure(AppLockError.authenticationCancelled))

        let disableLockRes = await manager.setAppLockEnabled(false)
        XCTAssertFalse(disableLockRes)
        XCTAssertTrue(manager.appLockEnabled, "Disabling appLockEnabled must require authentication")

        let disableSensitiveRes = await manager.setRequireAuthForSensitiveActions(false)
        XCTAssertFalse(disableSensitiveRes)
        XCTAssertTrue(manager.requireAuthForSensitiveActions, "Disabling requireAuthForSensitiveActions must require authentication")

        let zeroTimeoutRes = await manager.updateIdleTimeout(0)
        XCTAssertFalse(zeroTimeoutRes)
        XCTAssertEqual(manager.idleTimeoutSeconds, 300, "Setting idleTimeoutSeconds = 0 while protected must require authentication")

        let higherTimeoutRes = await manager.updateIdleTimeout(900)
        XCTAssertFalse(higherTimeoutRes)
        XCTAssertEqual(manager.idleTimeoutSeconds, 300, "Increasing idleTimeoutSeconds while protected must require authentication")

        let disableBgRes = await manager.setLockOnAppBackground(false)
        XCTAssertFalse(disableBgRes)
        XCTAssertTrue(manager.lockOnAppBackground, "Disabling lockOnAppBackground while protected must require authentication")

        // Strengthening idle timeout (300 -> 60) does not require authentication
        let shortenTimeoutRes = await manager.updateIdleTimeout(60)
        XCTAssertTrue(shortenTimeoutRes)
        XCTAssertEqual(manager.idleTimeoutSeconds, 60)

        // Lock fires callback & notification, and resetPreferences/resetNonSecurityPreferences cannot bypass lock
        manager.lockNow()
        XCTAssertTrue(manager.isLocked)
        XCTAssertEqual(didLockCallbackCount, 1)
        XCTAssertEqual(notificationCount.withLock { $0 }, 1)

        manager.resetPreferences()
        manager.resetNonSecurityPreferences()
        XCTAssertTrue(manager.isLocked, "resetPreferences must not clear active lock without authentication")
        XCTAssertTrue(manager.appLockEnabled, "resetPreferences must not disable active appLockEnabled")
        XCTAssertTrue(manager.lockOnAppBackground)
        XCTAssertEqual(manager.idleTimeoutSeconds, 60)

        // Succeeding authentication allows weakening/disabling
        auth.setResult(.success(()))
        let unlocked = await manager.unlockWithAuthentication()
        XCTAssertTrue(unlocked)
        XCTAssertFalse(manager.isLocked)
        let disabledSensitive = await manager.setRequireAuthForSensitiveActions(false)
        XCTAssertTrue(disabledSensitive)
        XCTAssertFalse(manager.requireAuthForSensitiveActions)
        let disabledBg = await manager.setLockOnAppBackground(false)
        XCTAssertTrue(disabledBg)
        XCTAssertFalse(manager.lockOnAppBackground)
        let disabledIdle = await manager.updateIdleTimeout(0)
        XCTAssertTrue(disabledIdle)
        XCTAssertEqual(manager.idleTimeoutSeconds, 0)
        let disabledAppLock = await manager.setAppLockEnabled(false)
        XCTAssertTrue(disabledAppLock)
        XCTAssertFalse(manager.appLockEnabled)
    }

    // MARK: - TC-V30-02: SensitivePasteboardHelper Concealed/Transient Markers & ChangeCount Auto-Clear

    func testTCV30_02_SensitivePasteboardHelperConcealedMarkersAndConditionalAutoClear() {
        let (defaults, suite) = makeIsolatedDefaults(prefix: "pasteboard")
        defer { defaults.removePersistentDomain(forName: suite) }

        let pasteboard = MockPasteboard()
        var scheduledActions: [(delay: TimeInterval, action: @MainActor () -> Void)] = []
        var cancelledCount = 0

        let helper = SensitivePasteboardHelper(
            pasteboard: pasteboard,
            userDefaults: defaults,
            scheduler: { delay, action in
                scheduledActions.append((delay, action))
                return { cancelledCount += 1 }
            }
        )

        XCTAssertEqual(helper.autoClearSeconds, 30)

        // 1. Copy secret writes concealed & transient types and clears when changeCount still matches
        let count1 = helper.copySecret("-----BEGIN OPENSSH PRIVATE KEY-----\nSECRET\n")
        XCTAssertEqual(pasteboard.lastString, "-----BEGIN OPENSSH PRIVATE KEY-----\nSECRET\n")
        XCTAssertEqual(pasteboard.writtenTypes[SensitivePasteboardHelper.concealedType], Data())
        XCTAssertEqual(pasteboard.writtenTypes[SensitivePasteboardHelper.transientType], Data())
        XCTAssertEqual(helper.lastChangeCount, count1)
        XCTAssertEqual(scheduledActions.count, 1)
        XCTAssertEqual(scheduledActions[0].delay, 30)

        scheduledActions[0].action()
        XCTAssertNil(pasteboard.lastString, "Clipboard must be cleared when changeCount still matches")
        XCTAssertNil(helper.lastChangeCount)

        // 2. If user copies something else before timer fires, scheduled clear must NOT overwrite newer clipboard
        _ = helper.copySecret("secret-2", autoClearAfter: 15)
        XCTAssertEqual(scheduledActions.count, 2)
        XCTAssertEqual(scheduledActions[1].delay, 15)

        pasteboard.clearContents()
        pasteboard.setString("user-normal-copy", forType: .string)
        scheduledActions[1].action()
        XCTAssertEqual(pasteboard.lastString, "user-normal-copy", "Auto-clear must never clobber a newer user clipboard entry")

        // 3. autoClearSeconds == 0 disables scheduling
        helper.autoClearSeconds = 0
        _ = helper.copySecret("secret-3")
        XCTAssertEqual(scheduledActions.count, 2, "autoClearSeconds == 0 must not schedule auto-clear")
        XCTAssertGreaterThanOrEqual(cancelledCount, 1)
    }

    // MARK: - TC-V30-03: KnownHostsManager App Store Path vs Direct Path & Permissions

    func testTCV30_03_KnownHostsManagerAppStorePathAndDisplayString() throws {
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("V30KnownHostsHome_\(UUID().uuidString)", isDirectory: true)
        let fakeAppSupport = fakeHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        let directURL = KnownHostsManager.defaultFileURL(
            for: .direct,
            homeDirectory: fakeHome,
            appSupportDirectory: fakeAppSupport
        )
        XCTAssertEqual(directURL.path, fakeHome.appendingPathComponent(".ssh/known_hosts").path)

        let storeURL = KnownHostsManager.defaultFileURL(
            for: .appStore,
            homeDirectory: fakeHome,
            appSupportDirectory: fakeAppSupport
        )
        XCTAssertEqual(storeURL.path, fakeAppSupport.appendingPathComponent("ApexTerm/SSH/known_hosts").path)

        let manager = KnownHostsManager(fileURL: storeURL)
        XCTAssertEqual(manager.displayPath, "Application Support/ApexTerm/SSH/known_hosts")

        // Writing an entry inside the App Store SSH path creates 0700 directory and 0600 file
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sampleLine = "example.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\nother.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBX9p7wK8vL2mN4qR6sT8uV0wX2yZ4aB6cD8eF0gH2iJ\n"
        try sampleLine.write(to: storeURL, atomically: true, encoding: .utf8)
        manager.reload()
        XCTAssertEqual(manager.entries.count, 2)

        XCTAssertTrue(try manager.removeEntry(id: manager.entries[0].id))
        let perms = (try FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual((perms ?? 0) & 0o777, 0o600)
    }

    // MARK: - TC-V30-04: iCloudSync Single-Token Password Sanitization & Locked Notification Redaction

    func testTCV30_04_ICloudSingleTokenSanitizationAndLockedNotificationRedaction() {
        let managedID = "ssh_\(UUID().uuidString)"
        let managedSession = Session(
            name: "Managed",
            host: "192.0.2.10",
            username: "ops",
            authMethod: .password(keychainRef: managedID)
        )
        let singleTokenSession = Session(
            name: "SingleToken",
            host: "192.0.2.11",
            username: "ops",
            authMethod: .password(keychainRef: "hunter2")
        )
        let sanitized = iCloudSyncManager.sanitizeForCloud(
            payload: iCloudSyncPayload(sessions: [managedSession, singleTokenSession])
        )
        XCTAssertEqual(sanitized.sessions[0].authMethod, .password(keychainRef: managedID))
        XCTAssertEqual(sanitized.sessions[1].authMethod, .password(keychainRef: ""))

        // Locked notification redaction
        let (defaults, suite) = makeIsolatedDefaults(prefix: "notify")
        defer { defaults.removePersistentDomain(forName: suite) }

        let sink = MockNotificationDeliverer()
        var locked = true
        let notifyManager = DesktopNotificationManager(
            defaults: defaults,
            deliverer: sink,
            isAppActive: { false },
            activeTabID: { nil },
            isAppLocked: { locked }
        )
        notifyManager.minimumCommandDurationSeconds = 5.0

        let tabID = UUID()
        notifyManager.handleCommandCompleted(
            commandText: "curl -H 'Authorization: Bearer TOPSECRET_TOKEN' https://api.internal",
            durationMs: 12_000,
            exitCode: 0,
            tabID: tabID,
            sessionTitle: "prod-secret-host"
        )
        notifyManager.handleOSCNotification(
            title: "Secret DB Alert",
            body: "Password rotated to Pass#999",
            tabID: tabID,
            sessionTitle: "prod-secret-host"
        )

        XCTAssertEqual(sink.delivered.count, 2)
        for payload in sink.delivered {
            XCTAssertEqual(payload.title, "AetherTerm 已锁定")
            XCTAssertEqual(payload.body, "安全提示：终端任务已完成")
            XCTAssertNil(payload.subtitle)
            XCTAssertFalse(payload.body.contains("TOPSECRET_TOKEN"))
            XCTAssertFalse(payload.body.contains("Pass#999"))
            XCTAssertFalse(payload.title.contains("prod-secret-host"))
            XCTAssertFalse(payload.title.contains("Secret DB Alert"))
        }

        // Unlocked resumes full notification detail
        locked = false
        notifyManager.handleOSCNotification(
            title: "Build Ready",
            body: "Artifact uploaded",
            tabID: tabID,
            sessionTitle: "build-node"
        )
        XCTAssertEqual(sink.delivered.count, 3)
        XCTAssertEqual(sink.delivered[2].title, "Build Ready")
        XCTAssertEqual(sink.delivered[2].body, "Artifact uploaded")
    }

    // MARK: - TC-V30-05: SSHKeyVaultManager 0600 Creation, Import Rollback & Stale Key Cleanup

    func testTCV30_05_SSHKeyVaultAtomicPermissionsRollbackAndStaleCleanup() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("V30VaultTests_\(UUID().uuidString)", isDirectory: true)
        let matDir = tempDir.appendingPathComponent("mat", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vault = SSHKeyVaultManager(baseDirectory: tempDir)
        let samplePub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH6jK6t+n6R5v+q1U6qW4yG6tH4x8W2x+JkL7Z9P0ABC ops@v30"
        let samplePriv = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----"

        // 1. Mid-way import failure rolls back already-saved private key reference
        var store: [String: String] = [:]
        var deletedKeys: [String] = []
        enum SimulatedKeychainFailure: Error { case passphraseSaveFailed }

        XCTAssertThrowsError(try vault.importKey(
            name: "RollbackKey",
            privateKeyPEM: samplePriv,
            publicKeyOpenSSH: samplePub,
            passphrase: "my-passphrase",
            secretSaver: { key, secret in
                if key.hasPrefix("vault.pass.") {
                    throw SimulatedKeychainFailure.passphraseSaveFailed
                }
                store[key] = secret
                return key
            },
            secretDeleter: { key in
                deletedKeys.append(key)
                store.removeValue(forKey: key)
            }
        ))

        XCTAssertTrue(store.isEmpty, "Failed import must roll back saved private key from Keychain")
        XCTAssertEqual(deletedKeys.count, 1)
        XCTAssertTrue(deletedKeys[0].hasPrefix("vault.priv."))
        XCTAssertTrue(vault.keys.isEmpty)

        // 2. Materialized key uses 0700 dir & 0600 file and cleanupStaleMaterializedKeys purges leftovers
        let privRef = "vault.priv.\(UUID().uuidString)"
        let path1 = try XCTUnwrap(SSHKeyVaultManager.materializePrivateKeyPath(
            for: privRef,
            directory: matDir,
            lookup: { $0 == privRef ? samplePriv : nil }
        ))
        let dirPerms = (try FileManager.default.attributesOfItem(atPath: matDir.path)[.posixPermissions] as? NSNumber)?.intValue
        let filePerms = (try FileManager.default.attributesOfItem(atPath: path1)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual((dirPerms ?? 0) & 0o777, 0o700)
        XCTAssertEqual((filePerms ?? 0) & 0o777, 0o600)

        // Re-materializing over existing file succeeds atomically and preserves 0600
        let path2 = try XCTUnwrap(SSHKeyVaultManager.materializePrivateKeyPath(
            for: privRef,
            directory: matDir,
            lookup: { $0 == privRef ? samplePriv : nil }
        ))
        XCTAssertEqual(path1, path2)
        let filePerms2 = (try FileManager.default.attributesOfItem(atPath: path2)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual((filePerms2 ?? 0) & 0o777, 0o600)

        SSHKeyVaultManager.cleanupStaleMaterializedKeys(directory: matDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: matDir.path))
    }

    // MARK: - TC-V30-06: SessionLogger 0700/0600 Permissions, Unique Filenames & Rotation Header

    func testTCV30_06_SessionLoggerPermissionsUniqueFilenamesAndRotation() throws {
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("V30Logs_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: logDir) }

        let session = Session(name: "SameSecond", host: "192.0.2.50", port: 22, username: "audit")
        let config = SessionLogConfig(
            autoLoggingEnabled: true,
            logDirectoryPath: logDir.path,
            format: .plainText,
            maxFileSizeMB: 1
        )

        let logger1 = SessionLogger(session: session, config: config)
        let logger2 = SessionLogger(session: session, config: config)
        defer {
            logger1.close()
            logger2.close()
        }

        let url1 = try XCTUnwrap(logger1.activeFileURL)
        let url2 = try XCTUnwrap(logger2.activeFileURL)
        XCTAssertNotEqual(url1.lastPathComponent, url2.lastPathComponent, "Same-second tabs must receive distinct log filenames")
        XCTAssertNil(logger1.lastWriteError)
        XCTAssertNil(logger2.lastWriteError)

        let dirPerms = (try FileManager.default.attributesOfItem(atPath: logDir.path)[.posixPermissions] as? NSNumber)?.intValue
        let filePerms1 = (try FileManager.default.attributesOfItem(atPath: url1.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual((dirPerms ?? 0) & 0o777, 0o700)
        XCTAssertEqual((filePerms1 ?? 0) & 0o777, 0o600)

        // Trigger rotation by writing > 1 MB
        let bigChunk = Data(String(repeating: "A", count: 1_100_000).utf8)
        logger1.appendData(bigChunk)
        logger1.close()

        let rotatedURL = url1.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path), "Rotated log file .1 must exist")
        let activeAfterRotate = try String(contentsOf: url1, encoding: .utf8)
        XCTAssertTrue(activeAfterRotate.contains("AetherTerm Session Log Rotated at"), "Rotated log file must start with a header stamp")
        let postRotatePerms = (try FileManager.default.attributesOfItem(atPath: url1.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual((postRotatePerms ?? 0) & 0o777, 0o600)
    }

    // MARK: - TC-V30-07: SSHConfigParser Flag Reset, Tunnel UUID Dedup, Version Helper & UpdateManager Verification

    func testTCV30_07_SSHConfigFlagOverwriteTunnelDedupVersionAndUpdateVerification() async throws {
        // 1. SSHConfigParser ForwardAgent/Compression `no` overwrites `true` on mergedSession
        let configText = """
        Host web-edge
            HostName 198.51.100.10
            User deploy
            ForwardAgent no
            Compression no
        """
        let parsed = SSHConfigParser.parse(content: configText)
        let host = try XCTUnwrap(parsed.first)
        XCTAssertEqual(host.explicitForwardAgent, false)
        XCTAssertEqual(host.explicitCompression, false)

        let existing = Session(
            name: "web-edge",
            host: "198.51.100.10",
            username: "deploy",
            authMethod: .agent,
            forwardAgent: true,
            compression: true
        )
        let merged = host.mergedSession(updating: existing)
        XCTAssertFalse(merged.forwardAgent, "Explicit ForwardAgent no must overwrite existing true")
        XCTAssertFalse(merged.compression, "Explicit Compression no must overwrite existing true")

        // Omitted directives still preserve existing settings
        let omittedHost = try XCTUnwrap(SSHConfigParser.parse(content: "Host web-edge\n    HostName 198.51.100.10\n").first)
        let preserved = omittedHost.mergedSession(updating: existing)
        XCTAssertTrue(preserved.forwardAgent)
        XCTAssertTrue(preserved.compression)

        // 2. importSharePackData deduplicates colliding tunnel UUIDs
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("V30PackTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(baseDirectory: tempDir)
        let tunManager = SSHTunnelManager(baseDirectory: tempDir)
        let existingSession = Session(name: "ExistingHost", host: "198.51.100.20", username: "ops", authMethod: .agent)
        store.addSession(existingSession)
        let collidingTunnelID = UUID()
        try tunManager.addTunnel(SSHTunnel(
            id: collidingTunnelID,
            name: "ExistingTunnel",
            type: .local,
            sessionId: existingSession.id,
            bindPort: 15432,
            targetHost: "127.0.0.1",
            targetPort: 5432
        ))

        let incomingSession = Session(name: "NewHost", host: "198.51.100.21", username: "ops", authMethod: .agent)
        let incomingTunnel = SSHTunnel(
            id: collidingTunnelID,
            name: "ImportedTunnel",
            type: .local,
            sessionId: incomingSession.id,
            bindPort: 15433,
            targetHost: "127.0.0.1",
            targetPort: 5432
        )
        let packData = try SessionBundleExporter.exportSharePackData(
            sessions: [incomingSession],
            tunnels: [incomingTunnel]
        )
        let report = try SessionBundleExporter.importSharePackData(packData, into: store, tunnelManager: tunManager)
        XCTAssertEqual(report.importedTunnels, 1)
        XCTAssertEqual(tunManager.tunnels.count, 2)
        XCTAssertEqual(Set(tunManager.tunnels.map(\.id)).count, 2)

        // 3. Shared Bundle version fallback has no stale literals
        let fallbackVersion = Bundle.apexResolvedAppVersion
        XCTAssertFalse(["1.4.0", "1.12.0", "1.17.2", "1.23.0", "1.26.0"].contains(fallbackVersion))
        XCTAssertEqual(UpdateManager().currentVersion, fallbackVersion)
        XCTAssertEqual(iCloudSyncManager.resolvedAppVersion, fallbackVersion)

        // 4. UpdateManager SHA-256 verification, codesign rejection of unsigned bundle, log dir, & pre-exit hook
        let archiveURL = tempDir.appendingPathComponent("update.tar.gz")
        let archiveBytes = Data("test-archive-payload".utf8)
        try archiveBytes.write(to: archiveURL)
        let expectedHex = SHA256.hash(data: archiveBytes).map { String(format: "%02x", $0) }.joined()

        try UpdateManager.verifyArchiveSHA256(at: archiveURL, expectedHex: expectedHex)
        XCTAssertThrowsError(try UpdateManager.verifyArchiveSHA256(
            at: archiveURL,
            expectedHex: String(repeating: "0", count: 64)
        ))
        let parsedHex = UpdateManager.parseExpectedSHA256(
            from: "\(expectedHex)  AetherTerm-v1.30.0-macos-arm64.tar.gz\n",
            filename: "AetherTerm-v1.30.0-macos-arm64.tar.gz"
        )
        XCTAssertEqual(parsedHex, expectedHex)

        let unsignedApp = tempDir.appendingPathComponent("Unsigned.app", isDirectory: true)
        try FileManager.default.createDirectory(at: unsignedApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: unsignedApp.appendingPathComponent("Contents/MacOS/ApexTerm"))
        XCTAssertThrowsError(try UpdateManager.verifyCodeSignature(at: unsignedApp))

        let fakeLogHome = tempDir.appendingPathComponent("LogHome", isDirectory: true)
        let updateLogURL = try UpdateManager.defaultUpdateLogURL(homeDirectory: fakeLogHome)
        XCTAssertEqual(updateLogURL.path, fakeLogHome.appendingPathComponent("Library/Logs/AetherTerm/update.log").path)
        let logDirPerms = (try FileManager.default.attributesOfItem(atPath: updateLogURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual((logDirPerms ?? 0) & 0o777, 0o700)

        // Signature failure aborts startInAppUpdate and does not reach .readyToRestart
        let failingUpdateManager = UpdateManager(
            distributionChannel: .direct,
            fetch: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
            downloadHandler: { _, _ in
                let copyURL = tempDir.appendingPathComponent("dl-\(UUID().uuidString).tar.gz")
                try archiveBytes.write(to: copyURL)
                return copyURL
            },
            extractHandler: { _, _ in unsignedApp },
            signatureValidator: { url in try UpdateManager.verifyCodeSignature(at: url) }
        )
        let rel = ReleaseInfo(
            version: "9.9.9",
            releaseDate: "2026-11-26",
            title: "Test",
            notes: "Notes",
            downloadUrl: "https://example.com",
            packageUrl: "https://example.com/update.tar.gz",
            packageName: "update.tar.gz",
            expectedSHA256: expectedHex
        )
        await failingUpdateManager.startInAppUpdate(release: rel)
        guard case .failed = failingUpdateManager.status else {
            return XCTFail("Expected .failed when signature validation fails, got \(failingUpdateManager.status)")
        }

        // Pre-exit cleanup hook runs synchronously
        var cleanupCalled = false
        failingUpdateManager.onBeforeTerminateForUpdate = { cleanupCalled = true }
        failingUpdateManager.runPreExitCleanupForUpdate()
        XCTAssertTrue(cleanupCalled)
    }
}
