import XCTest
@testable import ApexCore
@testable import ApexSSH

/// Verification and regression test suite for SSH connection testing (TC-TEST-01 ~ TC-TEST-08).
final class SSHTestConnectionTests: XCTestCase {
    
    // MARK: - TC-TEST-01: SSHTestConnectionResult data model and properties
    func testTC_TEST_01_ResultDataModel() {
        let success = SSHTestConnectionResult(isSuccess: true, latencyMs: 42, serverInfo: "Linux 6.8 x86_64")
        XCTAssertTrue(success.isSuccess)
        XCTAssertEqual(success.latencyMs, 42)
        XCTAssertEqual(success.serverInfo, "Linux 6.8 x86_64")
        XCTAssertNil(success.errorMessage)
        
        let failure = SSHTestConnectionResult(isSuccess: false, latencyMs: 15, errorMessage: "认证失败：用户名或密码错误")
        XCTAssertFalse(failure.isSuccess)
        XCTAssertEqual(failure.latencyMs, 15)
        XCTAssertNil(failure.serverInfo)
        XCTAssertEqual(failure.errorMessage, "认证失败：用户名或密码错误")
    }

    // MARK: - TC-TEST-02: SSH error message parsing for authentication failures
    func testTC_TEST_02_AuthenticationErrorParsing() {
        // Exit code 5 from sshpass indicates incorrect password
        let msgExit5 = NativeSSHSession.parseSSHErrorMessage(exitCode: 5, stderr: "")
        XCTAssertTrue(msgExit5.contains("用户名或密码错误"), "Expected message to mention password error, got: \(msgExit5)")

        // Permission denied (password)
        let msgDeniedPassword = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "root@192.168.1.100: Permission denied (password)."
        )
        XCTAssertTrue(msgDeniedPassword.contains("用户名或密码错误"), "Expected password error, got: \(msgDeniedPassword)")

        // Permission denied (publickey)
        let msgDeniedKey = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "debug1: Authentications that can continue: publickey\nPermission denied (publickey)."
        )
        XCTAssertTrue(msgDeniedKey.contains("用户名、私钥或证书不匹配"), "Expected key mismatch, got: \(msgDeniedKey)")

        // General permission denied
        let msgDeniedGeneral = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "Permission denied."
        )
        XCTAssertTrue(msgDeniedGeneral.contains("认证失败"), "Expected general auth failure, got: \(msgDeniedGeneral)")
    }

    // MARK: - TC-TEST-03: SSH error message parsing for network, timeout and DNS failures
    func testTC_TEST_03_NetworkAndResolutionErrorParsing() {
        // Connection refused
        let msgRefused = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "ssh: connect to host 127.0.0.1 port 2222: Connection refused"
        )
        XCTAssertTrue(msgRefused.contains("连接被拒绝"), "Expected connection refused, got: \(msgRefused)")

        // Connection timed out
        let msgTimeout = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "ssh: connect to host 10.255.255.1 port 22: Operation timed out"
        )
        XCTAssertTrue(msgTimeout.contains("连接超时"), "Expected timeout message, got: \(msgTimeout)")

        // DNS name resolution failure
        let msgDns = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "ssh: Could not resolve hostname invalid.domain.example: nodename nor servname provided, or not known"
        )
        XCTAssertTrue(msgDns.contains("域名解析失败") || msgDns.contains("无法解析主机名"), "Expected DNS resolution failure, got: \(msgDns)")

        // No route to host
        let msgNoRoute = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "ssh: connect to host 192.0.2.1 port 22: No route to host"
        )
        XCTAssertTrue(msgNoRoute.contains("网络不可达"), "Expected no route to host, got: \(msgNoRoute)")
    }

    // MARK: - TC-TEST-04: SSH error message parsing for passphrase & missing files
    func testTC_TEST_04_PassphraseAndMissingFileErrorParsing() {
        // Bad passphrase
        let msgPassphrase = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "Enter passphrase for key '/Users/user/.ssh/id_rsa': Bad passphrase"
        )
        XCTAssertTrue(msgPassphrase.contains("私钥口令 (Passphrase) 错误"), "Expected passphrase error, got: \(msgPassphrase)")

        // Missing file
        let msgMissing = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "Warning: Identity file /Users/user/.ssh/nonexistent not accessible: No such file or directory."
        )
        XCTAssertTrue(msgMissing.contains("指定的私钥或证书文件不存在"), "Expected missing file error, got: \(msgMissing)")

        // Host key verification failure
        let msgHostKey = NativeSSHSession.parseSSHErrorMessage(
            exitCode: 255,
            stderr: "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\nHost key verification failed."
        )
        XCTAssertTrue(msgHostKey.contains("主机密钥校验冲突"), "Expected host key verification failure, got: \(msgHostKey)")
    }

    // MARK: - TC-TEST-05: MockSSHSession testConnection protocol implementation
    func testTC_TEST_05_MockSSHSessionTestConnection() async {
        let session = Session(name: "Mock Host", host: "192.0.2.1", username: "root")
        let mock = MockSSHSession(session: session)
        
        // Default mock implementation returns success
        let defaultResult = await mock.testConnection()
        XCTAssertTrue(defaultResult.isSuccess)
        XCTAssertGreaterThan(defaultResult.latencyMs, 0)
        XCTAssertEqual(defaultResult.serverInfo, "Linux 6.8.0-45 x86_64")
        XCTAssertNil(defaultResult.errorMessage)

        // Custom test handler can simulate authentication failure
        mock.customTestConnectionHandler = {
            return SSHTestConnectionResult(isSuccess: false, latencyMs: 12, errorMessage: "模拟密码错误")
        }
        let customResult = await mock.testConnection()
        XCTAssertFalse(customResult.isSuccess)
        XCTAssertEqual(customResult.errorMessage, "模拟密码错误")
    }

    // MARK: - TC-TEST-06: LocalTerminalSession testConnection protocol implementation
    func testTC_TEST_06_LocalTerminalSessionTestConnection() async {
        let local = LocalTerminalSession()
        let result = await local.testConnection()
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.serverInfo, "Darwin local shell")
        XCTAssertNil(result.errorMessage)
    }

    // MARK: - TC-TEST-07: NativeSSHSession handles missing key and certificate paths safely
    func testTC_TEST_07_NativeSSHSessionMissingKeyPath() async {
        let nonexistentPath = "/tmp/apexterm_test_nonexistent_key_\(UUID().uuidString).pem"
        let session = Session(
            id: UUID(),
            name: "Test Session",
            host: "127.0.0.1",
            port: 22,
            username: "root",
            authMethod: .privateKey(keychainRef: nonexistentPath, passphraseRef: nil)
        )
        
        let client = NativeSSHSession(session: session)
        let result = await client.testConnection(timeoutSeconds: 1)
        
        XCTAssertFalse(result.isSuccess)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertTrue(
            result.errorMessage?.contains("私钥文件不存在") == true ||
            result.errorMessage?.contains("不存在") == true,
            "Expected missing key error, got: \(result.errorMessage ?? "")"
        )
    }

    // MARK: - TC-TEST-08: NativeSSHSession connection test to closed local port
    func testTC_TEST_08_NativeSSHSessionClosedPortConnectionTest() async {
        // Connect to a loopback port that is guaranteed not open (e.g. 59999)
        let session = Session(
            id: UUID(),
            name: "Closed Port Test",
            host: "127.0.0.1",
            port: 59999,
            username: "root",
            authMethod: .password(keychainRef: "dummy")
        )
        
        let result = await NativeSSHSession.testConnection(
            session: session,
            explicitPassword: "anyPassword",
            timeoutSeconds: 2
        )
        
        XCTAssertFalse(result.isSuccess)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertTrue(
            result.errorMessage?.contains("连接被拒绝") == true ||
            result.errorMessage?.contains("超时") == true ||
            result.errorMessage?.contains("Connection refused") == true,
            "Expected connection refused or timeout diagnostic, got: \(result.errorMessage ?? "")"
        )
    }
}
