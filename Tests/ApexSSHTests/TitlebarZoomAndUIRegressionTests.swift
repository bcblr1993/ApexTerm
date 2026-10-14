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
}
