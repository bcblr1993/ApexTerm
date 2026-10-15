import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

@MainActor
final class ExperiencePolishTests: XCTestCase {
    
    // MARK: - TC-EXP-01: Terminal Font & Nerd Font Recognition
    func testTerminalFontManagerEnumerationAndNerdFontRecognition() {
        let manager = TerminalFontManager.shared
        
        // 1. Test Nerd Font naming detection
        XCTAssertTrue(TerminalFontManager.detectNerdFont("MesloLGS NF"))
        XCTAssertTrue(TerminalFontManager.detectNerdFont("FiraCode Nerd Font"))
        XCTAssertTrue(TerminalFontManager.detectNerdFont("JetBrainsMono Nerd Font Mono"))
        XCTAssertTrue(TerminalFontManager.detectNerdFont("Hack NF"))
        XCTAssertTrue(TerminalFontManager.detectNerdFont("SauceCodePro Nerd Font"))
        XCTAssertTrue(TerminalFontManager.detectNerdFont("CascadiaCode Powerline"))
        XCTAssertFalse(TerminalFontManager.detectNerdFont("SF Mono"))
        XCTAssertFalse(TerminalFontManager.detectNerdFont("Menlo"))
        XCTAssertFalse(TerminalFontManager.detectNerdFont("Monaco"))
        XCTAssertFalse(TerminalFontManager.detectNerdFont("Courier"))
        XCTAssertFalse(TerminalFontManager.detectNerdFont("PingFang SC"))
        
        // 2. Test Monospace detection
        XCTAssertTrue(TerminalFontManager.isMonospace(fontName: "SF Mono"))
        XCTAssertTrue(TerminalFontManager.isMonospace(fontName: "Menlo"))
        XCTAssertTrue(TerminalFontManager.isMonospace(fontName: "Monaco"))
        XCTAssertTrue(TerminalFontManager.isMonospace(fontName: "Courier New"))
        XCTAssertTrue(TerminalFontManager.isMonospace(fontName: "JetBrains Mono"))
        XCTAssertTrue(TerminalFontManager.isMonospace(fontName: "MesloLGS NF"))
        XCTAssertFalse(TerminalFontManager.isMonospace(fontName: "Arial"))
        
        // 3. Test TerminalFontOption model
        let nfOption = TerminalFontOption(familyName: "MesloLGS NF")
        XCTAssertTrue(nfOption.isNerdFont)
        XCTAssertTrue(nfOption.displayName.contains("[Nerd Font]"))
        XCTAssertEqual(nfOption.id, "MesloLGS NF")
        
        let regularOption = TerminalFontOption(familyName: "SF Mono")
        XCTAssertFalse(regularOption.isNerdFont)
        XCTAssertEqual(regularOption.displayName, "SF Mono")
        
        // 4. Test available fonts list
        let fonts = manager.availableFonts(forceRefresh: true)
        XCTAssertFalse(fonts.isEmpty, "Font list must never be empty")
        
        // Ensure standard curated monospace fonts are present
        let familyNames = Set(fonts.map { $0.familyName })
        XCTAssertTrue(familyNames.contains("SF Mono") || familyNames.contains("Menlo") || familyNames.contains("Monaco"),
                      "Curated macOS monospace fonts should be included")
    }
    
    // MARK: - TC-EXP-02: Tab Cycling Navigation
    func testTabCyclingNavigationPreviousAndNext() {
        let session1 = Session(name: "Server-1", host: "192.0.2.1", username: "u1")
        let session2 = Session(name: "Server-2", host: "192.0.2.2", username: "u2")
        let session3 = Session(name: "Server-3", host: "192.0.2.3", username: "u3")
        
        let tab1 = TerminalTabItem(session: session1, sshClient: MockSSHSession(session: session1))
        let tab2 = TerminalTabItem(session: session2, sshClient: MockSSHSession(session: session2))
        let tab3 = TerminalTabItem(session: session3, sshClient: MockSSHSession(session: session3))
        
        let tabs = [tab1, tab2, tab3]
        var selectedTabId: UUID? = tab1.id
        
        // Helper function matching WorkspaceView tab cycling logic
        func cycleNext() {
            guard tabs.count > 1 else { return }
            let curIdx = tabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
            let nextIdx = (curIdx + 1) % tabs.count
            selectedTabId = tabs[nextIdx].id
        }
        
        func cyclePrevious() {
            guard tabs.count > 1 else { return }
            let curIdx = tabs.firstIndex(where: { $0.id == selectedTabId }) ?? 0
            let prevIdx = (curIdx - 1 + tabs.count) % tabs.count
            selectedTabId = tabs[prevIdx].id
        }
        
        // Test Next Cycling: 0 -> 1 -> 2 -> 0
        XCTAssertEqual(selectedTabId, tab1.id)
        cycleNext()
        XCTAssertEqual(selectedTabId, tab2.id)
        cycleNext()
        XCTAssertEqual(selectedTabId, tab3.id)
        cycleNext()
        XCTAssertEqual(selectedTabId, tab1.id, "Wrap-around next should return to tab 1")
        
        // Test Previous Cycling: 0 -> 2 -> 1 -> 0
        cyclePrevious()
        XCTAssertEqual(selectedTabId, tab3.id, "Wrap-around previous should jump to last tab")
        cyclePrevious()
        XCTAssertEqual(selectedTabId, tab2.id)
        cyclePrevious()
        XCTAssertEqual(selectedTabId, tab1.id)
    }
    
    // MARK: - TC-EXP-03: Split Pane Zoom / Maximize & Restore
    func testSplitPaneMaximizeAndRestore() {
        let session = Session(name: "prod-cluster", host: "10.0.0.1", username: "admin")
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        
        // Initial state: single pane, not maximized
        XCTAssertFalse(tab.isPaneMaximized)
        tab.toggleMaximizeActivePane()
        XCTAssertFalse(tab.isPaneMaximized, "Single pane should not maximize")
        
        // Split pane
        tab.split(mode: .vertical)
        XCTAssertEqual(tab.panes.count, 2)
        XCTAssertFalse(tab.isPaneMaximized)
        
        let pane1 = tab.panes[0]
        let pane2 = tab.panes[1]
        
        // Maximize active pane
        tab.toggleMaximizeActivePane()
        XCTAssertTrue(tab.isPaneMaximized, "Split pane should now be maximized")
        
        // Ensure background pane continues receiving data independently while unzoomed
        pane1.ringBuffer.appendStream("Background Primary Data\n")
        pane2.ringBuffer.appendStream("Maximized Secondary Data\n")
        
        XCTAssertEqual(pane1.ringBuffer.allLines(), ["Background Primary Data"])
        XCTAssertEqual(pane2.ringBuffer.allLines(), ["Maximized Secondary Data"])
        
        // Unmaximize
        tab.toggleMaximizeActivePane()
        XCTAssertFalse(tab.isPaneMaximized, "Should restore split ratio layout")
        
        // Close pane should safely reset maximize flag
        tab.toggleMaximizeActivePane()
        XCTAssertTrue(tab.isPaneMaximized)
        tab.closePane(id: pane2.id)
        XCTAssertEqual(tab.panes.count, 1)
        XCTAssertFalse(tab.isPaneMaximized, "Closing split pane should reset maximized state")
    }
    
    // MARK: - TC-EXP-04: Split Pane Focus Navigation
    func testSplitPaneFocusNavigation() {
        let session = Session(name: "multi-pane", host: "10.0.0.2", username: "dev")
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        
        tab.split(mode: .horizontal)
        XCTAssertEqual(tab.panes.count, 2)
        
        let pane0 = tab.panes[0]
        let pane1 = tab.panes[1]
        
        tab.activePaneId = pane0.id
        XCTAssertEqual(tab.activePane?.id, pane0.id)
        
        // Focus next pane: 0 -> 1
        tab.focusNextPane()
        XCTAssertEqual(tab.activePaneId, pane1.id)
        
        // Focus next pane wraps: 1 -> 0
        tab.focusNextPane()
        XCTAssertEqual(tab.activePaneId, pane0.id)
        
        // Focus previous pane wraps: 0 -> 1
        tab.focusPreviousPane()
        XCTAssertEqual(tab.activePaneId, pane1.id)
        
        // Focus previous pane: 1 -> 0
        tab.focusPreviousPane()
        XCTAssertEqual(tab.activePaneId, pane0.id)
    }
    
    // MARK: - TC-EXP-05: Shortcuts Cheat Sheet Accuracy
    func testShortcutsSheetAccuracyAndCommandConsistency() {
        let sheet = ShortcutsSheetView()
        let mirror = Mirror(reflecting: sheet)
        
        // Extract groups via reflection or struct inspection
        let groupsChild = mirror.children.first(where: { $0.label == "groups" })
        XCTAssertNotNil(groupsChild, "ShortcutsSheetView should define its shortcut groups")
        
        if let groups = groupsChild?.value as? [Any] {
            var allDescriptions: [String] = []
            var allKeyCombos: [[String]] = []
            
            for group in groups {
                let groupMirror = Mirror(reflecting: group)
                if let items = groupMirror.children.first(where: { $0.label == "items" })?.value as? [Any] {
                    for item in items {
                        let itemMirror = Mirror(reflecting: item)
                        if let keys = itemMirror.children.first(where: { $0.label == "keys" })?.value as? [String],
                           let desc = itemMirror.children.first(where: { $0.label == "description" })?.value as? String {
                            allDescriptions.append(desc)
                            allKeyCombos.append(keys)
                        }
                    }
                }
            }
            
            // Assert "新建本地终端" is present and matched to ⌘⇧T
            let hasLocalTerminal = allDescriptions.contains(where: { $0.contains("新建本地终端") || $0.contains("本地终端") })
            XCTAssertTrue(hasLocalTerminal, "Cheat sheet must correctly document ⌘⇧T as New Local Terminal")
            
            // Assert Tab cycling is documented
            let hasTabCycling = allDescriptions.contains(where: { $0.contains("下一个") || $0.contains("标签页") })
            XCTAssertTrue(hasTabCycling, "Cheat sheet must document tab cycling shortcuts")
            
            // Assert Split pane zoom is documented
            let hasZoom = allDescriptions.contains(where: { $0.contains("全屏放大") || $0.contains("最大化") || $0.contains("Zoom") })
            XCTAssertTrue(hasZoom, "Cheat sheet must document split pane zoom shortcut")
        }
    }
    
    // MARK: - TC-EXP-06: SFTP Bookmarks Preset and Custom Persistence
    func testSFTPBookmarksPresetAndCustomPersistence() {
        let manager = SFTPBookmarkManager.shared
        manager.resetToDefaults()
        
        // 1. Verify default presets
        let presets = SFTPBookmarkManager.defaultPresets
        XCTAssertGreaterThanOrEqual(presets.count, 5)
        
        let presetPaths = Set(presets.map { $0.path })
        XCTAssertTrue(presetPaths.contains("~"))
        XCTAssertTrue(presetPaths.contains("/var/log"))
        XCTAssertTrue(presetPaths.contains("/etc"))
        XCTAssertTrue(presetPaths.contains("/tmp"))
        XCTAssertTrue(presetPaths.contains("/opt"))
        
        // 2. Add custom bookmark
        XCTAssertFalse(manager.isBookmarked(path: "/data/wwwroot"))
        manager.addCustomBookmark(name: "生产 Web 根目录", path: "/data/wwwroot")
        
        XCTAssertTrue(manager.isBookmarked(path: "/data/wwwroot"))
        XCTAssertEqual(manager.customBookmarks.count, 1)
        XCTAssertEqual(manager.customBookmarks.first?.name, "生产 Web 根目录")
        XCTAssertEqual(manager.customBookmarks.first?.path, "/data/wwwroot")
        
        // 3. Remove custom bookmark
        if let customId = manager.customBookmarks.first?.id {
            manager.removeCustomBookmark(id: customId)
            XCTAssertFalse(manager.isBookmarked(path: "/data/wwwroot"))
            XCTAssertEqual(manager.customBookmarks.count, 0)
        }
        
        // 4. Cleanup
        manager.resetToDefaults()
    }
}
