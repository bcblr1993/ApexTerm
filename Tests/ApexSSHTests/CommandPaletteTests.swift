import XCTest
@testable import ApexCore

final class CommandPaletteTests: XCTestCase {
    
    private var sampleItems: [CommandPaletteItem] {
        [
            CommandPaletteItem(
                title: "生产数据库网关",
                subtitle: "deploy@192.168.10.1:22",
                category: .session,
                iconName: "server.rack",
                shortcutHint: nil,
                action: .connectSession(UUID())
            ),
            CommandPaletteItem(
                title: "测试环境 API 服务器",
                subtitle: "ubuntu@10.0.0.5:2222",
                category: .session,
                iconName: "server.rack",
                shortcutHint: nil,
                action: .connectSession(UUID())
            ),
            CommandPaletteItem(
                title: "系统日志目录",
                subtitle: "/var/log",
                category: .bookmark,
                iconName: "folder",
                shortcutHint: nil,
                action: .openBookmark("/var/log")
            ),
            CommandPaletteItem(
                title: "查看磁盘空间",
                subtitle: "df -h",
                category: .snippet,
                iconName: "terminal",
                shortcutHint: nil,
                action: .runSnippet(Snippet(title: "查看磁盘空间", command: "df -h"))
            ),
            CommandPaletteItem(
                title: "新建本地终端",
                subtitle: "打开当前机器的本地 Shell",
                category: .action,
                iconName: "laptopcomputer",
                shortcutHint: "⌘⇧T",
                action: .executeAppAction(.newLocalTerminal)
            ),
            CommandPaletteItem(
                title: "垂直分屏 (左/右)",
                subtitle: "向右拆分窗格",
                category: .action,
                iconName: "rectangle.split.2x1",
                shortcutHint: "⌘D",
                action: .executeAppAction(.splitVertical)
            ),
            CommandPaletteItem(
                title: "SSH 端口转发与隧道管理",
                subtitle: "配置与监控 Local/Remote/Dynamic 隧道",
                category: .action,
                iconName: "arrow.triangle.swap",
                shortcutHint: "⌘⌥T",
                action: .executeAppAction(.openTunnels)
            )
        ]
    }
    
    // MARK: - TC-PAL-01: Palette Item Construction & Categories
    func testPaletteItemConstruction() {
        let items = sampleItems
        XCTAssertEqual(items.count, 7)
        
        let categories = Set(items.map { $0.category })
        XCTAssertTrue(categories.contains(.session))
        XCTAssertTrue(categories.contains(.bookmark))
        XCTAssertTrue(categories.contains(.snippet))
        XCTAssertTrue(categories.contains(.action))
    }
    
    // MARK: - TC-PAL-02: Category Prefix Filtering
    func testPrefixFilterRouting() {
        let items = sampleItems
        
        // Action prefix: ">"
        let actionResults = CommandPaletteSearchEngine.search(items: items, query: ">")
        XCTAssertFalse(actionResults.isEmpty)
        for item in actionResults {
            XCTAssertEqual(item.category, .action)
        }
        
        // Session prefix: "@"
        let sessionResults = CommandPaletteSearchEngine.search(items: items, query: "@")
        XCTAssertFalse(sessionResults.isEmpty)
        for item in sessionResults {
            XCTAssertEqual(item.category, .session)
        }
        
        // Bookmark prefix: "/"
        let bookmarkResults = CommandPaletteSearchEngine.search(items: items, query: "/")
        XCTAssertFalse(bookmarkResults.isEmpty)
        for item in bookmarkResults {
            XCTAssertEqual(item.category, .bookmark)
        }
        
        // Snippet prefix: "#"
        let snippetResults = CommandPaletteSearchEngine.search(items: items, query: "#")
        XCTAssertFalse(snippetResults.isEmpty)
        for item in snippetResults {
            XCTAssertEqual(item.category, .snippet)
        }
    }
    
    // MARK: - TC-PAL-03: Ranking and Scoring Relevance
    func testRankingExactVsSubstring() {
        let items = [
            CommandPaletteItem(title: "终端", category: .action, iconName: "t", action: .executeAppAction(.newLocalTerminal)),
            CommandPaletteItem(title: "新建本地终端", category: .action, iconName: "t", action: .executeAppAction(.newLocalTerminal)),
            CommandPaletteItem(title: "复制终端标签页", category: .action, iconName: "t", action: .executeAppAction(.duplicateSession))
        ]
        
        // Query "终端" -> Exact match should be ranked first
        let results = CommandPaletteSearchEngine.search(items: items, query: "终端")
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.first?.title, "终端")
    }
    
    // MARK: - TC-PAL-04: Subtitle Match (IP / Path)
    func testSubtitleMatch() {
        let items = sampleItems
        
        // Search by IP address in subtitle
        let results = CommandPaletteSearchEngine.search(items: items, query: "192.168.10.1")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "生产数据库网关")
        
        // Search by path in subtitle
        let logResults = CommandPaletteSearchEngine.search(items: items, query: "/var/log")
        XCTAssertEqual(logResults.count, 1)
        XCTAssertEqual(logResults.first?.title, "系统日志目录")
    }
    
    // MARK: - TC-PAL-05: Empty Query and Result Limiting
    func testEmptyQueryAndResultLimits() {
        let items = sampleItems
        
        let all = CommandPaletteSearchEngine.search(items: items, query: "", maxResults: 100)
        XCTAssertEqual(all.count, sampleItems.count)
        
        let limited = CommandPaletteSearchEngine.search(items: items, query: "", maxResults: 3)
        XCTAssertEqual(limited.count, 3)
    }
    
    // MARK: - TC-PAL-06: Case Insensitivity
    func testCaseInsensitivity() {
        let items = sampleItems
        
        let lower = CommandPaletteSearchEngine.search(items: items, query: "ssh")
        let upper = CommandPaletteSearchEngine.search(items: items, query: "SSH")
        XCTAssertEqual(lower.count, upper.count)
        XCTAssertTrue(lower.map(\.title).contains("SSH 端口转发与隧道管理"))
    }
    
    // MARK: - TC-PAL-07: App Actions Catalog Completeness
    func testAppActionsCompleteness() {
        let allActions = CommandPaletteAppAction.allCases
        XCTAssertGreaterThanOrEqual(allActions.count, 12)
        
        for action in allActions {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.iconName.isEmpty)
        }
    }
    
    // MARK: - TC-PAL-08: Special Character and Regex Resilience
    func testSpecialCharacterResilience() {
        let items = sampleItems
        let maliciousQueries = [
            "[a-z(",
            ".*",
            "?+*",
            "\\\\",
            "\"' OR '1'='1",
            "⌘^⌥"
        ]
        
        for q in maliciousQueries {
            // Must execute safely without throwing or crashing
            let results = CommandPaletteSearchEngine.search(items: items, query: q)
            XCTAssertNotNil(results)
        }
    }
}
