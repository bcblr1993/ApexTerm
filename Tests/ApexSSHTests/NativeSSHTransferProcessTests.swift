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

    func testControlMasterCleanupReapsMuxProcessAndSocketOnDisconnect() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"), "Local /usr/sbin/sshd unavailable")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apex_mux_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hostKey = tempDir.appendingPathComponent("host_ed25519")
        let userKey = tempDir.appendingPathComponent("user_ed25519")
        for key in [hostKey, userKey] {
            let kg = Process()
            kg.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            kg.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", key.path]
            kg.standardInput = FileHandle.nullDevice
            kg.standardOutput = FileHandle.nullDevice
            kg.standardError = FileHandle.nullDevice
            try kg.run()
            kg.waitUntilExit()
            XCTAssertEqual(kg.terminationStatus, 0)
        }

        let sockFd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(sockFd, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sockFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sockFd, $0, &len) }
        }
        close(sockFd)
        let port = Int(UInt16(bigEndian: bound.sin_port))

        let sshdConfig = tempDir.appendingPathComponent("sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey.path)
        AuthorizedKeysFile \(userKey.path).pub
        PasswordAuthentication no
        PubkeyAuthentication yes
        KbdInteractiveAuthentication no
        UsePAM no
        PidFile \(tempDir.appendingPathComponent("sshd.pid").path)
        """.write(to: sshdConfig, atomically: true, encoding: .utf8)

        let sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-f", sshdConfig.path]
        sshd.standardInput = FileHandle.nullDevice
        sshd.standardOutput = FileHandle.nullDevice
        sshd.standardError = FileHandle.nullDevice
        try sshd.run()
        defer {
            let pid = sshd.processIdentifier
            if pid > 0 { kill(pid, SIGKILL) }
            let deadline = Date().addingTimeInterval(2.0)
            while sshd.isRunning && Date() < deadline { usleep(10_000) }
        }

        let listenDeadline = Date().addingTimeInterval(3.0)
        var ready = false
        while Date() < listenDeadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd >= 0 {
                var probe = sockaddr_in()
                probe.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                probe.sin_family = sa_family_t(AF_INET)
                probe.sin_port = UInt16(port).bigEndian
                probe.sin_addr.s_addr = inet_addr("127.0.0.1")
                let rc = withUnsafePointer(to: &probe) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                close(fd)
                if rc == 0 { ready = true; break }
            }
            usleep(20_000)
        }
        XCTAssertTrue(ready)

        let session = Session(
            name: "mux-cleanup",
            host: "127.0.0.1",
            port: port,
            username: NSUserName(),
            authMethod: .privateKey(keychainRef: userKey.path, passphraseRef: nil),
            agentlessMonitorEnabled: false
        )
        let client = NativeSSHSession(session: session, distributionChannel: .direct)
        let home = await client.probeRemoteHome()
        XCTAssertNotNil(home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: client.controlSocketPath), "ControlMaster socket should exist after mux command")

        await client.disconnect()
        XCTAssertFalse(FileManager.default.fileExists(atPath: client.controlSocketPath), "ControlMaster socket must be removed on disconnect")

        // Verify ssh -O check reports no active mux master process
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        check.arguments = ["-O", "check", "-o", "ControlPath=\(client.controlSocketPath)", "-p", "\(port)", "\(NSUserName())@127.0.0.1"]
        check.standardInput = FileHandle.nullDevice
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        XCTAssertNotEqual(check.terminationStatus, 0, "ControlMaster mux master process must not survive disconnect()")
    }

    func testBracketedIPv6HostNormalizationForSCP() {
        XCTAssertEqual(NativeSSHSession.scpRemoteSpecifier(username: "qa", host: "::1", path: "/tmp/file"), "qa@[::1]:/tmp/file")
        XCTAssertEqual(NativeSSHSession.scpRemoteSpecifier(username: "qa", host: "[::1]", path: "/tmp/file"), "qa@[::1]:/tmp/file")
    }
}
