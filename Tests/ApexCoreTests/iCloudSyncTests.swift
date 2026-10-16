import XCTest
@testable import ApexCore

final class iCloudSyncTests: XCTestCase {
    private var tempDirectory: URL!
    private var cloudDirectory: URL!
    
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "icloud.sync.conflictStrategy")
        UserDefaults.standard.removeObject(forKey: "icloud.sync.autoEnabled")
        let runId = UUID().uuidString
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("iCloudSyncTests_Local_\(runId)")
        cloudDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("iCloudSyncTests_Cloud_\(runId)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "icloud.sync.conflictStrategy")
        UserDefaults.standard.removeObject(forKey: "icloud.sync.autoEnabled")
        try? FileManager.default.removeItem(at: tempDirectory)
        try? FileManager.default.removeItem(at: cloudDirectory)
        super.tearDown()
    }
    
    // MARK: - TC-ICLOUD-01: Payload Serialization & JSON Roundtrip
    func testPayloadSerializationAndJSONRoundtrip() throws {
        let session = Session(name: "Cloud Gateway", host: "1.2.3.4", port: 22, username: "admin", authMethod: .agent)
        let snippet = Snippet(title: "Check Disk", command: "df -h", category: "系统")
        let trigger = Trigger(name: "Error Alert", regexPattern: "error", action: .highlight(colorHex: "#FF0000"))
        let bookmark = SFTPBookmark(name: "Web Root", path: "/var/www")
        let tunnel = SSHTunnel(name: "DB Tunnel", type: .local, sessionId: session.id, bindPort: 3306, targetPort: 3306)
        
        let payload = iCloudSyncPayload(
            version: 1,
            lastModified: Date(),
            deviceId: "mac-test-01",
            deviceName: "MacBook Pro",
            appVersion: "1.12.0",
            sessions: [session],
            snippets: [snippet],
            triggers: [trigger],
            bookmarks: [bookmark],
            tunnels: [tunnel]
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(iCloudSyncPayload.self, from: data)
        
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.deviceId, "mac-test-01")
        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.sessions.first?.name, "Cloud Gateway")
        XCTAssertEqual(decoded.snippets.count, 1)
        XCTAssertEqual(decoded.snippets.first?.title, "Check Disk")
        XCTAssertEqual(decoded.bookmarks.count, 1)
        XCTAssertEqual(decoded.bookmarks.first?.path, "/var/www")
        XCTAssertEqual(decoded.tunnels.count, 1)
        XCTAssertEqual(decoded.tunnels.first?.name, "DB Tunnel")
    }
    
    // MARK: - TC-ICLOUD-02: Zero-Bundle & Privacy Sanitization
    @MainActor
    func testZeroBundleAndPrivacySanitization() {
        let passwordSession = Session(
            name: "Secret Host",
            host: "secret.corp.com",
            port: 22,
            username: "root",
            authMethod: .password(keychainRef: "keychain_ref_uuid_123")
        )
        
        let rawPayload = iCloudSyncPayload(
            sessions: [passwordSession],
            snippets: [],
            triggers: [],
            bookmarks: [],
            tunnels: []
        )
        
        let sanitized = iCloudSyncManager.sanitizeForCloud(payload: rawPayload)
        
        // Assert password ref remains only a keychain reference, no plain passwords
        if case .password(let ref) = sanitized.sessions.first?.authMethod {
            XCTAssertEqual(ref, "keychain_ref_uuid_123")
            XCTAssertFalse(ref.contains("password123"))
        } else {
            XCTFail("Expected .password authMethod with reference")
        }
        
        // Assert that private keys are sanitized and do not contain raw PEM markers
        let keySession = Session(
            name: "Key Host",
            host: "key.corp.com",
            port: 22,
            username: "ubuntu",
            authMethod: .privateKey(keychainRef: "/Users/test/.ssh/id_rsa", passphraseRef: "pass_ref")
        )
        let sanitizedKeyPayload = iCloudSyncManager.sanitizeForCloud(
            payload: iCloudSyncPayload(sessions: [keySession], snippets: [], triggers: [], bookmarks: [], tunnels: [])
        )
        if case .privateKey(let keychainRef, _) = sanitizedKeyPayload.sessions.first?.authMethod {
            XCTAssertFalse(keychainRef.contains("BEGIN OPENSSH PRIVATE KEY"))
            XCTAssertFalse(keychainRef.contains("BEGIN RSA PRIVATE KEY"))
        }
    }
    
    // MARK: - TC-ICLOUD-03: Fresh First-time Upload to Cloud
    @MainActor
    func testFreshFirstTimeUploadToCloud() async throws {
        let backend = FileSystemCloudStorageBackend(cloudDirectory: cloudDirectory)
        let localStore = SessionStore(baseDirectory: tempDirectory)
        localStore.addSession(Session(name: "Node-1", host: "10.0.0.1", username: "root", authMethod: .agent))
        
        let manager = iCloudSyncManager(storageBackend: backend, sessionStore: localStore)
        XCTAssertEqual(manager.syncStatus, .idle(lastSyncDate: nil))
        
        let result = try await manager.syncNow()
        XCTAssertEqual(result.uploadedSessionsCount, 1)
        XCTAssertTrue(backend.isCloudAvailable())
        
        let cloudData = try backend.readPayloadData()
        XCTAssertNotNil(cloudData)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cloudPayload = try decoder.decode(iCloudSyncPayload.self, from: cloudData!)
        XCTAssertEqual(cloudPayload.sessions.count, 1)
        XCTAssertEqual(cloudPayload.sessions.first?.name, "Node-1")
    }
    
    // MARK: - TC-ICLOUD-04: Smart Bi-directional Merge without Data Loss
    @MainActor
    func testSmartBidirectionalMergeWithoutDataLoss() async throws {
        let backend = FileSystemCloudStorageBackend(cloudDirectory: cloudDirectory)
        
        // Machine A: Uploads Session A and Snippet A
        let storeA = SessionStore(baseDirectory: tempDirectory.appendingPathComponent("MacA"))
        storeA.addSession(Session(name: "Server-Mac-A", host: "10.0.0.10", username: "ubuntu", authMethod: .agent))
        storeA.addSnippet(Snippet(title: "Command-A", command: "ls -la", category: "通用"))
        let managerA = iCloudSyncManager(storageBackend: backend, sessionStore: storeA, deviceName: "MacBook Air")
        _ = try await managerA.syncNow()
        
        // Machine B: Has Session B and Snippet B locally
        let storeB = SessionStore(baseDirectory: tempDirectory.appendingPathComponent("MacB"))
        storeB.addSession(Session(name: "Server-Mac-B", host: "10.0.0.20", username: "deploy", authMethod: .agent))
        storeB.addSnippet(Snippet(title: "Command-B", command: "docker ps", category: "Docker"))
        let managerB = iCloudSyncManager(storageBackend: backend, sessionStore: storeB, deviceName: "Mac mini")
        
        // Machine B performs smart sync
        managerB.conflictStrategy = .smartMerge
        _ = try await managerB.syncNow()
        
        // Assert Machine B now has both Server-Mac-A and Server-Mac-B
        let sessionNamesB = storeB.sessions.map(\.name)
        XCTAssertTrue(sessionNamesB.contains("Server-Mac-A"))
        XCTAssertTrue(sessionNamesB.contains("Server-Mac-B"))
        
        let snippetTitlesB = storeB.snippets.map(\.title)
        XCTAssertTrue(snippetTitlesB.contains("Command-A"))
        XCTAssertTrue(snippetTitlesB.contains("Command-B"))
        
        // Machine A now syncs again and receives Machine B's items
        _ = try await managerA.syncNow()
        let sessionNamesA = storeA.sessions.map(\.name)
        XCTAssertTrue(sessionNamesA.contains("Server-Mac-A"))
        XCTAssertTrue(sessionNamesA.contains("Server-Mac-B"))
        XCTAssertEqual(storeA.sessions.count, 2)
    }
    
    // MARK: - TC-ICLOUD-05: Force Upload (Local Overwrites Cloud)
    @MainActor
    func testForceUploadLocalOverwritesCloud() async throws {
        let backend = FileSystemCloudStorageBackend(cloudDirectory: cloudDirectory)
        
        // Remote Cloud already has Old-Server
        let oldSession = Session(name: "Old-Server", host: "9.9.9.9", username: "old", authMethod: .agent)
        let initialPayload = iCloudSyncPayload(sessions: [oldSession])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try backend.writePayloadData(try encoder.encode(initialPayload))
        
        // Local only has New-Server
        let localStore = SessionStore(baseDirectory: tempDirectory)
        localStore.addSession(Session(name: "New-Server", host: "8.8.8.8", username: "new", authMethod: .agent))
        
        let manager = iCloudSyncManager(storageBackend: backend, sessionStore: localStore)
        manager.conflictStrategy = .overwriteCloud
        _ = try await manager.syncNow()
        
        // Cloud must now only contain New-Server
        let cloudData = try backend.readPayloadData()!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let updatedCloud = try decoder.decode(iCloudSyncPayload.self, from: cloudData)
        XCTAssertEqual(updatedCloud.sessions.count, 1)
        XCTAssertEqual(updatedCloud.sessions.first?.name, "New-Server")
    }
    
    // MARK: - TC-ICLOUD-06: Force Download (Cloud Overwrites Local)
    @MainActor
    func testForceDownloadCloudOverwritesLocal() async throws {
        let backend = FileSystemCloudStorageBackend(cloudDirectory: cloudDirectory)
        
        // Remote Cloud has Master-Server
        let masterSession = Session(name: "Master-Server", host: "1.1.1.1", username: "master", authMethod: .agent)
        let initialPayload = iCloudSyncPayload(sessions: [masterSession])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try backend.writePayloadData(try encoder.encode(initialPayload))
        
        // Local has Local-Scratch
        let localStore = SessionStore(baseDirectory: tempDirectory)
        localStore.addSession(Session(name: "Local-Scratch", host: "127.0.0.1", username: "dev", authMethod: .agent))
        XCTAssertEqual(localStore.sessions.count, 1)
        
        let manager = iCloudSyncManager(storageBackend: backend, sessionStore: localStore)
        manager.conflictStrategy = .overwriteLocal
        _ = try await manager.syncNow()
        
        // Local must now only have Master-Server
        XCTAssertEqual(localStore.sessions.count, 1)
        XCTAssertEqual(localStore.sessions.first?.name, "Master-Server")
    }
    
    // MARK: - TC-ICLOUD-07: Corrupted Cloud File Resilience & Atomic Backup
    @MainActor
    func testCorruptedCloudFileResilienceAndBackup() async throws {
        let backend = FileSystemCloudStorageBackend(cloudDirectory: cloudDirectory)
        
        // Write corrupted file in cloud
        try "{ corrupted data [[".data(using: .utf8)!.write(to: cloudDirectory.appendingPathComponent("cloud_vault.json"))
        
        let localStore = SessionStore(baseDirectory: tempDirectory)
        localStore.addSession(Session(name: "Safe-Session", host: "10.0.0.1", username: "safe", authMethod: .agent))
        
        let manager = iCloudSyncManager(storageBackend: backend, sessionStore: localStore)
        
        // Sync should safely report error or backup corrupted file without crashing
        do {
            _ = try await manager.syncNow()
            XCTFail("Should throw a decoded/corruption error when cloud payload is corrupt")
        } catch {
            XCTAssertTrue(error is iCloudSyncError)
        }
        
        // Local sessions must remain intact!
        XCTAssertEqual(localStore.sessions.count, 1)
        XCTAssertEqual(localStore.sessions.first?.name, "Safe-Session")
    }
    
    // MARK: - TC-ICLOUD-08: Status Transitions & Observable Feedback
    @MainActor
    func testStatusTransitionsAndObservableFeedback() async throws {
        let backend = FileSystemCloudStorageBackend(cloudDirectory: cloudDirectory)
        let localStore = SessionStore(baseDirectory: tempDirectory)
        let manager = iCloudSyncManager(storageBackend: backend, sessionStore: localStore)
        
        XCTAssertEqual(manager.syncStatus, .idle(lastSyncDate: nil))
        
        _ = try await manager.syncNow()
        
        if case .success(let date, let count) = manager.syncStatus {
            XCTAssertNotNil(date)
            XCTAssertGreaterThanOrEqual(count, 0)
        } else {
            XCTFail("Expected status to transition to .success, got: \(manager.syncStatus)")
        }
        
        XCTAssertNotNil(manager.lastSyncDate)
    }
}
