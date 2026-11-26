import XCTest
import CryptoKit
import os
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

@MainActor
final class V31SFTPLogTailAndDualPaneTests: XCTestCase {

    private func waitUntil(
        timeout: TimeInterval = 3.0,
        condition: @MainActor () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - TC-V31-08: RemoteLogTailStreamer bounded ring buffer + ANSI strip + live keyword/regex filter
    func testTC_V31_08_RemoteLogTailRingBufferANSIStripAndLiveFilter() {
        let cmd = RemoteLogTailStreamer.buildTailCommand(remotePath: "/var/log/app 'prod'.log", initialLines: 500)
        XCTAssertEqual(cmd, "tail -n 500 -F -- '/var/log/app '\\''prod'\\''.log'")
        XCTAssertNil(RemoteLogTailStreamer.buildTailCommand(remotePath: "/var/../etc/passwd"))

        let streamer = RemoteLogTailStreamer(remotePath: "/var/log/nginx/access.log", maxLines: 5)
        streamer.appendLine("\u{001B}[32m[INFO]\u{001B}[0m server started on :8080\r")
        streamer.appendLine("\u{001B}[31m[ERROR]\u{001B}[0m upstream timeout id=42")
        streamer.appendLine("[WARN] slow query 350ms")
        streamer.appendLine("\u{001B}]0;title\u{0007}[INFO] healthcheck ok")
        streamer.appendLine("[ERROR] connection reset by peer id=99")
        streamer.appendLine("[INFO] request completed 200")
        streamer.appendLine("[ERROR] disk threshold exceeded id=105")

        // Ring buffer must cap strictly at maxLines (5) and track dropped oldest lines (2)
        XCTAssertEqual(streamer.lines.count, 5)
        XCTAssertEqual(streamer.droppedLineCount, 2)
        XCTAssertEqual(streamer.lines.first?.text, "[WARN] slow query 350ms")
        XCTAssertEqual(streamer.lines.last?.text, "[ERROR] disk threshold exceeded id=105")
        XCTAssertFalse(streamer.lines.contains(where: { $0.text.contains("\u{001B}") }))
        XCTAssertEqual(streamer.lines[1].text, "[INFO] healthcheck ok")

        // Keyword filter (case-insensitive)
        streamer.filterQuery = "error"
        XCTAssertEqual(streamer.filteredLines.count, 2)
        XCTAssertEqual(
            streamer.filteredOutputText,
            "[ERROR] connection reset by peer id=99\n[ERROR] disk threshold exceeded id=105"
        )

        // Regex filter
        streamer.isRegexFilter = true
        streamer.filterQuery = #"id=(99|105)$"#
        XCTAssertNil(streamer.regexError)
        XCTAssertEqual(streamer.filteredLines.count, 2)

        // Invalid regex must not crash and must populate regexError
        streamer.filterQuery = "[unclosed("
        XCTAssertNotNil(streamer.regexError)
        XCTAssertTrue(streamer.filteredLines.isEmpty)
    }

    // MARK: - TC-V31-09: RemoteLogTailStreamer pause/resume buffering & cancellation cleanup
    func testTC_V31_09_RemoteLogTailPauseResumeAndCancellationCleanup() async throws {
        final class StreamControl: @unchecked Sendable {
            private let lock = NSLock()
            var continuation: AsyncThrowingStream<String, Error>.Continuation?
            var terminated = false

            func setContinuation(_ c: AsyncThrowingStream<String, Error>.Continuation) {
                lock.withLock { continuation = c }
            }

            func yield(_ text: String) {
                _ = lock.withLock { continuation?.yield(text) }
            }

            func markTerminated() {
                lock.withLock { terminated = true }
            }

            func isTerminated() -> Bool {
                lock.withLock { terminated }
            }
        }

        let control = StreamControl()
        let streamer = RemoteLogTailStreamer(
            remotePath: "/var/log/app.log",
            maxLines: 100,
            streamFactory: { _, _ in
                AsyncThrowingStream { continuation in
                    control.setContinuation(continuation)
                    continuation.onTermination = { _ in
                        control.markTerminated()
                    }
                }
            }
        )

        streamer.start()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(streamer.state, .streaming)

        control.yield("line 1\nline 2\n")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(streamer.lines.map(\.text), ["line 1", "line 2"])

        // Pause stream display: incoming lines queue in pending buffer without mutating visible lines
        streamer.pause()
        XCTAssertTrue(streamer.isPaused)
        XCTAssertEqual(streamer.state, .paused)

        control.yield("line 3\nline 4\n")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(streamer.lines.map(\.text), ["line 1", "line 2"])
        XCTAssertEqual(streamer.pendingPausedCount, 2)

        // Resume flushes pending lines in order
        streamer.resume()
        XCTAssertFalse(streamer.isPaused)
        XCTAssertEqual(streamer.state, .streaming)
        XCTAssertEqual(streamer.pendingPausedCount, 0)
        XCTAssertEqual(streamer.lines.map(\.text), ["line 1", "line 2", "line 3", "line 4"])

        // Stop cancels task and triggers stream onTermination cleanup
        streamer.stop()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(streamer.state, .stopped)
        XCTAssertTrue(control.isTerminated(), "Stopping RemoteLogTailStreamer must terminate underlying stream")
    }

    // MARK: - TC-V31-10: Breadcrumb path segmentation parsing for `/` and nested paths
    func testTC_V31_10_BreadcrumbPathSegmentationParsing() {
        XCTAssertEqual(
            SFTPPathBreadcrumbParser.segments(for: "/"),
            [SFTPPathSegment(title: "/", targetPath: "/")]
        )

        XCTAssertEqual(
            SFTPPathBreadcrumbParser.segments(for: "/var/www/html"),
            [
                SFTPPathSegment(title: "/", targetPath: "/"),
                SFTPPathSegment(title: "var", targetPath: "/var"),
                SFTPPathSegment(title: "www", targetPath: "/var/www"),
                SFTPPathSegment(title: "html", targetPath: "/var/www/html")
            ]
        )

        XCTAssertEqual(
            SFTPPathBreadcrumbParser.segments(for: "///var//www/html/"),
            [
                SFTPPathSegment(title: "/", targetPath: "/"),
                SFTPPathSegment(title: "var", targetPath: "/var"),
                SFTPPathSegment(title: "www", targetPath: "/var/www"),
                SFTPPathSegment(title: "html", targetPath: "/var/www/html")
            ]
        )

        XCTAssertEqual(
            SFTPPathBreadcrumbParser.segments(for: "~/projects/aether"),
            [
                SFTPPathSegment(title: "~", targetPath: "~"),
                SFTPPathSegment(title: "projects", targetPath: "~/projects"),
                SFTPPathSegment(title: "aether", targetPath: "~/projects/aether")
            ]
        )
    }

    // MARK: - TC-V31-11: Directory diff computation (new / modified / orphaned & filtering)
    func testTC_V31_11_DirectoryDiffComputation() {
        let now = Date()
        let localItems = [
            SFTPItem(name: "same.txt", path: "/local/same.txt", isDirectory: false, size: 128, modificationDate: now),
            SFTPItem(name: "new_local.sh", path: "/local/new_local.sh", isDirectory: false, size: 64, modificationDate: now),
            SFTPItem(name: "config.yml", path: "/local/config.yml", isDirectory: false, size: 512, modificationDate: now),
            SFTPItem(name: "app.log", path: "/local/app.log", isDirectory: false, size: 256, modificationDate: now),
            SFTPItem(name: ".env", path: "/local/.env", isDirectory: false, size: 32, modificationDate: now)
        ]
        let remoteItems = [
            SFTPItem(name: "..", path: "/remote/..", isDirectory: true, size: 0, modificationDate: now),
            SFTPItem(name: "same.txt", path: "/remote/same.txt", isDirectory: false, size: 128, modificationDate: now.addingTimeInterval(1.0)),
            SFTPItem(name: "config.yml", path: "/remote/config.yml", isDirectory: false, size: 1024, modificationDate: now),
            SFTPItem(name: "app.log", path: "/remote/app.log", isDirectory: false, size: 256, modificationDate: now.addingTimeInterval(-30.0)),
            SFTPItem(name: "remote_orphan.tar.gz", path: "/remote/remote_orphan.tar.gz", isDirectory: false, size: 4096, modificationDate: now)
        ]

        let allDiffs = SFTPDirectoryDiffComputer.computeDiff(localItems: localItems, remoteItems: remoteItems, includeHidden: true)
        XCTAssertFalse(allDiffs.contains(where: { $0.name == ".." }))

        let byName = Dictionary(uniqueKeysWithValues: allDiffs.map { ($0.name, $0) })
        XCTAssertEqual(byName["new_local.sh"]?.kind, .newLocal)
        XCTAssertEqual(byName[".env"]?.kind, .newLocal)
        XCTAssertEqual(byName["remote_orphan.tar.gz"]?.kind, .newRemote)
        XCTAssertEqual(byName["config.yml"]?.kind, .modified)
        XCTAssertEqual(byName["config.yml"]?.reason, .sizeChanged(localSize: 512, remoteSize: 1024))
        XCTAssertEqual(byName["app.log"]?.kind, .modified)
        XCTAssertEqual(byName["same.txt"]?.kind, .identical)

        let onlyDiffs = SFTPDirectoryDiffComputer.filter(allDiffs, by: .allDifferences)
        XCTAssertFalse(onlyDiffs.contains(where: { $0.name == "same.txt" }))
        XCTAssertEqual(SFTPDirectoryDiffComputer.filter(allDiffs, by: .newRemote).map(\.name), ["remote_orphan.tar.gz"])
        XCTAssertEqual(SFTPDirectoryDiffComputer.filter(allDiffs, by: .modified).map(\.name), ["app.log", "config.yml"])

        let nonHidden = SFTPDirectoryDiffComputer.computeDiff(localItems: localItems, remoteItems: remoteItems, includeHidden: false)
        XCTAssertFalse(nonHidden.contains(where: { $0.name == ".env" }))
    }

    // MARK: - TC-V31-12: Post-transfer SHA-256 verification match & mismatch failure
    func testTC_V31_12_PostTransferSHA256VerificationMatchAndMismatch() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v31-sha256-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = Data("aetherterm-v31-verified-payload".utf8)
        let expectedHex = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let wrongHex = String(repeating: "0", count: 64)

        let session = Session(name: "SHAHost", host: "127.0.0.1", username: "root")
        let mock = MockSSHSession(session: session)
        try await mock.connect()
        mock.customDownloadHandler = { _, localURL, progress in
            try payload.write(to: localURL, options: .atomic)
            progress(1.0)
        }

        // 1. Matching checksum -> completes with .verified(expectedHex)
        let matchManager = TransferManager(
            distributionChannel: .direct,
            verifyChecksumAfterTransfer: true,
            remoteChecksumProvider: { _, _ in expectedHex }
        )
        let goodDest = tempDir.appendingPathComponent("good.bin")
        let matchResultBox = OSAllocatedUnfairLock<Result<URL, Error>?>(initialState: nil)
        let goodID = matchManager.enqueueDownload(
            session: mock,
            remotePath: "/srv/good.bin",
            localURL: goodDest,
            totalBytes: Int64(payload.count),
            onResult: { result in
                matchResultBox.withLock { $0 = result }
            }
        )
        let matched = try await waitUntil {
            matchResultBox.withLock { $0 != nil } && matchManager.tasks.first(where: { $0.id == goodID })?.status == .completed
        }
        XCTAssertTrue(matched)
        XCTAssertNoThrow(try matchResultBox.withLock { $0 }?.get())
        XCTAssertEqual(matchManager.tasks.first(where: { $0.id == goodID })?.status, .completed)
        XCTAssertEqual(matchManager.checksumStatuses[goodID], .verified(expectedHex))
        XCTAssertEqual(try Data(contentsOf: goodDest), payload)

        // 2. Mismatched checksum -> fails cleanly and does not write corrupt file to destination
        let mismatchManager = TransferManager(
            distributionChannel: .direct,
            verifyChecksumAfterTransfer: true,
            remoteChecksumProvider: { _, _ in wrongHex }
        )
        let badDest = tempDir.appendingPathComponent("corrupt.bin")
        let mismatchResultBox = OSAllocatedUnfairLock<Result<URL, Error>?>(initialState: nil)
        let badID = mismatchManager.enqueueDownload(
            session: mock,
            remotePath: "/srv/corrupt.bin",
            localURL: badDest,
            totalBytes: Int64(payload.count),
            onResult: { result in
                mismatchResultBox.withLock { $0 = result }
            }
        )
        let mismatched = try await waitUntil {
            mismatchResultBox.withLock { $0 != nil } && mismatchManager.tasks.first(where: { $0.id == badID })?.status.isTerminal == true
        }
        XCTAssertTrue(mismatched)
        if case .failure = mismatchResultBox.withLock({ $0 }) {
            // Expected
        } else {
            XCTFail("Expected mismatch download to fail")
        }
        if case .failed(let message) = mismatchManager.tasks.first(where: { $0.id == badID })?.status {
            XCTAssertTrue(message.contains("SHA-256"))
        } else {
            XCTFail("Expected .failed task status on SHA-256 mismatch")
        }
        XCTAssertEqual(mismatchManager.checksumStatuses[badID], .mismatch(local: expectedHex, remote: wrongHex))
        XCTAssertFalse(FileManager.default.fileExists(atPath: badDest.path))
    }

    // MARK: - TC-V31-13: .aetherpart partial file detection and retry resume
    func testTC_V31_13_AetherpartResumeDetectionAndRetry() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("v31-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetDest = tempDir.appendingPathComponent("backup.tar.gz")
        let orphanPart = tempDir.appendingPathComponent(".backup.tar.gz.aetherpart")
        try Data("partial-head".utf8).write(to: orphanPart)

        let detected = TransferManager.detectResumablePartialFile(for: targetDest, distributionChannel: .direct)
        XCTAssertEqual(detected?.standardizedFileURL, orphanPart.standardizedFileURL)
        try? FileManager.default.removeItem(at: orphanPart)

        // Simulate failed download leaving partial .aetherpart, then retryTask(id:) resumes via rsyncResumeHandler
        let session = Session(name: "ResumeHost", host: "127.0.0.1", username: "root")
        let mock = MockSSHSession(session: session)
        try await mock.connect()
        mock.customDownloadHandler = { _, stagingURL, _ in
            try Data("chunk-1-partial".utf8).write(to: stagingURL, options: .atomic)
            throw NSError(domain: "Net", code: 54, userInfo: [NSLocalizedDescriptionKey: "Connection reset by peer"])
        }

        let rsyncObservedStaging = OSAllocatedUnfairLock<String?>(initialState: nil)
        let manager = TransferManager(
            distributionChannel: .direct,
            enableRsyncPartialResume: true,
            rsyncResumeHandler: { _, _, stagingURL, progress in
                let existing = try Data(contentsOf: stagingURL)
                rsyncObservedStaging.withLock { $0 = String(decoding: existing, as: UTF8.self) }
                try (existing + Data("-chunk-2".utf8)).write(to: stagingURL, options: .atomic)
                progress(1.0)
                return true
            }
        )

        let firstID = manager.enqueueDownload(
            session: mock,
            remotePath: "/srv/backup.tar.gz",
            localURL: targetDest,
            totalBytes: 1024
        )
        let initialFailed = try await waitUntil {
            if case .failed = manager.tasks.first(where: { $0.id == firstID })?.status {
                return true
            }
            return false
        }
        XCTAssertTrue(initialFailed)

        XCTAssertTrue(manager.canRetryTask(id: firstID))
        let retryID = try XCTUnwrap(manager.retryTask(id: firstID))

        let retryCompleted = try await waitUntil {
            manager.tasks.first(where: { $0.id == retryID })?.status == .completed
        }
        XCTAssertTrue(retryCompleted)

        XCTAssertEqual(rsyncObservedStaging.withLock { $0 }, "chunk-1-partial")
        XCTAssertTrue(manager.resumedTaskIDs.contains(retryID))
        XCTAssertEqual(String(decoding: try Data(contentsOf: targetDest), as: UTF8.self), "chunk-1-partial-chunk-2")
    }

    // MARK: - TC-V31-14: Transfer speed formatting helper & QuickEditor LF/CRLF roundtrip
    func testTC_V31_14_TransferSpeedFormattingAndQuickEditorCodec() throws {
        XCTAssertEqual(TransferManager.formatSpeed(0), "0 B/s")
        XCTAssertEqual(TransferManager.formatSpeed(512), "512 B/s")
        XCTAssertEqual(TransferManager.formatSpeed(42 * 1024), "42 KB/s")
        XCTAssertEqual(TransferManager.formatSpeed(3.5 * 1024 * 1024), "3.5 MB/s")
        XCTAssertEqual(TransferManager.formatSpeed(1.25 * 1024 * 1024 * 1024), "1.25 GB/s")

        let lfMeta = QuickEditorDocumentMeta(encoding: .utf8, lineEnding: .lf, hasBOM: false)
        let crlfMeta = QuickEditorDocumentMeta(encoding: .utf8, lineEnding: .crlf, hasBOM: false)
        let crlfBytes = try QuickEditorTextCodec.encode("alpha\nbeta", meta: crlfMeta)
        XCTAssertEqual(String(decoding: crlfBytes, as: UTF8.self), "alpha\r\nbeta")
        let lfBytes = try QuickEditorTextCodec.encode("alpha\nbeta", meta: lfMeta)
        XCTAssertEqual(String(decoding: lfBytes, as: UTF8.self), "alpha\nbeta")
    }
}
