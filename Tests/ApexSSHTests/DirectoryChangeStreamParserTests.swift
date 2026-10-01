import XCTest
import ApexCore
@testable import ApexSSH

final class DirectoryChangeStreamParserTests: XCTestCase {
    func testDirectoryHintsAcrossEveryPacketBoundary() {
        for control in ["\u{1B}]7;file://host/tmp/%E4%B8%AD%E6%96%87%20a\u{7}", "\u{1B}]2;user@host: /tmp/中文 a\u{1B}\\"] {
            let bytes = Array(control.utf8)
            for split in 0...bytes.count {
                var parser = DirectoryChangeStreamParser()
                let first = parser.consume(Data(bytes.prefix(split)))
                let second = parser.consume(Data(bytes.dropFirst(split)))
                XCTAssertEqual(first.paths + second.paths, ["/tmp/中文 a"], "split \(split)")
                XCTAssertEqual(first.text + second.text, "")
            }
        }
    }

    func testSeveralHintsAndOrdinaryTextDoNotReplayOldDirectories() {
        var parser = DirectoryChangeStreamParser()
        let result = parser.consume(Data("before\u{1B}]7;file://host/one\u{7}between\u{1B}]7;file://host/two\u{1B}\\after".utf8))
        XCTAssertEqual(result.paths, ["/one", "/two"])
        XCTAssertEqual(result.text, "beforebetweenafter")
        XCTAssertTrue(parser.consume(Data("next".utf8)).paths.isEmpty)
    }

    func testPromptFallbackDoesNotTreatOutputBeforeTheNextPromptAsDirectory() {
        XCTAssertNil(NativeSSHSession.directoryFromPrompt("/dev/ttys013\r\n% "))
        XCTAssertNil(NativeSSHSession.directoryFromPrompt("/tmp/output\n> "))
        XCTAssertEqual(NativeSSHSession.directoryFromPrompt("/dev/ttys013\r\nuser@host:~/work$ "), "~/work")
        XCTAssertEqual(NativeSSHSession.directoryFromPrompt("root@host:/var/log# "), "/var/log")
        XCTAssertEqual(NativeSSHSession.directoryFromPrompt("user@host /tmp (main) % "), "/tmp")
    }

    func testIPv6JumpHostSyntax() {
        let client = NativeSSHSession(session: Session(name: "target", host: "example.test", username: "qa", authMethod: .agent))
        client.customJumpSession = Session(name: "jump", host: "::1", port: 2200, username: "qa", authMethod: .agent)
        XCTAssertEqual(client.jumpServerArgs(), ["-J", "qa@[::1]:2200"])
    }
}
