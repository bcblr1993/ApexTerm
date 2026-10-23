import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI
import AppKit
import SwiftUI

/// Regression coverage for the v1.14.2 full code review (TC-REV-01 ~ TC-REV-18).
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
}
