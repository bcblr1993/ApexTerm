import XCTest
@testable import ApexCore
@testable import ApexSSH

/// RG-15: Agentless Docker/Podman Container & Dynamic Systemd Ops (`TC-V24-07 ~ TC-V24-11`).
final class AgentlessContainerOpsTests: XCTestCase {

    // MARK: - TC-V24-07: Docker/Podman tab-separated parsing & no-runtime empty state
    func testTC_V24_07_ContainerParsingAndNoRuntimeState() {
        let dockerRaw = """
        ---RUNTIME:docker---
        a1b2c3d4e5f6\tapi-gateway\tnginx:1.27-alpine\trunning\tUp 3 days\t0.0.0.0:80->80/tcp
        f6e5d4c3b2a1\tworker-queue\tpython:3.12-slim\texited\tExited (0) 2 hours ago\t
        """
        let dockerParsed = AgentlessMonitor.parseContainerOutput(dockerRaw)
        XCTAssertEqual(dockerParsed.runtime, .docker)
        XCTAssertEqual(dockerParsed.items.count, 2)
        XCTAssertEqual(dockerParsed.items[0].name, "api-gateway")
        XCTAssertEqual(dockerParsed.items[0].image, "nginx:1.27-alpine")
        XCTAssertTrue(dockerParsed.items[0].isRunning)
        XCTAssertEqual(dockerParsed.items[0].ports, "0.0.0.0:80->80/tcp")
        XCTAssertFalse(dockerParsed.items[1].isRunning)

        let podmanRaw = """
        ---RUNTIME:podman---
        112233445566\tpostgres-db\tdocker.io/library/postgres:16\trunning\tUp 5 hours\t127.0.0.1:5432->5432/tcp
        """
        let podmanParsed = AgentlessMonitor.parseContainerOutput(podmanRaw)
        XCTAssertEqual(podmanParsed.runtime, .podman)
        XCTAssertEqual(podmanParsed.items.first?.runtime, .podman)

        let noneParsed = AgentlessMonitor.parseContainerProbeResult(AgentlessMonitor.noContainerRuntimeSentinel)
        XCTAssertNil(noneParsed.runtime)
        XCTAssertTrue(noneParsed.items.isEmpty)
        XCTAssertNil(noneParsed.errorMessage)
    }

    // MARK: - TC-V24-08: Strict whitelist validation blocks shell injection for container ID & systemd unit
    func testTC_V24_08_ContainerAndUnitInjectionProtection() {
        XCTAssertTrue(AgentlessMonitor.isValidContainerID("web_api-1.prod"))
        XCTAssertFalse(AgentlessMonitor.isValidContainerID("web; rm -rf /"))
        XCTAssertFalse(AgentlessMonitor.isValidContainerID("$(whoami)"))
        XCTAssertFalse(AgentlessMonitor.isValidContainerID("--force"))
        XCTAssertFalse(AgentlessMonitor.isValidContainerID("a b"))

        XCTAssertNil(AgentlessMonitor.containerActionCommand(runtime: .docker, id: "bad;id", action: .restart))
        XCTAssertNil(AgentlessMonitor.containerLogsCommand(runtime: .podman, id: "`id`", tail: 100))
        XCTAssertNil(AgentlessMonitor.containerExecCommand(runtime: .docker, id: "../etc"))

        XCTAssertTrue(AgentlessMonitor.isValidSystemdUnitName("nginx.service"))
        XCTAssertTrue(AgentlessMonitor.isValidSystemdUnitName("php8.2-fpm@www"))
        XCTAssertFalse(AgentlessMonitor.isValidSystemdUnitName("nginx;reboot"))
        XCTAssertFalse(AgentlessMonitor.isValidSystemdUnitName("-p"))
        XCTAssertNil(AgentlessMonitor.systemdJournalCommand(unit: "nginx && id"))
    }

    // MARK: - TC-V24-09: Protected systemd services block stop while allowing reload/logs
    func testTC_V24_09_ProtectedSystemdStopGuardrail() {
        for protected in ["sshd", "sshd.service", "ssh", "systemd-journald", "systemd-udevd", "dbus", "systemd-logind"] {
            let item = SystemdServiceItem(name: protected, activeState: "active")
            XCTAssertTrue(item.isProtectedForStop, "\(protected) must be protected against stop")
            XCTAssertNil(AgentlessMonitor.systemdActionCommand(unit: protected, action: .stop))
            XCTAssertNotNil(AgentlessMonitor.systemdActionCommand(unit: protected, action: .reload))
            XCTAssertNotNil(AgentlessMonitor.systemdJournalCommand(unit: protected, lines: 50))
        }

        let nginx = SystemdServiceItem(name: "nginx", activeState: "active")
        XCTAssertFalse(nginx.isProtectedForStop)
        XCTAssertEqual(AgentlessMonitor.systemdActionCommand(unit: "nginx", action: .stop), "systemctl stop 'nginx' 2>&1")
    }

    // MARK: - TC-V24-10: Command builders for exec, logs, journalctl, and dynamic systemd discovery
    func testTC_V24_10_CommandBuildersAndDynamicSystemdParser() {
        XCTAssertEqual(
            AgentlessMonitor.containerActionCommand(runtime: .docker, id: "api-1", action: .restart),
            "docker restart 'api-1' 2>&1"
        )
        XCTAssertEqual(
            AgentlessMonitor.containerLogsCommand(runtime: .podman, id: "api-1", tail: 200),
            "podman logs --tail 200 'api-1' 2>&1"
        )
        let execCmd = AgentlessMonitor.containerExecCommand(runtime: .docker, id: "api-1")
        XCTAssertEqual(
            execCmd,
            "docker exec -it 'api-1' /bin/sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'"
        )
        XCTAssertEqual(
            AgentlessMonitor.systemdJournalCommand(unit: "redis", lines: 100),
            "journalctl -u 'redis' -n 100 --no-pager 2>&1"
        )

        let rawUnits = """
        nginx.service             loaded active running A high performance web server
        ● mysql.service           loaded failed failed  MySQL Community Server
        sshd.service              loaded active running OpenBSD Secure Shell server
        app-worker.service        loaded inactive dead  Background worker
        """
        let units = AgentlessMonitor.parseSystemdDynamicOutput(rawUnits)
        XCTAssertEqual(units.count, 4)
        // Failed units sort first, followed by active, then inactive
        XCTAssertEqual(units[0].name, "mysql")
        XCTAssertEqual(units[0].activeState, "failed")
        XCTAssertEqual(units[1].name, "nginx")
        XCTAssertTrue(units[1].isRunning)
        XCTAssertEqual(units[3].name, "app-worker")
    }

    // MARK: - TC-V24-11: Permission denied stderr passes through cleanly without fabricating sudo passwords
    func testTC_V24_11_StderrPassthroughOnPermissionError() {
        let permDenied = """
        ---RUNTIME:docker---
        permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock
        """
        let result = AgentlessMonitor.parseContainerProbeResult(permDenied)
        XCTAssertEqual(result.runtime, .docker)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertTrue(result.errorMessage!.contains("permission denied"))
        XCTAssertFalse(AgentlessMonitor.containerListProbeCommand.contains("sudo"))
        XCTAssertFalse(AgentlessMonitor.systemdDynamicProbeCommand.contains("sudo"))
    }
}
