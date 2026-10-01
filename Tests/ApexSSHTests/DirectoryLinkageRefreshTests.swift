import XCTest
import Foundation
import ApexCore
import ApexSSH
@testable import ApexUI

final class DirectoryLinkageRefreshTests: XCTestCase {
    @MainActor
    func testRepeatedPromptHintsCoalesceButDirectoryChangesStayImmediate() async throws {
        let session = Session(name: "linkage", host: "192.0.2.10", username: "qa")
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        tab.currentRemotePath = "/tmp/owned-linkage"
        tab.isDirectoryLinkageEnabled = true
        defer { UserDefaults.standard.removeObject(forKey: "workspace.remotePath.\(session.id.uuidString)") }
        let event = expectation(description: "One trailing refresh after a burst of prompts")
        event.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(forName: NSNotification.Name("SFTPDirectoryRefreshNeeded"), object: nil, queue: nil) { note in
            if note.object as? String == "/tmp/owned-linkage" { event.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<10 {
            client.triggerDirectoryChange(to: "/tmp/owned-linkage")
            try await Task.sleep(for: .milliseconds(20))
        }
        await fulfillment(of: [event], timeout: 2)
        client.triggerDirectoryChange(to: "/tmp/owned-linkage/child")
        for _ in 0..<10 {
            if tab.currentRemotePath == "/tmp/owned-linkage/child" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(tab.currentRemotePath, "/tmp/owned-linkage/child")
    }
}
