import XCTest
import CryptoKit
import os
@testable import ApexCore
@testable import ApexSSH

@MainActor
final class ExternalEditSessionTests: XCTestCase {

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "ExternalEditSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func waitUntil(
        timeout: TimeInterval = 3.0,
        condition: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    // MARK: - TC-V29-01: Opening creates isolated temp file with downloaded bytes and records initial SHA-256 hash
    func testTC_V29_01_OpenCreatesIsolatedTempFileAndRecordsInitialSHA256() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialContent = Data("server {\n    listen 8080;\n}\n".utf8)
        let manager = ExternalEditSessionManager(
            defaults: defaults,
            debounceDuration: .milliseconds(100),
            fallbackPollInterval: .milliseconds(40),
            downloadHandler: { _, localURL in
                try initialContent.write(to: localURL, options: .atomic)
            },
            uploadHandler: { _, _ in },
            openHandler: { _, bundleID, _ in
                XCTAssertEqual(bundleID, "com.microsoft.VSCode")
                return "Visual Studio Code"
            }
        )
        defer { manager.stopAllSessions() }

        XCTAssertTrue(manager.autoUploadOnSave)
        XCTAssertEqual(manager.preferredEditorBundleID, "")
        manager.preferredEditorBundleID = "com.microsoft.VSCode"
        manager.autoUploadOnSave = false
        XCTAssertEqual(defaults.string(forKey: "externalEdit.preferredEditorBundleID"), "com.microsoft.VSCode")
        manager.resetPreferences()
        XCTAssertEqual(manager.preferredEditorBundleID, "")
        XCTAssertTrue(manager.autoUploadOnSave)

        let tabID = UUID()
        let session = try await manager.openInExternalEditor(
            tabID: tabID,
            sessionName: "prod-web",
            remotePath: "/etc/nginx/conf.d/site.conf",
            editorBundleID: "com.microsoft.VSCode"
        )

        XCTAssertEqual(session.tabID, tabID)
        XCTAssertEqual(session.sessionName, "prod-web")
        XCTAssertEqual(session.remotePath, "/etc/nginx/conf.d/site.conf")
        XCTAssertEqual(session.editorName, "Visual Studio Code")
        XCTAssertEqual(session.status, .watching)
        XCTAssertTrue(session.localURL.path.contains("aetherterm-external-edit/\(session.id.uuidString)/site.conf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.localURL.path))
        XCTAssertEqual(try Data(contentsOf: session.localURL), initialContent)
        XCTAssertEqual(session.lastHash, Data(SHA256.hash(data: initialContent)))
    }

    // MARK: - TC-V29-02: Atomic rename replacement triggers debounced auto-upload once with new bytes
    func testTC_V29_02_AtomicRenameSaveTriggersDebouncedAutoUploadOnce() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        final class UploadRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var _uploads: [(remotePath: String, data: Data)] = []
            func record(remotePath: String, data: Data) {
                lock.withLock { _uploads.append((remotePath, data)) }
            }
            var uploads: [(remotePath: String, data: Data)] {
                lock.withLock { _uploads }
            }
        }

        let recorder = UploadRecorder()
        let initialData = Data("version: 1\n".utf8)
        let manager = ExternalEditSessionManager(
            defaults: defaults,
            debounceDuration: .milliseconds(160),
            fallbackPollInterval: .milliseconds(40),
            downloadHandler: { _, localURL in
                try initialData.write(to: localURL, options: .atomic)
            },
            uploadHandler: { localURL, remotePath in
                let data = try Data(contentsOf: localURL)
                recorder.record(remotePath: remotePath, data: data)
            },
            openHandler: { _, _, _ in "Cursor" }
        )
        defer { manager.stopAllSessions() }

        let session = try await manager.openInExternalEditor(
            tabID: UUID(),
            sessionName: "staging",
            remotePath: "/app/docker-compose.yml"
        )

        // Rapidly perform two atomic rename-saves (simulating VS Code / Vim swap-rename)
        let stagingDir = session.localURL.deletingLastPathComponent()
        let swap1 = stagingDir.appendingPathComponent(".docker-compose.yml.tmp1")
        try Data("version: 2\n".utf8).write(to: swap1)
        _ = try FileManager.default.replaceItemAt(session.localURL, withItemAt: swap1)

        try await Task.sleep(for: .milliseconds(35))

        let updatedData = Data("version: 3\nservices:\n  api: {}\n".utf8)
        let swap2 = stagingDir.appendingPathComponent(".docker-compose.yml.tmp2")
        try updatedData.write(to: swap2)
        _ = try FileManager.default.replaceItemAt(session.localURL, withItemAt: swap2)

        let uploaded = try await waitUntil(timeout: 3.0) {
            recorder.uploads.count == 1 && manager.session(id: session.id)?.status == .synced
        }
        XCTAssertTrue(uploaded, "Expected debounced auto-upload to complete after atomic rename-save")

        // Confirm no extra duplicate uploads fire after settling
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(recorder.uploads.count, 1)
        XCTAssertEqual(recorder.uploads.first?.remotePath, "/app/docker-compose.yml")
        XCTAssertEqual(recorder.uploads.first?.data, updatedData)

        let current = try XCTUnwrap(manager.session(id: session.id))
        XCTAssertEqual(current.status, .synced)
        XCTAssertNotNil(current.lastSyncedAt)
        XCTAssertEqual(current.lastHash, Data(SHA256.hash(data: updatedData)))
    }

    // MARK: - TC-V29-03: Touching or rewriting identical content does NOT trigger redundant upload
    func testTC_V29_03_IdenticalContentTouchOrRewriteDoesNotUpload() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let uploadCount = OSAllocatedUnfairLock(initialState: 0)
        let initialData = Data("APP_ENV=production\nLOG_LEVEL=info\n".utf8)
        let manager = ExternalEditSessionManager(
            defaults: defaults,
            debounceDuration: .milliseconds(100),
            fallbackPollInterval: .milliseconds(40),
            downloadHandler: { _, localURL in
                try initialData.write(to: localURL, options: .atomic)
            },
            uploadHandler: { _, _ in
                uploadCount.withLock { $0 += 1 }
            },
            openHandler: { _, _, _ in "BBEdit" }
        )
        defer { manager.stopAllSessions() }

        let session = try await manager.openInExternalEditor(
            tabID: UUID(),
            sessionName: "env-node",
            remotePath: "/srv/.env"
        )

        // 1. Touch mtime without changing bytes
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: session.localURL.path
        )
        try await Task.sleep(for: .milliseconds(220))

        // 2. Rewrite identical bytes via atomic replace
        let identicalTemp = session.localURL.deletingLastPathComponent().appendingPathComponent(".env.same")
        try initialData.write(to: identicalTemp)
        _ = try FileManager.default.replaceItemAt(session.localURL, withItemAt: identicalTemp)

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(uploadCount.withLock { $0 }, 0, "SHA-256 hash comparison must suppress identical-content uploads")
        XCTAssertEqual(manager.session(id: session.id)?.status, .watching)
    }

    // MARK: - TC-V29-04: Upload failure sets .error(...) status and manual retry recovers to .synced
    func testTC_V29_04_UploadFailureSetsErrorAndManualRetryRecoversToSynced() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        struct MockUploadError: LocalizedError {
            var errorDescription: String? { "SFTP permission denied" }
        }

        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            var shouldFail = true
            var uploadedPayloads: [Data] = []
            func attemptUpload(from url: URL) throws {
                let fail = lock.withLock { shouldFail }
                if fail {
                    throw MockUploadError()
                }
                let data = try Data(contentsOf: url)
                lock.withLock { uploadedPayloads.append(data) }
            }
            func setShouldFail(_ value: Bool) {
                lock.withLock { shouldFail = value }
            }
            func payloads() -> [Data] {
                lock.withLock { uploadedPayloads }
            }
        }

        let gate = Gate()
        let initialData = Data("{\"port\":3000}\n".utf8)
        let manager = ExternalEditSessionManager(
            defaults: defaults,
            debounceDuration: .milliseconds(100),
            fallbackPollInterval: .milliseconds(40),
            downloadHandler: { _, localURL in
                try initialData.write(to: localURL, options: .atomic)
            },
            uploadHandler: { localURL, _ in
                try gate.attemptUpload(from: localURL)
            },
            openHandler: { _, _, _ in "TextEdit" }
        )
        defer { manager.stopAllSessions() }

        let session = try await manager.openInExternalEditor(
            tabID: UUID(),
            sessionName: "api",
            remotePath: "/opt/api/config.json"
        )

        let modifiedData = Data("{\"port\":8080}\n".utf8)
        try modifiedData.write(to: session.localURL, options: .atomic)

        let reachedError = try await waitUntil(timeout: 3.0) {
            if case .error = manager.session(id: session.id)?.status { return true }
            return false
        }
        XCTAssertTrue(reachedError)
        if case .error(let message) = manager.session(id: session.id)?.status {
            XCTAssertTrue(message.contains("SFTP permission denied"))
        } else {
            XCTFail("Expected .error status after failed upload")
        }

        // Recover via manual retry
        gate.setShouldFail(false)
        await manager.triggerManualUpload(id: session.id)

        let recovered = try XCTUnwrap(manager.session(id: session.id))
        XCTAssertEqual(recovered.status, .synced)
        XCTAssertNotNil(recovered.lastSyncedAt)
        XCTAssertEqual(recovered.lastHash, Data(SHA256.hash(data: modifiedData)))
        XCTAssertEqual(gate.payloads(), [modifiedData])
    }

    // MARK: - TC-V29-05: stopAll(forTabID:) stops watchers only for that tab and deletes temp staging files
    func testTC_V29_05_StopAllForTabIDIsolatesOtherTabsAndDeletesTempFiles() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let uploadedPaths = OSAllocatedUnfairLock(initialState: [String]())
        let manager = ExternalEditSessionManager(
            defaults: defaults,
            debounceDuration: .milliseconds(100),
            fallbackPollInterval: .milliseconds(40),
            downloadHandler: { remotePath, localURL in
                try Data("init:\(remotePath)\n".utf8).write(to: localURL, options: .atomic)
            },
            uploadHandler: { _, remotePath in
                uploadedPaths.withLock { $0.append(remotePath) }
            },
            openHandler: { _, _, _ in "Sublime Text" }
        )
        defer { manager.stopAllSessions() }

        let tabA = UUID()
        let tabB = UUID()

        let sessionA1 = try await manager.openInExternalEditor(tabID: tabA, sessionName: "A", remotePath: "/etc/a.conf")
        let sessionA2 = try await manager.openInExternalEditor(tabID: tabA, sessionName: "A", remotePath: "/etc/b.conf")
        let sessionB = try await manager.openInExternalEditor(tabID: tabB, sessionName: "B", remotePath: "/etc/c.conf")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionA1.localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionA2.localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionB.localURL.path))
        XCTAssertEqual(manager.sessions(forTabID: tabA).count, 2)
        XCTAssertEqual(manager.sessions(forTabID: tabB).count, 1)

        manager.stopAll(forTabID: tabA)

        XCTAssertTrue(manager.sessions(forTabID: tabA).isEmpty)
        XCTAssertEqual(manager.sessions(forTabID: tabB).map(\.id), [sessionB.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionA1.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionA1.localURL.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionA2.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionA2.localURL.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionB.localURL.path))

        // Confirm tabB watcher is still active after tabA cleanup
        try Data("updated:c\n".utf8).write(to: sessionB.localURL, options: .atomic)
        let syncedB = try await waitUntil(timeout: 3.0) {
            manager.session(id: sessionB.id)?.status == .synced
        }
        XCTAssertTrue(syncedB)
        XCTAssertEqual(uploadedPaths.withLock { $0 }, ["/etc/c.conf"])

        manager.stopAllSessions()
        XCTAssertTrue(manager.activeSessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionB.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionB.localURL.deletingLastPathComponent().path))
    }
}
