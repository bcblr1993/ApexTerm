import XCTest
@testable import ApexCore

@MainActor
final class UpdateCheckTests: XCTestCase {
    func testManualHTTPErrorIsFailure() async {
        let manager = UpdateManager { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        await manager.checkForUpdates(manual: true)
        guard case .failed = manager.status else { return XCTFail("HTTP failure must not report latest") }
        XCTAssertTrue(manager.isUpdateSheetPresented)
        XCTAssertFalse(manager.isChecking)
    }

    func testMalformedSuccessResponseIsFailure() async {
        let manager = UpdateManager { request in
            (Data("invalid json".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await manager.checkForUpdates(manual: true)
        guard case .failed = manager.status else { return XCTFail("Invalid response must not report latest") }
        XCTAssertFalse(manager.isChecking)
    }

    func testInvalidReleaseVersionsFailWithoutReportingLatest() async throws {
        for version in ["", "v", "---", "v1.two.3", "v1..3", "v-1.2.3"] {
            let data = try JSONSerialization.data(withJSONObject: ["tag_name": version, "html_url": "https://example.com/release"])
            let manager = UpdateManager { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            await manager.checkForUpdates(manual: true)
            guard case .failed = manager.status else { return XCTFail("Invalid version accepted: \(version)") }
            XCTAssertFalse(manager.isChecking)
            XCTAssertNil(manager.latestRelease)
        }
        XCTAssertFalse(UpdateManager.isVersion("", higherThan: "1.2.0"))
        XCTAssertFalse(UpdateManager.isVersion("1.2.0", higherThan: ""))
    }

    func testManualNetworkFailureIsFailure() async {
        let manager = UpdateManager { _ in throw URLError(.notConnectedToInternet) }
        await manager.checkForUpdates(manual: true)
        guard case .failed = manager.status else { return XCTFail("Offline must not report latest") }
        XCTAssertTrue(manager.isUpdateSheetPresented)
        XCTAssertFalse(manager.isChecking)
    }

    func testLoadingSheetAndDuplicateRequestGuard() async {
        let gate = UpdateRequestGate()
        let manager = UpdateManager { request in
            await gate.request()
            return (Data(#"{"tag_name":"v0.0.1","html_url":"https://example.com/release"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let task = Task { await manager.checkForUpdates(manual: true) }
        while await gate.count == 0 { await Task.yield() }
        XCTAssertEqual(manager.status, .checking)
        XCTAssertTrue(manager.isChecking)
        XCTAssertTrue(manager.isUpdateSheetPresented)
        await manager.checkForUpdates(manual: true)
        let count = await gate.count
        XCTAssertEqual(count, 1)
        await gate.release()
        await task.value
        XCTAssertEqual(manager.status, .upToDate(currentVersion: manager.currentVersion))
        XCTAssertFalse(manager.isChecking)
    }

    func testGitHubReleaseAssetParsing() async throws {
        let json = """
        {
          "tag_name": "v2.0.0",
          "name": "ApexTerm v2.0.0",
          "body": "Major release notes",
          "published_at": "2026-09-28T12:00:00Z",
          "html_url": "https://github.com/bcblr1993/ApexTerm/releases/tag/v2.0.0",
          "assets": [
            {
              "name": "ApexTerm-v2.0.0-macos-arm64.dmg",
              "size": 3100000,
              "browser_download_url": "https://example.com/ApexTerm-v2.0.0-macos-arm64.dmg"
            },
            {
              "name": "ApexTerm-v2.0.0-macos-arm64.tar.gz",
              "size": 2800000,
              "browser_download_url": "https://example.com/ApexTerm-v2.0.0-macos-arm64.tar.gz"
            }
          ]
        }
        """
        let manager = UpdateManager { request in
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await manager.checkForUpdates(manual: true)
        guard case .updateAvailable(let release) = manager.status else {
            return XCTFail("Expected updateAvailable status, got \(manager.status)")
        }
        XCTAssertEqual(release.version, "2.0.0")
        XCTAssertEqual(release.packageName, "ApexTerm-v2.0.0-macos-arm64.tar.gz")
        XCTAssertEqual(release.packageUrl, "https://example.com/ApexTerm-v2.0.0-macos-arm64.tar.gz")
        XCTAssertEqual(release.packageSize, 2800000)
    }

    func testStartInAppUpdateFlowWithProgressAndStaging() async throws {
        let tempAppDir = FileManager.default.temporaryDirectory.appendingPathComponent("MockStagedApp_\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: tempAppDir, withIntermediateDirectories: true)

        let mockDownloader: UpdateManager.DownloadHandler = { url, onProgress in
            onProgress(500, 1000)
            onProgress(1000, 1000)
            let tempArchive = FileManager.default.temporaryDirectory.appendingPathComponent("mock_archive_\(UUID().uuidString).tar.gz")
            try Data("mock archive content".utf8).write(to: tempArchive)
            return tempArchive
        }

        let mockExtractor: UpdateManager.ExtractHandler = { archiveURL, version in
            return tempAppDir
        }

        let manager = UpdateManager(
            fetch: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) },
            downloadHandler: mockDownloader,
            extractHandler: mockExtractor
        )

        let testRelease = ReleaseInfo(
            version: "2.0.0",
            releaseDate: "2026-09-28",
            title: "Test Release",
            notes: "Test notes",
            downloadUrl: "https://example.com",
            packageUrl: "https://example.com/ApexTerm.tar.gz",
            packageName: "ApexTerm.tar.gz",
            packageSize: 1000
        )

        await manager.startInAppUpdate(release: testRelease)

        guard case .readyToRestart(let version, let stagingURL) = manager.status else {
            return XCTFail("Expected readyToRestart status, got \(manager.status)")
        }
        XCTAssertEqual(version, "2.0.0")
        XCTAssertEqual(stagingURL, tempAppDir)
        XCTAssertFalse(manager.isDownloading)

        try? FileManager.default.removeItem(at: tempAppDir)
    }

    func testCancelUpdateRestoresAvailableState() async throws {
        let manager = UpdateManager(
            fetch: { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        )
        let testRelease = ReleaseInfo(
            version: "2.0.0",
            releaseDate: "2026-09-28",
            title: "Test Release",
            notes: "Test notes",
            downloadUrl: "https://example.com",
            packageUrl: "https://example.com/ApexTerm.tar.gz",
            packageName: "ApexTerm.tar.gz",
            packageSize: 1000
        )
        manager.latestRelease = testRelease
        manager.isDownloading = true
        manager.status = .downloading(progress: 0.5, totalBytes: 1000, receivedBytes: 500)

        manager.cancelUpdate()

        XCTAssertFalse(manager.isDownloading)
        XCTAssertEqual(manager.status, .updateAvailable(testRelease))
    }

    func testExtractionFailsGracefullyWithCorruptedArchive() async throws {
        let corruptFile = FileManager.default.temporaryDirectory.appendingPathComponent("corrupted_\(UUID().uuidString).tar.gz")
        try Data("not a gzip file".utf8).write(to: corruptFile)

        XCTAssertThrowsError(try UpdateManager.defaultExtractPackage(archiveURL: corruptFile, version: "2.0.0")) { error in
            XCTAssertTrue(error.localizedDescription.contains("解压更新包失败") || error.localizedDescription.contains("不支持"))
        }

        try? FileManager.default.removeItem(at: corruptFile)
    }

    func testExtractionValidatesAppBundleAndIdentifier() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("TestBundle_\(UUID().uuidString)")
        let appDir = tempRoot.appendingPathComponent("ApexTerm.app")
        let contentsDir = appDir.appendingPathComponent("Contents")
        let macosDir = contentsDir.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)

        let binaryURL = macosDir.appendingPathComponent("ApexTerm")
        try Data("binary".utf8).write(to: binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

        // Invalid Bundle Identifier
        let invalidPlist: [String: Any] = [
            "CFBundleIdentifier": "com.fraudulent.app",
            "CFBundleShortVersionString": "2.0.0"
        ]
        let plistURL = contentsDir.appendingPathComponent("Info.plist")
        let plistData = try PropertyListSerialization.data(fromPropertyList: invalidPlist, format: .xml, options: 0)
        try plistData.write(to: plistURL)

        // Create tar.gz
        let archiveURL = tempRoot.appendingPathComponent("bundle.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archiveURL.path, "-C", tempRoot.path, "ApexTerm.app"]
        try tar.run()
        tar.waitUntilExit()

        XCTAssertThrowsError(try UpdateManager.defaultExtractPackage(archiveURL: archiveURL, version: "2.0.0")) { error in
            XCTAssertTrue(error.localizedDescription.contains("安装包应用标识不符"))
        }

        // Fix to valid Bundle Identifier
        let validPlist: [String: Any] = [
            "CFBundleIdentifier": "com.apexterm.app",
            "CFBundleShortVersionString": "2.0.0"
        ]
        let validData = try PropertyListSerialization.data(fromPropertyList: validPlist, format: .xml, options: 0)
        try validData.write(to: plistURL)

        let tar2 = Process()
        tar2.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar2.arguments = ["-czf", archiveURL.path, "-C", tempRoot.path, "ApexTerm.app"]
        try tar2.run()
        tar2.waitUntilExit()

        let extractedApp = try UpdateManager.defaultExtractPackage(archiveURL: archiveURL, version: "2.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedApp.path))

        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.removeItem(at: extractedApp.deletingLastPathComponent())
    }
}

private actor UpdateRequestGate {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func request() async {
        count += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
