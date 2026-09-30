import XCTest
@testable import ApexCore
@testable import ApexTerminal

final class TriggersAndSnippetsTests: XCTestCase {

    func testInvalidMalformedRegexDoesNotCrash() {
        let highlighter = KeywordHighlighter()

        let validTrigger = Trigger(
            name: "Valid Error",
            regexPattern: "ERROR|FATAL",
            action: .highlight(colorHex: "#FF0000")
        )

        let brokenPatterns = [
            "[a-z(",      // Unclosed character class
            "(?<=abc",     // Incomplete lookbehind
            "*invalid",    // Quantifier without target
            "(\\d+",       // Unclosed capture group
            "[\\",         // Trailing escape in class
        ]

        var triggers: [Trigger] = [validTrigger]
        for pattern in brokenPatterns {
            triggers.append(
                Trigger(
                    name: "Broken \(pattern)",
                    regexPattern: pattern,
                    action: .highlight(colorHex: "#FFA500")
                )
            )
        }

        // Setting triggers with corrupted regexes must NOT crash
        highlighter.setTriggers(triggers)

        // Matching against text must continue to work for valid triggers
        let matches = highlighter.findMatches(in: "2026-09-30 08:00:00 [ERROR] Connection timed out")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.trigger.name, "Valid Error")
        XCTAssertEqual(matches.first?.colorHex, "#FF0000")
    }

    func testTriggerMultipleMatchesAndPriority() {
        let t1 = Trigger(name: "Error", regexPattern: "\\[ERROR\\]", action: .highlight(colorHex: "#FF0000"))
        let t2 = Trigger(name: "Timeout", regexPattern: "timeout|timed out", isCaseSensitive: false, action: .highlight(colorHex: "#FF8800"))
        let t3 = Trigger(name: "IP", regexPattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", action: .highlight(colorHex: "#00AAFF"))

        let highlighter = KeywordHighlighter(triggers: [t1, t2, t3])

        let sampleLog = "[ERROR] Gateway timed out while connecting to 192.168.1.100"
        let matches = highlighter.findMatches(in: sampleLog)

        XCTAssertEqual(matches.count, 3)
        let matchedColors = matches.map { $0.colorHex }
        XCTAssertTrue(matchedColors.contains("#FF0000"))
        XCTAssertTrue(matchedColors.contains("#FF8800"))
        XCTAssertTrue(matchedColors.contains("#00AAFF"))
    }

    func testTriggerCaseSensitivity() {
        let caseSensitive = Trigger(name: "Strict", regexPattern: "CRITICAL", isCaseSensitive: true, action: .highlight(colorHex: "#FF0000"))
        let caseInsensitive = Trigger(name: "Loose", regexPattern: "critical", isCaseSensitive: false, action: .highlight(colorHex: "#FF0000"))

        let highlighterStrict = KeywordHighlighter(triggers: [caseSensitive])
        let highlighterLoose = KeywordHighlighter(triggers: [caseInsensitive])

        let testText = "System is in critical state"

        // Strict shouldn't match lower case
        XCTAssertEqual(highlighterStrict.findMatches(in: testText).count, 0)
        // Loose should match
        XCTAssertEqual(highlighterLoose.findMatches(in: testText).count, 1)
    }

    func testSnippetResolvedCommandWithMultipleVariables() {
        let snippet = Snippet(
            title: "Database Backup",
            command: "pg_dump -h {{host}} -p {{port}} -U {{user}} -d {{db}} -F c -b -v -f /backups/{{db}}_{{date}}.dump",
            category: "Database",
            autoExecute: false
        )

        let context = [
            "host": "postgres.internal.net",
            "port": "5432",
            "user": "apex_admin",
            "db": "production_crm"
        ]

        let resolved = snippet.resolvedCommand(context: context)

        XCTAssertTrue(resolved.contains("pg_dump -h postgres.internal.net -p 5432 -U apex_admin -d production_crm"))
        XCTAssertTrue(resolved.contains("production_crm_"))
        XCTAssertTrue(resolved.contains(".dump"))

        // Date should be formatted as yyyy-MM-dd
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())
        XCTAssertTrue(resolved.contains(todayStr))
    }

    func testSnippetUnresolvedVariablesPreserved() {
        let snippet = Snippet(
            title: "Docker Compose",
            command: "docker-compose -f {{compose_file}} up -d --scale worker={{workers}} --env {{extra_env}}",
            category: "Containers"
        )

        // Only provide compose_file, leave workers and extra_env unresolved
        let context = [
            "compose_file": "docker-compose.prod.yml"
        ]

        let resolved = snippet.resolvedCommand(context: context)
        XCTAssertTrue(resolved.contains("docker-compose -f docker-compose.prod.yml up -d"))
        XCTAssertTrue(resolved.contains("--scale worker={{workers}}"))
        XCTAssertTrue(resolved.contains("--env {{extra_env}}"))
    }

    func testTriggerActionCodableAndHashability() throws {
        let actions: [TriggerAction] = [
            .highlight(colorHex: "#FF00FF"),
            .sendResponse(text: "yes\n"),
            .notify(title: "Task Finished")
        ]

        for action in actions {
            let encoded = try JSONEncoder().encode(action)
            let decoded = try JSONDecoder().decode(TriggerAction.self, from: encoded)
            XCTAssertEqual(action, decoded)
        }

        // Test Set deduping
        let set: Set<TriggerAction> = [
            .highlight(colorHex: "#000"),
            .highlight(colorHex: "#000"),
            .notify(title: "A")
        ]
        XCTAssertEqual(set.count, 2)
    }
}
