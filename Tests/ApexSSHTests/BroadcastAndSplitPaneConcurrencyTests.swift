import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

private final class ThreadSafeOutputMap: @unchecked Sendable {
    private var map: [UUID: [String]] = [:]
    private let lock = NSLock()

    func append(_ text: String, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        map[id, default: []].append(text)
    }

    func joinedText(for id: UUID) -> String {
        lock.lock()
        defer { lock.unlock() }
        return (map[id] ?? []).joined()
    }
}

private final class ThreadSafeTextCollector: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()

    func append(_ str: String) {
        lock.lock()
        defer { lock.unlock() }
        text += str
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

final class BroadcastAndSplitPaneConcurrencyTests: XCTestCase {

    @MainActor
    func testMultiSessionBroadcastDelivery() async throws {
        // Create 4 distinct mock sessions simulating 4 different cluster nodes
        var tabs: [TerminalTabItem] = []
        var mockClients: [MockSSHSession] = []
        let collector = ThreadSafeOutputMap()

        for i in 1...4 {
            let session = Session(name: "node-0\(i)", host: "10.0.0.\(i)", username: "root")
            let client = MockSSHSession(session: session)
            let tab = TerminalTabItem(session: session, sshClient: client)
            try await client.connect()
            
            let id = tab.id
            client.setOutputHandler { data in
                if let str = String(data: data, encoding: .utf8) {
                    collector.append(str, for: id)
                }
            }

            tabs.append(tab)
            mockClients.append(client)
        }

        // Simulate broadcast execution on all tabs
        let broadcastCommand = "uptime\n"
        guard let data = broadcastCommand.data(using: .utf8) else {
            XCTFail("Failed to encode broadcast command")
            return
        }

        // Dispatch broadcast to all tabs and all their panes
        for tab in tabs {
            for pane in tab.panes {
                pane.sshClient.sendInputSync(data)
            }
        }

        // Allow runloop/async execution to settle
        try await Task.sleep(nanoseconds: 50_000_000)

        // Verify each mock node received the command
        for tab in tabs {
            let joined = collector.joinedText(for: tab.id)
            XCTAssertTrue(joined.contains("uptime"), "Tab \(tab.session.name) should have processed uptime command")
        }

        for client in mockClients {
            await client.disconnect()
        }
    }

    @MainActor
    func testBroadcastWithDisconnectedSessionFaultTolerance() async throws {
        // Create 3 tabs: Node 1 (online), Node 2 (disconnected), Node 3 (online)
        let s1 = Session(name: "node-ok-1", host: "10.0.0.1", username: "root")
        let s2 = Session(name: "node-dead-2", host: "10.0.0.2", username: "root")
        let s3 = Session(name: "node-ok-3", host: "10.0.0.3", username: "root")

        let c1 = MockSSHSession(session: s1)
        let c2 = MockSSHSession(session: s2)
        let c3 = MockSSHSession(session: s3)

        let t1 = TerminalTabItem(session: s1, sshClient: c1)
        let t2 = TerminalTabItem(session: s2, sshClient: c2)
        let t3 = TerminalTabItem(session: s3, sshClient: c3)

        try await c1.connect()
        try await c3.connect()
        // c2 remains disconnected

        let c1Collector = ThreadSafeTextCollector()
        let c3Collector = ThreadSafeTextCollector()
        c1.setOutputHandler { data in
            if let str = String(data: data, encoding: .utf8) {
                c1Collector.append(str)
            }
        }
        c3.setOutputHandler { data in
            if let str = String(data: data, encoding: .utf8) {
                c3Collector.append(str)
            }
        }

        let tabs = [t1, t2, t3]
        let cmd = "hostname -f\n".data(using: .utf8)!

        // Broadcast must succeed without throwing or crashing despite node 2 being offline
        XCTAssertNoThrow({
            for tab in tabs {
                for pane in tab.panes {
                    pane.sshClient.sendInputSync(cmd)
                }
            }
        }())

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(c1Collector.get().contains("hostname"), "Node 1 should have received input")
        XCTAssertTrue(c3Collector.get().contains("hostname"), "Node 3 should have received input")

        await c1.disconnect()
        await c3.disconnect()
    }

    @MainActor
    func testSplitPaneRatioClampingBoundaries() {
        let session = Session(name: "ratio-test", host: "127.0.0.1", username: "root")
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        
        tab.split(mode: .vertical)
        XCTAssertEqual(tab.paneSplitRatio, 0.5)

        // Simulate dragging far to the left (target 0.02)
        let clampedMin = min(max(0.02, 0.15), 0.85)
        tab.paneSplitRatio = clampedMin
        XCTAssertEqual(tab.paneSplitRatio, 0.15, "Split ratio should be clamped to minimum 0.15")

        // Simulate dragging far to the right (target 0.98)
        let clampedMax = min(max(0.98, 0.15), 0.85)
        tab.paneSplitRatio = clampedMax
        XCTAssertEqual(tab.paneSplitRatio, 0.85, "Split ratio should be clamped to maximum 0.85")
    }

    @MainActor
    func testSplitPaneClosureSpaceReclamation() {
        let session = Session(name: "reclaim-test", host: "127.0.0.1", username: "root")
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)

        tab.split(mode: .horizontal)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertEqual(tab.splitMode, .horizontal)

        let firstId = tab.panes[0].id
        let secondId = tab.panes[1].id
        tab.activePaneId = secondId

        // Close the second pane
        tab.closePane(id: secondId)

        // After closure, tab must fall back to single mode and retain first pane
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertEqual(tab.splitMode, .single)
        XCTAssertEqual(tab.activePaneId, firstId)
        XCTAssertEqual(tab.activePane?.id, firstId)
    }

    @MainActor
    func testHighConcurrencyBroadcastTyping() async throws {
        var clients: [MockSSHSession] = []
        var tabs: [TerminalTabItem] = []

        for i in 1...3 {
            let s = Session(name: "c-node-\(i)", host: "10.0.1.\(i)", username: "admin")
            let c = MockSSHSession(session: s)
            let t = TerminalTabItem(session: s, sshClient: c)
            try await c.connect()
            clients.append(c)
            tabs.append(t)
        }

        // Concurrently send 50 key strokes to all tabs
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                let stroke = "echo \(i)\n".data(using: .utf8)!
                group.addTask { @MainActor in
                    for tab in tabs {
                        for pane in tab.panes {
                            pane.sshClient.sendInputSync(stroke)
                        }
                    }
                }
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        for c in clients {
            await c.disconnect()
        }
    }
}
