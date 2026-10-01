import XCTest
@testable import ApexCore

@MainActor
final class AppStoreUpdateTests: XCTestCase {
    func testStoreChecksNeverContactGitHub() async {
        let calls = UpdateCalls()
        let manager = UpdateManager(distributionChannel: .appStore, fetch: { request in
            await calls.record()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
        await manager.checkForUpdates()
        await manager.checkForUpdates(manual: true)
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(manager.isChecking)
        XCTAssertNil(manager.lastCheckedDate)
        XCTAssertNil(manager.latestRelease)
        XCTAssertFalse(manager.isUpdateSheetPresented)
    }

    func testStoreRejectsExplicitWebsitePackageBeforeDownloading() async {
        let calls = UpdateCalls()
        let manager = UpdateManager(distributionChannel: .appStore, fetch: { _ in
            throw URLError(.unsupportedURL)
        }, downloadHandler: { _, _ in
            await calls.record()
            throw URLError(.unsupportedURL)
        })
        let release = ReleaseInfo(version: "9.0.0", releaseDate: "2026-10-02", title: "Fixture", notes: "",
                                  downloadUrl: "https://example.com/ApexTerm.tar.gz")
        await manager.startInAppUpdate(release: release)
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(manager.isDownloading)
        XCTAssertNil(manager.currentStagedAppURL)
        XCTAssertFalse(manager.isUpdateSheetPresented)
        guard case .failed(let message) = manager.status else { return XCTFail("Store packages must not invoke website installation") }
        XCTAssertTrue(message.contains("App Store"))
    }

    func testStoreRejectsStagedInstallBeforeWritingRelaunchScript() {
        let manager = UpdateManager(distributionChannel: .appStore)
        manager.status = .readyToRestart(version: "9.0.0", stagingAppURL: URL(fileURLWithPath: "/nonexistent/apexterm-store-fixture.app"))
        manager.relaunchAndInstall(targetURL: URL(fileURLWithPath: "/nonexistent/apexterm-store-target.app"))
        guard case .failed(let message) = manager.status else { return XCTFail("A stale stage cannot replace an App Store app") }
        XCTAssertTrue(message.contains("App Store"))
    }
}

private actor UpdateCalls {
    private(set) var count = 0
    func record() { count += 1 }
}
