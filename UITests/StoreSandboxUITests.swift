import XCTest
import AppKit
import Darwin

/// Runs only against an isolated, signed App Sandbox QA bundle in macos27.
@MainActor
final class StoreSandboxUITests: XCTestCase {
    private var app: XCUIApplication?
    private var bundle: Bundle?
    private var appURL: URL?

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
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

    func testSandboxAboutPrivacyLink() throws {
        let application = try launchSandboxQA()
        let appName = try XCTUnwrap(bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let menu = application.menuBars.menuBarItems[appName]
        XCTAssertTrue(menu.exists)
        menu.click()
        let about = application.menuItems["关于 ApexTerm"].firstMatch
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
        let open = application.buttons.matching(NSPredicate(format: "label == '打开' OR label == 'Open'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Use the real macOS file picker inside App Sandbox")
        capture("store-sandbox-private-key-picker")
        application.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(open.waitForNonExistence(timeout: 5))
        XCTAssertTrue(path.exists)
        XCTAssertEqual(path.value as? String, initial, "Cancel must not change the key path or save a file grant")
        application.buttons["取消"].firstMatch.click()
        XCTAssertTrue(path.waitForNonExistence(timeout: 5))
    }

    func testSandboxMainWindowReopens() throws {
        let application = try launchSandboxQA()
        application.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in application.windows.count == 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reopen.arguments = ["-a", try XCTUnwrap(appURL).path]
        try reopen.run()
        reopen.waitUntilExit()
        XCTAssertEqual(reopen.terminationStatus, 0)
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 10))
        capture("store-sandbox-main-window-reopened")
    }
}
