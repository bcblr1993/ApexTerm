import XCTest
import Carbon

/// Drives an isolated QA host linked to the same product modules as the release.
@MainActor
final class ApexTermUITests: XCTestCase {
    private var app: XCUIApplication!
    private var ownedRemoteDirectory: String?
    private var inputSourceToRestore: IMEInputSourceSelection?

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        if (testRun?.failureCount ?? 0) > 0, let app, app.state == .runningForeground {
            capture("failure-" + name)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "failure-accessibility-tree"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
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
            cleanup.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "\(user)@\(host)",
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
        app.launchEnvironment = ["APEX_QA_SCENE": scene, "APEX_QA_DISABLE_TELEMETRY": "1", "APEX_QA_UI_RUN_ID": UUID().uuidString]
            .merging(extra) { _, new in new }
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            app.launchEnvironment["SSH_AUTH_SOCK"] = socket
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
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

    private func activateSettingsWindow() {
        app.activate()
        // A persistent menu-bar popover can leave the app's AX tree disabled.
        // Settings has no modal sheet here; Escape only dismisses that transient blocker.
        if !app.isEnabled {
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            app.activate()
        }
        XCTAssertTrue(app.isEnabled, "Settings input must not be blocked by another menu or popover")
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
        XCTAssertTrue(app.windows.buttons["前往下载更新"].firstMatch.isHittable)
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
        let split = app.menuButtons["rectangle.split.2x1"].firstMatch
        XCTAssertTrue(split.isHittable)
        split.click()
        app.menuItems["垂直分屏"].click()
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
        app.menuItems["水平分屏"].click()
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
        app.menuBars.menuBarItems["验收操作"].click()
        app.menuItems["断开测试终端"].click()
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
        app.menuBars.menuBarItems["验收页面"].click()
        app.menuItems["main"].click()
        let twoHosts = staticText("2 台主机", comparison: "CONTAINS")
        XCTAssertTrue(twoHosts.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["验收页面"].click()
        app.menuItems["import-sheet"].click()
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        selected.click()
        let secondSheetClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.sheets.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [secondSheetClosed], timeout: 5), .completed)
        app.menuBars.menuBarItems["验收页面"].click()
        app.menuItems["main"].click()
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
        app.menuBars.menuBarItems["验收页面"].click()
        app.menuItems["main"].click()
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

    func testSFTPCreateFileCancelAndSuccessfulListing() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        XCTAssertTrue(staticText("nginx.conf").waitForExistence(timeout: 10))
        let more = app.menuButtons["ellipsis"].firstMatch
        XCTAssertTrue(more.isHittable)
        more.click()
        app.menuItems["新建文件"].click()
        let name = app.textFields["文件名 (例如 test.sh)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-canceled-file.txt")
        app.windows.buttons["取消"].firstMatch.click()
        XCTAssertFalse(staticText("ui-canceled-file.txt").exists)
        more.click()
        app.menuItems["新建文件"].click()
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
        app.menuItems["重命名..."].click()
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
        app.menuItems["重命名..."].click()
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
        app.menuItems["新建文件夹"].click()
        let name = app.textFields["文件夹名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-canceled-folder")
        app.windows.buttons["取消"].firstMatch.click()
        XCTAssertFalse(staticText("ui-canceled-folder").exists)
        more.click()
        app.menuItems["新建文件夹"].click()
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
        app.menuItems["显示隐藏文件"].click()
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
        app.menuItems["新建文件"].click()
        let name = app.textFields["文件名 (例如 test.sh)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-own-delete-fixture.txt")
        app.windows.buttons["创建"].firstMatch.click()
        let fixture = staticText("ui-own-delete-fixture.txt")
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))
        fixture.click()
        fixture.rightClick()
        app.menuItems["删除"].click()
        let confirm = app.windows.buttons["永久删除「ui-own-delete-fixture.txt」"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture("sftp-delete-confirmation")
        app.windows.buttons["取消"].firstMatch.click()
        XCTAssertTrue(fixture.exists)
        XCTAssertFalse(confirm.exists)
        fixture.click()
        fixture.rightClick()
        app.menuItems["删除"].click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: fixture)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertTrue(staticText("nginx.conf").exists)
        capture("sftp-own-fixture-deleted")
    }

    func testRealSSHBuiltinPinyinCompositionAndCommit() throws {
        let environment = ProcessInfo.processInfo.environment
        let host = try XCTUnwrap(environment["APEX_UI_TEST_HOST"])
        let user = try XCTUnwrap(environment["APEX_UI_TEST_USER"])
        launch("main", extra: ["APEX_QA_REAL_HOST": host, "APEX_QA_REAL_USER": user, "APEX_QA_CONNECT": "1"])
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
        app.typeText("read -r apex_ui_ime; printf '\\nAPEX_UI_IME:%s\\n' \"$apex_ui_ime\"\n")
        try inputSource.selectEnabled("com.apple.inputmethod.SCIM.ITABC")
        app.textFields.firstMatch.click()
        terminal.click()
        XCTAssertEqual(IMEInputSourceSelection.currentIdentifier(), "com.apple.inputmethod.SCIM.ITABC")
        let outputBeforeComposition = terminal.value as? String
        app.typeText("zhongwen")
        let composition = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        composition.name = "real-system-pinyin-composition-and-candidates"
        composition.lifetime = .keepAlways
        add(composition)
        XCTAssertEqual(terminal.value as? String, outputBeforeComposition,
                       "No partial Pinyin preedit may enter the remote shell before candidate commit")
        app.typeKey(" ", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
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
        app.menuBars.menuBarItems["验收操作"].click()
        app.menuItems["断开测试终端"].click()
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
        app.menuItems["新建文件"].click()
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
        app.menuItems["快速查看 / 编辑"].click()
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
        app.menuItems["删除"].click()
        let delete = app.windows.buttons["永久删除「ui-real-file.txt」"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        XCTAssertTrue(staticText("文件夹为空").waitForExistence(timeout: 15))
        terminal.click()
        terminal.typeText("rmdir '\(directory)' && printf '\\nAPEX_UI_FIXTURE_CLEAN_OK\\n'\n")
        let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "\nAPEX_UI_FIXTURE_CLEAN_OK\n"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [cleaned], timeout: 15), .completed)
        ownedRemoteDirectory = nil
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
        launch("settings")
        app.menuBars.menuBarItems["验收主题"].click()
        clickVisibleCenter(app.menuItems["Catppuccin Mocha"])
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

    func testAllThemesAndPagesRender() {
        launch()
        let themes = ["经典白色（默认）", "VS Code Dark Modern", "Tokyo Night", "Catppuccin Mocha", "Catppuccin Latte", "Nord", "Dracula", "One Dark Pro", "Gruvbox Dark", "Everforest", "Rosé Pine", "Solarized Light"]
        let pages = ["main", "editor", "settings", "session", "about", "shortcuts", "transfers", "metrics", "import"]
        for theme in themes {
            app.menuBars.menuBarItems["验收主题"].click()
            let item = app.menuItems[theme]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Missing theme: \(theme)")
            clickVisibleCenter(item)
            for page in pages {
                app.menuBars.menuBarItems["验收页面"].click()
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
        guard let source = TISCopyCurrentKeyboardInputSource() else {
            throw NSError(domain: "ApexTerm.IMEAcceptance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The UI runner has no current system input source"])
        }
        original = source.takeRetainedValue()
        originalEnabledIdentifiers = Self.enabledIdentifiers()
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
            if !Self.enabledIdentifiers().contains(id) {
                let status = TISEnableInputSource(source)
                guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
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
