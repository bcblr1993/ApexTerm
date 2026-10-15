import XCTest
@testable import ApexCore
@testable import ApexSSH

final class SSHTunnelTests: XCTestCase {
    private var tempDirectory: URL!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SSHTunnelTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    // MARK: - TC-TUN-01: Validation and Port Bounds
    func testTunnelValidationAndPortBounds() {
        let sid = UUID()
        
        // Valid local tunnel
        let validLocal = SSHTunnel(
            name: "MySQL Tunnel",
            type: .local,
            sessionId: sid,
            bindHost: "127.0.0.1",
            bindPort: 3306,
            targetHost: "10.0.0.5",
            targetPort: 3306
        )
        XCTAssertTrue(validLocal.isValid)
        
        // Invalid ports: 0, 65536, -5
        let invalidPort0 = SSHTunnel(name: "Bad Port 0", type: .local, sessionId: sid, bindPort: 0, targetPort: 80)
        XCTAssertFalse(invalidPort0.isValid)
        
        let invalidPort65536 = SSHTunnel(name: "Bad Port High", type: .local, sessionId: sid, bindPort: 8080, targetPort: 65536)
        XCTAssertFalse(invalidPort65536.isValid)
        
        let invalidPortNeg = SSHTunnel(name: "Bad Port Neg", type: .local, sessionId: sid, bindPort: -1, targetPort: 80)
        XCTAssertFalse(invalidPortNeg.isValid)
        
        // Valid dynamic SOCKS5 proxy
        let validDynamic = SSHTunnel(name: "SOCKS5 Proxy", type: .dynamic, sessionId: sid, bindHost: "127.0.0.1", bindPort: 1080)
        XCTAssertTrue(validDynamic.isValid)
    }
    
    // MARK: - TC-TUN-02: OpenSSH Specifier Generation
    func testOpenSSHSpecifiers() {
        let sid = UUID()
        
        let local = SSHTunnel(name: "Web Tunnel", type: .local, sessionId: sid, bindHost: "127.0.0.1", bindPort: 8080, targetHost: "10.1.1.1", targetPort: 80)
        XCTAssertEqual(local.openSSHSpecifier, "-L 127.0.0.1:8080:10.1.1.1:80")
        
        let remote = SSHTunnel(name: "Webhook Reverse", type: .remote, sessionId: sid, bindHost: "0.0.0.0", bindPort: 9000, targetHost: "127.0.0.1", targetPort: 3000)
        XCTAssertEqual(remote.openSSHSpecifier, "-R 0.0.0.0:9000:127.0.0.1:3000")
        
        let dynamic = SSHTunnel(name: "VPN SOCKS", type: .dynamic, sessionId: sid, bindHost: "127.0.0.1", bindPort: 7890)
        XCTAssertEqual(dynamic.openSSHSpecifier, "-D 127.0.0.1:7890")
    }
    
    // MARK: - TC-TUN-03: Persistence & CRUD Operations
    @MainActor
    func testTunnelManagerPersistenceAndCRUD() throws {
        let manager = SSHTunnelManager(baseDirectory: tempDirectory)
        XCTAssertTrue(manager.tunnels.isEmpty)
        
        let sid = UUID()
        let tunnel1 = SSHTunnel(name: "Redis Local", type: .local, sessionId: sid, bindPort: 6379, targetHost: "redis.internal", targetPort: 6379)
        let tunnel2 = SSHTunnel(name: "PostgreSQL Local", type: .local, sessionId: sid, bindPort: 5432, targetHost: "db.internal", targetPort: 5432)
        
        try manager.addTunnel(tunnel1)
        try manager.addTunnel(tunnel2)
        XCTAssertEqual(manager.tunnels.count, 2)
        
        // Reload from disk to assert persistence
        let reloaded = SSHTunnelManager(baseDirectory: tempDirectory)
        XCTAssertEqual(reloaded.tunnels.count, 2)
        XCTAssertEqual(reloaded.tunnels.first(where: { $0.id == tunnel1.id })?.name, "Redis Local")
        
        // Update tunnel
        var modified = tunnel1
        modified.name = "Redis Cluster Primary"
        try manager.updateTunnel(modified)
        XCTAssertEqual(manager.tunnels.first(where: { $0.id == tunnel1.id })?.name, "Redis Cluster Primary")
        
        // Delete tunnel
        manager.deleteTunnel(id: tunnel2.id)
        XCTAssertEqual(manager.tunnels.count, 1)
        XCTAssertNil(manager.tunnels.first(where: { $0.id == tunnel2.id }))
    }
    
    // MARK: - TC-TUN-04: Port Conflict Prevention
    @MainActor
    func testTunnelManagerPortConflictPrevention() throws {
        let manager = SSHTunnelManager(baseDirectory: tempDirectory)
        let sid = UUID()
        
        let t1 = SSHTunnel(name: "Tunnel 1", type: .local, sessionId: sid, bindHost: "127.0.0.1", bindPort: 8080, targetHost: "remote1", targetPort: 80)
        try manager.addTunnel(t1)
        
        let duplicate = SSHTunnel(name: "Tunnel Duplicate", type: .local, sessionId: sid, bindHost: "127.0.0.1", bindPort: 8080, targetHost: "remote2", targetPort: 80)
        XCTAssertThrowsError(try manager.addTunnel(duplicate)) { error in
            guard case SSHTunnelError.portConflict(let port) = error else {
                return XCTFail("Expected portConflict error, got \(error)")
            }
            XCTAssertEqual(port, 8080)
        }
    }
    
    // MARK: - TC-TUN-05: Command Line Argument Generation
    func testBuildSSHArguments() {
        let session = Session(name: "Prod", host: "1.2.3.4", port: 22022, username: "admin", authMethod: .agent)
        let tunnel = SSHTunnel(name: "API", type: .local, sessionId: session.id, bindHost: "127.0.0.1", bindPort: 8080, targetHost: "localhost", targetPort: 8080)
        
        let args = SSHTunnelManager.buildSSHArguments(tunnel: tunnel, session: session, privateKeyPath: "/tmp/id_ed25519")
        
        XCTAssertTrue(args.contains("-N"))
        XCTAssertTrue(args.contains("-T"))
        XCTAssertTrue(args.contains("-o"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("-L"))
        XCTAssertTrue(args.contains("127.0.0.1:8080:localhost:8080"))
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("/tmp/id_ed25519"))
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("22022"))
        XCTAssertTrue(args.contains("admin@1.2.3.4"))
    }
    
    // MARK: - TC-TUN-06: Lifecycle State Transitions
    @MainActor
    func testTunnelLifecycleStates() {
        let manager = SSHTunnelManager(baseDirectory: tempDirectory)
        let tid = UUID()
        
        XCTAssertEqual(manager.state(for: tid), .stopped)
        
        manager.setSimulatedState(id: tid, state: .starting)
        XCTAssertEqual(manager.state(for: tid), .starting)
        XCTAssertFalse(manager.state(for: tid).isRunning)
        
        manager.setSimulatedState(id: tid, state: .active)
        XCTAssertEqual(manager.state(for: tid), .active)
        XCTAssertTrue(manager.state(for: tid).isRunning)
        
        manager.setSimulatedState(id: tid, state: .failed("bind: Address already in use"))
        XCTAssertEqual(manager.state(for: tid), .failed("bind: Address already in use"))
        XCTAssertFalse(manager.state(for: tid).isRunning)
        
        manager.stopTunnel(id: tid)
        XCTAssertEqual(manager.state(for: tid), .stopped)
    }
    
    // MARK: - TC-TUN-07: Session Association and Filtering
    @MainActor
    func testSessionFiltering() throws {
        let manager = SSHTunnelManager(baseDirectory: tempDirectory)
        let sidA = UUID()
        let sidB = UUID()
        
        try manager.addTunnel(SSHTunnel(name: "A1", type: .local, sessionId: sidA, bindPort: 8001, targetPort: 80))
        try manager.addTunnel(SSHTunnel(name: "A2", type: .local, sessionId: sidA, bindPort: 8002, targetPort: 80))
        try manager.addTunnel(SSHTunnel(name: "B1", type: .local, sessionId: sidB, bindPort: 8003, targetPort: 80))
        
        let tunnelsA = manager.tunnels(for: sidA)
        let tunnelsB = manager.tunnels(for: sidB)
        
        XCTAssertEqual(tunnelsA.count, 2)
        XCTAssertEqual(tunnelsB.count, 1)
        XCTAssertEqual(tunnelsB.first?.name, "B1")
    }
    
    // MARK: - TC-TUN-08: AutoStart Configuration Persistence
    @MainActor
    func testAutoStartConfigurationPersistence() throws {
        let manager = SSHTunnelManager(baseDirectory: tempDirectory)
        let sid = UUID()
        let tunnel = SSHTunnel(name: "Auto Tunnel", type: .dynamic, sessionId: sid, bindPort: 1088, autoStart: true)
        
        try manager.addTunnel(tunnel)
        
        let reloaded = SSHTunnelManager(baseDirectory: tempDirectory)
        XCTAssertEqual(reloaded.tunnels.first?.autoStart, true)
    }
}
