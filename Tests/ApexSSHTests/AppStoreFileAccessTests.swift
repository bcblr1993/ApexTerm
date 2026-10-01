import XCTest
@testable import ApexCore
@testable import ApexSSH

@MainActor
final class AppStoreFileAccessTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apex-store-access-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let suite = "apex-store-access-" + UUID().uuidString
        return (directory, try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testDirectSSHDoesNotRequestSandboxFileAccess() throws {
        let probe = AccessProbe()
        let config = Session(name: "direct", host: "example.test", username: "qa",
                             authMethod: .privateKey(keychainRef: "/missing/key", passphraseRef: nil))
        let client = NativeSSHSession(session: config, distributionChannel: .direct,
                                      fileAccessStore: FileAccessStore(defaults: UserDefaults(), backend: probe.backend))
        XCTAssertNil(try client.acquirePrivateKeyAccess())
        XCTAssertEqual(client.sshAuthArgs(), ["-i", "/missing/key"])
        XCTAssertEqual(probe.starts, 0)
    }

    func testMovedPrivateKeyUsesResolvedPathAndRetainsGrant() throws {
        let (directory, defaults, suite) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = directory.appendingPathComponent("original-key")
        let moved = directory.appendingPathComponent("moved-key")
        try Data("test key fixture, not a credential".utf8).write(to: moved)
        let probe = AccessProbe(movedURL: moved)
        let store = FileAccessStore(defaults: defaults, backend: probe.backend)
        try store.remember(original, readOnly: true)
        probe.reset()
        let config = Session(name: "moved", host: "example.test", username: "qa",
                             authMethod: .privateKey(keychainRef: original.path, passphraseRef: nil))
        let client = NativeSSHSession(session: config, distributionChannel: .appStore, fileAccessStore: store)
        let access = try XCTUnwrap(client.acquirePrivateKeyAccess())
        XCTAssertEqual(client.sshAuthArgs(privateKeyURL: access.url), ["-i", moved.path])
        XCTAssertEqual(probe.starts, 1)
        XCTAssertEqual(probe.stops, 0)
        access.close()
        XCTAssertEqual(probe.stops, 1)
    }

    func testUnreadableStoreKeyFailsBeforePTYAndReleasesGrant() async throws {
        let (directory, defaults, suite) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let probe = AccessProbe()
        let store = FileAccessStore(defaults: defaults, backend: probe.backend)
        let config = Session(name: "missing", host: "example.test", username: "qa",
                             authMethod: .privateKey(keychainRef: directory.appendingPathComponent("missing").path,
                                                     passphraseRef: nil))
        let client = NativeSSHSession(session: config, distributionChannel: .appStore, fileAccessStore: store)
        do {
            try await client.connect()
            XCTFail("Missing authorization must fail before launching SSH")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("重新授权"))
        }
        guard case .failed = client.connectionState else { return XCTFail("Connection must report failure") }
        XCTAssertEqual(probe.starts, 1)
        XCTAssertEqual(probe.stops, 1)
        client.terminatePTYProcess()
        XCTAssertEqual(probe.stops, 1, "Failed setup must release exactly once")
    }

    func testQueuedUploadKeepsTransientGrantUntilCompletion() async throws {
        let (directory, defaults, suite) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("upload.txt")
        try Data("scoped upload fixture".utf8).write(to: file)
        let probe = AccessProbe()
        let manager = TransferManager(distributionChannel: .appStore,
                                      fileAccessStore: FileAccessStore(defaults: defaults, backend: probe.backend))
        let session = MockSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa"))
        let done = expectation(description: "Upload completes while grant is held")
        let id = manager.enqueueUpload(session: session, localURL: file, remotePath: "/fixture/upload.txt", onResult: { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            XCTAssertEqual(probe.stops, 0)
            done.fulfill()
        })
        XCTAssertEqual(probe.starts, 1, "Grant must be acquired synchronously before queue dispatch")
        XCTAssertEqual(probe.stops, 0)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(manager.tasks.first(where: { $0.id == id })?.status, .completed)
        XCTAssertEqual(probe.stops, 1)
    }

    func testQueuedDownloadReturnsMovedDestinationAndReleasesGrant() async throws {
        let (directory, defaults, suite) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = directory.appendingPathComponent("original")
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: false)
        let payload = Data("download content".utf8)
        let seed = directory.appendingPathComponent("seed.txt")
        try payload.write(to: seed)
        let session = MockSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa"))
        try await session.uploadFile(localURL: seed, remotePath: "/fixture/download.txt", progress: { _ in })
        let probe = AccessProbe(movedURL: moved)
        let store = FileAccessStore(defaults: defaults, backend: probe.backend)
        try store.remember(original, isDirectory: true)
        probe.reset()
        let manager = TransferManager(distributionChannel: .appStore, fileAccessStore: store)
        let expected = moved.appendingPathComponent("download.txt")
        let done = expectation(description: "Download uses relocated directory")
        let id = manager.enqueueDownload(session: session, remotePath: "/fixture/download.txt",
                                         localURL: original.appendingPathComponent("download.txt"), totalBytes: Int64(payload.count),
                                         onResult: { result in
            switch result {
            case .success(let url): XCTAssertEqual(url, expected)
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            XCTAssertEqual(probe.stops, 0)
            done.fulfill()
        })
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: expected), payload)
        XCTAssertEqual(manager.tasks.first(where: { $0.id == id })?.localURL, expected)
        XCTAssertEqual(probe.stops, 1)
    }

    func testCancelledQueuedUploadReleasesItsGrant() async throws {
        let (directory, defaults, suite) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("cancel.txt")
        try Data("cancel fixture".utf8).write(to: file)
        let probe = AccessProbe()
        let manager = TransferManager(distributionChannel: .appStore,
                                      fileAccessStore: FileAccessStore(defaults: defaults, backend: probe.backend))
        let session = MockSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa"))
        let done = expectation(description: "Cancelled task settles")
        let id = manager.enqueueUpload(session: session, localURL: file, remotePath: "/fixture/cancel.txt", onResult: { result in
            guard case .failure(let error) = result else { done.fulfill(); return XCTFail("Cancelled upload must fail") }
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(probe.stops, 0, "Release follows child operation cancellation")
            done.fulfill()
        })
        manager.cancelTask(id: id)
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(manager.tasks.first(where: { $0.id == id })?.status, .cancelled)
        XCTAssertEqual(probe.stops, 1)
    }

    func testInvalidLocalURLProducesFailedRecordWithoutStartingAccess() async throws {
        let (directory, defaults, suite) = try fixture()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let probe = AccessProbe()
        let manager = TransferManager(distributionChannel: .appStore,
                                      fileAccessStore: FileAccessStore(defaults: defaults, backend: probe.backend))
        let session = MockSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa"))
        let done = expectation(description: "Invalid local URL reported")
        let id = manager.enqueueDownload(session: session, remotePath: "/fixture/download.txt",
                                         localURL: try XCTUnwrap(URL(string: "https://example.test/fixture")), totalBytes: 10,
                                         onResult: { result in
            if case .success = result { XCTFail("Remote URL cannot authorize a local file") }
            done.fulfill()
        })
        await fulfillment(of: [done], timeout: 3)
        guard case .failed = manager.tasks.first(where: { $0.id == id })?.status else { return XCTFail("Missing failed record") }
        XCTAssertEqual(probe.starts, 0)
        XCTAssertEqual(manager.activeCount, 0)
    }
}

private final class AccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0
    private let movedURL: URL?
    init(movedURL: URL? = nil) { self.movedURL = movedURL }
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    func reset() { lock.withLock { startCount = 0; stopCount = 0 } }
    var backend: BookmarkBackend {
        BookmarkBackend(make: { url, _ in Data(url.path.utf8) }, resolve: { [self] data in
            (movedURL ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), movedURL != nil)
        }, start: { [self] _ in lock.withLock { startCount += 1 }; return true },
           stop: { [self] _ in lock.withLock { stopCount += 1 } })
    }
}
