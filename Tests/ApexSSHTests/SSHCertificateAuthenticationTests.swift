import XCTest
@testable import ApexCore
@testable import ApexSSH

final class SSHCertificateAuthenticationTests: XCTestCase {
    private var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SSHCertTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    // MARK: - TC-CERT-01: Session Model with Certificate Authentication Serialization & Equality
    func testSessionCertificateAuthMethodSerialization() throws {
        let keyPath = "~/.ssh/id_ed25519"
        let certPath = "~/.ssh/id_ed25519-cert.pub"
        let passRef = "passphrase_123"
        
        let session = Session(
            name: "CA-Secured Bastion",
            host: "bastion.example.com",
            port: 2222,
            username: "deployer",
            authMethod: .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: passRef)
        )
        
        // Assert accessors
        XCTAssertTrue(session.authMethod.isCertificate)
        XCTAssertEqual(session.authMethod.certificatePath, certPath)
        XCTAssertEqual(session.authMethod.privateKeyPath, keyPath)
        XCTAssertEqual(session.certificatePath, certPath)
        
        // JSON Roundtrip
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(session)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Session.self, from: data)
        
        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.name, session.name)
        XCTAssertEqual(decoded.host, session.host)
        XCTAssertEqual(decoded.port, session.port)
        XCTAssertEqual(decoded.username, session.username)
        XCTAssertEqual(decoded.authMethod, session.authMethod)
        XCTAssertEqual(decoded.certificatePath, certPath)
    }
    
    // MARK: - TC-CERT-02: Native SSH Argument Construction with CertificateFile
    func testNativeSSHAuthArgsWithCertificate() {
        let keyPath = "/Users/test/.ssh/id_ed25519"
        let certPath = "/Users/test/.ssh/id_ed25519-cert.pub"
        
        let session = Session(
            name: "Cert Host",
            host: "10.0.0.1",
            port: 22,
            username: "root",
            authMethod: .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: nil)
        )
        
        let client = NativeSSHSession(session: session)
        let args = client.sshAuthArgs()
        
        // Must contain -i <keyPath>
        guard let iIndex = args.firstIndex(of: "-i") else {
            XCTFail("sshAuthArgs must include -i flag for private key identity")
            return
        }
        XCTAssertEqual(args[iIndex + 1], keyPath)
        
        // Must contain -o CertificateFile=<certPath>
        XCTAssertTrue(args.contains("-o"), "sshAuthArgs must include -o flag for OpenSSH options")
        XCTAssertTrue(args.contains("CertificateFile=\(certPath)"), "sshAuthArgs must pass CertificateFile=<path>")
    }
    
    // MARK: - TC-CERT-03: OpenSSH Config Parser with CertificateFile Directive
    func testOpenSSHConfigParserWithCertificateFileDirective() {
        let sshConfigContent = """
        Host production-node
            HostName prod.internal.net
            User ops
            Port 2200
            IdentityFile ~/.ssh/id_rsa
            CertificateFile ~/.ssh/id_rsa-cert.pub
        
        Host staging-node
            HostName stage.internal.net
            User stage
            IdentityFile ~/.ssh/id_ecdsa
        """
        
        let hosts = SSHConfigParser.parse(content: sshConfigContent)
        XCTAssertEqual(hosts.count, 2)
        
        let prodHost = hosts.first(where: { $0.hostPattern == "production-node" })
        XCTAssertNotNil(prodHost)
        XCTAssertEqual(prodHost?.hostName, "prod.internal.net")
        XCTAssertEqual(prodHost?.user, "ops")
        XCTAssertEqual(prodHost?.port, 2200)
        XCTAssertTrue(prodHost?.identityFile?.hasSuffix("/.ssh/id_rsa") == true)
        XCTAssertTrue(prodHost?.certificateFile?.hasSuffix("/.ssh/id_rsa-cert.pub") == true)
        
        // Convert to session
        let prodSession = prodHost!.toSession()
        XCTAssertTrue(prodSession.authMethod.isCertificate)
        XCTAssertEqual(prodSession.authMethod.privateKeyPath, prodHost?.identityFile)
        XCTAssertEqual(prodSession.authMethod.certificatePath, prodHost?.certificateFile)
        
        let stageHost = hosts.first(where: { $0.hostPattern == "staging-node" })
        XCTAssertNotNil(stageHost)
        XCTAssertNil(stageHost?.certificateFile)
        let stageSession = stageHost!.toSession()
        XCTAssertFalse(stageSession.authMethod.isCertificate)
    }
    
    // MARK: - TC-CERT-04: SSHTunnel Arguments with Certificate Authentication
    func testSSHTunnelArgumentsWithCertificate() {
        let sid = UUID()
        let keyPath = "/Users/ops/.ssh/id_ed25519"
        let certPath = "/Users/ops/.ssh/id_ed25519-cert.pub"
        
        let session = Session(
            id: sid,
            name: "Bastion Cert",
            host: "jump.company.com",
            port: 22,
            username: "tunneluser",
            authMethod: .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: nil)
        )
        
        let tunnel = SSHTunnel(
            name: "Internal Web",
            type: .local,
            sessionId: sid,
            bindHost: "127.0.0.1",
            bindPort: 8080,
            targetHost: "internal.web",
            targetPort: 80
        )
        
        let args = SSHTunnelManager.buildSSHArguments(tunnel: tunnel, session: session, privateKeyPath: keyPath)
        
        // Verify tunnel specifier and certificate file
        XCTAssertTrue(args.contains("-N"))
        XCTAssertTrue(args.contains("-L"))
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains(keyPath))
        XCTAssertTrue(args.contains("CertificateFile=\(certPath)"))
    }
    
    // MARK: - TC-CERT-05: iCloud Sync Zero-Bundle Sanitization with Certificate
    func testICloudSyncSanitizationWithCertificate() {
        let safeKeyPath = "key_vault_ed25519_ref"
        let certPath = "/Users/dev/.ssh/id_ed25519-cert.pub"
        let passRef = "pass_ref_1"
        
        let safeSession = Session(
            name: "Cloud Session",
            host: "cloud.host",
            username: "admin",
            authMethod: .certificate(keychainRef: safeKeyPath, certificatePath: certPath, passphraseRef: passRef)
        )
        
        // Session with accidental raw PEM in keychainRef (must be redacted)
        let unsafeSession = Session(
            name: "Unsafe Session",
            host: "leaked.host",
            username: "admin",
            authMethod: .certificate(keychainRef: "-----BEGIN OPENSSH PRIVATE KEY-----...", certificatePath: certPath, passphraseRef: passRef)
        )
        
        let payload = iCloudSyncPayload(sessions: [safeSession, unsafeSession])
        let sanitized = iCloudSyncManager.sanitizeForCloud(payload: payload)
        
        XCTAssertEqual(sanitized.sessions.count, 2)
        XCTAssertEqual(sanitized.sessions[0].authMethod, safeSession.authMethod)
        
        // Unsafe session private key PEM must be redacted to safe ref, while certPath is preserved
        guard case .certificate(let redactedKeyRef, let preservedCert, let pass) = sanitized.sessions[1].authMethod else {
            XCTFail("Must remain .certificate authMethod")
            return
        }
        XCTAssertEqual(redactedKeyRef, "redacted_key_ref")
        XCTAssertEqual(preservedCert, certPath)
        XCTAssertEqual(pass, passRef)
    }
    
    // MARK: - TC-CERT-06: Certificate File Auto-Discovery Helper
    func testCertificateFileAutoDiscovery() throws {
        let keyURL = tempDir.appendingPathComponent("id_ed25519")
        let certURL = tempDir.appendingPathComponent("id_ed25519-cert.pub")
        
        try "dummy-private-key".write(to: keyURL, atomically: true, encoding: .utf8)
        try "ssh-ed25519-cert-v01@openssh.com AAA... test".write(to: certURL, atomically: true, encoding: .utf8)
        
        let discovered = SSHCertificateHelper.discoverCertificate(forPrivateKeyPath: keyURL.path)
        XCTAssertEqual(discovered, certURL.path)
        
        // When cert file does not exist, returns nil
        let orphanKeyURL = tempDir.appendingPathComponent("orphan_rsa")
        try "dummy-key".write(to: orphanKeyURL, atomically: true, encoding: .utf8)
        XCTAssertNil(SSHCertificateHelper.discoverCertificate(forPrivateKeyPath: orphanKeyURL.path))
    }
    
    // MARK: - TC-CERT-07: OpenSSH Certificate Payload Validation & Metadata
    func testOpenSSHCertificateValidationAndMetadata() {
        // Valid OpenSSH certificate format
        let validCertString = "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAA... developer@aetherterm"
        let validInfo = SSHCertificateHelper.inspectCertificate(certContent: validCertString)
        XCTAssertTrue(validInfo.isValid)
        XCTAssertEqual(validInfo.keyType, "ssh-ed25519-cert-v01@openssh.com")
        XCTAssertEqual(validInfo.comment, "developer@aetherterm")
        
        // Plain public key (not a certificate)
        let plainPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... dev@host"
        let plainInfo = SSHCertificateHelper.inspectCertificate(certContent: plainPublicKey)
        XCTAssertFalse(plainInfo.isValid, "Standard public key must not be treated as an SSH certificate")
        
        // Invalid random content
        let invalidInfo = SSHCertificateHelper.inspectCertificate(certContent: "not a certificate")
        XCTAssertFalse(invalidInfo.isValid)
    }
    
    // MARK: - TC-CERT-08: Legacy AuthMethod Compatibility
    func testLegacyAuthMethodCompatibility() throws {
        // Verify JSON generated by older versions without certificate still decodes cleanly
        let legacyJSON = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "name": "Legacy Server",
            "host": "legacy.org",
            "port": 22,
            "username": "admin",
            "authMethod": {
                "privateKey": {
                    "keychainRef": "/path/to/key",
                    "passphraseRef": null
                }
            },
            "sessionType": "ssh",
            "tags": [],
            "agentlessMonitorEnabled": true,
            "sftpAutoSyncEnabled": true,
            "keepAliveIntervalSeconds": 30,
            "createdAt": 1700000000
        }
        """.data(using: .utf8)!
        
        let session = try JSONDecoder().decode(Session.self, from: legacyJSON)
        XCTAssertEqual(session.name, "Legacy Server")
        XCTAssertFalse(session.authMethod.isCertificate)
        XCTAssertNil(session.certificatePath)
        XCTAssertEqual(session.authMethod.privateKeyPath, "/path/to/key")
    }
}
