import XCTest
@testable import ApexCore
@testable import ApexTerminal

final class DesktopNotificationTests: XCTestCase {

    private final class MockNotificationDeliverer: DesktopNotificationDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var _delivered: [DesktopNotificationPayload] = []

        var delivered: [DesktopNotificationPayload] {
            lock.withLock { _delivered }
        }

        func deliver(_ payload: DesktopNotificationPayload) {
            lock.withLock { _delivered.append(payload) }
        }
    }

    private final class MockBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T

        init(_ value: T) {
            self._value = value
        }

        var value: T {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private final class MockOSCNotificationCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [(title: String?, body: String)] = []

        var items: [(title: String?, body: String)] {
            lock.withLock { _items }
        }

        func append(title: String?, body: String) {
            lock.withLock { _items.append((title: title, body: body)) }
        }
    }

    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "com.apexterm.tests.desktop-notify.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    // MARK: - TC-V29-12: Command duration threshold + exit code & formatted duration
    @MainActor
    func testTC_V29_12_CommandDurationThresholdAndContent() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let sink = MockNotificationDeliverer()
        let tabID = UUID()
        let manager = DesktopNotificationManager(
            defaults: defaults,
            deliverer: sink,
            isAppActive: { false },
            activeTabID: { nil }
        )
        manager.minimumCommandDurationSeconds = 10.0

        // Below threshold (9.99s) -> suppressed
        let shortRecord = CommandExecutionRecord(
            commandText: "ls -la",
            promptStartLine: 0,
            commandStartLine: 0,
            outputStartLine: 1,
            outputEndLine: 2,
            durationMs: 9_999,
            exitCode: 0
        )
        manager.handleCommandCompleted(record: shortRecord, tabID: tabID, sessionTitle: "prod-web-01")
        XCTAssertTrue(sink.delivered.isEmpty)

        // At threshold (10.00s) -> delivered with exit code & formatted duration
        let thresholdRecord = CommandExecutionRecord(
            commandText: "cargo build --release",
            promptStartLine: 3,
            commandStartLine: 3,
            outputStartLine: 4,
            outputEndLine: 20,
            durationMs: 10_000,
            exitCode: 0
        )
        manager.handleCommandCompleted(record: thresholdRecord, tabID: tabID, sessionTitle: "prod-web-01")

        // Non-zero exit code >= threshold -> delivered with exit code & formatted duration
        let failedRecord = CommandExecutionRecord(
            commandText: "make deploy",
            promptStartLine: 21,
            commandStartLine: 21,
            outputStartLine: 22,
            outputEndLine: 30,
            durationMs: 65_000,
            exitCode: 2
        )
        manager.handleCommandCompleted(record: failedRecord, tabID: tabID, sessionTitle: "prod-web-01")

        XCTAssertEqual(sink.delivered.count, 2)
        let first = sink.delivered[0]
        XCTAssertEqual(first.tabID, tabID)
        XCTAssertEqual(first.userInfo["tabID"], tabID.uuidString)
        XCTAssertTrue(first.body.contains("0"))
        XCTAssertTrue(first.body.contains(thresholdRecord.formattedDuration))

        let second = sink.delivered[1]
        XCTAssertTrue(second.title.contains("2") || second.body.contains("2"))
        XCTAssertTrue(second.body.contains(failedRecord.formattedDuration))

        // Also verify ShellIntegrationTracker.onCommandCompleted fires outside its lock (no deadlock on re-entrant read)
        let tracker = ShellIntegrationTracker()
        let callbackRecord = MockBox<CommandExecutionRecord?>(nil)
        let trackerRecordsCount = MockBox<Int>(0)
        tracker.onCommandCompleted = { record in
            callbackRecord.value = record
            trackerRecordsCount.value = tracker.allRecords().count
        }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        tracker.handleOSCPayload("133;A", currentLineIndex: 0, timestamp: t0)
        tracker.handleOSCPayload("133;C;sleep 12", currentLineIndex: 0, timestamp: t0)
        tracker.handleOSCPayload("133;D;0", currentLineIndex: 1, timestamp: t0.addingTimeInterval(12.5))
        XCTAssertEqual(callbackRecord.value?.commandText, "sleep 12")
        XCTAssertEqual(trackerRecordsCount.value, 1)

        // Verify resetPreferences() restores factory defaults
        manager.notificationsEnabled = false
        manager.onlyWhenInactiveOrBackgroundTab = false
        manager.minimumCommandDurationSeconds = 42.0
        manager.notifyOnOSCSequences = false
        manager.playSound = true
        manager.resetPreferences()
        XCTAssertTrue(manager.notificationsEnabled)
        XCTAssertTrue(manager.onlyWhenInactiveOrBackgroundTab)
        XCTAssertEqual(manager.minimumCommandDurationSeconds, 10.0)
        XCTAssertTrue(manager.notifyOnOSCSequences)
        XCTAssertFalse(manager.playSound)
    }

    // MARK: - TC-V29-13: Foreground focus suppression vs background tab / inactive app
    @MainActor
    func testTC_V29_13_FocusSuppressionAndBackgroundTriggering() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let sink = MockNotificationDeliverer()
        let targetTab = UUID()
        let otherTab = UUID()
        var appActive = true
        var focusedTab: UUID? = targetTab

        let manager = DesktopNotificationManager(
            defaults: defaults,
            deliverer: sink,
            isAppActive: { appActive },
            activeTabID: { focusedTab }
        )
        manager.onlyWhenInactiveOrBackgroundTab = true
        manager.minimumCommandDurationSeconds = 1.0

        let record = CommandExecutionRecord(
            commandText: "pytest",
            promptStartLine: 0,
            commandStartLine: 0,
            outputStartLine: 1,
            durationMs: 5_000,
            exitCode: 0
        )

        // Active app + active tab == targetTab -> suppressed
        manager.handleCommandCompleted(record: record, tabID: targetTab, sessionTitle: "api-server")
        manager.handleOSCNotification(title: "Build", body: "Done", tabID: targetTab, sessionTitle: "api-server")
        XCTAssertTrue(sink.delivered.isEmpty)

        // Active app + different tab focused (background tab) -> triggers
        focusedTab = otherTab
        manager.handleCommandCompleted(record: record, tabID: targetTab, sessionTitle: "api-server")
        XCTAssertEqual(sink.delivered.count, 1)

        // Same tab focused, but app is inactive -> triggers
        focusedTab = targetTab
        appActive = false
        manager.handleOSCNotification(title: "Deploy", body: "Finished", tabID: targetTab, sessionTitle: "api-server")
        XCTAssertEqual(sink.delivered.count, 2)
    }

    // MARK: - TC-V29-14: RingBuffer OSC 9 & OSC 777 parsing and OSC 9;4 progress ignore
    func testTC_V29_14_RingBufferOSC9And777ParsingIgnoresProgress() {
        let buffer = TerminalRingBuffer(maxLines: 100)
        let collector = MockOSCNotificationCollector()
        buffer.onDesktopNotification = { title, body in
            collector.append(title: title, body: body)
        }

        // ConEmu / Windows Terminal progress reporting (9;4;...) must be ignored cleanly
        buffer.appendStream("\u{1B}]9;4;1;50\u{07}")
        buffer.appendStream("\u{1B}]9;4;0\u{1B}\\")
        buffer.appendStream("\u{1B}]9;4;2;80\u{07}")
        XCTAssertTrue(collector.items.isEmpty)

        // OSC 9 with BEL and ST terminators
        buffer.appendStream("\u{1B}]9;Backup completed\u{07}")
        buffer.appendStream("\u{1B}]9;Disk snapshot ready\u{1B}\\")

        // OSC 777 notify with BEL and ST terminators
        buffer.appendStream("\u{1B}]777;notify;Build System;All 42 targets succeeded\u{07}")
        buffer.appendStream("\u{1B}]777;notify;CI;Stage;one;passed\u{1B}\\")

        // Visible terminal text after OSC must remain intact
        buffer.appendStream("prompt$ \n")
        XCTAssertEqual(buffer.allLines(), ["prompt$ "])

        let items = collector.items
        XCTAssertEqual(items.count, 4)
        XCTAssertNil(items[0].title)
        XCTAssertEqual(items[0].body, "Backup completed")
        XCTAssertNil(items[1].title)
        XCTAssertEqual(items[1].body, "Disk snapshot ready")
        XCTAssertEqual(items[2].title, "Build System")
        XCTAssertEqual(items[2].body, "All 42 targets succeeded")
        XCTAssertEqual(items[3].title, "CI")
        XCTAssertEqual(items[3].body, "Stage;one;passed")
    }

    // MARK: - TC-V29-15: Control-char sanitization, <=1024 byte cap & per-tab burst rate limiting
    @MainActor
    func testTC_V29_15_SanitizationSizeBoundAndRateLimiting() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // RingBuffer-level sanitization & 1024-byte cap
        let buffer = TerminalRingBuffer(maxLines: 50)
        let collector = MockOSCNotificationCollector()
        buffer.onDesktopNotification = { title, body in
            collector.append(title: title, body: body)
        }
        let oversized = String(repeating: "A", count: 2500)
        buffer.appendStream("\u{1B}]9;hi\u{0001}\u{0008}\nnext\t\(oversized)\u{1B}\\")
        XCTAssertEqual(collector.items.count, 1)
        let parsedBody = collector.items[0].body
        XCTAssertLessThanOrEqual(parsedBody.utf8.count, 1024)
        XCTAssertFalse(parsedBody.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })

        // Manager-level sanitization + per-tab rate limiting
        let sink = MockNotificationDeliverer()
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        let manager = DesktopNotificationManager(
            defaults: defaults,
            deliverer: sink,
            isAppActive: { false },
            activeTabID: { nil },
            now: { currentTime },
            rateLimitWindow: 10.0,
            maxNotificationsPerTabInWindow: 2
        )

        let tabA = UUID()
        let tabB = UUID()

        // Burst of 5 notifications on tabA -> capped at 2
        for idx in 1...5 {
            manager.handleOSCNotification(
                title: "Alert\u{0007}\(idx)",
                body: "Line1\u{001B}[31m\nLine2 \(String(repeating: "x", count: 1500))",
                tabID: tabA,
                sessionTitle: "host-a"
            )
        }
        XCTAssertEqual(sink.delivered.count, 2)
        for payload in sink.delivered {
            XCTAssertLessThanOrEqual(payload.body.utf8.count, 1024)
            XCTAssertFalse(payload.title.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
            XCTAssertFalse(payload.body.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
        }

        // Independent tabB is not blocked by tabA's burst limit
        manager.handleOSCNotification(title: nil, body: "Tab B ready", tabID: tabB, sessionTitle: "host-b")
        XCTAssertEqual(sink.delivered.count, 3)

        // Advancing time past rateLimitWindow restores quota for tabA
        currentTime = currentTime.addingTimeInterval(11.0)
        manager.handleOSCNotification(title: nil, body: "After cooldown", tabID: tabA, sessionTitle: "host-a")
        XCTAssertEqual(sink.delivered.count, 4)
    }

    // MARK: - TC-V29-16: Notification click routing posts focus notification with matching UUID
    @MainActor
    func testTC_V29_16_RouteNotificationClickPostsMatchingTabUUID() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let sink = MockNotificationDeliverer()
        let manager = DesktopNotificationManager(defaults: defaults, deliverer: sink)
        let expectedTabID = UUID()

        let receivedTabID = MockBox<UUID?>(nil)
        let exp = expectation(description: "Focus tab notification posted")
        let token = NotificationCenter.default.addObserver(
            forName: DesktopNotificationManager.focusTabNotification,
            object: nil,
            queue: .main
        ) { notif in
            receivedTabID.value = (notif.object as? UUID) ?? (notif.userInfo?["tabID"] as? UUID)
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.routeNotificationClick(userInfo: ["tabID": expectedTabID.uuidString])
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(receivedTabID.value, expectedTabID)
    }
}
