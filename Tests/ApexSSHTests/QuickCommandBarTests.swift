import XCTest
@testable import ApexCore

final class QuickCommandBarTests: XCTestCase {
    private var tempDirectory: URL!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("QuickCommandBarTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    // MARK: - TC-CMD-01: Variable Extraction & {{date}} exclusion
    func testVariableExtractionAndDeduplication() {
        let snippet = Snippet(
            title: "Docker Log Tail",
            command: "docker logs --tail {{lines}} -f {{container_name}} && echo {{container_name}} finished at {{date}}"
        )
        
        let variables = snippet.extractVariables()
        XCTAssertEqual(variables.count, 2)
        XCTAssertTrue(variables.contains("lines"))
        XCTAssertTrue(variables.contains("container_name"))
        // {{date}} is automatically resolved by resolvedCommand and should NOT be prompted to the user
        XCTAssertFalse(variables.contains("date"))
    }
    
    // MARK: - TC-CMD-02: Context Resolution & Date Interpolation
    func testContextResolutionAndInterpolation() {
        let snippet = Snippet(
            title: "Restart Service",
            command: "systemctl restart {{service}} && echo 'Done on {{date}}' > /tmp/{{service}}.log"
        )
        
        let resolved = snippet.resolvedCommand(context: ["service": "nginx"])
        XCTAssertTrue(resolved.contains("systemctl restart nginx"))
        XCTAssertTrue(resolved.contains("/tmp/nginx.log"))
        XCTAssertFalse(resolved.contains("{{service}}"))
        XCTAssertFalse(resolved.contains("{{date}}"))
        
        // Assert date format matches yyyy-MM-dd
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayStr = formatter.string(from: Date())
        XCTAssertTrue(resolved.contains(todayStr))
    }
    
    // MARK: - TC-CMD-03: Curated Snippets Completeness
    func testCuratedDefaultSnippetsCompleteness() {
        let presets = Snippet.defaultCuratedSnippets
        XCTAssertGreaterThanOrEqual(presets.count, 15)
        
        let categories = Set(presets.map { $0.category })
        XCTAssertTrue(categories.contains("系统"))
        XCTAssertTrue(categories.contains("进程"))
        XCTAssertTrue(categories.contains("Docker"))
        XCTAssertTrue(categories.contains("网络"))
        XCTAssertTrue(categories.contains("日志"))
        
        // Assert every preset has a valid title, command, and non-empty category
        for s in presets {
            XCTAssertFalse(s.title.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(s.command.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse(s.category.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
    
    // MARK: - TC-CMD-04: Dynamic Category Filtering
    func testDynamicCategoryFiltering() {
        let presets = Snippet.defaultCuratedSnippets
        
        let dockerSnippets = presets.filter { $0.category == "Docker" }
        XCTAssertGreaterThanOrEqual(dockerSnippets.count, 3)
        for s in dockerSnippets {
            XCTAssertEqual(s.category, "Docker")
        }
        
        let sysSnippets = presets.filter { $0.category == "系统" }
        XCTAssertGreaterThanOrEqual(sysSnippets.count, 4)
        for s in sysSnippets {
            XCTAssertEqual(s.category, "系统")
        }
    }
    
    // MARK: - TC-CMD-05: Execution Payload Generation
    func testExecutionPayloadGeneration() {
        let snippet = Snippet(title: "Disk Free", command: "df -h", autoExecute: true)
        let resolved = snippet.resolvedCommand(context: [:])
        let payload = resolved + "\n"
        
        guard let data = payload.data(using: .utf8) else {
            return XCTFail("Failed to encode payload to UTF-8")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "df -h\n")
    }
    
    // MARK: - TC-CMD-06: Special Character Preservation
    func testSpecialCharacterPreservation() {
        let snippet = Snippet(
            title: "Awk Pipeline",
            command: "ps aux | awk '{print $1, $2, $11}' | grep -v 'root' | grep '{{keyword}}'"
        )
        let resolved = snippet.resolvedCommand(context: ["keyword": "node"])
        XCTAssertEqual(resolved, "ps aux | awk '{print $1, $2, $11}' | grep -v 'root' | grep 'node'")
    }
    
    // MARK: - TC-CMD-07: Auto-Execute Flag Behavior
    func testAutoExecuteFlagBehavior() {
        let autoSnippet = Snippet(title: "Status", command: "uptime", autoExecute: true)
        XCTAssertTrue(autoSnippet.autoExecute)
        
        let manualSnippet = Snippet(title: "Kill", command: "kill -9 {{pid}}", autoExecute: false)
        XCTAssertFalse(manualSnippet.autoExecute)
    }
    
    // MARK: - TC-CMD-08: SessionStore Integration and Custom Snippet CRUD
    @MainActor
    func testSessionStoreSnippetCRUD() {
        let store = SessionStore(baseDirectory: tempDirectory)
        let initialCount = store.snippets.count
        XCTAssertGreaterThanOrEqual(initialCount, 15) // seeded with default curated snippets
        
        let custom = Snippet(title: "My Custom Script", command: "bash /opt/app/deploy.sh", category: "自定义")
        store.addSnippet(custom)
        XCTAssertEqual(store.snippets.count, initialCount + 1)
        
        // Reload from disk
        let reloaded = SessionStore(baseDirectory: tempDirectory)
        XCTAssertEqual(reloaded.snippets.count, initialCount + 1)
        XCTAssertEqual(reloaded.snippets.first(where: { $0.id == custom.id })?.title, "My Custom Script")
        
        // Update
        var updated = custom
        updated.title = "Production Deploy Script"
        store.updateSnippet(updated)
        XCTAssertEqual(store.snippets.first(where: { $0.id == custom.id })?.title, "Production Deploy Script")
        
        // Delete
        store.deleteSnippet(id: custom.id)
        XCTAssertEqual(store.snippets.count, initialCount)
        XCTAssertNil(store.snippets.first(where: { $0.id == custom.id }))
    }
}
