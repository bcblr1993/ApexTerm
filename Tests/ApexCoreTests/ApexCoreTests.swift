import XCTest
@testable import ApexCore

final class ApexCoreTests: XCTestCase {
    
    func testSessionEncodingDecoding() throws {
        let session = Session(
            name: "Test Server",
            host: "1.2.3.4",
            port: 2222,
            username: "admin",
            folder: "Testing",
            tags: ["tag1", "tag2"],
            colorHex: "#FF0000"
        )
        
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        
        XCTAssertEqual(session.id, decoded.id)
        XCTAssertEqual(session.name, decoded.name)
        XCTAssertEqual(session.host, decoded.host)
        XCTAssertEqual(session.port, decoded.port)
        XCTAssertEqual(session.username, decoded.username)
        XCTAssertEqual(session.folder, decoded.folder)
        XCTAssertEqual(session.tags, decoded.tags)
    }
    
    func testServerMetricsPercentages() {
        let snapshot = ServerMetricsSnapshot(
            cpuUsagePercent: 45.5,
            memoryTotalBytes: 16_000_000_000,
            memoryUsedBytes: 4_000_000_000,
            diskTotalBytes: 100_000_000_000,
            diskUsedBytes: 25_000_000_000
        )
        
        XCTAssertEqual(snapshot.cpuUsagePercent, 45.5)
        XCTAssertEqual(snapshot.memoryUsagePercent, 25.0)
        XCTAssertEqual(snapshot.diskUsagePercent, 25.0)
    }
    
    func testMetricsHistoryStoreMaxEntries() {
        let store = MetricsHistoryStore(maxEntries: 5)
        for i in 1...10 {
            store.append(ServerMetricsSnapshot(cpuUsagePercent: Double(i)))
        }
        
        let all = store.allSnapshots
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(store.latest?.cpuUsagePercent, 10.0)
        XCTAssertEqual(all.first?.cpuUsagePercent, 6.0)
    }
    
    func testSnippetInterpolation() {
        let snippet = Snippet(
            title: "Check Logs",
            command: "tail -f /var/log/app.log --host={{host}} --user={{user}}"
        )
        
        let resolved = snippet.resolvedCommand(context: [
            "host": "k8s-node-01",
            "user": "ubuntu"
        ])
        
        XCTAssertEqual(resolved, "tail -f /var/log/app.log --host=k8s-node-01 --user=ubuntu")
    }
    
    func testSFTPItemFormatting() {
        let file = SFTPItem(name: "test.zip", path: "/tmp/test.zip", isDirectory: false, size: 1024 * 1024 * 5)
        XCTAssertEqual(file.formattedSize, "5.0 MB")
        
        let dir = SFTPItem(name: "logs", path: "/var/logs", isDirectory: true)
        XCTAssertEqual(dir.formattedSize, "--")
    }
    
    func testSessionPasswordAuthMethod() throws {
        let session = Session(
            name: "VM Tart",
            host: "192.168.64.12",
            port: 22,
            username: "chenxu",
            authMethod: .password(keychainRef: "chenyn")
        )
        
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(session.authMethod, decoded.authMethod)
        if case .password(let ref) = decoded.authMethod {
            XCTAssertEqual(ref, "chenyn")
        } else {
            XCTFail("Decoded authMethod should be .password")
        }
    }
    
    func testL10nStrings() {
        XCTAssertFalse(L10n.newSessionTitle.isEmpty)
        XCTAssertFalse(L10n.authPassword.isEmpty)
        XCTAssertFalse(L10n.passwordLabel.isEmpty)
        XCTAssertEqual(L10n.passwordLabel, "登录密码")
    }
}
