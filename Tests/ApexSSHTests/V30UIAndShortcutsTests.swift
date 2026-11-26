import XCTest
import SwiftUI
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

@MainActor
final class V30UIAndShortcutsTests: XCTestCase {

    // MARK: - TC-V30-25: ApexShortcutRegistry zero duplicate shortcuts & ⌘⇧F conflict resolution
    func testTC_V30_25_ShortcutRegistryZeroDuplicatesAndToggleSFTPConflictFixed() {
        let duplicates = ApexShortcutRegistry.duplicateKeyboardShortcuts()
        XCTAssertTrue(duplicates.isEmpty, "Shortcut registry must contain zero duplicate keyboard shortcuts: \(duplicates)")

        XCTAssertEqual(ApexShortcutRegistry.shortcutHint(for: .toggleSFTP), "⌘⌥S")
        XCTAssertEqual(ApexShortcutRegistry.shortcutHint(for: .sftpRemoteSearch), "⌘⇧F")
        XCTAssertEqual(CommandPaletteAppAction.toggleSFTP.shortcutHint, "⌘⌥S")
        XCTAssertNotEqual(CommandPaletteAppAction.toggleSFTP.shortcutHint, "⌘⇧F")

        let expectedKeys: [(ApexShortcutActionKey, String)] = [
            (.lockApp, "⌘⇧L"),
            (.openBatchOperations, "⌘⌥B"),
            (.toggleSFTP, "⌘⌥S"),
            (.findNext, "⌘G"),
            (.findPrevious, "⌘⇧G"),
            (.selectAllTerminal, "⌘A"),
            (.showMainWindow, "⌘⇧0"),
            (.toggleFullScreen, "⌘⌃F")
        ]
        for (key, expected) in expectedKeys {
            XCTAssertEqual(ApexShortcutRegistry.shortcutHint(for: key), expected, "Missing or mismatched shortcut for \(key)")
        }

        // Verify ShortcutsSheetView reflects ApexShortcutRegistry cleanly
        let sheet = ShortcutsSheetView()
        let mirror = Mirror(reflecting: sheet)
        let groups = mirror.children.first(where: { $0.label == "groups" })?.value as? [Any]
        XCTAssertNotNil(groups)
        let sheetDescriptions = (groups ?? []).flatMap { group -> [String] in
            let gm = Mirror(reflecting: group)
            let items = gm.children.first(where: { $0.label == "items" })?.value as? [Any] ?? []
            return items.compactMap { item in
                Mirror(reflecting: item).children.first(where: { $0.label == "description" })?.value as? String
            }
        }
        XCTAssertTrue(sheetDescriptions.contains(where: { $0.contains("Toggle SFTP Panel") || $0.contains("SFTP 文件管理面板") }))
        XCTAssertTrue(sheetDescriptions.contains(where: { $0.contains("Find Next") }))
        XCTAssertTrue(sheetDescriptions.contains(where: { $0.contains("Lock App") }))
    }

    // MARK: - TC-V30-26: CommandPaletteAppAction completeness, notifications & close/zoom guardrails
    func testTC_V30_26_CommandPaletteActionsNotificationsAndCloseGuardrails() {
        let requiredCases: [CommandPaletteAppAction] = [
            .toggleBroadcast,
            .lockApp,
            .openProcessInspector,
            .copyLastCommandOutput,
            .reconnectSession,
            .newSession,
            .importSSHConfig
        ]
        for action in requiredCases {
            XCTAssertTrue(CommandPaletteAppAction.allCases.contains(action))
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.iconName.isEmpty)
        }
        XCTAssertEqual(CommandPaletteAppAction.lockApp.shortcutHint, "⌘⇧L")
        XCTAssertEqual(CommandPaletteAppAction.openProcessInspector.shortcutHint, "⌘⌥K")
        XCTAssertEqual(CommandPaletteAppAction.copyLastCommandOutput.shortcutHint, "⌘⌥C")
        XCTAssertEqual(CommandPaletteAppAction.reconnectSession.shortcutHint, "⌘R")

        XCTAssertEqual(WorkspaceView.clearTerminalScreenNotification, Notification.Name("ApexTermClearTerminalScreen"))
        XCTAssertEqual(WorkspaceView.requestCloseCurrentTabNotification, Notification.Name("ApexTermRequestCloseCurrentTab"))

        // Tab close guardrails: external edit + alternate screen + running foreground command
        let session = Session(name: "guard", host: "10.0.0.5", username: "ops")
        let tab = TerminalTabItem(session: session, sshClient: MockSSHSession(session: session))
        defer { tab.tearDown() }

        let activeEdit = ExternalEditSessionManager.ActiveEditSession(
            id: UUID(),
            tabID: tab.id,
            sessionName: session.name,
            remotePath: "/etc/nginx/nginx.conf",
            localURL: URL(fileURLWithPath: "/tmp/nginx.conf"),
            editorName: "TextEdit",
            status: .watching
        )
        let editGuard = WorkspaceView.closeGuardSummary(for: [tab], externalEditSessions: [activeEdit])
        XCTAssertTrue(editGuard.requiresConfirmation)
        XCTAssertEqual(editGuard.activeExternalEditsCount, 1)
        XCTAssertEqual(editGuard.activeExternalEditFiles, ["nginx.conf"])

        // Live TUI (alternate screen) when connected
        tab.panes[0].connectionState = .connected
        tab.panes[0].ringBuffer.appendData(Data("\u{1B}[?1049h".utf8))
        let tuiGuard = WorkspaceView.closeGuardSummary(for: [tab], externalEditSessions: [])
        XCTAssertTrue(tuiGuard.requiresConfirmation)
        XCTAssertEqual(tuiGuard.liveTUICount, 1)

        // Split resets isPaneMaximized = false
        tab.split(mode: .vertical)
        tab.toggleMaximizeActivePane()
        XCTAssertTrue(tab.isPaneMaximized)
        tab.split(mode: .horizontal)
        XCTAssertFalse(tab.isPaneMaximized, "Splitting or changing split mode must exit zoom state")
        XCTAssertEqual(tab.splitMode, .horizontal)
    }

    // MARK: - TC-V30-27: SSHConfigImportSheet host+name matching & Broadcast target counting/routing
    func testTC_V30_27_SSHConfigImportMatchingAndBroadcastTargets() async throws {
        // 1. SSHConfigImportSheet matching requires both name AND host
        let existingWeb = Session(name: "web", host: "10.0.0.10", username: "deploy")
        let incomingDifferentHost = Session(name: "web", host: "192.168.1.50", username: "ubuntu")
        let incomingSameHost = Session(name: "web", host: "10.0.0.10", username: "ubuntu")

        XCTAssertNil(
            SSHConfigImportSheet.findMatchingSession(for: incomingDifferentHost, in: [existingWeb]),
            "Same alias on a different host must NOT overwrite existing session"
        )
        XCTAssertEqual(
            SSHConfigImportSheet.findMatchingSession(for: incomingSameHost, in: [existingWeb])?.id,
            existingWeb.id
        )

        // 2. Broadcast targets count distinct connected tabs (no split-pane double-sending)
        let s1 = Session(name: "prod-1", host: "10.0.1.1", username: "ops")
        let s2 = Session(name: "prod-2", host: "10.0.1.2", username: "ops")
        let s3 = Session(name: "offline-3", host: "10.0.1.3", username: "ops")

        let c1 = MockSSHSession(session: s1)
        let c2 = MockSSHSession(session: s2)
        let c3 = MockSSHSession(session: s3)

        let t1 = TerminalTabItem(session: s1, sshClient: c1)
        let t2 = TerminalTabItem(session: s2, sshClient: c2)
        let t3 = TerminalTabItem(session: s3, sshClient: c3)
        defer {
            t1.tearDown()
            t2.tearDown()
            t3.tearDown()
        }

        // Connect t1 (with 2 split panes) and t2; leave t3 disconnected
        let c1Split = MockSSHSession(session: s1)
        try await c1.connect()
        t1.panes[0].connectionState = .connected
        t1.split(mode: .vertical, sshClient: c1Split)
        try await Task.sleep(nanoseconds: 50_000_000)
        t1.panes[0].connectionState = .connected
        t1.panes[1].connectionState = .connected
        t1.activePaneId = t1.panes[1].id

        try await c2.connect()
        t2.panes[0].connectionState = .connected

        t3.panes[0].connectionState = .disconnected

        let tabs = [t1, t2, t3]
        XCTAssertEqual(WorkspaceView.broadcastTargetCount(in: tabs), 2, "Only connected distinct tabs count as broadcast targets")
        XCTAssertEqual(WorkspaceView.broadcastRemoteTargetCount(in: tabs), 2)
        XCTAssertTrue(BroadcastBar.requiresEnableConfirmation(remoteTargetCount: 2))
        XCTAssertFalse(BroadcastBar.requiresEnableConfirmation(remoteTargetCount: 1))

        let payload = Data("uname -a\n".utf8)
        WorkspaceView.dispatchInputPayload(
            payload,
            activePane: t1.panes[1],
            activeTab: t1,
            allTabs: tabs,
            isBroadcastActive: true
        )

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(c1Split.sentInputs, [payload])
        XCTAssertTrue(c1.sentInputs.isEmpty, "Must NOT double-send across split panes in the same tab")
        XCTAssertEqual(c2.sentInputs, [payload])
        XCTAssertTrue(c3.sentInputs.isEmpty, "Disconnected tab must not receive broadcast payload")
    }

    // MARK: - TC-V30-28: QuickCommandBar autoExecute & {{host}}/{{user}} interpolation
    func testTC_V30_28_QuickCommandBarAutoExecuteAndContextInterpolation() {
        let session = Session(name: "edge-api", host: "api.prod.internal", username: "deployer")
        let ctx = QuickCommandBarView.context(for: session)
        XCTAssertEqual(ctx["host"], "api.prod.internal")
        XCTAssertEqual(ctx["user"], "deployer")

        let manualSnippet = Snippet(
            title: "Check Remote Host",
            command: "ssh {{user}}@{{host}} systemctl status {{service}}",
            category: "系统",
            autoExecute: false
        )
        XCTAssertEqual(manualSnippet.unresolvedVariables(context: ctx), ["service"])

        let filledContext = ctx.merging(["service": "nginx"]) { _, new in new }
        let insertedPayload = QuickCommandBarView.executionPayload(for: manualSnippet, context: filledContext)
        XCTAssertEqual(insertedPayload, "ssh deployer@api.prod.internal systemctl status nginx")
        XCTAssertFalse(insertedPayload.hasSuffix("\n"), "autoExecute == false must NOT append newline automatically")

        let confirmedPayload = QuickCommandBarView.executionPayload(
            for: manualSnippet,
            context: filledContext,
            executeImmediately: true
        )
        XCTAssertEqual(confirmedPayload, "ssh deployer@api.prod.internal systemctl status nginx\n")

        let autoSnippet = Snippet(
            title: "Host Info",
            command: "echo {{user}}@{{host}}",
            category: "系统",
            autoExecute: true
        )
        XCTAssertTrue(autoSnippet.unresolvedVariables(context: ctx).isEmpty)
        XCTAssertEqual(
            QuickCommandBarView.executionPayload(for: autoSnippet, context: ctx),
            "echo deployer@api.prod.internal\n"
        )
    }
}
