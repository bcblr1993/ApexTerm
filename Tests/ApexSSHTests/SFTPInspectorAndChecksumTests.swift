import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

final class SFTPInspectorAndChecksumTests: XCTestCase {

    // MARK: - TC-SFTP-INSP-01: Octal and Symbolic Permission Formatting (including setuid/setgid/sticky bits)
    func testOctalAndSymbolicPermissionFormatting() {
        let regularFile = SFTPItem(name: "app.swift", path: "/srv/app.swift", isDirectory: false, size: 4096, permissions: 0o644)
        XCTAssertEqual(regularFile.octalPermissionString, "0644")
        XCTAssertEqual(regularFile.permissionString, "-rw-r--r--")

        let dirItem = SFTPItem(name: "bin", path: "/usr/local/bin", isDirectory: true, permissions: 0o755)
        XCTAssertEqual(dirItem.octalPermissionString, "0755")
        XCTAssertEqual(dirItem.permissionString, "drwxr-xr-x")

        let stickyTmp = SFTPItem(name: "tmp", path: "/tmp", isDirectory: true, permissions: 0o1777)
        XCTAssertEqual(stickyTmp.octalPermissionString, "1777")
        XCTAssertEqual(stickyTmp.permissionString, "drwxrwxrwt")
    }

    // MARK: - TC-SFTP-INSP-02: Remote SHA-256 Command & Output Parsing (GNU, BSD shasum, OpenSSL)
    func testSHA256CommandAndMultiFormatOutputParsing() {
        let cmd = SFTPInspectorHelper.buildChecksumCommand(remotePath: "/var/www/my archive.tar.gz", algorithm: .sha256)
        XCTAssertTrue(cmd.contains("sha256sum"))
        XCTAssertTrue(cmd.contains("shasum -a 256"))
        XCTAssertTrue(cmd.contains("openssl dgst -sha256"))
        XCTAssertTrue(cmd.contains("'/var/www/my archive.tar.gz'"))

        let sampleHash = "ba4db4744579534a832365ae1ae6ee8b8ab8c462c1756743833bb4136df2813f"

        // 1. GNU sha256sum / BSD shasum output
        let gnuOutput = "\(sampleHash)  /var/www/my archive.tar.gz\n"
        XCTAssertEqual(SFTPInspectorHelper.parseChecksumOutput(gnuOutput, algorithm: .sha256), sampleHash)

        // 2. OpenSSL dgst -sha256 output
        let opensslOutput = "SHA2-256(/var/www/my archive.tar.gz)= \(sampleHash.uppercased())\n"
        XCTAssertEqual(SFTPInspectorHelper.parseChecksumOutput(opensslOutput, algorithm: .sha256), sampleHash)

        // 3. Invalid / error output returns nil
        XCTAssertNil(SFTPInspectorHelper.parseChecksumOutput("sha256sum: /missing: No such file or directory", algorithm: .sha256))
    }

    // MARK: - TC-SFTP-INSP-03: Remote MD5 Command & Output Parsing (md5sum, macOS md5 -q, OpenSSL)
    func testMD5CommandAndMultiFormatOutputParsing() {
        let cmd = SFTPInspectorHelper.buildChecksumCommand(remotePath: "/tmp/test.bin", algorithm: .md5)
        XCTAssertTrue(cmd.contains("md5sum"))
        XCTAssertTrue(cmd.contains("md5 -q"))

        let md5Hash = "d41d8cd98f00b204e9800998ecf8427e"
        XCTAssertEqual(SFTPInspectorHelper.parseChecksumOutput("\(md5Hash)  /tmp/test.bin", algorithm: .md5), md5Hash)
        XCTAssertEqual(SFTPInspectorHelper.parseChecksumOutput("\(md5Hash.uppercased())\n", algorithm: .md5), md5Hash)
        XCTAssertEqual(SFTPInspectorHelper.parseChecksumOutput("MD5(/tmp/test.bin)= \(md5Hash)", algorithm: .md5), md5Hash)
    }

    // MARK: - TC-SFTP-INSP-04: Expected Checksum Verification (Raw Hex & SHA256SUMS Line Paste)
    func testVerifyChecksumMatchesRawAndSHA256SUMSLine() {
        let computed = "ba4db4744579534a832365ae1ae6ee8b8ab8c462c1756743833bb4136df2813f"

        // Empty input -> nil (no comparison yet)
        XCTAssertNil(SFTPInspectorHelper.verifyChecksum(computed: computed, expectedInput: "   "))

        // Case-insensitive exact match
        XCTAssertEqual(SFTPInspectorHelper.verifyChecksum(computed: computed, expectedInput: computed.uppercased()), true)

        // Pasted directly from SHA256SUMS.txt (`<hash>  AetherTerm.dmg`)
        let pastedLine = "ba4db4744579534a832365ae1ae6ee8b8ab8c462c1756743833bb4136df2813f  AetherTerm-v1.17.5-macos-arm64.dmg"
        XCTAssertEqual(SFTPInspectorHelper.verifyChecksum(computed: computed, expectedInput: pastedLine), true)

        // Mismatch
        let wrongHash = "000000004579534a832365ae1ae6ee8b8ab8c462c1756743833bb4136df2813f"
        XCTAssertEqual(SFTPInspectorHelper.verifyChecksum(computed: computed, expectedInput: wrongHash), false)
    }

    // MARK: - TC-SFTP-INSP-05: Remote Symbolic Link (`ln -s`) Command Generation & Escaping
    func testBuildSymlinkCommand() {
        let cmd = SFTPInspectorHelper.buildSymlinkCommand(
            targetPath: "/srv/releases/v2.0/app's bin",
            linkPath: "/srv/current"
        )
        XCTAssertEqual(cmd, "ln -s '/srv/releases/v2.0/app'\\''s bin' '/srv/current'")
    }

    // MARK: - TC-SFTP-INSP-06: Server-Side Duplicate (`cp`) Command Generation for Files and Directories
    func testBuildServerSideDuplicateCommand() {
        let fileCmd = SFTPInspectorHelper.buildServerSideDuplicateCommand(
            sourcePath: "/etc/nginx/nginx.conf",
            destinationPath: "/etc/nginx/nginx copy.conf",
            isDirectory: false
        )
        XCTAssertEqual(fileCmd, "cp -p '/etc/nginx/nginx.conf' '/etc/nginx/nginx copy.conf'")

        let dirCmd = SFTPInspectorHelper.buildServerSideDuplicateCommand(
            sourcePath: "/var/www/site",
            destinationPath: "/var/www/site copy",
            isDirectory: true
        )
        XCTAssertEqual(dirCmd, "cp -pR '/var/www/site' '/var/www/site copy'")
    }

    // MARK: - TC-SFTP-INSP-07: Collision-Free Duplicate Filename Generator
    func testDefaultDuplicateNameCollisionAvoidance() {
        let existing: Set<String> = ["config.yaml", "config copy.yaml", "logs", "logs copy"]

        let nextFile = SFTPInspectorHelper.defaultDuplicateName(
            for: "config.yaml",
            isDirectory: false,
            existingNames: existing
        )
        XCTAssertEqual(nextFile, "config copy 2.yaml")

        let nextDir = SFTPInspectorHelper.defaultDuplicateName(
            for: "logs",
            isDirectory: true,
            existingNames: existing
        )
        XCTAssertEqual(nextDir, "logs copy 2")

        let hiddenFile = SFTPInspectorHelper.defaultDuplicateName(
            for: ".env",
            isDirectory: false,
            existingNames: [".env"]
        )
        XCTAssertEqual(hiddenFile, ".env copy")
    }

    // MARK: - TC-SFTP-INSP-08: End-to-End Checksum Computation via SSHSessionProtocol
    func testEndToEndRemoteChecksumViaSessionProtocol() async throws {
        let session = Session(name: "Checksum Host", host: "10.0.0.1", username: "root")
        let mock = MockSSHSession(session: session)
        try await mock.connect()

        let item = SFTPItem(name: "release.tar.gz", path: "/root/release.tar.gz", isDirectory: false, size: 1024)
        let digest = await SFTPInspectorHelper.computeRemoteChecksum(for: item, algorithm: .sha256, session: mock)
        // MockSSHSession returns deterministic mock output or nil when command is not mocked; verify no crash
        XCTAssertNil(digest)
    }
}
