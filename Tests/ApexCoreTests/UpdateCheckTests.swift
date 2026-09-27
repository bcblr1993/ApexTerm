import XCTest
@testable import ApexCore

@MainActor
final class UpdateCheckTests: XCTestCase {
    func testManualHTTPErrorIsFailure() async {
        let manager = UpdateManager { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        await manager.checkForUpdates(manual: true)
        guard case .failed = manager.status else { return XCTFail("HTTP failure must not report latest") }
        XCTAssertTrue(manager.isUpdateSheetPresented)
        XCTAssertFalse(manager.isChecking)
    }

    func testMalformedSuccessResponseIsFailure() async {
        let manager = UpdateManager { request in
            (Data("invalid json".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await manager.checkForUpdates(manual: true)
        guard case .failed = manager.status else { return XCTFail("Invalid response must not report latest") }
        XCTAssertFalse(manager.isChecking)
    }

    func testManualNetworkFailureIsFailure() async {
        let manager = UpdateManager { _ in throw URLError(.notConnectedToInternet) }
        await manager.checkForUpdates(manual: true)
        guard case .failed = manager.status else { return XCTFail("Offline must not report latest") }
        XCTAssertTrue(manager.isUpdateSheetPresented)
        XCTAssertFalse(manager.isChecking)
    }

    func testLoadingSheetAndDuplicateRequestGuard() async {
        let gate = UpdateRequestGate()
        let manager = UpdateManager { request in
            await gate.request()
            return (Data(#"{"tag_name":"v0.0.1","html_url":"https://example.com/release"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let task = Task { await manager.checkForUpdates(manual: true) }
        while await gate.count == 0 { await Task.yield() }
        XCTAssertEqual(manager.status, .checking)
        XCTAssertTrue(manager.isChecking)
        XCTAssertTrue(manager.isUpdateSheetPresented)
        await manager.checkForUpdates(manual: true)
        let count = await gate.count
        XCTAssertEqual(count, 1)
        await gate.release()
        await task.value
        XCTAssertEqual(manager.status, .upToDate(currentVersion: manager.currentVersion))
        XCTAssertFalse(manager.isChecking)
    }
}

private actor UpdateRequestGate {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func request() async {
        count += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
