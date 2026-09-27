import SwiftUI
import AppKit
import ApexCore
import ApexSSH
import ApexUI
import ApexTerminal

@MainActor
final class VerificationAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ThemeVerificationApp: App {
    @NSApplicationDelegateAdaptor(VerificationAppDelegate.self) private var appDelegate
    @ObservedObject private var settings = AppSettings.shared
    private let store: SessionStore
    @State private var tabs: [TerminalTabItem] = []
    @State private var selectedID: UUID?
    @State private var selectedSession: Session?
    @State private var scene = ProcessInfo.processInfo.environment["APEX_QA_SCENE"] ?? "main"
    @State private var editorContent = "# 示例配置\nserver=demo\nport=22\n"
    @State private var updatePresented = true
    @State private var editorPresented = true
    private let telemetry = QAProcessTelemetry()
    private let tab: TerminalTabItem
    private let importConfigURL: URL
    init() {
        let directory = qaRepositoryRoot.appendingPathComponent("outputs/macos27/qa/store-" + (Bundle.main.bundleIdentifier ?? "verification"))
        store = SessionStore(baseDirectory: directory)
        importConfigURL = directory.appendingPathComponent("ssh-config")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "Host qa-demo\n    HostName 192.0.2.10\n    User demo\n".write(to: importConfigURL, atomically: true, encoding: .utf8)
        let environment = ProcessInfo.processInfo.environment
        let realHost = environment["APEX_QA_REAL_HOST"]
        var session = Session(name: "主题验收 · 演示", host: realHost ?? "192.0.2.10", username: environment["APEX_QA_REAL_USER"] ?? "demo", authMethod: .password(keychainRef: ""), agentlessMonitorEnabled: environment["APEX_QA_MONITOR"] != "0")
        if environment["APEX_QA_SESSION_AUTH"] == "private-key" {
            session.authMethod = .privateKey(keychainRef: "synthetic-key-reference", passphraseRef: "synthetic-passphrase-reference")
            session.jumpServerId = UUID(uuidString: "00000000-0000-0000-0000-000000000123")
            session.keepAliveIntervalSeconds = 47
            session.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            session.lastConnectedAt = Date(timeIntervalSince1970: 1_700_000_100)
        }
        store.sessions = [session]
        let client: SSHSessionProtocol = realHost != nil
            ? NativeSSHSession(session: session)
            : environment["APEX_QA_FILES"].map { QAFileSession(session: session, mode: $0) } ?? MockSSHSession(session: session)
        tab = TerminalTabItem(session: session, sshClient: client)
        if let remotePath = environment["APEX_QA_REMOTE_PATH"] { tab.currentRemotePath = remotePath }
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
        WindowGroup("ApexTerm 主题验收 · " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Verification")) {
            Group {
            if scene == "editor" {
                QuickEditorView(item: SFTPItem(name: "demo.conf", path: "/demo.conf", isDirectory: false), content: $editorContent, onSave: { _ in try await Task.sleep(for: .seconds(8)) }, onReload: { "# 远端配置\nserver=demo\n" })
            } else if scene == "editor-sheet" {
                VStack {
                    Text("编辑器弹窗验收")
                    Button("显示编辑器") { editorPresented = true }
                }
                .frame(width: 900, height: 650)
                .sheet(isPresented: $editorPresented) {
                    QuickEditorView(item: SFTPItem(name: "demo.conf", path: "/demo.conf", isDirectory: false), content: $editorContent, onSave: { _ in
                        try await Task.sleep(for: .seconds(2))
                        if ProcessInfo.processInfo.environment["APEX_QA_EDITOR_SAVE"] == "failure" {
                            throw NSError(domain: "ApexTerm.QA", code: 13, userInfo: [NSLocalizedDescriptionKey: "验收模拟：远端写入权限不足"])
                        }
                    }, onReload: { "# 远端配置\nserver=demo\n" })
                    .apexTheme()
                }
            } else if scene == "settings" {
                SettingsView(initialTab: 1)
            } else if scene == "about" {
                AboutView()
            } else if scene == "update" {
                VStack {
                    Text("更新弹窗验收")
                    Button("显示更新弹窗") { updatePresented = true }
                }
                .frame(width: 560, height: 360)
                .sheet(isPresented: $updatePresented) { UpdateSheetView() }
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
                SessionEditModal(session: store.sessions.first, onSave: { saved in
                    guard ProcessInfo.processInfo.environment["APEX_QA_SESSION_AUTH"] == "private-key" else { return }
                    let resultURL = qaRepositoryRoot.appendingPathComponent("outputs/macos27/qa/session-private-key-saved.json")
                    do {
                        try JSONEncoder().encode(saved).write(to: resultURL, options: .atomic)
                    } catch {
                        NSLog("Unable to write synthetic session acceptance result: %@", error.localizedDescription)
                    }
                })
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
                if scene == "update" {
                    switch ProcessInfo.processInfo.environment["APEX_QA_UPDATE_STATE"] {
                    case "checking": UpdateManager.shared.status = .checking
                    case "failed": UpdateManager.shared.status = .failed("验收模拟：更新服务器暂时不可用，请稍后重试。")
                    default: UpdateManager.shared.status = .upToDate(currentVersion: "1.3.0")
                    }
                }
                // The initial scene does not trigger onChange, and restored window geometry
                // can be smaller than a fixed-size form. Apply its real content size once.
                if scene == "session" {
                    try? await Task.sleep(for: .milliseconds(100))
                    NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil })?.setContentSize(NSSize(width: 560, height: 560))
                }
                telemetry.start()
                if ProcessInfo.processInfo.environment["APEX_QA_KEY_DIAGNOSTICS"] == "1" {
                    var observedTerminals = Set<ObjectIdentifier>()
                    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        let terminal = NSApp.keyWindow?.firstResponder as? NativeTerminalView
                        if let terminal, observedTerminals.insert(ObjectIdentifier(terminal)).inserted,
                           let originalInput = terminal.onInput {
                            terminal.onInput = { data in
                                let record = "QA_INPUT bytes=\(data.count) carriageReturns=\(data.filter { $0 == 13 }.count)\n"
                                FileHandle.standardError.write(Data(record.utf8))
                                originalInput(data)
                            }
                        }
                        let record = "QA_KEY code=\(event.keyCode) modifiers=\(event.modifierFlags.rawValue) terminal=\(terminal != nil) marked=\(terminal?.hasMarkedText() ?? false) input=\(terminal?.onInput != nil) bufferMatches=\(terminal?.ringBuffer === tab.ringBuffer)\n"
                        FileHandle.standardError.write(Data(record.utf8))
                        if let terminal {
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1))
                                let lines = tab.ringBuffer.tailLines(count: 20)
                                let bufferError = lines.contains { $0.contains("command not found") }
                                let viewError = terminal.string.contains("command not found")
                                let record = "QA_DISPLAY committed=\(tab.ringBuffer.committedLineCount) viewChars=\(terminal.string.utf16.count) commandErrorInBuffer=\(bufferError) commandErrorInView=\(viewError)\n"
                                FileHandle.standardError.write(Data(record.utf8))
                            }
                        }
                        return event
                    }
                }
                if let delay = ProcessInfo.processInfo.environment["APEX_QA_ACTIVATE_DELAY"].flatMap(Double.init) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                            window.makeKeyAndOrderFront(nil)
                            @MainActor func terminal(in view: NSView) -> NativeTerminalView? {
                                if let terminal = view as? NativeTerminalView { return terminal }
                                for child in view.subviews { if let result = terminal(in: child) { return result } }
                                return nil
                            }
                            if let content = window.contentView, let terminal = terminal(in: content) { window.makeFirstResponder(terminal) }
                        }
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
        let realSSH = ProcessInfo.processInfo.environment["APEX_QA_REAL_HOST"] != nil
        let remoteDirectory = ProcessInfo.processInfo.environment["APEX_QA_REMOTE_PATH"] ?? ""
        guard !realSSH || remoteDirectory.hasPrefix("/tmp/apexterm-soak-") else {
            NSLog("Real SSH soak requires its own /tmp/apexterm-soak- directory")
            NSApplication.shared.terminate(nil)
            return
        }
        let remotePayload = realSSH ? remoteDirectory + "/qa-payload.bin" : "/qa-payload.bin"
        let root = qaRepositoryRoot.appendingPathComponent("outputs/macos27/soak")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let upload = root.appendingPathComponent("payload.bin")
        let payload = Data(repeating: 0x5A, count: 256 * 1024)
        try? payload.write(to: upload)
        let start = ContinuousClock.now
        // Short diagnostics exercise the same shutdown path; final acceptance still uses 1800 seconds.
        let requestedSeconds = Int(ProcessInfo.processInfo.environment["APEX_QA_SOAK_SECONDS"] ?? "1800") ?? 1800
        let durationSeconds = min(max(requestedSeconds, 1), 1800)
        var cycle = 0
        var transfers = 0
        var echoes = 0
        var failures: [String] = []
        let manager = TransferManager.shared
        func report(completed: Bool, phase: String = "workload") {
            let data: [String: Any] = ["completed": completed, "phase": phase, "requestedDurationSeconds": durationSeconds, "outputSource": realSSH ? "real SSH PTY output" : "synthetic RingBuffer load", "elapsed": start.duration(to: .now).description,
                "outputLines": cycle * 80, "committedLines": tab.ringBuffer.committedLineCount,
                "historyLimit": tab.ringBuffer.maxLines, "transferChecks": transfers,
                "transferRecords": manager.tasks.count, "inputChecks": echoes, "metricHistory": tab.metricsHistory.snapshots.count,
                "failures": failures]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]) {
                try? json.write(to: root.appendingPathComponent("progress.json"), options: .atomic)
            }
        }
        while start.duration(to: .now) < .seconds(durationSeconds) && !Task.isCancelled {
            let logs = (0..<80).map { "[QA] cycle=\(cycle) row=\($0) status=OK simulated output for bounded scrollback\n" }.joined()
            if realSSH {
                let command = "for i in {0..79}; do printf '[QA] cycle=\(cycle) row=%s status=OK\\n' \"$i\"; done\r"
                do { try await tab.sshClient.sendInput(Data(command.utf8)) }
                catch { failures.append("Output command failed: \(error.localizedDescription)") }
            } else {
                tab.ringBuffer.appendStream(logs)
            }
            if cycle % 100 == 0 {
                let marker = "QA_INPUT_\(cycle)"
                do {
                    let input = realSSH ? "printf '%s\\n' '\(marker)'\r" : marker + "\n"
                    try await tab.sshClient.sendInput(Data(input.utf8))
                    func hasEcho() -> Bool {
                        tab.ringBuffer.tailLines(count: 200).contains {
                            realSSH ? $0.trimmingCharacters(in: .whitespacesAndNewlines) == marker : $0.contains(marker)
                        }
                    }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while !hasEcho(),
                          ContinuousClock.now < deadline, !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    if hasEcho() { echoes += 1 }
                    else { failures.append("Missing input marker at cycle \(cycle)") }
                } catch { failures.append("Input failed at cycle \(cycle): \(error.localizedDescription)") }
            }
            if cycle % 300 == 0 {
                // A fresh destination prevents stale bytes from passing a failed download.
                let download = root.appendingPathComponent("roundtrip-\(UUID().uuidString).bin")
                let uploadID = manager.enqueueUpload(session: tab.sshClient, localURL: upload, remotePath: remotePayload)
                while manager.activeCount > 0 && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                let uploadSucceeded = manager.tasks.first(where: { $0.id == uploadID })?.status == .completed
                let downloadID = manager.enqueueDownload(session: tab.sshClient, remotePath: remotePayload, localURL: download, totalBytes: Int64(payload.count))
                while manager.activeCount > 0 && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                let downloadSucceeded = manager.tasks.first(where: { $0.id == downloadID })?.status == .completed
                if uploadSucceeded && downloadSucceeded && (try? Data(contentsOf: download)) == payload { transfers += 1 }
                else { failures.append("Transfer task failed or contents mismatched at cycle \(cycle)") }
            }
            cycle += 1
            if cycle % 100 == 0 { report(completed: false) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let workloadCompleted = !Task.isCancelled && start.duration(to: .now) >= .seconds(durationSeconds)
        report(completed: workloadCompleted, phase: "disconnecting")
        await tab.sshClient.disconnect()
        report(completed: workloadCompleted, phase: "disconnected")
        try? await Task.sleep(for: .seconds(30))
        report(completed: workloadCompleted, phase: "terminationRequested")
        NSApplication.shared.terminate(nil)
    }

}
