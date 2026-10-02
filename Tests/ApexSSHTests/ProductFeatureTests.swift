import XCTest
@testable import ApexCore
import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

@MainActor
final class ProductFeatureTests: XCTestCase {

    func testAppStoreNewAndEditedSessionsAllowUserSelectedPrivateKey() {
        let methods: [SSHAuthMethod?] = [nil, .agent, .password(keychainRef: "synthetic-password"),
                                       .privateKey(keychainRef: "/synthetic/key", passphraseRef: nil)]
        for method in methods {
            XCTAssertEqual(SessionEditModal.AuthType.availableTypes(for: method, channel: .appStore),
                           [.password, .agent, .privateKey])
        }
        for method in methods.dropLast() {
            XCTAssertEqual(SessionEditModal.AuthType.availableTypes(for: method, channel: .direct),
                           [.password, .agent])
        }
        XCTAssertEqual(SessionEditModal.AuthType.availableTypes(for: methods.last!, channel: .direct),
                       [.password, .agent, .privateKey])
    }
    
    func testEditingPrivateKeyAuthenticationRetainsBothReferences() {
        for passphrase in [nil, "synthetic-passphrase-reference"] as [String?] {
            let original = SSHAuthMethod.privateKey(keychainRef: "synthetic-key-reference", passphraseRef: passphrase)
            XCTAssertEqual(SessionEditModal.AuthType.privateKey.retainedPrivateKey(from: original), original)
            XCTAssertNil(SessionEditModal.AuthType.agent.retainedPrivateKey(from: original))
            XCTAssertNil(SessionEditModal.AuthType.password.retainedPrivateKey(from: original))
        }
        XCTAssertNil(SessionEditModal.AuthType.privateKey.retainedPrivateKey(from: nil))
        XCTAssertNil(SessionEditModal.AuthType.privateKey.retainedPrivateKey(from: .agent))
    }

    // MARK: - AppSettings Tests
    
    func testAppSettingsDefaultsAndMutations() {
        let settings = AppSettings.shared
        settings.resetToDefaults()
        
        XCTAssertEqual(settings.fontName, "SF Mono")
        XCTAssertEqual(settings.fontSize, 13.0)
        XCTAssertEqual(settings.cursorShape, .bar)
        XCTAssertTrue(settings.isCursorBlinkEnabled)
        XCTAssertEqual(settings.themePreset, .nativeLight)
        XCTAssertTrue(settings.isCopyOnSelectEnabled)
        XCTAssertTrue(settings.isRightClickPasteEnabled)
        XCTAssertTrue(settings.showHiddenFiles)
        XCTAssertTrue(settings.sftpAutoSyncEnabled)
        XCTAssertTrue(settings.checkForUpdatesOnLaunch)
        
        // Mutate properties
        final class FlagBox: @unchecked Sendable { var value = false }
        let flag = FlagBox()
        let token = NotificationCenter.default.addObserver(
            forName: AppSettings.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            flag.value = true
        }
        
        settings.fontSize = 16.0
        XCTAssertTrue(flag.value)
        XCTAssertEqual(settings.fontSize, 16.0)
        
        settings.cursorShape = .block
        XCTAssertEqual(settings.cursorShape, .block)
        
        settings.themePreset = .oledBlack
        XCTAssertEqual(settings.themePreset, .oledBlack)
        XCTAssertEqual(settings.themePreset.backgroundColorHex, "#000000")
        
        NotificationCenter.default.removeObserver(token)
        
        // Reset back
        settings.resetToDefaults()
        XCTAssertEqual(settings.fontSize, 13.0)
        XCTAssertEqual(settings.cursorShape, .bar)
    }
    
    func testFollowingSystemAppearancePreservesTerminalPalette() {
        let settings = AppSettings.shared
        settings.resetToDefaults()
        defer { settings.resetToDefaults() }
        settings.themePreset = .oledBlack
        settings.followsSystemAppearance = true
        XCTAssertEqual(settings.themePreset, .oledBlack)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "settings.appearance.followSystem"))
        settings.followsSystemAppearance = false
        XCTAssertEqual(settings.themePreset, .oledBlack)
        settings.resetToDefaults()
        XCTAssertFalse(settings.followsSystemAppearance)
    }

    func testRestoringDirectoryDoesNotReconnectSession() {
        let session = Session(name: "恢复测试", host: "192.0.2.10", username: "demo")
        let key = "workspace.remotePath.\(session.id.uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let original = TerminalTabItem(session: session, sshClient: MockSSHSession(session: session))
        original.currentRemotePath = "/var/log"
        let client = MockSSHSession(session: session)
        let restored = TerminalTabItem(session: session, sshClient: client)
        XCTAssertEqual(restored.currentRemotePath, "/var/log")
        XCTAssertEqual(client.connectionState, .disconnected)
    }

    func testClosingTabReleasesPaneAndStateCallbacks() {
        let session = Session(name: "生命周期测试", host: "192.0.2.10", username: "demo")
        let client = MockSSHSession(session: session)
        var tab: TerminalTabItem? = TerminalTabItem(session: session, sshClient: client)
        let weakTab = { [weak tab] in tab }
        let weakPane = { [weak pane = tab?.panes.first] in pane }
        tab = nil
        XCTAssertNil(weakTab())
        XCTAssertNil(weakPane())
    }

    // MARK: - UpdateManager Semantic Version Tests
    
    func testSemanticVersionComparison() {
        // Newer patch
        XCTAssertTrue(UpdateManager.isVersion("1.2.1", higherThan: "1.2.0"))
        // Newer minor
        XCTAssertTrue(UpdateManager.isVersion("1.3.0", higherThan: "1.2.9"))
        // Newer major
        XCTAssertTrue(UpdateManager.isVersion("2.0.0", higherThan: "1.9.9"))
        // Multi-digit components
        XCTAssertTrue(UpdateManager.isVersion("1.10.0", higherThan: "1.9.5"))
        // With 'v' prefix
        XCTAssertTrue(UpdateManager.isVersion("v1.2.1", higherThan: "v1.2.0"))
        XCTAssertTrue(UpdateManager.isVersion("v2.0.0", higherThan: "1.9.9"))
        
        // Equal versions
        XCTAssertFalse(UpdateManager.isVersion("1.2.0", higherThan: "1.2.0"))
        XCTAssertFalse(UpdateManager.isVersion("v1.2.0", higherThan: "1.2.0"))
        
        // Older versions
        XCTAssertFalse(UpdateManager.isVersion("1.1.9", higherThan: "1.2.0"))
        XCTAssertFalse(UpdateManager.isVersion("0.9.0", higherThan: "1.0.0"))
    }
    
    // MARK: - SessionStore Export & Import Tests
    
    func testSessionStoreExportAndImport() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = SessionStore(baseDirectory: tempDir)
        
        // Add sample session
        let sample = Session(
            name: "Test Node 1",
            host: "192.168.1.100",
            port: 22,
            username: "admin",
            folder: "TestFolder",
            tags: ["prod", "db"]
        )
        store.addSession(sample)
        
        // Export to JSON
        let data = try store.exportSessionsJSON()
        XCTAssertFalse(data.isEmpty)
        
        // Verify JSON string format
        let jsonStr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonStr.contains("Test Node 1"))
        XCTAssertTrue(jsonStr.contains("192.168.1.100"))
        
        // Import into new empty store
        let secondTempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secondStore = SessionStore(baseDirectory: secondTempDir)
        XCTAssertEqual(secondStore.sessions.count, 0)
        
        let count = try secondStore.importSessionsJSON(from: data, overwrite: false)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(secondStore.sessions.count, 1)
        XCTAssertEqual(secondStore.sessions.first?.name, "Test Node 1")
        XCTAssertEqual(secondStore.sessions.first?.host, "192.168.1.100")
        
        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: secondTempDir)
    }
    
    // MARK: - Update String Formatting Regression Tests
    
    func testUpdateStringFormattingDoesNotCrash() {
        let version = "1.2.0"
        let formatted = String(format: L10n.upToDateDesc, version as CVarArg)
        XCTAssertTrue(formatted.contains("1.2.0"))
        XCTAssertTrue(formatted.contains("最新稳定版本"))
    }
}
