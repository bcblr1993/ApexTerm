import XCTest
@testable import ApexCore

final class SessionStoreTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SessionStoreTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    @MainActor
    func testSessionCRUDAndPersistence() {
        let store = SessionStore(baseDirectory: tempDirectory)
        XCTAssertEqual(store.sessions.count, 0)
        
        // 1. Add session
        let session1 = Session(
            name: "Production Gateway",
            host: "192.168.10.1",
            port: 2222,
            username: "deploy",
            authMethod: .agent,
            folder: "Production",
            tags: ["prod", "gateway"]
        )
        store.addSession(session1)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].name, "Production Gateway")
        
        // 2. Add second session
        var session2 = Session(
            name: "Staging API",
            host: "10.0.0.5",
            port: 22,
            username: "ubuntu",
            authMethod: .password(keychainRef: "pass_ref_123"),
            folder: "Staging",
            tags: ["staging"]
        )
        store.addSession(session2)
        XCTAssertEqual(store.sessions.count, 2)
        
        // 3. Update session
        session2.port = 8022
        session2.tags.append("api")
        store.updateSession(session2)
        
        let updated = store.sessions.first(where: { $0.id == session2.id })
        XCTAssertEqual(updated?.port, 8022)
        XCTAssertTrue(updated?.tags.contains("api") == true)
        
        // 4. Persistence Reload Test
        let reloadedStore = SessionStore(baseDirectory: tempDirectory)
        XCTAssertEqual(reloadedStore.sessions.count, 2)
        XCTAssertEqual(reloadedStore.sessions.first(where: { $0.id == session2.id })?.port, 8022)
        
        // 5. Delete session
        store.deleteSession(id: session1.id)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].id, session2.id)
        
        let reloadedStoreAfterDelete = SessionStore(baseDirectory: tempDirectory)
        XCTAssertEqual(reloadedStoreAfterDelete.sessions.count, 1)
    }
    
    @MainActor
    func testDefaultTriggersSeeded() {
        let store = SessionStore(baseDirectory: tempDirectory)
        XCTAssertGreaterThanOrEqual(store.triggers.count, 3)
        let triggerNames = store.triggers.map { $0.name }
        XCTAssertTrue(triggerNames.contains("Error Highlighter"))
        XCTAssertTrue(triggerNames.contains("IP Address Highlighter"))
        XCTAssertTrue(triggerNames.contains("Success Highlighter"))
    }
    
    @MainActor
    func testCorruptedFileResilience() throws {
        // Write corrupted JSON to sessions.json
        let sessionsFile = tempDirectory.appendingPathComponent("sessions.json")
        try "{ corrupted json !! not valid [".write(to: sessionsFile, atomically: true, encoding: .utf8)
        
        // Should not crash and safely default to empty list
        let store = SessionStore(baseDirectory: tempDirectory)
        XCTAssertEqual(store.sessions.count, 0)
    }
}
