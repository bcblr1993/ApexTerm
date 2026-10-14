import XCTest
@testable import ApexCore

final class SessionTypeCompatibilityTests: XCTestCase {
    
    func testLegacySessionJSONDecodesAsSSHByDefault() throws {
        // Legacy JSON without "sessionType" field
        let legacyJSON = """
        {
            "id": "A1B2C3D4-E5F6-7A8B-9C0D-1E2F3A4B5C6D",
            "name": "Legacy Production Server",
            "host": "prod.example.com",
            "port": 22,
            "username": "deploy",
            "authMethod": { "agent": {} },
            "folder": "Production",
            "tags": ["prod", "web"],
            "colorHex": "#FF3B30",
            "agentlessMonitorEnabled": true,
            "sftpAutoSyncEnabled": true,
            "keepAliveIntervalSeconds": 30,
            "createdAt": 749000000
        }
        """
        
        let decoder = JSONDecoder()
        let data = legacyJSON.data(using: .utf8)!
        let session = try decoder.decode(Session.self, from: data)
        
        XCTAssertEqual(session.name, "Legacy Production Server")
        XCTAssertEqual(session.host, "prod.example.com")
        XCTAssertEqual(session.sessionType, .ssh)
        XCTAssertFalse(session.isLocal)
    }
    
    func testLocalSessionCreationAndRoundtrip() throws {
        let local = Session.local(name: "我的 Mac")
        XCTAssertEqual(local.sessionType, .local)
        XCTAssertTrue(local.isLocal)
        XCTAssertEqual(local.name, "我的 Mac")
        XCTAssertEqual(local.host, "localhost")
        XCTAssertEqual(local.port, 0)
        XCTAssertEqual(local.authMethod, .none)
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(local)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Session.self, from: data)
        
        XCTAssertEqual(decoded.id, local.id)
        XCTAssertEqual(decoded.sessionType, .local)
        XCTAssertTrue(decoded.isLocal)
        XCTAssertEqual(decoded.name, "我的 Mac")
        XCTAssertEqual(decoded.username, local.username)
    }
    
    @MainActor
    func testSessionStoreAddAndFilterLocalSession() {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test.sessions.local.type.\(UUID().uuidString)", isDirectory: true)
        let store = SessionStore(baseDirectory: tempDir)
        
        let local = Session.local()
        let remote = Session(name: "Remote Linux", host: "1.2.3.4", username: "root")
        
        store.addSession(local)
        store.addSession(remote)
        
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(store.sessions.contains(where: { $0.id == local.id && $0.isLocal }))
        XCTAssertTrue(store.sessions.contains(where: { $0.id == remote.id && !$0.isLocal }))
    }
}
