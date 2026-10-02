import XCTest
@testable import ApexCore

final class FileAccessStoreTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "apexterm-file-access-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testRealBookmarkSurvivesStoreRecreation() throws {
        try withDefaults { defaults in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("fixture.txt")
            let expected = Data("bookmark round trip".utf8)
            try expected.write(to: file)
            try FileAccessStore(defaults: defaults).remember(file, readOnly: true)
            let lease = try FileAccessStore(defaults: defaults).acquire(file)
            defer { lease.close() }
            XCTAssertEqual(try Data(contentsOf: lease.url), expected)
        }
    }

    func testFolderGrantIsHeldUntilExplicitCloseAndClosedOnce() throws {
        try withDefaults { defaults in
            let probe = BookmarkProbe()
            let store = FileAccessStore(defaults: defaults, backend: probe.backend)
            let folder = URL(fileURLWithPath: "/tmp/apexterm-downloads")
            try store.remember(folder, isDirectory: true)
            probe.reset()
            let file = folder.appendingPathComponent("new-file.txt")
            let lease = try store.acquire(file)
            XCTAssertEqual(lease.url, file)
            XCTAssertEqual(probe.starts, [folder.path])
            XCTAssertTrue(probe.stops.isEmpty)
            lease.close()
            lease.close()
            XCTAssertEqual(probe.stops, [folder.path])
        }
    }

    func testDirectoryNamePrefixDoesNotGrantSiblingAccess() throws {
        try withDefaults { defaults in
            let probe = BookmarkProbe()
            let store = FileAccessStore(defaults: defaults, backend: probe.backend)
            try store.remember(URL(fileURLWithPath: "/tmp/apexterm-downloads"), isDirectory: true)
            probe.reset()
            let sibling = URL(fileURLWithPath: "/tmp/apexterm-downloads-other/file.txt")
            let lease = try store.acquire(sibling)
            defer { lease.close() }
            XCTAssertEqual(probe.resolutions, 0)
            XCTAssertEqual(probe.starts, [sibling.path])
        }
    }

    func testFileGrantDoesNotBecomeDirectoryGrant() throws {
        try withDefaults { defaults in
            let probe = BookmarkProbe()
            let store = FileAccessStore(defaults: defaults, backend: probe.backend)
            let file = URL(fileURLWithPath: "/tmp/apexterm-key")
            try store.remember(file, readOnly: true)
            probe.reset()
            let child = file.appendingPathComponent("child")
            let lease = try store.acquire(child)
            defer { lease.close() }
            XCTAssertEqual(probe.resolutions, 0)
            XCTAssertEqual(probe.starts, [child.path])
        }
    }

    func testMovedDirectoryRefreshRebasesChildAndPersistsNewAlias() throws {
        try withDefaults { defaults in
            let probe = BookmarkProbe()
            let store = FileAccessStore(defaults: defaults, backend: probe.backend)
            let original = URL(fileURLWithPath: "/tmp/apexterm-old-downloads")
            let moved = URL(fileURLWithPath: "/tmp/apexterm-moved-downloads")
            try store.remember(original, isDirectory: true)
            probe.reset()
            probe.movedURL = moved
            let first = try store.acquire(original.appendingPathComponent("new.txt"))
            XCTAssertEqual(first.url, moved.appendingPathComponent("new.txt"))
            first.close()
            probe.movedURL = nil
            probe.reset()
            let recreated = FileAccessStore(defaults: defaults, backend: probe.backend)
            let second = try recreated.acquire(moved.appendingPathComponent("next.txt"))
            defer { second.close() }
            XCTAssertEqual(probe.resolutions, 1)
            XCTAssertEqual(second.url, moved.appendingPathComponent("next.txt"))
            XCTAssertEqual(probe.starts, [moved.path])
        }
    }

    func testStaleRefreshFailureBalancesStartedScope() throws {
        try withDefaults { defaults in
            let probe = BookmarkProbe()
            let store = FileAccessStore(defaults: defaults, backend: probe.backend)
            let file = URL(fileURLWithPath: "/tmp/apexterm-original-key")
            try store.remember(file, readOnly: true)
            probe.reset()
            probe.movedURL = URL(fileURLWithPath: "/tmp/apexterm-moved-key")
            probe.failMake = true
            XCTAssertThrowsError(try store.acquire(file))
            XCTAssertEqual(probe.starts, probe.stops)
            XCTAssertEqual(probe.stops.count, 1)
        }
    }

    func testNoStopWithoutSuccessfulStart() throws {
        try withDefaults { defaults in
            let probe = BookmarkProbe()
            probe.canStart = false
            let store = FileAccessStore(defaults: defaults, backend: probe.backend)
            let lease = try store.acquire(URL(fileURLWithPath: "/tmp/apexterm-transient-file"))
            lease.close()
            XCTAssertEqual(probe.starts.count, 1)
            XCTAssertTrue(probe.stops.isEmpty)
        }
    }

    func testLeaseDeinitializationReleasesScope() throws {
        try withDefaults { defaults in
            let probe = BookmarkProbe()
            let store = FileAccessStore(defaults: defaults, backend: probe.backend)
            let file = URL(fileURLWithPath: "/tmp/apexterm-transient-file")
            var lease: FileAccessLease? = try store.acquire(file)
            XCTAssertEqual(lease?.url, file)
            lease = nil
            XCTAssertNil(lease)
            XCTAssertEqual(probe.stops, [file.path])
        }
    }

    func testNetworkURLIsRejectedBeforeAcquiringAnyScope() throws {
        try withDefaults { defaults in
            let probe = BookmarkProbe()
            let store = FileAccessStore(defaults: defaults, backend: probe.backend)
            let url = try XCTUnwrap(URL(string: "https://example.com/fixture"))
            XCTAssertThrowsError(try store.remember(url))
            XCTAssertThrowsError(try store.acquire(url))
            XCTAssertTrue(probe.starts.isEmpty)
        }
    }
}

private final class BookmarkProbe: @unchecked Sendable {
    // Each probe is confined to one synchronous test; backend closures require Sendable.
    var starts: [String] = []
    var stops: [String] = []
    var resolutions = 0
    var movedURL: URL?
    var failMake = false
    var canStart = true

    var backend: BookmarkBackend {
        BookmarkBackend(make: { [self] url, _ in
            if failMake { throw CocoaError(.fileWriteUnknown) }
            return Data(url.path.utf8)
        }, resolve: { [self] data in
            resolutions += 1
            return (movedURL ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), movedURL != nil)
        }, start: { [self] url in
            starts.append(url.path)
            return canStart
        }, stop: { [self] url in stops.append(url.path) })
    }

    func reset() { starts = []; stops = []; resolutions = 0 }
}
