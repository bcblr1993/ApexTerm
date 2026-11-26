import Foundation
import Darwin

public enum SSHKeyVaultError: LocalizedError, Equatable {
    case duplicateKey(String)
    case invalidPublicKey(String)
    case keyNotFound
    case privateKeyEmpty
    case backupEmptyVault
    case invalidBackupEnvelope(String)
    case missingPrivateKeyMaterial(String)
    
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
        case .backupEmptyVault:
            return "当前密钥保险库为空，没有可导出的密钥"
        case .invalidBackupEnvelope(let reason):
            return reason
        case .missingPrivateKeyMaterial(let name):
            return "无法从钥匙串读取密钥「\(name)」的私钥内容"
        }
    }
}

/// Encrypted `.aetherkeyvault` backup envelope wrapping PBKDF2 + AES-GCM `AetherShareEnvelope`.
public struct AetherKeyVaultBackupEnvelope: Codable, Sendable, Equatable {
    public static let magic = "AETHERKEYVAULT"
    public static let currentFormatVersion = 1

    public var magic: String
    public var formatVersion: Int
    public var exportedAt: Date
    public var exportedByAppVersion: String
    public var keyCount: Int
    public var keyNames: [String]
    public var encryptedEnvelope: AetherShareEnvelope

    public init(
        magic: String = AetherKeyVaultBackupEnvelope.magic,
        formatVersion: Int = AetherKeyVaultBackupEnvelope.currentFormatVersion,
        exportedAt: Date = Date(),
        exportedByAppVersion: String = Bundle.apexResolvedAppVersion,
        keyCount: Int,
        keyNames: [String],
        encryptedEnvelope: AetherShareEnvelope
    ) {
        self.magic = magic
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.exportedByAppVersion = exportedByAppVersion
        self.keyCount = keyCount
        self.keyNames = keyNames
        self.encryptedEnvelope = encryptedEnvelope
    }
}

/// Result returned when restoring keys from an encrypted `.aetherkeyvault` backup.
public struct KeyVaultBackupImportReport: Sendable, Equatable {
    public let importedCount: Int
    public let skippedDuplicateCount: Int
    public let importedKeyNames: [String]

    public init(importedCount: Int, skippedDuplicateCount: Int, importedKeyNames: [String]) {
        self.importedCount = importedCount
        self.skippedDuplicateCount = skippedDuplicateCount
        self.importedKeyNames = importedKeyNames
    }

    public var summaryText: String {
        "已恢复 \(importedCount) 把密钥（跳过重复 \(skippedDuplicateCount) 把）"
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

    /// Writes sensitive private key bytes to `fileURL` via an exclusive `0o600` temp file and atomic `rename`.
    nonisolated public static func writePrivateKeyFileAtomically(_ data: Data, to fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(dir.path, 0o700)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let tempURL = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        var createdTemp = false
        do {
            let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            createdTemp = true
            do {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: data)
            }
            guard rename(tempURL.path, fileURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            createdTemp = false
            _ = chmod(fileURL.path, 0o600)
        } catch {
            if createdTemp {
                try? FileManager.default.removeItem(at: tempURL)
            }
            throw error
        }
    }

    /// Materializes a Keychain-backed SSH Key Vault reference (`vault.priv.<UUID>`) into a `0600` local file
    /// with a guaranteed trailing newline so `/usr/bin/ssh` and `/usr/bin/scp` can authenticate with it.
    nonisolated public static func materializePrivateKeyPath(
        for reference: String,
        directory: URL? = nil,
        lookup: (String) -> String? = { try? KeychainStore.shared.getSync(key: $0) }
    ) -> String? {
        guard KeychainStore.isVaultPrivateKeyReference(reference),
              let rawPEM = lookup(reference)?
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPEM.isEmpty else {
            return nil
        }
        let dir = directory ?? defaultMaterializedDirectory
        let fileURL = dir.appendingPathComponent("\(reference).key")
        let normalizedPEM = rawPEM + "\n"
        guard let data = normalizedPEM.data(using: .utf8) else { return nil }
        do {
            try writePrivateKeyFileAtomically(data, to: fileURL)
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

    /// Purges leftover materialized key files at launch (alias of `cleanupMaterializedKeys`).
    nonisolated public static func cleanupStaleMaterializedKeys(directory: URL? = nil) {
        cleanupMaterializedKeys(directory: directory)
    }
    
    public func key(for id: UUID) -> SSHKeyIdentity? {
        keys.first(where: { $0.id == id })
    }
    
    /// Imports a private/public key pair into the vault, storing sensitive private material in Keychain
    /// and rolling back saved Keychain entries if any subsequent step fails.
    public func importKey(
        name: String,
        privateKeyPEM: String,
        publicKeyOpenSSH: String,
        passphrase: String? = nil,
        secretSaver: (String, String) throws -> String = { try KeychainStore.shared.save(key: $0, secret: $1) },
        secretDeleter: (String) -> Void = { try? KeychainStore.shared.delete(key: $0) }
    ) throws -> SSHKeyIdentity {
        let cleanPriv = privateKeyPEM
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPub = publicKeyOpenSSH.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPriv.isEmpty else { throw SSHKeyVaultError.privateKeyEmpty }
        guard !cleanPub.isEmpty else { throw SSHKeyVaultError.invalidPublicKey("公钥不能为空") }
        let pubParts = cleanPub.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard pubParts.count >= 2, Data(base64Encoded: pubParts[1]) != nil else {
            throw SSHKeyVaultError.invalidPublicKey("需要有效的 OpenSSH 公钥格式（如 ssh-ed25519 AAAA...）")
        }
        
        let fp = SSHKeyIdentity.computeFingerprint(from: cleanPub)
        if keys.contains(where: { $0.fingerprintSHA256 == fp }) {
            throw SSHKeyVaultError.duplicateKey(fp)
        }
        
        let id = UUID()
        let savedPrivRef = try secretSaver("vault.priv.\(id.uuidString)", cleanPriv)
        var savedPassRef: String? = nil
        
        do {
            if let pass = passphrase, !pass.isEmpty {
                savedPassRef = try secretSaver("vault.pass.\(id.uuidString)", pass)
            }
            
            let algo = SSHKeyIdentity.detectAlgorithm(from: cleanPub)
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = SSHKeyIdentity(
                id: id,
                name: cleanName.isEmpty ? "\(algo.rawValue) (\(fp.prefix(16)))" : cleanName,
                algorithm: algo,
                fingerprintSHA256: fp,
                publicKeyOpenSSH: cleanPub,
                keychainPrivateKeyRef: savedPrivRef,
                hasPassphrase: savedPassRef != nil,
                keychainPassphraseRef: savedPassRef,
                createdAt: Date()
            )
            
            try addKey(identity)
            return identity
        } catch {
            secretDeleter(savedPrivRef)
            if let passRef = savedPassRef {
                secretDeleter(passRef)
            }
            throw error
        }
    }

    // MARK: - Passphrase-Encrypted Vault Backup (.aetherkeyvault)

    /// Exports all vault keys (including private key PEM and optional passphrase from Keychain)
    /// into a passphrase-encrypted `.aetherkeyvault` bundle powered by `SharePackCrypto` (PBKDF2 + AES-GCM).
    public func exportEncryptedVaultBackup(
        passphrase: String,
        secretReader: (String) throws -> String = { try KeychainStore.shared.getSync(key: $0) }
    ) throws -> Data {
        guard !keys.isEmpty else {
            throw SSHKeyVaultError.backupEmptyVault
        }
        let cleanPassphrase = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPassphrase.isEmpty else {
            throw SharePackCryptoError.emptyPassphraseNotAllowed
        }

        var records: [SharePackVaultKeyRecord] = []
        records.reserveCapacity(keys.count)

        for key in keys {
            let privatePEM: String
            do {
                privatePEM = try secretReader(key.keychainPrivateKeyRef)
            } catch {
                throw SSHKeyVaultError.missingPrivateKeyMaterial(key.name)
            }
            guard !privatePEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SSHKeyVaultError.missingPrivateKeyMaterial(key.name)
            }

            var keyPassphrase: String? = nil
            if let passRef = key.keychainPassphraseRef, !passRef.isEmpty {
                keyPassphrase = try? secretReader(passRef)
            }

            records.append(SharePackVaultKeyRecord(
                originalPrivateKeyRef: key.keychainPrivateKeyRef,
                name: key.name,
                publicKeyOpenSSH: key.publicKeyOpenSSH,
                privateKeyPEM: privatePEM,
                passphrase: keyPassphrase
            ))
        }

        let bundle = SharePackSecretBundle(
            pack: AetherSharePack(),
            credentials: SharePackCredentialPayload(embeddedVaultKeys: records)
        )
        let header = AetherShareEnvelopeHeader(
            groupNames: ["SSH Key Vault"],
            sessionCount: 0,
            tunnelCount: 0,
            includesCredentials: true
        )
        let encryptedEnvelope = try SharePackCrypto.encryptBundle(
            bundle,
            mode: .passphrase,
            passphrase: passphrase,
            header: header
        )

        let backupEnvelope = AetherKeyVaultBackupEnvelope(
            keyCount: records.count,
            keyNames: records.map(\.name),
            encryptedEnvelope: encryptedEnvelope
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backupEnvelope)
    }

    /// Inspects an unencrypted backup header to show key count/names before asking for the passphrase.
    public static func inspectEncryptedVaultBackup(_ data: Data) throws -> AetherKeyVaultBackupEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: AetherKeyVaultBackupEnvelope
        do {
            envelope = try decoder.decode(AetherKeyVaultBackupEnvelope.self, from: data)
        } catch {
            throw SSHKeyVaultError.invalidBackupEnvelope("备份文件格式损坏或不是有效的 .aetherkeyvault 文件：\(error.localizedDescription)")
        }
        guard envelope.magic == AetherKeyVaultBackupEnvelope.magic else {
            throw SSHKeyVaultError.invalidBackupEnvelope("文件标识无效，不是有效的 AetherTerm 密钥库备份 (.aetherkeyvault)。")
        }
        guard envelope.formatVersion > 0 && envelope.formatVersion <= AetherKeyVaultBackupEnvelope.currentFormatVersion else {
            throw SharePackCryptoError.unsupportedFormatVersion(envelope.formatVersion)
        }
        return envelope
    }

    /// Decrypts a `.aetherkeyvault` backup with the supplied passphrase and imports non-duplicate keys into the vault.
    @discardableResult
    public func importEncryptedVaultBackup(
        _ data: Data,
        passphrase: String,
        secretSaver: (String, String) throws -> String = { try KeychainStore.shared.save(key: $0, secret: $1) },
        secretDeleter: (String) -> Void = { try? KeychainStore.shared.delete(key: $0) }
    ) throws -> KeyVaultBackupImportReport {
        let backupEnvelope = try Self.inspectEncryptedVaultBackup(data)
        guard backupEnvelope.encryptedEnvelope.protectionMode == .passphrase else {
            throw SSHKeyVaultError.invalidBackupEnvelope("密钥库备份必须使用口令加密保护。")
        }

        let decryptedBundle = try SharePackCrypto.decryptEnvelope(
            backupEnvelope.encryptedEnvelope,
            passphrase: passphrase
        )

        var importedCount = 0
        var skippedDuplicateCount = 0
        var importedNames: [String] = []

        for record in decryptedBundle.credentials.embeddedVaultKeys {
            do {
                let imported = try importKey(
                    name: record.name,
                    privateKeyPEM: record.privateKeyPEM,
                    publicKeyOpenSSH: record.publicKeyOpenSSH,
                    passphrase: record.passphrase,
                    secretSaver: secretSaver,
                    secretDeleter: secretDeleter
                )
                importedCount += 1
                importedNames.append(imported.name)
            } catch SSHKeyVaultError.duplicateKey {
                skippedDuplicateCount += 1
            }
        }

        return KeyVaultBackupImportReport(
            importedCount: importedCount,
            skippedDuplicateCount: skippedDuplicateCount,
            importedKeyNames: importedNames
        )
    }
}
