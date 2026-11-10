import XCTest
@testable import ApexCore

final class SessionCopyHelperTests: XCTestCase {
    
    // MARK: - Format Username and Password
    
    func testFormatUserAndPasswordWithPassword() {
        let result = SessionCopyHelper.formatUserAndPassword(username: "root", password: "Password123!")
        XCTAssertEqual(result, "用户名: root 密码: Password123!")
        XCTAssertFalse(result.contains("\n"))
    }
    
    func testFormatUserAndPasswordWithoutPassword() {
        let result = SessionCopyHelper.formatUserAndPassword(username: "ubuntu", password: nil)
        XCTAssertEqual(result, "用户名: ubuntu 密码: (未配置)")
        XCTAssertFalse(result.contains("\n"))
    }
    
    func testFormatUserAndPasswordWithEmptyPassword() {
        let result = SessionCopyHelper.formatUserAndPassword(username: "deploy", password: "")
        XCTAssertEqual(result, "用户名: deploy 密码: (未配置)")
        XCTAssertFalse(result.contains("\n"))
    }
    
    func testFormatUserAndPasswordWithWhitespaceUsername() {
        let result = SessionCopyHelper.formatUserAndPassword(username: "  admin  ", password: "pwd")
        XCTAssertEqual(result, "用户名: admin 密码: pwd")
        XCTAssertFalse(result.contains("\n"))
    }
    
    // MARK: - Format Session Info
    
    func testFormatSessionInfoWithSameNameAndHost() {
        let session = Session(
            name: "10.8.8.71",
            host: "10.8.8.71",
            port: 22,
            username: "root"
        )
        let result = SessionCopyHelper.formatSessionInfo(session: session, password: "SecretPassword")
        let expected = "主机: 10.8.8.71 端口: 22 用户名: root 密码: SecretPassword"
        XCTAssertEqual(result, expected)
        XCTAssertFalse(result.contains("\n"))
    }
    
    func testFormatSessionInfoWithCustomNameAndNonStandardPort() {
        let session = Session(
            name: "微服务测试机器-10.8.8.246",
            host: "10.8.8.246",
            port: 22022,
            username: "admin"
        )
        let result = SessionCopyHelper.formatSessionInfo(session: session, password: "MyComplex#Pass99")
        let expected = "会话: 微服务测试机器-10.8.8.246 主机: 10.8.8.246 端口: 22022 用户名: admin 密码: MyComplex#Pass99"
        XCTAssertEqual(result, expected)
        XCTAssertFalse(result.contains("\n"))
    }
    
    func testFormatSessionInfoWithoutPassword() {
        let session = Session(
            name: "bastion",
            host: "10.0.0.1",
            port: 22,
            username: "ops"
        )
        let result = SessionCopyHelper.formatSessionInfo(session: session, password: nil)
        let expected = "会话: bastion 主机: 10.0.0.1 端口: 22 用户名: ops 密码: (未配置)"
        XCTAssertEqual(result, expected)
        XCTAssertFalse(result.contains("\n"))
    }
    
    // MARK: - Resolve Secret
    
    func testResolveSecretManagedKeychainRef() async {
        let session = Session(
            name: "test",
            host: "1.1.1.1",
            username: "root",
            authMethod: .password(keychainRef: "ssh_12345678-1234-1234-1234-123456789abc")
        )
        let secret = await SessionCopyHelper.resolveSecret(for: session, lookup: { ref in
            XCTAssertEqual(ref, "ssh_12345678-1234-1234-1234-123456789abc")
            return "ResolvedKeychainPassword"
        })
        XCTAssertEqual(secret, "ResolvedKeychainPassword")
    }
    
    func testResolveSecretLegacyInlinePassword() async {
        let session = Session(
            name: "legacy",
            host: "2.2.2.2",
            username: "root",
            authMethod: .password(keychainRef: "rawInlinePasswordText")
        )
        let secret = await SessionCopyHelper.resolveSecret(for: session, lookup: { _ in nil })
        XCTAssertEqual(secret, "rawInlinePasswordText")
    }
    
    func testResolveSecretPrivateKeyPassphrase() async {
        let session = Session(
            name: "key-auth",
            host: "3.3.3.3",
            username: "git",
            authMethod: .privateKey(keychainRef: "/path/to/key", passphraseRef: "passphrase_abcd")
        )
        let secret = await SessionCopyHelper.resolveSecret(for: session, lookup: { ref in
            return ref == "passphrase_abcd" ? "SecretPassphrase" : nil
        })
        XCTAssertEqual(secret, "SecretPassphrase")
    }
    
    func testResolveSecretAgentAuthReturnsNil() async {
        let session = Session(
            name: "agent-session",
            host: "4.4.4.4",
            username: "dev",
            authMethod: .agent
        )
        let secret = await SessionCopyHelper.resolveSecret(for: session, lookup: { _ in "notCalled" })
        XCTAssertNil(secret)
    }
    
    // MARK: - L10n Verification
    
    func testLocalizationStrings() {
        XCTAssertEqual(L10n.copyUsernameAction, "复制用户名")
        XCTAssertEqual(L10n.copyPasswordAction, "复制密码")
        XCTAssertEqual(L10n.copyUsernameAndPasswordAction, "复制用户名密码")
        XCTAssertEqual(L10n.copySessionInfoAction, "复制会话信息")
        
        XCTAssertEqual(L10n.copiedUsernameToast, "已复制用户名")
        XCTAssertEqual(L10n.copiedPasswordToast, "已复制密码")
        XCTAssertEqual(L10n.copiedUsernameAndPasswordToast, "已复制用户名和密码")
        XCTAssertEqual(L10n.copiedSessionInfoToast, "已复制会话信息")
        XCTAssertEqual(L10n.noPasswordConfiguredToast, "未配置密码或口令")
        XCTAssertEqual(L10n.emptyUsernameToast, "用户名为空")
    }
}
