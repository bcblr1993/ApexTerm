import XCTest
@testable import ApexCore
@testable import ApexSSH

final class SessionAuditLoggingTests: XCTestCase {
    private var tempDirectory: URL!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SessionAuditLoggingTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    // MARK: - TC-LOG-01: ANSI Escapes Stripping
    func testStripANSISequences() {
        let raw = "\u{1b}[31m[ERROR]\u{1b}[0m Connection \u{1b}[1mfailed\u{1b}[0m: timeout\r\n\u{1b}[2K\u{1b}[1;1HNext line"
        let stripped = SessionLogger.stripANSI(from: raw)
        
        XCTAssertFalse(stripped.contains("\u{1b}"))
        XCTAssertFalse(stripped.contains("[31m"))
        XCTAssertTrue(stripped.contains("[ERROR] Connection failed: timeout"))
        XCTAssertTrue(stripped.contains("Next line"))
    }
    
    // MARK: - TC-LOG-02: SessionLogger File Creation and Header Stamp
    func testSessionLoggerFileCreationAndHeader() {
        let session = Session(name: "ProdWeb", host: "192.168.1.100", port: 22, username: "admin")
        let config = SessionLogConfig(autoLoggingEnabled: true, logDirectoryPath: tempDirectory.path, format: .plainText)
        let logger = SessionLogger(session: session, config: config)
        
        let exp = expectation(description: "Wait for log creation")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            guard let fileURL = logger.activeFileURL else {
                XCTFail("activeFileURL was nil")
                exp.fulfill()
                return
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            XCTAssertTrue(content.contains("AetherTerm Session Log Started"))
            XCTAssertTrue(content.contains("Target: admin@192.168.1.100 [ProdWeb]"))
            logger.close()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
    
    // MARK: - TC-LOG-03: Plain Text Log Appending
    func testSessionLoggerAppendPlainText() {
        let session = Session(name: "AppSvc", host: "10.0.0.1", port: 22, username: "deploy")
        let config = SessionLogConfig(autoLoggingEnabled: true, logDirectoryPath: tempDirectory.path, format: .plainText)
        let logger = SessionLogger(session: session, config: config)
        
        let chunk = "\u{1b}[32mDEPLOY SUCCESS\u{1b}[0m at build #42\n".data(using: .utf8)!
        logger.appendData(chunk)
        
        let exp = expectation(description: "Wait for append")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            guard let fileURL = logger.activeFileURL else {
                XCTFail("activeFileURL was nil")
                exp.fulfill()
                return
            }
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            XCTAssertTrue(content.contains("DEPLOY SUCCESS at build #42"))
            XCTAssertFalse(content.contains("\u{1b}[32m"))
            logger.close()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
    
    // MARK: - TC-LOG-04: Raw ANSI Log Appending
    func testSessionLoggerAppendRawAnsi() {
        let session = Session(name: "AnsiNode", host: "10.0.0.2", port: 22, username: "root")
        let config = SessionLogConfig(autoLoggingEnabled: true, logDirectoryPath: tempDirectory.path, format: .rawAnsi)
        let logger = SessionLogger(session: session, config: config)
        
        let rawString = "\u{1b}[34mBLUE TEXT\u{1b}[0m"
        logger.appendData(rawString.data(using: .utf8)!)
        
        let exp = expectation(description: "Wait for raw append")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            guard let fileURL = logger.activeFileURL else {
                XCTFail("activeFileURL was nil")
                exp.fulfill()
                return
            }
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            XCTAssertTrue(content.contains("\u{1b}[34mBLUE TEXT\u{1b}[0m"))
            logger.close()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
    
    // MARK: - TC-LOG-05: SessionLogger Close Footer
    func testSessionLoggerClose() {
        let session = Session(name: "TestClose", host: "127.0.0.1", port: 22, username: "tester")
        let config = SessionLogConfig(autoLoggingEnabled: true, logDirectoryPath: tempDirectory.path, format: .plainText)
        let logger = SessionLogger(session: session, config: config)
        
        let fileURL = logger.activeFileURL
        logger.close()
        
        let content = (try? String(contentsOf: fileURL!, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.contains("AetherTerm Session Log Ended at"))
    }
    
    // MARK: - TC-LOG-06: Extract Last Command Output (Standard Prompt)
    func testExtractLastCommandOutputBasic() {
        let terminalLines = [
            "ubuntu@cloud:~$ uptime",
            " 05:14:32 up 45 days,  2:15,  1 user,  load average: 0.12, 0.08, 0.05",
            "ubuntu@cloud:~$ cat /etc/issue",
            "Ubuntu 24.04 LTS \\n \\l",
            "",
            "ubuntu@cloud:~$ "
        ]
        
        let output = CommandBoundaryDetector.extractLastCommandOutput(from: terminalLines)
        XCTAssertNotNil(output)
        XCTAssertEqual(output, "Ubuntu 24.04 LTS \\n \\l")
    }
    
    // MARK: - TC-LOG-07: Extract Last Command Output (Modern Prompts: ❯, ➜)
    func testExtractLastCommandOutputAlternativePrompts() {
        let zshLines = [
            "➜ git status",
            "On branch master",
            "nothing to commit, working tree clean",
            "➜ "
        ]
        let zshOutput = CommandBoundaryDetector.extractLastCommandOutput(from: zshLines)
        XCTAssertNotNil(zshOutput)
        XCTAssertTrue(zshOutput!.contains("On branch master"))
        
        let starshipLines = [
            "user in repo on ⎇ main ❯ docker ps",
            "CONTAINER ID   IMAGE     COMMAND   PORTS",
            "a1b2c3d4e5f6   redis:7   redis     6379/tcp",
            "user in repo on ⎇ main ❯ "
        ]
        let starOutput = CommandBoundaryDetector.extractLastCommandOutput(from: starshipLines)
        XCTAssertNotNil(starOutput)
        XCTAssertTrue(starOutput!.contains("CONTAINER ID   IMAGE"))
        XCTAssertTrue(starOutput!.contains("a1b2c3d4e5f6"))
    }
    
    // MARK: - TC-LOG-08: Extract Output Edge Cases (Empty or Single Line)
    func testExtractLastCommandOutputEmpty() {
        XCTAssertNil(CommandBoundaryDetector.extractLastCommandOutput(from: []))
        XCTAssertNil(CommandBoundaryDetector.extractLastCommandOutput(from: [""]))
        XCTAssertNil(CommandBoundaryDetector.extractLastCommandOutput(from: ["ubuntu@host:~$ "]))
    }
}
