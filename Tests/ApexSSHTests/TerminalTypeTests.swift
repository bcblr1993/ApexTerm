import XCTest
@testable import ApexCore
@testable import ApexSSH

/// Session-level TERM selection and remote terminfo detection (TC-TERM-01 ~ TC-TERM-08).
final class TerminalTypeTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalType_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func termValues(_ env: [String]) -> [String] {
        env.filter { $0.hasPrefix("TERM=") }
    }

    /// Runs the probe script locally; `PATH` may hide infocmp to exercise the directory fallback.
    private func runProbe(_ command: String, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// PATH containing only `sh` and `tr`, so `command -v infocmp` fails and the directory scan runs.
    private func pathWithoutInfocmp() throws -> String {
        let bin = tempDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["/bin/sh", "/usr/bin/tr"] {
            let url = URL(fileURLWithPath: tool)
            try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent(url.lastPathComponent), withDestinationURL: url)
        }
        return bin.path
    }

    // MARK: - TC-TERM-01: PTY environment advertises the session TERM exactly once
    func testTC_TERM_01_PTYEnvironmentUsesSessionTerminalType() {
        let inherited = ["TERM": "dumb", "COLORTERM": "x", "HOME": "/Users/qa", "PATH": "/usr/bin"]
        for type in TerminalType.allCases {
            let env = NativeSSHSession.ptyEnvironment(terminalType: type, inherited: inherited, grantsPath: nil)
            XCTAssertEqual(termValues(env), ["TERM=\(type.rawValue)"])
            XCTAssertEqual(env.filter { $0.hasPrefix("COLORTERM=") }, ["COLORTERM=truecolor"])
            XCTAssertTrue(env.contains("HOME=/Users/qa"))
            XCTAssertTrue(env.contains("PATH=/usr/bin:/usr/local/bin:/opt/homebrew/bin"))
        }
        let withGrants = NativeSSHSession.ptyEnvironment(terminalType: .xterm, inherited: [:], grantsPath: "/tmp/grants.json")
        XCTAssertTrue(withGrants.contains("\(ChildProcessFileGrants.environmentKey)=/tmp/grants.json"))
    }

    // MARK: - TC-TERM-02: Client-level override survives without rebuilding the session
    func testTC_TERM_02_ClientTerminalTypeOverride() {
        let session = Session(name: "linx", host: "10.0.0.8", username: "root", terminalType: .xterm256Color)
        let client = NativeSSHSession(session: session)
        XCTAssertEqual(client.terminalType, .xterm256Color)
        client.setTerminalType(.xterm)
        XCTAssertEqual(client.terminalType, .xterm)
        XCTAssertEqual(client.session.terminalType, .xterm256Color, "stored session stays immutable")

        let local = LocalTerminalSession(session: .local())
        local.setTerminalType(.vt100)
        XCTAssertEqual(local.terminalType, .default, "local shells keep their own TERM")
    }

    // MARK: - TC-TERM-03: Sessions saved by older builds decode with the default TERM
    func testTC_TERM_03_LegacySessionJSONDefaultsToXterm256Color() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"old","host":"h","port":22,"username":"u","authMethod":{"agent":{}}}
        """
        let session = try JSONDecoder().decode(Session.self, from: Data(legacy.utf8))
        XCTAssertEqual(session.terminalType, .xterm256Color)
        XCTAssertEqual(Session(name: "n", host: "h", username: "u").terminalType, .xterm256Color)
    }

    // MARK: - TC-TERM-04: Unknown TERM values from newer builds fall back instead of failing
    func testTC_TERM_04_UnknownTerminalTypeFallsBack() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Session(name: "n", host: "h", username: "u"))) as! [String: Any]
        object["terminalType"] = "kitty-ultra"
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: data).terminalType, .default)
        object["terminalType"] = 42
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: object)).terminalType, .default)
    }

    // MARK: - TC-TERM-05: Round trip and iCloud sanitisation keep the selected TERM
    func testTC_TERM_05_RoundTripAndCloudSyncPreserveTerminalType() throws {
        let session = Session(name: "linx", host: "h", username: "u", authMethod: .password(keychainRef: "ref"), terminalType: .linux)
        let encoded = try JSONEncoder().encode(session)
        XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains("\"terminalType\":\"linux\""))
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: encoded), session)

        let sanitized = iCloudSyncManager.sanitizeForCloud(payload: iCloudSyncPayload(sessions: [session]))
        XCTAssertEqual(sanitized.sessions.first?.terminalType, .linux)
    }

    // MARK: - TC-TERM-06: Probe script works with infocmp and with the directory fallback
    func testTC_TERM_06_ProbeCommandDetectsTerminfo() throws {
        let command = TerminfoProbe.command(for: .xterm256Color)
        XCTAssertTrue(command.hasPrefix("sh -c '") && command.hasSuffix("'"))
        XCTAssertEqual(command.dropFirst(7).dropLast().filter { $0 == "'" }.count, 0, "script must not break single quoting")
        XCTAssertTrue(command.contains("infocmp xterm-256color"))
        XCTAssertTrue(command.contains("/x/xterm-256color") && command.contains("/78/xterm-256color"))

        // infocmp branch (macOS ships ncurses)
        let systemEnv = ["PATH": "/usr/bin:/bin", "HOME": tempDir.path]
        XCTAssertEqual(TerminfoProbe.parse(try runProbe(command, environment: systemEnv)), .present)
        XCTAssertEqual(TerminfoProbe.parse(try runProbe(TerminfoProbe.command(term: "apex-missing-term"), environment: systemEnv)), .missing)

        // Directory fallback: hex layout via $TERMINFO, letter layout via ~/.terminfo
        let path = try pathWithoutInfocmp()
        let terminfo = tempDir.appendingPathComponent("terminfo")
        try FileManager.default.createDirectory(at: terminfo.appendingPathComponent("61"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: terminfo.appendingPathComponent("61/apex-hex-term").path, contents: Data())
        let home = tempDir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".terminfo/a"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: home.appendingPathComponent(".terminfo/a/apex-letter-term").path, contents: Data())
        let fallbackEnv = ["PATH": path, "HOME": home.path, "TERMINFO": terminfo.path]
        XCTAssertEqual(TerminfoProbe.parse(try runProbe(TerminfoProbe.command(term: "apex-hex-term"), environment: fallbackEnv)), .present)
        XCTAssertEqual(TerminfoProbe.parse(try runProbe(TerminfoProbe.command(term: "apex-letter-term"), environment: fallbackEnv)), .present)
        XCTAssertEqual(TerminfoProbe.parse(try runProbe(TerminfoProbe.command(term: "apex-missing-term"), environment: fallbackEnv)), .missing)
    }

    // MARK: - TC-TERM-07: Probe output parsing tolerates noise and stays silent when undecided
    func testTC_TERM_07_ProbeOutputParsing() {
        XCTAssertEqual(TerminfoProbe.parse("APEX_TERMINFO=OK\n"), .present)
        XCTAssertEqual(TerminfoProbe.parse("APEX_TERMINFO=MISSING"), .missing)
        XCTAssertEqual(TerminfoProbe.parse("Welcome to Linx GNU/Linux\r\n  APEX_TERMINFO=MISSING\r\n"), .missing)
        XCTAssertEqual(TerminfoProbe.parse("APEX_TERMINFO=UNKNOWN\n"), .unknown)
        XCTAssertEqual(TerminfoProbe.parse(""), .unknown)
        XCTAssertEqual(TerminfoProbe.parse("bash: sh: command not found\n"), .unknown)
    }

    // MARK: - TC-TERM-08: Fallback target never loops back to the missing type
    func testTC_TERM_08_FallbackTargets() {
        XCTAssertEqual(TerminalType.xterm256Color.fallback, .xterm)
        XCTAssertEqual(TerminalType.linux.fallback, .xterm)
        XCTAssertEqual(TerminalType.xterm.fallback, .vt100)
        XCTAssertEqual(TerminalType.vt100.fallback, .vt100)
        for type in TerminalType.allCases where type != .vt100 {
            XCTAssertNotEqual(type.fallback, type)
        }
        XCTAssertEqual(TerminalType.allCases.map(\.rawValue), ["xterm-256color", "xterm", "vt100", "linux"])
    }
}
