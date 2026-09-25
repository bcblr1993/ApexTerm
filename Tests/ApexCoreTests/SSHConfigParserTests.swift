import XCTest
@testable import ApexCore

final class SSHConfigParserTests: XCTestCase {
    
    func testParseBasicConfig() {
        let config = """
        # Global settings
        Host *
            ServerAliveInterval 60
            User root

        Host dev-box
            HostName 192.168.1.50
            User developer
            Port 2222
            IdentityFile ~/.ssh/id_ed25519

        Host staging prod-api
            HostName api.example.com
            User ops
            Port 22
        """
        
        let hosts = SSHConfigParser.parse(content: config)
        XCTAssertEqual(hosts.count, 3)
        
        // Host: dev-box
        let devBox = hosts.first(where: { $0.hostPattern == "dev-box" })
        XCTAssertNotNil(devBox)
        XCTAssertEqual(devBox?.hostName, "192.168.1.50")
        XCTAssertEqual(devBox?.user, "developer")
        XCTAssertEqual(devBox?.port, 2222)
        XCTAssertTrue(devBox?.identityFile?.hasSuffix("/.ssh/id_ed25519") == true)
        
        // Host: staging & prod-api (split pattern)
        let staging = hosts.first(where: { $0.hostPattern == "staging" })
        XCTAssertNotNil(staging)
        XCTAssertEqual(staging?.hostName, "api.example.com")
        XCTAssertEqual(staging?.user, "ops")
        XCTAssertEqual(staging?.port, 22)
        
        let prodApi = hosts.first(where: { $0.hostPattern == "prod-api" })
        XCTAssertNotNil(prodApi)
        XCTAssertEqual(prodApi?.hostName, "api.example.com")
    }
    
    func testParseEqualSignDelimiters() {
        let config = """
        Host web-server
            HostName=10.0.0.15
            User=admin
            Port=8022
        """
        let hosts = SSHConfigParser.parse(content: config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostPattern, "web-server")
        XCTAssertEqual(hosts[0].hostName, "10.0.0.15")
        XCTAssertEqual(hosts[0].user, "admin")
        XCTAssertEqual(hosts[0].port, 8022)
    }
    
    func testToSessionConversion() {
        let host = SSHConfigHost(
            hostPattern: "bastion",
            hostName: "bastion.internal",
            user: "jumpuser",
            port: 22,
            identityFile: "/Users/test/.ssh/id_rsa"
        )
        let session = host.toSession(folder: "CustomFolder")
        XCTAssertEqual(session.name, "bastion")
        XCTAssertEqual(session.host, "bastion.internal")
        XCTAssertEqual(session.username, "jumpuser")
        XCTAssertEqual(session.port, 22)
        XCTAssertEqual(session.folder, "CustomFolder")
        XCTAssertEqual(session.authMethod, .privateKey(keychainRef: "/Users/test/.ssh/id_rsa", passphraseRef: nil))
    }
}
