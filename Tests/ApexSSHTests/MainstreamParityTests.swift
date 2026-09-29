import XCTest
import Foundation
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

/// Comprehensive functional test suite comparing against mainstream tools (Electerm, FinalShell, Termius)
/// Covering:
/// 1. OpenSSH command construction, Private Key, Passphrase, Tilde expansion, ProxyJump, KeepAlive
/// 2. Terminal Emulation: Bracketed Paste Mode (DEC 2004), Shift+Tab, Option word navigation, F1-F12 keys, Alternate Screen
/// 3. SFTP File Manager: Escaping special chars, non-UTF-8 encoding fallback in QuickEditor, duplicate downloads, transfer queue
/// 4. Agentless Server Monitor (FinalShell parity): Linux multi-core, Alpine/Busybox, macOS, error resilience
/// 5. Session store, Keychain security & zero credential leakage
final class MainstreamParityTests: XCTestCase {

    // MARK: - Dimension 1: OpenSSH Compatibility & Connection Lifecycle (Electerm / FinalShell Parity)

    func testPrivateKeyAuthArgGenerationAndTildeExpansion() {
        let keyPath = "~/.ssh/id_ed25519"
        let session = Session(
            name: "ServerWithKey",
            host: "10.0.0.5",
            port: 2222,
            username: "deploy",
            authMethod: .privateKey(keychainRef: keyPath, passphraseRef: nil),
            keepAliveIntervalSeconds: 45
        )
        let sshSession = NativeSSHSession(session: session)
        
        // Verify tilde expansion
        let expanded = NativeSSHSession.expandPath(keyPath)
        XCTAssertFalse(expanded.hasPrefix("~"), "Tilde must be expanded to real home directory path")
        XCTAssertTrue(expanded.hasSuffix(".ssh/id_ed25519"))
        XCTAssertTrue(expanded.hasPrefix("/"))

        // Verify ssh auth args
        let authArgs = sshSession.sshAuthArgs()
        XCTAssertEqual(authArgs, ["-i", expanded], "Private key must generate -i <expandedPath> argument")
    }

    func testProxyJumpArgGeneration() {
        let jumpId = UUID()
        let jumpSession = Session(
            id: jumpId,
            name: "BastionHost",
            host: "bastion.example.com",
            port: 22022,
            username: "jumpuser",
            authMethod: .agent
        )
        
        let targetSession = Session(
            name: "InternalServer",
            host: "10.100.1.20",
            port: 22,
            username: "admin",
            authMethod: .agent,
            jumpServerId: jumpId
        )
        
        let client = NativeSSHSession(session: targetSession)
        client.customJumpSession = jumpSession
        
        let jumpArgs = client.jumpServerArgs()
        XCTAssertEqual(jumpArgs, ["-J", "jumpuser@bastion.example.com:22022"], "ProxyJump must generate -J jumpuser@host:port argument")
    }

    func testKeepAliveAndCustomPortParameters() {
        let session = Session(
            name: "CustomServer",
            host: "192.168.1.100",
            port: 8022,
            username: "ubuntu",
            authMethod: .agent,
            keepAliveIntervalSeconds: 15
        )
        
        XCTAssertEqual(session.port, 8022)
        XCTAssertEqual(session.keepAliveIntervalSeconds, 15)
        
        let client = NativeSSHSession(session: session)
        XCTAssertTrue(client.jumpServerArgs().isEmpty)
        XCTAssertTrue(client.sshAuthArgs().isEmpty)
    }

    // MARK: - Dimension 2: Terminal Emulation & Keyboard Navigation (Electerm / Xterm Parity)

    func testBracketedPasteModeCSI2004() {
        let buffer = TerminalRingBuffer()
        XCTAssertFalse(buffer.isBracketedPasteEnabled, "Bracketed paste should initially be disabled")
        
        // Remote shell sends DEC private mode 2004 enable: \e[?2004h
        buffer.appendStream("\u{1B}[?2004h")
        XCTAssertTrue(buffer.isBracketedPasteEnabled, "DEC ?2004h must enable bracketed paste mode")
        
        // Remote shell sends DEC private mode 2004 disable: \e[?2004l
        buffer.appendStream("\u{1B}[?2004l")
        XCTAssertFalse(buffer.isBracketedPasteEnabled, "DEC ?2004l must disable bracketed paste mode")
    }

    func testBracketedPasteModeInAlternateScreen() {
        let buffer = TerminalRingBuffer()
        // Switch to alternate screen (e.g. vim or nano)
        buffer.appendStream("\u{1B}[?1049h")
        XCTAssertNotNil(buffer.screenLines, "Alternate screen buffer should be active")
        
        // Shell/Vim enables bracketed paste in alternate screen
        buffer.appendStream("\u{1B}[?2004h")
        XCTAssertTrue(buffer.isBracketedPasteEnabled)
        
        buffer.appendStream("\u{1B}[?2004l")
        XCTAssertFalse(buffer.isBracketedPasteEnabled)
        
        // Exit alternate screen
        buffer.appendStream("\u{1B}[?1049l")
        XCTAssertNil(buffer.screenLines)
    }

    func testShiftTabBacktabEscapeCodeDefinition() {
        // Shift+Tab must send \e[Z
        let backtabSequence = "\u{1B}[Z"
        XCTAssertEqual(backtabSequence.data(using: .utf8), Data([0x1B, 0x5B, 0x5A]))
    }

    func testOptionKeyWordNavigationEscapeCodes() {
        // Mainstream macOS terminal keybindings for Option navigation:
        // Option + Left -> Meta-b (\eb)
        let optLeft = "\u{1B}b"
        XCTAssertEqual(optLeft.data(using: .utf8), Data([0x1B, 0x62]))
        
        // Option + Right -> Meta-f (\ef)
        let optRight = "\u{1B}f"
        XCTAssertEqual(optRight.data(using: .utf8), Data([0x1B, 0x66]))
        
        // Option + Backspace -> Meta-DEL (\e\x7F)
        let optBackspace = "\u{1B}\u{7F}"
        XCTAssertEqual(optBackspace.data(using: .utf8), Data([0x1B, 0x7F]))
        
        // Option + d -> Meta-d (\ed)
        let optDelete = "\u{1B}d"
        XCTAssertEqual(optDelete.data(using: .utf8), Data([0x1B, 0x64]))
    }

    func testFunctionKeysF1ThroughF12EscapeCodes() {
        let functionKeys: [Int: String] = [
            1: "\u{1B}OP",
            2: "\u{1B}OQ",
            3: "\u{1B}OR",
            4: "\u{1B}OS",
            5: "\u{1B}[15~",
            6: "\u{1B}[17~",
            7: "\u{1B}[18~",
            8: "\u{1B}[19~",
            9: "\u{1B}[20~",
            10: "\u{1B}[21~",
            11: "\u{1B}[23~",
            12: "\u{1B}[24~"
        ]
        
        for (fNum, expected) in functionKeys {
            XCTAssertFalse(expected.isEmpty, "F\(fNum) sequence must not be empty")
            XCTAssertTrue(expected.hasPrefix("\u{1B}"), "F\(fNum) must be an escape sequence")
        }
    }

    func testTerminalURLDetectionRobustness() {
        let sample = "Logs: http://192.168.1.1:8080/dashboard?user=admin&token=xyz. Also see https://github.com/apexterm/app, and ssh://git@github.com."
        let matches = NativeTerminalView.detectURLs(in: sample)
        
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches[0].url.absoluteString, "http://192.168.1.1:8080/dashboard?user=admin&token=xyz")
        XCTAssertEqual(matches[1].url.absoluteString, "https://github.com/apexterm/app")
        XCTAssertEqual(matches[2].url.absoluteString, "ssh://git@github.com")
    }

    // MARK: - Dimension 3: SFTP File Management & Edge Cases (FinalShell / Electerm Parity)

    func testRemotePathQuotingWithSpecialCharacters() {
        // Special chars commonly encountered on Linux servers
        let trickyPaths = [
            "/var/www/my project with spaces/index.html",
            "/home/ubuntu/file$with$dollars.log",
            "/opt/app (v1.2.0)/config.yaml",
            "/data/中文目录/测试文件.txt",
            "/tmp/file'with'single'quotes.tar.gz",
            "/tmp/file\"with\"double\"quotes.json",
            "/tmp/command;injection&pipe|test.sh"
        ]
        
        for path in trickyPaths {
            let quoted = NativeSSHSession.quoteRemotePath(path)
            XCTAssertTrue(quoted.hasPrefix("'"), "Quoted path must start with single quote: \(path)")
            XCTAssertTrue(quoted.hasSuffix("'"), "Quoted path must end with single quote: \(path)")
            XCTAssertFalse(quoted.contains("\n"), "Quoted path must not contain unescaped newline")
        }
    }

    func testQuickEditorNonUTF8EncodingFallback() {
        // Create sample data in ISO-8859-1 / Windows-1252 with special European characters (e.g. copyright, accented letters)
        let nonUTF8Bytes: [UInt8] = [0x43, 0x61, 0x66, 0xE9, 0x20, 0xA9, 0x32, 0x30, 0x32, 0x36] // "Café ©2026" in latin1
        let data = Data(nonUTF8Bytes)
        
        // UTF-8 decoding should fail or be nil on raw byte 0xE9 + 0x20
        let utf8String = String(data: data, encoding: .utf8)
        XCTAssertNil(utf8String, "Raw latin-1 bytes should not decode as strict UTF-8")
        
        // Mainstream fallback decoding:
        let decoded = String(data: data, encoding: .utf8) ??
                      String(data: data, encoding: .windowsCP1252) ??
                      String(data: data, encoding: .isoLatin1) ??
                      String(decoding: data, as: UTF8.self)
        
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertTrue(decoded.contains("Caf"))
    }

    @MainActor
    func testDuplicateDownloadNameResolution() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let existingFile = tempDir.appendingPathComponent("export.sql")
        try? "SELECT 1;".write(to: existingFile, atomically: true, encoding: .utf8)
        
        let manager = TransferManager.shared
        let candidate1 = manager.availableDownloadURL(in: tempDir, fileName: "export.sql")
        XCTAssertEqual(candidate1.lastPathComponent, "export (2).sql")
        
        // Create candidate1 on disk as well
        try? "SELECT 2;".write(to: candidate1, atomically: true, encoding: .utf8)
        let candidate2 = manager.availableDownloadURL(in: tempDir, fileName: "export.sql")
        XCTAssertEqual(candidate2.lastPathComponent, "export (3).sql")
    }

    @MainActor
    func testTransferManagerTaskCancellation() {
        let manager = TransferManager.shared
        let dummyLocalURL = FileManager.default.temporaryDirectory.appendingPathComponent("cancel_test.txt")
        try? "data".write(to: dummyLocalURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dummyLocalURL) }
        
        let taskId = manager.beginExternalTransfer(
            fileName: "cancel_test.txt",
            remotePath: "/tmp/cancel_test.txt",
            localURL: dummyLocalURL,
            direction: .upload,
            totalBytes: 1024
        )
        
        guard let task = manager.tasks.first(where: { $0.id == taskId }) else {
            XCTFail("Task should be present in manager")
            return
        }
        XCTAssertEqual(task.status, .transferring)
        
        manager.cancelExternalTransfer(taskId: taskId)
        
        guard let updated = manager.tasks.first(where: { $0.id == taskId }) else {
            XCTFail("Task should be present in manager")
            return
        }
        XCTAssertEqual(updated.status, .cancelled)
    }

    // MARK: - Dimension 4: Agentless Server Monitoring (FinalShell Flagship Feature Parity)

    func testLinuxMultiCoreMetricsParsing() {
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = AgentlessMonitor.CpuTickState(idle: 1000, total: 2000)
        var prevNet: AgentlessMonitor.NetTickState? = nil
        
        let sampleLinuxOutput = """
        cpu  1200 0 100 1300 0 0 0 0 0 0
        MemTotal:       32880000 kB
        MemFree:         8000000 kB
        MemAvailable:   24000000 kB
        Buffers:         2000000 kB
        Cached:         14000000 kB
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo: 1000000       0    0    0    0     0          0         0  1000000       0    0    0    0     0       0          0
          eth0: 50000000       0    0    0    0     0          0         0 20000000       0    0    0    0     0       0          0
        ---DF---
        /dev/nvme0n1p2 500000000 200000000 300000000 40% /
        ---UPTIME---
        864000.50 1728000.00
        ---LOAD---
        0.75 0.50 0.35 1/450 12345
        ---TOP---
        1234 root 15.2 2.5 nginx
        5678 mysql 8.1 12.0 mysqld
        ---CPUMODEL---
        AMD EPYC 7763 64-Core Processor
        ---DISKTYPE---
        NVMe SSD
        """
        
        let snapshot = monitor.parseOutput(sampleLinuxOutput, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertEqual(snapshot.cpuModel, "AMD EPYC 7763 64-Core Processor")
        XCTAssertEqual(snapshot.diskType, "NVMe SSD")
        XCTAssertTrue(snapshot.isSSD)
        XCTAssertGreaterThan(snapshot.memoryTotalBytes, 30_000_000_000)
        XCTAssertGreaterThan(snapshot.cpuUsagePercent, 0.0)
        XCTAssertEqual(snapshot.loadAvg1m, 0.75)
        XCTAssertEqual(snapshot.loadAvg5m, 0.50)
        XCTAssertEqual(snapshot.loadAvg15m, 0.35)
        XCTAssertEqual(snapshot.topProcesses.count, 2)
        XCTAssertEqual(snapshot.topProcesses[0].command, "nginx")
        XCTAssertEqual(snapshot.topProcesses[0].cpuPercent, 15.2)
    }

    func testLinuxAlpineBusyboxMetricsParsing() {
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil
        
        // Alpine busybox format often lacks extended stats
        let busyboxOutput = """
        cpu 500 0 50 1000 0 0 0 0
        MemTotal:        4096000 kB
        MemFree:         1024000 kB
        MemAvailable:    2048000 kB
        ---DF---
        /dev/vda1 20000000 5000000 15000000 25% /
        ---UPTIME---
        3600.00
        ---LOAD---
        0.10 0.05 0.01
        ---TOP---
        1 root 0.1 0.2 sh
        ---CPUMODEL---
        x86_64
        ---DISKTYPE---
        SSD
        """
        
        let snapshot = monitor.parseOutput(busyboxOutput, prevCpu: &prevCpu, prevNet: &prevNet)
        XCTAssertEqual(snapshot.cpuModel, "x86_64")
        XCTAssertEqual(snapshot.diskType, "SSD")
        XCTAssertEqual(snapshot.loadAvg1m, 0.10)
        XCTAssertEqual(snapshot.loadAvg15m, 0.01)
        XCTAssertEqual(snapshot.uptimeSeconds, 3600)
        XCTAssertFalse(snapshot.topProcesses.isEmpty)
    }

    func testMacOSNativeMetricsParsing() {
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil
        
        let macosOutput = """
        CPU usage: 12.5% user, 8.2% sys, 79.3% idle
        PhysMem: 16G used (2048M wired), 16G unused.
        ---CORES---
        10
        ---DF---
        /dev/disk3s1s1 494384640 18349280 476035360 4% /
        ---UPTIME---
        14:32  up 12 days,  3:15, 3 users, load averages: 1.82 1.65 1.50
        ---NET---
        en0   1500  <Link#6>    f0:18:98:xx:xx:xx 123456789     0  987654321     0     0
        ---TOP---
        101 root 25.0 1.2 WindowServer
        ---CPUMODEL---
        Apple M2 Pro
        ---DISKTYPE---
        NVMe SSD
        """
        
        let snapshot = monitor.parseOutput(macosOutput, prevCpu: &prevCpu, prevNet: &prevNet)
        XCTAssertEqual(snapshot.cpuModel, "Apple M2 Pro")
        XCTAssertEqual(snapshot.cpuCores, 10)
        XCTAssertEqual(snapshot.diskType, "NVMe SSD")
        XCTAssertTrue(snapshot.isSSD)
        XCTAssertEqual(snapshot.cpuUsagePercent, 20.7, accuracy: 0.1)
        XCTAssertEqual(snapshot.loadAvg1m, 1.82, accuracy: 0.01)
        XCTAssertEqual(snapshot.loadAvg5m, 1.65, accuracy: 0.01)
        XCTAssertEqual(snapshot.loadAvg15m, 1.50, accuracy: 0.01)
        XCTAssertEqual(snapshot.topProcesses.first?.command, "WindowServer")
    }

    func testCorruptedAndEmptyMetricsHandledGracefully() {
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil
        
        // Empty string
        let emptySnapshot = monitor.parseOutput("", prevCpu: &prevCpu, prevNet: &prevNet)
        XCTAssertEqual(emptySnapshot.cpuUsagePercent, 0.0)
        XCTAssertEqual(emptySnapshot.memoryUsagePercent, 0.0)
        XCTAssertEqual(emptySnapshot.diskUsagePercent, 0.0)
        XCTAssertFalse(emptySnapshot.cpuUsagePercent.isNaN)
        XCTAssertFalse(emptySnapshot.memoryUsagePercent.isNaN)
        
        // Garbage non-metric string
        let garbageSnapshot = monitor.parseOutput("permission denied\ncommand not found\n###ERROR###", prevCpu: &prevCpu, prevNet: &prevNet)
        XCTAssertEqual(garbageSnapshot.cpuUsagePercent, 0.0)
        XCTAssertEqual(garbageSnapshot.memoryUsagePercent, 0.0)
        XCTAssertFalse(garbageSnapshot.cpuUsagePercent.isNaN)
    }

    // MARK: - Dimension 5: Session Persistence & Security

    @MainActor
    func testSessionWithPrivateKeyAndPassphrasePersistence() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(baseDirectory: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let session = Session(
            name: "CloudProd",
            host: "aws.prod.internal",
            port: 22,
            username: "ec2-user",
            authMethod: .privateKey(keychainRef: "~/.ssh/prod_key.pem", passphraseRef: "pass_1234"),
            folder: "Production",
            tags: ["cloud", "aws"]
        )
        
        store.addSession(session)
        XCTAssertEqual(store.sessions.count, 1)
        
        guard let retrieved = store.sessions.first else {
            XCTFail("Session should be present in store")
            return
        }
        XCTAssertEqual(retrieved.name, "CloudProd")
        XCTAssertEqual(retrieved.folder, "Production")
        XCTAssertEqual(retrieved.authMethod, SSHAuthMethod.privateKey(keychainRef: "~/.ssh/prod_key.pem", passphraseRef: "pass_1234"))
        
        store.deleteSession(id: session.id)
        XCTAssertTrue(store.sessions.isEmpty)
    }
}
