import Foundation
import Security
import LocalAuthentication

/// Keychain and Biometric Security Store for SSH Credentials
public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()
    
    private let serviceName = "com.apexterm.ssh.credentials"
    
    public init() {}
    
    /// Save password or private key data securely
    public func save(key: String, secret: String) throws {
        guard let data = secret.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    /// Retrieve password or private key with optional Touch ID biometric challenge
    public func get(key: String, promptTouchID: Bool = false, promptReason: String = "Authenticate to access SSH credentials") async throws -> String {
        if promptTouchID {
            let context = LAContext()
            var authError: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
                let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: promptReason)
                if !success {
                    throw KeychainError.biometricAuthenticationFailed
                }
            }
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.readFailed(status)
        }
        return secret
    }
    
    /// Delete a secret
    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.deleteFailed(status)
        }
    }
}

public enum KeychainError: LocalizedError, Sendable {
    case saveFailed(OSStatus)
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case itemNotFound
    case biometricAuthenticationFailed
    
    public var errorDescription: String? {
        switch self {
        case .saveFailed(let s): return "Keychain save failed with status: \(s)"
        case .readFailed(let s): return "Keychain read failed with status: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed with status: \(s)"
        case .itemNotFound: return "Keychain item not found"
        case .biometricAuthenticationFailed: return "Biometric authentication failed or was cancelled"
        }
    }
}
