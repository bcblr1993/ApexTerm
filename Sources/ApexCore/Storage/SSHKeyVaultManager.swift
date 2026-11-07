import Foundation
import Darwin

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
        // Clean up secrets from Keychain and any materialized temporary key file
        try? KeychainStore.shared.delete(key: key.keychainPrivateKeyRef)
        if let passRef = key.keychainPassphraseRef {
            try? KeychainStore.shared.delete(key: passRef)
        }
        let tempKeyURL = Self.defaultMaterializedDirectory.appendingPathComponent("\(key.keychainPrivateKeyRef).key")
        try? fileManager.removeItem(at: tempKeyURL)
        keys.removeAll(where: { $0.id == id })
        saveKeys()
    }

    /// Restricted user-only temporary directory used to materialize Vault private keys for `/usr/bin/ssh`.
    nonisolated public static var defaultMaterializedDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("com.apexterm.vaultkeys.\(getuid())", isDirectory: true)
    }

    /// Materializes a Keychain-backed SSH Key Vault reference (`vault.priv.<UUID>`) into a `0600` local file
    /// with a guaranteed trailing newline so `/usr/bin/ssh` and `/usr/bin/scp` can authenticate with it.
    nonisolated public static func materializePrivateKeyPath(
        for reference: String,
        directory: URL? = nil,
        lookup: (String) -> String? = { try? KeychainStore.shared.getSync(key: $0) }
    ) -> String? {
        guard KeychainStore.isVaultPrivateKeyReference(reference),
              let rawPEM = lookup(reference)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPEM.isEmpty else {
            return nil
        }
        let dir = directory ?? defaultMaterializedDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(dir.path, 0o700)

        let fileURL = dir.appendingPathComponent("\(reference).key")
        let normalizedPEM = rawPEM + "\n"
        guard let data = normalizedPEM.data(using: .utf8) else { return nil }
        do {
            try data.write(to: fileURL, options: .atomic)
            _ = chmod(fileURL.path, 0o600)
            return fileURL.path
        } catch {
            return nil
        }
    }

    /// Removes all materialized temporary key files on application exit.
    nonisolated public static func cleanupMaterializedKeys(directory: URL? = nil) {
        let dir = directory ?? defaultMaterializedDirectory
        try? FileManager.default.removeItem(at: dir)
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
