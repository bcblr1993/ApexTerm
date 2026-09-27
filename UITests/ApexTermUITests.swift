import XCTest

/// Drives an isolated QA host linked to the same product modules as the release.
@MainActor
final class ApexTermUITests: XCTestCase {
    private var app: XCUIApplication!

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        if (testRun?.failureCount ?? 0) > 0, let app, app.state == .runningForeground {
            capture("failure-" + name)
        }
        app?.terminate()
    }

    private func launch(_ scene: String = "main", extra: [String: String] = [:]) {
        app = XCUIApplication(bundleIdentifier: "com.apexterm.qa.verification")
        app.launchEnvironment = ["APEX_QA_SCENE": scene, "APEX_QA_DISABLE_TELEMETRY": "1", "APEX_QA_UI_RUN_ID": UUID().uuidString]
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
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 台主机")).firstMatch.exists)
    }

    func testSessionValidPortRecoveryAndSave() {
        launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "添加新的 SSH 会话")).firstMatch.click()
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
        let save = app.buttons["保存"]
        XCTAssertFalse(save.isEnabled)
        port.typeKey("a", modifierFlags: .command)
        port.typeText("2222")
        XCTAssertTrue(save.isEnabled)
        save.click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 台主机")).firstMatch.waitForExistence(timeout: 5))
        let search = app.textFields.matching(NSPredicate(format: "label CONTAINS %@", "搜索会话")).firstMatch
        search.click()
        search.typeText("UI saved synthetic")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "UI saved synthetic")).firstMatch.waitForExistence(timeout: 5))
        capture("session-saved-and-searchable")
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

    func testSFTPFilterEmptyClearAndEscape() {
        launch("main", extra: ["APEX_QA_FILES": "normal", "APEX_QA_CONNECT": "1"])
        let file = app.staticTexts["nginx.conf"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "筛选")).firstMatch
        XCTAssertTrue(toggle.isHittable)
        toggle.click()
        let filter = app.textFields["筛选当前目录文件..."]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeText("UI_NO_MATCH_FILE")
        XCTAssertTrue(app.staticTexts["没有匹配的文件"].waitForExistence(timeout: 5))
        XCTAssertFalse(file.exists)
        capture("sftp-filter-no-match")
        app.buttons["清除文件筛选"].click()
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertEqual(filter.value as? String, "")
        filter.click()
        filter.typeText("nginx")
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["docker-compose.yml"].exists)
        filter.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(filter.exists)
        XCTAssertTrue(app.staticTexts["docker-compose.yml"].waitForExistence(timeout: 5))
        capture("sftp-filter-escape-restored")
    }

    func testSFTPDirectoryFailureRetryRecovers() {
        launch("main", extra: ["APEX_QA_FILES": "failure-once", "APEX_QA_CONNECT": "1"])
        let failure = app.staticTexts["无法读取远程文件"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10))
        let retry = app.buttons["重试"]
        XCTAssertTrue(retry.isHittable)
        XCTAssertFalse(app.staticTexts["nginx.conf"].exists)
        capture("sftp-before-retry")
        retry.click()
        XCTAssertTrue(app.staticTexts["nginx.conf"].waitForExistence(timeout: 10))
        XCTAssertFalse(failure.exists)
        XCTAssertFalse(retry.exists)
        capture("sftp-retry-restored")
    }

    func testSFTPPathDraftCancelEmptyAndSubmit() {
        launch("main", extra: ["APEX_QA_FILES": "normal", "APEX_QA_CONNECT": "1"])
        XCTAssertTrue(app.staticTexts["nginx.conf"].waitForExistence(timeout: 10))
        let path = app.textFields["远程路径"]
        XCTAssertTrue(path.exists)
        let original = path.value as? String
        XCTAssertNotNil(original)
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText("/ui-unsubmitted-draft")
        path.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertEqual(path.value as? String, original)
        XCTAssertTrue(app.staticTexts["nginx.conf"].exists)
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText("   ")
        path.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertEqual(path.value as? String, original)
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText("  /ui-synthetic-directory  ")
        path.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let submitted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "/ui-synthetic-directory"), object: path)
        XCTAssertEqual(XCTWaiter.wait(for: [submitted], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["nginx.conf"].waitForExistence(timeout: 10))
        capture("sftp-path-submitted")
    }

    func testTerminalSplitOrientationAndClose() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
        let split = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "分屏")).firstMatch
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
        app.buttons["关闭此分屏"].firstMatch.click()
        let onePane = XCTNSPredicateExpectation(predicate: NSPredicate { [app] _, _ in
            app?.textViews.count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [onePane], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["关闭此分屏"].exists)
        capture("terminal-split-closed")
    }

    func testSSHConfigImportSelectionAndDuplicateRecovery() {
        launch("import")
        let selected = app.buttons["导入选中的 1 台主机"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertTrue(selected.isEnabled)
        app.buttons["取消全选"].click()
        XCTAssertFalse(app.buttons["导入选中的 0 台主机"].isEnabled)
        app.buttons["全选"].click()
        XCTAssertTrue(selected.isEnabled)
        selected.click()
        let notice = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已成功导入 1 台主机")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        capture("ssh-config-import-success")
        app.menuBars.menuBarItems["验收页面"].click()
        app.menuItems["main"].click()
        let twoHosts = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 台主机")).firstMatch
        XCTAssertTrue(twoHosts.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["验收页面"].click()
        app.menuItems["import"].click()
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        selected.click()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["验收页面"].click()
        app.menuItems["main"].click()
        XCTAssertTrue(twoHosts.waitForExistence(timeout: 5), "Reimport must update the existing session rather than duplicate it")
        let search = app.textFields.matching(NSPredicate(format: "label CONTAINS %@", "搜索会话")).firstMatch
        search.click()
        search.typeText("qa-demo")
        XCTAssertTrue(app.staticTexts["qa-demo"].waitForExistence(timeout: 5))
        capture("ssh-config-import-deduplicated")
    }

    func testSSHConfigImportSheetCancelDoesNotImport() {
        launch("import-sheet")
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["导入选中的 1 台主机"].isEnabled)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertFalse(app.sheets.firstMatch.exists)
        app.buttons["显示导入弹窗"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.buttons["取消"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
        app.menuBars.menuBarItems["验收页面"].click()
        app.menuItems["main"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 台主机")).firstMatch.waitForExistence(timeout: 5))
        let search = app.textFields.matching(NSPredicate(format: "label CONTAINS %@", "搜索会话")).firstMatch
        search.click()
        search.typeText("qa-demo")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "未找到匹配会话")).firstMatch.waitForExistence(timeout: 5))
        capture("ssh-config-cancel-no-import")
    }

    func testSFTPCreateFileCancelAndSuccessfulListing() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        XCTAssertTrue(app.staticTexts["nginx.conf"].waitForExistence(timeout: 10))
        let more = app.buttons["更多文件操作"]
        XCTAssertTrue(more.isHittable)
        more.click()
        app.menuItems["新建文件"].click()
        let name = app.textFields["文件名 (例如 test.sh)"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-canceled-file.txt")
        app.buttons["取消"].click()
        XCTAssertFalse(app.staticTexts["ui-canceled-file.txt"].exists)
        more.click()
        app.menuItems["新建文件"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-created-file.txt")
        app.buttons["创建"].click()
        XCTAssertTrue(app.staticTexts["ui-created-file.txt"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["ui-canceled-file.txt"].exists)
        XCTAssertTrue(app.staticTexts["nginx.conf"].exists)
        capture("sftp-create-file-listed")
    }

    func testSFTPRenameCancelAndSuccessfulListing() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        let original = app.staticTexts["nginx.conf"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        original.click()
        original.rightClick()
        app.menuItems["重命名..."].click()
        let name = app.textFields["新名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("ui-canceled-name.conf")
        app.buttons["取消"].click()
        XCTAssertTrue(original.exists)
        XCTAssertFalse(app.staticTexts["ui-canceled-name.conf"].exists)
        original.click()
        original.rightClick()
        app.menuItems["重命名..."].click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("ui-renamed.conf")
        app.buttons["确定"].click()
        XCTAssertTrue(app.staticTexts["ui-renamed.conf"].waitForExistence(timeout: 10))
        XCTAssertFalse(original.exists)
        XCTAssertTrue(app.staticTexts["docker-compose.yml"].exists)
        capture("sftp-renamed-file-listed")
    }

    func testSFTPCreateFolderCancelAndSuccessfulListing() {
        launch("main", extra: ["APEX_QA_CONNECT": "1"])
        XCTAssertTrue(app.staticTexts["nginx.conf"].waitForExistence(timeout: 10))
        let more = app.buttons["更多文件操作"]
        more.click()
        app.menuItems["新建文件夹"].click()
        let name = app.textFields["文件夹名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("ui-canceled-folder")
        app.buttons["取消"].click()
        XCTAssertFalse(app.staticTexts["ui-canceled-folder"].exists)
        more.click()
        app.menuItems["新建文件夹"].click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("  ui-created-folder  ")
        app.buttons["创建"].click()
        let folder = app.staticTexts["ui-created-folder"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["ui-canceled-folder"].exists)
        XCTAssertTrue(app.staticTexts["nginx.conf"].exists)
        capture("sftp-create-folder-listed")
        folder.doubleClick()
        let path = app.textFields["远程路径"]
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value ENDSWITH %@", "/ui-created-folder"), object: path)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 10), .completed)
        capture("sftp-created-folder-entered")
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

    func testEditorUnsavedCancelSaveAndClose() {
        launch("editor-sheet")
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nui_acceptance=true")
        app.buttons["关闭"].click()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        capture("editor-unsaved-close")
        app.buttons["继续编辑"].click()
        XCTAssertTrue(app.sheets.firstMatch.exists)
        let save = app.buttons["保存 (⌘S)"]
        save.click()
        XCTAssertFalse(save.isEnabled)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已保存并上传至服务器")).firstMatch.waitForExistence(timeout: 5))
        capture("editor-save-completed")
        app.buttons["关闭"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testEditorSaveFailureKeepsChanges() {
        launch("editor-sheet", extra: ["APEX_QA_EDITOR_SAVE": "failure"])
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nkeep_after_failure=true")
        app.buttons["保存 (⌘S)"].click()
        let failed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "权限不足")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String)?.contains("keep_after_failure=true") == true)
        capture("editor-save-failure")
        app.buttons["关闭"].click()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].click()
    }

    func testEditorSaveFailureRetryRecovers() {
        launch("editor-sheet", extra: ["APEX_QA_EDITOR_SAVE": "failure-once"])
        let editor = app.textViews["文件内容"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nretry_revision=true")
        let save = app.buttons["保存 (⌘S)"]
        save.click()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "保存失败:")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue((editor.value as? String)?.contains("retry_revision=true") == true)
        save.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已保存并上传至服务器")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(error.exists)
        XCTAssertTrue((editor.value as? String)?.contains("retry_revision=true") == true)
        capture("editor-save-retry-recovered")
        app.buttons["关闭"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.buttons["继续编辑"].exists)
    }

    func testEditorChangesDuringSaveRemainUnsaved() {
        launch("editor-sheet", extra: ["APEX_QA_EDITOR_SAVE_DELAY": "8"])
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nfirst_revision=true")
        let save = app.buttons["保存 (⌘S)"]
        save.click()
        XCTAssertFalse(save.isEnabled)
        editor.click()
        editor.typeText("\nsecond_revision=true")
        let pending = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "仍有新更改待保存")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 20))
        XCTAssertTrue((editor.value as? String)?.contains("second_revision=true") == true)
        app.buttons["关闭"].click()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        capture("editor-save-preserves-new-changes")
        app.buttons["继续编辑"].click()
        save.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已保存并上传至服务器")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["关闭"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
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
        find.typeText("keyboard_revision")
        XCTAssertEqual(find.value as? String, "keyboard_revision")
        XCTAssertEqual(editor.value as? String, edited, "Searching must not modify file contents")
        capture("editor-native-find")
        editor.click()
        editor.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已保存并上传至服务器")).firstMatch.waitForExistence(timeout: 10))
        editor.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testEditorReloadCancelAndDiscard() {
        launch("editor-sheet")
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nunsaved_reload_marker=true")
        let reload = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "重新加载")).firstMatch
        XCTAssertTrue(reload.isHittable)
        reload.click()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].click()
        XCTAssertTrue((editor.value as? String)?.contains("unsaved_reload_marker=true") == true)
        reload.click()
        XCTAssertTrue(app.buttons["放弃更改"].waitForExistence(timeout: 5))
        app.buttons["放弃更改"].click()
        let remote = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ AND NOT value CONTAINS %@", "远端配置", "unsaved_reload_marker"), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [remote], timeout: 10), .completed)
        capture("editor-reloaded")
        app.buttons["关闭"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
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
                switch page {
                case "session":
                    XCTAssertTrue(app.textFields["会话名称"].waitForExistence(timeout: 3))
                    XCTAssertTrue(app.buttons["保存"].exists)
                    XCTAssertTrue(app.buttons["取消"].isHittable)
                case "editor":
                    XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 3))
                    XCTAssertTrue(app.buttons["保存 (⌘S)"].isHittable)
                case "about":
                    XCTAssertTrue(app.buttons["立即检查更新"].waitForExistence(timeout: 3))
                case "transfers":
                    XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "暂无传输任务")).firstMatch.waitForExistence(timeout: 3))
                case "import":
                    XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "导入选中的")).firstMatch.waitForExistence(timeout: 3))
                case "settings":
                    for tab in ["通用", "终端外观", "操作习惯", "SFTP传输", "数据备份"] {
                        let tabButton = app.radioButtons[tab]
                        XCTAssertTrue(tabButton.waitForExistence(timeout: 3), "Missing settings tab: \(tab)")
                        tabButton.click()
                        XCTAssertTrue(tabButton.isSelected)
                        switch tab {
                        case "通用":
                            XCTAssertTrue(app.buttons["立即检查更新"].isHittable)
                        case "终端外观":
                            XCTAssertTrue(app.sliders.firstMatch.exists)
                        case "操作习惯", "SFTP传输":
                            XCTAssertGreaterThan(app.checkBoxes.count + app.switches.count, 0)
                        default:
                            XCTAssertGreaterThan(app.buttons.count, 0)
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
