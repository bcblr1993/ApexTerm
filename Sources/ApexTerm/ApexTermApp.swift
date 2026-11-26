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
                guard !AppLockManager.shared.isLocked else { return }
                openSettings()
            }
    }
}

@MainActor
private final class ApexTermAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var reopenMainWindow: (() -> Void)?
    var onBeforeTerminate: (() -> Void)?
    private var activityEventMonitor: Any?
    private var idleLockTimer: Timer?
    private var resignActiveObserver: NSObjectProtocol?
    private var distributedActivateObserver: NSObjectProtocol?
    private var lockStateCancellable: AnyCancellable?
    private var deferredNotificationFocusUserInfo: [String: String]?
    private var deferredShareImportURL: URL?
    private var hasDeferredShareImportPicker: Bool = false

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
        SSHKeyVaultManager.cleanupStaleMaterializedKeys()
        UpdateManager.shared.onBeforeTerminateForUpdate = { [weak self] in
            self?.performTerminationCleanup()
        }

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

        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                AppLockManager.shared.checkIdleLock()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleLockTimer = timer

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppLockManager.shared.handleAppDidResignActive()
            }
        }

        lockStateCancellable = AppLockManager.shared.$isLocked
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] isLocked in
                guard let self, !isLocked else { return }
                self.flushDeferredRequestsAfterUnlock()
            }

        distributedActivateObserver = DistributedNotificationCenter.default().addObserver(
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
        idleLockTimer?.invalidate()
        idleLockTimer = nil
        lockStateCancellable?.cancel()
        lockStateCancellable = nil
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        if let distributedActivateObserver {
            DistributedNotificationCenter.default().removeObserver(distributedActivateObserver)
            self.distributedActivateObserver = nil
        }
        if let monitor = activityEventMonitor {
            NSEvent.removeMonitor(monitor)
            activityEventMonitor = nil
        }
        performTerminationCleanup()
    }

    func performTerminationCleanup() {
        if let onBeforeTerminate {
            onBeforeTerminate()
        } else {
            SSHControlMasterPool.shared.closeAll()
            SSHTunnelManager.shared.stopAll()
            TransferManager.shared.cancelAllTasks()
            ExternalEditSessionManager.shared.stopAllSessions()
            SSHKeyVaultManager.cleanupMaterializedKeys()
        }
    }

    func enqueueOrDispatchShareImport(url: URL?) {
        if AppLockManager.shared.isLocked {
            if let url {
                deferredShareImportURL = url
                hasDeferredShareImportPicker = false
            } else if deferredShareImportURL == nil {
                hasDeferredShareImportPicker = true
            }
            return
        }
        IncomingShareCoordinator.shared.requestImport(url: url)
    }

    func enqueueOrDispatchNotificationFocus(userInfo: [String: String]) {
        if AppLockManager.shared.isLocked {
            deferredNotificationFocusUserInfo = userInfo
            return
        }
        let postedInfo: [AnyHashable: Any] = userInfo
        NotificationCenter.default.post(
            name: DesktopNotificationManager.focusTabNotification,
            object: nil,
            userInfo: postedInfo
        )
    }

    private func flushDeferredRequestsAfterUnlock() {
        guard !AppLockManager.shared.isLocked else { return }
        if let userInfo = deferredNotificationFocusUserInfo {
            deferredNotificationFocusUserInfo = nil
            let postedInfo: [AnyHashable: Any] = userInfo
            NotificationCenter.default.post(
                name: DesktopNotificationManager.focusTabNotification,
                object: nil,
                userInfo: postedInfo
            )
        }
        if let url = deferredShareImportURL {
            deferredShareImportURL = nil
            hasDeferredShareImportPicker = false
            IncomingShareCoordinator.shared.requestImport(url: url)
        } else if hasDeferredShareImportPicker {
            hasDeferredShareImportPicker = false
            IncomingShareCoordinator.shared.requestImport(url: nil)
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
            self.enqueueOrDispatchNotificationFocus(userInfo: userInfo)
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
        enqueueOrDispatchShareImport(url: targetURL)
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
    @State private var hasAttemptedSnapshotRestore = false
    
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
            .onReceive(NotificationCenter.default.publisher(for: AppLockManager.appDidLockNotification)) { _ in
                dismissAppLevelSheetsForLock()
            }
            .onChange(of: lockManager.isLocked) { _, isLocked in
                if isLocked {
                    dismissAppLevelSheetsForLock()
                } else {
                    restoreWorkspaceOnLaunchIfNeeded()
                }
            }
            .onChange(of: settings.controlMasterPoolEnabled) { _, enabled in
                SSHControlMasterPool.isPoolEnabled = enabled
            }
            .onReceive(NotificationCenter.default.publisher(for: AppSettings.didResetToDefaultsNotification)) { _ in
                SSHControlMasterPool.isPoolEnabled = settings.controlMasterPoolEnabled
            }
            .onChange(of: activeTabs.map(\.id)) { _, _ in
                persistLastWorkspaceSnapshot()
            }
            .onChange(of: selectedTabId) { _, _ in
                persistLastWorkspaceSnapshot()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                performBeforeTerminateCleanup()
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
                guard !lockManager.isLocked else { return }
                isAboutPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenShortcutsModal"))) { _ in
                guard !lockManager.isLocked else { return }
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
                appDelegate.enqueueOrDispatchShareImport(url: url)
                showMainWindow()
            }
            .onAppear {
                SSHControlMasterPool.isPoolEnabled = settings.controlMasterPoolEnabled
                wireLifecycleHandlers()
                restoreWorkspaceOnLaunchIfNeeded()
            }
            .task {
                SSHControlMasterPool.isPoolEnabled = settings.controlMasterPoolEnabled
                wireLifecycleHandlers()
                restoreWorkspaceOnLaunchIfNeeded()
                if updateManager.distributionChannel == .direct && settings.checkForUpdatesOnLaunch && ProcessInfo.processInfo.environment["APEX_UI_TEST_REOPEN"] != "1" {
                    await updateManager.checkForUpdates(manual: false)
                }
            }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .defaultSize(width: ApexStyle.defaultWindowWidth, height: ApexStyle.defaultWindowHeight)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button(L10n.menuShowMainWindow) {
                    showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])

                Button(L10n.menuLockAppAction) {
                    lockManager.lockNow()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .appInfo) {
                Button(L10n.menuAbout) {
                    guard !lockManager.isLocked else { return }
                    isAboutPresented = true
                }
                .disabled(lockManager.isLocked)
                
                Button(L10n.menuCheckUpdates) {
                    guard !lockManager.isLocked else { return }
                    if updateManager.distributionChannel == .appStore {
                        NSWorkspace.shared.open(DistributionChannel.appStoreURL)
                    } else {
                        Task {
                            await updateManager.checkForUpdates(manual: true)
                        }
                    }
                }
                .disabled(lockManager.isLocked)
            }
            
            CommandGroup(replacing: .newItem) {
                Button(L10n.menuNewLocalTerminal) {
                    guard !lockManager.isLocked else { return }
                    openLocalTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(lockManager.isLocked)
                
                Button(L10n.menuDuplicateOrNewTab) {
                    guard !lockManager.isLocked else { return }
                    if activeTabs.contains(where: { $0.id == selectedTabId }) {
                        duplicateCurrentSession()
                    } else if let selected = selectedSidebarSession ?? sessionStore.sessions.first {
                        connectToSession(selected)
                    } else {
                        openLocalTerminal()
                    }
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(lockManager.isLocked)
                
                Divider()
                
                Button(L10n.menuExportSessions) {
                    guard !lockManager.isLocked else { return }
                    exportSessions()
                }
                .disabled(lockManager.isLocked)
                
                Button(L10n.menuImportSessions) {
                    guard !lockManager.isLocked else { return }
                    importSessions()
                }
                .disabled(lockManager.isLocked)
            }
            
            CommandGroup(after: .pasteboard) {
                Button(L10n.menuFind) {
                    guard !lockManager.isLocked else { return }
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
                .disabled(lockManager.isLocked)
            }
            
            CommandGroup(replacing: .saveItem) {
                Button(L10n.menuCloseCurrentPaneOrTab) {
                    guard !lockManager.isLocked else { return }
                    if isWorkspaceWindow == true, NSApp.keyWindow?.sheetParent == nil,
                       NSApp.keyWindow?.attachedSheet == nil,
                       activeTabs.contains(where: { $0.id == selectedTabId }) {
                        NotificationCenter.default.post(name: WorkspaceView.requestCloseCurrentTabNotification, object: nil)
                    } else {
                        NSApplication.shared.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(lockManager.isLocked)
            }

            CommandMenu(L10n.menuSession) {
                Button(L10n.menuDuplicateToNewTab) {
                    guard !lockManager.isLocked else { return }
                    duplicateCurrentSession()
                }
                .disabled(lockManager.isLocked || activeTabs.isEmpty)

                Button(L10n.menuReconnectSession) {
                    guard !lockManager.isLocked else { return }
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }),
                       let active = current.activePane {
                        current.reconnect(pane: active)
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(lockManager.isLocked || !activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Divider()
                
                Button(L10n.menuDisconnect) {
                    guard !lockManager.isLocked else { return }
                    NotificationCenter.default.post(name: WorkspaceView.requestCloseCurrentTabNotification, object: nil)
                }
                .disabled(lockManager.isLocked || !activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Divider()
                
                Button(L10n.menuSplitVertical) {
                    guard !lockManager.isLocked else { return }
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.split(mode: .vertical)
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(lockManager.isLocked || !activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Button(L10n.menuSplitHorizontal) {
                    guard !lockManager.isLocked else { return }
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.split(mode: .horizontal)
                    }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(lockManager.isLocked || !activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Button(L10n.menuToggleMaximizePane) {
                    guard !lockManager.isLocked else { return }
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.toggleMaximizeActivePane()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(lockManager.isLocked || (activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Button(L10n.menuNextPane) {
                    guard !lockManager.isLocked else { return }
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.focusNextPane()
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(lockManager.isLocked || (activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Button(L10n.menuPreviousPane) {
                    guard !lockManager.isLocked else { return }
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.focusPreviousPane()
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(lockManager.isLocked || (activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Button(L10n.menuNextPaneVertical) {
                    guard !lockManager.isLocked else { return }
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.focusNextPane()
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(lockManager.isLocked || (activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Button(L10n.menuPreviousPaneVertical) {
                    guard !lockManager.isLocked else { return }
                    if let current = activeTabs.first(where: { $0.id == selectedTabId }) {
                        current.focusPreviousPane()
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(lockManager.isLocked || (activeTabs.first(where: { $0.id == selectedTabId })?.panes.count ?? 0) < 2)

                Divider()

                Button(L10n.menuNextTab) {
                    guard !lockManager.isLocked else { return }
                    selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(lockManager.isLocked || activeTabs.count < 2)

                Button(L10n.menuPreviousTab) {
                    guard !lockManager.isLocked else { return }
                    selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(lockManager.isLocked || activeTabs.count < 2)

                Menu(L10n.menuSwitchTabSubmenu) {
                    ForEach(1...9, id: \.self) { number in
                        Button(L10n.menuSwitchToTab(number)) {
                            guard !lockManager.isLocked else { return }
                            guard activeTabs.indices.contains(number - 1) else { return }
                            selectedTabId = activeTabs[number - 1].id
                        }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                        .disabled(lockManager.isLocked || !activeTabs.indices.contains(number - 1))
                    }
                }
                .disabled(lockManager.isLocked || activeTabs.isEmpty)
                
                Divider()
                
                Button(L10n.menuClearScrollback) {
                    guard !lockManager.isLocked else { return }
                    clearActiveTerminalScreen()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(lockManager.isLocked || !activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Divider()
                
                Button(L10n.menuCommandPalette) {
                    guard !lockManager.isLocked else { return }
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerCommandPalette"), object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(lockManager.isLocked)
                
                Button(L10n.menuSSHTunnels) {
                    guard !lockManager.isLocked else { return }
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerSSHTunnels"), object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(lockManager.isLocked)

                Button(L10n.menuBatchOperations) {
                    guard !lockManager.isLocked else { return }
                    CommandPaletteItem.postOpenBatchOperations(sessionIDs: [], folder: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(lockManager.isLocked)

                Button(L10n.menuProcessInspector) {
                    guard !lockManager.isLocked else { return }
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerProcessInspector"), object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(lockManager.isLocked || !activeTabs.contains(where: { $0.id == selectedTabId }))

                Button(L10n.menuToggleSFTP) {
                    guard !lockManager.isLocked else { return }
                    NotificationCenter.default.post(name: WorkspaceView.toggleSFTPNotification, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(lockManager.isLocked || !activeTabs.contains(where: { $0.id == selectedTabId }))
                
                Button(L10n.menuToggleQuickCommandBar) {
                    guard !lockManager.isLocked else { return }
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerQuickCommandBar"), object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(lockManager.isLocked)

                Button(L10n.menuCopyLastCommandOutput) {
                    guard !lockManager.isLocked else { return }
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerCopyLastCommandOutput"), object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(lockManager.isLocked || !activeTabs.contains(where: { $0.id == selectedTabId }))
            }
            
            CommandGroup(replacing: .help) {
                Button(L10n.menuShortcuts) {
                    guard !lockManager.isLocked else { return }
                    isShortcutsPresented = true
                }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(lockManager.isLocked)
                
                Divider()
                
                Button(L10n.menuDocumentation) {
                    guard !lockManager.isLocked else { return }
                    if let url = URL(string: "https://github.com/bcblr1993/ApexTerm#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(lockManager.isLocked)
                
                Button(L10n.menuGitHubRepo) {
                    guard !lockManager.isLocked else { return }
                    if let url = URL(string: "https://github.com/bcblr1993/ApexTerm") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(lockManager.isLocked)
                
                Button(L10n.menuReportIssue) {
                    guard !lockManager.isLocked else { return }
                    if let url = URL(string: "https://github.com/bcblr1993/ApexTerm/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(lockManager.isLocked)
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

    private func wireLifecycleHandlers() {
        appDelegate.reopenMainWindow = { showMainWindow() }
        appDelegate.onBeforeTerminate = { performBeforeTerminateCleanup() }
        UpdateManager.shared.onBeforeTerminateForUpdate = { performBeforeTerminateCleanup() }
        lockManager.onDidLock = { dismissAppLevelSheetsForLock() }
    }

    private func dismissAppLevelSheetsForLock() {
        isAboutPresented = false
        isShortcutsPresented = false
        isNewSessionPresented = false
        updateManager.isUpdateSheetPresented = false
    }

    private func performBeforeTerminateCleanup() {
        persistLastWorkspaceSnapshot()
        SSHControlMasterPool.shared.closeAll()
        SSHTunnelManager.shared.stopAll()
        TransferManager.shared.cancelAllTasks()
        ExternalEditSessionManager.shared.stopAllSessions()
        SSHKeyVaultManager.cleanupMaterializedKeys()
        for tab in activeTabs {
            for pane in tab.panes {
                (pane.sshClient as? NativeSSHSession)?.terminatePTYProcess()
                (pane.sshClient as? LocalTerminalSession)?.terminatePTYProcess()
            }
        }
    }

    private func persistLastWorkspaceSnapshot() {
        let isSFTPVisible = UserDefaults.standard.object(forKey: "workspace.filesVisible") as? Bool ?? true
        let filesSplitRatio = UserDefaults.standard.object(forKey: "workspace.filesSplitRatio") as? Double ?? 0.70
        let snap = WorkspaceView.makeSnapshot(
            name: "上次工作区",
            tabs: activeTabs,
            selectedTabId: selectedTabId,
            isSFTPVisible: isSFTPVisible,
            filesSplitRatio: filesSplitRatio
        )
        WorkspaceSnapshotStore.shared.saveLastWorkspace(snap)
    }

    private func restoreWorkspaceOnLaunchIfNeeded() {
        guard !hasAttemptedSnapshotRestore else { return }
        guard settings.restoreWorkspaceOnLaunch, !lockManager.isLocked else { return }
        guard activeTabs.isEmpty else {
            hasAttemptedSnapshotRestore = true
            return
        }
        guard ProcessInfo.processInfo.environment["APEX_UI_TEST_REOPEN"] != "1" else {
            hasAttemptedSnapshotRestore = true
            return
        }
        hasAttemptedSnapshotRestore = true
        guard let snap = WorkspaceSnapshotStore.shared.loadLastWorkspace() ?? WorkspaceSnapshotStore.shared.snapshots.first,
              !snap.tabs.isEmpty else {
            return
        }
        let restored = WorkspaceView.restoreSnapshot(
            snap,
            store: sessionStore,
            activeTabs: &activeTabs,
            selectedTabId: &selectedTabId
        )
        UserDefaults.standard.set(restored.isSFTPVisible, forKey: "workspace.filesVisible")
        UserDefaults.standard.set(restored.filesSplitRatio, forKey: "workspace.filesSplitRatio")
    }

    private func clearActiveTerminalScreen() {
        guard let current = activeTabs.first(where: { $0.id == selectedTabId }),
              let pane = current.activePane ?? current.panes.first else {
            return
        }
        guard !pane.ringBuffer.isInAlternateScreen else { return }
        let hadContent = pane.ringBuffer.totalCommittedCount > 0 || !pane.ringBuffer.currentActiveLine.isEmpty
        NotificationCenter.default.post(
            name: WorkspaceView.clearTerminalScreenNotification,
            object: pane.id,
            userInfo: ["tabId": current.id, "paneId": pane.id]
        )
        if hadContent && (pane.ringBuffer.totalCommittedCount > 0 || !pane.ringBuffer.currentActiveLine.isEmpty) {
            pane.ringBuffer.clear()
            Task { try? await pane.sshClient.sendInput(Data([0x0C])) }
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
        guard !lockManager.isLocked else { return }
        showMainWindow()
        IncomingShareCoordinator.shared.requestExport()
    }
    
    private func importSessions() {
        showMainWindow()
        appDelegate.enqueueOrDispatchShareImport(url: nil)
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
