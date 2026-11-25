import XCTest
import AppKit
import SwiftUI
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI

@MainActor
final class SidebarCloneAndPinnedMonitorTests: XCTestCase {

    // MARK: - 1. Sidebar Context Menu Cleanup

    func testSidebarContextMenuKeepsOnlyCopySessionInfoAndCloneSession() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/Sidebar/SidebarView.swift"),
            encoding: .utf8
        )

        let menuStart = try XCTUnwrap(sidebarSource.range(of: ".contextMenu {"))
        let menuEnd = try XCTUnwrap(
            sidebarSource.range(of: "label: {", range: menuStart.upperBound..<sidebarSource.endIndex),
            "Expected DisclosureGroup label block after SessionRow contextMenu"
        )
        let menuBlock = String(sidebarSource[menuStart.lowerBound..<menuEnd.lowerBound])

        XCTAssertTrue(menuBlock.contains("L10n.copySessionInfoAction"), "Context menu must keep 复制会话信息")
        XCTAssertTrue(menuBlock.contains("L10n.cloneSessionAction"), "Context menu must offer 克隆会话...")
        XCTAssertEqual(L10n.copySessionInfoAction, "复制会话信息")
        XCTAssertEqual(L10n.cloneSessionAction, "克隆会话...")

        XCTAssertFalse(menuBlock.contains("L10n.copyUsernameAction"), "Context menu must remove 复制用户名")
        XCTAssertFalse(menuBlock.contains("L10n.copyPasswordAction"), "Context menu must remove 复制密码")
        XCTAssertFalse(menuBlock.contains("L10n.copyUsernameAndPasswordAction"), "Context menu must remove 复制用户名密码")
        XCTAssertFalse(menuBlock.contains("L10n.duplicateSessionAction"), "Context menu must replace 复制会话 with 克隆会话...")
        XCTAssertTrue(sidebarSource.contains("SessionEditModal(session: sourceSession, isCloning: true)"),
                      "Sidebar clone action must open SessionEditModal in clone mode")
    }

    // MARK: - 2. Clone Mode Display Name & Jump Host Candidates

    func testSessionEditModalCloneDisplayNameAndJumpHostCandidates() {
        let named = Session(name: "10.8.8.71", host: "10.8.8.71", username: "root")
        XCTAssertEqual(SessionEditModal.initialDisplayName(for: named, isCloning: true), "10.8.8.71 (副本)")
        XCTAssertEqual(SessionEditModal.initialDisplayName(for: named, isCloning: false), "10.8.8.71")

        let blankName = Session(name: "   ", host: "10.8.8.72", username: "ops")
        XCTAssertEqual(SessionEditModal.initialDisplayName(for: blankName, isCloning: true), "10.8.8.72 (副本)")
        XCTAssertEqual(SessionEditModal.initialDisplayName(for: nil, isCloning: true), "")

        let bastion = Session(name: "Bastion", host: "10.0.0.1", username: "jump")
        let all = [named, bastion, Session.local()]

        let cloneCandidates = SessionEditModal.jumpHostCandidates(from: all, excluding: nil)
        XCTAssertEqual(Set(cloneCandidates.map(\.id)), Set([named.id, bastion.id]),
                       "Clone mode should allow selecting the original remote session as a jump host")

        let editCandidates = SessionEditModal.jumpHostCandidates(from: all, excluding: named.id)
        XCTAssertEqual(editCandidates.map(\.id), [bastion.id],
                       "Edit mode must exclude the session itself from jump host candidates")
    }

    // MARK: - 3. Clone Mode Keychain Secret Isolation

    func testSessionEditModalCloneAuthMethodIsolatesKeychainSecrets() throws {
        let oldId = UUID()
        let newId = UUID()
        let oldPassRef = "ssh_\(oldId.uuidString)"
        let oldPhraseRef = "passphrase_\(oldId.uuidString)"

        var mockKeychain: [String: String] = [
            oldPassRef: "original-password-123",
            oldPhraseRef: "original-passphrase-456"
        ]
        let reader: (String) -> String? = { mockKeychain[$0] }
        let writer: (String, String) throws -> String = { key, secret in
            mockKeychain[key] = secret
            return key
        }

        // 1. Password session with explicit edited password writes to new session's Keychain ref
        let typedPassMethod = try SessionEditModal.cloneAuthMethodForSave(
            authType: .password,
            sessionId: newId,
            typedPassword: "new-cloned-password",
            typedPassphrase: "",
            privateKeyPath: "",
            certificatePath: "",
            sourceAuthMethod: .password(keychainRef: oldPassRef),
            didFinishLoadingSecret: true,
            didFinishLoadingPassphrase: true,
            secretReader: reader,
            secretWriter: writer
        )
        XCTAssertEqual(typedPassMethod, .password(keychainRef: "ssh_\(newId.uuidString)"))
        XCTAssertEqual(mockKeychain["ssh_\(newId.uuidString)"], "new-cloned-password")
        XCTAssertEqual(mockKeychain[oldPassRef], "original-password-123", "Original session secret must not be modified")

        // 2. Password session saved quickly before async load completes copies original Keychain secret
        let newFastId = UUID()
        let fastSavePassMethod = try SessionEditModal.cloneAuthMethodForSave(
            authType: .password,
            sessionId: newFastId,
            typedPassword: "",
            typedPassphrase: "",
            privateKeyPath: "",
            certificatePath: "",
            sourceAuthMethod: .password(keychainRef: oldPassRef),
            didFinishLoadingSecret: false,
            didFinishLoadingPassphrase: true,
            secretReader: reader,
            secretWriter: writer
        )
        XCTAssertEqual(fastSavePassMethod, .password(keychainRef: "ssh_\(newFastId.uuidString)"))
        XCTAssertEqual(mockKeychain["ssh_\(newFastId.uuidString)"], "original-password-123")

        // 3. Legacy inline password saved before async load completes migrates cleanly into new Keychain ref
        let legacyCloneId = UUID()
        let legacyMethod = try SessionEditModal.cloneAuthMethodForSave(
            authType: .password,
            sessionId: legacyCloneId,
            typedPassword: "",
            typedPassphrase: "",
            privateKeyPath: "",
            certificatePath: "",
            sourceAuthMethod: .password(keychainRef: "raw-legacy-secret"),
            didFinishLoadingSecret: false,
            didFinishLoadingPassphrase: true,
            secretReader: { _ in nil },
            secretWriter: writer
        )
        XCTAssertEqual(legacyMethod, .password(keychainRef: "ssh_\(legacyCloneId.uuidString)"))
        XCTAssertEqual(mockKeychain["ssh_\(legacyCloneId.uuidString)"], "raw-legacy-secret")

        // 4. Intentionally clearing password after load does NOT resurrect the original secret
        let clearedCloneId = UUID()
        let clearedPassMethod = try SessionEditModal.cloneAuthMethodForSave(
            authType: .password,
            sessionId: clearedCloneId,
            typedPassword: "",
            typedPassphrase: "",
            privateKeyPath: "",
            certificatePath: "",
            sourceAuthMethod: .password(keychainRef: oldPassRef),
            didFinishLoadingSecret: true,
            didFinishLoadingPassphrase: true,
            secretReader: reader,
            secretWriter: writer
        )
        XCTAssertEqual(clearedPassMethod, .password(keychainRef: ""))
        XCTAssertNil(mockKeychain["ssh_\(clearedCloneId.uuidString)"])

        // 5. PrivateKey session isolates passphrase on fast-save and respects clearing after load
        let keyFastId = UUID()
        let keyFastMethod = try SessionEditModal.cloneAuthMethodForSave(
            authType: .privateKey,
            sessionId: keyFastId,
            typedPassword: "",
            typedPassphrase: "",
            privateKeyPath: " ~/.ssh/id_ed25519 ",
            certificatePath: "",
            sourceAuthMethod: .privateKey(keychainRef: "~/.ssh/id_ed25519", passphraseRef: oldPhraseRef),
            didFinishLoadingSecret: true,
            didFinishLoadingPassphrase: false,
            secretReader: reader,
            secretWriter: writer
        )
        XCTAssertEqual(keyFastMethod, .privateKey(keychainRef: "~/.ssh/id_ed25519", passphraseRef: "passphrase_\(keyFastId.uuidString)"))
        XCTAssertEqual(mockKeychain["passphrase_\(keyFastId.uuidString)"], "original-passphrase-456")

        let keyClearedId = UUID()
        let keyClearedMethod = try SessionEditModal.cloneAuthMethodForSave(
            authType: .privateKey,
            sessionId: keyClearedId,
            typedPassword: "",
            typedPassphrase: "",
            privateKeyPath: "~/.ssh/id_ed25519",
            certificatePath: "",
            sourceAuthMethod: .privateKey(keychainRef: "~/.ssh/id_ed25519", passphraseRef: oldPhraseRef),
            didFinishLoadingSecret: true,
            didFinishLoadingPassphrase: true,
            secretReader: reader,
            secretWriter: writer
        )
        XCTAssertEqual(keyClearedMethod, .privateKey(keychainRef: "~/.ssh/id_ed25519", passphraseRef: nil))

        // 6. Certificate session preserves key/cert paths and isolates passphrase
        let certCloneId = UUID()
        let certMethod = try SessionEditModal.cloneAuthMethodForSave(
            authType: .certificate,
            sessionId: certCloneId,
            typedPassword: "",
            typedPassphrase: "cert-new-passphrase",
            privateKeyPath: " /keys/id_ed25519 ",
            certificatePath: " /keys/id_ed25519-cert.pub ",
            sourceAuthMethod: .certificate(keychainRef: "/keys/id_ed25519", certificatePath: "/keys/id_ed25519-cert.pub", passphraseRef: oldPhraseRef),
            didFinishLoadingSecret: true,
            didFinishLoadingPassphrase: true,
            secretReader: reader,
            secretWriter: writer
        )
        XCTAssertEqual(
            certMethod,
            .certificate(
                keychainRef: "/keys/id_ed25519",
                certificatePath: "/keys/id_ed25519-cert.pub",
                passphraseRef: "passphrase_\(certCloneId.uuidString)"
            )
        )
        XCTAssertEqual(mockKeychain["passphrase_\(certCloneId.uuidString)"], "cert-new-passphrase")

        // 7. Agent auth stays .agent
        let agentMethod = try SessionEditModal.cloneAuthMethodForSave(
            authType: .agent,
            sessionId: UUID(),
            typedPassword: "",
            typedPassphrase: "",
            privateKeyPath: "",
            certificatePath: "",
            sourceAuthMethod: .agent,
            didFinishLoadingSecret: true,
            didFinishLoadingPassphrase: true,
            secretReader: reader,
            secretWriter: writer
        )
        XCTAssertEqual(agentMethod, .agent)
    }

    // MARK: - 4. Clone Modal Layout Render

    func testSessionEditModalCloneModeRendersCleanly() {
        let source = Session(
            name: "Prod App",
            host: "10.8.8.71",
            port: 2222,
            username: "deploy",
            authMethod: .agent,
            folder: "生产环境",
            tags: ["prod", "api"],
            forwardAgent: true,
            compression: true,
            proxyCommand: "nc -X 5 -x 127.0.0.1:1080 %h %p",
            initialWorkingDirectory: "/srv/app",
            startupCommand: "tmux attach || tmux new",
            environmentVariables: ["APP_ENV": "production"]
        )
        let modal = SessionEditModal(session: source, isCloning: true) { _ in }
        let host = NSHostingView(rootView: modal.apexTheme())
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 660)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.subviews.count, 0, "SessionEditModal in clone mode must lay out cleanly")
    }

    // MARK: - 5. Pinned Monitor Presentation State Machine & Persistence

    func testMetricsDetailPresentationStateTransitionsAndPersistence() throws {
        let suiteName = "MetricsPinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storageKey = "workspace.metricsPanelPinned"
        let presentation = MetricsDetailPresentation(defaults: defaults, storageKey: storageKey)

        // Initial state
        XCTAssertFalse(presentation.isPinned)
        XCTAssertFalse(presentation.isPresented)
        XCTAssertFalse(presentation.showsFloatingOverlay)
        XCTAssertFalse(presentation.showsDockedPanel)

        // Open floating overlay from toolbar
        presentation.toggleFromToolbar()
        XCTAssertTrue(presentation.isPresented)
        XCTAssertFalse(presentation.isPinned)
        XCTAssertTrue(presentation.showsFloatingOverlay)
        XCTAssertFalse(presentation.showsDockedPanel)

        // Switching tabs while unpinned closes floating overlay
        presentation.handleTabChanged()
        XCTAssertFalse(presentation.isPresented)
        XCTAssertFalse(presentation.showsFloatingOverlay)

        // Open floating again and pin to right dock
        presentation.toggleFromToolbar()
        XCTAssertTrue(presentation.showsFloatingOverlay)
        presentation.togglePin()
        XCTAssertTrue(presentation.isPinned)
        XCTAssertFalse(presentation.isPresented)
        XCTAssertTrue(presentation.showsDockedPanel)
        XCTAssertFalse(presentation.showsFloatingOverlay)
        XCTAssertTrue(defaults.bool(forKey: storageKey), "Pin state must persist in UserDefaults")

        // New instance restores persisted pinned state
        let restored = MetricsDetailPresentation(defaults: defaults, storageKey: storageKey)
        XCTAssertTrue(restored.isPinned)
        XCTAssertTrue(restored.showsDockedPanel)
        XCTAssertFalse(restored.showsFloatingOverlay)

        // Switching tabs while pinned keeps docked panel open
        restored.handleTabChanged()
        XCTAssertTrue(restored.isPinned)
        XCTAssertTrue(restored.showsDockedPanel)

        // Unpinning from docked panel switches back to floating card
        restored.togglePin()
        XCTAssertFalse(restored.isPinned)
        XCTAssertTrue(restored.isPresented)
        XCTAssertTrue(restored.showsFloatingOverlay)
        XCTAssertFalse(restored.showsDockedPanel)
        XCTAssertFalse(defaults.bool(forKey: storageKey))

        // Pin again, then clicking toolbar capsule unpins and closes
        restored.togglePin()
        XCTAssertTrue(restored.isPinned)
        restored.toggleFromToolbar()
        XCTAssertFalse(restored.isPinned)
        XCTAssertFalse(restored.isPresented)
        XCTAssertFalse(restored.showsDockedPanel)
        XCTAssertFalse(restored.showsFloatingOverlay)

        // Pin again, then closing docked panel via close button unpins and closes
        restored.toggleFromToolbar()
        restored.togglePin()
        XCTAssertTrue(restored.showsDockedPanel)
        restored.closeDocked()
        XCTAssertFalse(restored.isPinned)
        XCTAssertFalse(restored.isPresented)
        XCTAssertFalse(restored.showsDockedPanel)
        XCTAssertFalse(defaults.bool(forKey: storageKey))
    }

    // MARK: - 6. Docked Metrics Width Clamping Across Window Sizes

    func testDockedMetricsWidthClampingAcrossWindowSizes() {
        // Wide window (1140pt) enforces [310, 480] bounds
        XCTAssertEqual(WorkspaceMainAreaWithMetricsDock.clampedDockedWidth(preferred: 200, availableTotalWidth: 1140), 310)
        XCTAssertEqual(WorkspaceMainAreaWithMetricsDock.clampedDockedWidth(preferred: 372, availableTotalWidth: 1140), 372)
        XCTAssertEqual(WorkspaceMainAreaWithMetricsDock.clampedDockedWidth(preferred: 600, availableTotalWidth: 1140), 480)

        // Medium window (740pt): maxAllowed = 740 - 240 - 8 = 492 -> capped at 480
        XCTAssertEqual(WorkspaceMainAreaWithMetricsDock.clampedDockedWidth(preferred: 372, availableTotalWidth: 740), 372)
        XCTAssertEqual(WorkspaceMainAreaWithMetricsDock.clampedDockedWidth(preferred: 520, availableTotalWidth: 740), 480)

        // Tighter split window (560pt): maxAllowed = 560 - 240 - 8 = 312 -> leaves >= 240pt for terminal
        let tightWidth = WorkspaceMainAreaWithMetricsDock.clampedDockedWidth(preferred: 372, availableTotalWidth: 560)
        XCTAssertEqual(tightWidth, 312)
        XCTAssertGreaterThanOrEqual(560 - 8 - tightWidth, WorkspaceMainAreaWithMetricsDock.minTerminalWidthAlongsideDockedMetrics)

        // Half-screen compact detail area (400pt): keeps panel <= 48% and terminal > 50%
        let compactWidth = WorkspaceMainAreaWithMetricsDock.clampedDockedWidth(preferred: 372, availableTotalWidth: 400)
        XCTAssertEqual(compactWidth, 188)
        XCTAssertGreaterThan(400 - 8 - compactWidth, compactWidth)

        // Zero-size initial layout pass safely clamps to 0
        XCTAssertEqual(WorkspaceMainAreaWithMetricsDock.clampedDockedWidth(preferred: 372, availableTotalWidth: 0), 0)
    }

    // MARK: - 7. Pinned & Unpinned Metric Views Layout Verification

    func testPinnedAndUnpinnedMetricViewsRenderCleanly() throws {
        let history = ObservableMetricsHistory()
        history.append(
            ServerMetricsSnapshot(
                cpuUsagePercent: 12.2,
                cpuCores: 160,
                cpuModel: "Intel(R) Xeon(R) Gold @ 2.10GHz",
                memoryTotalBytes: 377 * 1024 * 1024 * 1024,
                memoryUsedBytes: 299 * 1024 * 1024 * 1024,
                swapTotalBytes: 0,
                swapUsedBytes: 0,
                networkRxBytesPerSec: 42_000,
                networkTxBytesPerSec: 570_200,
                diskTotalBytes: 1_885_000_000_000,
                diskUsedBytes: 1_269_000_000_000,
                diskType: "SSD",
                isSSD: true,
                loadAvg1m: 20.97,
                loadAvg5m: 20.92,
                loadAvg15m: 24.32,
                uptimeSeconds: 7 * 86400 + 17 * 3600,
                topProcesses: [
                    ProcessMetricItem(pid: 431482, user: "root", cpuPercent: 1254.0, memPercent: 3.2, command: "java"),
                    ProcessMetricItem(pid: 84033, user: "root", cpuPercent: 800.0, memPercent: 0.0, command: "ps")
                ]
            )
        )

        for pinned in [false, true] {
            let capsule = MetricCapsuleView(
                historyStore: history,
                compact: true,
                monitoringEnabled: true,
                connectionActive: true,
                connectionConnecting: false,
                isPinned: pinned,
                onToggleDetail: {}
            )
            let capsuleHost = NSHostingView(rootView: capsule.apexTheme())
            capsuleHost.frame = NSRect(x: 0, y: 0, width: 200, height: 32)
            capsuleHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(capsuleHost.subviews.count, 0)

            let detail = MetricDetailView(
                historyStore: history,
                monitoringEnabled: true,
                connectionActive: true,
                connectionConnecting: false,
                isPinned: pinned,
                sessionLabel: "10.8.8.71",
                onTogglePin: {},
                onDismiss: {}
            )
            let detailHost = NSHostingView(rootView: detail.apexTheme())
            detailHost.frame = NSRect(x: 0, y: 0, width: pinned ? 372 : 416, height: 520)
            detailHost.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(detailHost.subviews.count, 0)
        }

        // Docked workspace split render using isolated presentation state
        let suiteName = "MetricsDockRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "workspace.metricsPanelPinned")

        let presentation = MetricsDetailPresentation(defaults: defaults, storageKey: "workspace.metricsPanelPinned")
        let store = SessionStore()
        let local = Session.local()
        store.sessions = [local]
        let client = SSHClientFactory.makeClient(for: local)
        let tab = TerminalTabItem(session: local, sshClient: client)

        let dockedWorkspace = WorkspaceMainAreaWithMetricsDock(
            store: store,
            tab: tab,
            activeTabs: [tab],
            isBroadcastActive: false,
            isSFTPVisible: .constant(true),
            splitRatio: .constant(0.7),
            splitDragStartRatio: .constant(nil),
            metricsPresentation: presentation,
            metricsDockWidth: .constant(372),
            metricsDockDragStartWidth: .constant(nil),
            transferPresentation: TransferDrawerPresentation()
        )
        let dockedHost = NSHostingView(rootView: dockedWorkspace.apexTheme())
        dockedHost.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
        dockedHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(dockedHost.subviews.count, 0, "Docked metrics workspace layout must render cleanly")
    }

    // MARK: - 8. Unpinned Floating Overlay Sizing, Charts & Header Regression

    func testUnpinnedMetricsDetailOverlayWrapsContentWithoutDeadSpaceAndRendersChartsCleanly() throws {
        let baseDate = Date(timeIntervalSince1970: 1_795_606_960)
        let history = ObservableMetricsHistory()
        let rxSamples: [Double] = [18_000, 22_000, 25_000, 32_000, 910_000, 258_100]
        let txSamples: [Double] = [8_000, 12_000, 14_000, 19_000, 860_000, 248_300]
        let cpuSamples: [Double] = [1.5, 4.2, 6.8, 5.1, 7.4, 3.8]
        for idx in 0..<6 {
            history.append(
                ServerMetricsSnapshot(
                    timestamp: baseDate.addingTimeInterval(Double(idx * 2)),
                    cpuUsagePercent: cpuSamples[idx],
                    cpuCores: 2,
                    cpuModel: "AMD EPYC 7K62 48-Core Processor",
                    memoryTotalBytes: 2 * 1024 * 1024 * 1024,
                    memoryUsedBytes: UInt64(0.9 * 1024 * 1024 * 1024),
                    swapTotalBytes: UInt64(1.9 * 1024 * 1024 * 1024),
                    swapUsedBytes: UInt64(0.8 * 1024 * 1024 * 1024),
                    networkRxBytesPerSec: rxSamples[idx],
                    networkTxBytesPerSec: txSamples[idx],
                    diskTotalBytes: 53_000_000_000,
                    diskUsedBytes: 13_000_000_000,
                    diskType: "HDD",
                    isSSD: false,
                    loadAvg1m: 0.02,
                    loadAvg5m: 0.07,
                    loadAvg15m: 0.08,
                    uptimeSeconds: 83 * 86400 + 4 * 3600,
                    topProcesses: [
                        ProcessMetricItem(pid: 3_716_888, user: "root", cpuPercent: 1.0, memPercent: 3.4, command: "YDService"),
                        ProcessMetricItem(pid: 1_176_924, user: "root", cpuPercent: 1.0, memPercent: 0.8, command: "barad_agent"),
                        ProcessMetricItem(pid: 2_589_252, user: "root", cpuPercent: 0.6, memPercent: 1.0, command: "xray-real")
                    ]
                )
            )
        }

        // 1. Measure intrinsic MetricDetailView fitting height at unpinned width 416pt
        let detail = MetricDetailView(
            historyStore: history,
            monitoringEnabled: true,
            connectionActive: true,
            connectionConnecting: false,
            isPinned: false,
            sessionLabel: "10.8.8.71",
            onTogglePin: {},
            onDismiss: {}
        )
        let detailMeasureHost = NSHostingView(rootView: detail.fixedSize(horizontal: false, vertical: true).frame(width: 416).apexTheme())
        detailMeasureHost.frame = NSRect(x: 0, y: 0, width: 416, height: 900)
        detailMeasureHost.layoutSubtreeIfNeeded()
        let intrinsicHeight = detailMeasureHost.fittingSize.height
        XCTAssertGreaterThan(intrinsicHeight, 320)
        XCTAssertLessThan(intrinsicHeight, 620, "Unpinned MetricDetailView intrinsic height should stay compact instead of stretching")

        // 2. Mount full MetricsDetailOverlay in a 1100x900 container (maxCardHeight = 848pt)
        let suiteName = "MetricsOverlaySizeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let presentation = MetricsDetailPresentation(defaults: defaults, storageKey: "workspace.metricsPanelPinned")
        presentation.toggleFromToolbar()
        XCTAssertTrue(presentation.showsFloatingOverlay)

        let session = Session(name: "10.8.8.71", host: "10.8.8.71", username: "root")
        let client = SSHClientFactory.makeClient(for: session)
        let tab = TerminalTabItem(session: session, sshClient: client)
        let pane = try XCTUnwrap(tab.panes.first)
        pane.connectionState = .connected

        let overlay = MetricsDetailOverlay(
            presentation: presentation,
            tab: tab,
            pane: pane,
            historyStore: history,
            monitoringEnabled: true,
            containerSize: CGSize(width: 1100, height: 900)
        )
        let overlayHost = NSHostingView(rootView: overlay.frame(width: 1100, height: 900).apexTheme())
        overlayHost.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
        overlayHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(overlayHost.subviews.count, 0)

        // Verify the rendered overlay border/background view frame does not stretch to maxCardHeight (848pt)
        func collectSubframes(in view: NSView) -> [NSRect] {
            var rects: [NSRect] = []
            for sub in view.subviews {
                let converted = view.convert(sub.bounds, from: sub)
                rects.append(converted)
                rects.append(contentsOf: collectSubframes(in: sub))
            }
            return rects
        }
        let wideCardFrames = collectSubframes(in: overlayHost).filter {
            $0.width >= 400 && $0.width <= 430 && $0.height > 100 && $0.height < 890
        }
        if let maxRenderedCardHeight = wideCardFrames.map(\.height).max() {
            XCTAssertLessThan(
                maxRenderedCardHeight,
                640,
                "Floating card should wrap its intrinsic content height instead of stretching toward maxCardHeight (848pt)"
            )
        }

        // 3. Compact window height (1100x340 -> maxCardHeight = 288pt) falls back cleanly to ScrollView
        let compactOverlay = MetricsDetailOverlay(
            presentation: presentation,
            tab: tab,
            pane: pane,
            historyStore: history,
            monitoringEnabled: true,
            containerSize: CGSize(width: 1100, height: 340)
        )
        let compactHost = NSHostingView(rootView: compactOverlay.frame(width: 1100, height: 340).apexTheme())
        compactHost.frame = NSRect(x: 0, y: 0, width: 1100, height: 340)
        compactHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(compactHost.subviews.count, 0)

        // 4. Verify source invariants so regressions are caught at build/test time
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/Workspace/WorkspaceView.swift"),
            encoding: .utf8
        )
        let metricSource = try String(
            contentsOf: root.appendingPathComponent("Sources/ApexUI/Dashboard/MetricCapsuleView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(workspaceSource.contains("let needsScroll = measuredContentHeight > maxCardHeight"))
        XCTAssertTrue(metricSource.contains("stacking: .unstacked"))
        XCTAssertTrue(metricSource.contains(".interpolationMethod(.monotone)"))
        XCTAssertFalse(metricSource.contains(".interpolationMethod(.catmullRom)"))
        XCTAssertTrue(metricSource.contains(".chartPlotStyle"))
        XCTAssertTrue(metricSource.contains("AxisValueLabel(anchor: anchor)"))

        // 5. Optional offscreen PNG dump when APEX_DUMP_METRICS_SNAPSHOT_DIR is set
        if let dumpDir = ProcessInfo.processInfo.environment["APEX_DUMP_METRICS_SNAPSHOT_DIR"], !dumpDir.isEmpty {
            let dirURL = URL(fileURLWithPath: dumpDir)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

            let prevPreset = AppSettings.shared.themePreset
            let prevFollow = AppSettings.shared.followsSystemAppearance
            defer {
                AppSettings.shared.themePreset = prevPreset
                AppSettings.shared.followsSystemAppearance = prevFollow
            }
            AppSettings.shared.followsSystemAppearance = false

            for (name, preset) in [("light", TerminalThemePreset.nativeLight), ("modern", TerminalThemePreset.modern)] {
                AppSettings.shared.themePreset = preset
                let snapOverlay = MetricsDetailOverlay(
                    presentation: presentation,
                    tab: tab,
                    pane: pane,
                    historyStore: history,
                    monitoringEnabled: true,
                    containerSize: CGSize(width: 460, height: 760)
                )
                let snapContainer = snapOverlay
                    .frame(width: 460, height: 760, alignment: .topTrailing)
                    .background(preset == .nativeLight ? Color(white: 0.94) : Color(red: 0.11, green: 0.12, blue: 0.15))
                    .apexTheme()
                let host = NSHostingView(rootView: snapContainer)
                host.appearance = NSAppearance(named: preset == .nativeLight ? .aqua : .darkAqua)
                host.frame = NSRect(x: 0, y: 0, width: 460, height: 760)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try png.write(to: dirURL.appendingPathComponent("metrics_overlay_\(name).png"))
                    }
                }
            }
        }
    }
}
