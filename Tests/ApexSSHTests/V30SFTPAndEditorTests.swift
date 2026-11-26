import XCTest
import CryptoKit
import SwiftUI
import AppKit
import os
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

@MainActor
final class V30SFTPAndEditorTests: XCTestCase {

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "V30SFTPAndEditorTests.\(UUID().uuidString)"
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

    // MARK: - TC-V30-20: External-edit remote conflict detection & .conflict recovery
    func testTC_V30_20_ExternalEditRemoteConflictDetectionAndRecovery() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("v30-ext-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        final class RemoteState: @unchecked Sendable {
            private let lock = NSLock()
            var content = Data("server_v1\n".utf8)
            var mtime: TimeInterval = 1_700_000_000
            var uploadCount = 0

            func snapshot() -> (Data, ExternalEditSessionManager.RemoteFileMetadata) {
                lock.withLock {
                    let hashHex = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
                    let meta = ExternalEditSessionManager.RemoteFileMetadata(
                        mtime: mtime,
                        size: Int64(content.count),
                        sha256: hashHex
                    )
                    return (content, meta)
                }
            }

            func mutateRemotely(newData: Data, newMtime: TimeInterval) {
                lock.withLock {
                    content = newData
                    mtime = newMtime
                }
            }

            func recordUpload(from localURL: URL) throws {
                let data = try Data(contentsOf: localURL)
                lock.withLock {
                    content = data
                    mtime += 10
                    uploadCount += 1
                }
            }

            func uploads() -> Int { lock.withLock { uploadCount } }
        }

        let remote = RemoteState()
        let manager = ExternalEditSessionManager(
            defaults: defaults,
            stagingRootURL: tempRoot,
            debounceDuration: .milliseconds(80),
            fallbackPollInterval: .milliseconds(30),
            downloadHandler: { _, localURL in
                let (data, _) = remote.snapshot()
                try data.write(to: localURL, options: .atomic)
            },
            uploadHandler: { localURL, _ in
                try remote.recordUpload(from: localURL)
            },
            metadataProbeHandler: { _ in
                remote.snapshot().1
            },
            openHandler: { _, _, _ in "VS Code" }
        )
        defer { manager.stopAllSessions() }

        let session = try await manager.openInExternalEditor(
            tabID: UUID(),
            sessionName: "prod",
            remotePath: "/etc/app.conf"
        )
        XCTAssertEqual(session.baselineMetadata?.size, Int64("server_v1\n".utf8.count))

        // Simulate remote concurrent modification before local save finishes
        let remoteV2 = Data("server_v2_from_teammate\n".utf8)
        remote.mutateRemotely(newData: remoteV2, newMtime: 1_700_000_050)

        // Local edit triggers auto-upload -> must pause and transition to .conflict
        try Data("local_edit_v1\n".utf8).write(to: session.localURL, options: .atomic)

        let reachedConflict = try await waitUntil {
            manager.session(id: session.id)?.status.isConflict == true
        }
        XCTAssertTrue(reachedConflict, "Auto-upload must pause and transition to .conflict when remote changed")
        XCTAssertEqual(remote.uploads(), 0, "Conflicting auto-upload must NOT overwrite remote")

        if case .conflict(let conflictState) = manager.session(id: session.id)?.status {
            XCTAssertEqual(conflictState.remoteMetadata.size, Int64(remoteV2.count))
        } else {
            XCTFail("Expected .conflict status")
        }

        // Additional local save while conflicted must remain paused
        try Data("local_edit_v2\n".utf8).write(to: session.localURL, options: .atomic)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(remote.uploads(), 0)
        XCTAssertTrue(manager.session(id: session.id)?.status.isConflict == true)

        // 1. Recover via reload remote
        await manager.resolveConflictReloadRemote(id: session.id)
        let afterReload = try XCTUnwrap(manager.session(id: session.id))
        XCTAssertEqual(afterReload.status, .watching)
        XCTAssertEqual(try Data(contentsOf: session.localURL), remoteV2)
        XCTAssertEqual(afterReload.lastHash, Data(SHA256.hash(data: remoteV2)))

        // 2. Trigger second conflict and recover via force overwrite
        remote.mutateRemotely(newData: Data("server_v3\n".utf8), newMtime: 1_700_000_100)
        let forcedPayload = Data("local_force_override\n".utf8)
        try forcedPayload.write(to: session.localURL, options: .atomic)

        let secondConflict = try await waitUntil {
            manager.session(id: session.id)?.status.isConflict == true
        }
        XCTAssertTrue(secondConflict)

        await manager.resolveConflictForceOverwrite(id: session.id)
        let afterForce = try XCTUnwrap(manager.session(id: session.id))
        XCTAssertEqual(afterForce.status, .synced)
        XCTAssertEqual(remote.uploads(), 1)
        XCTAssertEqual(remote.snapshot().0, forcedPayload)
        XCTAssertEqual(afterForce.baselineMetadata?.size, Int64(forcedPayload.count))
    }

    // MARK: - TC-V30-21: Startup stale dir sweep, pendingForcedUpload, uploadTask cancel & streaming SHA-256
    func testTC_V30_21_StaleSweepPendingForcedUploadUploadCancelAndStreamingSHA256() async throws {
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("v30-ext-sweep-\(UUID().uuidString)", isDirectory: true)
        let staleDir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staleDir, withIntermediateDirectories: true)
        try Data("orphaned".utf8).write(to: staleDir.appendingPathComponent("old.conf"))
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // 1. Streaming SHA-256 check on multi-chunk (> 512 KB) file
        let largePayload = Data((0..<(700 * 1024)).map { UInt8($0 & 0xFF) })
        let largeURL = tempRoot.appendingPathComponent("large.bin")
        try largePayload.write(to: largeURL)
        let streamedHash = try await ExternalEditSessionManager.streamingSHA256(at: largeURL, chunkSize: 64 * 1024)
        XCTAssertEqual(streamedHash, Data(SHA256.hash(data: largePayload)))

        // 2. Startup stale dir sweep + upload cancellation + pendingForcedUpload separation
        final class UploadGate: @unchecked Sendable {
            private let lock = NSLock()
            var callCount = 0
            var cancelledSeen = false
            var uploadedPayloads: [Data] = []
            var allowFirstFinish = false

            func nextCall() -> Int {
                lock.withLock {
                    callCount += 1
                    return callCount
                }
            }

            func markCancelled() { lock.withLock { cancelledSeen = true } }
            func setAllowFirstFinish(_ value: Bool) { lock.withLock { allowFirstFinish = value } }
            func canFinishFirst() -> Bool { lock.withLock { allowFirstFinish } }
            func appendPayload(_ data: Data) { lock.withLock { uploadedPayloads.append(data) } }
            func payloads() -> [Data] { lock.withLock { uploadedPayloads } }
            func wasCancelled() -> Bool { lock.withLock { cancelledSeen } }
        }

        let gate = UploadGate()
        let manager = ExternalEditSessionManager(
            defaults: defaults,
            stagingRootURL: tempRoot,
            debounceDuration: .milliseconds(60),
            fallbackPollInterval: .milliseconds(30),
            downloadHandler: { _, localURL in
                try Data("init\n".utf8).write(to: localURL)
            },
            uploadHandler: { localURL, _ in
                let idx = gate.nextCall()
                let data = try Data(contentsOf: localURL)
                if idx == 1 {
                    while !gate.canFinishFirst() {
                        if Task.isCancelled {
                            gate.markCancelled()
                            throw CancellationError()
                        }
                        try await Task.sleep(for: .milliseconds(15))
                    }
                }
                gate.appendPayload(data)
            },
            openHandler: { _, _, _ in "Zed" }
        )
        defer { manager.stopAllSessions() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDir.path), "Orphaned staging dir must be swept on startup")

        // Disable auto-upload so only explicit forced uploads run
        manager.autoUploadOnSave = false
        let s1 = try await manager.openInExternalEditor(tabID: UUID(), sessionName: "s1", remotePath: "/tmp/a.txt")
        let s1Dir = s1.localURL.deletingLastPathComponent()

        let v1 = Data("forced_v1\n".utf8)
        try v1.write(to: s1.localURL, options: .atomic)
        let firstTask = Task { await manager.triggerManualUpload(id: s1.id) }

        let uploadingStarted = try await waitUntil {
            manager.session(id: s1.id)?.status == .uploading
        }
        XCTAssertTrue(uploadingStarted)

        // Write v2 and trigger a second forced upload while the first is still in-flight
        let v2 = Data("forced_v2\n".utf8)
        try v2.write(to: s1.localURL, options: .atomic)
        await manager.triggerManualUpload(id: s1.id)

        gate.setAllowFirstFinish(true)
        await firstTask.value

        let settled = try await waitUntil {
            manager.session(id: s1.id)?.status == .synced && gate.payloads().count == 2
        }
        XCTAssertTrue(settled, "pendingForcedUpload must trigger follow-up forced upload even when autoUploadOnSave is false")
        XCTAssertEqual(gate.payloads(), [v1, v2])

        // Now test stopSession cancels active uploadTask cleanly before removing stagingDir
        let s2 = try await manager.openInExternalEditor(tabID: UUID(), sessionName: "s2", remotePath: "/tmp/b.txt")
        gate.setAllowFirstFinish(false)
        // Reset callCount to 0 so s2 upload hits the blocking branch (idx == 1)
        let s2Dir = s2.localURL.deletingLastPathComponent()
        let cancelGate = UploadGate()
        let cancelManager = ExternalEditSessionManager(
            defaults: defaults,
            stagingRootURL: tempRoot,
            debounceDuration: .milliseconds(50),
            fallbackPollInterval: .milliseconds(30),
            downloadHandler: { _, localURL in
                try Data("init\n".utf8).write(to: localURL)
            },
            uploadHandler: { _, _ in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(15))
                }
                cancelGate.markCancelled()
                throw CancellationError()
            },
            openHandler: { _, _, _ in "Zed" }
        )
        defer { cancelManager.stopAllSessions() }

        let s3 = try await cancelManager.openInExternalEditor(tabID: UUID(), sessionName: "s3", remotePath: "/tmp/c.txt")
        let s3Dir = s3.localURL.deletingLastPathComponent()
        let uploadTask = Task { await cancelManager.triggerManualUpload(id: s3.id) }
        let s3Uploading = try await waitUntil {
            cancelManager.session(id: s3.id)?.status == .uploading
        }
        XCTAssertTrue(s3Uploading)

        cancelManager.stopSession(id: s3.id)
        await uploadTask.value
        let observedCancel = try await waitUntil { cancelGate.wasCancelled() }
        XCTAssertTrue(observedCancel, "stopSession must cancel active uploadTask")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s3Dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s1Dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s2Dir.path))
    }

    // MARK: - TC-V30-22: QuickEditor NUL/binary rejection, GB18030/CRLF & UTF-16 roundtrip, TextKit1 & IME guard
    func testTC_V30_22_QuickEditorBinaryRejectionAndEncodingRoundtrip() throws {
        // 1. NUL byte rejection
        let nulData = Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01, 0x02])
        XCTAssertThrowsError(try QuickEditorTextCodec.decode(nulData)) { err in
            XCTAssertEqual(err as? QuickEditorCodecError, .binaryFileDetected)
        }

        // 2. High control-byte ratio rejection without NUL
        var controlBlob = Data(repeating: 0x41, count: 80)
        controlBlob.append(Data(repeating: 0x07, count: 20)) // 20% BEL bytes
        XCTAssertThrowsError(try QuickEditorTextCodec.decode(controlBlob)) { err in
            XCTAssertEqual(err as? QuickEditorCodecError, .binaryFileDetected)
        }

        // 3. GB18030 + CRLF roundtrip
        let cfGB = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfGB))
        let originalCRLF = "服务器配置=生产环境\r\n端口=8080\r\n"
        let gbData = try XCTUnwrap(originalCRLF.data(using: gbEncoding))
        let decodedGB = try QuickEditorTextCodec.decode(gbData)
        XCTAssertEqual(decodedGB.meta.encoding, .gb18030)
        XCTAssertEqual(decodedGB.meta.lineEnding, .crlf)
        XCTAssertEqual(decodedGB.text, "服务器配置=生产环境\n端口=8080\n")

        let reencodedGB = try QuickEditorTextCodec.encode(decodedGB.text + "新增=生效\n", meta: decodedGB.meta)
        let roundtripStr = String(data: reencodedGB, encoding: gbEncoding)
        XCTAssertEqual(roundtripStr, "服务器配置=生产环境\r\n端口=8080\r\n新增=生效\r\n")

        // 4. UTF-16 LE with BOM must NOT be rejected for containing 0x00 bytes
        var utf16Data = Data([0xFF, 0xFE])
        utf16Data.append(try XCTUnwrap("host=localhost\n".data(using: .utf16LittleEndian)))
        let decodedUTF16 = try QuickEditorTextCodec.decode(utf16Data)
        XCTAssertEqual(decodedUTF16.meta.encoding, .utf16LittleEndian)
        XCTAssertTrue(decodedUTF16.meta.hasBOM)
        XCTAssertEqual(decodedUTF16.text, "host=localhost\n")
        let reencodedUTF16 = try QuickEditorTextCodec.encode("host=127.0.0.1\n", meta: decodedUTF16.meta)
        XCTAssertTrue(reencodedUTF16.starts(with: [0xFF, 0xFE]))

        // 5. Verify NativeCodeEditor TextKit 1 explicit init & IME guard, and QuickEditorView large-file notice
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let nativeEditorSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/SFTP/NativeCodeEditor.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(nativeEditorSource.contains("NSTextView(usingTextLayoutManager: false)"))
        XCTAssertTrue(nativeEditorSource.contains("!editor.hasMarkedText()"))

        let quickEditorSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/SFTP/QuickEditorView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(quickEditorSource.contains("大文件高亮已禁用"))
        XCTAssertTrue(quickEditorSource.contains(".keyboardShortcut(isSearchVisible ? nil : .cancelAction)"))
    }

    // MARK: - TC-V30-23: Drag-export cancellation, .aetherpart download cancel cleanup & 0-byte upload
    func testTC_V30_23_DragExportCancelAetherpartCleanupAndZeroByteCount() async throws {
        TransferManager.shared.cancelAllTasks()
        TransferManager.shared.clearCompleted()
        defer {
            TransferManager.shared.cancelAllTasks()
            TransferManager.shared.clearCompleted()
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v30-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Drag-export cancellation via TransferManager.cancelTask(id:) + completeExternalTransfer guard
        let session = Session(name: "ExportNode", host: "127.0.0.1", username: "root")
        let mock = MockSSHSession(session: session)
        let startedExp = expectation(description: "Drag export entered downloadFile")
        let downloadCancelled = OSAllocatedUnfairLock(initialState: false)
        mock.customDownloadHandler = { _, localURL, _ in
            await MainActor.run { startedExp.fulfill() }
            try Data("partial".utf8).write(to: localURL)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(15))
            }
            downloadCancelled.withLock { $0 = true }
            throw CancellationError()
        }

        let item = SFTPItem(name: "huge.tar.gz", path: "/srv/huge.tar.gz", isDirectory: false, size: 1024 * 1024)
        let destURL = tempDir.appendingPathComponent("huge.tar.gz")
        let exportTask = Task {
            try await SFTPDragExportHelper.exportItemToDestination(
                item: item,
                session: mock,
                destinationURL: destURL
            )
        }

        await fulfillment(of: [startedExp], timeout: 3.0)
        let taskID = try XCTUnwrap(TransferManager.shared.tasks.first(where: { $0.fileName == "huge.tar.gz" })?.id)
        TransferManager.shared.cancelTask(id: taskID)

        do {
            _ = try await exportTask.value
            XCTFail("Cancelled drag export must throw CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertTrue(downloadCancelled.withLock { $0 })
        XCTAssertEqual(TransferManager.shared.tasks.first(where: { $0.id == taskID })?.status, .cancelled)
        // Guard: completeExternalTransfer must NOT overwrite .cancelled
        TransferManager.shared.completeExternalTransfer(taskId: taskID)
        XCTAssertEqual(TransferManager.shared.tasks.first(where: { $0.id == taskID })?.status, .cancelled)

        // 2. Download .aetherpart staging & cleanup on cancel
        let localManager = TransferManager(distributionChannel: .direct)
        let partCreatedExp = expectation(description: ".aetherpart created")
        let dlMock = MockSSHSession(session: session)
        let sawPartSuffix = OSAllocatedUnfairLock(initialState: false)
        dlMock.customDownloadHandler = { _, stagingURL, _ in
            if stagingURL.pathExtension == "aetherpart" {
                sawPartSuffix.withLock { $0 = true }
            }
            try Data("partial-bytes".utf8).write(to: stagingURL)
            await MainActor.run { partCreatedExp.fulfill() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(15))
            }
            throw CancellationError()
        }

        let finalDest = tempDir.appendingPathComponent("artifact.bin")
        let cancelExpectation = expectation(description: "Download cancelled")
        let dlTaskID = localManager.enqueueDownload(
            session: dlMock,
            remotePath: "/srv/artifact.bin",
            localURL: finalDest,
            totalBytes: 1024,
            onResult: { result in
                if case .failure = result {
                    cancelExpectation.fulfill()
                }
            }
        )
        await fulfillment(of: [partCreatedExp], timeout: 3.0)
        XCTAssertTrue(sawPartSuffix.withLock { $0 })
        localManager.cancelTask(id: dlTaskID)
        await fulfillment(of: [cancelExpectation], timeout: 3.0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: finalDest.path))
        let remainingParts = (try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "aetherpart" } ?? []
        XCTAssertTrue(remainingParts.isEmpty, "Cancelled download must clean up .aetherpart partial file")

        // 3. 0-byte upload must report transferredBytes == 0 (not 100)
        let emptyFile = tempDir.appendingPathComponent("empty.txt")
        try Data().write(to: emptyFile)
        let ulMock = MockSSHSession(session: session)
        let ulExp = expectation(description: "0-byte upload completed")
        let ulTaskID = localManager.enqueueUpload(
            session: ulMock,
            localURL: emptyFile,
            remotePath: "/srv/empty.txt",
            onResult: { _ in ulExp.fulfill() }
        )
        await fulfillment(of: [ulExp], timeout: 3.0)
        let ulTask = try XCTUnwrap(localManager.tasks.first(where: { $0.id == ulTaskID }))
        XCTAssertEqual(ulTask.totalBytes, 0)
        XCTAssertEqual(ulTask.transferredBytes, 0, "0-byte upload must not fabricate 100 transferred bytes")
    }

    // MARK: - TC-V30-24: executeCommandWithResult failure propagation, filename/chmod/rename/symlink guards
    func testTC_V30_24_RemoteOpsFailurePropagationAndValidationGuards() async throws {
        // 1. Non-zero exitCode surfaces stderr/stdout cleanly
        let okResult = SSHCommandResult(stdout: "done", stderr: "", exitCode: 0, durationMs: 1.0)
        XCTAssertNil(SFTPRemoteOperations.formatCommandFailure(okResult))

        let errResult = SSHCommandResult(stdout: "", stderr: "zip: permission denied", exitCode: 13, durationMs: 2.0)
        XCTAssertEqual(SFTPRemoteOperations.formatCommandFailure(errResult), "zip: permission denied")

        let mergedResult = SSHCommandResult(stdout: "tar: Cannot open: No such file", stderr: "", exitCode: 2, durationMs: 2.0)
        XCTAssertEqual(SFTPRemoteOperations.formatCommandFailure(mergedResult), "tar: Cannot open: No such file")

        // 2. Safe relative filename validation
        XCTAssertFalse(SFTPRemoteOperations.isSafeRelativeName(""))
        XCTAssertFalse(SFTPRemoteOperations.isSafeRelativeName("."))
        XCTAssertFalse(SFTPRemoteOperations.isSafeRelativeName(".."))
        XCTAssertFalse(SFTPRemoteOperations.isSafeRelativeName("dir/file"))
        XCTAssertFalse(SFTPRemoteOperations.isSafeRelativeName("../evil"))
        XCTAssertFalse(SFTPRemoteOperations.isSafeRelativeName("bad\0name"))
        XCTAssertTrue(SFTPRemoteOperations.isSafeRelativeName("nginx.conf"))
        XCTAssertTrue(SFTPRemoteOperations.isSafeRelativeName(".env.production"))

        // 3. Octal chmod validation & recursive command
        XCTAssertTrue(SFTPRemoteOperations.isValidOctalPermissions("755"))
        XCTAssertTrue(SFTPRemoteOperations.isValidOctalPermissions("0644"))
        XCTAssertTrue(SFTPRemoteOperations.isValidOctalPermissions("1777"))
        XCTAssertFalse(SFTPRemoteOperations.isValidOctalPermissions("888"))
        XCTAssertFalse(SFTPRemoteOperations.isValidOctalPermissions("75"))
        XCTAssertFalse(SFTPRemoteOperations.isValidOctalPermissions("755 -R"))
        XCTAssertEqual(
            SFTPRemoteOperations.chmodRecursiveCommand(remotePath: "/var/www/my app", permissions: "755"),
            "chmod -R -- '755' '/var/www/my app'"
        )
        XCTAssertNil(SFTPRemoteOperations.chmodRecursiveCommand(remotePath: "/var/www", permissions: "abc"))

        // 4. Keep-both non-colliding remote name generator
        let existing: Set<String> = ["app.tar.gz", "app (2).tar.gz", "logs", ".env"]
        XCTAssertEqual(
            SFTPRemoteOperations.availableRemoteName(for: "app.tar.gz", isDirectory: false, existingNames: existing),
            "app (3).tar.gz"
        )
        XCTAssertEqual(
            SFTPRemoteOperations.availableRemoteName(for: "logs", isDirectory: true, existingNames: existing),
            "logs (2)"
        )
        XCTAssertEqual(
            SFTPRemoteOperations.availableRemoteName(for: ".env", isDirectory: false, existingNames: existing),
            ".env (2)"
        )

        // 5. Directory remove command for replace-nesting prevention
        XCTAssertNil(SFTPRemoteOperations.removeDirectoryCommand(remotePath: "/"))
        XCTAssertNil(SFTPRemoteOperations.removeDirectoryCommand(remotePath: "~"))
        XCTAssertNil(SFTPRemoteOperations.removeDirectoryCommand(remotePath: "/tmp/../etc"))
        XCTAssertEqual(
            SFTPRemoteOperations.removeDirectoryCommand(remotePath: "/var/www/site dir"),
            "rm -rf -- '/var/www/site dir'"
        )

        // 6. Symlink probe parsing
        XCTAssertEqual(SFTPRemoteOperations.parseSymlinkProbeOutput("__AETHER_SYMLINK_DIR__\n"), .directory)
        XCTAssertEqual(SFTPRemoteOperations.parseSymlinkProbeOutput("__AETHER_SYMLINK_FILE__\n"), .regularFile)
        XCTAssertEqual(SFTPRemoteOperations.parseSymlinkProbeOutput("__AETHER_SYMLINK_BROKEN__\n"), .broken)
        XCTAssertEqual(SFTPRemoteOperations.parseSymlinkProbeOutput("noise"), .unknown)
    }
}
