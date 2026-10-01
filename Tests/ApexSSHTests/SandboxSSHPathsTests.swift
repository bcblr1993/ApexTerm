import XCTest
import ApexCore
@testable import ApexSSH

final class SandboxSSHPathsTests: XCTestCase {
    private let home = FileManager.default.temporaryDirectory.appendingPathComponent("apex-ssh-home " + UUID().uuidString)
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
    }

    func testHostTrustFileIsPrivateAndSurvivesPreparation() throws {
        let paths = SandboxSSHPaths(home: home)
        try paths.prepare()
        try Data("owned trust fixture".utf8).write(to: paths.knownHosts)
        try paths.prepare()
        XCTAssertEqual(try String(contentsOf: paths.knownHosts, encoding: .utf8), "owned trust fixture")
        let fileMode = try FileManager.default.attributesOfItem(atPath: paths.knownHosts.path)[.posixPermissions] as? NSNumber
        let dirMode = try FileManager.default.attributesOfItem(atPath: paths.directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(dirMode?.intValue, 0o700)
    }

    func testTrustFileSymlinkCannotWriteOutsideContainer() throws {
        let paths = SandboxSSHPaths(home: home)
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = home.appendingPathComponent("untouched")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.knownHosts, withDestinationURL: target)
        XCTAssertThrowsError(try paths.prepare())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }

    func testWorldReadableTrustFileIsRejected() throws {
        let paths = SandboxSSHPaths(home: home)
        try paths.prepare()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.knownHosts.path)
        XCTAssertThrowsError(try paths.prepare())
    }

    func testOverlongUTF8SocketPathIsRejectedBeforeWriting() throws {
        let paths = SandboxSSHPaths(home: home, temporary: URL(fileURLWithPath: "/" + String(repeating: "中", count: 32)))
        XCTAssertThrowsError(try paths.prepare())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testRemoteCommandCannotSuppressDefaultConfigIsolation() throws {
        let paths = SandboxSSHPaths(home: home)
        let original = ["-p", "22", "example.test", "printf", "-F", "/remote/config"]
        let args = try paths.arguments(prependingTo: original, tool: "ssh")
        XCTAssertEqual(Array(args.prefix(2)), ["-F", "/dev/null"])
        XCTAssertEqual(Array(args.suffix(original.count)), original)
        let explicit = try paths.arguments(prependingTo: ["-F", "/selected/config", "example.test"], tool: "ssh")
        XCTAssertEqual(explicit.filter { $0 == "-F" }.count, 1)
        XCTAssertEqual(Array(explicit.suffix(3)), ["-F", "/selected/config", "example.test"])
    }

    func testOpenSSHParsesTrustPathContainingSpaces() throws {
        let paths = SandboxSSHPaths(home: home)
        try paths.prepare()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try paths.arguments(prependingTo: ["-G", "example.test"], tool: "ssh")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try XCTUnwrap(output.fileHandleForReading.readToEnd())
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertTrue(lines.contains { $0 == "userknownhostsfile " + paths.knownHosts.path })
    }

    func testStoreControlSocketsStayInTemporaryDirectoryAndSeparateSessions() {
        let session = Session(name: "fixture", host: "example.test", username: "qa")
        let first = NativeSSHSession(session: session, distributionChannel: .appStore, sandboxHomeURL: home, sandboxTemporaryURL: home)
        let second = NativeSSHSession(session: session, distributionChannel: .appStore, sandboxHomeURL: home, sandboxTemporaryURL: home)
        XCTAssertEqual(URL(fileURLWithPath: first.controlSocketPath).deletingLastPathComponent().path, home.path)
        XCTAssertNotEqual(first.controlSocketPath, second.controlSocketPath)
    }
}
