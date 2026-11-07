import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

final class ListeningPortInspectorTests: XCTestCase {

    // MARK: - TC-PORT-01: Linux `ss -tulpnH` IPv4, IPv6, and Interface-Scoped Parsing
    func testParseLinuxSSOutput() {
        let ssSample = """
        tcp   LISTEN 0      511          0.0.0.0:80         0.0.0.0:*    users:(("nginx",pid=1234,fd=6),("nginx",pid=1235,fd=6))
        tcp   LISTEN 0      128        127.0.0.1:6379       0.0.0.0:*    users:(("redis-server",pid=3072,fd=7))
        tcp   LISTEN 0      128             [::]:22            [::]:*    users:(("sshd",pid=684,fd=4))
        udp   UNCONN 0      0      127.0.0.53%lo:53         0.0.0.0:*    users:(("systemd-resolve",pid=412,fd=12))
        """

        let items = ListeningPortParser.parseOutput(ssSample)
        XCTAssertEqual(items.count, 4)

        // Sorted by port ascending: 22, 53, 80, 6379
        XCTAssertEqual(items.map(\.port), [22, 53, 80, 6379])

        let sshItem = items[0]
        XCTAssertEqual(sshItem.proto, "TCP")
        XCTAssertEqual(sshItem.bindAddress, "::")
        XCTAssertEqual(sshItem.pid, 684)
        XCTAssertEqual(sshItem.processName, "sshd")
        XCTAssertTrue(sshItem.isPubliclyExposed)

        let dnsItem = items[1]
        XCTAssertEqual(dnsItem.proto, "UDP")
        XCTAssertEqual(dnsItem.bindAddress, "127.0.0.53")
        XCTAssertEqual(dnsItem.pid, 412)
        XCTAssertEqual(dnsItem.processName, "systemd-resolve")
        XCTAssertFalse(dnsItem.isPubliclyExposed)

        let redisItem = items[3]
        XCTAssertEqual(redisItem.bindAddress, "127.0.0.1")
        XCTAssertEqual(redisItem.port, 6379)
        XCTAssertEqual(redisItem.processName, "redis-server")
        XCTAssertFalse(redisItem.isPubliclyExposed)
    }

    // MARK: - TC-PORT-02: Linux `netstat -tulpn` Fallback Output Parsing
    func testParseLinuxNetstatOutput() {
        let netstatSample = """
        Active Internet connections (only servers)
        Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
        tcp        0      0 0.0.0.0:3306            0.0.0.0:*               LISTEN      1990/mysqld
        tcp6       0      0 :::8080                 :::*                    LISTEN      2048/java
        udp        0      0 127.0.0.1:323           0.0.0.0:*                           550/chronyd
        """

        let items = ListeningPortParser.parseOutput(netstatSample)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.port), [323, 3306, 8080])

        XCTAssertEqual(items[0].proto, "UDP")
        XCTAssertEqual(items[0].processName, "chronyd")
        XCTAssertEqual(items[0].pid, 550)
        XCTAssertFalse(items[0].isPubliclyExposed)

        XCTAssertEqual(items[1].proto, "TCP")
        XCTAssertEqual(items[1].processName, "mysqld")
        XCTAssertEqual(items[1].pid, 1990)
        XCTAssertTrue(items[1].isPubliclyExposed)

        XCTAssertEqual(items[2].bindAddress, "::")
        XCTAssertEqual(items[2].processName, "java")
        XCTAssertTrue(items[2].isPubliclyExposed)
    }

    // MARK: - TC-PORT-03: macOS / BSD `lsof -iTCP -sTCP:LISTEN -P -n` Parsing
    func testParseMacOSLsofOutput() {
        let lsofSample = """
        COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rapportd    512 chenxu    4u  IPv4 0x67b1f09812345678      0t0  TCP *:49152 (LISTEN)
        postgres   1420 chenxu    7u  IPv6 0x67b1f09887654321      0t0  TCP [::1]:5432 (LISTEN)
        postgres   1420 chenxu    8u  IPv4 0x67b1f09887654322      0t0  TCP 127.0.0.1:5432 (LISTEN)
        node       8810 chenxu   21u  IPv4 0x67b1f09887654329      0t0  TCP 0.0.0.0:3000 (LISTEN)
        """

        let items = ListeningPortParser.parseOutput(lsofSample)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.map(\.port), [3000, 5432, 5432, 49152])

        let nodeItem = items[0]
        XCTAssertEqual(nodeItem.processName, "node")
        XCTAssertEqual(nodeItem.pid, 8810)
        XCTAssertEqual(nodeItem.bindAddress, "0.0.0.0")
        XCTAssertTrue(nodeItem.isPubliclyExposed)

        let rapportItem = items[3]
        XCTAssertEqual(rapportItem.bindAddress, "*")
        XCTAssertTrue(rapportItem.isPubliclyExposed)
    }

    // MARK: - TC-PORT-04: Public Exposure vs. Loopback Classification
    func testPublicExposureClassification() {
        let wildcardV4 = ListeningPortItem(proto: "TCP", bindAddress: "0.0.0.0", port: 80, pid: 100, processName: "nginx")
        let wildcardStar = ListeningPortItem(proto: "TCP", bindAddress: "*", port: 80, pid: 100, processName: "nginx")
        let wildcardV6 = ListeningPortItem(proto: "TCP", bindAddress: "::", port: 80, pid: 100, processName: "nginx")
        let lanIP = ListeningPortItem(proto: "TCP", bindAddress: "192.168.1.10", port: 9000, pid: 200, processName: "app")

        let loopbackV4 = ListeningPortItem(proto: "TCP", bindAddress: "127.0.0.1", port: 6379, pid: 300, processName: "redis")
        let loopbackDNS = ListeningPortItem(proto: "UDP", bindAddress: "127.0.0.53", port: 53, pid: 301, processName: "resolved")
        let loopbackV6 = ListeningPortItem(proto: "TCP", bindAddress: "::1", port: 5432, pid: 302, processName: "postgres")
        let localhostName = ListeningPortItem(proto: "TCP", bindAddress: "localhost", port: 8080, pid: 303, processName: "uvicorn")

        XCTAssertTrue(wildcardV4.isPubliclyExposed)
        XCTAssertTrue(wildcardStar.isPubliclyExposed)
        XCTAssertTrue(wildcardV6.isPubliclyExposed)
        XCTAssertTrue(lanIP.isPubliclyExposed)

        XCTAssertFalse(loopbackV4.isPubliclyExposed)
        XCTAssertFalse(loopbackDNS.isPubliclyExposed)
        XCTAssertFalse(loopbackV6.isPubliclyExposed)
        XCTAssertFalse(localhostName.isPubliclyExposed)
    }

    // MARK: - TC-PORT-05: Deduplication and Port-Ascending Ordering
    func testDeduplicationAndSorting() {
        let duplicateOutput = """
        tcp LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=100,fd=6))
        tcp LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=101,fd=6))
        tcp LISTEN 0 511 0.0.0.0:80  0.0.0.0:* users:(("nginx",pid=100,fd=5))
        """
        let items = ListeningPortParser.parseOutput(duplicateOutput)
        XCTAssertEqual(items.count, 2, "Identical proto+bindAddress+port listening entries across worker processes must be deduplicated")
        XCTAssertEqual(items.map(\.port), [80, 443])
    }

    // MARK: - TC-PORT-06: Search and Exposure Filtering
    func testListeningPortSearchFilter() {
        let sample = [
            ListeningPortItem(proto: "TCP", bindAddress: "0.0.0.0", port: 80, pid: 100, processName: "nginx"),
            ListeningPortItem(proto: "TCP", bindAddress: "127.0.0.1", port: 6379, pid: 200, processName: "redis-server"),
            ListeningPortItem(proto: "UDP", bindAddress: "127.0.0.53", port: 53, pid: 300, processName: "systemd-resolve")
        ]

        XCTAssertEqual(ListeningPortParser.filter(sample, query: "").count, 3)
        XCTAssertEqual(ListeningPortParser.filter(sample, query: "6379").map(\.processName), ["redis-server"])
        XCTAssertEqual(ListeningPortParser.filter(sample, query: "nginx").map(\.port), [80])
        XCTAssertEqual(ListeningPortParser.filter(sample, query: "udp").map(\.port), [53])
        XCTAssertEqual(ListeningPortParser.filter(sample, query: "公网").map(\.port), [80])
        XCTAssertEqual(ListeningPortParser.filter(sample, query: "本地").map(\.port), [6379, 53])
    }

    // MARK: - TC-PORT-07: One-Click Local SSH Tunnel (-L) Generation & Privileged Port Mapping
    func testOneClickLocalForwardingTunnelGeneration() {
        let sid = UUID()
        // High port (>= 1024) maps 1:1 to the same local port
        let redisPort = ListeningPortItem(proto: "TCP", bindAddress: "127.0.0.1", port: 6379, pid: 3072, processName: "redis-server")
        let redisTunnel = redisPort.toLocalForwardingTunnel(sessionId: sid)
        XCTAssertEqual(redisTunnel.type, .local)
        XCTAssertEqual(redisTunnel.sessionId, sid)
        XCTAssertEqual(redisTunnel.bindHost, "127.0.0.1")
        XCTAssertEqual(redisTunnel.bindPort, 6379)
        XCTAssertEqual(redisTunnel.targetHost, "127.0.0.1")
        XCTAssertEqual(redisTunnel.targetPort, 6379)
        XCTAssertTrue(redisTunnel.isValid)

        // Privileged port (< 1024, e.g. 80) automatically shifts local bindPort to 10080 to avoid root requirement on macOS
        let httpPort = ListeningPortItem(proto: "TCP", bindAddress: "0.0.0.0", port: 80, pid: 1234, processName: "nginx")
        let httpTunnel = httpPort.toLocalForwardingTunnel(sessionId: sid)
        XCTAssertEqual(httpTunnel.bindPort, 10080)
        XCTAssertEqual(httpTunnel.targetPort, 80)
        XCTAssertTrue(httpTunnel.isValid)
    }

    // MARK: - TC-PORT-08: Multi-OS Probe Command Coverage
    func testListeningPortsProbeCommandIncludesMultiOSFallbacks() {
        let cmd = AgentlessMonitor.listeningPortsProbeCommand
        XCTAssertTrue(cmd.contains("lsof -iTCP -sTCP:LISTEN"))
        XCTAssertTrue(cmd.contains("ss -tulpn"))
        XCTAssertTrue(cmd.contains("netstat -tulpn"))
    }
}
