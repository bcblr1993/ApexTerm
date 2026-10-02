import XCTest
@testable import ApexCore
@testable import ApexSSH

final class AppStoreSSHBridgeTests: XCTestCase {
    private let sandboxHome = FileManager.default.temporaryDirectory.appendingPathComponent("apex-store-paths-" + UUID().uuidString)

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: sandboxHome.path) { try FileManager.default.removeItem(at: sandboxHome) }
    }
    private var bridge: URL {
        Bundle(for: AppStoreSSHBridgeTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ApexSSHBridge")
    }

    func testBridgeExecutesSSHWithRestoredBookmarkAndCleansRuntimeRequest() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bridge.path), "swift test must build the bridge product")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apex-bridge-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("key fixture")
        try Data("non-credential fixture".utf8).write(to: file)
        let access = try FileAccessStore().acquire(file)
        defer { access.close() }
        let client = NativeSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa"),
                                      distributionChannel: .appStore, bridgeExecutableURL: bridge, sandboxHomeURL: sandboxHome)
        let command = try XCTUnwrap(client.prepareStoreCommand(binaryPath: "/usr/bin/ssh",
            arguments: ["-F", "/dev/null", "-G", "-i", file.path, "example.test", file.path], accesses: [access]))
        defer { command.grants.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.binaryPath)
        process.arguments = command.arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment[ChildProcessFileGrants.environmentKey] = command.grants.fileURL.path
        process.environment = environment
        try process.run()
        let data = try XCTUnwrap(output.fileHandleForReading.readToEnd())
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let payload = try ChildProcessFileGrants.read(from: command.grants.fileURL)
        let expectedIdentity = try XCTUnwrap(payload.resolve().first?.url.path)
        let identityLines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("identityfile ") }
        XCTAssertTrue(identityLines.contains { $0 == "identityfile " + expectedIdentity },
                      "Only fixture identity lines: \(identityLines)")
        command.grants.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: command.grants.fileURL.path))
    }

    func testSCPRoutesItsNestedSSHThroughBridge() throws {
        let client = NativeSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa"),
                                      distributionChannel: .appStore, bridgeExecutableURL: bridge, sandboxHomeURL: sandboxHome)
        let command = try XCTUnwrap(client.prepareStoreCommand(binaryPath: "/usr/bin/scp",
            arguments: ["-P", "2222", "qa@example.test:/fixture", "/tmp/fixture"], accesses: []))
        defer { command.grants.close() }
        XCTAssertEqual(command.binaryPath, bridge.path)
        XCTAssertEqual(Array(command.arguments.prefix(4)), ["--tool", "scp", "-S", bridge.path])
        XCTAssertEqual(Array(command.arguments.suffix(4)), ["-P", "2222", "qa@example.test:/fixture", "/tmp/fixture"])
    }

    func testMissingStoreBridgeFailsClosedBeforeGrantFileCreation() throws {
        let client = NativeSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa"),
            distributionChannel: .appStore,
            bridgeExecutableURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertThrowsError(try client.prepareStoreCommand(binaryPath: "/usr/bin/ssh", arguments: [], accesses: []))
    }

    func testDirectSSHDoesNotRequireBridgeOrCreateGrantFile() throws {
        let client = NativeSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa"), distributionChannel: .direct)
        XCTAssertNil(try client.prepareStoreCommand(binaryPath: "/usr/bin/ssh", arguments: [], accesses: []))
    }

    func testNestedSCPEntryPointDefaultsToSSH() throws {
        let request = try ChildProcessFileGrants(files: [])
        defer { request.close() }
        let process = Process()
        process.executableURL = bridge
        // scp invokes its -S program with SSH flags, without a --tool prefix.
        process.arguments = ["-F", "/dev/null", "-G", "example.test"]
        process.environment = ProcessInfo.processInfo.environment.merging([ChildProcessFileGrants.environmentKey: request.fileURL.path]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try XCTUnwrap(output.fileHandleForReading.readToEnd())
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("hostname example.test"))
    }

    func testMissingGrantRequestFailsClosed() throws {
        let process = Process()
        process.executableURL = bridge
        process.arguments = ["--tool", "ssh", "-V"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: ChildProcessFileGrants.environmentKey)
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
    }

    func testBridgeCannotExecuteAnArbitraryTool() throws {
        let request = try ChildProcessFileGrants(files: [])
        defer { request.close() }
        let process = Process()
        process.executableURL = bridge
        process.arguments = ["--tool", "/bin/sh", "-c", "exit 0"]
        process.environment = ProcessInfo.processInfo.environment.merging([ChildProcessFileGrants.environmentKey: request.fileURL.path]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
    }
    func testStorePasswordCommandUsesAskpassWithoutSecretArguments() throws {
        let client = NativeSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa", authMethod: .password(keychainRef: "fixture")),
            distributionChannel: .appStore, bridgeExecutableURL: bridge, sandboxHomeURL: sandboxHome)
        let secret = "non-credential fixture"
        let command = try XCTUnwrap(client.prepareStoreCommand(binaryPath: "/usr/bin/ssh", arguments: ["example.test"], accesses: [], authenticationSecret: secret))
        defer { command.grants.close() }
        XCTAssertEqual(command.binaryPath, bridge.path)
        XCTAssertFalse(command.arguments.contains(secret))
        XCTAssertEqual(try ChildProcessFileGrants.read(from: command.grants.fileURL).authentication?.kind, .password)
    }

    func testAskpassBridgeRejectsWrongAuthenticationPromptWithoutSecretOutput() throws {
        let request = try ChildProcessFileGrants(files: [], authentication: .init(kind: .passphrase, secret: "non-credential fixture"))
        defer { request.close() }
        for (prompt, expectedStatus) in [("Enter passphrase for key '/fixture': ", Int32(0)), ("qa@example.test's password: ", Int32(1)), ("Are you sure?", Int32(1))] {
            let process = Process()
            process.executableURL = bridge
            process.arguments = [prompt]
            process.environment = ProcessInfo.processInfo.environment.merging([
                ChildProcessFileGrants.environmentKey: request.fileURL.path, "SSH_ASKPASS": bridge.path, "SSH_ASKPASS_REQUIRE": "force"
            ]) { _, new in new }
            let output = Pipe(); process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = try output.fileHandleForReading.readToEnd() ?? Data(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, expectedStatus)
            XCTAssertEqual(data.isEmpty, expectedStatus != 0)
        }
    }

}
