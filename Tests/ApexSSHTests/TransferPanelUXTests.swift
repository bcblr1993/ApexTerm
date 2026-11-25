import XCTest
import AppKit
import SwiftUI
import os
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

@MainActor
final class TransferPanelUXTests: XCTestCase {

    // MARK: - 1. Adaptive SFTP Transfer Drawer Layout Modes

    func testSFTPTransferDrawerLayoutAdaptiveModes() {
        // Collapsed always resolves to .collapsed regardless of height
        XCTAssertEqual(SFTPTransferDrawerLayout.resolve(isExpanded: false, availableHeight: 500), .collapsed)
        XCTAssertEqual(SFTPTransferDrawerLayout.resolve(isExpanded: false, availableHeight: 150), .collapsed)
        XCTAssertEqual(SFTPTransferDrawerLayout.resolve(isExpanded: true, availableHeight: 0), .collapsed)

        // Compact SFTP heights (< 300pt) use fillSFTPArea so file table isn't crushed
        for compactHeight in [135.0, 205.0, 299.0] {
            XCTAssertEqual(
                SFTPTransferDrawerLayout.resolve(isExpanded: true, availableHeight: compactHeight),
                .fillSFTPArea,
                "Height \(compactHeight)pt should fill SFTP area instead of over-cramping both lists"
            )
        }

        // Taller SFTP heights (>= 300pt) split cleanly within [180, 240] while leaving >= 120pt for files
        let medium = SFTPTransferDrawerLayout.resolve(isExpanded: true, availableHeight: 300)
        XCTAssertEqual(medium, .dockedSplit(drawerHeight: 180))

        let standard = SFTPTransferDrawerLayout.resolve(isExpanded: true, availableHeight: 360)
        XCTAssertEqual(standard, .dockedSplit(drawerHeight: 180))

        let tall = SFTPTransferDrawerLayout.resolve(isExpanded: true, availableHeight: 600)
        XCTAssertEqual(tall, .dockedSplit(drawerHeight: 240))

        for h in [300.0, 360.0, 440.0, 600.0] {
            if case .dockedSplit(let drawerHeight) = SFTPTransferDrawerLayout.resolve(isExpanded: true, availableHeight: h) {
                XCTAssertGreaterThanOrEqual(drawerHeight, SFTPTransferDrawerLayout.minSplitDrawerHeight)
                XCTAssertLessThanOrEqual(drawerHeight, SFTPTransferDrawerLayout.maxSplitDrawerHeight)
                XCTAssertGreaterThanOrEqual(h - drawerHeight, SFTPTransferDrawerLayout.minFileListHeightInSplit)
            } else {
                XCTFail("Expected dockedSplit at height \(h)")
            }
        }
    }

    // MARK: - 2. Inline Progress Summary Selection & Formatting

    func testTransferProgressSummarySelectionAndFormatting() {
        let completed = TransferTask(
            fileName: "done.tar",
            remotePath: "/root/done.tar",
            localURL: URL(fileURLWithPath: "/tmp/done.tar"),
            direction: .download,
            totalBytes: 1024,
            transferredBytes: 1024,
            status: .completed
        )
        let failed = TransferTask(
            fileName: "err.tar",
            remotePath: "/root/err.tar",
            localURL: URL(fileURLWithPath: "/tmp/err.tar"),
            direction: .upload,
            totalBytes: 1024,
            transferredBytes: 128,
            status: .failed("permission denied")
        )

        // Empty or terminal-only task lists produce nil (inline bar hides cleanly)
        XCTAssertNil(TransferProgressSummary.make(from: [], formattedTotalSpeed: "0 B/s"))
        XCTAssertNil(TransferProgressSummary.make(from: [completed, failed], formattedTotalSpeed: "0 B/s"))

        // Single transferring task with known totalBytes
        let uploading = TransferTask(
            fileName: "jdk17.tar",
            remotePath: "/root/jdk17.tar",
            localURL: URL(fileURLWithPath: "/tmp/jdk17.tar"),
            direction: .upload,
            totalBytes: 1000,
            transferredBytes: 420,
            speedBytesPerSec: 2_500_000,
            status: .transferring
        )
        let single = TransferProgressSummary.make(from: [completed, uploading], formattedTotalSpeed: "2.4 MB/s")
        XCTAssertEqual(single?.primaryTask.id, uploading.id)
        XCTAssertEqual(single?.activeCount, 1)
        XCTAssertEqual(single?.otherActiveCount, 0)
        XCTAssertEqual(single?.progressFraction ?? -1, 0.42, accuracy: 0.001)
        XCTAssertEqual(single?.percentText, "42%")
        XCTAssertFalse(single?.bytesText.isEmpty ?? true)
        XCTAssertEqual(single?.speedText, uploading.formattedSpeed)

        // Active task with unknown totalBytes yields nil fraction (indeterminate track)
        let unknownSize = TransferTask(
            fileName: "stream.log",
            remotePath: "/var/log/stream.log",
            localURL: URL(fileURLWithPath: "/tmp/stream.log"),
            direction: .download,
            totalBytes: 0,
            transferredBytes: 4096,
            speedBytesPerSec: 1024,
            status: .transferring
        )
        let unknownSummary = TransferProgressSummary.make(from: [unknownSize], formattedTotalSpeed: "1 KB/s")
        XCTAssertNil(unknownSummary?.progressFraction)
        XCTAssertFalse(unknownSummary?.percentText.isEmpty ?? true)

        // Queued-only task displays "等待中"
        let queued = TransferTask(
            fileName: "queued.zip",
            remotePath: "/root/queued.zip",
            localURL: URL(fileURLWithPath: "/tmp/queued.zip"),
            direction: .upload,
            totalBytes: 0,
            transferredBytes: 0,
            status: .queued
        )
        let queuedSummary = TransferProgressSummary.make(from: [queued], formattedTotalSpeed: "0 B/s")
        XCTAssertEqual(queuedSummary?.percentText, "等待中")
        XCTAssertNil(queuedSummary?.progressFraction)

        // Multiple active tasks prioritize transferring task and aggregate speed + count badge
        let queued2 = TransferTask(
            fileName: "queued2.zip",
            remotePath: "/root/queued2.zip",
            localURL: URL(fileURLWithPath: "/tmp/queued2.zip"),
            direction: .download,
            totalBytes: 5000,
            transferredBytes: 0,
            status: .queued
        )
        let multi = TransferProgressSummary.make(
            from: [queued, uploading, queued2],
            formattedTotalSpeed: "4.2 MB/s"
        )
        XCTAssertEqual(multi?.primaryTask.id, uploading.id)
        XCTAssertEqual(multi?.activeCount, 3)
        XCTAssertEqual(multi?.otherActiveCount, 2)
        XCTAssertEqual(multi?.speedText, "4.2 MB/s")
    }

    // MARK: - 3. TransferDrawerPresentation State Transitions

    func testTransferDrawerPresentationToggleOpenClose() {
        let presentation = TransferDrawerPresentation()
        XCTAssertFalse(presentation.isPresented)

        presentation.open()
        XCTAssertTrue(presentation.isPresented)

        presentation.close()
        XCTAssertFalse(presentation.isPresented)

        presentation.toggle()
        XCTAssertTrue(presentation.isPresented)

        presentation.toggle()
        XCTAssertFalse(presentation.isPresented)
    }

    // MARK: - 4. Unified Header & Body Geometry Across All/Uploads/Downloads Tabs

    func testTransferDrawerUnifiedLayoutAcrossAllUploadDownloadTabs() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let drawerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/SFTP/TransferDrawer.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(drawerSource.contains(".frame(height: 140)"),
                       "Empty state must not hardcode a 140pt height that shifts the header downwards")
        XCTAssertFalse(drawerSource.contains(".frame(maxHeight: 240)"),
                       "Task list must not cap maxHeight inside a taller container causing vertical centering drift")
        XCTAssertTrue(drawerSource.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"),
                      "TransferDrawer content must align cleanly to top across empty and non-empty tabs")
        XCTAssertTrue(drawerSource.contains(".accessibilityIdentifier(\"transfer.emptyState\")"))
        XCTAssertTrue(drawerSource.contains(".accessibilityIdentifier(\"transfer.taskList\")"))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferDrawerUnifiedTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = Session(name: "TestNode", host: "10.0.0.5", username: "root")
        let mock = MockSSHSession(session: session)
        mock.customDownloadHandler = { _, localURL, progress in
            try Data("payload".utf8).write(to: localURL)
            progress(1.0)
        }

        let manager = TransferManager(distributionChannel: .direct)
        let doneExpectation = expectation(description: "Download finishes")
        let localDest = tempDir.appendingPathComponent("jdk17.tar")
        manager.enqueueDownload(
            session: mock,
            remotePath: "/root/jdk17.tar",
            localURL: localDest,
            totalBytes: 7,
            onResult: { _ in
                Task { @MainActor in doneExpectation.fulfill() }
            }
        )
        await fulfillment(of: [doneExpectation], timeout: 3.0)

        for filter in TransferDrawer.TransferFilter.allCases {
            let drawer = TransferDrawer(
                isExpanded: .constant(true),
                manager: manager,
                initialFilter: filter
            )
            let host = NSHostingView(rootView: drawer.apexTheme())
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.subviews.count, 0, "TransferDrawer tab \(filter.rawValue) must lay out cleanly")
        }
    }

    // MARK: - 5. Elimination of Blocking Modal Sheets & Auto-Popups

    func testTransferUIEliminatesModalSheetsAndAutoPopups() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let sftpSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/SFTP/SFTPView.swift"),
            encoding: .utf8
        )
        let workspaceSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/Workspace/WorkspaceView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(sftpSource.contains(".sheet(isPresented: $isTransferDrawerExpanded)"),
                       "SFTPView must not block the workspace with a modal transfer .sheet")
        XCTAssertFalse(sftpSource.contains("isTransferDrawerExpanded = true"),
                       "SFTPView must not auto-open the full transfer drawer on transfer start/failure")
        XCTAssertTrue(sftpSource.contains("TransferInlineProgressBar("),
                      "SFTPView must embed TransferInlineProgressBar for click-free live progress")
        XCTAssertTrue(sftpSource.contains("SFTPTransferDrawerLayout.resolve("),
                      "SFTPView must resolve embedded drawer sizing adaptively")

        XCTAssertFalse(workspaceSource.contains(".sheet(isPresented: $isTransferDrawerPresented)"),
                       "WorkspaceBottomStatusBar must not present a blocking .sheet for transfers")
        XCTAssertTrue(workspaceSource.contains("WorkspaceTransferOverlayHost("),
                      "WorkspaceView must host non-modal floating transfer card when SFTP is hidden")
        XCTAssertTrue(workspaceSource.contains("StatusBarTransferIndicator("),
                      "WorkspaceBottomStatusBar must display inline transfer progress/indicator")
    }

    // MARK: - 6. Inline Progress Bar & Non-Modal Floating Card Render Verification

    func testInlineProgressBarAndFloatingTransferCardRenderCleanly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferInlineRenderTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let srcFile = tempDir.appendingPathComponent("jdk17.tar")
        try Data(repeating: 0x41, count: 4096).write(to: srcFile)

        let session = Session(name: "UploadNode", host: "10.0.0.6", username: "root")
        let mock = MockSSHSession(session: session)
        let startedExpectation = expectation(description: "Upload entered handler")
        let didFulfillStart = OSAllocatedUnfairLock(initialState: false)
        mock.customUploadHandler = { _, _, progress in
            progress(0.5)
            let shouldFulfill = didFulfillStart.withLock { flag -> Bool in
                guard !flag else { return false }
                flag = true
                return true
            }
            if shouldFulfill {
                await MainActor.run {
                    startedExpectation.fulfill()
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        let manager = TransferManager(distributionChannel: .direct)
        defer {
            manager.cancelAllTasks()
            manager.clearCompleted()
        }
        manager.enqueueUpload(session: mock, localURL: srcFile, remotePath: "/root/jdk17.tar")
        await fulfillment(of: [startedExpectation], timeout: 3.0)

        let inlineBar = TransferInlineProgressBar(isDrawerExpanded: .constant(false), manager: manager)
        let inlineHost = NSHostingView(rootView: inlineBar.apexTheme())
        inlineHost.frame = NSRect(x: 0, y: 0, width: 640, height: 36)
        inlineHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(inlineHost.subviews.count, 0, "TransferInlineProgressBar must render cleanly while active")

        let store = SessionStore()
        let local = Session.local()
        store.sessions = [local]
        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)

        let workspace = WorkspaceView(
            store: store,
            activeTabs: .constant([tab]),
            selectedTabId: .constant(tab.id)
        )
        let workspaceHost = NSHostingView(rootView: workspace.apexTheme())
        workspaceHost.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        workspaceHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(workspaceHost.subviews.count, 0, "WorkspaceView with updated transfer UI must render cleanly")
    }

    // MARK: - 7. SFTP Notice Suppression, Toolbar Menu/Filter Guards & Multi-Width Render

    func testShouldSuppressInlineNoticeForActiveTransfers() {
        XCTAssertTrue(SFTPView.shouldSuppressInlineNotice("正在上传 jdk17.tar…"))
        XCTAssertTrue(SFTPView.shouldSuppressInlineNotice("正在批量上传 2 个文件…"))
        XCTAssertTrue(SFTPView.shouldSuppressInlineNotice("正在下载: jdk17.tar..."))
        XCTAssertTrue(SFTPView.shouldSuppressInlineNotice("正在下载 3 个项目…"))
        XCTAssertTrue(SFTPView.shouldSuppressInlineNotice("正在下载并导出: jdk17.tar..."))

        XCTAssertFalse(SFTPView.shouldSuppressInlineNotice("上传失败: permission denied"))
        XCTAssertFalse(SFTPView.shouldSuppressInlineNotice("上传成功: jdk17.tar"))
        XCTAssertFalse(SFTPView.shouldSuppressInlineNotice("正在压缩 archive.tar.gz..."))
        XCTAssertFalse(SFTPView.shouldSuppressInlineNotice("正在解压 archive.tar.gz..."))
        XCTAssertFalse(SFTPView.shouldSuppressInlineNotice("已新建文件夹: logs"))
    }

    func testSFTPToolbarAndStatusBarDeduplicationGuards() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let sftpSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/SFTP/SFTPView.swift"),
            encoding: .utf8
        )
        let workspaceSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/Workspace/WorkspaceView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(sftpSource.contains("正在批量上传 \\("),
                       "SFTPView must not display a duplicate batch upload notice banner while TransferInlineProgressBar is active")
        XCTAssertFalse(sftpSource.contains("self.transferNotice = \"正在下载"),
                       "SFTPView must not display a duplicate download progress notice banner")
        XCTAssertFalse(sftpSource.contains("transferNotice = \"正在下载"),
                       "SFTPView must not display a duplicate batch download progress notice banner")
        XCTAssertFalse(sftpSource.contains("Toggle(isOn: $isFilterVisible)"),
                       "SFTPView filter button must use unified 24pt ApexIconButton instead of oversized Toggle button")

        let hiddenIndicatorCount = sftpSource.components(separatedBy: ".menuIndicator(.hidden)").count - 1
        XCTAssertGreaterThanOrEqual(hiddenIndicatorCount, 2,
                                    "Both bookmark and ellipsis Menus in SFTPView must hide system disclosure indicators")

        let statusBarRange = try XCTUnwrap(workspaceSource.range(of: "private struct WorkspaceBottomStatusBar: View"))
        let statusBarRest = workspaceSource[statusBarRange.upperBound...]
        let statusBarBody = statusBarRest.range(of: "\nprivate struct ").map { statusBarRest[..<$0.lowerBound] } ?? statusBarRest
        XCTAssertTrue(statusBarBody.contains("if showsDirectoryControls {\n                StatusBarTransferIndicator("),
                      "WorkspaceBottomStatusBar must only show StatusBarTransferIndicator when SFTP panel is hidden")
        XCTAssertFalse(statusBarBody.contains("Rectangle()\n                .frame(height: 0.75)"),
                       "WorkspaceBottomStatusBar must not draw a duplicate top border below WorkspaceView's Divider")
    }

    func testSFTPViewMultiWidthLayoutWithActiveUpload() async throws {
        final class ListingMockSession: SSHSessionProtocol, @unchecked Sendable {
            let session: Session
            var connectionState: SSHConnectionState = .connected
            private let uploadEntered = OSAllocatedUnfairLock(initialState: false)
            var onUploadEntered: (@Sendable () -> Void)?

            init(session: Session) {
                self.session = session
            }

            func connect() async throws {}
            func disconnect() async {}
            func sendInput(_ data: Data) async throws {}
            func resizeTerminal(columns: Int, rows: Int) async throws {}
            func listDirectory(path: String) async throws -> [SFTPItem] {
                [
                    SFTPItem(name: "logs", path: "\(path)/logs", isDirectory: true, size: 4096, permissions: 0o755, modificationDate: Date()),
                    SFTPItem(name: "check_main_thread.py", path: "\(path)/check_main_thread.py", isDirectory: false, size: 323, permissions: 0o644, modificationDate: Date()),
                    SFTPItem(name: "config-mate.tar", path: "\(path)/config-mate.tar", isDirectory: false, size: 330_196_582, permissions: 0o644, modificationDate: Date()),
                    SFTPItem(name: "db_2026-11-19.bak", path: "\(path)/db_2026-11-19.bak", isDirectory: false, size: 17_244_291_072, permissions: 0o644, modificationDate: Date())
                ]
            }
            func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {}
            func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {
                progress(0.33)
                let shouldSignal = uploadEntered.withLock { entered -> Bool in
                    guard !entered else { return false }
                    entered = true
                    return true
                }
                if shouldSignal {
                    onUploadEntered?()
                }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) {}
            func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) {}
            func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) {}
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SFTPViewMultiWidthTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let srcFile = tempDir.appendingPathComponent("iotedge-logs-wuyuan-a.tar.gz")
        try Data(repeating: 0x42, count: 8192).write(to: srcFile)

        let session = Session(name: "Prod", host: "10.8.8.71", username: "root")
        let mock = ListingMockSession(session: session)
        let started = expectation(description: "Upload active")
        mock.onUploadEntered = {
            Task { @MainActor in started.fulfill() }
        }

        defer {
            TransferManager.shared.cancelAllTasks()
            TransferManager.shared.clearCompleted()
        }
        TransferManager.shared.enqueueUpload(session: mock, localURL: srcFile, remotePath: "/root/\(srcFile.lastPathComponent)")
        await fulfillment(of: [started], timeout: 3.0)

        for width in [600.0, 800.0, 1100.0] {
            let view = SFTPView(
                currentPath: .constant("/root"),
                isLinkageEnabled: .constant(true),
                session: mock,
                connectionState: .connected
            )
            let host = NSHostingView(rootView: view.apexTheme())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 320),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 320)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()

            XCTAssertGreaterThan(host.subviews.count, 0, "SFTPView must lay out cleanly at width \(width)")
            window.orderOut(nil)
        }
    }
}
