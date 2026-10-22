import XCTest
import AppKit
import SwiftUI
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

@MainActor
final class TitlebarZoomAndUIRegressionTests: XCTestCase {
    
    func testTitlebarEmptyAreaDetection() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "TestToolbar")
        window.toolbar = toolbar
        window.makeKeyAndOrderFront(nil)

        let contentMaxY = window.contentLayoutRect.maxY

        // 1. Point in the empty titlebar center
        let emptyPoint = NSPoint(x: 450, y: contentMaxY + 15)
        XCTAssertTrue(
            TitlebarZoomHelper.isTitlebarEmptyArea(at: emptyPoint, in: window),
            "Middle of titlebar should be recognized as empty area"
        )

        // 2. Point in the content area (below titlebar)
        let contentPoint = NSPoint(x: 400, y: 200)
        XCTAssertFalse(
            TitlebarZoomHelper.isTitlebarEmptyArea(at: contentPoint, in: window),
            "Points below contentLayoutRect.maxY must NOT be recognized as titlebar"
        )

        // 3. Point above window frame
        let abovePoint = NSPoint(x: 400, y: window.frame.height + 50)
        XCTAssertFalse(
            TitlebarZoomHelper.isTitlebarEmptyArea(at: abovePoint, in: window),
            "Points above window frame must NOT be recognized as titlebar"
        )

        // 4. Point in the traffic lights area (close / miniaturize / zoom buttons)
        if let closeBtn = window.standardWindowButton(.closeButton) {
            let closeFrame = closeBtn.convert(closeBtn.bounds, to: nil)
            let trafficPoint = NSPoint(x: closeFrame.midX, y: closeFrame.midY)
            XCTAssertFalse(
                TitlebarZoomHelper.isTitlebarEmptyArea(at: trafficPoint, in: window),
                "Traffic light buttons must NOT be treated as empty titlebar space"
            )
        }
        
        window.orderOut(nil)
    }

    func testTitlebarDoubleClickPerformsZoom() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)

        let prevPref = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        defer {
            if let prev = prevPref {
                UserDefaults.standard.set(prev, forKey: "AppleActionOnDoubleClick")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleActionOnDoubleClick")
            }
        }
        UserDefaults.standard.removeObject(forKey: "AppleActionOnDoubleClick")

        let initialFrame = window.frame
        TitlebarZoomHelper.performDoubleClickAction(for: window)
        let zoomedFrame = window.frame
        XCTAssertNotEqual(zoomedFrame, initialFrame, "performDoubleClickAction should toggle window zoom")

        // Toggle again to restore
        TitlebarZoomHelper.performDoubleClickAction(for: window)
        let restoredFrame = window.frame
        XCTAssertEqual(restoredFrame, initialFrame, "Second double-click action should restore the original window frame")

        window.orderOut(nil)
    }

    func testTitlebarDoubleClickRespectsMinimizePreference() {
        final class MockWindow: NSWindow {
            var miniaturizeCalled = false
            override func miniaturize(_ sender: Any?) {
                miniaturizeCalled = true
            }
        }

        let window = MockWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        let prevPref = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        defer {
            if let prev = prevPref {
                UserDefaults.standard.set(prev, forKey: "AppleActionOnDoubleClick")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleActionOnDoubleClick")
            }
        }
        UserDefaults.standard.set("Minimize", forKey: "AppleActionOnDoubleClick")

        TitlebarZoomHelper.performDoubleClickAction(for: window)
        XCTAssertTrue(window.miniaturizeCalled, "performDoubleClickAction should call miniaturize when preference is Minimize")
    }

    func testTitlebarDoubleClickRespectsNonePreference() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)

        let prevPref = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        defer {
            if let prev = prevPref {
                UserDefaults.standard.set(prev, forKey: "AppleActionOnDoubleClick")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleActionOnDoubleClick")
            }
        }
        UserDefaults.standard.set("None", forKey: "AppleActionOnDoubleClick")

        let initialFrame = window.frame
        TitlebarZoomHelper.performDoubleClickAction(for: window)
        XCTAssertEqual(window.frame, initialFrame, "performDoubleClickAction should do nothing when preference is None")
        XCTAssertFalse(window.isMiniaturized)

        window.orderOut(nil)
    }

    func testWorkspaceToolbarAlignedTitle() {
        let store = SessionStore()
        let local = Session.local()
        store.sessions = [local]
        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)

        let workspace = WorkspaceView(
            store: store,
            activeTabs: .constant([tab]),
            selectedTabId: .constant(tab.id)
        )

        let host = NSHostingView(rootView: workspace.apexTheme())
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unifiedCompact
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(window.title, "本地终端", "Window title should be synchronized with tab display title")
        window.orderOut(nil)
    }

    func testWorkspaceActionControlsOnRightSide() {
        let store = SessionStore()
        let local = Session.local()
        store.sessions = [local]
        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)

        let workspace = WorkspaceView(
            store: store,
            activeTabs: .constant([tab]),
            selectedTabId: .constant(tab.id)
        )

        let host = NSHostingView(rootView: workspace.apexTheme())
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .unifiedCompact
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        // Any toolbar items hosted in the window should be positioned towards the trailing (right) half
        for item in window.toolbar?.items ?? [] {
            if let view = item.view, view.window === window {
                let frameInWindow = view.convert(view.bounds, to: nil)
                XCTAssertGreaterThan(
                    frameInWindow.midX,
                    window.frame.width * 0.4,
                    "Toolbar action item \(item.itemIdentifier.rawValue) should be in the right/trailing area of the window, not clustered near the left title"
                )
            }
        }
        window.orderOut(nil)
    }

    func testSidebarAndDetailViewDesignSystem16ptGrid() {
        XCTAssertEqual(ApexStyle.s4, 16, "ApexStyle.s4 must be standardized to 16pt")
        XCTAssertEqual(ApexStyle.badgeRadius, 4)
        XCTAssertEqual(ApexStyle.controlRadius, 6)

        let store = SessionStore()
        let local = Session.local()
        store.sessions = [local]
        
        let sidebar = SidebarView(
            store: store,
            selectedSession: .constant(nil),
            onConnect: { _ in },
            onRunSnippet: { _ in }
        )
        let sidebarHost = NSHostingView(rootView: sidebar.apexTheme())
        sidebarHost.frame = NSRect(x: 0, y: 0, width: 290, height: 600)
        sidebarHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(sidebarHost.subviews.count, 0, "Sidebar should render subviews cleanly")

        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)
        let workspace = WorkspaceView(
            store: store,
            activeTabs: .constant([tab]),
            selectedTabId: .constant(tab.id)
        )
        let workspaceHost = NSHostingView(rootView: workspace.apexTheme())
        workspaceHost.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        workspaceHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(workspaceHost.subviews.count, 0, "Workspace should render subviews cleanly")
    }

    func testWindowMinimumDimensionsSupportHalfScreenTiling() {
        // 1. Verify design metrics guarantee 50/50 half-screen tiling on all standard MacBook displays:
        // - 13" MacBook standard (1280x800): half-width is 640pt
        // - 13"/14" MacBook scaled (1440x900): half-width is 720pt
        // - 14" MacBook Pro default (1512x982): half-width is 756pt
        // The previous bug had minWidth = 960pt, causing 960/1440 = 66.7% window occupation and clipping adjacent windows.
        XCTAssertLessThanOrEqual(ApexStyle.minWindowWidth, 640, "Window minWidth must be <= 640 to support half-screen tiling on 1280x800 screens")
        XCTAssertEqual(ApexStyle.minWindowWidth, 600, "Window minWidth should be 600pt")
        XCTAssertLessThanOrEqual(ApexStyle.minWindowHeight, 440, "Window minHeight must be <= 440")
        XCTAssertEqual(ApexStyle.minWindowHeight, 400, "Window minHeight should be 400pt")
        XCTAssertLessThanOrEqual(ApexStyle.minSidebarWidth, 200, "Sidebar minWidth must be <= 200 to allow sufficient detail pane width in half-screen")

        // 2. Verify WindowStateView sets minSize on NSWindow
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let stateHost = NSHostingView(rootView: WindowStateView().frame(width: 0, height: 0))
        window.contentView = stateHost
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertLessThanOrEqual(window.minSize.width, 640, "NSWindow minSize width must not exceed 640pt")
        XCTAssertEqual(window.minSize.width, ApexStyle.minWindowWidth)
        XCTAssertLessThanOrEqual(window.minSize.height, 440, "NSWindow minSize height must not exceed 440pt")
        XCTAssertEqual(window.minSize.height, ApexStyle.minWindowHeight)
        window.orderOut(nil)

        // 3. Verify Sidebar and Workspace layout render cleanly at compact 600x400 split dimensions
        let store = SessionStore()
        let local = Session.local()
        store.sessions = [local]
        let sidebar = SidebarView(
            store: store,
            selectedSession: .constant(nil),
            onConnect: { _ in },
            onRunSnippet: { _ in }
        )
        let compactSidebarHost = NSHostingView(rootView: sidebar.apexTheme())
        compactSidebarHost.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        compactSidebarHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(compactSidebarHost.subviews.count, 0, "Compact sidebar at 200pt width must lay out successfully")

        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)
        let workspace = WorkspaceView(
            store: store,
            activeTabs: .constant([tab]),
            selectedTabId: .constant(tab.id)
        )
        let compactWorkspaceHost = NSHostingView(rootView: workspace.apexTheme())
        compactWorkspaceHost.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        compactWorkspaceHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(compactWorkspaceHost.subviews.count, 0, "Compact detail pane at 400pt width must lay out successfully")
    }

    func testLiquidClassDesignTokensAndModifiers() {
        // 1. Verify fluid spring animation tokens
        XCTAssertNotNil(ApexStyle.springDefault)
        XCTAssertNotNil(ApexStyle.springSnappy)
        XCTAssertNotNil(ApexStyle.springSmooth)
        XCTAssertNotNil(ApexStyle.hoverTransition)

        // 2. Verify apexGlassCard modifier
        let cardView = Text("Liquid Glass Content")
            .apexGlassCard(cornerRadius: 12, material: .regularMaterial, borderColor: Color.primary.opacity(0.1), shadowRadius: 8)
        let hostingCard = NSHostingView(rootView: cardView)
        hostingCard.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        let cardSize = hostingCard.fittingSize
        XCTAssertGreaterThan(cardSize.width, 0, "apexGlassCard must compute valid layout width")
        XCTAssertGreaterThan(cardSize.height, 0, "apexGlassCard must compute valid layout height")

        // 3. Verify apexKeycap modifier
        let keycapView = Text("⌘P").apexKeycap()
        let hostingKeycap = NSHostingView(rootView: keycapView)
        hostingKeycap.frame = NSRect(x: 0, y: 0, width: 60, height: 26)
        let keycapSize = hostingKeycap.fittingSize
        XCTAssertGreaterThan(keycapSize.width, 0, "apexKeycap must compute valid layout width")
        XCTAssertGreaterThan(keycapSize.height, 0, "apexKeycap must compute valid layout height")

        // 4. Verify ApexIconButton rendering and frame geometry
        var iconClicked = false
        let iconButton = ApexIconButton(
            icon: "plus",
            label: "新建",
            size: 26,
            iconSize: 11,
            isSelected: false,
            action: { iconClicked = true }
        )
        let hostingIconBtn = NSHostingView(rootView: iconButton)
        hostingIconBtn.frame = NSRect(x: 0, y: 0, width: 26, height: 26)
        let iconBtnSize = hostingIconBtn.fittingSize
        XCTAssertGreaterThan(iconBtnSize.width, 0, "ApexIconButton must compute valid layout width")
        XCTAssertFalse(iconClicked)

        // 5. Verify ApexPillButton rendering
        var pillClicked = false
        let pillButton = ApexPillButton(
            title: "Docker",
            icon: "bolt.fill",
            isSelected: true,
            count: 5,
            action: { pillClicked = true }
        )
        let hostingPillBtn = NSHostingView(rootView: pillButton)
        hostingPillBtn.frame = NSRect(x: 0, y: 0, width: 120, height: 28)
        let pillBtnSize = hostingPillBtn.fittingSize
        XCTAssertGreaterThan(pillBtnSize.width, 0, "ApexPillButton must compute valid layout width")
        XCTAssertFalse(pillClicked)

        // 6. Verify ApexActionButton rendering (standard, prominent, and loading)
        var actionClicked = false
        let actionButton = ApexActionButton(
            "一键部署",
            icon: "arrow.up.forward.app",
            tint: ApexStyle.accent,
            size: .small,
            action: { actionClicked = true }
        )
        let hostingActionBtn = NSHostingView(rootView: actionButton)
        hostingActionBtn.frame = NSRect(x: 0, y: 0, width: 100, height: 26)
        let actionBtnSize = hostingActionBtn.fittingSize
        XCTAssertGreaterThan(actionBtnSize.width, 0, "ApexActionButton must compute valid layout width")
        XCTAssertFalse(actionClicked)

        let prominentActionButton = ApexActionButton(
            "立即保存",
            icon: "checkmark",
            tint: ApexStyle.accent,
            size: .regular,
            isProminent: true,
            isLoading: false,
            action: {}
        )
        let hostingProminentBtn = NSHostingView(rootView: prominentActionButton)
        hostingProminentBtn.frame = NSRect(x: 0, y: 0, width: 120, height: 32)
        XCTAssertGreaterThan(hostingProminentBtn.fittingSize.width, 0, "Prominent ApexActionButton must compute valid layout width")

        let loadingActionButton = ApexActionButton(
            "同步中",
            tint: ApexStyle.accent,
            size: .small,
            isProminent: false,
            isLoading: true,
            action: {}
        )
        let hostingLoadingBtn = NSHostingView(rootView: loadingActionButton)
        hostingLoadingBtn.frame = NSRect(x: 0, y: 0, width: 100, height: 26)
        XCTAssertGreaterThan(hostingLoadingBtn.fittingSize.width, 0, "Loading ApexActionButton must compute valid layout width")

        // 7. Verify ApexMenuTrigger rendering
        let menuTrigger = ApexMenuTrigger(
            icon: "ellipsis",
            label: "更多文件操作",
            size: 24,
            iconSize: 11
        )
        let hostingMenuTrigger = NSHostingView(rootView: menuTrigger)
        hostingMenuTrigger.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        let menuTriggerSize = hostingMenuTrigger.fittingSize
        XCTAssertGreaterThan(menuTriggerSize.width, 0, "ApexMenuTrigger must compute valid layout width")

        // 8. Verify ApexSplitDividerHandle rendering
        let verticalHandle = ApexSplitDividerHandle(isVertical: true)
        let hostingVHandle = NSHostingView(rootView: verticalHandle)
        hostingVHandle.frame = NSRect(x: 0, y: 0, width: 8, height: 100)
        XCTAssertGreaterThan(hostingVHandle.fittingSize.height, 0, "Vertical ApexSplitDividerHandle must lay out cleanly")

        let horizontalHandle = ApexSplitDividerHandle(isVertical: false)
        let hostingHHandle = NSHostingView(rootView: horizontalHandle)
        hostingHHandle.frame = NSRect(x: 0, y: 0, width: 100, height: 8)
        XCTAssertGreaterThan(hostingHHandle.fittingSize.width, 0, "Horizontal ApexSplitDividerHandle must lay out cleanly")
    }

    func testQuickCommandDockAndTabLiquidClassIntegration() {
        let store = SessionStore()
        let local = Session.local()
        store.sessions = [local]
        
        var isQuickCmdVisible = true
        var executedCommand = ""
        let quickDock = QuickCommandBarView(
            store: store,
            isVisible: Binding(get: { isQuickCmdVisible }, set: { isQuickCmdVisible = $0 }),
            onExecuteCommand: { cmd in executedCommand = cmd }
        )
        let hostingDock = NSHostingView(rootView: quickDock.apexTheme())
        hostingDock.frame = NSRect(x: 0, y: 0, width: 600, height: 38)
        hostingDock.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingDock.subviews.count, 0, "QuickCommandBarView dock must lay out cleanly at 38pt height")
        XCTAssertEqual(executedCommand, "")
    }

    func testWorkspaceEmptyStateAndBottomStatusBarLiquidClass() {
        let store = SessionStore()
        
        // 1. Test empty state layout (activeTabs is empty)
        let emptyWorkspace = WorkspaceView(
            store: store,
            activeTabs: .constant([]),
            selectedTabId: .constant(nil)
        )
        let emptyHost = NSHostingView(rootView: emptyWorkspace.apexTheme())
        emptyHost.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        emptyHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(emptyHost.subviews.count, 0, "Workspace empty state view must render cleanly")

        // 2. Test bottom status bar layout with active tab
        let local = Session.local()
        store.sessions = [local]
        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)
        let workspaceWithTab = WorkspaceView(
            store: store,
            activeTabs: .constant([tab]),
            selectedTabId: .constant(tab.id)
        )
        let activeHost = NSHostingView(rootView: workspaceWithTab.apexTheme())
        activeHost.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        activeHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(activeHost.subviews.count, 0, "Workspace with active tab and bottom status bar must render cleanly")
    }

    func testModalsAndSheetsLiquidClassIntegration() {
        let store = SessionStore()
        
        // 1. Test ShortcutsSheetView
        let shortcutsSheet = ShortcutsSheetView()
        let shortcutsHost = NSHostingView(rootView: shortcutsSheet.apexTheme())
        shortcutsHost.frame = NSRect(x: 0, y: 0, width: 620, height: 480)
        shortcutsHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(shortcutsHost.subviews.count, 0, "ShortcutsSheetView must lay out cleanly")

        // 2. Test SessionEditModal
        let sessionEdit = SessionEditModal(session: nil) { _ in }
        let sessionEditHost = NSHostingView(rootView: sessionEdit.apexTheme())
        sessionEditHost.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
        sessionEditHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(sessionEditHost.subviews.count, 0, "SessionEditModal must lay out cleanly")

        // 3. Test SSHConfigImportSheet
        let importSheet = SSHConfigImportSheet(store: store)
        let importHost = NSHostingView(rootView: importSheet.apexTheme())
        importHost.frame = NSRect(x: 0, y: 0, width: 540, height: 440)
        importHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(importHost.subviews.count, 0, "SSHConfigImportSheet must lay out cleanly")

        // 4. Test SSHTunnelModalView
        let tunnelModal = SSHTunnelModalView(store: store)
        let tunnelHost = NSHostingView(rootView: tunnelModal.apexTheme())
        tunnelHost.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        tunnelHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(tunnelHost.subviews.count, 0, "SSHTunnelModalView must lay out cleanly")

        // 5. Test UpdateSheetView with status
        let origStatus = UpdateManager.shared.status
        UpdateManager.shared.status = .upToDate(currentVersion: "1.10.0")
        defer { UpdateManager.shared.status = origStatus }
        let updateSheet = UpdateSheetView()
        let updateHost = NSHostingView(rootView: updateSheet.apexTheme())
        updateHost.frame = NSRect(x: 0, y: 0, width: 440, height: 320)
        updateHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(updateHost.subviews.count, 0, "UpdateSheetView must lay out cleanly")

        // 6. Test AboutView
        let aboutView = AboutView()
        let aboutHost = NSHostingView(rootView: aboutView.apexTheme())
        aboutHost.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        aboutHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(aboutHost.subviews.count, 0, "AboutView must lay out cleanly")
    }

    func testSettingsViewAndiCloudSyncLiquidClassIntegration() {
        let settingsView = SettingsView(initialTab: 4)
        let host = NSHostingView(rootView: settingsView.apexTheme())
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.subviews.count, 0, "SettingsView Backup & iCloud Sync tab must lay out cleanly")
        window.orderOut(nil)
    }

    func testSidebarViewIsCleanAndFocusedOnSessions() {
        let store = SessionStore()
        store.snippets = [
            Snippet(title: "Check Disk Space", command: "df -h", category: "系统管理")
        ]
        store.sessions = [Session.local(), Session(name: "Prod Server", host: "10.0.0.1", username: "root", authMethod: .agent)]
        
        let sidebar = SidebarView(
            store: store,
            selectedSession: .constant(nil),
            onConnect: { _ in }
        )
        let host = NSHostingView(rootView: sidebar.apexTheme())
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.subviews.count, 0, "Clean sidebar should render cleanly without crashing")
    }
}
