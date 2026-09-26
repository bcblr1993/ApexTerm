import Foundation
import XCTest

/// 耗时类性能阈值断言。
///
/// 阈值按开发机（Apple Silicon）标定。GitHub Actions 的共享 macOS 机器明显更慢且波动大，
/// 所以在 CI 上（`CI=true`）不达标时只输出 `::warning` 注释，不判失败；本地仍严格断言。
/// 设置 `APEX_STRICT_PERF=1` 可在 CI 上也强制断言。
enum PerformanceThreshold {
    static var isEnforced: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["APEX_STRICT_PERF"] == "1" { return true }
        return env["CI"] != "true"
    }

    static func assertGreaterThan(
        _ actual: Double, _ threshold: Double, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        check(actual > threshold, actual: actual, expectation: "> \(threshold)", message: message, file: file, line: line)
    }

    static func assertLessThan(
        _ actual: Double, _ threshold: Double, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        check(actual < threshold, actual: actual, expectation: "< \(threshold)", message: message, file: file, line: line)
    }

    private static func check(
        _ passed: Bool, actual: Double, expectation: String, message: String,
        file: StaticString, line: UInt
    ) {
        guard !passed else { return }
        let detail = "\(message) (actual: \(String(format: "%.3f", actual)), expected \(expectation))"
        if isEnforced {
            XCTFail(detail, file: file, line: line)
        } else {
            let path = "\(file)".replacingOccurrences(of: FileManager.default.currentDirectoryPath + "/", with: "")
            print("::warning file=\(path),line=\(line),title=性能未达标（CI 机器，不判失败）::\(detail)")
        }
    }
}
