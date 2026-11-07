import XCTest
@testable import ApexCore

final class KnownHostsManagerTests: XCTestCase {

    private let sampleEd25519KeyA = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    private let sampleEd25519KeyB = "AAAAC3NzaC1lZDI1NTE5AAAAIBX9p7wK8vL2mN4qR6sT8uV0wX2yZ4aB6cD8eF0gH2iJ"
    private let sampleRSAKey = "AAAAB3NzaC1yc2EAAAADAQABAAABAQDf1234567890abcdef"

    /// TC-KH-01: Standard host,ip and custom port [host]:2222 parsing and matchesEndpoint verification
    func testStandardAndCustomPortParsingAndEndpointMatching() {
        let raw = """
        # Developer known_hosts
        github.com,140.82.112.4 ssh-ed25519 \(sampleEd25519KeyA) git@github
        [bastion.apex.io]:2222 ecdsa-sha2-nistp256 \(sampleEd25519KeyB)
        """
        let entries = KnownHostsManager.parse(content: raw)
        XCTAssertEqual(entries.count, 2)

        let first = entries[0]
        XCTAssertEqual(first.lineNumber, 2)
        XCTAssertEqual(first.individualHosts, ["github.com", "140.82.112.4"])
        XCTAssertEqual(first.algorithmBadge, "ED25519")
        XCTAssertEqual(first.comment, "git@github")
        XCTAssertTrue(first.matchesEndpoint(host: "github.com", port: 22))
        XCTAssertTrue(first.matchesEndpoint(host: "140.82.112.4", port: 22))
        XCTAssertFalse(first.matchesEndpoint(host: "github.com", port: 2222))

        let second = entries[1]
        XCTAssertEqual(second.lineNumber, 3)
        XCTAssertEqual(second.algorithmBadge, "ECDSA")
        XCTAssertTrue(second.matchesEndpoint(host: "bastion.apex.io", port: 2222))
        XCTAssertFalse(second.matchesEndpoint(host: "bastion.apex.io", port: 22))
    }

    /// TC-KH-02: @cert-authority and @revoked marker parsing
    func testCertAuthorityAndRevokedMarkerParsing() {
        let raw = """
        @cert-authority *.corp.example.com ssh-ed25519 \(sampleEd25519KeyA) CA-Root
        @revoked compromised.example.com ssh-rsa \(sampleRSAKey)
        """
        let entries = KnownHostsManager.parse(content: raw)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].marker, .certAuthority)
        XCTAssertEqual(entries[0].hostPattern, "*.corp.example.com")
        XCTAssertEqual(entries[0].comment, "CA-Root")

        XCTAssertEqual(entries[1].marker, .revoked)
        XCTAssertEqual(entries[1].hostPattern, "compromised.example.com")
        XCTAssertEqual(entries[1].algorithmBadge, "RSA")
    }

    /// TC-KH-03: Hashed host entry (|1|salt|hash) recognition
    func testHashedHostEntryRecognition() {
        let raw = "|1|F1E2D3C4B5A69788=|A9B8C7D6E5F40123= ssh-ed25519 \(sampleEd25519KeyA)"
        let entries = KnownHostsManager.parse(content: raw)
        XCTAssertEqual(entries.count, 1)
        let entry = entries[0]
        XCTAssertTrue(entry.isHashed)
        XCTAssertEqual(entry.displayHostTitle, "哈希混淆主机 (Hashed Host)")
        XCTAssertFalse(entry.matchesEndpoint(host: "192.168.1.10", port: 22))
    }

    /// TC-KH-04: OpenSSH SHA256:<unpadded-base64> fingerprint calculation
    func testSHA256FingerprintCalculationMatchesOpenSSHFormat() {
        let fp = KnownHostsManager.computeSHA256Fingerprint(base64PublicKey: sampleEd25519KeyA)
        XCTAssertTrue(fp.hasPrefix("SHA256:"))
        XCTAssertFalse(fp.contains("="), "OpenSSH SHA256 fingerprint must strip trailing base64 '=' padding")
        // Verify deterministic SHA-256 of GitHub's well-known Ed25519 public key
        XCTAssertEqual(fp, "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
    }

    /// TC-KH-05: Host key conflict detection for same host + keyType with different fingerprints
    func testHostKeyConflictDetection() {
        let raw = """
        10.0.1.50 ssh-ed25519 \(sampleEd25519KeyA) old-os-install
        10.0.1.50 ssh-ed25519 \(sampleEd25519KeyB) reinstalled-os
        10.0.1.50 ssh-rsa \(sampleRSAKey) coexisting-rsa-is-not-conflict
        """
        let entries = KnownHostsManager.parse(content: raw)
        let conflicts = KnownHostsManager.detectConflicts(in: entries)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].endpoint, "10.0.1.50")
        XCTAssertEqual(conflicts[0].keyType, "ssh-ed25519")
        XCTAssertEqual(conflicts[0].conflictingEntries.count, 2)
    }

    /// TC-KH-06: Single-entry removal creates atomic known_hosts.bak backup and preserves comments
    func testRemoveSingleEntryCreatesAtomicBackupAndPreservesComments() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("kh-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let khFile = tempDir.appendingPathComponent("known_hosts")
        let initial = """
        # Managed by AetherTerm
        node1.apex.io ssh-ed25519 \(sampleEd25519KeyA)
        node2.apex.io ssh-ed25519 \(sampleEd25519KeyB)
        """
        try initial.write(to: khFile, atomically: true, encoding: .utf8)

        let manager = KnownHostsManager(fileURL: khFile)
        XCTAssertEqual(manager.entries.count, 2)

        let firstId = manager.entries[0].id
        let removed = try manager.removeEntry(id: firstId)
        XCTAssertTrue(removed)
        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries[0].hostPattern, "node2.apex.io")

        // Verify .bak backup has original content and new file preserves comment header
        let backupContent = try String(contentsOf: manager.backupFileURL, encoding: .utf8)
        XCTAssertEqual(backupContent, initial)
        let updatedContent = try String(contentsOf: khFile, encoding: .utf8)
        XCTAssertTrue(updatedContent.contains("# Managed by AetherTerm"))
        XCTAssertFalse(updatedContent.contains("node1.apex.io"))
        XCTAssertTrue(updatedContent.contains("node2.apex.io"))
    }

    /// TC-KH-07: removeEntries(matchingEndpoint:port:) cleans up standard and custom port entries
    func testRemoveEntriesMatchingEndpointAndPort() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("kh-endpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let khFile = tempDir.appendingPathComponent("known_hosts")
        let initial = """
        [192.168.1.20]:2222 ssh-ed25519 \(sampleEd25519KeyA)
        192.168.1.20 ssh-ed25519 \(sampleEd25519KeyB)
        """
        try initial.write(to: khFile, atomically: true, encoding: .utf8)

        let manager = KnownHostsManager(fileURL: khFile)
        let removedCustomPort = try manager.removeEntries(matchingEndpoint: "192.168.1.20", port: 2222)
        XCTAssertEqual(removedCustomPort, 1)
        XCTAssertEqual(manager.entries.count, 1)
        XCTAssertEqual(manager.entries[0].hostPattern, "192.168.1.20")
    }

    /// TC-KH-08: Filtering by hostname, algorithm badge, SHA-256 fingerprint, and marker
    func testFilterKnownHostsByHostAlgorithmFingerprintAndMarker() {
        let raw = """
        prod-db.internal ssh-ed25519 \(sampleEd25519KeyA) db-primary
        @cert-authority *.staging.internal ssh-rsa \(sampleRSAKey) staging-ca
        """
        let entries = KnownHostsManager.parse(content: raw)
        XCTAssertEqual(KnownHostsManager.filter(entries, query: "prod-db").count, 1)
        XCTAssertEqual(KnownHostsManager.filter(entries, query: "ED25519").count, 1)
        XCTAssertEqual(KnownHostsManager.filter(entries, query: "+DiY3wvvV6Tu").count, 1)
        XCTAssertEqual(KnownHostsManager.filter(entries, query: "@cert-authority").count, 1)
        XCTAssertEqual(KnownHostsManager.filter(entries, query: "nonexistent").count, 0)
    }
}
