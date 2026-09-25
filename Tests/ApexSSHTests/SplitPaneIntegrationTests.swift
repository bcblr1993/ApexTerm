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
}
