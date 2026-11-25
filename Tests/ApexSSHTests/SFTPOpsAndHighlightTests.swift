import XCTest
@testable import ApexCore
@testable import ApexSSH
@testable import ApexUI

/// RG-15: SFTP Remote Archive/Search & Lightweight Syntax Highlighting (`TC-V24-17 ~ TC-V24-20`).
final class SFTPOpsAndHighlightTests: XCTestCase {

    // MARK: - TC-V24-17: Safe POSIX quoting for archive/extract with spaces, quotes & CJK filenames
    func testTC_V24_17_ArchiveAndExtractEscaping() {
        let archiveCmd = SFTPRemoteOperations.archiveCommand(
            items: ["my config.yml", "it's 日志.txt"],
            inDirectory: "/var/log/my app",
            format: .tarGz,
            archiveName: "backup 'prod'.tar.gz"
        )
        XCTAssertNotNil(archiveCmd)
        XCTAssertTrue(archiveCmd!.contains("cd '/var/log/my app'"))
        XCTAssertTrue(archiveCmd!.contains("tar -czf 'backup '\\''prod'\\''.tar.gz' 'my config.yml' 'it'\\''s 日志.txt'"))

        let zipCmd = SFTPRemoteOperations.archiveCommand(
            items: ["-dashfile.log"],
            inDirectory: "~/logs",
            format: .zip,
            archiveName: "out.zip"
        )
        XCTAssertNotNil(zipCmd)
        XCTAssertTrue(zipCmd!.contains("cd \"$HOME\"/'logs'"))
        XCTAssertTrue(zipCmd!.contains("'./-dashfile.log'"))

        // Reject path traversal & slashes in archiveName
        XCTAssertNil(SFTPRemoteOperations.archiveCommand(items: ["../secret"], inDirectory: "/tmp", format: .tarGz, archiveName: "a.tar.gz"))
        XCTAssertNil(SFTPRemoteOperations.archiveCommand(items: ["a"], inDirectory: "/tmp", format: .tarGz, archiveName: "../evil.tar.gz"))
        XCTAssertNil(SFTPRemoteOperations.extractCommand(archivePath: "/tmp/../evil.tgz", targetDirectory: "/tmp"))

        let extractTar = SFTPRemoteOperations.extractCommand(archivePath: "/opt/app/rel '1'.tgz", targetDirectory: "/opt/app/out dir")
        XCTAssertEqual(extractTar, "mkdir -p '/opt/app/out dir' && tar -xzf '/opt/app/rel '\\''1'\\''.tgz' -C '/opt/app/out dir' 2>&1")
        let extractZip = SFTPRemoteOperations.extractCommand(archivePath: "/opt/app/dist.zip", targetDirectory: "/opt/app")
        XCTAssertTrue(extractZip?.contains("unzip -oq '/opt/app/dist.zip' -d '/opt/app'") == true)
    }

    // MARK: - TC-V24-18: Remote find / grep -F command building & colon-preserving output parsing
    func testTC_V24_18_RemoteSearchCommandAndParsing() {
        let findCmd = SFTPRemoteOperations.searchCommand(basePath: "/etc/nginx", query: "site*.conf", mode: .filename, maxDepth: 4, maxResults: 150)
        XCTAssertEqual(findCmd, "find '/etc/nginx' -maxdepth 4 -iname '*site\\*.conf*' 2>/dev/null | head -n 150")

        let grepCmd = SFTPRemoteOperations.searchCommand(basePath: "/app", query: "http://localhost:8080", mode: .content)
        XCTAssertEqual(grepCmd, "grep -rnI --max-count=5 -F -- 'http://localhost:8080' '/app' 2>/dev/null | head -n 200")

        let findOutput = """
        /etc/nginx/nginx.conf
        /etc/nginx/conf.d/default.conf
        """
        let findHits = SFTPRemoteOperations.parseSearchOutput(findOutput, mode: .filename)
        XCTAssertEqual(findHits.count, 2)
        XCTAssertEqual(findHits[1].fileName, "default.conf")
        XCTAssertEqual(findHits[1].parentDirectory, "/etc/nginx/conf.d")

        let grepOutput = """
        /app/config.json:42:  "endpoint": "http://127.0.0.1:8080/api:v1"
        Binary file /app/blob.bin matches
        /app/env:7:PORT=8080
        """
        let contentHits = SFTPRemoteOperations.parseSearchOutput(grepOutput, mode: .content)
        XCTAssertEqual(contentHits.count, 2)
        XCTAssertEqual(contentHits[0].path, "/app/config.json")
        XCTAssertEqual(contentHits[0].lineNumber, 42)
        XCTAssertEqual(contentHits[0].snippet, "\"endpoint\": \"http://127.0.0.1:8080/api:v1\"")

        let colonPathOutput = "/var/log/app:v1/err:2026.log:17:status=500:timeout"
        let colonHits = SFTPRemoteOperations.parseSearchOutput(colonPathOutput, mode: .content)
        XCTAssertEqual(colonHits.count, 1)
        XCTAssertEqual(colonHits[0].path, "/var/log/app:v1/err:2026.log")
        XCTAssertEqual(colonHits[0].lineNumber, 17)
        XCTAssertEqual(colonHits[0].snippet, "status=500:timeout")
    }

    // MARK: - TC-V24-19: SyntaxHighlighter tokenizes YAML, JSON, Shell, Dockerfile & Nginx accurately
    func testTC_V24_19_SyntaxHighlighterTokenRecognition() {
        XCTAssertEqual(SyntaxLanguage.detect(filename: "docker-compose.yml"), .yaml)
        XCTAssertEqual(SyntaxLanguage.detect(filename: "package.json"), .json)
        XCTAssertEqual(SyntaxLanguage.detect(filename: "deploy.sh"), .shell)
        XCTAssertEqual(SyntaxLanguage.detect(filename: "Dockerfile.prod"), .dockerfile)
        XCTAssertEqual(SyntaxLanguage.detect(filename: "nginx.conf"), .nginx)
        XCTAssertEqual(SyntaxLanguage.detect(filename: ".env.local"), .ini)

        let yaml = """
        # service config
        enabled: true
        port: 8080
        name: "api # inside string"
        """
        let yamlTokens = SyntaxHighlighter.tokenize(yaml, language: .yaml)
        XCTAssertTrue(yamlTokens.contains(where: { $0.kind == .comment }))
        XCTAssertTrue(yamlTokens.contains(where: { $0.kind == .key }))
        XCTAssertTrue(yamlTokens.contains(where: { $0.kind == .keyword }))
        XCTAssertTrue(yamlTokens.contains(where: { $0.kind == .number }))
        XCTAssertTrue(yamlTokens.contains(where: { $0.kind == .string }))
        // Ensure `# inside string` wasn't split into a second comment token
        XCTAssertEqual(yamlTokens.filter { $0.kind == .comment }.count, 1)

        let json = """
        {
          "host": "localhost",
          "port": 443,
          "tls": true
        }
        """
        let jsonTokens = SyntaxHighlighter.tokenize(json, language: .json)
        XCTAssertEqual(jsonTokens.filter { $0.kind == .key }.count, 3)
        XCTAssertTrue(jsonTokens.contains(where: { $0.kind == .string }))
        XCTAssertTrue(jsonTokens.contains(where: { $0.kind == .number }))
        XCTAssertTrue(jsonTokens.contains(where: { $0.kind == .keyword }))

        let dockerfile = """
        FROM alpine:3.20 AS builder
        ENV APP_ENV="prod"
        RUN apk add --no-cache curl
        """
        let dockerTokens = SyntaxHighlighter.tokenize(dockerfile, language: .dockerfile)
        XCTAssertEqual(dockerTokens.filter { $0.kind == .directive }.count, 3)
        XCTAssertTrue(dockerTokens.contains(where: { $0.kind == .keyword }))
        XCTAssertTrue(dockerTokens.contains(where: { $0.kind == .string }))

        let nginx = """
        server {
            listen 443 ssl;
            proxy_pass $upstream_url;
        }
        """
        let nginxTokens = SyntaxHighlighter.tokenize(nginx, language: .nginx)
        XCTAssertTrue(nginxTokens.contains(where: { $0.kind == .directive }))
        XCTAssertTrue(nginxTokens.contains(where: { $0.kind == .variable }))
        XCTAssertTrue(nginxTokens.contains(where: { $0.kind == .number }))
    }

    // MARK: - TC-V24-20: Files > 512 KB bypass highlighting immediately (< 5ms)
    func testTC_V24_20_LargeFileHighlightBypassAndPerformance() {
        let largeYAML = String(repeating: "key: value # comment\n", count: 30_000) // ~630 KB
        XCTAssertGreaterThan(largeYAML.utf8.count, 512 * 1024)

        let start = ContinuousClock.now
        let tokens = SyntaxHighlighter.tokenize(largeYAML, language: .yaml)
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(tokens.isEmpty)
        XCTAssertLessThan(elapsed, .milliseconds(5))
    }
}
