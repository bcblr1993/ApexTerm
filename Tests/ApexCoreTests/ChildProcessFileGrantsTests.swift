import XCTest
@testable import ApexCore

final class ChildProcessFileGrantsTests: XCTestCase {
    func testDirectoryLeaseExportsGrantForNewChildFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apex-grant-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = FileAccessLease(url: directory.appendingPathComponent("not-created.txt"), grantURL: directory, release: {})
        defer { lease.close() }
        let grant = try lease.childProcessGrant()
        XCTAssertEqual(grant.path, directory.path)
        let payload = ChildProcessGrantPayload(files: [grant])
        let resolved = try payload.resolve()
        XCTAssertEqual(resolved.first?.url.standardizedFileURL, directory.standardizedFileURL)
    }

    func testClosedLeaseCannotExportCapability() throws {
        let lease = FileAccessLease(url: FileManager.default.temporaryDirectory, release: {})
        lease.close()
        XCTAssertThrowsError(try lease.childProcessGrant())
    }

    func testArgumentRebasePreservesRemoteOperandsAndSiblingPaths() {
        let grants: [(originalPath: String, url: URL)] = [("/tmp/original", URL(fileURLWithPath: "/tmp/new place"))]
        XCTAssertEqual(ChildProcessGrantPayload.rebaseArguments([
            "-i", "/tmp/original/key", "/tmp/original", "/tmp/original-other/key", "qa@example.test:/tmp/original/key", "/tmp/original/key"
        ], using: grants, at: [1, 2, 3, 4]), ["-i", "/tmp/new place/key", "/tmp/new place", "/tmp/original-other/key", "qa@example.test:/tmp/original/key", "/tmp/original/key"])
    }

    func testSSHLocalFileSelectionStopsBeforeRemoteCommand() throws {
        let arguments = ["-tt", "-o", "ServerAliveCountMax=3", "-i", "/old/key", "-p", "2222", "qa@example.test", "-i", "/old/key"]
        let selected = try ChildProcessGrantPayload.localFileArgumentIndices(in: arguments, tool: "ssh")
        XCTAssertEqual(selected, [4])
        let rewritten = ChildProcessGrantPayload.rebaseArguments(arguments,
            using: [("/old/key", URL(fileURLWithPath: "/new/key"))], at: selected)
        XCTAssertEqual(rewritten[4], "/new/key")
        XCTAssertEqual(Array(rewritten.suffix(2)), ["-i", "/old/key"])
    }

    func testSCPSelectsIdentityAndLocalOperandsWithPreservePermissionsFlag() throws {
        let arguments = ["-p", "-r", "-S", "/bridge", "-i", "/old/key", "-P", "2222", "qa@example.test:/old/key", "/old/download/file"]
        let selected = try ChildProcessGrantPayload.localFileArgumentIndices(in: arguments, tool: "scp")
        XCTAssertEqual(selected, [5, 8, 9])
        let rewritten = ChildProcessGrantPayload.rebaseArguments(arguments,
            using: [("/old", URL(fileURLWithPath: "/new"))], at: selected)
        XCTAssertEqual(rewritten[5], "/new/key")
        XCTAssertEqual(rewritten[8], "qa@example.test:/old/key")
        XCTAssertEqual(rewritten[9], "/new/download/file")
    }

    func testMalformedLocalFileOptionIsRejected() {
        XCTAssertThrowsError(try ChildProcessGrantPayload.localFileArgumentIndices(in: ["-i"], tool: "ssh"))
    }

    func testPrivateRequestRoundTripAndIdempotentCleanup() throws {
        let request = try ChildProcessFileGrants(files: [])
        defer { request.close() }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: request.fileURL.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try ChildProcessFileGrants.read(from: request.fileURL).files.count, 0)
        request.close()
        request.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.fileURL.path))
    }

    func testRequestSymlinkIsRejected() throws {
        let request = try ChildProcessFileGrants(files: [])
        defer { request.close() }
        let link = ChildProcessFileGrants.directory.appendingPathComponent("grant-" + UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: request.fileURL)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(try ChildProcessFileGrants.read(from: link))
    }

    func testReadableByOtherUsersRequestIsRejected() throws {
        let request = try ChildProcessFileGrants(files: [])
        defer { request.close() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: request.fileURL.path)
        XCTAssertThrowsError(try ChildProcessFileGrants.read(from: request.fileURL))
    }

    func testOutsideTemporaryGrantDirectoryIsRejected() {
        XCTAssertThrowsError(try ChildProcessFileGrants.read(from: URL(fileURLWithPath: "/tmp/grant-other.json")))
    }

    func testUnknownProtocolVersionIsRejected() throws {
        let request = try ChildProcessFileGrants(files: [])
        defer { request.close() }
        try Data("{\"version\":2,\"files\":[]}".utf8).write(to: request.fileURL)
        XCTAssertThrowsError(try ChildProcessFileGrants.read(from: request.fileURL))
    }

    func testOversizedRequestIsRejected() throws {
        let request = try ChildProcessFileGrants(files: [])
        defer { request.close() }
        try Data(repeating: 32, count: 1_048_577).write(to: request.fileURL)
        XCTAssertThrowsError(try ChildProcessFileGrants.read(from: request.fileURL))
    }
}
