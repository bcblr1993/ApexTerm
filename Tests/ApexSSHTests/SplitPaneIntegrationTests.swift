import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

final class SplitPaneIntegrationTests: XCTestCase {
    
    @MainActor
    func testSplitPaneCreationAndIndependence() {
        let session = Session(name: "dev-server", host: "10.0.1.10", username: "developer")
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        
        // 1. Initial State
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertEqual(tab.splitMode, .single)
        XCTAssertEqual(tab.activePaneId, tab.panes.first?.id)
        
        let primaryPane = tab.panes[0]
        XCTAssertEqual(primaryPane.title, "dev-server")
        
        // 2. Perform Split (horizontal)
        tab.split(mode: .horizontal)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.splitMode, .horizontal)
        XCTAssertEqual(tab.activePaneId, tab.panes[1].id)
        
        let secondaryPane = tab.panes[1]
        XCTAssertNotEqual(primaryPane.id, secondaryPane.id)
        XCTAssertTrue(secondaryPane.title.contains("分屏"))
        
        // 3. Test Buffer Stream Isolation between Panes
        primaryPane.ringBuffer.appendStream("Output only on Primary\n")
        secondaryPane.ringBuffer.appendStream("Output only on Secondary\n")
        
        XCTAssertEqual(primaryPane.ringBuffer.allLines(), ["Output only on Primary"])
        XCTAssertEqual(secondaryPane.ringBuffer.allLines(), ["Output only on Secondary"])
        
        // 4. Test Active Pane RingBuffer switching
        tab.activePaneId = primaryPane.id
        XCTAssertEqual(tab.ringBuffer.allLines(), ["Output only on Primary"])
        
        tab.activePaneId = secondaryPane.id
        XCTAssertEqual(tab.ringBuffer.allLines(), ["Output only on Secondary"])
        
        // 5. Test Split Pane Closing Lifecycle
        tab.closePane(id: secondaryPane.id)
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertEqual(tab.splitMode, .single)
        XCTAssertEqual(tab.activePaneId, primaryPane.id)
    }
    
    @MainActor
    func testDirectoryLinkageToggle() async {
        let session = Session(name: "linkage-test", host: "10.0.1.10", username: "root", sftpAutoSyncEnabled: true)
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        
        XCTAssertEqual(tab.currentRemotePath, "/root")
        XCTAssertTrue(tab.isDirectoryLinkageEnabled)
        
        // Trigger directory change when enabled
        client.triggerDirectoryChange(to: "/var/log/nginx")
        // Allow Task @MainActor to execute
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tab.currentRemotePath, "/var/log/nginx")
        
        // Disable directory linkage
        tab.isDirectoryLinkageEnabled = false
        client.triggerDirectoryChange(to: "/etc/systemd")
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Should not have changed because linkage is disabled
        XCTAssertEqual(tab.currentRemotePath, "/var/log/nginx")
    }
    
    @MainActor
    func testSplitPaneRehydrationAndFocusManagement() {
        let session = Session(name: "rehydration-test", host: "10.0.1.10", username: "ubuntu")
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        
        let primaryPane = tab.panes[0]
        primaryPane.ringBuffer.appendStream("Welcome to Ubuntu 24.04 LTS\nubuntu@VM-0-17:~$ ")
        
        // Split vertically
        tab.split(mode: .vertical)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.activePaneId, tab.panes[1].id)
        
        // Verify primaryPane rehydrates immediately upon view attachment (no blank screen)
        let scrollView = NativeTerminalScrollView()
        scrollView.terminalView.ringBuffer = primaryPane.ringBuffer
        scrollView.terminalView.refresh()
        
        let text = scrollView.terminalView.textStorage?.string ?? ""
        XCTAssertTrue(text.contains("Welcome to Ubuntu 24.04 LTS"), "Buffer history must be rendered immediately")
        XCTAssertTrue(text.contains("ubuntu@VM-0-17:~$"), "Active prompt must be rendered immediately")
        
        // Verify onFocus callback updates tab.activePaneId
        var focusTriggered = false
        scrollView.terminalView.onFocus = {
            focusTriggered = true
            tab.activePaneId = primaryPane.id
        }
        _ = scrollView.terminalView.becomeFirstResponder()
        XCTAssertTrue(focusTriggered)
        XCTAssertEqual(tab.activePaneId, primaryPane.id)
    }
    
    @MainActor
    func testSplitPaneModeTogglingAndTitleReset() {
        let session = Session(name: "prod-server", host: "10.0.1.10", username: "root")
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        
        // 1. Initial split to vertical
        tab.split(mode: .vertical)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.splitMode, .vertical)
        
        // 2. Smooth toggle to horizontal when already split
        tab.split(mode: .horizontal)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.splitMode, .horizontal)
        
        // 3. Smooth toggle back to vertical
        tab.split(mode: .vertical)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.splitMode, .vertical)
        
        // 4. Close first pane, verify remaining pane resets title cleanly
        let firstId = tab.panes[0].id
        tab.closePane(id: firstId)
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertEqual(tab.splitMode, .single)
        XCTAssertEqual(tab.panes[0].title, "prod-server")
    }
}
