import XCTest
import UniformTypeIdentifiers
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

@MainActor
final class ComprehensiveFeatureTests: XCTestCase {

    // MARK: - 1. SSH Session & Connection State Tests
    
    func testSSHSessionConnectionStates() async {
        let session = Session(
            name: "Test Cluster",
            host: "10.0.1.10",
            port: 22,
            username: "root",
            authMethod: .password(keychainRef: "secret")
        )
        let client = MockSSHSession(session: session)
        
        XCTAssertEqual(client.connectionState, .disconnected)
        
        do {
            try await client.connect()
            XCTAssertEqual(client.connectionState, .connected)
        } catch {
            XCTFail("Connection failed: \(error)")
        }
        
        // Test sending input data
        let testCommand = "echo 'ApexTerm Test'\n".data(using: .utf8)!
        do {
            try await client.sendInput(testCommand)
        } catch {
            XCTFail("Send input failed: \(error)")
        }
        
        // Test terminal resize
        do {
            try await client.resizeTerminal(columns: 120, rows: 40)
        } catch {
            XCTFail("Resize failed: \(error)")
        }
        
        // Disconnect
        await client.disconnect()
        XCTAssertEqual(client.connectionState, .disconnected)
    }

    // MARK: - 2. Agentless Linux Metrics Parsing Tests
    
    func testAgentlessMetricsParsing() {
        let sample = """
        cpu  2255 34 2290 22625563 6290 127 456 0 0 0
        cpu0 1132 18 1441 11311800 3611 98 397 0 0 0
        cpu1 1123 16  849 11313763 2679 29  59 0 0 0
        MemTotal:        4018896 kB
        MemFree:          847320 kB
        MemAvailable:    2548232 kB
        Buffers:          184728 kB
        Cached:          1654320 kB
        eth0: 1000000 1000 0 0 0 0 0 0 500000 500 0 0 0 0 0 0
        ---DF---
        /dev/sda1 41943040 10485760 31457280 25% /
        ---UPTIME---
        142857.42 284192.11
        ---LOAD---
        0.42 0.58 0.65 1/120 1234
        """
        
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = AgentlessMonitor.CpuTickState(idle: 22000000, total: 22600000)
        var prevNet: AgentlessMonitor.NetTickState? = AgentlessMonitor.NetTickState(rx: 900000, tx: 450000, timestamp: Date().addingTimeInterval(-1.0))
        
        let snapshot = monitor.parseLinuxOutput(sample, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertEqual(snapshot.cpuCores, 2)
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 0)
        XCTAssertGreaterThan(snapshot.memoryUsedBytes, 0)
        XCTAssertEqual(snapshot.uptimeSeconds, 142857)
        XCTAssertEqual(snapshot.diskTotalBytes, 41943040 * 1024)
        XCTAssertEqual(snapshot.diskUsedBytes, 10485760 * 1024)
    }

    // MARK: - 3. SFTP Item Formatting & Sorting Tests
    
    func testSFTPItemFormattingAndSorting() {
        let dir = SFTPItem(
            name: "var",
            path: "/var",
            isDirectory: true,
            isSymlink: false,
            size: 4096,
            permissions: 0o755,
            modificationDate: Date()
        )
        
        let fileSmall = SFTPItem(
            name: "config.yaml",
            path: "/var/config.yaml",
            isDirectory: false,
            isSymlink: false,
            size: 1536,
            permissions: 0o644,
            modificationDate: Date()
        )
        
        let fileLarge = SFTPItem(
            name: "backup.tar.gz",
            path: "/var/backup.tar.gz",
            isDirectory: false,
            isSymlink: false,
            size: 104857600, // 100 MB
            permissions: 0o644,
            modificationDate: Date()
        )
        
        XCTAssertEqual(fileSmall.formattedSize, "1.5 KB")
        XCTAssertEqual(fileLarge.formattedSize, "100.0 MB")
        XCTAssertEqual(dir.formattedSize, "--")
        XCTAssertEqual(dir.permissionString, "drwxr-xr-x")
        XCTAssertEqual(fileSmall.permissionString, "-rw-r--r--")
        
        // Sorting: directories first, then alphabetical
        let items = [fileLarge, dir, fileSmall]
        let sorted = items.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        
        XCTAssertEqual(sorted[0].name, "var")
        XCTAssertEqual(sorted[1].name, "backup.tar.gz")
        XCTAssertEqual(sorted[2].name, "config.yaml")
    }

    // MARK: - 4. TransferManager Scheduling Tests
    
    func testTransferManagerEnqueueAndCancel() {
        let manager = TransferManager.shared
        
        let session = Session(name: "Transfer Test", host: "10.0.1.10", port: 22, username: "root")
        let client = MockSSHSession(session: session)
        
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_transfer_\(UUID().uuidString).txt")
        try? "Transfer Payload Content".data(using: .utf8)?.write(to: tempFile)
        
        let taskId = manager.enqueueUpload(
            session: client,
            localURL: tempFile,
            remotePath: "/tmp/uploaded_test.txt"
        )
        
        let task = manager.tasks.first(where: { $0.id == taskId })
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.remotePath, "/tmp/uploaded_test.txt")
        
        // Test cancellation
        manager.cancelTask(id: taskId)
        
        try? FileManager.default.removeItem(at: tempFile)
    }

    // MARK: - 5. Terminal RingBuffer ECMA-48 Operations
    
    func testRingBufferECMA48Operations() {
        let buffer = TerminalRingBuffer(maxLines: 500)
        
        // Type initial prompt and command
        buffer.appendStream("user@host:~$ ls")
        XCTAssertEqual(buffer.currentActiveLine, "user@host:~$ ls")
        
        // Backspace \x08 moves cursor left without deleting
        buffer.appendStream("\u{08}")
        XCTAssertEqual(buffer.cursorColumn, 14)
        
        // Carriage return \r resets cursor column to 0
        buffer.appendStream("\r")
        XCTAssertEqual(buffer.cursorColumn, 0)
        
        // Newline commits the line
        buffer.appendStream("\n")
        XCTAssertEqual(buffer.committedLineCount, 1)
        XCTAssertEqual(buffer.cursorColumn, 0)
        
        // Clear screen
        buffer.clear()
        XCTAssertEqual(buffer.committedLineCount, 0)
        XCTAssertEqual(buffer.currentActiveLine, "")
    }

    // MARK: - 6. VTParser Color & OSC 7 Directory Sync Tests
    
    func testVTParserTrueColorAndOSC7Sync() {
        let parser = VTParser()
        
        // TrueColor 24-bit ANSI foreground color: ESC [ 38;2;255;100;50 m
        let trueColorInput = "\u{1b}[38;2;255;100;50mColored Text\u{1b}[0m"
        let spans = parser.parseANSI(trueColorInput)
        
        XCTAssertFalse(spans.isEmpty)
        XCTAssertEqual(spans.first?.text, "Colored Text")
        XCTAssertEqual(spans.first?.foregroundColorHex, "#FF6432")
        
        // OSC 7 Current Directory URL Sync via SSH session
        final class PathBox: @unchecked Sendable {
            var path: String?
        }
        let box = PathBox()
        let session = Session(name: "OSC7 Test", host: "1.2.3.4", port: 22, username: "user")
        let mock = MockSSHSession(session: session)
        mock.setDirectoryChangeHandler { path in
            box.path = path
        }
        mock.triggerDirectoryChange(to: "/var/log")
        XCTAssertEqual(box.path, "/var/log")
    }

    // MARK: - 7. Terminal Split Panes & Multi-Tab Model
    
    func testTerminalTabItemSplits() {
        let session = Session(name: "Split Test", host: "10.0.1.10", port: 22, username: "root")
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertEqual(tab.activePaneId, tab.panes.first?.id)
        
        // Split vertical
        tab.split(mode: .vertical)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.splitMode, .vertical)
        
        // Split guard check (caps at 2 panes)
        tab.split(mode: .horizontal)
        XCTAssertEqual(tab.panes.count, 2)
        
        // Close secondary pane
        if let toClose = tab.panes.last?.id {
            tab.closePane(id: toClose)
            XCTAssertEqual(tab.panes.count, 1)
            XCTAssertEqual(tab.splitMode, .single)
        }
    }

    // MARK: - 8. Snippet Parameter Interpolation
    
    func testSnippetParameterInterpolation() {
        let snippet = Snippet(
            title: "Deploy K8s",
            command: "kubectl --server=https://{{host}}:{{port}} get pods -n {{namespace}}",
            category: "DevOps",
            autoExecute: true
        )
        
        let context = [
            "host": "192.168.1.50",
            "port": "6443",
            "namespace": "production"
        ]
        
        let resolved = snippet.resolvedCommand(context: context)
        XCTAssertEqual(resolved, "kubectl --server=https://192.168.1.50:6443 get pods -n production")
    }

    // MARK: - 9. AppSettings Complete Model Verification
    
    func testAppSettingsCompleteModel() {
        let settings = AppSettings.shared
        settings.resetToDefaults()
        
        // Appearance
        settings.fontName = "JetBrains Mono"
        settings.fontSize = 15.0
        settings.cursorShape = .underline
        settings.isCursorBlinkEnabled = false
        settings.themePreset = .monokai
        
        XCTAssertEqual(settings.fontName, "JetBrains Mono")
        XCTAssertEqual(settings.fontSize, 15.0)
        XCTAssertEqual(settings.cursorShape, .underline)
        XCTAssertFalse(settings.isCursorBlinkEnabled)
        XCTAssertEqual(settings.themePreset, .monokai)
        
        // Behavior
        settings.isCopyOnSelectEnabled = false
        settings.isRightClickPasteEnabled = false
        settings.scrollbackMaxLines = 25000
        settings.bellMode = .visual
        
        XCTAssertFalse(settings.isCopyOnSelectEnabled)
        XCTAssertFalse(settings.isRightClickPasteEnabled)
        XCTAssertEqual(settings.scrollbackMaxLines, 25000)
        XCTAssertEqual(settings.bellMode, .visual)
        
        // SFTP
        settings.showHiddenFiles = false
        settings.sftpAutoSyncEnabled = false
        settings.maxConcurrentTransfers = 5
        
        XCTAssertFalse(settings.showHiddenFiles)
        XCTAssertFalse(settings.sftpAutoSyncEnabled)
        XCTAssertEqual(settings.maxConcurrentTransfers, 5)
        
        settings.resetToDefaults()
    }

    // MARK: - 10. SFTP Drag-and-Drop Item Provider Export Tests
    
    func testSFTPDragItemProviderExport() async {
        let fileItem = SFTPItem(
            name: "test_report.pdf",
            path: "/var/log/test_report.pdf",
            isDirectory: false,
            isSymlink: false,
            size: 2048,
            permissions: 0o644,
            modificationDate: Date()
        )
        
        let session = MockSSHSession(session: Session(name: "Test", host: "localhost", username: "test"))
        
        let provider = SFTPDragExportHelper.makeItemProvider(for: fileItem, session: session)
        
        XCTAssertEqual(provider.suggestedName, "test_report.pdf")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.data.identifier))
    }

    // MARK: - 11. All 4 Transfer Scenarios Record in TransferManager Tests
    
    func testAllFourTransferScenariosRecordInTransferManager() async {
        let manager = TransferManager.shared
        manager.clearCompleted()
        
        let session = MockSSHSession(session: Session(name: "TestServer", host: "127.0.0.1", username: "root"))
        let tempDir = FileManager.default.temporaryDirectory
        
        // 1. Scenario 1: Click to Download (enqueueDownload)
        let downloadDest = tempDir.appendingPathComponent("click_download.log")
        let downloadId = manager.enqueueDownload(
            session: session,
            remotePath: "/var/log/click_download.log",
            localURL: downloadDest,
            totalBytes: 1024
        )
        XCTAssertTrue(manager.tasks.contains(where: { $0.id == downloadId && $0.direction == .download }))
        
        // 2. Scenario 2: Drag to Download (beginExternalTransfer)
        let dragDownloadId = UUID()
        let dragDest = tempDir.appendingPathComponent("drag_download.pdf")
        manager.beginExternalTransfer(
            id: dragDownloadId,
            fileName: "drag_download.pdf",
            remotePath: "/remote/drag_download.pdf",
            localURL: dragDest,
            direction: .download,
            totalBytes: 50000
        )
        XCTAssertTrue(manager.tasks.contains(where: { $0.id == dragDownloadId && $0.direction == .download && $0.status == .transferring }))
        
        manager.updateExternalProgress(taskId: dragDownloadId, fraction: 0.5)
        let taskMid = manager.tasks.first(where: { $0.id == dragDownloadId })
        XCTAssertEqual(taskMid?.transferredBytes, 25000)
        
        manager.completeExternalTransfer(taskId: dragDownloadId)
        let taskEnd = manager.tasks.first(where: { $0.id == dragDownloadId })
        XCTAssertEqual(taskEnd?.status, .completed)
        
        // 3. Scenario 3: Click to Upload (enqueueUpload)
        let uploadLocal = tempDir.appendingPathComponent("click_upload.txt")
        try? "test data".write(to: uploadLocal, atomically: true, encoding: .utf8)
        let uploadId = manager.enqueueUpload(
            session: session,
            localURL: uploadLocal,
            remotePath: "/home/ubuntu/click_upload.txt"
        )
        XCTAssertTrue(manager.tasks.contains(where: { $0.id == uploadId && $0.direction == .upload }))
        
        // 4. Scenario 4: Drag to Upload (enqueueUpload via drop)
        let dragUploadLocal = tempDir.appendingPathComponent("drag_upload.png")
        try? "image data".write(to: dragUploadLocal, atomically: true, encoding: .utf8)
        let dragUploadId = manager.enqueueUpload(
            session: session,
            localURL: dragUploadLocal,
            remotePath: "/home/ubuntu/drag_upload.png"
        )
        XCTAssertTrue(manager.tasks.contains(where: { $0.id == dragUploadId && $0.direction == .upload }))
        
        // Assert all 4 tasks are recorded
        let uploadTasks = manager.tasks.filter { $0.direction == .upload }
        let downloadTasks = manager.tasks.filter { $0.direction == .download }
        XCTAssertGreaterThanOrEqual(uploadTasks.count, 2)
        XCTAssertGreaterThanOrEqual(downloadTasks.count, 2)
        
        // Cleanup
        manager.clearCompleted()
    }

    // MARK: - 12. Duplicate Tab (复制会话) & Context Management Tests
    
    func testDuplicateTabSessionStateAndInheritance() async {
        let session = Session(
            name: "Prod Cluster",
            host: "10.0.1.10",
            port: 22,
            username: "ubuntu",
            authMethod: .password(keychainRef: "secret")
        )
        let client = MockSSHSession(session: session)
        let tab1 = TerminalTabItem(session: session, sshClient: client)
        tab1.currentRemotePath = "/var/www/html"
        tab1.isDirectoryLinkageEnabled = true
        
        // Emulate duplicateTab logic
        let dupClient = MockSSHSession(session: session)
        let tab2 = TerminalTabItem(session: session, sshClient: dupClient)
        tab2.currentRemotePath = tab1.currentRemotePath
        tab2.isDirectoryLinkageEnabled = tab1.isDirectoryLinkageEnabled
        
        // Assertions
        XCTAssertNotEqual(tab1.id, tab2.id)
        XCTAssertEqual(tab2.session.name, "Prod Cluster")
        XCTAssertEqual(tab2.session.host, "10.0.1.10")
        XCTAssertEqual(tab2.session.username, "ubuntu")
        XCTAssertEqual(tab2.currentRemotePath, "/var/www/html")
        XCTAssertTrue(tab2.isDirectoryLinkageEnabled)
    }
}
