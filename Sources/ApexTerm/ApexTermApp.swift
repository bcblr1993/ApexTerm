import SwiftUI
import AppKit
import Combine
import UserNotifications
import ApexCore
import ApexSSH
import ApexTerminal
import ApexUI

private struct WorkspaceCommandFocusKey: FocusedValueKey {
    typealias Value = Bool
}

private extension FocusedValues {
    var isWorkspaceWindow: Bool? {
        get { self[WorkspaceCommandFocusKey.self] }
        set { self[WorkspaceCommandFocusKey.self] = newValue }
    }
}

private struct SettingsOpenerBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettingsModal"))) { _ in
                openSettings()
            }
    }
}

@MainActor
private final class ApexTermAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var reopenMainWindow: (() -> Void)?
    private var activityEventMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard UpdateManager.shouldEnforceSingleInstance() else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apexterm.app")
        let runningSummary = running.map {
            (pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier, isTerminated: $0.isTerminated)
        }
        let otherPIDs = Set(UpdateManager.otherRunningInstancePIDs(
            bundleIdentifier: "com.apexterm.app",
            currentPID: currentPID,
            runningApps: runningSummary
        ))

        if let existing = running.first(where: { otherPIDs.contains($0.processIdentifier) }) {
            NSApp.setActivationPolicy(.prohibited)
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(UpdateManager.activateMainWindowNotificationName),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            existing.unhide()
            existing.activate(options: [.activateAllWindows])
            exit(0)
        }

        let canonicalURL = URL(fileURLWithPath: "/Applications/AetherTerm.app")
        if let redirectURL = UpdateManager.canonicalRedirectAppURL(
            currentBundleURL: Bundle.main.bundleURL,
            installedAppURL: canonicalURL,
            installedExists: FileManager.default.fileExists(atPath: canonicalURL.path)
        ) {
            NSApp.setActivationPolicy(.prohibited)
            let openProc = Process()
            openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProc.arguments = ["-a", redirectURL.path]
            try? openProc.run()
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        activityEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { event in
            MainActor.assumeIsolated {
                AppLockManager.shared.recordUserActivity()
            }
            return event
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(UpdateManager.activateMainWindowNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reopenMainWindow?()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = activityEventMonitor {
            NSEvent.removeMonitor(monitor)
            activityEventMonitor = nil
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = Self.sendableUserInfo(from: response.notification.request.content.userInfo)
        Task { @MainActor in
            let postedInfo: [AnyHashable: Any] = userInfo
            NotificationCenter.default.post(
                name: Notification.Name("ApexTermFocusTabFromNotification"),
                object: nil,
                userInfo: postedInfo
            )
            self.reopenMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
        completionHandler()
    }

    nonisolated private static func sendableUserInfo(from raw: [AnyHashable: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in raw {
            let keyStr = (key as? String) ?? String(describing: key)
            result[keyStr] = (value as? String) ?? String(describing: value)
        }
        return result
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            reopenMainWindow?()
            return reopenMainWindow == nil
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let targetURL = urls.first(where: { SessionBundleExporter.isSupportedShareFileURL($0) }) else {
            return
        }
        IncomingShareCoordinator.shared.requestImport(url: targetURL)
        reopenMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ApexTermApp: App {
    @NSApplicationDelegateAdaptor(ApexTermAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var sessionStore = SessionStore.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var lockManager = AppLockManager.shared
    
    @FocusedValue(\.isWorkspaceWindow) private var isWorkspaceWindow

    @State private var activeTabs: [TerminalTabItem] = []
    @State private var selectedTabId: UUID?
    @State private var selectedSidebarSession: Session?
    
    @State private var isAboutPresented = false
    @State private var isShortcutsPresented = false
    @State private var isNewSessionPresented = false

    private let idleLockTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    
    var body: some Scene {
        WindowGroup(id: "main") {
            ZStack {
                NavigationSplitView {
                    SidebarView(
                        store: sessionStore,
                        selectedSession: $selectedSidebarSession,
                        onConnect: { session in
                            connectToSession(session)
                        },
                        onRunSnippet: { snippet in
                            runSnippet(snippet)
                        }
                    )
                    .frame(minWidth: ApexStyle.minSidebarWidth, idealWidth: ApexStyle.idealSidebarWidth, maxWidth: ApexStyle.maxSidebarWidth)
                } detail: {
                    WorkspaceView(
                        store: sessionStore,
                        activeTabs: $activeTabs,
                        selectedTabId: $selectedTabId
                    )
                }
                .disabled(lockManager.isLocked)

                if lockManager.isLocked {
                    AppLockOverlayView(lockManager: lockManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            .focusedSceneValue(\.isWorkspaceWindow, true)
            .onReceive(idleLockTimer) { _ in
                lockManager.checkIdleLock()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                lockManager.handleAppDidResignActive()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                SSHTunnelManager.shared.stopAll()
                TransferManager.shared.cancelAllTasks()
                SSHKeyVaultManager.cleanupMaterializedKeys()
                for tab in activeTabs {
                    for pane in tab.panes {
                        (pane.sshClient as? NativeSSHSession)?.terminatePTYProcess()
                        (pane.sshClient as? LocalTerminalSession)?.terminatePTYProcess()
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .background {
                ZStack {
                    WindowStateView()
                    SettingsOpenerBridge()
                }
                .frame(width: 0, height: 0)
            }
            .apexTheme()
            .frame(minWidth: ApexStyle.minWindowWidth, minHeight: ApexStyle.minWindowHeight)
            .sheet(isPresented: $isAboutPresented) {
                AboutView().apexTheme()
            }
            .sheet(isPresented: $isShortcutsPresented) {
                ShortcutsSheetView().apexTheme()
            }
            .sheet(isPresented: $isNewSessionPresented) {
                SessionEditModal(session: nil) { session in
                    sessionStore.addSession(session)
                }.apexTheme()
            }
            .sheet(isPresented: $updateManager.isUpdateSheetPresented) {
                UpdateSheetView().apexTheme()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenAboutModal"))) { _ in
                isAboutPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenShortcutsModal"))) { _ in
                isShortcutsPresented = true
            }
            .onChange(of: updateManager.isUpdateSheetPresented) { _, isPresented in
                if isPresented && isAboutPresented {
                    isAboutPresented = false
                }
            }
            .onChange(of: sessionStore.sessions) { _, updatedSessions in
                WorkspaceView.syncActiveTabs(activeTabs, with: updatedSessions)
                if let selected = selectedSidebarSession {
                    if let refreshed = updatedSessions.first(where: { $0.id == selected.id }) {
                        selectedSidebarSession = refreshed
                    } else if !selected.isLocal {
                        selectedSidebarSession = nil
                    }
                }
            }
            .onOpenURL { url in
                guard SessionBundleExporter.isSupportedShareFileURL(url) else { return }
                IncomingShareCoordinator.shared.requestImport(url: url)
                showMainWindow()
            }
            .task {
                appDelegate.reopenMainWindow = { showMainWindow() }
                if updateManager.distributionChannel == .direct && settings.checkForUpdatesOnLaunch && ProcessInfo.processInfo.environment["APEX_UI_TEST_REOPEN"] != "1" {
                    await updateManager.checkForUpdates(manual: false)
                }
            }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .defaultSize(width: ApexStyle.defaultWindowWidth, height: ApexStyle.defaultWindowHeight)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("显示主窗口") {
                    showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])

                Button("锁定应用") {
                    lockManager.lockNow()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .appInfo) {
                Button(L10n.menuAbout) {
                    isAboutPresented = true
                }
                
                Button(L10n.menuCheckUpdates) {
                    if updateManager.distributionChannel == .appStore {
                        NSWorkspace.shared.open(DistributionChannel.appStoreURL)
                    } else {
                        Task {
                            await updateManager.checkForUpdates(manual: true)
                        }
                    }
                }
            }
            
            CommandGroup(replacing: .newItem) {
                Button("新建本地终端") {
                    openLocalTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                
                Button("复制当前会话 / 新建标签页") {
                    if activeTabs.contains(where: { $0.id == selectedTabId }) {
                        duplicateCurrentSession()
                    } else if let selected = selectedSidebarSession ?? sessionStore.sessions.first {
                        connectToSession(selected)
                    } else {
                        openLocalTerminal()
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                
                Divider()
                
                Button(L10n.menuExportSessions) {
                    exportSessions()
                }
                
                Button(L10n.menuImportSessions) {
                    importSessions()
                }
            }
            
            CommandGroup(after: .pasteboard) {
                Button("查找...") {
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
            
            CommandGroup(replacing: .saveItem) {
                Button("关闭当前窗格 / 标签页") {
                    if isWorkspaceWindow == true, NSApp.keyWindow?.sheetParent == nil,
                       NSApp.keyWindow?.attachedSheet == nil,
                       activeTabs.contains(where: { $0.id == selectedTabId }) {
                        closeCurrentConnection()
                    } else {
                        NSApplication.shared.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandMenu(L10n.menuSession) {
                Button("复制此会话到新标签页") {
                    duplicateCurrentSession()
                }
                .disabled(activeTabs.isEmpty)
                
                Divider()
                
                Button(L10n.menuDisconnect) {
                    closeCurrentConnection()
                }
                .disabled(!activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Divider()
                
                Button("垂直分屏") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.split(mode: .vertical)
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Button("水平分屏") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.split(mode: .horizontal)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Button("全屏放大 / 恢复分屏") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.toggleMaximizeActivePane()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled((activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Button("切换到下一个分屏窗格") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.focusNextPane()
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled((activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Button("切换到上一个分屏窗格") {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.focusPreviousPane()
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled((activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Divider()

                Button("下一个标签页") {
                    selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(activeTabs.count < 2)

                Button("上一个标签页") {
                    selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(activeTabs.count < 2)
                
                Divider()
                
                Button(L10n.menuClearScrollback) {
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.ringBuffer.clear()
                    }
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Divider()
                
                Button("全局快速搜索与命令面板...") {
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerCommandPalette"), object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                
                Button("SSH 端口转发与隧道管理...") {
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerSSHTunnels"), object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                
                Button("显示 / 隐藏底部快捷命令栏") {
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerQuickCommandBar"), object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            
            CommandGroup(replacing: .help) {
                Button(L10n.menuShortcuts) {
                    isShortcutsPresented = true
                }
                .keyboardShortcut("/", modifiers: .command)
                
                Divider()
                
                Button(L10n.menuDocumentation) {
                    if let url = URL(string: "https://github.com/bcblr1993/ApexTerm#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Button(L10n.menuGitHubRepo) {
                    if let url = URL(string: "https://github.com/bcblr1993/ApexTerm") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Button(L10n.menuReportIssue) {
                    if let url = URL(string: "https://github.com/bcblr1993/ApexTerm/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        
        Settings {
            ZStack {
                SettingsView().apexTheme()
                    .disabled(lockManager.isLocked)

                if lockManager.isLocked {
                    AppLockOverlayView(lockManager: lockManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .apexTheme()
                }
            }
            .focusedSceneValue(\.isWorkspaceWindow, false)
        }
    }

    private func showMainWindow() {
        let workspace = NSApp.windows.first(where: {
            $0.isVisible && ($0.frameAutosaveName == "ApexTerm.MainWorkspace"
                || $0.identifier?.rawValue.hasPrefix("main-") == true)
        }) ?? NSApp.windows.first(where: { $0.frameAutosaveName == "ApexTerm.MainWorkspace" })
        if let window = workspace {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: "main")
        }
    }
    
    private func exportSessions() {
        showMainWindow()
        IncomingShareCoordinator.shared.requestExport()
    }
    
    private func importSessions() {
        showMainWindow()
        IncomingShareCoordinator.shared.requestImport(url: nil)
    }
    
    private func closeCurrentConnection() {
        guard let current = activeTabs.first(where: { $0.id == selectedTabId }) else { return }
        if current.panes.count > 1, let activeId = current.activePaneId {
            current.closePane(id: activeId)
        } else {
            current.tearDown()
            activeTabs.removeAll(where: { $0.id == current.id })
            selectedTabId = activeTabs.first?.id
        }
    }

    private func duplicateCurrentSession() {
        guard let current = activeTabs.first(where: { $0.id == selectedTabId }) else { return }
        let session = current.session
        let client = SSHClientFactory.makeClient(for: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        tab.currentRemotePath = current.currentRemotePath
        tab.isDirectoryLinkageEnabled = current.isDirectoryLinkageEnabled
        
        if let idx = activeTabs.firstIndex(where: { $0.id == current.id }) {
            activeTabs.insert(tab, at: idx + 1)
        } else {
            activeTabs.append(tab)
        }
        selectedTabId = tab.id
        tab.connect()
    }

    private func selectNextTab() {
        guard activeTabs.count > 1 else { return }
        let curIdx = activeTabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
        let nextIdx = (curIdx + 1) % activeTabs.count
        selectedTabId = activeTabs[nextIdx].id
    }

    private func selectPreviousTab() {
        guard activeTabs.count > 1 else { return }
        let curIdx = activeTabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
        let prevIdx = (curIdx - 1 + activeTabs.count) % activeTabs.count
        selectedTabId = activeTabs[prevIdx].id
    }

    private func connectToSession(_ session: Session) {
        let client = SSHClientFactory.makeClient(for: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        activeTabs.append(tab)
        selectedTabId = tab.id
        tab.connect()
    }
    
    private func openLocalTerminal() {
        let local = Session.local()
        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)
        activeTabs.append(tab)
        selectedTabId = tab.id
        tab.connect()
    }
    
    private func runSnippet(_ snippet: Snippet) {
        NotificationCenter.default.post(name: WorkspaceView.executeSnippetNotification, object: snippet)
    }
}
