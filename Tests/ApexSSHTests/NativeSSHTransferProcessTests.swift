import Foundation
import ApexCore
import XCTest
@testable import ApexSSH

final class NativeSSHTransferProcessTests: XCTestCase {
    func testIdenticalHostsHaveIndependentControlConnections() {
        let config = Session(name: "same host", host: "example.test", username: "qa", authMethod: .agent)
        let first = NativeSSHSession(session: config)
        let second = NativeSSHSession(session: config)
        XCTAssertNotEqual(first.controlSocketPath, second.controlSocketPath, "Closing one tab must not close another tab's SFTP and monitoring control connection")
    }

    func testSCPRemotePathIsLiteralAndIPv6IsBracketed() {
        XCTAssertEqual(NativeSSHSession.scpRemoteSpecifier(username: "qa", host: "::1", path: "/tmp/中文 'quote' $literal.txt"), "qa@[::1]:/tmp/中文 'quote' $literal.txt")
        XCTAssertEqual(NativeSSHSession.scpRemoteSpecifier(username: "qa", host: "[::1]", path: "/tmp/a b"), "qa@[::1]:/tmp/a b")
    }

    func testLargeSCPErrorOutputCannotBlockTransfer() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/usr/bin/head -c 1048576 /dev/zero >&2"]
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe

        let transfer = Task { try await NativeSSHSession.runSCPProcess(process, standardError: pipe) }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(3))
            transfer.cancel()
        }
        defer { deadline.cancel() }

        let output = try await transfer.value
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(output.count, 65_536, "Retain only bounded diagnostic output")
    }
}
