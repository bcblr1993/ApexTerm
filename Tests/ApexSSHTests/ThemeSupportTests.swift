import XCTest
import AppKit
import SwiftUI
@testable import ApexCore
@testable import ApexTerminal
import ApexUI
import ApexSSH

final class ThemeSupportTests: XCTestCase {
    func testEveryThemeHasReadableUIAndTerminalColors() {
        XCTAssertEqual(TerminalThemePreset.selectablePresets.count, 12)
        XCTAssertEqual(TerminalThemePreset.selectablePresets.first, .nativeLight)
        for theme in TerminalThemePreset.allCases {
            let p = theme.palette
            XCTAssertEqual(p.ansi.count, 16, theme.rawValue)
            XCTAssertGreaterThanOrEqual(ThemePalette.contrast("#FFFFFF", ThemePalette.readable(p.accent, on: ["#FFFFFF"])), 4.5)
            for background in [p.surface, p.sidebar, p.selection] {
                for text in [p.foreground, p.secondary, p.accent, p.success, p.warning, p.error] {
                    XCTAssertGreaterThanOrEqual(ThemePalette.contrast(text, background), 4.5, "\(theme.rawValue): \(text) on \(background)")
                }
            }
            for index in 0..<16 {
                XCTAssertGreaterThanOrEqual(ThemePalette.contrast(p.terminalColor(at: index), p.terminal), 4.5, "\(theme.rawValue) ANSI \(index)")
            }
        }
    }

    @MainActor
    func testSwitchRecolorsExistingOutputAndPreservesTrueColor() {
        let settings = AppSettings.shared
        let previous = settings.themePreset
        defer { settings.themePreset = previous }
        settings.themePreset = .tokyo
        let scroll = NativeTerminalScrollView()
        let view = scroll.terminalView
        view.applyAppSettings()
        view.appendRawOutput("plain \u{1B}[31mred \u{1B}[38;2;1;2;3mtrue")
        let text = view.string
        for theme in TerminalThemePreset.allCases {
            settings.themePreset = theme
            view.applyAppSettings()
            XCTAssertEqual(view.string, text)
            let storage = view.textStorage!
            let expected = NSColor(hex: theme.foregroundColorHex)!
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, expected)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor, NSColor(hex: theme.palette.terminalColor(at: 1)))
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor, NSColor(hex: "#010203"))
            XCTAssertEqual(view.appearance?.name, theme.isDark ? .darkAqua : .aqua)
            XCTAssertEqual(scroll.searchBarOverlay.searchField.textColor, NSColor(hex: theme.foregroundColorHex))
        }
    }

    @MainActor
    func testRingBufferRetainsThemeIndicesAcrossChunksAndRefresh() {
        let settings = AppSettings.shared
        let previous = settings.themePreset
        defer { settings.themePreset = previous }
        let buffer = TerminalRingBuffer()
        buffer.appendStream("\u{1B}[31mred")
        buffer.appendStream(" line\n\u{1B}[38;2;1;2;3mtrue\n")
        let parsed = VTParser().parseANSI(buffer.tailLines(count: 2).joined(separator: "\n"))
        XCTAssertEqual(parsed.first?.ansiColorIndex, 1)
        let view = NativeTerminalView()
        view.ringBuffer = buffer
        settings.themePreset = .nativeLight
        view.applyAppSettings()
        view.refresh()
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor(hex: settings.themePreset.palette.terminalColor(at: 1)))
        settings.themePreset = .mocha
        view.applyAppSettings()
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor(hex: settings.themePreset.palette.terminalColor(at: 1)))
        let trueRange = (view.string as NSString).range(of: "true")
        XCTAssertNotEqual(trueRange.location, NSNotFound, view.string)
        XCTAssertEqual(view.textStorage?.attribute(.foregroundColor, at: trueRange.location, effectiveRange: nil) as? NSColor, NSColor(hex: "#010203"), "Rendered: \(view.string.debugDescription), spans: \(parsed)")
    }

    @MainActor
    func testFindHighlightsStayReadableAfterSwitch() {
        let settings = AppSettings.shared
        let previous = settings.themePreset
        defer { settings.themePreset = previous }
        let view = NativeTerminalView()
        view.appendRawOutput("match match")
        XCTAssertEqual(view.performFind(query: "match"), 2)
        for theme in TerminalThemePreset.selectablePresets {
            settings.themePreset = theme
            view.applyAppSettings()
            for range in view.currentMatches {
                let foreground = view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
                let background = view.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
                XCTAssertNotNil(foreground)
                XCTAssertNotNil(background)
            }
        }
        view.clearFind()
        XCTAssertNil(view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil))
    }

    func testIndexedColorsRemainDistinctFromTrueColor() {
        let spans = VTParser().parseANSI("\u{1B}[31mA\u{1B}[91mB\u{1B}[38;5;4mC\u{1B}[38;2;255;69;58mD\u{1B}[39mE")
        XCTAssertEqual(spans.map(\.ansiColorIndex), [1, 9, 4, nil, nil])
        XCTAssertEqual(spans[3].foregroundColorHex, "#FF453A")
    }

    @MainActor
    func testThemeSettingsAndDialogSnapshots() throws {
        guard ProcessInfo.processInfo.environment["APEX_THEME_SNAPSHOTS"] == "1" else { return }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        let settings = AppSettings.shared
        let previous = settings.themePreset
        defer { settings.themePreset = previous }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/theme-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(baseDirectory: directory.appendingPathComponent("synthetic-store"))
        let session = Session(name: "主题验收 · 演示", host: "example.invalid", username: "demo")
        store.sessions = [session]
        let client = MockSSHSession(session: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        tab.connectionState = .connected
        tab.panes[0].connectionState = .connected
        tab.ringBuffer.appendStream("demo@host $ ls\n\u{1B}[31mERROR demo\u{1B}[0m\n\u{1B}[32mOK demo\u{1B}[0m\n\u{1B}[33mWARN demo\u{1B}[0m\n")
        let main = NavigationSplitView {
            SidebarView(store: store, selectedSession: .constant(session), onConnect: { _ in }, onRunSnippet: { _ in })
                .frame(minWidth: 260)
        } detail: {
            WorkspaceView(store: store, activeTabs: .constant([tab]), selectedTabId: .constant(tab.id))
        }
        let editor = QuickEditorView(item: SFTPItem(name: "demo.txt", path: "/demo/demo.txt", isDirectory: false), content: .constant("Hello, theme!\nReadable editor text\n"), onSave: { _ in }, onReload: { "demo" })
        let themes: [TerminalThemePreset] = [.nativeLight, .modern, .tokyo, .mocha, .nord, .dracula, .latte, .onedark, .gruvbox, .everforest, .rosepine, .solarized]
        for (index, theme) in themes.enumerated() {
            if let only = ProcessInfo.processInfo.environment["APEX_THEME_SNAPSHOT_ONLY"], only != String(index) { continue }
            settings.themePreset = theme
            let views: [(String, AnyView, NSSize)] = [
                ("settings", AnyView(SettingsView(initialTab: 1).apexTheme()), NSSize(width: 620, height: 530)),
                ("session", AnyView(SessionEditModal(session: nil, onSave: { _ in }).apexTheme()), NSSize(width: 620, height: 660)),
                ("about", AnyView(AboutView().apexTheme()), NSSize(width: 700, height: 760)),
                ("shortcuts", AnyView(ShortcutsSheetView().apexTheme()), NSSize(width: 760, height: 760)),
                ("main", AnyView(main.apexTheme()), NSSize(width: 1240, height: 760)),
                ("editor", AnyView(editor.apexTheme()), NSSize(width: 900, height: 650)),
                ("transfers", AnyView(TransferDrawer(isExpanded: .constant(true)).apexTheme()), NSSize(width: 900, height: 550))
            ]
            for (name, root, size) in views {
                if let scope = ProcessInfo.processInfo.environment["APEX_THEME_SNAPSHOT_SCOPE"], name != scope { continue }
                let host = NSHostingView(rootView: root.environment(\.controlActiveState, .active))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.toolbarStyle = .unifiedCompact
                window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
                window.makeKeyAndOrderFront(nil)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                window.displayIfNeeded()
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent(String(format: "%02d-%@.png", index, name)))
                if name == "main" {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-l", String(window.windowNumber), directory.appendingPathComponent(String(format: "%02d-main-screen.png", index)).path]
                    capture.standardError = FileHandle.nullDevice
                    try capture.run()
                    capture.waitUntilExit()
                }
                window.orderOut(nil)
            }
        }
    }
}
