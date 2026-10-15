import XCTest
@testable import ApexCore
@testable import ApexSSH

final class SSHKeyVaultTests: XCTestCase {
    private var tempDirectory: URL!
    
    // Sample public keys
    private let sampleEd25519Pub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH6jK6t+n6R5v+q1U6qW4yG6tH4x8W2x+JkL7Z9P0ABC user@devops"
    private let sampleRSAPub = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC8vF4b2190... user@legacy"
    private let sampleECDSAPub = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAI... user@cloud"
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SSHKeyVaultTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    // MARK: - TC-KEY-01: Fingerprint Calculation
    func testFingerprintCalculationEd25519() {
        let fp = SSHKeyIdentity.computeFingerprint(from: sampleEd25519Pub)
        XCTAssertTrue(fp.hasPrefix("SHA256:"))
        XCTAssertGreaterThan(fp.count, 20)
        XCTAssertFalse(fp.contains("=")) // padding stripped standard OpenSSH style
    }
    
    // MARK: - TC-KEY-02: Algorithm Detection
    func testDetectAlgorithm() {
        XCTAssertEqual(SSHKeyIdentity.detectAlgorithm(from: sampleEd25519Pub), .ed25519)
        XCTAssertEqual(SSHKeyIdentity.detectAlgorithm(from: sampleRSAPub), .rsa)
        XCTAssertEqual(SSHKeyIdentity.detectAlgorithm(from: sampleECDSAPub), .ecdsa)
    }
    
    // MARK: - TC-KEY-03: Deploy Command Generation
    func testGenerateDeployCommand() {
        let key = SSHKeyIdentity(
            name: "DevOps Key",
            algorithm: .ed25519,
            fingerprintSHA256: "SHA256:mockfingerprint",
            publicKeyOpenSSH: sampleEd25519Pub,
            keychainPrivateKeyRef: "vault.priv.test"
        )
        let cmd = key.generateDeployCommand()
        XCTAssertTrue(cmd.contains("umask 077"))
        XCTAssertTrue(cmd.contains("chmod 700 ~/.ssh"))
        XCTAssertTrue(cmd.contains("chmod 600 ~/.ssh/authorized_keys"))
        XCTAssertTrue(cmd.contains("echo 'ssh-ed25519"))
        XCTAssertTrue(cmd.contains(">> ~/.ssh/authorized_keys"))
    }
    
    // MARK: - TC-KEY-04: Add and Retrieve Key
    @MainActor
    func testAddAndRetrieveKey() throws {
        let manager = SSHKeyVaultManager(baseDirectory: tempDirectory)
        XCTAssertTrue(manager.keys.isEmpty)
        
        let id = UUID()
        let key = SSHKeyIdentity(
            id: id,
            name: "Production Bastion",
            algorithm: .ed25519,
            fingerprintSHA256: "SHA256:abc123xyz",
            publicKeyOpenSSH: sampleEd25519Pub,
            keychainPrivateKeyRef: "vault.priv.\(id.uuidString)"
        )
        try manager.addKey(key)
        
        XCTAssertEqual(manager.keys.count, 1)
        XCTAssertEqual(manager.key(for: id)?.name, "Production Bastion")
    }
    
    // MARK: - TC-KEY-05: Duplicate Key Prevention
    @MainActor
    func testDuplicateKeyPrevention() throws {
        let manager = SSHKeyVaultManager(baseDirectory: tempDirectory)
        let key1 = SSHKeyIdentity(
            name: "Key 1",
            algorithm: .ed25519,
            fingerprintSHA256: "SHA256:samefingerprint",
            publicKeyOpenSSH: sampleEd25519Pub,
            keychainPrivateKeyRef: "vault.priv.1"
        )
        try manager.addKey(key1)
        
        let key2 = SSHKeyIdentity(
            name: "Key 2",
            algorithm: .ed25519,
            fingerprintSHA256: "SHA256:samefingerprint",
            publicKeyOpenSSH: sampleEd25519Pub,
            keychainPrivateKeyRef: "vault.priv.2"
        )
        
        XCTAssertThrowsError(try manager.addKey(key2)) { error in
            guard case SSHKeyVaultError.duplicateKey(let fp) = error else {
                XCTFail("Expected duplicateKey error")
                return
            }
            XCTAssertEqual(fp, "SHA256:samefingerprint")
        }
    }
    
    // MARK: - TC-KEY-06: Delete Key
    @MainActor
    func testDeleteKey() throws {
        let manager = SSHKeyVaultManager(baseDirectory: tempDirectory)
        let id = UUID()
        let key = SSHKeyIdentity(
            id: id,
            name: "Temporary Key",
            algorithm: .ed25519,
            fingerprintSHA256: "SHA256:temp",
            publicKeyOpenSSH: sampleEd25519Pub,
            keychainPrivateKeyRef: "vault.priv.temp"
        )
        try manager.addKey(key)
        XCTAssertEqual(manager.keys.count, 1)
        
        manager.deleteKey(id: id)
        XCTAssertEqual(manager.keys.count, 0)
        XCTAssertNil(manager.key(for: id))
    }
    
    // MARK: - TC-KEY-07: Empty Private Key Validation
    @MainActor
    func testEmptyPrivateKeyValidation() async {
        let manager = SSHKeyVaultManager(baseDirectory: tempDirectory)
        do {
            _ = try manager.importKey(
                name: "Bad Key",
                privateKeyPEM: "   \n  ",
                publicKeyOpenSSH: sampleEd25519Pub
            )
            XCTFail("Expected error for empty private key")
        } catch let error as SSHKeyVaultError {
            XCTAssertEqual(error, .privateKeyEmpty)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    // MARK: - TC-KEY-08: Vault Persistence Roundtrip
    @MainActor
    func testVaultPersistence() throws {
        let manager1 = SSHKeyVaultManager(baseDirectory: tempDirectory)
        let key = SSHKeyIdentity(
            name: "Persistent Key",
            algorithm: .ed25519,
            fingerprintSHA256: "SHA256:persist",
            publicKeyOpenSSH: sampleEd25519Pub,
            keychainPrivateKeyRef: "vault.priv.persist",
            hasPassphrase: true
        )
        try manager1.addKey(key)
        
        // Create second instance reading from same directory
        let manager2 = SSHKeyVaultManager(baseDirectory: tempDirectory)
        XCTAssertEqual(manager2.keys.count, 1)
        XCTAssertEqual(manager2.keys.first?.name, "Persistent Key")
        XCTAssertEqual(manager2.keys.first?.fingerprintSHA256, "SHA256:persist")
        XCTAssertTrue(manager2.keys.first?.hasPassphrase == true)
    }
}
