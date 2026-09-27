import Foundation
import ApexCore
import ApexSSH

/// Synthetic UI states only: never opens a network connection or touches a private session store.
final class QAFileSession: SSHSessionProtocol {
    let session: Session
    private let base: MockSSHSession
    private let mode: String
    private let calls = QAFileCallLog()
    private let retryFailure = QAOnceFailure()
    var connectionState: SSHConnectionState { base.connectionState }
    init(session: Session, mode: String) {
        self.session = session
        self.base = MockSSHSession(session: session)
        self.mode = mode
    }
    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func sendInput(_ data: Data) async throws { try await base.sendInput(data) }
    func sendInputSync(_ data: Data) { base.sendInputSync(data) }
    func resizeTerminal(columns: Int, rows: Int) async throws { try await base.resizeTerminal(columns: columns, rows: rows) }
    func listDirectory(path: String) async throws -> [SFTPItem] {
        calls.record(path)
        switch mode {
        case "empty": return []
        case "failure": throw NSError(domain: "ApexTerm.QA", code: 13, userInfo: [NSLocalizedDescriptionKey: "无法读取目录：演示权限不足。请检查目录权限或重新连接。"])
        case "failure-once":
            if await retryFailure.consume() {
                throw NSError(domain: "ApexTerm.QA", code: 54, userInfo: [NSLocalizedDescriptionKey: "无法读取目录：受控连接中断，请重试。"])
            }
            return try await base.listDirectory(path: path)
        case "loading":
            try await Task.sleep(for: .seconds(8))
            return try await base.listDirectory(path: path)
        case "large":
            return (0..<10_000).map { index in
                SFTPItem(name: String(format: "file-%05d.log", index), path: path + "/file-\(index).log", isDirectory: false, size: UInt64(index * 100), modificationDate: Date(timeIntervalSince1970: 1_790_200_000))
            }
        default: return try await base.listDirectory(path: path)
        }
    }
    func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {
        try await base.downloadFile(remotePath: remotePath, localURL: localURL, progress: progress)
    }
    func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {
        try await base.uploadFile(localURL: localURL, remotePath: remotePath, progress: progress)
    }
    func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) { base.setOutputHandler(handler) }
    func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) { base.setMetricsHandler(handler) }
    func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) { base.setDirectoryChangeHandler(handler) }
    func setStateChangeHandler(_ handler: @Sendable @escaping (SSHConnectionState) -> Void) {
        #if !APEX_BASELINE
        base.setStateChangeHandler(handler)
        #endif
    }
}

private actor QAOnceFailure {
    private var pending = true
    func consume() -> Bool {
        defer { pending = false }
        return pending
    }
}

private final class QAFileCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func record(_ path: String) {
        let data = lock.withLock {
            paths.append(path)
            return try? JSONSerialization.data(withJSONObject: paths, options: [.sortedKeys])
        }
        let url = qaRepositoryRoot.appendingPathComponent("outputs/macos27/qa/directory-calls-\(Bundle.main.bundleIdentifier ?? "app").json")
        if let data { try? data.write(to: url, options: .atomic) }
    }
}
