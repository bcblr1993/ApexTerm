import XCTest
import AppKit
import SwiftUI
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

@MainActor
final class UIQualityOverhaulTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - 1. Solarized Selection & WCAG Theme Contrast

    func testSolarizedSelectionIsDistinctAndAccessibleContrast() {
        let solarized = ThemePalette.forPreset(.solarized)
        XCTAssertNotEqual(
            solarized.selection.uppercased(),
            solarized.surface.uppercased(),
            "Solarized selection color must differ from surface so editor and list selections remain visible"
        )

        for preset in TerminalThemePreset.allCases {
            let p = preset.palette
            for bg in [p.surface, p.sidebar, p.selection] {
                XCTAssertGreaterThanOrEqual(
                    ThemePalette.contrast(p.foreground, bg),
                    4.5,
                    "\(preset.rawValue): foreground must maintain >=4.5:1 contrast on \(bg)"
                )
                XCTAssertGreaterThanOrEqual(
                    ThemePalette.contrast(p.accent, bg),
                    4.5,
                    "\(preset.rawValue): accent must maintain >=4.5:1 contrast on \(bg)"
                )
            }
        }
    }

    // MARK: - 2. CommandPaletteItem Deterministic Stable IDs

    func testCommandPaletteStableIDDeterminism() throws {
        let a1 = CommandPaletteItem.stableID(for: "action.openSettings")
        let a2 = CommandPaletteItem.stableID(for: "action.openSettings")
        let b = CommandPaletteItem.stableID(for: "action.newLocalTerminal")
        XCTAssertEqual(a1, a2, "Identical keys must produce identical stable UUIDs")
        XCTAssertNotEqual(a1, b, "Distinct keys must produce distinct stable UUIDs")

        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/ApexUI/Workspace/CommandPaletteModalView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("CommandPaletteItem.stableID(for:"),
            "CommandPaletteModalView must assign deterministic stable IDs instead of random UUID() per redraw"
        )
    }

    // MARK: - 3. Foundation Controls: ApexIconButton isEnabled & ApexGlassCardModifier Clipping

    func testApexStyleIconButtonIsEnabledAndGlassCardClipping() throws {
        let styleSource = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/ApexUI/ApexStyle.swift"),
            encoding: .utf8
        )

        let iconStart = try XCTUnwrap(styleSource.range(of: "public struct ApexIconButton: View"))
        let iconRest = styleSource[iconStart.upperBound...]
        let iconBody = iconRest.range(of: "\npublic struct ").map { iconRest[..<$0.lowerBound] } ?? iconRest
        XCTAssertTrue(iconBody.contains("@Environment(\\.isEnabled)"), "ApexIconButton must observe @Environment(\\.isEnabled)")
        XCTAssertTrue(iconBody.contains("activeHover"), "ApexIconButton must suppress hover highlights when disabled")

        let glassStart = try XCTUnwrap(styleSource.range(of: "public struct ApexGlassCardModifier: ViewModifier"))
        let glassRest = styleSource[glassStart.upperBound...]
        let glassBody = glassRest.range(of: "\n/// ").map { glassRest[..<$0.lowerBound] } ?? glassRest
        XCTAssertTrue(glassBody.contains(".clipShape(RoundedRectangle(cornerRadius: cornerRadius))"),
                      "ApexGlassCardModifier must clip inner backgrounds to its rounded border")

        let disabledBtn = ApexIconButton(icon: "play.fill", label: "Run", size: 24, iconSize: 11) {}
            .disabled(true)
            .apexTheme()
        let host = NSHostingView(rootView: disabledBtn)
        host.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.subviews.count, 0)
    }

    // MARK: - 4. Sheet Theme Propagation Across Modules

    func testSheetsAndModalsApplyApexTheme() throws {
        let root = repoRoot()

        let sftpSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/SFTP/SFTPView.swift"), encoding: .utf8)
        let editorSheetRange = try XCTUnwrap(sftpSource.range(of: ".sheet(item: $editingFile)"))
        let editorSnippet = String(sftpSource[editorSheetRange.upperBound...].prefix(500))
        XCTAssertTrue(editorSnippet.contains(".apexTheme()"), "QuickEditorView sheet in SFTPView must apply .apexTheme()")

        let sidebarSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Sidebar/SidebarView.swift"), encoding: .utf8)
        for sheetName in ["$showingAddSheet", "$showingImportSheet", "$editingSession", "$cloningSession"] {
            let range = try XCTUnwrap(sidebarSource.range(of: ".sheet(isPresented: \(sheetName))") ?? sidebarSource.range(of: ".sheet(item: \(sheetName))"), sheetName)
            let snippet = String(sidebarSource[range.upperBound...].prefix(350))
            XCTAssertTrue(snippet.contains(".apexTheme()"), "Sidebar sheet \(sheetName) must apply .apexTheme()")
        }

        let vaultSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Settings/SSHKeyVaultSettingsView.swift"), encoding: .utf8)
        for sheetName in ["$showingImportSheet", "$showingDeploySheet"] {
            let range = try XCTUnwrap(vaultSource.range(of: ".sheet(isPresented: \(sheetName))"), sheetName)
            let snippet = String(vaultSource[range.upperBound...].prefix(200))
            XCTAssertTrue(snippet.contains(".apexTheme()"), "KeyVault sheet \(sheetName) must apply .apexTheme()")
        }
    }

    // MARK: - 5. App, Update, KnownHosts, About & SFTP Notice Verification

    func testAppSettingsObserverAndModalBehaviorGuards() throws {
        let root = repoRoot()

        let appSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexTerm/ApexTermApp.swift"), encoding: .utf8)
        XCTAssertTrue(appSource.contains("NSNotification.Name(\"OpenSettingsModal\")"),
                      "ApexTermApp must observe OpenSettingsModal notifications from Command Palette")

        let updateSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/About/UpdateSheetView.swift"), encoding: .utf8)
        XCTAssertFalse(updateSource.contains("case .idle:\n            EmptyView()"),
                       "UpdateSheetView must render an explicit idle fallback with dismiss control rather than EmptyView")
        XCTAssertTrue(updateSource.contains("idleView"), "UpdateSheetView must provide an idleView fallback")

        let knownHostsSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Settings/KnownHostsSettingsView.swift"), encoding: .utf8)
        XCTAssertFalse(knownHostsSource.contains("try? manager.removeEntry"),
                       "KnownHostsSettingsView must handle removeEntry errors instead of swallowing with try?")

        let aboutSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/About/AboutView.swift"), encoding: .utf8)
        XCTAssertTrue(aboutSource.contains("distributionChannel == .appStore"),
                      "AboutView check-update button must route App Store builds to the App Store listing")

        let sftpSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/SFTP/SFTPView.swift"), encoding: .utf8)
        XCTAssertTrue(sftpSource.contains("enum SFTPNoticeKind"),
                      "SFTPView must classify notice severity via explicit SFTPNoticeKind enum")
    }

    // MARK: - 6. Compact 600x400 & Multi-Theme Render Smoke Checks

    func testCompact600x400AndSheetRenderSmokeChecks() {
        let store = SessionStore()
        let local = Session.local()
        let remote = Session(name: "ProdNode", host: "10.8.8.71", port: 22, username: "root")
        store.sessions = [local, remote]
        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)

        let workspace = WorkspaceView(
            store: store,
            activeTabs: .constant([tab]),
            selectedTabId: .constant(tab.id)
        )
        let wsHost = NSHostingView(rootView: workspace.apexTheme())
        wsHost.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        wsHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(wsHost.subviews.count, 0)

        let palette = CommandPaletteModalView(store: store, isPresented: .constant(true)) { _ in }
        let paletteHost = NSHostingView(rootView: palette.apexTheme())
        paletteHost.frame = NSRect(x: 0, y: 0, width: 400, height: 360)
        paletteHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(paletteHost.subviews.count, 0)

        let metrics = ServerMetricsSnapshot(
            cpuUsagePercent: 42.5,
            cpuCores: 8,
            cpuModel: "Apple Silicon",
            memoryTotalBytes: 16 * 1024 * 1024 * 1024,
            memoryUsedBytes: 4 * 1024 * 1024 * 1024,
            swapTotalBytes: 2 * 1024 * 1024 * 1024,
            swapUsedBytes: 128 * 1024 * 1024,
            networkRxBytesPerSec: 1_240_000,
            networkTxBytesPerSec: 420_000,
            diskTotalBytes: 200_000_000_000,
            diskUsedBytes: 128_000_000_000,
            loadAvg1m: 1.20,
            loadAvg5m: 0.95,
            loadAvg15m: 0.80,
            uptimeSeconds: 12 * 86400,
            topProcesses: [
                ProcessMetricItem(pid: 101, user: "root", cpuPercent: 18.2, memPercent: 4.5, command: "swift")
            ]
        )
        let history = ObservableMetricsHistory()
        history.append(metrics)
        for dockWidth in [188.0, 310.0] {
            let detail = MetricDetailView(
                historyStore: history,
                monitoringEnabled: true,
                connectionActive: true,
                connectionConnecting: false,
                isPinned: true,
                sessionLabel: "root@10.8.8.71",
                onTogglePin: {},
                onDismiss: {}
            )
            let detailHost = NSHostingView(rootView: detail.apexTheme())
            detailHost.frame = NSRect(x: 0, y: 0, width: dockWidth, height: 360)
            detailHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(detailHost.subviews.count, 0)
        }

        let prevPreset = AppSettings.shared.themePreset
        let prevFollow = AppSettings.shared.followsSystemAppearance
        defer {
            AppSettings.shared.themePreset = prevPreset
            AppSettings.shared.followsSystemAppearance = prevFollow
        }
        AppSettings.shared.followsSystemAppearance = false
        AppSettings.shared.themePreset = .solarized

        let editor = QuickEditorView(
            item: SFTPItem(name: "nginx.conf", path: "/etc/nginx/nginx.conf", isDirectory: false, size: 128, permissions: 0o644),
            content: .constant("server { listen 80; }\n"),
            onSave: { _ in },
            onReload: { "server { listen 80; }\n" }
        )
        let editorHost = NSHostingView(rootView: editor.apexTheme())
        editorHost.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        editorHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(editorHost.subviews.count, 0)

        let drawer = TransferDrawer(isExpanded: .constant(true))
        let drawerHost = NSHostingView(rootView: drawer.apexTheme())
        drawerHost.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        drawerHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(drawerHost.subviews.count, 0)

        for view in [
            AnyView(SSHTunnelModalView(store: store).apexTheme()),
            AnyView(UpdateSheetView().apexTheme()),
            AnyView(AboutView().apexTheme()),
            AnyView(ShortcutsSheetView().apexTheme())
        ] {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.subviews.count, 0)
        }
    }
}
