import Foundation
import CryptoKit

/// Cryptographic algorithm type of the SSH key pair
public enum SSHKeyAlgorithm: String, CaseIterable, Codable, Sendable, Identifiable {
    case ed25519 = "Ed25519"
    case rsa     = "RSA (4096-bit)"
    case ecdsa   = "ECDSA (P-256)"
    
    public var id: String { rawValue }
    
    public var isModern: Bool {
        self == .ed25519
    }
}

/// Represents a managed SSH Key pair in the centralized SSH Key Vault
public struct SSHKeyIdentity: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var algorithm: SSHKeyAlgorithm
    public var fingerprintSHA256: String
    public var publicKeyOpenSSH: String
    public var keychainPrivateKeyRef: String
    public var hasPassphrase: Bool
    public var keychainPassphraseRef: String?
    public var createdAt: Date
    
    public init(
        id: UUID = UUID(),
        name: String,
        algorithm: SSHKeyAlgorithm = .ed25519,
        fingerprintSHA256: String,
        publicKeyOpenSSH: String,
        keychainPrivateKeyRef: String,
        hasPassphrase: Bool = false,
        keychainPassphraseRef: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.fingerprintSHA256 = fingerprintSHA256
        self.publicKeyOpenSSH = publicKeyOpenSSH.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keychainPrivateKeyRef = keychainPrivateKeyRef
        self.hasPassphrase = hasPassphrase
        self.keychainPassphraseRef = keychainPassphraseRef
        self.createdAt = createdAt
    }
    
    /// Generates standard OpenSSH command to append this public key to the remote host's ~/.ssh/authorized_keys
    public func generateDeployCommand() -> String {
        let cleanPub = publicKeyOpenSSH.replacingOccurrences(of: "'", with: "'\\''")
        return "umask 077; test -d ~/.ssh || mkdir -p ~/.ssh; chmod 700 ~/.ssh; echo '\(cleanPub)' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
    }
    
    /// Computes SHA256 OpenSSH fingerprint from base64 public key bytes
    public static func computeFingerprint(from openSSHPubKey: String) -> String {
        let parts = openSSHPubKey.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2, let keyData = Data(base64Encoded: parts[1]) else {
            // Fallback SHA256 of the raw string if not standard space-delimited
            let hash = SHA256.hash(data: Data(openSSHPubKey.utf8))
            let b64 = Data(hash).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return "SHA256:\(b64)"
        }
        let hash = SHA256.hash(data: keyData)
        let b64 = Data(hash).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(b64)"
    }
    
    /// Detects algorithm from public key string
    public static func detectAlgorithm(from pubKey: String) -> SSHKeyAlgorithm {
        let lower = pubKey.lowercased()
        if lower.contains("ssh-ed25519") {
            return .ed25519
        } else if lower.contains("ecdsa") {
            return .ecdsa
        } else {
            return .rsa
        }
    }
}
