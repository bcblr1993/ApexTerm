import XCTest
@testable import ApexCore

final class SSHConfigParserEdgeCaseTests: XCTestCase {
    
    /// Test 1: Quoted paths with spaces and tabs
    func testQuotedPathsWithSpacesAndTabs() {
        let config = """
        \tHost\t  "cluster master"
        \t\tHostName\t  "10.240.0.10"
        \t\tUser\t  'kube admin'
        \t\tIdentityFile\t  "~/My Keys/Enterprise Cluster.pem"
        \t\tPort\t  2202
        """
        
        let hosts = SSHConfigParser.parse(content: config)
        XCTAssertEqual(hosts.count, 1)
        
        let master = hosts[0]
        XCTAssertEqual(master.hostPattern, "cluster master")
        XCTAssertEqual(master.hostName, "10.240.0.10")
        XCTAssertEqual(master.user, "kube admin")
        XCTAssertEqual(master.port, 2202)
        XCTAssertTrue(master.identityFile?.contains("/My Keys/Enterprise Cluster.pem") == true)
        
        let session = master.toSession()
        XCTAssertEqual(session.name, "cluster master")
        XCTAssertEqual(session.host, "10.240.0.10")
        XCTAssertEqual(session.username, "kube admin")
        XCTAssertEqual(session.port, 2202)
        if case .privateKey(let path, _) = session.authMethod {
            XCTAssertTrue(path.contains("/My Keys/Enterprise Cluster.pem"))
        } else {
            XCTFail("authMethod should be .privateKey")
        }
    }
    
    /// Test 2: Mixed casing for directives
    func testCaseInsensitiveDirectives() {
        let config = """
        HOST edge-node
            HOSTNAME edge.internal.net
            USER root
            PORT 222
            IDENTITYFILE ~/.ssh/edge_key
        """
        
        let hosts = SSHConfigParser.parse(content: config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostPattern, "edge-node")
        XCTAssertEqual(hosts[0].hostName, "edge.internal.net")
        XCTAssertEqual(hosts[0].user, "root")
        XCTAssertEqual(hosts[0].port, 222)
    }
    
    /// Test 3: Multiple hosts separated by whitespace and wildcards
    func testMultipleHostsAndWildcardMatching() {
        let config = """
        Host db-1  db-2    db-3
            HostName shared-db.internal
            User postgres
            Port 5432
            
        Host *
            ServerAliveInterval 15
        """
        
        let hosts = SSHConfigParser.parse(content: config)
        // Global Host * is ignored as non-session
        XCTAssertEqual(hosts.count, 3)
        let names = hosts.map { $0.hostPattern }
        XCTAssertTrue(names.contains("db-1"))
        XCTAssertTrue(names.contains("db-2"))
        XCTAssertTrue(names.contains("db-3"))
        for h in hosts {
            XCTAssertEqual(h.hostName, "shared-db.internal")
            XCTAssertEqual(h.user, "postgres")
            XCTAssertEqual(h.port, 5432)
        }
    }
    
    /// Test 4: Empty, comment-only, and malformed files
    func testEmptyAndMalformedConfigs() {
        XCTAssertEqual(SSHConfigParser.parse(content: "").count, 0)
        XCTAssertEqual(SSHConfigParser.parse(content: "\n\n   \t  \n").count, 0)
        XCTAssertEqual(SSHConfigParser.parse(content: "# Just a comment\n# Another comment").count, 0)
        
        let malformed = """
        RandomGarbageLineWithoutKey
        == == ==
        Host
        HostName missing-host
        """
        // Should gracefully ignore invalid syntax without crashing
        _ = SSHConfigParser.parse(content: malformed)
    }
    
    /// Test 5: Default fallback values when fields omitted
    func testDefaultFallbacks() {
        let config = """
        Host minimal-box
            HostName 1.2.3.4
        """
        let hosts = SSHConfigParser.parse(content: config)
        XCTAssertEqual(hosts.count, 1)
        let session = hosts[0].toSession()
        XCTAssertEqual(session.name, "minimal-box")
        XCTAssertEqual(session.host, "1.2.3.4")
        XCTAssertEqual(session.port, 22) // Defaults to 22
        XCTAssertEqual(session.authMethod, .agent) // Defaults to SSH agent when no key specified
    }
}
