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
}
