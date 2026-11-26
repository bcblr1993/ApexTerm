import Foundation
import CryptoKit
import CommonCrypto
import Security

public extension Bundle {
    /// Resolves the running AetherTerm app's marketing version from `CFBundleShortVersionString`,
    /// falling back to the current release baseline only in non-bundled test runners.
    static var apexResolvedAppVersion: String {
        if let bundleId = main.bundleIdentifier,
           bundleId.lowercased().contains("apexterm"),
           let ver = main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let trimmed = ver.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "1.30.0"
    }
}

/// Protection mode applied when exporting an `.aetherpack` share bundle.
public enum SharePackProtectionMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Sealed with AES-256-GCM + HKDF-SHA256 using an app-embedded key without a user passphrase.
    /// Prevents plaintext casual reading while supporting one-click import inside AetherTerm;
    /// public or cross-team distribution MUST use `.passphrase` with an independent passphrase.
    case appSealed = "app_sealed"
    /// Encrypted with AES-256-GCM + PBKDF2-HMAC-SHA256 using an explicit share passphrase.
    case passphrase = "passphrase"
    /// Zero-credential metadata only (`plainPack` without passwords, passphrases, or vault keys).
    case zeroCredential = "zero_credential"
}

/// Errors raised while encrypting, inspecting, or decrypting `.aetherpack` share bundles.
public enum SharePackCryptoError: LocalizedError, Sendable, Equatable {
    case passphraseRequired
    case invalidPassphrase
    case emptyPassphraseNotAllowed
    case invalidEnvelope(String)
    case unsupportedFormatVersion(Int)
    case encryptionFailed

    public var errorDescription: String? {
        switch self {
        case .passphraseRequired:
            return "该分享包已启用口令加密，请输入分享口令后解密导入。"
        case .invalidPassphrase:
            return "分享口令不正确，或分享包内容已被篡改。"
        case .emptyPassphraseNotAllowed:
            return "启用口令保护时，分享口令不能为空。"
        case .invalidEnvelope(let reason):
            return reason
        case .unsupportedFormatVersion(let version):
            return "当前版本的 AetherTerm 暂不支持此分享包格式（v\(version)），请更新应用后重试。"
        case .encryptionFailed:
            return "生成加密分享包失败，请重试。"
        }
    }
}

/// Key Vault private key material bundled inside an encrypted share payload.
public struct SharePackVaultKeyRecord: Codable, Sendable, Equatable {
    public var originalPrivateKeyRef: String
    public var name: String
    public var publicKeyOpenSSH: String
    public var privateKeyPEM: String
    public var passphrase: String?

    public init(
        originalPrivateKeyRef: String,
        name: String,
        publicKeyOpenSSH: String,
        privateKeyPEM: String,
        passphrase: String? = nil
    ) {
        self.originalPrivateKeyRef = originalPrivateKeyRef
        self.name = name
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.privateKeyPEM = privateKeyPEM
        self.passphrase = passphrase
    }
}

/// Credentials and key material sealed inside a v2 `.aetherpack` payload.
/// Maps secrets by the exported session UUID or original vault reference so they are
/// isolated in the encrypted ciphertext and materialized into fresh local Keychain entries on import.
public struct SharePackCredentialPayload: Codable, Sendable, Equatable {
    public var sessionPasswords: [UUID: String]
    public var sessionPassphrases: [UUID: String]
    public var sessionVaultKeyRefs: [UUID: String]
    public var sessionPrivateKeysPEM: [UUID: String]
    public var embeddedVaultKeys: [SharePackVaultKeyRecord]

    public init(
        sessionPasswords: [UUID: String] = [:],
        sessionPassphrases: [UUID: String] = [:],
        sessionVaultKeyRefs: [UUID: String] = [:],
        sessionPrivateKeysPEM: [UUID: String] = [:],
        embeddedVaultKeys: [SharePackVaultKeyRecord] = []
    ) {
        self.sessionPasswords = sessionPasswords
        self.sessionPassphrases = sessionPassphrases
        self.sessionVaultKeyRefs = sessionVaultKeyRefs
        self.sessionPrivateKeysPEM = sessionPrivateKeysPEM
        self.embeddedVaultKeys = embeddedVaultKeys
    }

    public var hasAnySecret: Bool {
        !sessionPasswords.isEmpty
            || !sessionPassphrases.isEmpty
            || !sessionPrivateKeysPEM.isEmpty
            || !embeddedVaultKeys.isEmpty
    }

    public func hasCredential(for sessionID: UUID) -> Bool {
        if let pw = sessionPasswords[sessionID], !pw.isEmpty { return true }
        if let pass = sessionPassphrases[sessionID], !pass.isEmpty { return true }
        if let pem = sessionPrivateKeysPEM[sessionID], !pem.isEmpty { return true }
        if let vaultRef = sessionVaultKeyRefs[sessionID],
           embeddedVaultKeys.contains(where: { $0.originalPrivateKeyRef == vaultRef }) {
            return true
        }
        return false
    }
}

/// Combined payload sealed inside an `AetherShareEnvelope`.
public struct SharePackSecretBundle: Codable, Sendable, Equatable {
    public var pack: AetherSharePack
    public var credentials: SharePackCredentialPayload

    public init(pack: AetherSharePack, credentials: SharePackCredentialPayload = SharePackCredentialPayload()) {
        self.pack = pack
        self.credentials = credentials
    }
}

/// Unencrypted summary header allowing the import wizard to describe a share package
/// (group names, session counts, protection status) before asking for a passphrase.
public struct AetherShareEnvelopeHeader: Codable, Sendable, Equatable {
    public var groupNames: [String]
    public var sessionCount: Int
    public var tunnelCount: Int
    public var includesCredentials: Bool
    public var exportedByAppVersion: String
    public var exportedAt: Date

    public init(
        groupNames: [String] = [],
        sessionCount: Int = 0,
        tunnelCount: Int = 0,
        includesCredentials: Bool = false,
        exportedByAppVersion: String = Bundle.apexResolvedAppVersion,
        exportedAt: Date = Date()
    ) {
        self.groupNames = groupNames
        self.sessionCount = sessionCount
        self.tunnelCount = tunnelCount
        self.includesCredentials = includesCredentials
        self.exportedByAppVersion = exportedByAppVersion
        self.exportedAt = exportedAt
    }
}

/// Ciphertext container stored inside `AetherShareEnvelope`.
public struct EncryptedShareBlob: Codable, Sendable, Equatable {
    public var kdf: String
    public var iterations: Int
    public var saltBase64: String
    public var nonceBase64: String
    public var ciphertextBase64: String
    public var tagBase64: String

    public init(
        kdf: String,
        iterations: Int,
        saltBase64: String,
        nonceBase64: String,
        ciphertextBase64: String,
        tagBase64: String
    ) {
        self.kdf = kdf
        self.iterations = iterations
        self.saltBase64 = saltBase64
        self.nonceBase64 = nonceBase64
        self.ciphertextBase64 = ciphertextBase64
        self.tagBase64 = tagBase64
    }
}

/// Self-describing v2 `.aetherpack` file format supporting app-sealed credential packages,
/// passphrase-encrypted packages, and zero-credential team bundles.
public struct AetherShareEnvelope: Codable, Sendable, Equatable {
    public static let magic = "AETHERPACK"
    public static let currentEnvelopeVersion = 2

    public var magic: String
    public var envelopeVersion: Int
    public var protectionMode: SharePackProtectionMode
    public var header: AetherShareEnvelopeHeader
    public var plainPack: AetherSharePack?
    public var encryptedPayload: EncryptedShareBlob?

    public init(
        magic: String = AetherShareEnvelope.magic,
        envelopeVersion: Int = AetherShareEnvelope.currentEnvelopeVersion,
        protectionMode: SharePackProtectionMode,
        header: AetherShareEnvelopeHeader,
        plainPack: AetherSharePack? = nil,
        encryptedPayload: EncryptedShareBlob? = nil
    ) {
        self.magic = magic
        self.envelopeVersion = envelopeVersion
        self.protectionMode = protectionMode
        self.header = header
        self.plainPack = plainPack
        self.encryptedPayload = encryptedPayload
    }
}

/// AES-256-GCM + HKDF-SHA256 / PBKDF2-HMAC-SHA256 cryptographic engine for `.aetherpack` share files.
public enum SharePackCrypto {
    public static let pbkdf2Iterations: Int = 200_000
    private static let saltByteCount = 16
    private static let appSealInfo = Data("com.apexterm.aetherpack.v2.app-sealed".utf8)
    private static let appSealIKMSeed = Data("com.apexterm.sharepack.appseal.v2.keymaterial".utf8)
    private static let passphraseAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789")

    /// Encrypts or wraps a `SharePackSecretBundle` according to `mode`.
    public static func encryptBundle(
        _ bundle: SharePackSecretBundle,
        mode: SharePackProtectionMode,
        passphrase: String?,
        header: AetherShareEnvelopeHeader
    ) throws -> AetherShareEnvelope {
        let sanitizedPack = SessionBundleExporter.sanitizePack(bundle.pack)

        switch mode {
        case .zeroCredential:
            return AetherShareEnvelope(
                protectionMode: .zeroCredential,
                header: header,
                plainPack: sanitizedPack,
                encryptedPayload: nil
            )

        case .appSealed, .passphrase:
            let normalizedBundle = SharePackSecretBundle(pack: sanitizedPack, credentials: bundle.credentials)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var plaintext = try encoder.encode(normalizedBundle)
            defer { zeroData(&plaintext) }

            let salt = try randomBytes(count: saltByteCount)
            let (key, kdfName, iterations): (SymmetricKey, String, Int)
            if mode == .appSealed {
                key = deriveAppSealedKey(salt: salt)
                kdfName = "hkdf-sha256"
                iterations = 1
            } else {
                guard let pass = passphrase, !pass.isEmpty else {
                    throw SharePackCryptoError.emptyPassphraseNotAllowed
                }
                key = try derivePBKDF2Key(passphrase: pass, salt: salt, iterations: pbkdf2Iterations)
                kdfName = "pbkdf2-hmac-sha256"
                iterations = pbkdf2Iterations
            }

            let aad = authenticatedData(
                magic: AetherShareEnvelope.magic,
                envelopeVersion: AetherShareEnvelope.currentEnvelopeVersion,
                mode: mode
            )
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
            let blob = EncryptedShareBlob(
                kdf: kdfName,
                iterations: iterations,
                saltBase64: salt.base64EncodedString(),
                nonceBase64: Data(nonce).base64EncodedString(),
                ciphertextBase64: sealed.ciphertext.base64EncodedString(),
                tagBase64: sealed.tag.base64EncodedString()
            )
            return AetherShareEnvelope(
                protectionMode: mode,
                header: header,
                plainPack: nil,
                encryptedPayload: blob
            )
        }
    }

    /// Decrypts or unwraps an `AetherShareEnvelope` into a verified `SharePackSecretBundle`.
    public static func decryptEnvelope(
        _ envelope: AetherShareEnvelope,
        passphrase: String?
    ) throws -> SharePackSecretBundle {
        guard envelope.magic == AetherShareEnvelope.magic else {
            throw SharePackCryptoError.invalidEnvelope("文件头标识无效，不是有效的 AetherTerm 分享包。")
        }
        guard envelope.envelopeVersion > 0 && envelope.envelopeVersion <= AetherShareEnvelope.currentEnvelopeVersion else {
            throw SharePackCryptoError.unsupportedFormatVersion(envelope.envelopeVersion)
        }

        switch envelope.protectionMode {
        case .zeroCredential:
            guard let plainPack = envelope.plainPack else {
                throw SharePackCryptoError.invalidEnvelope("零凭据分享包缺少会话数据。")
            }
            return SharePackSecretBundle(
                pack: SessionBundleExporter.sanitizePack(plainPack),
                credentials: SharePackCredentialPayload()
            )

        case .appSealed, .passphrase:
            guard let blob = envelope.encryptedPayload,
                  let salt = Data(base64Encoded: blob.saltBase64),
                  salt.count >= 8,
                  let nonceData = Data(base64Encoded: blob.nonceBase64),
                  let ciphertext = Data(base64Encoded: blob.ciphertextBase64),
                  let tag = Data(base64Encoded: blob.tagBase64) else {
                throw SharePackCryptoError.invalidEnvelope("加密分享包数据损坏或不完整。")
            }

            let key: SymmetricKey
            if envelope.protectionMode == .appSealed {
                guard blob.kdf == "hkdf-sha256" else {
                    throw SharePackCryptoError.invalidEnvelope("不支持的密钥派生方式：\(blob.kdf)")
                }
                key = deriveAppSealedKey(salt: salt)
            } else {
                guard let pass = passphrase, !pass.isEmpty else {
                    throw SharePackCryptoError.passphraseRequired
                }
                guard blob.kdf == "pbkdf2-hmac-sha256",
                      blob.iterations >= 10_000,
                      blob.iterations <= 2_000_000 else {
                    throw SharePackCryptoError.invalidEnvelope("分享包口令派生参数异常。")
                }
                key = try derivePBKDF2Key(passphrase: pass, salt: salt, iterations: blob.iterations)
            }

            let aad = authenticatedData(
                magic: envelope.magic,
                envelopeVersion: envelope.envelopeVersion,
                mode: envelope.protectionMode
            )

            var plaintext: Data
            do {
                let nonce = try AES.GCM.Nonce(data: nonceData)
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
                plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
            } catch {
                if envelope.protectionMode == .passphrase {
                    throw SharePackCryptoError.invalidPassphrase
                }
                throw SharePackCryptoError.invalidEnvelope("分享包解密失败或内容已损坏。")
            }
            defer { zeroData(&plaintext) }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(SharePackSecretBundle.self, from: plaintext)
            return SharePackSecretBundle(
                pack: SessionBundleExporter.sanitizePack(decoded.pack),
                credentials: decoded.credentials
            )
        }
    }

    /// Generates an easy-to-read random share passphrase formatted into 4-character groups.
    public static func generateReadablePassphrase(length: Int = 12) -> String {
        let clampedLength = max(8, length)
        let alphabetCount = passphraseAlphabet.count
        let rejectionLimit = (256 / alphabetCount) * alphabetCount
        var chars: [Character] = []
        chars.reserveCapacity(clampedLength)

        var randomByte: UInt8 = 0
        while chars.count < clampedLength {
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &randomByte)
            let byteValue: UInt8 = status == errSecSuccess ? randomByte : UInt8.random(in: 0...255)
            guard Int(byteValue) < rejectionLimit else { continue }
            chars.append(passphraseAlphabet[Int(byteValue) % alphabetCount])
        }

        var groups: [String] = []
        var index = 0
        while index < chars.count {
            let end = min(index + 4, chars.count)
            groups.append(String(chars[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }

    // MARK: - Private Key Derivation & Memory Hygiene

    private static func authenticatedData(
        magic: String,
        envelopeVersion: Int,
        mode: SharePackProtectionMode
    ) -> Data {
        Data("\(magic):\(envelopeVersion):\(mode.rawValue)".utf8)
    }

    private static func deriveAppSealedKey(salt: Data) -> SymmetricKey {
        let ikmDigest = SHA256.hash(data: appSealIKMSeed)
        let ikm = SymmetricKey(data: ikmDigest)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: appSealInfo,
            outputByteCount: 32
        )
    }

    private static func derivePBKDF2Key(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var passwordBytes = Array(passphrase.utf8)
        var derivedBytes = [UInt8](repeating: 0, count: 32)
        defer {
            passwordBytes.withUnsafeMutableBytes { buf in
                if let base = buf.baseAddress { memset(base, 0, buf.count) }
            }
            derivedBytes.withUnsafeMutableBytes { buf in
                if let base = buf.baseAddress { memset(base, 0, buf.count) }
            }
        }

        let status = passwordBytes.withUnsafeBytes { passRaw in
            salt.withUnsafeBytes { saltRaw in
                let passPtr = passRaw.bindMemory(to: Int8.self).baseAddress
                let saltPtr = saltRaw.bindMemory(to: UInt8.self).baseAddress
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr,
                    passwordBytes.count,
                    saltPtr,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derivedBytes,
                    derivedBytes.count
                )
            }
        }

        guard status == kCCSuccess else {
            throw SharePackCryptoError.encryptionFailed
        }
        return SymmetricKey(data: derivedBytes)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw SharePackCryptoError.encryptionFailed
        }
        return bytes
    }

    private static func zeroData(_ data: inout Data) {
        data.withUnsafeMutableBytes { buf in
            if let base = buf.baseAddress {
                memset(base, 0, buf.count)
            }
        }
        data = Data()
    }
}
