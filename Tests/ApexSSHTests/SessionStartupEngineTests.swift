import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

final class SessionStartupEngineTests: XCTestCase {

    // MARK: - TC-START-01: Session JSON Roundtrip & Legacy Backward Compatibility
    func testSessionStartupFieldsRoundtripAndLegacyCompatibility() throws {
        // 1. Legacy JSON without startup fields decodes cleanly with safe defaults
        let legacyJSON = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Legacy Server",
          "host": "10.0.0.10",
          "port": 22,
          "username": "root",
          "authMethod": { "agent": {} },
          "tags": ["legacy"],
          "agentlessMonitorEnabled": true,
          "sftpAutoSyncEnabled": true
        }
        """.data(using: .utf8)!

        let decodedLegacy = try JSONDecoder().decode(Session.self, from: legacyJSON)
        XCTAssertNil(decodedLegacy.initialWorkingDirectory)
        XCTAssertNil(decodedLegacy.startupCommand)
        XCTAssertTrue(decodedLegacy.environmentVariables.isEmpty)

        // 2. Full Session with startup fields encodes and decodes losslessly
        let fullSession = Session(
            name: "App Prod",
            host: "10.0.1.50",
            port: 2222,
            username: "deploy",
            authMethod: .agent,
            initialWorkingDirectory: "/srv/app/current",
            startupCommand: "tmux attach -t prod || tmux new -s prod",
            environmentVariables: ["APP_ENV": "production", "NODE_OPTIONS": "--max-old-space-size=4096"]
        )

        let data = try JSONEncoder().encode(fullSession)
        let roundtripped = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(roundtripped.initialWorkingDirectory, "/srv/app/current")
        XCTAssertEqual(roundtripped.startupCommand, "tmux attach -t prod || tmux new -s prod")
        XCTAssertEqual(roundtripped.environmentVariables, [
            "APP_ENV": "production",
            "NODE_OPTIONS": "--max-old-space-size=4096"
        ])
    }

    // MARK: - TC-START-02: Environment Variable Identifier Validation & Multi-Line Parser
    func testEnvKeyValidationAndMultiLineParser() {
        XCTAssertTrue(SessionStartupHelper.isValidEnvKey("APP_ENV"))
        XCTAssertTrue(SessionStartupHelper.isValidEnvKey("_INTERNAL_FLAG_1"))
        XCTAssertFalse(SessionStartupHelper.isValidEnvKey(""))
        XCTAssertFalse(SessionStartupHelper.isValidEnvKey("1INVALID"))
        XCTAssertFalse(SessionStartupHelper.isValidEnvKey("BAD-KEY"))
        XCTAssertFalse(SessionStartupHelper.isValidEnvKey("BAD KEY"))
        // Restricted dynamic linker injection variables must be rejected
        XCTAssertFalse(SessionStartupHelper.isValidEnvKey("LD_PRELOAD"))
        XCTAssertFalse(SessionStartupHelper.isValidEnvKey("DYLD_INSERT_LIBRARIES"))

        let rawText = """
        # Application runtime environment
        export APP_ENV=production
        JAVA_OPTS="-Xms512m -Xmx2g"
        CONNECTION_URL=postgres://user:pass@localhost:5432/db?sslmode=disable
        1BAD_KEY=val
        LD_PRELOAD=/tmp/evil.so
        """

        let parsed = SessionStartupHelper.parseEnvLines(rawText)
        XCTAssertEqual(parsed.variables["APP_ENV"], "production")
        XCTAssertEqual(parsed.variables["JAVA_OPTS"], "-Xms512m -Xmx2g")
        XCTAssertEqual(parsed.variables["CONNECTION_URL"], "postgres://user:pass@localhost:5432/db?sslmode=disable")
        XCTAssertEqual(parsed.invalidKeys, ["1BAD_KEY", "LD_PRELOAD"])

        // Format back to sorted KEY=VALUE text
        let formatted = SessionStartupHelper.formatEnvLines(["B_VAR": "2", "A_VAR": "1"])
        XCTAssertEqual(formatted, "A_VAR=1\nB_VAR=2")
    }

    // MARK: - TC-START-03: Shell Quoting & Home Directory Tilde Expansion Safety
    func testShellQuotingAndTildePathExpansion() {
        XCTAssertEqual(SessionStartupHelper.shellSingleQuoted("simple"), "'simple'")
        XCTAssertEqual(SessionStartupHelper.shellSingleQuoted("it's a $test"), "'it'\\''s a $test'")

        // Tilde path expansion preserves $HOME while quoting spaces/special characters in the subpath
        XCTAssertEqual(SessionStartupHelper.shellQuotedWorkingDirectory("~"), "\"$HOME\"")
        XCTAssertEqual(SessionStartupHelper.shellQuotedWorkingDirectory("~/projects/my app"), "\"$HOME\"/'projects/my app'")
        XCTAssertEqual(SessionStartupHelper.shellQuotedWorkingDirectory("/var/www/html"), "'/var/www/html'")
    }

    // MARK: - TC-START-04: Composite Bootstrap Command Generation
    func testCompositeBootstrapCommandGeneration() {
        let emptySession = Session(name: "Plain", host: "10.0.0.1", username: "root")
        XCTAssertNil(SessionStartupHelper.buildBootstrapCommand(for: emptySession))

        let configuredSession = Session(
            name: "Dev Workspace",
            host: "10.0.0.2",
            username: "ubuntu",
            initialWorkingDirectory: "~/workspace/api",
            startupCommand: "docker compose ps",
            environmentVariables: [
                "STAGE": "staging",
                "GREETING": "hello 'world'"
            ]
        )

        let cmd = SessionStartupHelper.buildBootstrapCommand(for: configuredSession)
        XCTAssertEqual(
            cmd,
            "export GREETING='hello '\\''world'\\''' STAGE='staging' && cd \"$HOME\"/'workspace/api' && docker compose ps"
        )

        // When includeEnvExports is false (e.g. LocalTerminalSession already injected env into posix_spawnp), only cd + startupCommand run
        let localCmd = SessionStartupHelper.buildBootstrapCommand(
            for: configuredSession,
            includeWorkingDirectory: false,
            includeEnvExports: false
        )
        XCTAssertEqual(localCmd, "docker compose ps")
    }

    // MARK: - TC-START-05: LocalTerminalSession Environment Variable Injection
    func testLocalTerminalEnvironmentPreparation() {
        let localSession = Session(
            name: "Local Dev",
            host: "localhost",
            username: "user",
            sessionType: .local,
            initialWorkingDirectory: "/tmp",
            startupCommand: "echo ready",
            environmentVariables: [
                "APEX_TEST_ENV": "enabled_123",
                "LD_PRELOAD": "/should/be/blocked.dylib"
            ]
        )
        let mergedEnv = LocalTerminalSession.buildSpawnEnvironment(
            base: ["PATH": "/usr/bin:/bin"],
            session: localSession,
            homeDirectory: "/Users/test",
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(mergedEnv["APEX_TEST_ENV"], "enabled_123")
        XCTAssertNil(mergedEnv["LD_PRELOAD"], "Unsafe linker variable must never be injected into child environment")
        XCTAssertEqual(mergedEnv["PWD"], "/tmp")
    }

    // MARK: - TC-START-06: iCloud Sync Zero-Bundle Redaction for Sensitive Environment Variables
    func testICloudSyncRedactsSensitiveEnvironmentVariables() {
        let session = Session(
            name: "Cloud Synced Node",
            host: "10.2.3.4",
            username: "admin",
            authMethod: .agent,
            initialWorkingDirectory: "/opt/service",
            startupCommand: "./run.sh",
            environmentVariables: [
                "APP_ENV": "production",
                "LOG_LEVEL": "info",
                "AWS_SECRET_ACCESS_KEY": "super-secret-value",
                "GITHUB_TOKEN": "ghp_1234567890",
                "DB_PASSWORD": "my_db_password"
            ]
        )
        let payload = iCloudSyncPayload(sessions: [session])
        let sanitized = iCloudSyncManager.sanitizeForCloud(payload: payload)

        guard let syncedSession = sanitized.sessions.first else {
            return XCTFail("Expected sanitized session")
        }
        XCTAssertEqual(syncedSession.initialWorkingDirectory, "/opt/service")
        XCTAssertEqual(syncedSession.startupCommand, "./run.sh")
        XCTAssertEqual(syncedSession.environmentVariables["APP_ENV"], "production")
        XCTAssertEqual(syncedSession.environmentVariables["LOG_LEVEL"], "info")
        XCTAssertNil(syncedSession.environmentVariables["AWS_SECRET_ACCESS_KEY"], "Secret keys must be stripped before iCloud upload")
        XCTAssertNil(syncedSession.environmentVariables["GITHUB_TOKEN"], "Token keys must be stripped before iCloud upload")
        XCTAssertNil(syncedSession.environmentVariables["DB_PASSWORD"], "Password keys must be stripped before iCloud upload")
    }

    // MARK: - TC-START-07: Session Duplication & SSHConfig Re-Import Preserve Startup Settings
    @MainActor
    func testSessionDuplicationAndSSHConfigMergePreserveStartupSettings() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("StartupStoreTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(baseDirectory: tempDir)
        let original = Session(
            name: "k8s-master",
            host: "10.10.0.1",
            port: 22,
            username: "ubuntu",
            authMethod: .agent,
            initialWorkingDirectory: "/etc/kubernetes",
            startupCommand: "kubectl get nodes",
            environmentVariables: ["KUBECONFIG": "/etc/kubernetes/admin.conf"]
        )
        store.addSession(original)
        store.duplicateSession(original)

        XCTAssertEqual(store.sessions.count, 2)
        let copy = store.sessions.first(where: { $0.id != original.id })
        XCTAssertEqual(copy?.initialWorkingDirectory, "/etc/kubernetes")
        XCTAssertEqual(copy?.startupCommand, "kubectl get nodes")
        XCTAssertEqual(copy?.environmentVariables["KUBECONFIG"], "/etc/kubernetes/admin.conf")

        let hostEntry = SSHConfigHost(hostPattern: "k8s-master", hostName: "10.10.0.99", user: "admin", port: 2222)
        let merged = hostEntry.mergedSession(updating: original, folder: "SSH Config")
        XCTAssertEqual(merged.initialWorkingDirectory, "/etc/kubernetes")
        XCTAssertEqual(merged.startupCommand, "kubectl get nodes")
        XCTAssertEqual(merged.environmentVariables["KUBECONFIG"], "/etc/kubernetes/admin.conf")
    }

    // MARK: - TC-START-08: SessionEditModal Environment Validation & Initial Remote Path Binding
    @MainActor
    func testSessionEditModalEnvValidationAndTabInitialRemotePath() {
        XCTAssertNil(SessionEditModal.environmentValidationMessage(for: "APP_ENV=prod\nPORT=8080"))
        let errMessage = SessionEditModal.environmentValidationMessage(for: "VALID_KEY=1\n9BAD=2\nLD_PRELOAD=foo")
        XCTAssertNotNil(errMessage)
        XCTAssertTrue(errMessage?.contains("9BAD") == true)
        XCTAssertTrue(errMessage?.contains("LD_PRELOAD") == true)

        let sessionWithDir = Session(
            name: "Web Server",
            host: "10.0.0.8",
            username: "www",
            initialWorkingDirectory: "/var/www/app"
        )
        let tab = TerminalTabItem(session: sessionWithDir, sshClient: MockSSHSession(session: sessionWithDir))
        XCTAssertEqual(tab.currentRemotePath, "/var/www/app",
                       "TerminalTabItem should initialize currentRemotePath from session.initialWorkingDirectory when no prior UserDefaults override exists")
    }
}
