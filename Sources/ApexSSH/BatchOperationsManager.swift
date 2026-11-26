import Foundation
import ApexCore

/// Operational mode for multi-host batch execution
public enum BatchOperationMode: String, CaseIterable, Sendable, Identifiable {
    case command = "批量执行命令"
    case fileDistribution = "批量分发文件"

    public var id: String { rawValue }
}

/// Lifecycle state for an individual host in a batch run
public enum BatchHostStatus: Sendable, Equatable {
    case pending
    case running
    case succeeded
    case failed(String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .pending, .running:
            return false
        }
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var displayLabel: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "执行中"
        case .succeeded: return "成功"
        case .failed(let reason): return reason.isEmpty ? "失败" : "失败: \(reason)"
        case .cancelled: return "已取消"
        }
    }
}

/// Per-host execution or file distribution result
public struct BatchHostResult: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: UUID
    public let hostName: String
    public let hostAddress: String
    public var status: BatchHostStatus
    public var exitCode: Int32?
    public var stdout: String
    public var stderr: String
    public var durationMs: Double?
    public var progress: Double
    public var remoteTargetPath: String?

    public init(
        session: Session,
        status: BatchHostStatus = .pending,
        exitCode: Int32? = nil,
        stdout: String = "",
        stderr: String = "",
        durationMs: Double? = nil,
        progress: Double = 0,
        remoteTargetPath: String? = nil
    ) {
        self.id = session.id
        self.sessionID = session.id
        self.hostName = session.name
        self.hostAddress = session.isLocal ? "local" : "\(session.username)@\(session.host):\(session.port)"
        self.status = status
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.durationMs = durationMs
        self.progress = progress
        self.remoteTargetPath = remoteTargetPath
    }
}

/// Coordinates bounded-concurrency batch command execution and file distribution across multiple SSH hosts.
@MainActor
public final class BatchOperationsManager: ObservableObject {
    public static let shared = BatchOperationsManager()
    public static let openNotification = CommandPaletteItem.openBatchOperationsNotification

    public typealias SessionClientProvider = @Sendable (Session) async throws -> any SSHSessionProtocol

    private enum BatchJobPayload: Sendable {
        case command(String)
        case fileUpload(localURLs: [URL], remoteDirectory: String, createRemoteDirectory: Bool)
    }

    private struct HostTimeoutError: Error {}

    @Published public var createRemoteDirectoryBeforeUpload: Bool = false

    @Published public var maxConcurrency: Int {
        didSet {
            let clamped = Self.clampConcurrency(maxConcurrency)
            if maxConcurrency != clamped {
                maxConcurrency = clamped
            }
        }
    }

    @Published public var commandTimeoutSeconds: TimeInterval {
        didSet {
            let clamped = Self.clampTimeout(commandTimeoutSeconds)
            if commandTimeoutSeconds != clamped {
                commandTimeoutSeconds = clamped
            }
        }
    }

    @Published public private(set) var results: [BatchHostResult] = []
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var currentMode: BatchOperationMode = .command
    @Published public private(set) var lastCommand: String = ""
    @Published public private(set) var lastUploadURLs: [URL] = []
    @Published public private(set) var lastRemoteDirectory: String = ""
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var finishedAt: Date?

    private let customDefaultClientProvider: SessionClientProvider?
    private var activeBatchTask: Task<Void, Never>?
    private var currentRunID: UUID?
    private var cancelledRunIDs: Set<UUID> = []
    private var lastTargetSessions: [Session] = []
    private var lastJobPayload: BatchJobPayload?
    private var lastRunClientProvider: SessionClientProvider?

    public init(
        maxConcurrency: Int = 4,
        commandTimeoutSeconds: TimeInterval = 60,
        clientProvider: SessionClientProvider? = nil
    ) {
        self.maxConcurrency = Self.clampConcurrency(maxConcurrency)
        self.commandTimeoutSeconds = Self.clampTimeout(commandTimeoutSeconds)
        self.customDefaultClientProvider = clientProvider
    }

    public nonisolated static func clampConcurrency(_ value: Int) -> Int {
        max(1, min(16, value))
    }

    public nonisolated static func clampTimeout(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 60 }
        return max(0.05, min(3600, value))
    }

    public nonisolated static func resolvedRemoteFilePath(localURL: URL, remoteDirectory: String) -> String {
        let trimmed = remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = localURL.lastPathComponent
        if trimmed.isEmpty || trimmed == "~" {
            return "~/\(fileName)"
        }
        if trimmed == "/" {
            return "/\(fileName)"
        }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return "\(base)/\(fileName)"
    }

    public nonisolated static func makeRemoteDirectoryCommand(for remoteDirectory: String) -> String? {
        let trimmed = remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "~", trimmed != "/" else { return nil }
        if trimmed.hasPrefix("~/") {
            let sub = String(trimmed.dropFirst(2))
            guard !sub.isEmpty else { return nil }
            return "mkdir -p \"$HOME/\"\(AgentlessMonitor.posixSingleQuoted(sub))"
        }
        return "mkdir -p \(AgentlessMonitor.posixSingleQuoted(trimmed))"
    }

    // MARK: - Progress & Summary Helpers

    public var totalCount: Int { results.count }
    public var succeededCount: Int { results.filter { $0.status == .succeeded }.count }
    public var failedCount: Int { results.filter { $0.status.isFailed }.count }
    public var cancelledCount: Int { results.filter { $0.status == .cancelled }.count }
    public var runningCount: Int { results.filter { $0.status == .running }.count }
    public var pendingCount: Int { results.filter { $0.status == .pending }.count }
    public var completedCount: Int { results.filter { $0.status.isTerminal }.count }
    public var hasFailedHosts: Bool { failedCount > 0 }

    public var overallProgress: Double {
        guard !results.isEmpty else { return 0 }
        let sum = results.reduce(0.0) { partial, item in
            switch item.status {
            case .succeeded, .failed, .cancelled:
                return partial + 1.0
            case .running:
                return partial + max(0.05, min(0.99, item.progress))
            case .pending:
                return partial
            }
        }
        return sum / Double(results.count)
    }

    // MARK: - Batch Execution API

    public func executeBatchCommand(
        _ command: String,
        on sessions: [Session],
        clientProvider: SessionClientProvider? = nil
    ) async {
        let task = startBatchCommand(command, on: sessions, clientProvider: clientProvider)
        await task.value
    }

    @discardableResult
    public func startBatchCommand(
        _ command: String,
        on sessions: [Session],
        clientProvider: SessionClientProvider? = nil
    ) -> Task<Void, Never> {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        currentMode = .command
        lastCommand = command
        let payload = BatchJobPayload.command(trimmedCommand.isEmpty ? command : trimmedCommand)
        return launchBatch(
            sessions: sessions,
            payload: payload,
            clientProvider: clientProvider,
            resetAllResults: true
        )
    }

    public func uploadFile(
        _ localURL: URL,
        toRemoteDirectory remoteDirectory: String,
        on sessions: [Session],
        createRemoteDirectory: Bool? = nil,
        clientProvider: SessionClientProvider? = nil
    ) async {
        await distributeFiles(
            [localURL],
            toRemoteDirectory: remoteDirectory,
            on: sessions,
            createRemoteDirectory: createRemoteDirectory,
            clientProvider: clientProvider
        )
    }

    public func distributeFiles(
        _ localURLs: [URL],
        toRemoteDirectory remoteDirectory: String,
        on sessions: [Session],
        createRemoteDirectory: Bool? = nil,
        clientProvider: SessionClientProvider? = nil
    ) async {
        let task = startBatchFileDistribution(
            localURLs,
            toRemoteDirectory: remoteDirectory,
            on: sessions,
            createRemoteDirectory: createRemoteDirectory,
            clientProvider: clientProvider
        )
        await task.value
    }

    @discardableResult
    public func startBatchFileDistribution(
        _ localURLs: [URL],
        toRemoteDirectory remoteDirectory: String,
        on sessions: [Session],
        createRemoteDirectory: Bool? = nil,
        clientProvider: SessionClientProvider? = nil
    ) -> Task<Void, Never> {
        currentMode = .fileDistribution
        lastUploadURLs = localURLs
        lastRemoteDirectory = remoteDirectory
        let shouldCreateDir = createRemoteDirectory ?? createRemoteDirectoryBeforeUpload
        let payload = BatchJobPayload.fileUpload(
            localURLs: localURLs,
            remoteDirectory: remoteDirectory,
            createRemoteDirectory: shouldCreateDir
        )
        return launchBatch(
            sessions: sessions,
            payload: payload,
            clientProvider: clientProvider,
            resetAllResults: true
        )
    }

    public func retryFailedHosts(clientProvider: SessionClientProvider? = nil) async {
        let task = startRetryFailedHosts(clientProvider: clientProvider)
        await task.value
    }

    @discardableResult
    public func startRetryFailedHosts(clientProvider: SessionClientProvider? = nil) -> Task<Void, Never> {
        guard let payload = lastJobPayload else {
            return Task {}
        }
        let failedIDs = Set(results.filter { $0.status.isFailed }.map(\.sessionID))
        let retrySessions = lastTargetSessions.filter { failedIDs.contains($0.id) }
        guard !retrySessions.isEmpty else {
            return Task {}
        }
        let effectiveProvider = clientProvider ?? lastRunClientProvider
        return launchBatch(
            sessions: retrySessions,
            payload: payload,
            clientProvider: effectiveProvider,
            resetAllResults: false
        )
    }

    public func cancelCurrentBatch() {
        guard let runID = currentRunID else { return }
        cancelledRunIDs.insert(runID)
        activeBatchTask?.cancel()
        for index in results.indices where !results[index].status.isTerminal {
            results[index].status = .cancelled
        }
        isRunning = false
        finishedAt = Date()
    }

    public func clearResults() {
        cancelCurrentBatch()
        results = []
        startedAt = nil
        finishedAt = nil
    }

    // MARK: - Internal TaskGroup Runner

    private func launchBatch(
        sessions: [Session],
        payload: BatchJobPayload,
        clientProvider: SessionClientProvider?,
        resetAllResults: Bool
    ) -> Task<Void, Never> {
        let previousTask = activeBatchTask
        previousTask?.cancel()
        if let previousRunID = currentRunID {
            cancelledRunIDs.insert(previousRunID)
        }

        let runID = UUID()
        currentRunID = runID
        let sessionsSnapshot = SessionStore.shared.sessions
        let resolvedProvider: SessionClientProvider = clientProvider ?? customDefaultClientProvider ?? { session in
            if session.isLocal {
                return LocalTerminalSession(session: session)
            } else if session.host == "192.0.2.10" {
                return MockSSHSession(session: session)
            } else {
                let resolvedHops = SSHArgumentBuilder.resolveJumpChain(for: session, availableSessions: sessionsSnapshot).hops
                let reuseLiveMux = SSHControlMasterPool.isPoolEnabled
                    && SSHControlMasterPool.shared.hasActiveSocket(for: session, resolvedJumpHops: resolvedHops)
                return NativeSSHSession(
                    session: session,
                    availableSessions: sessionsSnapshot,
                    disableControlPersist: !reuseLiveMux
                )
            }
        }
        lastJobPayload = payload
        lastRunClientProvider = clientProvider

        let deduplicatedSessions = Self.deduplicatedSessions(sessions)
        if resetAllResults {
            lastTargetSessions = deduplicatedSessions
            let remoteDirHint: String? = {
                if case .fileUpload(_, let dir, _) = payload { return dir }
                return nil
            }()
            results = deduplicatedSessions.map {
                BatchHostResult(session: $0, status: .pending, remoteTargetPath: remoteDirHint)
            }
        } else {
            let retryIDs = Set(deduplicatedSessions.map(\.id))
            for idx in results.indices where retryIDs.contains(results[idx].sessionID) {
                results[idx].status = .pending
                results[idx].exitCode = nil
                results[idx].stdout = ""
                results[idx].stderr = ""
                results[idx].durationMs = nil
                results[idx].progress = 0
            }
        }

        guard !deduplicatedSessions.isEmpty else {
            isRunning = false
            startedAt = Date()
            finishedAt = startedAt
            let emptyTask = Task<Void, Never> {
                _ = await previousTask?.value
            }
            activeBatchTask = emptyTask
            return emptyTask
        }

        isRunning = true
        startedAt = Date()
        finishedAt = nil

        let concurrencyLimit = Self.clampConcurrency(maxConcurrency)
        let timeoutSec = Self.clampTimeout(commandTimeoutSeconds)

        let task = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            let stillActive = await MainActor.run { self.isRunActive(runID) }
            guard !Task.isCancelled, stillActive else {
                await MainActor.run {
                    guard self.currentRunID == runID else { return }
                    for idx in self.results.indices where !self.results[idx].status.isTerminal {
                        self.results[idx].status = .cancelled
                    }
                    self.isRunning = false
                    if self.finishedAt == nil {
                        self.finishedAt = Date()
                    }
                }
                return
            }
            await self.runBoundedTaskGroup(
                runID: runID,
                sessions: deduplicatedSessions,
                payload: payload,
                limit: concurrencyLimit,
                timeoutSeconds: timeoutSec,
                provider: resolvedProvider
            )
            await MainActor.run {
                guard self.currentRunID == runID else { return }
                if self.cancelledRunIDs.contains(runID) {
                    for idx in self.results.indices where !self.results[idx].status.isTerminal {
                        self.results[idx].status = .cancelled
                    }
                }
                self.isRunning = false
                if self.finishedAt == nil {
                    self.finishedAt = Date()
                }
            }
        }
        activeBatchTask = task
        return task
    }

    private func runBoundedTaskGroup(
        runID: UUID,
        sessions: [Session],
        payload: BatchJobPayload,
        limit: Int,
        timeoutSeconds: TimeInterval,
        provider: @escaping SessionClientProvider
    ) async {
        var iterator = sessions.makeIterator()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(limit, sessions.count) {
                guard let session = iterator.next() else { break }
                group.addTask { [weak self] in
                    await Self.processHost(
                        manager: self,
                        runID: runID,
                        session: session,
                        payload: payload,
                        timeoutSeconds: timeoutSeconds,
                        provider: provider
                    )
                }
            }

            while await group.next() != nil {
                if Task.isCancelled {
                    break
                }
                if let nextSession = iterator.next() {
                    group.addTask { [weak self] in
                        await Self.processHost(
                            manager: self,
                            runID: runID,
                            session: nextSession,
                            payload: payload,
                            timeoutSeconds: timeoutSeconds,
                            provider: provider
                        )
                    }
                }
            }
        }
    }

    private nonisolated static func runWithTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let clamped = clampTimeout(seconds)
        let nanos = UInt64(clamped * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw HostTimeoutError()
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func processHost(
        manager: BatchOperationsManager?,
        runID: UUID,
        session: Session,
        payload: BatchJobPayload,
        timeoutSeconds: TimeInterval,
        provider: @escaping SessionClientProvider
    ) async {
        if Task.isCancelled {
            await manager?.applyCancelled(runID: runID, sessionID: session.id)
            return
        }

        let shouldContinue = await manager?.markHostRunning(runID: runID, sessionID: session.id) ?? false
        guard shouldContinue else { return }

        let startNs = DispatchTime.now().uptimeNanoseconds
        var createdClient: (any SSHSessionProtocol)?

        do {
            try Task.checkCancellation()
            let client = try await provider(session)
            createdClient = client
            try Task.checkCancellation()

            switch payload {
            case .command(let command):
                guard !command.isEmpty else {
                    throw NSError(
                        domain: "ApexSSH.Batch",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "执行命令不能为空"]
                    )
                }
                let result = try await runWithTimeout(seconds: timeoutSeconds) {
                    try await client.executeCommandWithResult(command)
                }
                if Task.isCancelled {
                    await manager?.applyCancelled(runID: runID, sessionID: session.id)
                } else {
                    await manager?.applyCommandResult(runID: runID, sessionID: session.id, result: result)
                }

            case .fileUpload(let localURLs, let remoteDirectory, let createRemoteDirectory):
                guard !localURLs.isEmpty else {
                    throw NSError(
                        domain: "ApexSSH.Batch",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "未选择任何待分发的本地文件"]
                    )
                }
                let uploadedPaths = try await runWithTimeout(seconds: timeoutSeconds) { [weak manager] in
                    if createRemoteDirectory, let mkdirCmd = makeRemoteDirectoryCommand(for: remoteDirectory) {
                        let mkdirResult = try await client.executeCommandWithResult(mkdirCmd)
                        if mkdirResult.exitCode != 0 {
                            let detail = [mkdirResult.stderr, mkdirResult.stdout]
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                                .joined(separator: " ")
                            throw NSError(
                                domain: "ApexSSH.Batch",
                                code: Int(mkdirResult.exitCode),
                                userInfo: [NSLocalizedDescriptionKey: detail.isEmpty ? "创建远端目录失败 (退出码 \(mkdirResult.exitCode))" : "创建远端目录失败: \(detail)"]
                            )
                        }
                    }
                    let totalFiles = localURLs.count
                    var paths: [String] = []
                    for (index, localURL) in localURLs.enumerated() {
                        try Task.checkCancellation()
                        let targetPath = resolvedRemoteFilePath(localURL: localURL, remoteDirectory: remoteDirectory)
                        try await client.uploadFile(localURL: localURL, remotePath: targetPath) { [weak manager] fraction in
                            let clamped = max(0.0, min(1.0, fraction))
                            let combined = (Double(index) + clamped) / Double(totalFiles)
                            Task { @MainActor [weak manager] in
                                manager?.updateHostProgress(runID: runID, sessionID: session.id, progress: combined)
                            }
                        }
                        paths.append(targetPath)
                    }
                    return paths
                }

                if Task.isCancelled {
                    await manager?.applyCancelled(runID: runID, sessionID: session.id)
                } else {
                    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                    let summary = uploadedPaths.joined(separator: "\n")
                    await manager?.applyUploadSuccess(
                        runID: runID,
                        sessionID: session.id,
                        summary: summary,
                        targetPath: uploadedPaths.last,
                        durationMs: elapsedMs
                    )
                }
            }
        } catch is CancellationError {
            await manager?.applyCancelled(runID: runID, sessionID: session.id)
        } catch is HostTimeoutError {
            if Task.isCancelled {
                await manager?.applyCancelled(runID: runID, sessionID: session.id)
            } else {
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                await manager?.applyFailure(
                    runID: runID,
                    sessionID: session.id,
                    message: "执行超时",
                    durationMs: elapsedMs
                )
            }
        } catch {
            if Task.isCancelled {
                await manager?.applyCancelled(runID: runID, sessionID: session.id)
            } else {
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
                await manager?.applyFailure(
                    runID: runID,
                    sessionID: session.id,
                    message: error.localizedDescription,
                    durationMs: elapsedMs
                )
            }
        }

        if let createdClient {
            await createdClient.disconnect()
        }
    }

    private func isRunActive(_ runID: UUID) -> Bool {
        currentRunID == runID && !cancelledRunIDs.contains(runID)
    }

    private func markHostRunning(runID: UUID, sessionID: UUID) -> Bool {
        guard isRunActive(runID),
              let idx = results.firstIndex(where: { $0.sessionID == sessionID }) else {
            return false
        }
        results[idx].status = .running
        results[idx].progress = 0.05
        return true
    }

    private func updateHostProgress(runID: UUID, sessionID: UUID, progress: Double) {
        guard isRunActive(runID),
              let idx = results.firstIndex(where: { $0.sessionID == sessionID }),
              results[idx].status == .running else {
            return
        }
        results[idx].progress = max(results[idx].progress, min(1.0, progress))
    }

    private func applyCommandResult(runID: UUID, sessionID: UUID, result: SSHCommandResult) {
        guard isRunActive(runID),
              let idx = results.firstIndex(where: { $0.sessionID == sessionID }) else {
            return
        }
        results[idx].exitCode = result.exitCode
        results[idx].stdout = result.stdout
        results[idx].stderr = result.stderr
        results[idx].durationMs = result.durationMs
        results[idx].progress = 1.0
        if result.exitCode == 0 {
            results[idx].status = .succeeded
        } else {
            results[idx].status = .failed("退出码 \(result.exitCode)")
        }
    }

    private func applyUploadSuccess(
        runID: UUID,
        sessionID: UUID,
        summary: String,
        targetPath: String?,
        durationMs: Double
    ) {
        guard isRunActive(runID),
              let idx = results.firstIndex(where: { $0.sessionID == sessionID }) else {
            return
        }
        results[idx].status = .succeeded
        results[idx].exitCode = 0
        results[idx].stdout = summary
        results[idx].stderr = ""
        results[idx].durationMs = durationMs
        results[idx].progress = 1.0
        if let targetPath {
            results[idx].remoteTargetPath = targetPath
        }
    }

    private func applyFailure(runID: UUID, sessionID: UUID, message: String, durationMs: Double) {
        guard isRunActive(runID),
              let idx = results.firstIndex(where: { $0.sessionID == sessionID }) else {
            return
        }
        results[idx].status = .failed(message)
        results[idx].stderr = message
        results[idx].durationMs = durationMs
    }

    private func applyCancelled(runID: UUID, sessionID: UUID) {
        guard currentRunID == runID,
              let idx = results.firstIndex(where: { $0.sessionID == sessionID }),
              !results[idx].status.isTerminal else {
            return
        }
        results[idx].status = .cancelled
    }

    private static func deduplicatedSessions(_ sessions: [Session]) -> [Session] {
        var seen: Set<UUID> = []
        var unique: [Session] = []
        for session in sessions where seen.insert(session.id).inserted {
            unique.append(session)
        }
        return unique
    }

    // MARK: - Export (CSV & Markdown)

    public func exportResultsCSV() -> String {
        var lines: [String] = ["Host,Address,Status,ExitCode,DurationMs,OutputSummary,Stderr"]
        for item in results {
            let exitText = item.exitCode.map(String.init) ?? ""
            let durationText = item.durationMs.map { String(format: "%.2f", $0) } ?? ""
            let summary = Self.compactSummary(stdout: item.stdout, stderr: item.stderr)
            let row = [
                item.hostName,
                item.hostAddress,
                item.status.displayLabel,
                exitText,
                durationText,
                summary,
                item.stderr
            ].map(Self.escapeCSVField)
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    public func exportResultsMarkdown() -> String {
        var lines: [String] = []
        lines.append("# AetherTerm 批量执行报告")
        lines.append("")
        switch lastJobPayload {
        case .command(let cmd):
            lines.append("- 模式: 批量执行命令")
            lines.append("- 命令: `\(cmd.replacingOccurrences(of: "`", with: "\\`"))`")
        case .fileUpload(let urls, let dir, _):
            lines.append("- 模式: 批量分发文件")
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            lines.append("- 文件: `\(names)` -> `\(dir)`")
        case .none:
            lines.append("- 模式: \(currentMode.rawValue)")
        }
        lines.append("- 统计: 共 \(totalCount) 台 | 成功 \(succeededCount) | 失败 \(failedCount) | 已取消 \(cancelledCount)")
        lines.append("")
        lines.append("| 主机 | 地址 | 状态 | 退出码 | 耗时 (ms) | 输出摘要 |")
        lines.append("| --- | --- | --- | --- | --- | --- |")

        for item in results {
            let exitText = item.exitCode.map(String.init) ?? "-"
            let durationText = item.durationMs.map { String(format: "%.2f", $0) } ?? "-"
            let summary = Self.compactSummary(stdout: item.stdout, stderr: item.stderr)
            let cells = [
                item.hostName,
                item.hostAddress,
                item.status.displayLabel,
                exitText,
                durationText,
                summary
            ].map(Self.escapeMarkdownTableCell)
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func compactSummary(stdout: String, stderr: String) -> String {
        let trimmedOut = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOut.isEmpty && !trimmedErr.isEmpty {
            return "\(trimmedOut) [stderr: \(trimmedErr)]"
        }
        if !trimmedOut.isEmpty {
            return trimmedOut
        }
        if !trimmedErr.isEmpty {
            return trimmedErr
        }
        return "-"
    }

    private static func escapeCSVField(_ value: String) -> String {
        let needsQuotes = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
        guard needsQuotes else { return value }
        let doubled = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(doubled)\""
    }

    private static func escapeMarkdownTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
            .replacingOccurrences(of: "|", with: "\\|")
    }
}
