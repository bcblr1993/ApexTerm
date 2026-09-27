import XCTest

/// Drives an isolated QA host linked to the same product modules as the release.
@MainActor
final class ApexTermUITests: XCTestCase {
    private var app: XCUIApplication!

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws { app?.terminate() }

    private func launch(_ scene: String = "main", extra: [String: String] = [:]) {
        app = XCUIApplication(bundleIdentifier: "com.apexterm.qa.verification")
        app.launchEnvironment = ["APEX_QA_SCENE": scene, "APEX_QA_DISABLE_TELEMETRY": "1"]
            .merging(extra) { _, new in new }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSearchEmptyAndRecovery() {
        launch()
        let search = app.textFields.matching(NSPredicate(format: "label CONTAINS %@", "搜索会话")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("UI_NO_MATCH_5f0d60a")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "未找到匹配会话")).firstMatch.waitForExistence(timeout: 5))
        capture("search-empty")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 台主机")).firstMatch.waitForExistence(timeout: 5))
        capture("search-restored")
    }

    func testSessionEmptyInvalidPortAndCancel() {
        launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "添加新的 SSH 会话")).firstMatch.click()
        let save = app.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        app.textFields["会话名称"].click()
        app.textFields["会话名称"].typeText("UI synthetic")
        app.textFields["主机地址 / IP"].click()
        app.textFields["主机地址 / IP"].typeText("example.com")
        let port = app.textFields["SSH 端口"]
        port.click()
        port.typeKey("a", modifierFlags: .command)
        port.typeText("70000")
        XCTAssertFalse(save.isEnabled)
        capture("session-invalid-port")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testUpdateFailureCloseAndReopen() {
        launch("update", extra: ["APEX_QA_UPDATE_STATE": "failed"])
        XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["关闭"].isHittable)
        capture("update-failed")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(app.sheets.firstMatch.exists)
        app.buttons["显示更新弹窗"].click()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        app.buttons["关闭"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testUpdateLoadingAndSuccess() {
        launch("update", extra: ["APEX_QA_UPDATE_STATE": "checking"])
        XCTAssertTrue(app.progressIndicators.firstMatch.waitForExistence(timeout: 5))
        capture("update-loading")
        app.terminate()
        launch("update")
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testSFTPEmptyLoadingAndFailureStates() {
        for mode in ["empty", "loading", "failure"] {
            launch("main", extra: ["APEX_QA_FILES": mode, "APEX_QA_CONNECT": "1"])
            switch mode {
            case "empty":
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "文件夹为空")).firstMatch.waitForExistence(timeout: 10))
            case "loading":
                XCTAssertTrue(app.progressIndicators.firstMatch.waitForExistence(timeout: 5))
            default:
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "无法读取目录")).firstMatch.waitForExistence(timeout: 10))
            }
            capture("sftp-\(mode)")
            app.terminate()
        }
    }

    func testRealSSHConfiguredHostIsMandatory() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["APEX_UI_TEST_HOST"], !host.isEmpty,
              let user = environment["APEX_UI_TEST_USER"], !user.isEmpty else {
            XCTFail("Release UI acceptance requires APEX_UI_TEST_HOST and APEX_UI_TEST_USER; no skipped real-host acceptance")
            return
        }
        launch("main", extra: ["APEX_QA_REAL_HOST": host, "APEX_QA_REAL_USER": user, "APEX_QA_CONNECT": "1"])
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.click()
        terminal.typeText("printf '\\nAPEX_UI_REAL_PTY_OK\\n'\n")
        let output = NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_REAL_PTY_OK\n")
        let echo = XCTNSPredicateExpectation(predicate: output, object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [echo], timeout: 15), .completed)
        capture("real-ssh-pty")
    }

    func testAllThemesAndPagesRender() {
        launch()
        let themes = ["经典白色（默认）", "VS Code Dark Modern", "Tokyo Night", "Catppuccin Mocha", "Catppuccin Latte", "Nord", "Dracula", "One Dark Pro", "Gruvbox Dark", "Everforest", "Rosé Pine", "Solarized Light"]
        let pages = ["main", "editor", "settings", "session", "about", "shortcuts", "transfers", "metrics", "import"]
        for theme in themes {
            app.menuBars.menuBarItems["验收主题"].click()
            let item = app.menuItems[theme]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Missing theme: \(theme)")
            item.click()
            for page in pages {
                app.menuBars.menuBarItems["验收页面"].click()
                app.menuItems[page].click()
                XCTAssertTrue(app.windows.firstMatch.exists)
                XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 300)
                capture("\(theme)-\(page)")
            }
        }
    }
}
