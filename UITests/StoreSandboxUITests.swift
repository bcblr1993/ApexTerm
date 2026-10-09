import XCTest
import AppKit
import Darwin

/// Runs only against an isolated, signed App Sandbox QA bundle in macos27.
@MainActor
final class StoreSandboxUITests: XCTestCase, @unchecked Sendable {
    nonisolated deinit {}
    private var app: XCUIApplication?
    private var bundle: Bundle?
    private var appURL: URL?

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    nonisolated override func tearDownWithError() throws {
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated { runTearDown() }
    }

    private func runTearDown() {
        if let app, (testRun?.failureCount ?? 0) > 0 {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "store-sandbox-failure-tree"
            tree.lifetime = .keepAlways
            add(tree)
            capture("store-sandbox-failure")
        }
        app?.terminate()
    }

    private func launchSandboxQA() throws -> XCUIApplication {
        var size = 0
        XCTAssertEqual(sysctlbyname("hw.model", nil, &size, nil, 0), 0)
        var model = [CChar](repeating: 0, count: size)
        XCTAssertEqual(sysctlbyname("hw.model", &model, &size, nil, 0), 0)
        XCTAssertTrue(String(decoding: model.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix("VirtualMac"))
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["APEX_STORE_UI_APP_PATH"])
        let url = URL(fileURLWithPath: path)
        let metadata = try XCTUnwrap(Bundle(url: url))
        XCTAssertTrue(try XCTUnwrap(metadata.bundleIdentifier).hasPrefix("com.apexterm.qa.store."))
        XCTAssertEqual(metadata.object(forInfoDictionaryKey: "ApexDistributionChannel") as? String, "appStore")
        XCTAssertEqual(metadata.object(forInfoDictionaryKey: "ApexBuildPurpose") as? String, "sandboxQA")
        bundle = metadata
        appURL = url
        let application = XCUIApplication(url: url)
        app = application
        application.launch()
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 10))
        application.activate()
        application.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 180, dy: 8)).click()
        return application
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func launchDownloadDemo() throws -> XCUIApplication {
        let application = try launchSandboxQA()
        application.buttons["添加新的 SSH 会话"].firstMatch.click()
        let name = application.textFields["会话名称"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        paste("Save Panel Demo", into: name)
        let host = application.textFields["主机地址 / IP"].firstMatch
        paste("192.0.2.10", into: host)
        application.radioButtons["SSH 密钥 / Agent"].firstMatch.click()
        application.buttons["保存"].firstMatch.click()
        let connect = application.buttons["连接到 Save Panel Demo"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.click()
        XCTAssertTrue(application.staticTexts["nginx.conf"].firstMatch.waitForExistence(timeout: 10))
        return application
    }

    private func paste(_ text: String, into field: XCUIElement) {
        let board = NSPasteboard.general
        let previous = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            board.writeObjects(previous.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        board.clearContents()
        board.setString(text, forType: .string)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("v", modifierFlags: .command)
    }

    func testSandboxDownloadSavePanelCancel() throws {
        let application = try launchDownloadDemo()
        application.staticTexts["nginx.conf"].firstMatch.rightClick()
        application.menuItems["下载并保存…"].firstMatch.click()
        let panel = application.dialogs["save-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        capture("store-sandbox-download-save-panel")
        panel.buttons["CancelButton"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(application.staticTexts["下载完成: nginx.conf"].exists)

        let filter = application.textFields["筛选当前目录文件..."].firstMatch
        paste("bin", into: filter)
        let folder = application.staticTexts["bin"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        XCTAssertTrue(folder.isHittable)
        folder.rightClick()
        application.menuItems["下载并保存…"].firstMatch.click()
        let directory = application.dialogs["open-panel"].firstMatch
        XCTAssertTrue(directory.waitForExistence(timeout: 5), "Directory downloads must also request a user-selected destination")
        directory.buttons["CancelButton"].click()
        XCTAssertTrue(directory.waitForNonExistence(timeout: 5))
    }

    func testSandboxDownloadSavesToUserSelectedFile() throws {
        let application = try launchDownloadDemo()
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let destination = downloads.appendingPathComponent("aetherterm-save-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        application.staticTexts["nginx.conf"].firstMatch.rightClick()
        application.menuItems["下载并保存…"].firstMatch.click()
        let panel = application.dialogs["save-panel"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        application.typeKey("g", modifierFlags: [.command, .shift])
        let path = application.sheets.textFields.firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        paste(destination.path, into: path)
        application.typeKey(.return, modifierFlags: [])
        panel.buttons["OKButton"].click()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: destination) else { return false }
            return String(decoding: data, as: UTF8.self).contains("nginx.conf")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        XCTAssertTrue(application.staticTexts["下载完成: nginx.conf"].firstMatch.waitForExistence(timeout: 5))
        capture("store-sandbox-download-saved-outside-container")
    }

    func testSandboxAboutPrivacyLink() throws {
        try run_testSandboxAboutPrivacyLink()
    }

    private func run_testSandboxAboutPrivacyLink() throws {
        let application = try launchSandboxQA()
        let appName = try XCTUnwrap(bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let menu = application.menuBars.menuBarItems[appName]
        XCTAssertTrue(menu.exists)
        menu.click()
        let about = application.menuItems["关于 AetherTerm"].firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let privacy = application.descendants(matching: .any).matching(identifier: "about.privacy").firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        XCTAssertTrue(privacy.isHittable, "The actual sandboxed About window must expose the privacy link")
        capture("store-sandbox-about-privacy")
        application.buttons["关闭"].firstMatch.click()
        XCTAssertTrue(privacy.waitForNonExistence(timeout: 5))
    }

    func testSandboxNewSessionPrivateKeyPickerCancel() throws {
        try run_testSandboxNewSessionPrivateKeyPickerCancel()
    }

    private func run_testSandboxNewSessionPrivateKeyPickerCancel() throws {
        let application = try launchSandboxQA()
        let addSession = application.buttons["添加新的 SSH 会话"].firstMatch
        if !addSession.exists || !addSession.isHittable {
            let sidebar = application.buttons.matching(NSPredicate(
                format: "label == 'Show Sidebar' OR label == '显示边栏' OR label == '显示侧边栏'")).firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            sidebar.click()
        }
        XCTAssertTrue(addSession.waitForExistence(timeout: 5))
        XCTAssertTrue(addSession.isHittable)
        addSession.click()
        let keyOption = application.radioButtons["指定私钥"].firstMatch
        XCTAssertTrue(keyOption.waitForExistence(timeout: 5), "A new Store session must allow user-selected key files")
        keyOption.click()
        let path = application.textFields["session.privateKeyPath"].firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        let initial = path.value as? String
        application.buttons["浏览..."].firstMatch.click()
        let picker = application.dialogs["open-panel"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Use the real macOS file picker inside App Sandbox")
        XCTAssertTrue(picker.buttons["OKButton"].exists)
        capture("store-sandbox-private-key-picker")
        picker.buttons["CancelButton"].click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        XCTAssertTrue(path.exists)
        XCTAssertEqual(path.value as? String, initial, "Cancel must not change the key path or save a file grant")
        application.buttons["取消"].firstMatch.click()
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
    }

    func testSandboxMainWindowReopens() throws {
        try run_testSandboxMainWindowReopens()
    }

    private func run_testSandboxMainWindowReopens() throws {
        let application = try launchSandboxQA()
        application.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in application.windows.count == 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertNotEqual(application.state, .notRunning)
        application.activate()
        let windowMenu = application.menuBars.menuBarItems.matching(NSPredicate(
            format: "title == 'Window' OR title == '窗口' OR label == 'Window' OR label == '窗口'")).firstMatch
        XCTAssertTrue(windowMenu.exists)
        windowMenu.click()
        let showMain = application.menuItems["显示主窗口"].firstMatch
        XCTAssertTrue(showMain.waitForExistence(timeout: 5))
        XCTAssertTrue(showMain.isEnabled, "The main-window menu must remain enabled after the last window closes")
        showMain.click()
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 10))
        windowMenu.click()
        application.menuItems["显示主窗口"].firstMatch.click()
        XCTAssertEqual(application.windows.count, 1, "Showing the main window must not create duplicate workspaces")
        application.typeKey("0", modifierFlags: [.command, .shift])
        XCTAssertEqual(application.windows.count, 1, "Showing the main window must not create duplicate workspaces")
        capture("store-sandbox-main-window-reopened")
    }
}
