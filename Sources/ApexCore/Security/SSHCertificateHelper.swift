import Foundation

/// Certificate inspection metadata for OpenSSH user certificates
public struct SSHCertificateInfo: Sendable, Equatable {
    public let isValid: Bool
    public let keyType: String?
    public let comment: String?
    
    public init(isValid: Bool, keyType: String? = nil, comment: String? = nil) {
        self.isValid = isValid
        self.keyType = keyType
        self.comment = comment
    }
}

/// Helper utilities for OpenSSH certificate discovery, inspection, and path resolution
public enum SSHCertificateHelper {
    
    /// Known OpenSSH certificate type identifiers
    public static let supportedCertTypes: Set<String> = [
        "ssh-ed25519-cert-v01@openssh.com",
        "ssh-rsa-cert-v01@openssh.com",
        "ecdsa-sha2-nistp256-cert-v01@openssh.com",
        "ecdsa-sha2-nistp384-cert-v01@openssh.com",
        "ecdsa-sha2-nistp521-cert-v01@openssh.com",
        "sk-ssh-ed25519-cert-v01@openssh.com",
        "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com"
    ]
    
    /// Inspects raw string content of an OpenSSH public key / certificate file
    public static func inspectCertificate(certContent: String) -> SSHCertificateInfo {
        let trimmed = certContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else {
            return SSHCertificateInfo(isValid: false)
        }
        
        let type = parts[0]
        guard supportedCertTypes.contains(type) else {
            return SSHCertificateInfo(isValid: false)
        }
        
        let comment = parts.count >= 3 ? parts[2...].joined(separator: " ") : nil
        return SSHCertificateInfo(isValid: true, keyType: type, comment: comment)
    }
    
    /// Automatically locates `<privateKeyPath>-cert.pub` in the same directory if it exists
    public static func discoverCertificate(forPrivateKeyPath privateKeyPath: String) -> String? {
        let clean = privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        
        let expanded: String
        if clean.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path + "/" + String(clean.dropFirst(2))
        } else if clean == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else {
            expanded = clean
        }
        
        let candidatePath = expanded + "-cert.pub"
        if FileManager.default.fileExists(atPath: candidatePath) {
            return candidatePath
        }
        
        // Also check if clean path ends in .pub (unlikely for private key, but handle edge case)
        if clean.hasSuffix(".pub") {
            let withoutPub = String(clean.dropLast(4))
            let certCandidate = withoutPub + "-cert.pub"
            if FileManager.default.fileExists(atPath: certCandidate) {
                return certCandidate
            }
        }
        
        return nil
    }
}
