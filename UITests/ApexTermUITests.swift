import XCTest
import AppKit
import Carbon
import CryptoKit

/// Drives an isolated QA host linked to the same product modules as the release.
@MainActor
final class ApexTermUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ownedRemoteDirectory: String?
    private var inputSourceToRestore: IMEInputSourceSelection?
    private var imeTraceFiles: [URL] = []

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        // Cleanup must finish even when an earlier cleanup assertion fails.
        continueAfterFailure = true
        if (testRun?.failureCount ?? 0) > 0, let app, app.state == .runningForeground {
            capture("failure-" + name)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "failure-accessibility-tree"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        do { try cleanupFinderDrag() }
        catch { XCTFail("Owned drag fixture cleanup failed: \(error)") }
        if let app, app.state != .notRunning,
           app.launchEnvironment["APEX_QA_REAL_HOST"] != nil {
            app.activate()
            if app.sheets.firstMatch.exists {
                let close = app.windows.buttons["收起传输任务"].firstMatch
                if close.exists { clickVisibleCenter(close) }
            }
            if !app.sheets.firstMatch.exists {
                // The system Pinyin candidate menu can leave XCTest's menu item
                // geometry unavailable. Invoke the same QA menu action by its shortcut.
                focusOwnedWindow()
                app.typeKey("x", modifierFlags: [.command, .option, .shift])
                XCTAssertTrue(staticText("会话已断开").waitForExistence(timeout: 10),
                              "Disconnect the real PTY before XCTest terminates its host")
            } else {
                XCTFail("Cannot disconnect the real PTY behind an unexpected modal sheet")
            }
        }
        app?.terminate()
        for file in imeTraceFiles {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                let attachment = XCTAttachment(string: text)
                attachment.name = file.pathExtension == "json" ? "real-system-pinyin-final-context" : "real-system-pinyin-key-events"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            try? FileManager.default.removeItem(at: file)
        }
        imeTraceFiles.removeAll()
        if let inputSourceToRestore {
            do {
                try inputSourceToRestore.restore()
                let evidence = XCTAttachment(string: inputSourceToRestore.restorationEvidence)
                evidence.name = "restored-system-input-source-configuration"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
            catch { XCTFail("Failed to restore input sources: \(error)") }
            self.inputSourceToRestore = nil
        }
        if let directory = ownedRemoteDirectory {
            let environment = ProcessInfo.processInfo.environment
            let host = try XCTUnwrap(environment["APEX_UI_TEST_HOST"])
            let user = try XCTUnwrap(environment["APEX_UI_TEST_USER"])
            XCTAssertNotNil(directory.range(of: "^/tmp/apex-ui-[A-Za-z0-9]+$", options: .regularExpression))
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            cleanup.environment = ProcessInfo.processInfo.environment
            let agentSocket = try XCTUnwrap(ProcessInfo.processInfo.environment["APEX_UI_AGENT_SOCKET"] ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"])
            cleanup.arguments = ["-F", "/dev/null", "-o", "IdentitiesOnly=no", "-o", "IdentityAgent=\(agentSocket)", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "\(user)@\(host)",
                                 "/bin/rm -f '\(directory)/ui-real-file.txt' && /bin/rmdir '\(directory)'"]
            let output = Pipe()
            cleanup.standardOutput = output
            cleanup.standardError = output
            try cleanup.run()
            cleanup.waitUntilExit()
            let record = XCTAttachment(string: "Owned fixture cleanup exit code: \(cleanup.terminationStatus)\n" + String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            record.name = "real-host-failure-cleanup"
            record.lifetime = .keepAlways
            add(record)
            XCTAssertEqual(cleanup.terminationStatus, 0, "Failed to remove this test's exact owned fixture")
        }
    }

    private func launch(_ scene: String = "main", extra: [String: String] = [:]) {
        if let path = ProcessInfo.processInfo.environment["APEX_UI_APP_PATH"] {
            app = XCUIApplication(url: URL(fileURLWithPath: path))
        } else {
            app = XCUIApplication(bundleIdentifier: "com.apexterm.qa.verification")
        }
        app.launchEnvironment = ["APEX_QA_SCENE": scene, "APEX_QA_DISABLE_TELEMETRY": "1", "APEX_QA_RAISE_WINDOW": "1", "APEX_QA_UI_RUN_ID": UUID().uuidString]
            .merging(extra) { _, new in new }
        if let socket = ProcessInfo.processInfo.environment["APEX_UI_AGENT_SOCKET"] ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            app.launchEnvironment["SSH_AUTH_SOCK"] = socket
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        focusOwnedWindow()
    }

    func testProductReopensMainWindowAfterLastWindowCloses() throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["APEX_UI_PRODUCT_APP_PATH"])
        app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launchEnvironment = ["APEX_UI_TEST_REOPEN": "1"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        focusOwnedWindow()
        app.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.windows.count == 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reopen.arguments = ["-a", path]
        try reopen.run()
        reopen.waitUntilExit()
        XCTAssertEqual(reopen.terminationStatus, 0)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "Clicking the running app must restore its main window")
    }

    // AppKit exposes ordinary macOS text through AXValue, while custom labels use AXLabel.
    private func staticText(_ text: String, comparison: String = "==") -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label \(comparison) %@ OR value \(comparison) %@", text, text)).firstMatch
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func clickVisibleCenter(_ item: XCUIElement) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let rect = item.frame
            return item.exists && rect.origin.x.isFinite && rect.origin.y.isFinite
                && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
        }, object: item)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed,
                       "Control must have a visible, finite screen rectangle")
        // XCTest's menu click hover path can resolve an infinite point on macOS 27.
        // Click the actual visible center without invoking that hover path.
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func focusOwnedWindow() {
        app.activate()
        // A click inside our own window dismisses another app's transient status popover.
        // Use the sheet when present so we never click behind an attached modal sheet.
        let window = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let rect = window.frame
        XCTAssertTrue(rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width > 0 && rect.height > 0)
        // The fixed blank chrome point lies after traffic lights and before settings tabs.
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 82, dy: 8)).click()
    }

    private func activateSettingsWindow() {
        // Application AXEnabled is not a reliable proxy for whether its tabs accept input.
        // Each tab's actual selected state is asserted after the real mouse click.
        focusOwnedWindow()
    }

    func testSearchEmptyAndRecovery() {
        launch()
        let search = app.textFields.matching(NSPredicate(format: "label CONTAINS %@", "搜索会话")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("UI_NO_MATCH_5f0d60a")
        XCTAssertTrue(staticText("未找到匹配会话", comparison: "CONTAINS").waitForExistence(timeout: 5))
        capture("search-empty")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        XCTAssertTrue(staticText("1 台主机", comparison: "CONTAINS").waitForExistence(timeout: 5))
        capture("search-restored")
    }

    func testSessionEmptyInvalidPortAndCancel() {
        launch()
        app.windows.buttons.matching(NSPredicate(format: "label CONTAINS %@", "添加新的 SSH 会话")).firstMatch.click()
        let save = app.windows.buttons["保存"].firstMatch
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
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(staticText("1 台主机", comparison: "CONTAINS").exists)
    }

    func testSessionValidPortRecoveryAndSave() {
        launch()
        app.windows.buttons.matching(NSPredicate(format: "label CONTAINS %@", "添加新的 SSH 会话")).firstMatch.click()
        let name = app.textFields["会话名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("UI saved synthetic")
        let host = app.textFields["主机地址 / IP"]
        host.click()
        host.typeText("example.com")
        let port = app.textFields["SSH 端口"]
        port.click()
        port.typeKey("a", modifierFlags: .command)
        port.typeText("65536")
        let save = app.windows.buttons["保存"].firstMatch
        XCTAssertFalse(save.isEnabled)
        port.typeKey("a", modifierFlags: .command)
        port.typeText("2222")
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(staticText("2 台主机", comparison: "CONTAINS").waitForExistence(timeout: 5))
        let search = app.textFields.matching(NSPredicate(format: "label CONTAINS %@", "搜索会话")).firstMatch
        search.click()
        search.typeText("UI saved synthetic")
        XCTAssertTrue(staticText("UI saved synthetic", comparison: "==").waitForExistence(timeout: 5))
        capture("session-saved-and-searchable")
    }

    func testUpdateFailureCloseAndReopen() {
        launch("update", extra: ["APEX_QA_UPDATE_STATE": "failed"])
        XCTAssertTrue(app.windows.buttons["重试"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.buttons["关闭"].firstMatch.isHittable)
        capture("update-failed")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        app.windows.buttons["显示更新弹窗"].firstMatch.click()
        XCTAssertTrue(app.windows.buttons["关闭"].firstMatch.waitForExistence(timeout: 5))
        app.windows.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testUpdateLoadingAndSuccess() {
        launch("update", extra: ["APEX_QA_UPDATE_STATE": "checking"])
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 5))
        capture("update-loading")
        app.terminate()
        launch("update")
        XCTAssertTrue(app.windows.buttons["完成"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testUpdateAvailableVersionNotesAndEscape() {
        launch("update", extra: ["APEX_QA_UPDATE_STATE": "available"])
        XCTAssertTrue(staticText("发现新版本可用").waitForExistence(timeout: 5))
        XCTAssertTrue(staticText("新版本: v9.9.9", comparison: "CONTAINS").exists)
        XCTAssertTrue(staticText("UI验收更新说明", comparison: "CONTAINS").exists)
        XCTAssertTrue(app.windows.buttons["立即更新"].firstMatch.isHittable)
        XCTAssertTrue(app.windows.buttons["稍后提醒"].firstMatch.isHittable)
        capture("update-available-version-notes")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows.buttons["显示更新弹窗"].firstMatch.isHittable)
    }

    func testSFTPEmptyLoadingAndFailureStates() {
        for mode in ["empty", "loading", "failure"] {
            launch("main", extra: ["APEX_QA_FILES": mode, "APEX_QA_CONNECT": "1"])
            switch mode {
            case "empty":
                XCTAssertTrue(staticText("文件夹为空", comparison: "CONTAINS").waitForExistence(timeout: 10))
            case "loading":
                XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 5))
            default:
                XCTAssertTrue(staticText("无法读取远程文件", comparison: "CONTAINS").waitForExistence(timeout: 10))
            }
            capture("sftp-\(mode)")
            app.terminate()
        }
    }

    func testSFTPFilterEmptyClearAndEscape() {
        launch("main", extra: ["APEX_QA_FILES": "normal", "APEX_QA_CONNECT": "1"])
        let file = staticText("nginx.conf")
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        let toggle = app.checkBoxes["筛选文件"].firstMatch
        XCTAssertTrue(toggle.isHittable)
        toggle.click()
        let filter = app.textFields["筛选当前目录文件..."]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeText("UI_NO_MATCH_FILE")
        XCTAssertTrue(staticText("没有匹配的文件").waitForExistence(timeout: 5))
        XCTAssertFalse(file.exists)
        capture("sftp-filter-no-match")
        app.windows.buttons["清除文件筛选"].firstMatch.click()
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertEqual(filter.value as? String, "")
        filter.click()
        filter.typeText("nginx")
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertFalse(staticText("docker-compose.yml").exists)
        filter.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(filter.exists)
        XCTAssertTrue(staticText("docker-compose.yml").waitForExistence(timeout: 5))
        capture("sftp-filter-escape-restored")
    }

    func testSFTPDirectoryFailureRetryRecovers() {
        launch("main", extra: ["APEX_QA_FILES": "failure-once", "APEX_QA_CONNECT": "1"])
        let failure = staticText("无法读取远程文件")
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        let retry = app.windows.buttons["重试"].firstMatch
        XCTAssertTrue(retry.isHittable)
        XCTAssertFalse(staticText("nginx.conf").exists)
        capture("sftp-before-retry")
        retry.click()
        XCTAssertTrue(staticText("nginx.conf").waitForExistence(timeout: 10))
        XCTAssertFalse(failure.exists)
        XCTAssertFalse(retry.exists)
        capture("sftp-retry-restored")
    }

    func testSFTPPathDraftCancelEmptyAndSubmit() {
        launch("main", extra: ["APEX_QA_FILES": "normal", "APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("nginx.conf").waitForExistence(timeout: 10))
        let path = app.textFields["远程路径"]
        XCTAssertTrue(path.exists)
        let original = path.value as? String
        XCTAssertNotNil(original)
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText("/ui-unsubmitted-draft")
        let copyPath = app.buttons["复制当前路径"].firstMatch
        XCTAssertTrue(copyPath.isHittable)
        copyPath.click()
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(path.value as? String, original, "Copy the current directory, not an unsubmitted draft")
        path.typeKey("a", modifierFlags: .command)
        path.typeText("/ui-unsubmitted-draft")
        path.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(path.value as? String, original)
        XCTAssertTrue(staticText("nginx.conf").exists)
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText("   ")
        path.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertEqual(path.value as? String, original)
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText(" /ui-synthetic-directory ")
        path.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let submitted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "/ui-synthetic-directory"), object: path)
        XCTAssertEqual(XCTWaiter.wait(for: [submitted], timeout: 5), .completed, "Submitted path: \(path.value ?? "missing")")
        XCTAssertTrue(staticText("nginx.conf").waitForExistence(timeout: 10))
        capture("sftp-path-submitted")
    }

    func testTerminalSplitOrientationAndClose() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        // Keep our toolbar clear of unrelated, persistent menu-bar popovers.
        let chrome = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 82, dy: 8))
        chrome.click(forDuration: 0.5, thenDragTo: chrome.withOffset(CGVector(dx: -400, dy: 0)))
        let split = app.menuButtons["rectangle.split.2x1"].firstMatch
        XCTAssertTrue(split.isHittable)
        split.click()
        clickVisibleCenter(app.menuItems["垂直分屏"])
        let twoPanes = XCTNSPredicateExpectation(predicate: NSPredicate { [app] _, _ in
            app?.textViews.count == 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [twoPanes], timeout: 10), .completed)
        let left = app.textViews.element(boundBy: 0).frame
        let right = app.textViews.element(boundBy: 1).frame
        XCTAssertGreaterThan(abs(left.midX - right.midX), 100)
        XCTAssertLessThan(abs(left.midY - right.midY), 30)
        capture("terminal-split-vertical")
        split.click()
        clickVisibleCenter(app.menuItems["水平分屏"])
        let horizontalLayout = XCTNSPredicateExpectation(predicate: NSPredicate { [app] _, _ in
            guard let app, app.textViews.count == 2 else { return false }
            let first = app.textViews.element(boundBy: 0).frame
            let second = app.textViews.element(boundBy: 1).frame
            return abs(first.midY - second.midY) > 50 && abs(first.midX - second.midX) < 30
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [horizontalLayout], timeout: 5), .completed)
        let top = app.textViews.element(boundBy: 0).frame
        let bottom = app.textViews.element(boundBy: 1).frame
        XCTAssertGreaterThan(abs(top.midY - bottom.midY), 50)
        XCTAssertLessThan(abs(top.midX - bottom.midX), 30)
        capture("terminal-split-horizontal")
        app.windows.buttons["关闭此分屏"].firstMatch.click()
        let onePane = XCTNSPredicateExpectation(predicate: NSPredicate { [app] _, _ in
            app?.textViews.count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [onePane], timeout: 5), .completed)
        XCTAssertFalse(app.windows.buttons["关闭此分屏"].firstMatch.exists)
        capture("terminal-split-closed")
    }

    func testTerminalDisconnectedReconnectRestoresInput() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 10))
        clickVisibleCenter(app.menuBars.menuBarItems["验收操作"])
        clickVisibleCenter(app.menuItems["断开测试终端"])
        XCTAssertTrue(staticText("会话已断开").waitForExistence(timeout: 5))
        let reconnect = app.windows.buttons["重新连接 (⌘R)"].firstMatch
        XCTAssertTrue(reconnect.isHittable)
        capture("terminal-disconnected")
        reconnect.click()
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 10))
        XCTAssertFalse(staticText("会话已断开").exists)
        XCTAssertFalse(reconnect.exists)
        let terminal = app.textViews.firstMatch
        terminal.click()
        terminal.typeText("UI_RECONNECTED_INPUT")
        let input = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "UI_RECONNECTED_INPUT"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [input], timeout: 5), .completed)
        capture("terminal-reconnected-input")
    }

    func testSSHConfigImportSelectionAndDuplicateRecovery() {
        launch("import-sheet")
        let selected = app.windows.buttons["导入选中的 1 台主机"].firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertTrue(selected.isEnabled)
        app.windows.buttons["取消全选"].firstMatch.click()
        XCTAssertFalse(app.windows.buttons["导入选中的 0 台主机"].firstMatch.isEnabled)
        app.windows.buttons["全选"].firstMatch.click()
        XCTAssertTrue(selected.isEnabled)
        selected.click()
        let sheetClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.sheets.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [sheetClosed], timeout: 5), .completed)
        capture("ssh-config-import-success")
        clickVisibleCenter(app.menuBars.menuBarItems["验收页面"])
        clickVisibleCenter(app.menuItems["main"])
        let twoHosts = staticText("2 台主机", comparison: "CONTAINS")
        XCTAssertTrue(twoHosts.waitForExistence(timeout: 5))
        clickVisibleCenter(app.menuBars.menuBarItems["验收页面"])
        clickVisibleCenter(app.menuItems["import-sheet"])
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        selected.click()
        let secondSheetClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.sheets.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [secondSheetClosed], timeout: 5), .completed)
        clickVisibleCenter(app.menuBars.menuBarItems["验收页面"])
        clickVisibleCenter(app.menuItems["main"])
        XCTAssertTrue(twoHosts.waitForExistence(timeout: 5), "Reimport must update the existing session rather than duplicate it")
        let search = app.textFields.matching(NSPredicate(format: "label CONTAINS %@", "搜索会话")).firstMatch
        search.click()
        search.typeText("qa-demo")
        XCTAssertTrue(staticText("qa-demo").waitForExistence(timeout: 5))
        capture("ssh-config-import-deduplicated")
    }

    func testSSHConfigImportSheetCancelDoesNotImport() {
        launch("import-sheet")
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.buttons["导入选中的 1 台主机"].firstMatch.isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        app.windows.buttons["显示导入弹窗"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.windows.buttons["取消"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        clickVisibleCenter(app.menuBars.menuBarItems["验收页面"])
        clickVisibleCenter(app.menuItems["main"])
        XCTAssertTrue(staticText("1 台主机", comparison: "CONTAINS").waitForExistence(timeout: 5))
        let search = app.textFields.matching(NSPredicate(format: "label CONTAINS %@", "搜索会话")).firstMatch
        search.click()
        search.typeText("qa-demo")
        XCTAssertTrue(staticText("未找到匹配会话", comparison: "CONTAINS").waitForExistence(timeout: 5))
        capture("ssh-config-cancel-no-import")
    }

    func testSSHConfigEmptyImportDisabledAndCancel() {
        launch("import-sheet", extra: ["APEX_QA_IMPORT_CONFIG": "empty"])
        XCTAssertTrue(staticText("没有找到主机配置").waitForExistence(timeout: 5))
        let importButton = app.windows.buttons["导入选中的 0 台主机"].firstMatch
        XCTAssertTrue(importButton.exists)
        XCTAssertFalse(importButton.isEnabled)
        XCTAssertFalse(app.windows.buttons["全选"].firstMatch.exists)
        capture("ssh-config-empty-disabled")
        app.windows.buttons["取消"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows.buttons["显示导入弹窗"].firstMatch.isHittable)
    }

    func testSFTPCreationPermissionFailureShowsDetailsWithoutOpeningTransfers() {
        launch("main", extra: ["APEX_QA_FILES": "creation-permission-denied", "APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("nginx.conf").waitForExistence(timeout: 10))
        let more = app.menuButtons["ellipsis"].firstMatch
        more.click()
        clickVisibleCenter(app.menuItems["新建文件"])
        let name = app.textFields["文件名 (例如 test.sh)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-denied-file.sh")
        app.windows.buttons["创建"].firstMatch.click()
        let notice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "新建文件失败：当前用户没有目标文件或目录的写入权限")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertFalse(staticText("ui-denied-file.sh").exists)
        notice.click()
        XCTAssertTrue(staticText("创建失败").waitForExistence(timeout: 5))
        let details = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "Permission denied", "ui-denied-file.sh")).firstMatch
        XCTAssertTrue(details.exists)
        XCTAssertFalse(app.buttons["收起传输任务"].exists)
        capture("sftp-creation-permission-details")
        app.windows.buttons["好"].firstMatch.click()
        XCTAssertTrue(staticText("nginx.conf").exists)
        more.click()
        clickVisibleCenter(app.menuItems["新建文件夹"])
        let folderName = app.textFields["文件夹名称"]
        XCTAssertTrue(folderName.waitForExistence(timeout: 5))
        folderName.click()
        folderName.typeText("ui-denied-folder")
        app.windows.buttons["创建"].firstMatch.click()
        let folderNotice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "新建文件夹失败：当前用户没有目标文件或目录的写入权限")).firstMatch
        XCTAssertTrue(folderNotice.waitForExistence(timeout: 5))
        XCTAssertFalse(staticText("ui-denied-folder").exists)
        folderNotice.click()
        XCTAssertTrue(staticText("创建失败").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "Permission denied", "ui-denied-folder")).firstMatch.exists)
        XCTAssertFalse(app.buttons["收起传输任务"].exists)
        capture("sftp-folder-creation-permission-details")
        app.windows.buttons["好"].firstMatch.click()
    }

    func testSFTPCreateFileCancelAndSuccessfulListing() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("nginx.conf").waitForExistence(timeout: 10))
        let more = app.menuButtons["ellipsis"].firstMatch
        XCTAssertTrue(more.isHittable)
        more.click()
        clickVisibleCenter(app.menuItems["新建文件"])
        let name = app.textFields["文件名 (例如 test.sh)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-canceled-file.txt")
        app.windows.buttons["取消"].firstMatch.click()
        XCTAssertFalse(staticText("ui-canceled-file.txt").exists)
        more.click()
        clickVisibleCenter(app.menuItems["新建文件"])
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-created-file.txt")
        app.windows.buttons["创建"].firstMatch.click()
        XCTAssertTrue(staticText("ui-created-file.txt").waitForExistence(timeout: 10))
        XCTAssertFalse(staticText("ui-canceled-file.txt").exists)
        XCTAssertTrue(staticText("nginx.conf").exists)
        capture("sftp-create-file-listed")
    }

    func testSFTPRenameCancelAndSuccessfulListing() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        let original = staticText("nginx.conf")
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.click()
        original.rightClick()
        clickVisibleCenter(app.menuItems["重命名..."])
        let name = app.textFields["新名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("ui-canceled-name.conf")
        app.windows.buttons["取消"].firstMatch.click()
        XCTAssertTrue(original.exists)
        XCTAssertFalse(staticText("ui-canceled-name.conf").exists)
        original.click()
        original.rightClick()
        clickVisibleCenter(app.menuItems["重命名..."])
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("ui-renamed.conf")
        app.windows.buttons["确定"].firstMatch.click()
        XCTAssertTrue(staticText("ui-renamed.conf").waitForExistence(timeout: 10))
        XCTAssertFalse(original.exists)
        XCTAssertTrue(staticText("docker-compose.yml").exists)
        capture("sftp-renamed-file-listed")
    }

    func testSFTPCreateFolderCancelAndSuccessfulListing() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("nginx.conf").waitForExistence(timeout: 10))
        let more = app.menuButtons["ellipsis"].firstMatch
        more.click()
        clickVisibleCenter(app.menuItems["新建文件夹"])
        let name = app.textFields["文件夹名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-canceled-folder")
        app.windows.buttons["取消"].firstMatch.click()
        XCTAssertFalse(staticText("ui-canceled-folder").exists)
        more.click()
        clickVisibleCenter(app.menuItems["新建文件夹"])
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText(" ui-created-folder ")
        app.windows.buttons["创建"].firstMatch.click()
        let folder = staticText("ui-created-folder")
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        XCTAssertFalse(staticText("ui-canceled-folder").exists)
        XCTAssertTrue(staticText("nginx.conf").exists)
        capture("sftp-create-folder-listed")
        app.checkBoxes["筛选文件"].firstMatch.click()
        let filter = app.textFields["筛选当前目录文件..."]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeText("ui-created-folder")
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: folder)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        folder.doubleClick()
        let path = app.textFields["远程路径"]
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH %@", "/ui-created-folder"), object: path)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 10), .completed)
        capture("sftp-created-folder-entered")
    }

    func testSFTPHiddenFilesToggleAndKeyboardRecovery() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        let ordinary = staticText("nginx.conf")
        XCTAssertTrue(ordinary.waitForExistence(timeout: 10))
        let hidden = staticText(".bashrc")
        XCTAssertFalse(hidden.exists)
        app.menuButtons["ellipsis"].firstMatch.click()
        clickVisibleCenter(app.menuItems["显示隐藏文件"])
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        XCTAssertTrue(ordinary.exists)
        capture("sftp-hidden-files-visible")
        ordinary.click()
        app.typeKey(".", modifierFlags: [.command, .shift])
        let hiddenRemoved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: hidden)
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenRemoved], timeout: 5), .completed)
        XCTAssertTrue(ordinary.exists)
        capture("sftp-hidden-files-keyboard-hidden")
    }

    func testSFTPDeleteConfirmationCancelAndRemoveOwnFixture() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("nginx.conf").waitForExistence(timeout: 10))
        app.menuButtons["ellipsis"].firstMatch.click()
        clickVisibleCenter(app.menuItems["新建文件"])
        let name = app.textFields["文件名 (例如 test.sh)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-own-delete-fixture.txt")
        app.windows.buttons["创建"].firstMatch.click()
        let fixture = staticText("ui-own-delete-fixture.txt")
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))
        fixture.click()
        fixture.rightClick()
        clickVisibleCenter(app.menuItems["删除"])
        let confirm = app.windows.buttons["永久删除「ui-own-delete-fixture.txt」"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture("sftp-delete-confirmation")
        app.windows.buttons["取消"].firstMatch.click()
        XCTAssertTrue(fixture.exists)
        XCTAssertFalse(confirm.exists)
        fixture.click()
        fixture.rightClick()
        clickVisibleCenter(app.menuItems["删除"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: fixture)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertTrue(staticText("nginx.conf").exists)
        capture("sftp-own-fixture-deleted")
    }

    func testRealSSHVimClipboardArrowsResizeAndSave() throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(environment["APEX_UI_TEST_HOST"])
        let user = try XCTUnwrap(environment["APEX_UI_TEST_USER"])
        launch("main", extra: ["APEX_QA_REAL_HOST": host, "APEX_QA_REAL_USER": user, "APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 30))
        let inputSource = try IMEInputSourceSelection()
        inputSourceToRestore = inputSource
        try inputSource.selectEnabled("com.apple.keylayout.US")
        let clipboard = NSPasteboard.general
        let previous = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            clipboard.clearContents()
            let items = previous.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { clipboard.writeObjects(items) }
        }
        let terminal = app.textViews.firstMatch
        terminal.click()
        terminal.typeText("printf '\\nAPEX_UI_TMP=%s\\n' \"$(mktemp -d /tmp/apex-ui-XXXXXX)\"\n")
        let created = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s).*\\nAPEX_UI_TMP=/tmp/apex-ui-[A-Za-z0-9]+\\r?\\n.*"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 15), .completed)
        let text = terminal.value as? String ?? ""
        let regex = try NSRegularExpression(pattern: "\\nAPEX_UI_TMP=(/tmp/apex-ui-[A-Za-z0-9]+)\\r?\\n")
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
        let directory = String(text[range])
        ownedRemoteDirectory = directory
        terminal.typeText("vim -Nu NONE -n '\(directory)/ui-real-file.txt'\n")
        // Vim's filename message is transient and disappears on a SIGWINCH redraw.
        // Empty-buffer tildes plus removed shell history identify its alternate screen.
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ AND NOT value CONTAINS %@", "\n~\n", "APEX_UI_TMP"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 15), .completed)
        terminal.typeText("i")
        clipboard.clearContents()
        clipboard.setString("中文\ntwo\nthree", forType: .string)
        terminal.typeKey("v", modifierFlags: .command)
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "中文", "three"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 10), .completed)
        capture("real-vim-chinese-multiline-paste")
        terminal.typeKey(.escape, modifierFlags: [])
        terminal.typeKey(.upArrow, modifierFlags: [])
        terminal.typeKey(.leftArrow, modifierFlags: [])
        terminal.typeText("rX")
        let edited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "tXo"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [edited], timeout: 10), .completed)
        terminal.typeKey("=", modifierFlags: .command)
        terminal.typeKey("0", modifierFlags: .command)
        capture("real-vim-arrows-font-resize")
        let filePanel = app.checkBoxes["文件面板"].firstMatch
        XCTAssertTrue(filePanel.waitForExistence(timeout: 5))
        let remotePathField = app.textFields["远程路径"]
        if !remotePathField.exists { filePanel.click() }
        XCTAssertTrue(remotePathField.waitForExistence(timeout: 5))
        terminal.click()
        terminal.typeText(":let g:apex_before = &lines\n")
        filePanel.click()
        XCTAssertTrue(remotePathField.waitForNonExistence(timeout: 10))
        terminal.click()
        terminal.typeText(":echo &lines > g:apex_before ? 'APEX_VIEWPORT_GREW' : 'APEX_VIEWPORT_FAILED'\n")
        let acknowledged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s).*\\nAPEX_VIEWPORT_GREW(?:\\n.*|$)"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 10), .completed)
        capture("real-vim-remote-viewport-acknowledged")
        terminal.typeKey(.return, modifierFlags: [])
        terminal.typeText(":wq\n")
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "APEX_UI_TMP"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 10), .completed)
        terminal.typeText("cat '\(directory)/ui-real-file.txt'\n")
        let shellOutput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\n中文\ntXo\nthree\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [shellOutput], timeout: 15), .completed)
        terminal.typeKey("a", modifierFlags: .command)
        terminal.typeKey("c", modifierFlags: .command)
        XCTAssertTrue(clipboard.string(forType: .string)?.contains("中文\ntXo\nthree") == true)
        let read = Process()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        read.environment = ProcessInfo.processInfo.environment
        let agentSocket = try XCTUnwrap(ProcessInfo.processInfo.environment["APEX_UI_AGENT_SOCKET"] ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: agentSocket), "The forwarded SSH agent socket must exist")
        read.arguments = ["-F", "/dev/null", "-o", "IdentitiesOnly=no", "-o", "IdentityAgent=\(agentSocket)", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "\(user)@\(host)", "cat '\(directory)/ui-real-file.txt'"]
        let output = Pipe()
        read.standardOutput = output
        let errors = Pipe()
        read.standardError = errors
        try read.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        read.waitUntilExit()
        let sshError = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let sshDiagnostic = XCTAttachment(string: "SSH exit: \(read.terminationStatus)\n" + sshError)
        sshDiagnostic.name = "real-vim-independent-ssh-verification"
        sshDiagnostic.lifetime = .keepAlways
        add(sshDiagnostic)
        XCTAssertEqual(read.terminationStatus, 0, sshError)
        XCTAssertEqual(bytes, Data("中文\ntXo\nthree\n".utf8))
        capture("real-vim-copy-and-saved-bytes-verified")
    }

    func testTerminalNumberedTabShortcutsKeepOutputSeparate() {
        launch()
        var terminal = app.textViews.firstMatch
        terminal.click()
        terminal.typeText("printf 'APEX_FIRST_TAB_MARKER\\n'\n")
        let initial = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "APEX_FIRST_TAB_MARKER"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [initial], timeout: 5), .completed)
        app.toolbars.buttons["复制会话"].firstMatch.click()
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 15))
        terminal = app.textViews.firstMatch
        terminal.click()
        terminal.typeText("printf 'APEX_SECOND_TAB_MARKER\\n'\n")
        let second = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "APEX_SECOND_TAB_MARKER"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [second], timeout: 5), .completed)
        terminal.typeKey("1", modifierFlags: .command)
        let first = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ AND NOT value CONTAINS %@", "APEX_FIRST_TAB_MARKER", "APEX_SECOND_TAB_MARKER"), object: app.textViews.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [first], timeout: 5), .completed)
        app.textViews.firstMatch.typeKey("2", modifierFlags: .command)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ AND NOT value CONTAINS %@", "APEX_SECOND_TAB_MARKER", "APEX_FIRST_TAB_MARKER"), object: app.textViews.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        capture("numbered-tabs-preserve-independent-output")
    }

    func testRealSSHBuiltinPinyinCompositionAndCommit() throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(environment["APEX_UI_TEST_HOST"])
        let user = try XCTUnwrap(environment["APEX_UI_TEST_USER"])
        let trace = FileManager.default.temporaryDirectory.appendingPathComponent("apex-ime-key-trace-" + UUID().uuidString + ".log")
        let inputState = trace.appendingPathExtension("json")
        imeTraceFiles = [trace, inputState]
        launch("main", extra: ["APEX_QA_REAL_HOST": host, "APEX_QA_REAL_USER": user, "APEX_QA_CONNECT": "1", "APEX_QA_KEY_DIAGNOSTICS": "1", "APEX_QA_KEY_TRACE_PATH": trace.path, "APEX_QA_IME_STATE_PATH": inputState.path])
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 30))
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.click()
        let inputSource = try IMEInputSourceSelection()
        inputSourceToRestore = inputSource
        try inputSource.selectEnabled("com.apple.keylayout.US")
        app.activate()
        app.textFields.firstMatch.click()
        terminal.click()
        app.typeText("printf '\\nAPEX_UI_IME_READY\\n'; read -r apex_ui_ime; printf '\\nAPEX_UI_IME:%s\\n' \"$apex_ui_ime\"\n")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_IME_READY\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        app.textFields.firstMatch.click()
        terminal.click()
        try inputSource.selectEnabled("com.apple.inputmethod.SCIM.ITABC")
        // Select the real system IME in the focused client's context, not only
        // in the background runner's process-local input source cache.
        app.typeKey("p", modifierFlags: [.command, .option, .shift])
        func waitForInputState(marked: Bool) {
            let state = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let data = try? Data(contentsOf: inputState),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return record["focused"] as? Bool == true
                    && record["source"] as? String == "com.apple.inputmethod.SCIM.ITABC"
                    && record["marked"] as? Bool == marked
                    && record["alternate"] as? Bool == false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 5), .completed,
                           "The actual terminal input context must have the expected system Pinyin composition state")
        }
        waitForInputState(marked: false)
        XCTAssertEqual(IMEInputSourceSelection.currentIdentifier(), "com.apple.inputmethod.SCIM.ITABC")
        func postPhysicalKey(_ name: String) throws {
            // Launch Services attributes TCC to the signed helper. A direct
            // Process inherits the runner/SSH responsible process instead.
            let executable = URL(fileURLWithPath: try XCTUnwrap(environment["APEX_UI_PHYSICAL_KEY_HELPER"]))
            let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            XCTAssertEqual(Bundle(url: bundle)?.bundleIdentifier, "com.apexterm.qa.physicalkeys")
            let target = try XCTUnwrap(environment["APEX_UI_PHYSICAL_KEY_TARGET"])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apex-key-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("stdout")
            let helperError = directory.appendingPathComponent("stderr")
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            helper.arguments = ["-n", "-g", "-W", "--stdout", output.path, "--stderr", helperError.path,
                                "--env", "APEX_UI_PHYSICAL_KEY_TARGET=" + target, "-a", bundle.path, "--args", name]
            let error = Pipe()
            helper.standardError = error
            try helper.run()
            helper.waitUntilExit()
            XCTAssertEqual(helper.terminationStatus, 0, String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            let diagnostic = (try? String(contentsOf: helperError, encoding: .utf8)) ?? ""
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "APEX_PHYSICAL_KEY_OK \(name)\n",
                           "The helper must confirm completion; open's exit status does not report helper failures. " + diagnostic)
        }
        try postPhysicalKey("--preflight")
        let outputBeforeComposition = terminal.value as? String
        try postPhysicalKey("pinyin")
        waitForInputState(marked: true)
        let composition = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        composition.name = "real-system-pinyin-composition-and-candidates"
        composition.lifetime = .keepAlways
        add(composition)
        XCTAssertEqual(terminal.value as? String, outputBeforeComposition,
                       "No partial Pinyin preedit may enter the remote shell before candidate commit")
        // Verify cancellation: Escape discards the preedit without sending input or ESC to the remote shell
        // Post a real hardware Escape without XCTest switching keyboard sources
        // or committing preedit before the event reaches the application.
        try postPhysicalKey("escape")
        waitForInputState(marked: false)
        let keys = try String(contentsOf: trace, encoding: .utf8)
        XCTAssertTrue(keys.split(separator: "\n").contains { line in
            line.contains("QA_KEY code=53 ") && line.contains("terminal=true")
                && line.contains("marked=true") && line.contains("alternate=false")
                && line.contains("source=com.apple.inputmethod.SCIM.ITABC")
        }, "A real Escape key must reach the terminal while system Pinyin preedit is active")
        let leaked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", try XCTUnwrap(outputBeforeComposition)), object: terminal)
        leaked.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [leaked], timeout: 0.5), .completed, "Cancelled preedit must remain absent after remote echo settles")
        XCTAssertEqual(terminal.value as? String, outputBeforeComposition,
                       "Cancelling Pinyin composition with Escape must not send preedit or control codes to remote shell")
        let cancelled = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        cancelled.name = "real-system-pinyin-cancelled-by-escape"
        cancelled.lifetime = .keepAlways
        add(cancelled)

        // Type again and commit Chinese via Space candidate selection
        try postPhysicalKey("pinyin")
        waitForInputState(marked: true)
        XCTAssertEqual(terminal.value as? String, outputBeforeComposition,
                       "Pinyin preedit must remain isolated from remote shell")
        try postPhysicalKey("space")
        try postPhysicalKey("return")
        let committed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_IME:中文\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 15), .completed,
                       "The actual system input method must commit Chinese into the real SSH session")
        capture("real-system-pinyin-ssh-echo")
    }

    func testRealSSHConfiguredHostIsMandatory() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["APEX_UI_TEST_HOST"], !host.isEmpty,
              let user = environment["APEX_UI_TEST_USER"], !user.isEmpty else {
            XCTFail("Release UI acceptance requires APEX_UI_TEST_HOST and APEX_UI_TEST_USER; no skipped real-host acceptance")
            return
        }
        launch("main", extra: ["APEX_QA_REAL_HOST": host, "APEX_QA_REAL_USER": user, "APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 30), "Real SSH must reach connected state before typing")
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.click()
        terminal.typeText("printf '\\nAPEX_UI_REAL_PTY_OK\\n'\n")
        let output = NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_REAL_PTY_OK\n")
        let echo = XCTNSPredicateExpectation(predicate: output, object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [echo], timeout: 15), .completed)
        capture("real-ssh-pty")
        clickVisibleCenter(app.menuBars.menuBarItems["验收操作"])
        clickVisibleCenter(app.menuItems["断开测试终端"])
        XCTAssertTrue(staticText("会话已断开").waitForExistence(timeout: 10))
        app.windows.buttons["重新连接 (⌘R)"].firstMatch.click()
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 30))
        XCTAssertFalse(staticText("会话已断开").exists)
        terminal.click()
        terminal.typeText("printf '\\nAPEX_UI_REAL_RECONNECT_OK\\n'\n")
        let restoredOutput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_REAL_RECONNECT_OK\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredOutput], timeout: 15), .completed)
        capture("real-ssh-reconnect-pty")
        terminal.typeText("printf '\\nAPEX_UI_TMP=%s\\n' \"$(mktemp -d /tmp/apex-ui-XXXXXX)\"\n")
        let directoryOutput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s).*\\nAPEX_UI_TMP=/tmp/apex-ui-[A-Za-z0-9]+\\r?\\n.*"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [directoryOutput], timeout: 15), .completed)
        let pattern = try NSRegularExpression(pattern: "\\nAPEX_UI_TMP=(/tmp/apex-ui-[A-Za-z0-9]+)\\r?\\n")
        let outputText = terminal.value as? String ?? ""
        let match = try XCTUnwrap(pattern.firstMatch(in: outputText, range: NSRange(outputText.startIndex..., in: outputText)))
        let directoryRange = try XCTUnwrap(Range(match.range(at: 1), in: outputText))
        let directory = String(outputText[directoryRange])
        ownedRemoteDirectory = directory
        terminal.typeText("cd '\(directory)'\n")
        let fixtureRecord = XCTAttachment(string: "Owned temporary directory: \(directory)\nOwned file: ui-real-file.txt\nNormal success removes the file through SFTP and removes the empty directory through SSH.\nOn failure, SSH cleanup removes only this exact file and then the empty directory; it never recursively removes other paths.")
        fixtureRecord.name = "real-host-owned-fixture"
        fixtureRecord.lifetime = .keepAlways
        add(fixtureRecord)
        let path = app.textFields["远程路径"]
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText(directory)
        path.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(staticText("文件夹为空").waitForExistence(timeout: 15))
        app.menuButtons["ellipsis"].firstMatch.click()
        clickVisibleCenter(app.menuItems["新建文件"])
        let fileName = app.textFields["文件名 (例如 test.sh)"]
        XCTAssertTrue(fileName.waitForExistence(timeout: 5))
        fileName.click()
        fileName.typeText("ui-real-file.txt")
        app.windows.buttons["创建"].firstMatch.click()
        let realFile = staticText("ui-real-file.txt")
        XCTAssertTrue(realFile.waitForExistence(timeout: 15))
        terminal.click()
        terminal.typeText("test -f '\(directory)/ui-real-file.txt' && printf '\\nAPEX_UI_REAL_FILE_OK\\n'\n")
        let existsRemotely = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_REAL_FILE_OK\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [existsRemotely], timeout: 15), .completed)
        capture("real-sftp-created-file-verified")
        realFile.click()
        realFile.rightClick()
        clickVisibleCenter(app.menuItems["快速查看 / 编辑"])
        let remoteEditor = app.textViews["文件内容"]
        XCTAssertTrue(remoteEditor.waitForExistence(timeout: 15))
        remoteEditor.click()
        remoteEditor.typeText("APEX_UI_REMOTE_EDITOR_CONTENT")
        app.windows.buttons["保存 (⌘S)"].firstMatch.click()
        XCTAssertTrue(staticText("已保存并上传至服务器", comparison: "CONTAINS").waitForExistence(timeout: 20))
        capture("real-sftp-editor-save")
        app.windows.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        terminal.click()
        terminal.typeText("test \"$(cat '\(directory)/ui-real-file.txt')\" = 'APEX_UI_REMOTE_EDITOR_CONTENT' && printf '\\nAPEX_UI_REMOTE_CONTENT_OK\\n'\n")
        let savedRemotely = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_REMOTE_CONTENT_OK\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [savedRemotely], timeout: 15), .completed)
        realFile.click()
        realFile.rightClick()
        clickVisibleCenter(app.menuItems["删除"])
        let delete = app.windows.buttons["永久删除「ui-real-file.txt」"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        XCTAssertTrue(staticText("文件夹为空").waitForExistence(timeout: 15))
        terminal.click()
        terminal.typeText("cd ~; rmdir '\(directory)' && printf '\\nAPEX_UI_FIXTURE_CLEAN_OK\\n'\n")
        let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_FIXTURE_CLEAN_OK\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [cleaned], timeout: 15), .completed)
        ownedRemoteDirectory = nil
    }

    private var dragLocalDirectory: URL?
    private var dragRemoteFixture: (destination: String, directory: String, fileName: String)?
    private var dragFinderWindow: XCUIElement?
    func testRealFinderDragUploadAndRecord() throws {
        try exerciseFinderDrag(download: false)
    }

    func testRealFinderDragDownloadAndRecord() throws {
        try exerciseFinderDrag(download: true)
    }

    func testRealFinderDragLargeDownloadAndRecord() throws {
        try exerciseFinderDrag(download: true, large: true)
    }

    private func exerciseFinderDrag(download: Bool, large: Bool = false) throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(environment["APEX_UI_TEST_HOST"])
        let user = try XCTUnwrap(environment["APEX_UI_TEST_USER"])
        let destination = "\(user)@\(host)"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("apex-ui-drag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
        dragLocalDirectory = local
        launch("main", extra: ["APEX_QA_REAL_HOST": host, "APEX_QA_REAL_USER": user, "APEX_QA_CONNECT": "1", "APEX_QA_MONITOR": "0", "APEX_QA_SIDE_BY_SIDE": "1"])
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 30))
        let terminal = app.textViews.firstMatch
        terminal.click()
        terminal.typeText("printf '\\nAPEX_UI_DRAG_DIR=%s\\n' \"$(mktemp -d /tmp/apex-ui-drag-XXXXXX)\"\n")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "(?s).*\\nAPEX_UI_DRAG_DIR=/tmp/apex-ui-drag-[A-Za-z0-9]+\\r?\\n.*"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        let regex = try NSRegularExpression(pattern: "\\nAPEX_UI_DRAG_DIR=(/tmp/apex-ui-drag-[A-Za-z0-9]+)\\r?\\n")
        let text = terminal.value as? String ?? ""
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
        let directory = String(text[range])
        guard directory.range(of: "^/tmp/apex-ui-drag-[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "ApexTerm.DragAcceptance", code: 1)
        }
        let name = large ? "ui-drag-large.bin" : "ui-drag-payload.txt"
        dragRemoteFixture = (destination, directory, name)
        let file = local.appendingPathComponent(name)
        let payload = large ? Data(repeating: 0, count: 64 * 1024 * 1024)
                            : Data((0..<262144).map { 65 + UInt8($0 % 26) })
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        if download {
            let seed = large
                ? "dd if=/dev/zero of='\(directory)/\(name)' bs=1048576 count=64 2>/dev/null"
                : "awk 'BEGIN { for (i=0; i<262144; i++) printf \"%c\", 65+(i%26) }' > '\(directory)/\(name)'"
            terminal.typeText("\(seed) && printf '\\nAPEX_UI_DRAG_SEEDED\\n'\n")
            let seeded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_DRAG_SEEDED\n"), object: terminal)
            XCTAssertEqual(XCTWaiter.wait(for: [seeded], timeout: 15), .completed)
        } else { try payload.write(to: file) }
        let path = app.textFields["远程路径"]
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText(directory)
        path.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.dialogs.buttons.matching(identifier: "Capslock").firstMatch
            .waitForNonExistence(timeout: 5),
            "Submitting a directory must dismiss the path field's input indicator before file dragging")
        if download { XCTAssertTrue(staticText(name).waitForExistence(timeout: 15)) }
        else { XCTAssertTrue(staticText("文件夹为空").waitForExistence(timeout: 15)) }

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        XCTAssertTrue(NSWorkspace.shared.open(local))
        finder.activate()
        let window = finder.windows[local.lastPathComponent]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        dragFinderWindow = window
        // Finder retains window positions across runs. Choose a content point
        // beyond the app's right edge instead of moving Finder via its toolbar.
        let finderDropOffset = CGPoint(
            x: max(350, app.windows.firstMatch.frame.maxX + 40 - window.frame.minX),
            y: 200)
        print("Finder fixture layout app=\(app.windows.firstMatch.frame) finder=\(window.frame) dropOffset=\(finderDropOffset)")
        let tiled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let target = CGPoint(x: window.frame.minX + finderDropOffset.x,
                                 y: window.frame.minY + finderDropOffset.y)
            return window.frame.contains(target) && !self.app.windows.firstMatch.frame.contains(target)
        }, object: window)
        XCTAssertEqual(XCTWaiter.wait(for: [tiled], timeout: 10), .completed)
        let fullScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        fullScreen.name = download ? "finder-download-before-drag" : "finder-upload-before-drag"
        fullScreen.lifetime = .keepAlways
        add(fullScreen)
        if download {
            // macOS 27 can keep another app in front after activate(). Raise
            // our owned window by its visible title strip before dragging.
            focusOwnedWindow()
            let remoteFile = staticText(name)
            remoteFile.click()
            capture("finder-download-selected-remote-row")
            let geometry = XCTAttachment(string: "source=\(remoteFile.frame) finder=\(window.frame) app=\(app.windows.firstMatch.frame)\n\(finder.debugDescription)")
            geometry.name = "finder-download-drag-geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
            // Keep both coordinates owned by the source application. A Finder-
            // owned endpoint can raise Finder before the gesture and cover the
            // remote row, so the drag never begins on the intended file.
            let appWindow = app.windows.firstMatch
            let nameFrame = remoteFile.frame
            XCTAssertTrue(remoteFile.isHittable)
            XCTAssertTrue(nameFrame.width > 0 && nameFrame.height > 0)
            // Start inside the filename cell using its larger visible drag target.
            let downloadSource = appWindow.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: nameFrame.midX - appWindow.frame.minX,
                         dy: nameFrame.midY - appWindow.frame.minY))
            let finderTarget = CGPoint(x: window.frame.minX + finderDropOffset.x,
                                       y: window.frame.minY + finderDropOffset.y)
            let downloadTarget = appWindow.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: finderTarget.x - appWindow.frame.minX,
                         dy: finderTarget.y - appWindow.frame.minY))
            print("Finder download filename=\(nameFrame) target=\(finderTarget)")
            downloadSource.click(forDuration: 0.6,
                thenDragTo: downloadTarget,
                withVelocity: .slow, thenHoldForDuration: 1.0)
            let landed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: file.path)
            }, object: nil)
            let landingResult = XCTWaiter.wait(for: [landed], timeout: large ? 120 : 30)
            if landingResult != .completed {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? []
                let diagnostic = XCTAttachment(string: "expected=\(name)\nreceived=\(files)\n")
                diagnostic.name = "finder-download-destination-contents"
                diagnostic.lifetime = .keepAlways
                add(diagnostic)
                print("Finder download expected=\(name) received=\(files)")
                let records = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "传输记录")).firstMatch
                if records.exists {
                    clickVisibleCenter(records)
                    capture("finder-download-timeout-transfer-records")
                    let recordTree = XCTAttachment(string: app.debugDescription)
                    recordTree.name = "finder-download-timeout-transfer-record-tree"
                    recordTree.lifetime = .keepAlways
                    add(recordTree)
                }
            }
            XCTAssertEqual(landingResult, .completed)
            XCTAssertEqual(try Data(contentsOf: file), payload)
        } else {
            let source = window.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", name, name)).firstMatch
            let emptyFrame = staticText("文件夹为空").frame
            let appFrame = app.windows.firstMatch.frame
            // All candidates lie in the file browser's empty content area.
            let uploadCandidates = [
                CGPoint(x: appFrame.minX + appFrame.width * 0.3, y: emptyFrame.midY),
                CGPoint(x: emptyFrame.midX, y: emptyFrame.midY),
                CGPoint(x: appFrame.maxX - 30, y: emptyFrame.midY),
                CGPoint(x: appFrame.minX + appFrame.width * 0.3, y: appFrame.maxY - 60),
                CGPoint(x: appFrame.maxX - 30, y: appFrame.maxY - 60)
            ]
            let finderFrames = finder.windows.allElementsBoundByIndex.map(\.frame)
            let uploadPoint = try XCTUnwrap(uploadCandidates.first { point in
                appFrame.contains(point) && !finderFrames.contains { $0.contains(point) }
            }, "The upload target must remain visible beside Finder")
            // Resolving a coordinate owned by the other application activates it
            // before the gesture and covers Finder's source icon. Resolve the
            // endpoint through Finder's window using the same screen location.
            finder.activate()
            // Activate alone does not reliably raise Finder on macOS 27.
            // Click its visible title strip before resolving the source icon.
            window.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: finderDropOffset.x, dy: 8)).click()
            finder.typeKey("2", modifierFlags: .command)
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            XCTAssertTrue(source.isHittable, "Finder's source file must be visible before dragging")
            let sourceTree = XCTAttachment(string: window.debugDescription)
            sourceTree.name = "finder-upload-source-tree"
            sourceTree.lifetime = .keepAlways
            add(sourceTree)
            let sourceFrame = source.frame
            let sourceIcon = try XCTUnwrap(window.images.allElementsBoundByIndex.first { image in
                let frame = image.frame
                return frame.width > 0 && frame.height > 0
                    && abs(frame.midY - sourceFrame.midY) <= 3
                    && frame.maxX <= sourceFrame.minX
                    && sourceFrame.minX - frame.maxX <= 12
            }, "Finder must expose the file icon immediately beside its filename")
            let iconFrame = sourceIcon.frame
            print("Finder upload icon=\(iconFrame)")
            let dragStart = window.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: iconFrame.midX - window.frame.minX, dy: iconFrame.midY - window.frame.minY))
            print("Finder upload source=\(source.frame) target=\(uploadPoint)")
            dragStart.click(forDuration: 0.6,
                thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(
                    CGVector(dx: uploadPoint.x - window.frame.minX, dy: uploadPoint.y - window.frame.minY)),
                withVelocity: .slow, thenHoldForDuration: 1.0)
            // A real upload opens its progress sheet. Inspect it before returning
            // to the underlying directory; querying behind a sheet hides AX rows.
            XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(staticText(name).waitForExistence(timeout: 5))
            XCTAssertTrue(staticText("传输完成").waitForExistence(timeout: 30))
            capture("real-finder-upload-automatic-completed-record")
            clickVisibleCenter(app.windows.buttons["收起传输任务"].firstMatch)
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            // SwiftUI's macOS Table is exposed as AXOutline, not AXTable.
            let listedFile = app.outlines.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", name, name)).firstMatch
            XCTAssertTrue(listedFile.waitForExistence(timeout: 30), "The remote file table must contain the upload; a failure record cannot substitute for listing")
        }
        app.activate()
        terminal.click()
        terminal.typeText("printf '\\nAPEX_UI_HASH:%s\\n' \"$(shasum -a 256 '\(directory)/\(name)' | awk '{print $1}')\"\n")
        let hashMatches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_HASH:\(digest)\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [hashMatches], timeout: 15), .completed)
        app.activate()
        app.windows.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "传输记录")).firstMatch.click()
        XCTAssertTrue(staticText(name).waitForExistence(timeout: 5))
        XCTAssertTrue(staticText(download ? "下载" : "上传").exists)
        XCTAssertTrue(staticText("传输完成").waitForExistence(timeout: 10))
        XCTAssertTrue(staticText(directory + "/" + name, comparison: "CONTAINS").exists)
        capture(download ? "real-finder-download-completed-record" : "real-finder-upload-completed-record")
        let proof = XCTAttachment(string: "Direction: \(download ? "download" : "upload")\nBytes: \(payload.count)\nSHA256: \(digest)\nRemote: \(directory)/\(name)\nLocal: \(file.path)")
        proof.name = "real-finder-drag-content-proof"
        proof.lifetime = .keepAlways
        add(proof)
    }

    private func cleanupFinderDrag() throws {
        defer {
            if let local = dragLocalDirectory {
                do {
                    try FileManager.default.removeItem(at: local)
                    dragLocalDirectory = nil
                } catch {
                    XCTFail("Cannot remove the owned local drag fixture: \(error)")
                }
            }
        }
        if dragRemoteFixture != nil {
            app.activate()
            if app.sheets.firstMatch.exists {
                let close = app.windows.buttons["收起传输任务"].firstMatch
                if close.exists { clickVisibleCenter(close) }
                guard app.sheets.firstMatch.waitForNonExistence(timeout: 10) else {
                    throw NSError(domain: "ApexTerm.DragAcceptance", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot clean owned fixture behind an open transfer sheet"])
                }
            }
        }
        if let window = dragFinderWindow, window.exists {
            let close = window.buttons[XCUIIdentifierCloseWindow].firstMatch
            XCTAssertTrue(close.exists, "Close only the owned UUID-directory Finder window")
            if close.exists {
                let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
                finder.activate()
                close.click()
                XCTAssertTrue(window.waitForNonExistence(timeout: 5), "The owned Finder window must close before removing its directory")
            }
        }
        dragFinderWindow = nil
        if let fixture = dragRemoteFixture {
            app.activate()
            let terminal = app.textViews.firstMatch
            XCTAssertTrue(terminal.waitForExistence(timeout: 5))
            terminal.click()
            let marker = "APEX_UI_DRAG_CLEAN_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            terminal.typeText("/bin/rm -f '\(fixture.directory)/\(fixture.fileName)' && /bin/rmdir '\(fixture.directory)' && printf '\\n\(marker)\\n'\n")
            let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\n\(marker)\n"), object: terminal)
            XCTAssertEqual(XCTWaiter.wait(for: [cleaned], timeout: 15), .completed)
            dragRemoteFixture = nil
        }
    }

    func testRealSSHTerminalScrollSystemMetrics() throws {
        guard #available(macOS 26.0, *) else {
            XCTFail("Application hitch acceptance requires macOS 26 or later")
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(environment["APEX_UI_TEST_HOST"])
        let user = try XCTUnwrap(environment["APEX_UI_TEST_USER"])
        launch("main", extra: ["APEX_QA_REAL_HOST": host, "APEX_QA_REAL_USER": user, "APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 30))
        let terminal = app.textViews.firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        terminal.click()
        terminal.typeText("awk 'BEGIN { for (i=0; i<5000; i++) printf \"APEX_SCROLL_LINE_%05d abcdefghijklmnopqrstuvwxyz\\n\", i; print \"APEX_UI_SCROLL_READY\" }'\n")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_SCROLL_READY\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        capture("real-terminal-scroll-metrics-before")
        let options = XCTMeasureOptions.default
        options.iterationCount = 3
        measure(metrics: [XCTHitchMetric(application: app), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            terminal.scroll(byDeltaX: 0, deltaY: 5000)
            terminal.scroll(byDeltaX: 0, deltaY: -5000)
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "real-terminal-scroll-metrics-target"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture("real-terminal-scroll-metrics-after")
    }

    func testTransferRecordFiltersAndClearCompleted() {
        launch("transfers", extra: ["APEX_QA_TRANSFER_RECORDS": "1"])
        let upload = staticText("ui-upload.txt")
        let download = staticText("ui-download.txt")
        XCTAssertTrue(upload.waitForExistence(timeout: 5))
        XCTAssertTrue(download.exists)
        app.radioButtons["上传 (1)"].click()
        XCTAssertTrue(upload.exists)
        XCTAssertFalse(download.exists)
        app.radioButtons["下载 (1)"].click()
        XCTAssertTrue(download.exists)
        XCTAssertFalse(upload.exists)
        app.radioButtons["全部 (2)"].click()
        XCTAssertTrue(upload.exists)
        XCTAssertTrue(download.exists)
        capture("transfer-record-filters")
        app.windows.buttons["清空记录"].firstMatch.click()
        XCTAssertFalse(upload.exists)
        XCTAssertTrue(download.exists, "Clearing completed records must preserve failures")
        XCTAssertFalse(app.windows.buttons["清空记录"].firstMatch.exists)
        capture("transfer-clear-preserves-failure")
    }

    func testTransferCancelAndClearPreservesActiveTask() {
        launch("transfers", extra: ["APEX_QA_TRANSFER_RECORDS": "active"])
        let cancel = app.windows.buttons["取消传输 ui-cancel.txt"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.buttons["取消传输 ui-keep-active.txt"].firstMatch.exists)
        cancel.click()
        XCTAssertTrue(staticText("已取消").waitForExistence(timeout: 5))
        XCTAssertFalse(cancel.exists)
        XCTAssertTrue(staticText("ui-cancel.txt").exists)
        capture("transfer-cancelled-record")
        app.windows.buttons["清空记录"].firstMatch.click()
        XCTAssertFalse(staticText("ui-cancel.txt").exists)
        XCTAssertTrue(staticText("ui-keep-active.txt").exists)
        XCTAssertTrue(app.windows.buttons["取消传输 ui-keep-active.txt"].firstMatch.isHittable)
        XCTAssertFalse(app.windows.buttons["清空记录"].firstMatch.exists)
        capture("transfer-clear-preserves-active")
    }

    func testEditorUnsavedCancelSaveAndClose() {
        launch("editor-sheet")
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nui_acceptance=true")
        app.windows.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(app.windows.buttons["继续编辑"].firstMatch.waitForExistence(timeout: 5))
        capture("editor-unsaved-close")
        app.windows.buttons["继续编辑"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.exists)
        let save = app.windows.buttons["保存 (⌘S)"].firstMatch
        save.click()
        XCTAssertTrue(app.activityIndicators["保存 (⌘S)"].firstMatch.waitForExistence(timeout: 5))
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        XCTAssertTrue(staticText("已保存并上传至服务器", comparison: "CONTAINS").waitForExistence(timeout: 5))
        capture("editor-save-completed")
        app.windows.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testEditorSaveFailureKeepsChanges() {
        launch("editor-sheet", extra: ["APEX_QA_EDITOR_SAVE": "failure"])
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nkeep_after_failure=true")
        app.windows.buttons["保存 (⌘S)"].firstMatch.click()
        let failed = staticText("权限不足", comparison: "CONTAINS")
        XCTAssertTrue(failed.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String)?.contains("keep_after_failure=true") == true)
        capture("editor-save-failure")
        app.windows.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(app.windows.buttons["继续编辑"].firstMatch.waitForExistence(timeout: 5))
        app.windows.buttons["继续编辑"].firstMatch.click()
    }

    func testEditorSaveFailureRetryRecovers() {
        launch("editor-sheet", extra: ["APEX_QA_EDITOR_SAVE": "failure-once"])
        let editor = app.textViews["文件内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nretry_revision=true")
        let save = app.windows.buttons["保存 (⌘S)"].firstMatch
        save.click()
        let error = staticText("保存失败:", comparison: "CONTAINS")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue((editor.value as? String)?.contains("retry_revision=true") == true)
        save.click()
        XCTAssertTrue(staticText("已保存并上传至服务器", comparison: "CONTAINS").waitForExistence(timeout: 10))
        XCTAssertFalse(error.exists)
        XCTAssertTrue((editor.value as? String)?.contains("retry_revision=true") == true)
        capture("editor-save-retry-recovered")
        app.windows.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.windows.buttons["继续编辑"].firstMatch.exists)
    }

    func testEditorReloadFailureRetryPreservesContent() {
        launch("editor-sheet", extra: ["APEX_QA_EDITOR_RELOAD": "failure-once"])
        let editor = app.textViews["文件内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let original = editor.value as? String
        let reload = app.windows.buttons.matching(NSPredicate(format: "label CONTAINS %@", "重新加载")).firstMatch
        // A physical pointer click avoids XCTest focus traversal inserting Tab into the editor.
        reload.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let error = staticText("拉取失败:", comparison: "CONTAINS")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, original)
        XCTAssertTrue(reload.isEnabled)
        capture("editor-reload-failed-content-preserved")
        // A physical pointer click avoids XCTest focus traversal inserting Tab into the editor.
        reload.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(staticText("已重新拉取远端最新内容").waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
        XCTAssertEqual(editor.value as? String, "# 远端配置\nserver=demo\n")
        app.windows.buttons["关闭"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testEditorChangesDuringSaveRemainUnsaved() {
        launch("editor-sheet", extra: ["APEX_QA_EDITOR_SAVE_DELAY": "8"])
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nfirst_revision=true")
        let save = app.windows.buttons["保存 (⌘S)"].firstMatch
        save.click()
        XCTAssertTrue(app.activityIndicators["保存 (⌘S)"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.activityIndicators["保存 (⌘S)"].firstMatch.isEnabled)
        editor.click()
        editor.typeText("\nsecond_revision=true")
        let pending = staticText("仍有新更改待保存", comparison: "CONTAINS")
        XCTAssertTrue(pending.waitForExistence(timeout: 20))
        XCTAssertTrue((editor.value as? String)?.contains("second_revision=true") == true)
        app.windows.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(app.windows.buttons["继续编辑"].firstMatch.waitForExistence(timeout: 5))
        capture("editor-save-preserves-new-changes")
        app.windows.buttons["继续编辑"].firstMatch.click()
        save.click()
        XCTAssertTrue(staticText("已保存并上传至服务器", comparison: "CONTAINS").waitForExistence(timeout: 10))
        app.windows.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testEditorKeyboardFindUndoAndSave() {
        launch("editor-sheet")
        let editor = app.textViews["文件内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let initial = editor.value as? String
        editor.click()
        editor.typeText("\nkeyboard_revision=true")
        XCTAssertTrue((editor.value as? String)?.contains("keyboard_revision=true") == true)
        editor.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, initial)
        editor.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue((editor.value as? String)?.contains("keyboard_revision=true") == true)
        let edited = editor.value as? String
        editor.typeKey("f", modifierFlags: .command)
        let find = app.searchFields.firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 5), "Native find bar must expose a search field")
        find.click()
        find.typeKey("a", modifierFlags: .command)
        find.typeText("keyboard_revision")
        XCTAssertEqual(find.value as? String, "keyboard_revision")
        XCTAssertEqual(editor.value as? String, edited, "Searching must not modify file contents")
        capture("editor-native-find")
        editor.click()
        editor.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(staticText("已保存并上传至服务器", comparison: "CONTAINS").waitForExistence(timeout: 10))
        editor.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testEditorReloadCancelAndDiscard() {
        launch("editor-sheet")
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nunsaved_reload_marker=true")
        let reload = app.windows.buttons.matching(NSPredicate(format: "label CONTAINS %@", "重新加载")).firstMatch
        XCTAssertTrue(reload.isHittable)
        reload.click()
        XCTAssertTrue(app.windows.buttons["继续编辑"].firstMatch.waitForExistence(timeout: 5))
        app.windows.buttons["继续编辑"].firstMatch.click()
        XCTAssertTrue((editor.value as? String)?.contains("unsaved_reload_marker=true") == true)
        reload.click()
        XCTAssertTrue(app.windows.buttons["放弃更改"].firstMatch.waitForExistence(timeout: 5))
        app.windows.buttons["放弃更改"].firstMatch.click()
        let remote = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ AND NOT value CONTAINS %@", "远端配置", "unsaved_reload_marker"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [remote], timeout: 10), .completed)
        capture("editor-reloaded")
        app.windows.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
    }

    func testMochaSettingsTabsRemainClickable() {
        // Set the actual theme before launch: the QA menu's AX geometry can be unavailable on macOS 27.
        launch("settings", extra: ["APEX_QA_THEME": "Catppuccin Mocha"])
        for tab in ["SFTP传输", "数据备份", "通用", "终端外观", "操作习惯", "数据备份"] {
            activateSettingsWindow()
            let control = app.tabs[tab]
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            clickVisibleCenter(control)
            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "selected == true OR value == 1 OR value == %@", "1"), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                           "Settings tab must actually switch: " + tab)
            capture("mocha-settings-click-" + tab)
        }
    }

    func testRealSSHMonitoringDisconnectAndReconnect() throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(environment["APEX_UI_TEST_HOST"])
        let user = try XCTUnwrap(environment["APEX_UI_TEST_USER"])
        let metricsResult = FileManager.default.temporaryDirectory.appendingPathComponent("apex-metrics-" + UUID().uuidString + ".json")
        defer {
            app?.terminate()
            try? FileManager.default.removeItem(at: metricsResult)
        }
        launch("main", extra: ["APEX_QA_REAL_HOST": host, "APEX_QA_REAL_USER": user,
                               "APEX_QA_CONNECT": "1", "APEX_QA_MONITOR": "1",
                               "APEX_QA_METRICS_RESULT": metricsResult.path])
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 30))
        let summary = app.buttons["metrics.summary"]
        let sampled = NSPredicate(format: "label CONTAINS %@", "%")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sampled, object: summary)], timeout: 30), .completed)
        capture("real-monitor-connected")
        clickVisibleCenter(app.menuBars.menuBarItems["验收操作"])
        clickVisibleCenter(app.menuItems["断开测试终端"])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "监控连接已中断"), object: summary)], timeout: 5), .completed)
        clickVisibleCenter(summary)
        XCTAssertTrue(staticText("连接已中断，以下为最后一次采样").waitForExistence(timeout: 3))
        XCTAssertTrue(staticText("CPU").exists)
        capture("real-monitor-disconnected-history")
        app.typeKey(.escape, modifierFlags: [])
        let reconnect = app.windows.buttons["重新连接 (⌘R)"].firstMatch
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
        let reconnectStarted = Date().timeIntervalSince1970
        reconnect.click()
        XCTAssertTrue(staticText("已连接", comparison: "BEGINSWITH").waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sampled, object: summary)], timeout: 30), .completed)
        let freshSample = NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: metricsResult),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = record["timestamp"] as? Double else { return false }
            return timestamp > reconnectStarted
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: freshSample, object: NSObject())], timeout: 30), .completed)
        let samplingEvidence = XCTAttachment(data: try Data(contentsOf: metricsResult), uniformTypeIdentifier: "public.json")
        samplingEvidence.name = "real-monitor-post-reconnect-sample"
        samplingEvidence.lifetime = .keepAlways
        add(samplingEvidence)
        capture("real-monitor-reconnected")
    }

    func testMonitoringStatesAreExplicit() {
        for state in ["live", "stale", "waiting", "disabled", "disabled-history", "disconnected-history", "connecting", "connecting-history"] {
            launch("metrics", extra: ["APEX_QA_METRICS_STATE": state])
            // AppKit exposes the connecting-state ProgressView as an activity
            // indicator, even though the SwiftUI control remains clickable.
            let summary = app.descendants(matching: .any)["metrics.summary"].firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            if state == "connecting" || state == "connecting-history" {
                XCTAssertTrue(summary.label.contains("监控连接中"))
            } else if state == "disconnected-history" {
                XCTAssertTrue(summary.label.contains("监控连接已中断"))
            } else if state == "stale" {
                XCTAssertTrue(summary.label.contains("监控已过期"))
            } else if state == "waiting" {
                XCTAssertTrue(summary.label.contains("监控待命"))
            } else if state == "disabled" || state == "disabled-history" {
                XCTAssertTrue(summary.label.contains("监控已关闭"))
            } else {
                XCTAssertTrue(summary.label.contains("24.0%"))
            }
            capture("metrics-" + state + "-summary")
            focusOwnedWindow()
            clickVisibleCenter(summary)
            XCTAssertTrue(app.staticTexts["metrics.detail.title"].waitForExistence(timeout: 3))
            switch state {
            case "connecting":
                XCTAssertTrue(staticText("正在连接，等待监控数据…").exists)
            case "connecting-history":
                XCTAssertTrue(staticText("正在连接，等待新监控数据").exists)
                XCTAssertTrue(staticText("CPU 与内存历史 (%)").exists)
            case "disconnected-history":
                XCTAssertTrue(staticText("连接已中断，以下为最后一次采样").exists)
                XCTAssertTrue(staticText("CPU").exists)
                XCTAssertTrue(staticText("CPU 与内存历史 (%)").exists)
            case "stale":
                XCTAssertTrue(staticText("数据已过期", comparison: "CONTAINS").exists)
                XCTAssertTrue(staticText("CPU 与内存历史 (%)").exists)
            case "waiting":
                XCTAssertTrue(staticText("等待监控数据…").exists)
            case "disabled", "disabled-history":
                XCTAssertTrue(staticText("监控已关闭，可在会话设置中开启").exists)
            default:
                XCTAssertTrue(staticText("CPU").exists)
                XCTAssertTrue(staticText("CPU 与内存历史 (%)").exists)
            }
            capture("metrics-" + state + "-detail")
            app.typeKey(.escape, modifierFlags: [])
            app.terminate()
        }
    }

    func testAllThemesAndPagesRender() {
        launch()
        let themes = ["经典白色（默认）", "VS Code Dark Modern", "Tokyo Night", "Catppuccin Mocha", "Catppuccin Latte", "Nord", "Dracula", "One Dark Pro", "Gruvbox Dark", "Everforest", "Rosé Pine", "Solarized Light"]
        let pages = ["main", "editor", "settings", "session", "about", "shortcuts", "transfers", "metrics", "import"]
        for theme in themes {
            clickVisibleCenter(app.menuBars.menuBarItems["验收主题"])
            let item = app.menuItems[theme]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Missing theme: \(theme)")
            clickVisibleCenter(item)
            for page in pages {
                clickVisibleCenter(app.menuBars.menuBarItems["验收页面"])
                clickVisibleCenter(app.menuItems[page])
                XCTAssertTrue(app.windows.firstMatch.exists)
                XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 300)
                switch page {
                case "session":
                    XCTAssertTrue(app.textFields["会话名称"].waitForExistence(timeout: 3))
                    XCTAssertTrue(app.windows.buttons["保存"].firstMatch.exists)
                    XCTAssertTrue(app.windows.buttons["取消"].firstMatch.isHittable)
                case "editor":
                    XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 3))
                    XCTAssertTrue(app.windows.buttons["保存 (⌘S)"].firstMatch.isHittable)
                case "about":
                    XCTAssertTrue(app.windows.buttons["立即检查更新"].firstMatch.waitForExistence(timeout: 3))
                case "metrics":
                    let summary = app.buttons["metrics.summary"]
                    XCTAssertTrue(summary.waitForExistence(timeout: 3))
                    XCTAssertTrue(summary.label.contains("24.0%"),
                                  "Each theme must capture a fresh monitoring fixture")
                    clickVisibleCenter(summary)
                    let detail = app.staticTexts["metrics.detail.title"]
                    XCTAssertTrue(detail.waitForExistence(timeout: 3))
                    XCTAssertTrue(detail.isHittable)
                    for label in ["CPU", "内存", "磁盘", "网络"] {
                        XCTAssertTrue(staticText(label).exists, "Missing monitoring detail: " + label)
                    }
                    XCTAssertTrue(staticText("CPU 与内存历史 (%)").isHittable,
                                  "Monitoring history must be visible: " + theme)
                    capture("\(theme)-metrics-detail")
                    app.typeKey(.escape, modifierFlags: [])
                    let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: detail)
                    XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
                case "shortcuts":
                    let title = app.staticTexts["shortcuts.title"]
                    XCTAssertTrue(title.waitForExistence(timeout: 3))
                    XCTAssertTrue(title.isHittable, "Shortcuts header must be visible: " + theme)
                    XCTAssertTrue(app.buttons["shortcuts.close.header"].isHittable,
                                  "Shortcuts header close must be visible: " + theme)
                    XCTAssertTrue(app.buttons["shortcuts.close.footer"].isHittable,
                                  "Shortcuts footer close must be visible: " + theme)
                case "transfers":
                    XCTAssertTrue(staticText("暂无传输任务", comparison: "CONTAINS").waitForExistence(timeout: 3))
                case "import":
                    XCTAssertTrue(app.windows.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "导入选中的")).firstMatch.waitForExistence(timeout: 3))
                case "settings":
                    for tab in ["通用", "终端外观", "操作习惯", "SFTP传输", "数据备份"] {
                        let tabButton = app.tabs[tab]
                        XCTAssertTrue(tabButton.waitForExistence(timeout: 3), "Missing settings tab: \(tab)")
                        activateSettingsWindow()
                        clickVisibleCenter(tabButton)
                        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true OR value == 1 OR value == %@", "1"), object: tabButton)
                        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed, "Settings tab: \(tab), value: \(tabButton.value ?? "missing")")
                        switch tab {
                        case "通用":
                            XCTAssertTrue(app.windows.buttons["立即检查更新"].firstMatch.isHittable)
                        case "终端外观":
                            XCTAssertTrue(app.sliders.firstMatch.exists)
                        case "操作习惯", "SFTP传输":
                            XCTAssertGreaterThan(app.checkBoxes.count + app.switches.count, 0)
                        default:
                            XCTAssertGreaterThan(app.windows.buttons.count, 0)
                        }
                        capture("\(theme)-settings-\(tab)")
                    }
                default: break
                }
                capture("\(theme)-\(page)")
            }
        }
    }
}


@MainActor
final class IMEInputSourceSelection {
    private let original: TISInputSource
    private let originalEnabledIdentifiers: Set<String>
    private var temporarilyEnabled: [TISInputSource] = []
    private(set) var restorationEvidence = ""

    init() throws {
        // A previous test may have disabled a parent input method. HIToolbox's
        // process cache can then retain phantom mode IDs, so capture live state.
        let snapshot = Process()
        snapshot.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["APEX_UI_INPUT_SOURCE_RESTORER"]))
        snapshot.arguments = ["--snapshot"]
        let output = Pipe()
        snapshot.standardOutput = output
        snapshot.standardError = FileHandle.nullDevice
        try snapshot.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        snapshot.waitUntilExit()
        XCTAssertEqual(snapshot.terminationStatus, 0)
        let live = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let id = try XCTUnwrap(live["selected"] as? String)
        guard let key = kTISPropertyInputSourceID,
              let list = TISCreateInputSourceList([key: id] as CFDictionary, true),
              let source = (list.takeRetainedValue() as NSArray).firstObject else {
            throw NSError(domain: "ApexTerm.IMEAcceptance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The UI runner has no current system input source"])
        }
        original = source as! TISInputSource
        originalEnabledIdentifiers = Set(try XCTUnwrap(live["enabled"] as? [String]))
    }

    static func identifier(_ source: TISInputSource) -> String? {
        guard let key = kTISPropertyInputSourceID,
              let property = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    static func currentIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource() else { return nil }
        return identifier(source.takeRetainedValue())
    }

    func selectEnabled(_ identifier: String) throws {
        guard let key = kTISPropertyInputSourceID else {
            throw NSError(domain: "ApexTerm.IMEAcceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required enabled input source is unavailable: " + identifier])
        }
        func enabledSource(_ id: String) throws -> TISInputSource {
            guard let list = TISCreateInputSourceList([key: id] as CFDictionary, true),
                  let object = (list.takeRetainedValue() as NSArray).firstObject else {
                throw NSError(domain: "ApexTerm.IMEAcceptance", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Unavailable input source: " + id])
            }
            let source = object as! TISInputSource
            let status = TISEnableInputSource(source)
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            if !originalEnabledIdentifiers.contains(id), !temporarilyEnabled.contains(where: { Self.identifier($0) == id }) {
                temporarilyEnabled.append(source)
            }
            return source
        }
        if identifier == "com.apple.inputmethod.SCIM.ITABC" {
            _ = try enabledSource("com.apple.inputmethod.SCIM")
        }
        let source = try enabledSource(identifier)
        let status = TISSelectInputSource(source)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func restore() throws {
        let status = TISSelectInputSource(original)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        for source in temporarilyEnabled.reversed() {
            let result = TISDisableInputSource(source)
            guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        }
        temporarilyEnabled.removeAll()
        // Verify in a fresh process: HIToolbox retains a stale mode identifier in the
        // runner after disabling its parent, while the system creates PinyinKeyboard.
        let originalID = try XCTUnwrap(Self.identifier(original))
        let configuration = try JSONSerialization.data(withJSONObject: [originalID, Array(originalEnabledIdentifiers)]).base64EncodedString()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["APEX_UI_INPUT_SOURCE_RESTORER"]))
        process.arguments = [configuration]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ApexTerm.IMEAcceptance", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Fresh input-source restoration failed: " + errorText])
        }
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        let enabled = Set(try XCTUnwrap(report["enabled"] as? [String]))
        restorationEvidence = "Original selected: \(originalID)\nOriginal enabled: \(originalEnabledIdentifiers.sorted())\nRestored: \(report)"
        guard enabled == originalEnabledIdentifiers, report["selected"] as? String == originalID else {
            throw NSError(domain: "ApexTerm.IMEAcceptance", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Input sources not restored: \(report)"])
        }
    }

    private static func enabledIdentifiers() -> Set<String> {
        guard let list = TISCreateInputSourceList(nil, false) else { return [] }
        return Set((list.takeRetainedValue() as NSArray).compactMap { identifier($0 as! TISInputSource) })
    }
}
