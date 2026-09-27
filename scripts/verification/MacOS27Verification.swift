import SwiftUI
import AppKit
import ApexCore
import ApexSSH
import ApexUI

@main
struct ThemeVerificationApp: App {
    @ObservedObject private var settings = AppSettings.shared
    private let store: SessionStore
    @State private var tabs: [TerminalTabItem] = []
    @State private var selectedID: UUID?
    @State private var selectedSession: Session?
    @State private var scene = ProcessInfo.processInfo.environment["APEX_QA_SCENE"] ?? "main"
    @State private var editorContent = "# 示例配置\nserver=demo\nport=22\n"
    private let telemetry = QAProcessTelemetry()
    private let tab: TerminalTabItem
    private let importConfigURL: URL
    init() {
        let directory = qaRepositoryRoot.appendingPathComponent("outputs/macos27/qa/store-" + (Bundle.main.bundleIdentifier ?? "verification"))
        store = SessionStore(baseDirectory: directory)
        importConfigURL = directory.appendingPathComponent("ssh-config")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "Host qa-demo\n    HostName 192.0.2.10\n    User demo\n".write(to: importConfigURL, atomically: true, encoding: .utf8)
        let session = Session(name: "主题验收 · 演示", host: "192.0.2.10", username: "demo", agentlessMonitorEnabled: ProcessInfo.processInfo.environment["APEX_QA_MONITOR"] != "0")
        store.sessions = [session]
        let client: SSHSessionProtocol = ProcessInfo.processInfo.environment["APEX_QA_FILES"].map { QAFileSession(session: session, mode: $0) } ?? MockSSHSession(session: session)
        tab = TerminalTabItem(session: session, sshClient: client)
        _tabs = State(initialValue: [tab])
        _selectedID = State(initialValue: tab.id)
        _selectedSession = State(initialValue: session)
        tab.connectionState = .connected
        tab.panes[0].connectionState = .connected
        if ProcessInfo.processInfo.environment["APEX_QA_SCENE"] == "metrics" {
            tab.metricsHistory.append(ServerMetricsSnapshot(cpuUsagePercent: 24, cpuCores: 8, cpuModel: "示例服务器", memoryTotalBytes: 8_589_934_592, memoryUsedBytes: 3_221_225_472))
        }
        if let lines = ProcessInfo.processInfo.environment["APEX_QA_LINES"].flatMap(Int.init), lines > 0 {
            _editorContent = State(initialValue: (0..<lines).map { "配置行 \($0) = 示例内容" }.joined(separator: "\n"))
        }
        tab.ringBuffer.appendStream("demo@host $ ls\n\u{1B}[31mERROR demo\u{1B}[0m\n\u{1B}[32mOK demo\u{1B}[0m\n\u{1B}[33mWARN demo\u{1B}[0m\n")
    }
    var body: some Scene {
        WindowGroup("ApexTerm 主题验收") {
            Group {
            if scene == "editor" {
                QuickEditorView(item: SFTPItem(name: "demo.conf", path: "/demo.conf", isDirectory: false), content: $editorContent, onSave: { _ in try await Task.sleep(for: .seconds(8)) }, onReload: { "# 远端配置\nserver=demo\n" })
            } else if scene == "settings" {
                SettingsView(initialTab: 1)
            } else if scene == "about" {
                AboutView()
            } else if scene == "shortcuts" {
                ShortcutsSheetView()
            } else if scene == "transfers" {
                TransferDrawer(isExpanded: .constant(true))
            } else if scene == "metrics" {
                MetricCapsuleView(historyStore: tab.metricsHistory)
            } else if scene == "import" {
                #if APEX_BASELINE
                Text("旧版导入界面请使用正式 App 验证")
                #else
                SSHConfigImportSheet(store: store, configURL: importConfigURL)
                #endif
            } else if scene == "session" {
                SessionEditModal(session: store.sessions.first, onSave: { _ in })
            } else {
            NavigationSplitView {
                SidebarView(store: store, selectedSession: $selectedSession, onConnect: { _ in }, onRunSnippet: { _ in })
                    .frame(minWidth: 260, idealWidth: 290, maxWidth: 370)
            } detail: {
                WorkspaceView(store: store, activeTabs: $tabs, selectedTabId: $selectedID)
            }
            .navigationSplitViewStyle(.balanced)
            }
            }
            .apexTheme()
            .frame(minWidth: scene == "main" ? 960 : 0, minHeight: scene == "main" ? 640 : 0)
            .onChange(of: scene) { _, page in
                if page == "metrics" && tab.metricsHistory.latest == nil {
                    tab.metricsHistory.append(ServerMetricsSnapshot(cpuUsagePercent: 24, cpuCores: 8, cpuModel: "示例服务器", memoryTotalBytes: 8_589_934_592, memoryUsedBytes: 3_221_225_472))
                }
                let sizes: [String: NSSize] = ["main": NSSize(width: 1100, height: 760), "settings": NSSize(width: 580, height: 460), "session": NSSize(width: 560, height: 560), "about": NSSize(width: 520, height: 650), "shortcuts": NSSize(width: 580, height: 480), "editor": NSSize(width: 900, height: 650), "transfers": NSSize(width: 900, height: 420), "metrics": NSSize(width: 500, height: 300), "import": NSSize(width: 620, height: 500)]
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil })?.setContentSize(sizes[page] ?? NSSize(width: 1100, height: 760))
                }
            }
            .task {
                telemetry.start()
                if let delay = ProcessInfo.processInfo.environment["APEX_QA_ACTIVATE_DELAY"].flatMap(Double.init) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil })?.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
                NSApplication.shared.setActivationPolicy(.regular)
                if ProcessInfo.processInfo.environment["APEX_QA_SOAK"] != "1" { NSApplication.shared.activate(ignoringOtherApps: true) }
                if ProcessInfo.processInfo.environment["APEX_QA_CONNECT"] == "1" || ProcessInfo.processInfo.environment["APEX_QA_SOAK"] == "1" {
                    try? await tab.sshClient.connect()
                    tab.connectionState = tab.sshClient.connectionState
                }
                if ProcessInfo.processInfo.environment["APEX_QA_SOAK"] == "1" {
                    await runSoak()
                }
            }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            CommandGroup(after: .pasteboard) {
                Button("查找…") {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable, !editor.isFieldEditor {
                        let action = NSMenuItem()
                        action.tag = NSTextFinder.Action.showFindInterface.rawValue
                        editor.performTextFinderAction(action)
                    } else {
                        NotificationCenter.default.post(name: NSNotification.Name("TriggerSFTPFind"), object: nil)
                        NotificationCenter.default.post(name: NSNotification.Name("TriggerTerminalFind"), object: nil)
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("验收页面") {
                ForEach(["main", "editor", "settings", "session", "about", "shortcuts", "transfers", "metrics", "import"], id: \.self) { page in
                    Button(page) { scene = page }
                }
            }
            CommandMenu("验收主题") {
                ForEach(TerminalThemePreset.selectablePresets, id: \.self) { theme in
                    Button(theme.rawValue) { settings.themePreset = theme }
                }
            }
        }
    }
    @MainActor
    private func runSoak() async {
        let root = qaRepositoryRoot.appendingPathComponent("outputs/macos27/soak")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let upload = root.appendingPathComponent("payload.bin")
        let download = root.appendingPathComponent("roundtrip.bin")
        let payload = Data(repeating: 0x5A, count: 256 * 1024)
        try? payload.write(to: upload)
        let start = ContinuousClock.now
        var cycle = 0
        var transfers = 0
        var echoes = 0
        var failures: [String] = []
        let manager = TransferManager.shared
        func report(completed: Bool) {
            let data: [String: Any] = ["completed": completed, "elapsed": start.duration(to: .now).description,
                "outputLines": cycle * 80, "committedLines": tab.ringBuffer.committedLineCount,
                "historyLimit": tab.ringBuffer.maxLines, "transferChecks": transfers,
                "transferRecords": manager.tasks.count, "inputChecks": echoes, "metricHistory": tab.metricsHistory.snapshots.count,
                "failures": failures]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]) {
                try? json.write(to: root.appendingPathComponent("progress.json"), options: .atomic)
            }
        }
        while start.duration(to: .now) < .seconds(1800) && !Task.isCancelled {
            let logs = (0..<80).map { "[QA] cycle=\(cycle) row=\($0) status=OK simulated output for bounded scrollback\n" }.joined()
            tab.ringBuffer.appendStream(logs)
            if cycle % 100 == 0 {
                let marker = "QA_INPUT_\(cycle)"
                try? await tab.sshClient.sendInput(Data((marker + "\n").utf8))
                if tab.ringBuffer.tailLines(count: 20).contains(where: { $0.contains(marker) }) { echoes += 1 }
                else { failures.append("Missing input marker at cycle \(cycle)") }
            }
            if cycle % 300 == 0 {
                manager.enqueueUpload(session: tab.sshClient, localURL: upload, remotePath: "/qa-payload.bin")
                while manager.activeCount > 0 && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                manager.enqueueDownload(session: tab.sshClient, remotePath: "/qa-payload.bin", localURL: download, totalBytes: Int64(payload.count))
                while manager.activeCount > 0 && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                if (try? Data(contentsOf: download)) == payload { transfers += 1 }
                else { failures.append("Transfer contents mismatch at cycle \(cycle)") }
            }
            cycle += 1
            if cycle % 100 == 0 { report(completed: false) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        report(completed: !Task.isCancelled && start.duration(to: .now) >= .seconds(1800))
        await tab.sshClient.disconnect()
        try? await Task.sleep(for: .seconds(30))
        NSApplication.shared.terminate(nil)
    }

}
