import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal
@testable import ApexUI
import AppKit
import SwiftUI
import os

/// Regression coverage for the v1.14.2 full code review (TC-REV-01 ~ TC-REV-20).
final class CodeReviewRegressionTests: XCTestCase {
    private var tempDir: URL!
    private let sandboxHome = FileManager.default.temporaryDirectory.appendingPathComponent("apex-review-store-" + UUID().uuidString)

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("CodeReview_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: sandboxHome)
        super.tearDown()
    }

    private var bridge: URL {
        Bundle(for: CodeReviewRegressionTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ApexSSHBridge")
    }

    private func certSession(passphraseRef: String? = "passphrase_ref") -> Session {
        Session(name: "ca", host: "bastion.example.test", username: "qa",
                authMethod: .certificate(keychainRef: "/keys/id_ed25519", certificatePath: "/keys/id_ed25519-cert.pub", passphraseRef: passphraseRef))
    }

    // MARK: - TC-REV-01: Certificate sessions answer the key passphrase prompt, not the password prompt
    func testCertificateSessionUsesPassphraseAuthenticationKind() throws {
        let client = NativeSSHSession(session: certSession(), distributionChannel: .appStore,
                                      bridgeExecutableURL: bridge, sandboxHomeURL: sandboxHome)
        XCTAssertTrue(client.usesKeyPassphrase)
        let command = try XCTUnwrap(client.prepareStoreCommand(binaryPath: "/usr/bin/ssh", arguments: ["example.test"],
                                                               accesses: [], authenticationSecret: "non-credential fixture"))
        defer { command.grants.close() }
        XCTAssertEqual(try ChildProcessFileGrants.read(from: command.grants.fileURL).authentication?.kind, .passphrase)

        let passwordClient = NativeSSHSession(session: Session(name: "pw", host: "h", username: "u", authMethod: .password(keychainRef: "x")))
        XCTAssertFalse(passwordClient.usesKeyPassphrase)
    }

    // MARK: - TC-REV-02: sshpass matches the passphrase prompt for key-based sessions
    func testSSHPassArgumentsMatchPassphrasePromptForKeySessions() {
        let certClient = NativeSSHSession(session: certSession())
        XCTAssertEqual(certClient.sshpassArguments(secret: "s", tool: "/usr/bin/ssh"), ["-p", "s", "-P", "passphrase", "/usr/bin/ssh"])

        let keyClient = NativeSSHSession(session: Session(name: "k", host: "h", username: "u",
                                                          authMethod: .privateKey(keychainRef: "/k", passphraseRef: "r")))
        XCTAssertEqual(keyClient.sshpassArguments(secret: "s", tool: "/usr/bin/scp"), ["-p", "s", "-P", "passphrase", "/usr/bin/scp"])

        let pwClient = NativeSSHSession(session: Session(name: "p", host: "h", username: "u", authMethod: .password(keychainRef: "r")))
        XCTAssertEqual(pwClient.sshpassArguments(secret: "s", tool: "/usr/bin/ssh"), ["-p", "s", "/usr/bin/ssh"])
    }

    // MARK: - TC-REV-03: Store bridge still parses sshpass commands carrying a passphrase prompt
    func testStoreCommandParsesSSHPassPromptOption() throws {
        let client = NativeSSHSession(session: certSession(), distributionChannel: .appStore,
                                      bridgeExecutableURL: bridge, sandboxHomeURL: sandboxHome)
        guard let sshpass = client.sshpassExecutablePath else {
            throw XCTSkip("store builds only use the sshpass bundled inside the app")
        }
        let secret = "non-credential fixture"
        let args = client.sshpassArguments(secret: secret, tool: "/usr/bin/ssh") + ["-p", "22", "qa@example.test"]
        let command = try XCTUnwrap(client.prepareStoreCommand(binaryPath: sshpass, arguments: args, accesses: []))
        defer { command.grants.close() }
        XCTAssertEqual(Array(command.arguments.prefix(2)), ["--tool", "ssh"])
        XCTAssertFalse(command.arguments.contains(secret), "secret must travel through askpass, never argv")
        XCTAssertFalse(command.arguments.contains("passphrase"))
        XCTAssertEqual(Array(command.arguments.suffix(3)), ["-p", "22", "qa@example.test"])
        XCTAssertEqual(try ChildProcessFileGrants.read(from: command.grants.fileURL).authentication?.kind, .passphrase)
    }

    // MARK: - TC-REV-04: Tunnel credential resolution covers certificate passphrases and legacy passwords
    func testTunnelSecretResolution() async {
        let store: [String: String] = ["passphrase_ref": "cert-pass", "ssh_ok": "login-pass"]
        let lookup: @Sendable (String) async -> String? = { store[$0] }

        let certSecret = await SSHTunnelManager.resolveSecret(for: certSession(), lookup: lookup)
        XCTAssertEqual(certSecret, "cert-pass")
        let noPassphrase = await SSHTunnelManager.resolveSecret(for: certSession(passphraseRef: nil), lookup: lookup)
        XCTAssertNil(noPassphrase)

        let pw = Session(name: "p", host: "h", username: "u", authMethod: .password(keychainRef: "ssh_ok"))
        let found = await SSHTunnelManager.resolveSecret(for: pw, lookup: lookup)
        XCTAssertEqual(found, "login-pass")

        let legacy = Session(name: "l", host: "h", username: "u", authMethod: .password(keychainRef: "inline-legacy"))
        let legacySecret = await SSHTunnelManager.resolveSecret(for: legacy, lookup: lookup)
        XCTAssertEqual(legacySecret, "inline-legacy")

        let managed = Session(name: "m", host: "h", username: "u", authMethod: .password(keychainRef: "ssh_\(UUID().uuidString)"))
        let managedSecret = await SSHTunnelManager.resolveSecret(for: managed, lookup: lookup)
        XCTAssertNil(managedSecret, "a missing managed keychain item must not be sent as the password")

        let agent = await SSHTunnelManager.resolveSecret(for: Session(name: "a", host: "h", username: "u"), lookup: lookup)
        XCTAssertNil(agent)
    }

    // MARK: - TC-REV-05: Tunnel sshpass prefix adapts to the authentication kind
    func testTunnelSSHPassArguments() {
        XCTAssertEqual(SSHTunnelManager.sshpassArguments(secret: "s", session: certSession()), ["-p", "s", "-P", "passphrase", "/usr/bin/ssh"])
        let pw = Session(name: "p", host: "h", username: "u", authMethod: .password(keychainRef: "r"))
        XCTAssertEqual(SSHTunnelManager.sshpassArguments(secret: "s", session: pw), ["-p", "s", "/usr/bin/ssh"])
    }

    // MARK: - TC-REV-06: Managed keychain reference detection
    func testManagedKeychainReferenceDetection() {
        let id = UUID().uuidString
        XCTAssertTrue(KeychainStore.isManagedReference("ssh_\(id)"))
        XCTAssertTrue(KeychainStore.isManagedReference("passphrase_\(id)"))
        XCTAssertFalse(KeychainStore.isManagedReference("ssh_not-a-uuid"))
        XCTAssertFalse(KeychainStore.isManagedReference("hunter2"))
        XCTAssertFalse(KeychainStore.isManagedReference(""))
    }

    // MARK: - TC-REV-07: SSH config follows OpenSSH first-value-wins and isolates Match blocks
    func testSSHConfigFirstValueWinsAndMatchIsolation() {
        let config = """
        Host web
            HostName 10.0.0.1
            User deploy
            Port 2200
            HostName 10.0.0.99
            Port 2299
            IdentityFile ~/.ssh/first
            IdentityFile ~/.ssh/second

        Match host web exec "true"
            User attacker
            Port 9999

        Host db
            HostName 10.0.0.2
        """
        let hosts = SSHConfigParser.parse(content: config)
        XCTAssertEqual(hosts.map(\.hostPattern), ["web", "db"])
        let web = hosts[0]
        XCTAssertEqual(web.hostName, "10.0.0.1")
        XCTAssertEqual(web.user, "deploy")
        XCTAssertEqual(web.port, 2200)
        XCTAssertEqual(web.identityFile, ("~/.ssh/first" as NSString).expandingTildeInPath)
        XCTAssertEqual(hosts[1].hostName, "10.0.0.2")
        XCTAssertEqual(hosts[1].port, 22)
    }

    // MARK: - TC-REV-08: CertificateFile without IdentityFile derives the paired private key
    func testCertificateOnlyConfigDerivesPrivateKey() {
        let hosts = SSHConfigParser.parse(content: """
        Host ca
            HostName ca.example.test
            CertificateFile /keys/id_ed25519-cert.pub
        """)
        let session = hosts[0].toSession()
        XCTAssertEqual(session.authMethod, .certificate(keychainRef: "/keys/id_ed25519", certificatePath: "/keys/id_ed25519-cert.pub", passphraseRef: nil))

        let odd = SSHConfigParser.parse(content: "Host odd\n  CertificateFile /keys/custom.crt\n")[0].toSession()
        XCTAssertEqual(odd.authMethod, .agent, "non-standard certificate names cannot be paired, fall back to agent")
    }

    // MARK: - TC-REV-09: Certificate discovery from a public key path
    func testCertificateDiscoveryFromPublicKeyPath() throws {
        let key = tempDir.appendingPathComponent("id_ed25519").path
        let cert = key + "-cert.pub"
        try Data("ssh-ed25519-cert-v01@openssh.com AAAA test".utf8).write(to: URL(fileURLWithPath: cert))
        XCTAssertEqual(SSHCertificateHelper.discoverCertificate(forPrivateKeyPath: key), cert)
        XCTAssertEqual(SSHCertificateHelper.discoverCertificate(forPrivateKeyPath: key + ".pub"), cert)
        XCTAssertNil(SSHCertificateHelper.discoverCertificate(forPrivateKeyPath: tempDir.appendingPathComponent("missing").path))
    }

    // MARK: - TC-REV-10: Session editor validation, tags and jump host candidates
    @MainActor
    func testSessionEditorValidationTagsAndJumpHosts() {
        typealias Auth = SessionEditModal.AuthType
        XCTAssertNotNil(Auth.privateKey.validationMessage(privateKeyPath: "  ", certificatePath: ""))
        XCTAssertNil(Auth.privateKey.validationMessage(privateKeyPath: "~/.ssh/id_ed25519", certificatePath: ""))
        XCTAssertNotNil(Auth.certificate.validationMessage(privateKeyPath: "", certificatePath: "/c-cert.pub"))
        XCTAssertNotNil(Auth.certificate.validationMessage(privateKeyPath: "/k", certificatePath: " "))
        XCTAssertNil(Auth.certificate.validationMessage(privateKeyPath: "/k", certificatePath: "/k-cert.pub"))
        XCTAssertNil(Auth.password.validationMessage(privateKeyPath: "", certificatePath: ""))
        XCTAssertNil(Auth.agent.validationMessage(privateKeyPath: "", certificatePath: ""))

        XCTAssertEqual(SessionEditModal.parseTags("prod, ,web，db,prod,"), ["prod", "web", "db"])
        XCTAssertEqual(SessionEditModal.parseTags("   "), [])

        let current = Session(name: "self", host: "a", username: "u")
        let remote = Session(name: "bastion", host: "b", username: "u")
        let candidates = SessionEditModal.jumpHostCandidates(from: [current, remote, Session.local()], excluding: current.id)
        XCTAssertEqual(candidates.map(\.id), [remote.id])
    }

    // MARK: - TC-REV-11: Sidebar groups padded/blank folders and hides empty groups while searching
    @MainActor
    func testSidebarFolderNormalizationAndSearch() {
        let padded = Session(name: "api", host: "10.0.0.1", username: "u", folder: "  Prod  ")
        let blank = Session(name: "misc", host: "10.0.0.2", username: "u", folder: "")
        let none = Session(name: "box", host: "10.0.0.3", username: "u", folder: nil, tags: ["edge"])
        let all = [padded, blank, none]

        XCTAssertEqual(SidebarView.folderNames(sessions: all, extraFolders: ["Empty"], searchFilter: ""),
                       ["Empty", "Prod", L10n.generalFolder].sorted())
        XCTAssertEqual(SidebarView.sessions(in: "Prod", from: all, searchFilter: "").map(\.id), [padded.id])
        XCTAssertEqual(SidebarView.sessions(in: L10n.generalFolder, from: all, searchFilter: "").map(\.id), [blank.id, none.id])

        XCTAssertEqual(SidebarView.folderNames(sessions: all, extraFolders: ["Empty"], searchFilter: "edge"), [L10n.generalFolder])
        XCTAssertEqual(SidebarView.sessions(in: L10n.generalFolder, from: all, searchFilter: " edge ").map(\.id), [none.id])
    }

    // MARK: - TC-REV-12: Updater ranks a final release above its pre-release
    func testUpdaterPrereleaseOrdering() {
        XCTAssertTrue(UpdateManager.isVersion("1.15.0", higherThan: "1.15.0-beta.1"))
        XCTAssertFalse(UpdateManager.isVersion("1.15.0-beta.1", higherThan: "1.15.0"))
        XCTAssertFalse(UpdateManager.isVersion("1.15.0-rc.1", higherThan: "1.15.0-beta.1"))
        XCTAssertTrue(UpdateManager.isVersion("1.15.1-beta", higherThan: "1.15.0"))
        XCTAssertFalse(UpdateManager.isVersion("1.15.0", higherThan: "1.15.0"))
    }

    // MARK: - TC-REV-13: Icon-only buttons announce their purpose, not the SF Symbol description
    // SwiftUI does not populate its accessibility tree in a headless xctest process, so the live
    // behaviour is asserted by UI acceptance; this guard keeps the shared components wired up.
    func testIconButtonsExposeAccessibilityLabel() throws {
        let styleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ApexUI/ApexStyle.swift")
        let source = try String(contentsOf: styleURL, encoding: .utf8)
        for component in ["public struct ApexIconButton", "public struct ApexMenuTrigger"] {
            let start = try XCTUnwrap(source.range(of: component), component)
            let rest = source[start.upperBound...]
            let body = rest.range(of: "\npublic struct ").map { rest[..<$0.lowerBound] } ?? rest
            XCTAssertTrue(body.contains(".apexAccessibilityLabel(label)"), "\(component) must expose its label to accessibility")
        }
        XCTAssertTrue(source.contains("accessibilityLabel(label)"))
    }

    // MARK: - TC-REV-14: Settings window keeps all six toolbar tabs visible
    @MainActor
    func testSettingsWindowFitsAllToolbarTabs() {
        XCTAssertGreaterThanOrEqual(SettingsView.contentWidth, 700,
                                    "six toolbar tabs overflow into 'more toolbar items' below ~700pt")
    }

    // MARK: - TC-REV-15: Session editor offers existing groups and reuses their spelling
    @MainActor
    func testSessionEditorExistingFolderSelection() {
        let sessions = [
            Session(name: "a", host: "h1", username: "u", folder: " Prod "),
            Session(name: "b", host: "h2", username: "u", folder: "数据库"),
            Session(name: "c", host: "h3", username: "u", folder: nil),
            Session.local()
        ]
        let folders = SessionEditModal.existingFolders(sessions: sessions, extraFolders: ["空分组", "  "])
        XCTAssertEqual(folders, ["Prod", "数据库", "空分组", L10n.generalFolder].sorted())

        XCTAssertEqual(SessionEditModal.canonicalFolder("prod  ", existing: folders), "Prod")
        XCTAssertEqual(SessionEditModal.canonicalFolder("数据库", existing: folders), "数据库")
        XCTAssertEqual(SessionEditModal.canonicalFolder("  新分组 ", existing: folders), "新分组")
        XCTAssertEqual(SessionEditModal.canonicalFolder("   ", existing: folders), L10n.generalFolder)
    }

    // MARK: - TC-REV-16: Action buttons never animate their own position
    // A value-based `.animation(_:value: isEnabled)` animated the save button's frame when a sheet
    // populated its form during the first layout, so the button flew from center to bottom.
    func testActionButtonAnimationIsScopedToVisualModifiers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let style = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/ApexStyle.swift"), encoding: .utf8)
        let start = try XCTUnwrap(style.range(of: "public struct ApexActionButton"))
        let rest = style[start.upperBound...]
        let body = rest.range(of: "\npublic struct ").map { rest[..<$0.lowerBound] } ?? rest
        XCTAssertFalse(body.contains(".animation(ApexStyle.springSnappy, value:"),
                       "ApexActionButton must not use value-based implicit animations")
        XCTAssertTrue(body.contains(".animation(ApexStyle.springSnappy) { content in"))

        let modal = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Sidebar/SessionEditModal.swift"), encoding: .utf8)
        XCTAssertTrue(modal.contains("transaction.disablesAnimations = true"),
                      "Populating the session form must not animate the first layout")
    }

    // MARK: - TC-REV-17: Prominent buttons keep readable text in every theme
    // Pastel dark-theme accents (Everforest, Nord, Rosé Pine…) rendered white text at ~2:1.
    func testProminentButtonTextContrastAcrossThemes() throws {
        for preset in TerminalThemePreset.allCases {
            let accent = preset.palette.accent
            let readable = ThemePalette.readable(accent, on: ["#FFFFFF"])
            XCTAssertGreaterThanOrEqual(ThemePalette.contrast("#FFFFFF", readable), 4.5,
                                        "\(preset.rawValue) prominent fill must carry white text")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let style = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/ApexStyle.swift"), encoding: .utf8)
        XCTAssertTrue(style.contains("tint == ApexStyle.accent ? ApexStyle.buttonAccent : tint"))
        XCTAssertTrue(style.contains(".foregroundColor(isProminent ? prominentForeground : tint)"))
    }

    // MARK: - TC-REV-18: Tunnel editor fits its sheet and rejects out-of-range ports
    @MainActor
    func testTunnelEditorSegmentsAndPortValidation() {
        // Long "本地端口转发 (Local -L)" segments overflowed the 520pt sheet and clipped both edges.
        for type in SSHTunnelType.allCases {
            XCTAssertLessThanOrEqual(type.shortLabel.count, 10, type.rawValue)
        }
        let host = NSHostingView(rootView: Picker("类型", selection: .constant(SSHTunnelType.local)) {
            ForEach(SSHTunnelType.allCases) { Text($0.shortLabel).tag($0) }
        }.pickerStyle(.segmented).labelsHidden())
        XCTAssertLessThan(host.fittingSize.width, 472, "segments must fit the sheet's content width")

        let session = UUID()
        func draft(_ bind: String, _ target: String, _ type: SSHTunnelType = .local, name: String = "") -> SSHTunnel {
            AddOrEditTunnelSheet.makeDraft(id: UUID(), name: name, type: type, sessionId: session,
                                           bindHost: " 127.0.0.1 ", bindPort: bind, targetHost: " db ",
                                           targetPort: target, autoStart: false)
        }
        let ok = draft(" 3306 ", "3306 ", name: "  MySQL  ")
        XCTAssertEqual(ok.bindPort, 3306)
        XCTAssertEqual(ok.targetHost, "db")
        XCTAssertEqual(ok.name, "MySQL")
        XCTAssertNil(AddOrEditTunnelSheet.validationMessage(for: ok, bindPort: " 3306 ", targetPort: "3306 "))
        XCTAssertEqual(draft("8080", "80").name, "127.0.0.1:8080")

        XCTAssertNotNil(AddOrEditTunnelSheet.validationMessage(for: draft("0", "3306"), bindPort: "0", targetPort: "3306"))
        XCTAssertNotNil(AddOrEditTunnelSheet.validationMessage(for: draft("70000", "3306"), bindPort: "70000", targetPort: "3306"))
        XCTAssertNotNil(AddOrEditTunnelSheet.validationMessage(for: draft("3306", ""), bindPort: "3306", targetPort: ""))
        XCTAssertNil(AddOrEditTunnelSheet.validationMessage(for: draft("1080", "", .dynamic), bindPort: "1080", targetPort: ""),
                     "dynamic SOCKS tunnels have no target port")
    }

    // MARK: - TC-REV-19: Session editor keeps writing to the session's current keychain reference
    @MainActor
    func testSessionEditorSecretReferenceFollowsCurrentAccount() {
        let session = UUID()
        let moved = "ssh_\(UUID().uuidString)"
        XCTAssertEqual(SessionEditModal.secretReference(prefix: "ssh_", sessionId: session, existing: .password(keychainRef: moved)), moved,
                       "after an ownership conflict the session points at a fresh account; later edits must update it")
        XCTAssertEqual(SessionEditModal.secretReference(prefix: "ssh_", sessionId: session, existing: nil), "ssh_\(session.uuidString)")
        XCTAssertEqual(SessionEditModal.secretReference(prefix: "ssh_", sessionId: session, existing: .password(keychainRef: "legacy-inline")),
                       "ssh_\(session.uuidString)", "legacy inline passwords migrate to a managed account")
        let pass = "passphrase_\(UUID().uuidString)"
        XCTAssertEqual(SessionEditModal.secretReference(prefix: "passphrase_", sessionId: session,
                                                        existing: .certificate(keychainRef: "/k", certificatePath: "/c", passphraseRef: pass)), pass)
        XCTAssertEqual(SessionEditModal.secretReference(prefix: "passphrase_", sessionId: session, existing: .password(keychainRef: moved)),
                       "passphrase_\(session.uuidString)", "a password reference is never reused for a passphrase")
    }

    // MARK: - TC-REV-20: Tunnel manager header pins title left and actions right
    // Without a spacer the header HStack was centered, leaving 「新建隧道」 and close floating mid-sheet.
    func testTunnelManagerHeaderIsEdgeAligned() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Tunnel/SSHTunnelModalView.swift"), encoding: .utf8)
        let header = try XCTUnwrap(source.range(of: "// Header"))
        let divider = try XCTUnwrap(source.range(of: "Divider()", range: header.upperBound..<source.endIndex))
        let block = source[header.upperBound..<divider.lowerBound]
        XCTAssertTrue(block.contains("Spacer(minLength: ApexStyle.s4)"), "title and actions must be pushed to opposite edges")
        XCTAssertTrue(block.contains(".padding(.horizontal, ApexStyle.s4)"), "header inset must match the footer's ApexStyle.s4")
    }

    // MARK: - TC-REV-21: ProcessInspector executes kill signals out-of-band via executeCommand (never sendInput)
    @MainActor
    func testProcessInspectorKillSignalUsesExecuteCommandInsteadOfPTYInput() async {
        let session = Session(name: "ProcTest", host: "10.0.0.12", username: "ubuntu")
        let mock = MockSSHSession(session: session)
        try? await mock.connect()

        let worker = ProcessDetailItem(pid: 4321, user: "ubuntu", cpuPercent: 18.5, memPercent: 2.1, command: "python3")
        let feedback = await ProcessInspectorView.performKillSignal(to: worker, signal: .sigterm, client: mock)
        XCTAssertTrue(feedback.contains("已向 PID 4321"))
        XCTAssertEqual(mock.executedCommands, ["kill -15 4321 2>&1"], "Kill signal must run via out-of-band executeCommand")
        XCTAssertTrue(mock.sentInputs.isEmpty, "Kill signal must NEVER inject keystrokes into interactive PTY stdin")

        // Verify permission-denied error feedback from remote kill command
        mock.customExecuteCommandHandler = { _ in
            "bash: line 1: kill: (4321) - Operation not permitted"
        }
        let deniedFeedback = await ProcessInspectorView.performKillSignal(to: worker, signal: .sigkill, client: mock)
        XCTAssertTrue(deniedFeedback.contains("发送信号失败") || deniedFeedback.contains("Operation not permitted"))
    }

    // MARK: - TC-REV-22: TransferManager enforces maxConcurrentTransfers queue limit and cancelAllTasks
    @MainActor
    func testTransferManagerMaxConcurrentTransfersEnforcement() async throws {
        let manager = TransferManager(maxConcurrentTransfers: 2)
        let session = MockSSHSession(session: Session(name: "QueueTest", host: "127.0.0.1", username: "root"))

        let counters = OSAllocatedUnfairLock(initialState: (current: 0, maxObserved: 0))

        session.customUploadHandler = { _, _, progress in
            counters.withLock { state in
                state.current += 1
                if state.current > state.maxObserved {
                    state.maxObserved = state.current
                }
            }
            progress(0.5)
            try await Task.sleep(nanoseconds: 80_000_000)
            counters.withLock { state in
                state.current -= 1
            }
            progress(1.0)
        }

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("concurrency_\(UUID().uuidString).bin")
        try Data(repeating: 0x5A, count: 4096).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var expectations: [XCTestExpectation] = []
        for i in 0..<6 {
            let exp = expectation(description: "Upload \(i)")
            expectations.append(exp)
            manager.enqueueUpload(session: session, localURL: tempFile, remotePath: "/tmp/q_\(i).bin") {
                exp.fulfill()
            }
        }

        await fulfillment(of: expectations, timeout: 5.0)
        let maxObservedActive = counters.withLock { $0.maxObserved }
        XCTAssertLessThanOrEqual(maxObservedActive, 2, "Concurrent active uploads must never exceed maxConcurrentTransfers=2")
        XCTAssertEqual(maxObservedActive, 2, "Should utilize all 2 allowed concurrent slots")
        XCTAssertEqual(manager.activeCount, 0)
    }

    // MARK: - TC-REV-23: SFTPBatchTracker retains FileAccessLease until the last transfer finishes
    func testBatchTrackerRetainsResourcesUntilAllCompleted() {
        let tracker = SFTPBatchTracker(total: 3)
        let closedCounter = OSAllocatedUnfairLock(initialState: 0)
        tracker.addCompletionHandler {
            closedCounter.withLock { $0 += 1 }
        }

        let s1 = tracker.advance()
        XCTAssertEqual(s1.completed, 1)
        XCTAssertFalse(s1.isDone)
        XCTAssertEqual(closedCounter.withLock { $0 }, 0, "Lease must NOT close after 1st of 3 transfers")

        let s2 = tracker.advance()
        XCTAssertEqual(s2.completed, 2)
        XCTAssertFalse(s2.isDone)
        XCTAssertEqual(closedCounter.withLock { $0 }, 0, "Lease must NOT close after 2nd of 3 transfers")

        let s3 = tracker.advance()
        XCTAssertEqual(s3.completed, 3)
        XCTAssertTrue(s3.isDone)
        XCTAssertEqual(closedCounter.withLock { $0 }, 1, "Lease must close exactly once when all 3 transfers finish")
    }

    // MARK: - TC-REV-24: Upload real-time progress and Darwin vnode offset inspection
    @MainActor
    func testUploadRealTimeProgressAndVnodeOffsetInspection() async throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("vnode_progress_\(UUID().uuidString).bin")
        let payload = Data(repeating: 0x33, count: 120_000)
        try payload.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let fh = try FileHandle(forReadingFrom: tempFile)
        defer { try? fh.close() }
        _ = try fh.read(upToCount: 64_000)

        let sampledOffset = NativeSSHSession.currentUploadReadBytes(forPid: getpid(), targetURL: tempFile)
        XCTAssertEqual(sampledOffset, 64_000, "Kernel vnode fd inspection must report exact read offset of open local file")

        let manager = TransferManager()
        let session = MockSSHSession(session: Session(name: "UploadProg", host: "127.0.0.1", username: "root"))
        let exp = expectation(description: "Upload completed")
        var observedIntermediate = false

        session.customUploadHandler = { _, _, progress in
            for step in 1...4 {
                progress(Double(step) * 0.2)
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            progress(1.0)
        }

        let taskId = manager.enqueueUpload(session: session, localURL: tempFile, remotePath: "/tmp/up.bin") {
            exp.fulfill()
        }

        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 30_000_000)
            if let t = manager.tasks.first(where: { $0.id == taskId }),
               t.transferredBytes > 0 && t.transferredBytes < Int64(payload.count) {
                observedIntermediate = true
                break
            }
        }

        await fulfillment(of: [exp], timeout: 3.0)
        XCTAssertTrue(observedIntermediate, "Upload task must report intermediate transferredBytes before completion")
    }

    // MARK: - TC-REV-25: SFTPView showHiddenFiles synchronizes with AppSettings.shared.showHiddenFiles
    func testSFTPViewShowHiddenFilesWiresToAppSettings() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sftpSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/SFTP/SFTPView.swift"), encoding: .utf8)
        XCTAssertTrue(sftpSource.contains("@State private var showHiddenFiles = AppSettings.shared.showHiddenFiles"),
                      "SFTPView must initialize showHiddenFiles from AppSettings.shared.showHiddenFiles")
        XCTAssertTrue(sftpSource.contains(".onChange(of: themeSettings.showHiddenFiles)"),
                      "SFTPView must observe changes to AppSettings.shared.showHiddenFiles")
    }

    // MARK: - TC-REV-26: Enhanced keep-alive setting dynamically controls NativeSSHSession keep-alive
    func testEnhancedKeepAliveSettingControlsNativeSSHSession() {
        let suiteName = "com.apexterm.tests.keepalive.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(NativeSSHSession.isEnhancedKeepAliveEnabled(defaults: defaults), "Enhanced keep-alive must default to true")
        defaults.set(false, forKey: "settings.ssh.keepAliveEnhanced")
        XCTAssertFalse(NativeSSHSession.isEnhancedKeepAliveEnabled(defaults: defaults), "Disabling settings.ssh.keepAliveEnhanced must be respected")
        defaults.set(true, forKey: "settings.ssh.keepAliveEnhanced")
        XCTAssertTrue(NativeSSHSession.isEnhancedKeepAliveEnabled(defaults: defaults))
    }

    // MARK: - TC-REV-27: LocalTerminalSession synchronous termination and dynamic iCloudSyncManager appVersion
    @MainActor
    func testLocalTerminalTerminationAndDynamicCloudAppVersion() throws {
        let localSession = LocalTerminalSession()
        localSession.terminatePTYProcess()
        XCTAssertEqual(localSession.connectionState, .disconnected)

        let version = iCloudSyncManager.resolvedAppVersion
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotEqual(version, "1.12.0", "iCloudSyncManager must not hardcode stale 1.12.0 version")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexTerm/ApexTermApp.swift"), encoding: .utf8)
        XCTAssertTrue(appSource.contains("LocalTerminalSession)?.terminatePTYProcess()"),
                      "App termination must clean up LocalTerminalSession PTY processes")
        XCTAssertTrue(appSource.contains("TransferManager.shared.cancelAllTasks()"),
                      "App termination must cancel active SFTP transfers")
    }

    // MARK: - TC-REV-28: SSH Key Vault materialization and passphrase fallback for SSH & Tunnels
    @MainActor
    func testSSHKeyVaultMaterializationAndPassphraseFallback() async throws {
        let keyId = UUID()
        let privRef = "vault.priv.\(keyId.uuidString)"
        let passRef = "vault.pass.\(keyId.uuidString)"
        let fakePEM = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----"

        XCTAssertTrue(KeychainStore.isManagedReference(privRef))
        XCTAssertTrue(KeychainStore.isManagedReference(passRef))
        XCTAssertTrue(KeychainStore.isVaultPrivateKeyReference(privRef))
        XCTAssertEqual(KeychainStore.vaultPassphraseReference(forPrivateKeyRef: privRef), passRef)

        let tempVaultDir = FileManager.default.temporaryDirectory.appendingPathComponent("VaultMaterialize_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempVaultDir) }

        let materializedPath = SSHKeyVaultManager.materializePrivateKeyPath(
            for: privRef,
            directory: tempVaultDir,
            lookup: { ref in ref == privRef ? fakePEM : nil }
        )
        let unwrappedPath = try XCTUnwrap(materializedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrappedPath))

        let content = try String(contentsOfFile: unwrappedPath, encoding: .utf8)
        XCTAssertTrue(content.hasSuffix("\n"), "Materialized OpenSSH private key must end with a trailing newline")
        let attrs = try FileManager.default.attributesOfItem(atPath: unwrappedPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "Materialized private key file must have 0600 permissions")

        let session = Session(
            name: "VaultKeyHost",
            host: "10.0.0.10",
            username: "ubuntu",
            authMethod: .privateKey(keychainRef: privRef, passphraseRef: nil)
        )
        let secret = await SSHTunnelManager.resolveSecret(for: session) { ref in
            if ref == passRef { return "vault-key-passphrase-123" }
            return nil
        }
        XCTAssertEqual(secret, "vault-key-passphrase-123", "Vault key session without explicit passphraseRef must fall back to vault.pass.<UUID>")
    }

    // MARK: - TC-REV-29: Duplicating a session isolates Keychain secret references
    @MainActor
    func testDuplicateSessionIsolatesKeychainReferences() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DupSessionTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = SessionStore(baseDirectory: tempDir)

        let origId = UUID()
        let origRef = "ssh_\(origId.uuidString)"
        let original = Session(
            id: origId,
            name: "Prod DB",
            host: "10.0.1.5",
            username: "postgres",
            authMethod: .password(keychainRef: origRef)
        )
        store.addSession(original)

        var simulatedKeychain: [String: String] = [origRef: "origin-secret-pw"]
        let duplicate = store.duplicateSession(
            original,
            nameSuffix: " (副本)",
            secretCloner: { oldRef, newRef in
                if let val = simulatedKeychain[oldRef] {
                    simulatedKeychain[newRef] = val
                    return newRef
                }
                return newRef
            }
        )

        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.name, "Prod DB (副本)")
        guard case .password(let dupRef) = duplicate.authMethod else {
            return XCTFail("Expected password auth method on duplicated session")
        }
        XCTAssertNotEqual(dupRef, origRef, "Duplicated session must use its own dedicated Keychain reference")
        XCTAssertEqual(dupRef, "ssh_\(duplicate.id.uuidString)")
        XCTAssertEqual(simulatedKeychain[dupRef], "origin-secret-pw")
    }

    // MARK: - TC-REV-30: Deleting a session cleans up Keychain secrets, tunnels, and dangling jumpServerId
    @MainActor
    func testDeleteSessionCleansUpSecretsTunnelsAndJumpServerReferences() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteSessionTests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = SessionStore(baseDirectory: tempDir)
        let tunnelManager = SSHTunnelManager(baseDirectory: tempDir)

        let jumpId = UUID()
        let jumpRef = "ssh_\(jumpId.uuidString)"
        let jumpSession = Session(
            id: jumpId,
            name: "Bastion Host",
            host: "1.1.1.1",
            username: "jump",
            authMethod: .password(keychainRef: jumpRef)
        )
        let appSession = Session(
            name: "Inner App",
            host: "10.0.0.2",
            username: "app",
            authMethod: .agent,
            jumpServerId: jumpId
        )
        store.addSession(jumpSession)
        store.addSession(appSession)

        let tunnel = SSHTunnel(name: "Bastion SOCKS", type: .dynamic, sessionId: jumpId, bindPort: 11080)
        try tunnelManager.addTunnel(tunnel)
        XCTAssertEqual(tunnelManager.tunnels(for: jumpId).count, 1)

        var deletedKeys: [String] = []
        store.deleteSession(
            id: jumpId,
            tunnelManager: tunnelManager,
            secretDeleter: { key in deletedKeys.append(key) }
        )

        XCTAssertNil(store.sessions.first(where: { $0.id == jumpId }))
        XCTAssertTrue(deletedKeys.contains(jumpRef), "Deleting session must delete its managed Keychain secret")
        XCTAssertTrue(tunnelManager.tunnels(for: jumpId).isEmpty, "Deleting session must remove associated SSH tunnels")
        let remainingApp = try XCTUnwrap(store.sessions.first(where: { $0.id == appSession.id }))
        XCTAssertNil(remainingApp.jumpServerId, "Deleting jump host session must clear dangling jumpServerId on dependent sessions")
    }

    // MARK: - TC-REV-31: Snippet unresolvedVariables detection for interactive parameter prompting
    func testSnippetUnresolvedVariablesDetection() throws {
        let dockerSnippet = Snippet(title: "Logs", command: "docker logs -f --tail 100 {{container}}")
        XCTAssertEqual(dockerSnippet.unresolvedVariables(context: ["host": "1.2.3.4", "user": "root"]), ["container"])
        XCTAssertTrue(dockerSnippet.unresolvedVariables(context: ["container": "nginx-proxy"]).isEmpty)

        let portSnippet = Snippet(title: "Port Check", command: "ss -tulpn | grep {{port}}")
        XCTAssertEqual(portSnippet.unresolvedVariables(context: ["host": "1.2.3.4", "user": "root"]), ["port"])

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workspaceSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Workspace/WorkspaceView.swift"), encoding: .utf8)
        XCTAssertTrue(workspaceSource.contains("executeSnippet(snippet)"),
                      "CommandPalette snippet execution must route through unified executeSnippet handler with variable prompt support")
    }

    // MARK: - TC-REV-32: SSHTunnelManager jump server (-J) arguments and path expansion
    func testSSHTunnelBuildArgumentsWithJumpServerAndPathExpansion() {
        let jump = Session(name: "Jump", host: "203.0.113.5", port: 2222, username: "bastion", authMethod: .agent)
        let target = Session(
            name: "Internal DB",
            host: "10.10.0.8",
            port: 22,
            username: "dbadmin",
            authMethod: .certificate(keychainRef: "~/.ssh/id_ed25519", certificatePath: "~/.ssh/id_ed25519-cert.pub", passphraseRef: nil),
            jumpServerId: jump.id
        )
        let tunnel = SSHTunnel(name: "PG Tunnel", type: .local, sessionId: target.id, bindPort: 15432, targetHost: "127.0.0.1", targetPort: 5432)

        let args = SSHTunnelManager.buildSSHArguments(tunnel: tunnel, session: target, jumpSession: jump)
        if let jIdx = args.firstIndex(of: "-J"), jIdx + 1 < args.count {
            XCTAssertEqual(args[jIdx + 1], "bastion@203.0.113.5:2222")
        } else {
            XCTFail("SSHTunnelManager.buildSSHArguments must include -J user@host:port when jumpSession is provided")
        }
        XCTAssertFalse(args.contains("~/.ssh/id_ed25519"), "Private key path must expand ~ before invoking Process")
        XCTAssertFalse(args.contains("CertificateFile=~/.ssh/id_ed25519-cert.pub"), "Certificate path must expand ~ before invoking Process")
    }

    // MARK: - TC-REV-33: SessionLogger streaming UTF-8 decoding across split multi-byte chunks
    func testSessionLoggerSplitMultiByteUTF8AndANSIFiltering() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("LoggerUTF8Tests_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let session = Session(name: "UTF8Test", host: "10.0.0.1", username: "root")
        let config = SessionLogConfig(autoLoggingEnabled: true, logDirectoryPath: tempDir.path, format: .plainText, maxFileSizeMB: 10)
        let logger = SessionLogger(session: session, config: config)

        // "\u{001B}[32m中文测试\u{001B}[0m\n" where "中" (E4 B8 AD) is split across two chunks!
        let fullBytes = Array("\u{001B}[32m中文测试\u{001B}[0m\n".utf8)
        // Find first byte of "中" (0xE4) and split right after 0xE4, 0xB8
        let splitIndex = 6 // 5 bytes of "\x1B[32m" + 1st byte of "中" (0xE4)
        let chunk1 = Data(fullBytes[0..<splitIndex])
        let chunk2 = Data(fullBytes[splitIndex..<fullBytes.count])

        logger.appendData(chunk1)
        logger.appendData(chunk2)
        logger.close()

        let fileURL = try XCTUnwrap(logger.activeFileURL)
        let loggedText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(loggedText.contains("中文测试"), "Split multi-byte UTF-8 characters must be reassembled cleanly")
        XCTAssertFalse(loggedText.contains("\u{001B}[32m"), "Split UTF-8 chunk must not bypass ANSI stripping in plainText mode")
    }

    // MARK: - TC-REV-34: AppSettings.resetToDefaults resets session audit logging properties
    @MainActor
    func testAppSettingsResetToDefaultsResetsLoggingProperties() {
        let settings = AppSettings.shared
        let prevEnabled = settings.isSessionLoggingEnabled
        let prevFormat = settings.sessionLogFormat
        let prevDir = settings.sessionLogDirectory
        let prevMax = settings.sessionLogMaxFileSizeMB
        defer {
            settings.isSessionLoggingEnabled = prevEnabled
            settings.sessionLogFormat = prevFormat
            settings.sessionLogDirectory = prevDir
            settings.sessionLogMaxFileSizeMB = prevMax
        }

        settings.isSessionLoggingEnabled = true
        settings.sessionLogFormat = .rawAnsi
        settings.sessionLogDirectory = "/tmp/custom_audit_logs"
        settings.sessionLogMaxFileSizeMB = 200

        settings.resetToDefaults()

        XCTAssertFalse(settings.isSessionLoggingEnabled)
        XCTAssertEqual(settings.sessionLogFormat, .plainText)
        XCTAssertEqual(settings.sessionLogMaxFileSizeMB, 50)
        XCTAssertTrue(settings.sessionLogDirectory.hasSuffix("AetherTerm/Logs"))
    }

    // MARK: - TC-REV-35: Broadcast mode filters connected panes and refreshes directory linkage
    func testBroadcastModeFiltersConnectedPanesAndRefreshesLinkage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workspaceSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Workspace/WorkspaceView.swift"), encoding: .utf8)
        XCTAssertTrue(workspaceSource.contains("where p.connectionState == .connected"),
                      "Broadcast mode must only send input to connected panes")
    }

    // MARK: - TC-REV-36: Copy-on-select setting respected by context menu and WorkspaceView binding
    @MainActor
    func testCopyOnSelectDisabledDoesNotClobberPasteboardOnContextMenu() throws {
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }

        pasteboard.clearContents()
        pasteboard.setString("keep-existing-clipboard", forType: .string)

        let view = NativeTerminalView()
        view.isCopyOnSelectEnabled = false
        view.textStorage?.setAttributedString(NSAttributedString(string: "selected terminal text"))
        view.setSelectedRange(NSRange(location: 0, length: 8))

        _ = view.menu(for: NSEvent())
        XCTAssertEqual(pasteboard.string(forType: .string), "keep-existing-clipboard",
                       "Opening context menu with isCopyOnSelectEnabled == false must not overwrite clipboard")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workspaceSource = try String(contentsOf: root.appendingPathComponent("Sources/ApexUI/Workspace/WorkspaceView.swift"), encoding: .utf8)
        XCTAssertTrue(workspaceSource.contains("isCopyOnSelectEnabled: themeSettings.isCopyOnSelectEnabled"),
                      "PaneContainerView must pass themeSettings.isCopyOnSelectEnabled to TerminalRepresentable")
    }

    // MARK: - TC-REV-37: TerminalRingBuffer records standalone BEL (\u{07}) while ignoring OSC terminator BEL
    @MainActor
    func testTerminalBellDetectionAndVisualBellHandling() {
        let buffer = TerminalRingBuffer(maxLines: 100)
        XCTAssertFalse(buffer.consumeBellFlag())

        // 1. OSC title sequence terminated by \u{07} must NOT trigger a terminal bell
        buffer.appendStream("\u{1B}]0;user@host:~/project\u{07}prompt$ ")
        XCTAssertFalse(buffer.consumeBellFlag(), "OSC sequence terminator BEL must not trigger terminal bell")

        // 2. Standalone BEL (\u{07}) must set the pending bell flag and be consumed atomically once
        buffer.appendStream("\u{07}")
        XCTAssertTrue(buffer.consumeBellFlag(), "Standalone BEL character must set bell flag")
        XCTAssertFalse(buffer.consumeBellFlag(), "consumeBellFlag must reset flag after consumption")

        // 3. NativeTerminalView.refresh() consumes bell flag and increments bellTriggerCount
        let prevBellMode = AppSettings.shared.bellMode
        AppSettings.shared.bellMode = .visual
        defer { AppSettings.shared.bellMode = prevBellMode }

        let view = NativeTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: nil)
        view.ringBuffer = buffer
        buffer.appendStream("alert\u{07}\n")
        view.refresh()
        XCTAssertEqual(view.bellTriggerCount, 1)
    }

    // MARK: - TC-REV-38: TransferManager.clearCompleted removes failed tasks and cleans speed tracking dictionaries
    @MainActor
    func testTransferManagerClearCompletedRemovesFailedTasksAndCleansSamples() {
        let manager = TransferManager(distributionChannel: .direct, maxConcurrentTransfers: 2)
        let dummyURL = URL(fileURLWithPath: "/tmp/test-transfer.bin")

        let completedId = manager.beginExternalTransfer(
            fileName: "done.bin", remotePath: "/root/done.bin", localURL: dummyURL, direction: .upload, totalBytes: 100
        )
        manager.completeExternalTransfer(taskId: completedId)

        let failedId = manager.beginExternalTransfer(
            fileName: "failed.bin", remotePath: "/root/failed.bin", localURL: dummyURL, direction: .download, totalBytes: 200
        )
        manager.failExternalTransfer(taskId: failedId, error: NSError(domain: "SFTP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied"]))

        let activeId = manager.beginExternalTransfer(
            fileName: "active.bin", remotePath: "/root/active.bin", localURL: dummyURL, direction: .upload, totalBytes: 500
        )

        XCTAssertTrue(manager.tasks.first(where: { $0.id == completedId })?.status.isTerminal == true)
        XCTAssertTrue(manager.tasks.first(where: { $0.id == failedId })?.status.isTerminal == true)
        XCTAssertFalse(manager.tasks.first(where: { $0.id == activeId })?.status.isTerminal == true)

        manager.clearCompleted()

        XCTAssertEqual(manager.tasks.map(\.id), [activeId], "clearCompleted() must remove completed, cancelled, and failed tasks while keeping active tasks")

        manager.removeTask(id: activeId)
        XCTAssertTrue(manager.tasks.isEmpty, "removeTask(id:) must cancel and remove the specified task")
    }

    // MARK: - TC-REV-39: VTParser and TerminalRingBuffer support colon-separated CSI SGR subparameters
    func testVTParserAndRingBufferColonSeparatedSGRAndIntermediateCSI() {
        let parser = VTParser()
        // Colon-separated TrueColor (38:2:255:128:0 and ITU 38:2::0:200:100) + curly underline (4:3) + underline off (4:0) + DECSCUSR (\e[6 q)
        let raw = "\u{1B}[6 q\u{1B}[38:2:255:128:0;4:3mOrangeUnder\u{1B}[4:0;38:2::0:200:100mGreenPlain\u{1B}[0m"
        let spans = parser.parseANSI(raw)

        XCTAssertEqual(spans.map(\.text).joined(), "OrangeUnderGreenPlain",
                       "CSI sequences with colon subparameters or intermediate bytes must never leak into visible text")
        XCTAssertEqual(spans.first?.foregroundColorHex, "#FF8000")
        XCTAssertEqual(spans.first?.isUnderlined, true)
        if spans.count >= 2 {
            XCTAssertEqual(spans[1].foregroundColorHex, "#00C864")
            XCTAssertEqual(spans[1].isUnderlined, false)
        }

        let buffer = TerminalRingBuffer(maxLines: 50)
        buffer.appendStream("\u{1B}[38:2:255:128:0mColored\u{1B}[0m\r\n")
        let lines = buffer.tailLines(count: 1)
        XCTAssertEqual(lines.count, 1)
        let parsedFromBuffer = parser.parseANSI(lines[0])
        XCTAssertEqual(parsedFromBuffer.map(\.text).joined(), "Colored")
    }

    // MARK: - TC-REV-40: iCloudSyncManager.syncNow(withTemporaryStrategy:) restores conflictStrategy on error
    @MainActor
    func testICloudSyncTemporaryStrategyRestoresOnThrow() async {
        final class UnavailableCloudBackend: iCloudStorageBackend, @unchecked Sendable {
            func isCloudAvailable() -> Bool { false }
            func readPayloadData() throws -> Data? { nil }
            func writePayloadData(_ data: Data) throws {}
            func readBackupData() throws -> Data? { nil }
            func removePayloadData() throws {}
            func lastModifiedDate() -> Date? { nil }
            func cloudVaultURL() -> URL? { nil }
        }

        let manager = iCloudSyncManager(
            storageBackend: UnavailableCloudBackend(),
            conflictStrategy: .smartMerge
        )
        XCTAssertEqual(manager.conflictStrategy, .smartMerge)

        do {
            _ = try await manager.syncNow(withTemporaryStrategy: .overwriteCloud)
            XCTFail("Expected cloudUnavailable error")
        } catch {
            // Expected throw
        }

        XCTAssertEqual(manager.conflictStrategy, .smartMerge,
                       "conflictStrategy must be restored to original value even when syncNow throws")
    }
}
