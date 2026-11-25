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

    func testAskpassBridgePreservesSpecialCharPasswordsIncludingDoubleDollarLiterally() throws {
        let specialSecrets = [
            "p@ss$$w0rd!'\"" + "` ",
            "-leading-dash$$HOME$(id)",
            "密码$$测试!#%^&*()"
        ]
        for secret in specialSecrets {
            let request = try ChildProcessFileGrants(files: [], authentication: .init(kind: .password, secret: secret))
            defer { request.close() }
            let process = Process()
            process.executableURL = bridge
            process.arguments = ["qa@example.test's password: "]
            process.environment = ProcessInfo.processInfo.environment.merging([
                ChildProcessFileGrants.environmentKey: request.fileURL.path,
                "SSH_ASKPASS": bridge.path,
                "SSH_ASKPASS_REQUIRE": "force"
            ]) { _, new in new }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), secret + "\n", "Secret must never undergo $$ or shell expansion")
        }
    }

    func testSSHPassDeliversSpecialCharPasswordIncludingDoubleDollarLiterally() throws {
        let client = NativeSSHSession(session: Session(name: "fixture", host: "example.test", username: "qa"), distributionChannel: .direct)
        guard let sshpass = client.sshpassExecutablePath else {
            throw XCTSkip("sshpass binary unavailable on host")
        }
        let secret = "p@ss$$w0rd!'\"` !#$"
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            return XCTFail("openpty failed")
        }
        defer { close(master) }

        let outPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshpass)
        process.arguments = client.sshpassArguments(secret: secret, tool: "/bin/sh") + [
            "-c",
            "printf 'user@host password: ' > /dev/tty; IFS= read -r pw < /dev/tty; printf '%s' \"$pw\""
        ]
        process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        close(slave)

        let data = try outPipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), secret, "sshpass must deliver exact literal bytes including $$")
    }

    func testStoreExecuteCommandFailsClosedWithoutGrant() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apex-store-exec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "apex-store-exec-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = FileAccessStore(defaults: defaults)
        let session = Session(
            name: "missing-grant",
            host: "127.0.0.1",
            port: 22,
            username: "qa",
            authMethod: .privateKey(keychainRef: directory.appendingPathComponent("missing.key").path, passphraseRef: nil)
        )
        let client = NativeSSHSession(
            session: session,
            distributionChannel: .appStore,
            fileAccessStore: store,
            bridgeExecutableURL: bridge,
            sandboxHomeURL: sandboxHome
        )
        do {
            _ = try await client.executeCommand("echo ok")
            XCTFail("App Store executeCommand must fail closed when key grant is missing")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("重新授权"))
        }
    }

    @MainActor
    func testStoreTestConnectionResolvesBookmarkWithoutPrematureFileExistsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apex-store-testconn-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "apex-store-testconn-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let originalKey = directory.appendingPathComponent("old.key")
        let movedKey = directory.appendingPathComponent("moved.key")
        try Data("test-key".utf8).write(to: movedKey)
        let backend = BookmarkBackend(
            make: { url, _ in Data(url.path.utf8) },
            resolve: { _ in (movedKey, true) },
            start: { _ in true },
            stop: { _ in }
        )
        let store = FileAccessStore(defaults: defaults, backend: backend)
        try store.remember(originalKey, readOnly: true)

        let session = Session(
            name: "moved-key-test",
            host: "127.0.0.1",
            port: 59998,
            username: "qa",
            authMethod: .privateKey(keychainRef: originalKey.path, passphraseRef: nil)
        )
        let client = NativeSSHSession(
            session: session,
            distributionChannel: .appStore,
            fileAccessStore: store,
            bridgeExecutableURL: bridge,
            sandboxHomeURL: sandboxHome
        )
        let result = await client.testConnection(timeoutSeconds: 1)
        XCTAssertFalse(result.isSuccess)
        XCTAssertFalse(result.errorMessage?.contains("指定的私钥文件不存在") ?? false,
                       "App Store testConnection must resolve bookmark instead of failing on stale raw path: \(result.errorMessage ?? "")")
    }

}
