import Foundation

public enum SSHKeyVaultError: LocalizedError, Equatable {
    case duplicateKey(String)
    case invalidPublicKey(String)
    case keyNotFound
    case privateKeyEmpty
    
    public var errorDescription: String? {
        switch self {
        case .duplicateKey(let fp):
            return "该 SSH 密钥已被保险库收纳 (指纹: \(fp))"
        case .invalidPublicKey(let reason):
            return "公钥格式无效：\(reason)"
        case .keyNotFound:
            return "未在密钥保险库中找到指定密钥"
        case .privateKeyEmpty:
            return "私钥内容不能为空"
        }
    }
}

/// Centralized manager for SSH Key Vault persistence, Keychain secret storage, and public key deployment
@MainActor
public final class SSHKeyVaultManager: ObservableObject {
    public static let shared = SSHKeyVaultManager()
    
    @Published public private(set) var keys: [SSHKeyIdentity] = []
    
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    
    public init(baseDirectory: URL? = nil) {
        if let baseDirectory = baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = SessionStore.defaultDirectory(appSupport: appSupport, bundleIdentifier: Bundle.main.bundleIdentifier)
        }
        
        try? fileManager.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
        loadKeys()
    }
    
    private var vaultFileURL: URL {
        baseDirectory.appendingPathComponent("key_vault.json")
    }
    
    public func loadKeys() {
        guard let data = try? Data(contentsOf: vaultFileURL),
              let decoded = try? JSONDecoder().decode([SSHKeyIdentity].self, from: data) else {
            return
        }
        self.keys = decoded
    }
    
    public func saveKeys() {
        if let data = try? JSONEncoder().encode(keys) {
            try? data.write(to: vaultFileURL, options: .atomic)
        }
    }
    
    public func addKey(_ identity: SSHKeyIdentity) throws {
        if keys.contains(where: { $0.id != identity.id && $0.fingerprintSHA256 == identity.fingerprintSHA256 }) {
            throw SSHKeyVaultError.duplicateKey(identity.fingerprintSHA256)
        }
        keys.append(identity)
        saveKeys()
    }
    
    public func updateKey(_ identity: SSHKeyIdentity) throws {
        if let index = keys.firstIndex(where: { $0.id == identity.id }) {
            keys[index] = identity
            saveKeys()
        } else {
            throw SSHKeyVaultError.keyNotFound
        }
    }
    
    public func deleteKey(id: UUID) {
        guard let key = keys.first(where: { $0.id == id }) else { return }
        // Clean up secrets from Keychain
        try? KeychainStore.shared.delete(key: key.keychainPrivateKeyRef)
        if let passRef = key.keychainPassphraseRef {
            try? KeychainStore.shared.delete(key: passRef)
        }
        keys.removeAll(where: { $0.id == id })
        saveKeys()
    }
    
    public func key(for id: UUID) -> SSHKeyIdentity? {
        keys.first(where: { $0.id == id })
    }
    
    /// Imports a private/public key pair into the vault, storing sensitive private material in Keychain
    public func importKey(
        name: String,
        privateKeyPEM: String,
        publicKeyOpenSSH: String,
        passphrase: String? = nil
    ) throws -> SSHKeyIdentity {
        let cleanPriv = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPub = publicKeyOpenSSH.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPriv.isEmpty else { throw SSHKeyVaultError.privateKeyEmpty }
        guard !cleanPub.isEmpty else { throw SSHKeyVaultError.invalidPublicKey("公钥不能为空") }
        
        let fp = SSHKeyIdentity.computeFingerprint(from: cleanPub)
        if keys.contains(where: { $0.fingerprintSHA256 == fp }) {
            throw SSHKeyVaultError.duplicateKey(fp)
        }
        
        let id = UUID()
        let privRef = "vault.priv.\(id.uuidString)"
        var passRef: String? = nil
        
        try KeychainStore.shared.save(key: privRef, secret: cleanPriv)
        if let pass = passphrase, !pass.isEmpty {
            passRef = "vault.pass.\(id.uuidString)"
            try KeychainStore.shared.save(key: passRef!, secret: pass)
        }
        
        let algo = SSHKeyIdentity.detectAlgorithm(from: cleanPub)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = SSHKeyIdentity(
            id: id,
            name: cleanName.isEmpty ? "\(algo.rawValue) (\(fp.prefix(16)))" : cleanName,
            algorithm: algo,
            fingerprintSHA256: fp,
            publicKeyOpenSSH: cleanPub,
            keychainPrivateKeyRef: privRef,
            hasPassphrase: passRef != nil,
            keychainPassphraseRef: passRef,
            createdAt: Date()
        )
        
        try addKey(identity)
        return identity
    }
}
