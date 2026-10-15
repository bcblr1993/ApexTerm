import XCTest
@testable import ApexCore
@testable import ApexSSH

final class ProcessInspectorTests: XCTestCase {
    
    // Sample real-world Linux ps output
    private let samplePSOutput = """
      PID USER     %CPU %MEM   RSS    VSZ STAT COMMAND         ARGS
        1 root      0.0  0.2 11840 169344 Ss   systemd         /sbin/init
      684 root      0.0  0.1  8420  18236 Ss   sshd            sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups
     1024 deploy    1.5  3.2 131072 524288 Sl  node            node /app/server.js --port 8080
     2048 ubuntu    0.8  1.1  45056 128000 S   python3         python3 worker.py
     3099 root      0.0  0.0     0      0 S    kthreadd        [kthreadd]
     4112 nginx     0.2  0.5  20480  56000 S    nginx           nginx: worker process
    """
    
    // MARK: - TC-PROC-01: PS Output Parsing
    func testParsePSOutput() {
        let items = ProcessListParser.parsePSOutput(samplePSOutput)
        XCTAssertEqual(items.count, 6)
        
        let initProcess = items[0]
        XCTAssertEqual(initProcess.pid, 1)
        XCTAssertEqual(initProcess.user, "root")
        XCTAssertEqual(initProcess.cpuPercent, 0.0)
        XCTAssertEqual(initProcess.memPercent, 0.2)
        XCTAssertEqual(initProcess.rssBytes, 11840 * 1024)
        XCTAssertEqual(initProcess.vszBytes, 169344 * 1024)
        XCTAssertEqual(initProcess.state, .sleeping)
        XCTAssertEqual(initProcess.command, "systemd")
        XCTAssertEqual(initProcess.fullCommandLine, "/sbin/init")
        
        let nodeProcess = items[2]
        XCTAssertEqual(nodeProcess.pid, 1024)
        XCTAssertEqual(nodeProcess.user, "deploy")
        XCTAssertEqual(nodeProcess.cpuPercent, 1.5)
        XCTAssertEqual(nodeProcess.memPercent, 3.2)
        XCTAssertEqual(nodeProcess.rssBytes, 131072 * 1024)
        XCTAssertEqual(nodeProcess.command, "node")
        XCTAssertEqual(nodeProcess.fullCommandLine, "node /app/server.js --port 8080")
    }
    
    // MARK: - TC-PROC-02: Critical System Process Protection
    func testProcessProtection() {
        let sys1 = ProcessDetailItem(pid: 1, user: "root", cpuPercent: 0.0, memPercent: 0.1, command: "systemd")
        XCTAssertTrue(sys1.isProtected)
        
        let sshd = ProcessDetailItem(pid: 684, user: "root", cpuPercent: 0.0, memPercent: 0.1, command: "sshd")
        XCTAssertTrue(sshd.isProtected)
        
        let kernel = ProcessDetailItem(pid: 2, user: "root", cpuPercent: 0.0, memPercent: 0.0, command: "kthreadd")
        XCTAssertTrue(kernel.isProtected)
        
        let normal = ProcessDetailItem(pid: 2048, user: "ubuntu", cpuPercent: 5.0, memPercent: 2.0, command: "python3")
        XCTAssertFalse(normal.isProtected)
    }
    
    // MARK: - TC-PROC-03: Self Session Shell Protection
    func testCanKillSelfSession() {
        let selfShell = ProcessDetailItem(pid: 8888, user: "ubuntu", cpuPercent: 0.1, memPercent: 0.2, command: "bash")
        let result = selfShell.canKill(sessionPid: 8888)
        XCTAssertFalse(result.allowed)
        XCTAssertNotNil(result.reason)
        XCTAssertTrue(result.reason!.contains("当前 SSH 会话自身的 Shell"))
    }
    
    // MARK: - TC-PROC-04: Non-Protected Process Termination Allowed
    func testCanKillNormalProcess() {
        let worker = ProcessDetailItem(pid: 9999, user: "deploy", cpuPercent: 12.0, memPercent: 4.5, command: "sidekiq")
        let result = worker.canKill(sessionPid: 8888)
        XCTAssertTrue(result.allowed)
        XCTAssertNil(result.reason)
    }
    
    // MARK: - TC-PROC-05: Signal Values and Naming
    func testProcessSignalValues() {
        XCTAssertEqual(ProcessSignal.sigterm.rawValue, 15)
        XCTAssertEqual(ProcessSignal.sigkill.rawValue, 9)
        XCTAssertEqual(ProcessSignal.sighup.rawValue, 1)
        
        XCTAssertTrue(ProcessSignal.sigterm.name.contains("SIGTERM"))
        XCTAssertTrue(ProcessSignal.sigkill.name.contains("SIGKILL"))
        XCTAssertTrue(ProcessSignal.sighup.name.contains("SIGHUP"))
    }
    
    // MARK: - TC-PROC-06: Process List Sorting
    func testProcessSorting() {
        let items = ProcessListParser.parsePSOutput(samplePSOutput)
        
        let sortedByCPU = items.sorted { $0.cpuPercent > $1.cpuPercent }
        XCTAssertEqual(sortedByCPU.first?.pid, 1024) // node 1.5%
        
        let sortedByMem = items.sorted { $0.rssBytes > $1.rssBytes }
        XCTAssertEqual(sortedByMem.first?.pid, 1024) // node 131072 KB
    }
    
    // MARK: - TC-PROC-07: Systemd Service Status Parsing
    func testParseSystemdServices() {
        let rawStatus = """
        active
        inactive
        failed
        active
        """
        let monitored = ["nginx", "redis", "mysql", "docker"]
        let services = ProcessListParser.parseSystemdServices(rawStatus, monitoredServices: monitored)
        
        XCTAssertEqual(services.count, 4)
        XCTAssertEqual(services[0].name, "nginx")
        XCTAssertTrue(services[0].isRunning)
        XCTAssertEqual(services[0].activeState, "active")
        
        XCTAssertEqual(services[1].name, "redis")
        XCTAssertFalse(services[1].isRunning)
        XCTAssertEqual(services[1].activeState, "inactive")
        
        XCTAssertEqual(services[2].name, "mysql")
        XCTAssertFalse(services[2].isRunning)
        XCTAssertEqual(services[2].activeState, "failed")
        
        XCTAssertEqual(services[3].name, "docker")
        XCTAssertTrue(services[3].isRunning)
    }
    
    // MARK: - TC-PROC-08: Formatted Memory String
    func testFormattedMemoryString() {
        let item1 = ProcessDetailItem(pid: 100, user: "root", cpuPercent: 1.0, memPercent: 1.0, rssBytes: 50 * 1024 * 1024, command: "app")
        XCTAssertTrue(item1.formattedRSS.contains("50") || item1.formattedRSS.contains("MB"))
        
        let item2 = ProcessDetailItem(pid: 101, user: "root", cpuPercent: 1.0, memPercent: 1.0, rssBytes: 2 * 1024 * 1024 * 1024, command: "db")
        XCTAssertTrue(item2.formattedRSS.contains("2") || item2.formattedRSS.contains("GB"))
    }
}
