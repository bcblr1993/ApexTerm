import XCTest
@testable import ApexCore

final class KeychainSecurityStoreTests: XCTestCase {
    private var testKeys: [String] = []
    private let store = KeychainStore()

    override func tearDown() {
        for key in testKeys {
            try? store.delete(key: key)
        }
        testKeys.removeAll()
        super.tearDown()
    }

    private func createTestKey() -> String {
        let key = "test_key_\(UUID().uuidString)"
        testKeys.append(key)
        return key
    }

    func testSaveAndRetrieveSecret() async throws {
        let key = createTestKey()
        let secret = "super-secret-password-12345!@#"

        try store.save(key: key, secret: secret)
        let retrieved = try await store.get(key: key, promptTouchID: false)
        XCTAssertEqual(retrieved, secret)
    }

    func testOverwriteExistingSecret() async throws {
        let key = createTestKey()
        let secretV1 = "initial-secret-v1"
        let secretV2 = "updated-secret-v2"

        try store.save(key: key, secret: secretV1)
        let firstGet = try await store.get(key: key, promptTouchID: false)
        XCTAssertEqual(firstGet, secretV1)

        // Overwrite
        try store.save(key: key, secret: secretV2)
        let secondGet = try await store.get(key: key, promptTouchID: false)
        XCTAssertEqual(secondGet, secretV2)
    }

    /// save() updates in place and reports the account it used; a legacy item created with
    /// another accessibility class is overwritten rather than duplicated.
    func testSaveUpdatesInPlaceAndReturnsAccount() async throws {
        let key = createTestKey()
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.apexterm.ssh.credentials",
            kSecAttrAccount as String: key,
            kSecValueData as String: Data("legacy-secret".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        XCTAssertEqual(SecItemAdd(legacy as CFDictionary, nil), errSecSuccess)

        XCTAssertEqual(try store.save(key: key, secret: "rotated-secret"), key)
        let retrieved = try await store.get(key: key, promptTouchID: false)
        XCTAssertEqual(retrieved, "rotated-secret")
        XCTAssertEqual(try store.save(key: key, secret: "rotated-again"), key)
        let again = try await store.get(key: key, promptTouchID: false)
        XCTAssertEqual(again, "rotated-again")
    }

    /// Items owned by the pre-rename ApexTerm.app cannot be modified; managed references then
    /// move to a fresh account with the same prefix, unmanaged ones fail loudly.
    func testReplacementReferenceForUnmodifiableItems() throws {
        let password = try XCTUnwrap(KeychainStore.replacementReference(for: "ssh_\(UUID().uuidString)"))
        XCTAssertTrue(password.hasPrefix("ssh_"))
        XCTAssertTrue(KeychainStore.isManagedReference(password))
        let passphrase = try XCTUnwrap(KeychainStore.replacementReference(for: "passphrase_\(UUID().uuidString)"))
        XCTAssertTrue(passphrase.hasPrefix("passphrase_"))
        XCTAssertTrue(KeychainStore.isManagedReference(passphrase))
        XCTAssertNil(KeychainStore.replacementReference(for: "vault.priv.\(UUID().uuidString)"))
        XCTAssertNil(KeychainStore.replacementReference(for: "legacy-inline-password"))
    }

    func testGetNonExistentSecretThrowsItemNotFound() async {
        let nonExistentKey = "non_existent_\(UUID().uuidString)"
        do {
            _ = try await store.get(key: nonExistentKey, promptTouchID: false)
            XCTFail("Expected KeychainError.itemNotFound but got success")
        } catch let error as KeychainError {
            switch error {
            case .itemNotFound:
                XCTAssertEqual(error.localizedDescription, "Keychain item not found")
            default:
                XCTFail("Expected .itemNotFound but got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testDeleteSecret() async throws {
        let key = createTestKey()
        let secret = "to-be-deleted"

        try store.save(key: key, secret: secret)
        let beforeDelete = try await store.get(key: key, promptTouchID: false)
        XCTAssertEqual(beforeDelete, secret)

        try store.delete(key: key)

        do {
            _ = try await store.get(key: key, promptTouchID: false)
            XCTFail("Expected itemNotFound after delete")
        } catch let error as KeychainError {
            if case .itemNotFound = error {
                // Expected
            } else {
                XCTFail("Expected .itemNotFound but got \(error)")
            }
        }
    }

    func testDeleteNonExistentSecretSucceeds() throws {
        let key = "not_existing_key_\(UUID().uuidString)"
        // Deleting non-existent key should not throw error
        XCTAssertNoThrow(try store.delete(key: key))
    }

    func testConcurrentKeychainAccess() async throws {
        let keys = (0..<10).map { _ in createTestKey() }
        let secrets = keys.map { "secret_for_\($0)" }
        let localStore = self.store

        // Concurrent writes
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<keys.count {
                let k = keys[i]
                let s = secrets[i]
                group.addTask {
                    try localStore.save(key: k, secret: s)
                }
            }
            try await group.waitForAll()
        }

        // Concurrent reads
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            for i in 0..<keys.count {
                let k = keys[i]
                group.addTask {
                    let val = try await localStore.get(key: k, promptTouchID: false)
                    return (k, val)
                }
            }

            for try await (k, val) in group {
                guard let idx = keys.firstIndex(of: k) else {
                    XCTFail("Unknown key returned: \(k)")
                    continue
                }
                XCTAssertEqual(val, secrets[idx])
            }
        }
    }

    func testKeychainErrorDescriptions() {
        let saveErr = KeychainError.saveFailed(-50)
        let readErr = KeychainError.readFailed(-25300)
        let delErr = KeychainError.deleteFailed(-25299)
        let notFoundErr = KeychainError.itemNotFound
        let bioErr = KeychainError.biometricAuthenticationFailed

        XCTAssertTrue(saveErr.localizedDescription.contains("-50"))
        XCTAssertTrue(readErr.localizedDescription.contains("-25300"))
        XCTAssertTrue(delErr.localizedDescription.contains("-25299"))
        XCTAssertEqual(notFoundErr.localizedDescription, "Keychain item not found")
        XCTAssertTrue(bioErr.localizedDescription.contains("Biometric"))
    }
}
