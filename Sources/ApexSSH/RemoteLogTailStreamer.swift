import Foundation
import ApexCore
import os

#if canImport(Darwin)
import Darwin
#endif

/// Single line entry displayed by `RemoteLogTailSheet`.
public struct RemoteLogLine: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// Lifecycle state for a remote `tail -n 500 -F` stream.
public enum RemoteLogTailState: Equatable, Sendable {
    case idle
    case connecting
    case streaming
    case paused
    case stopped
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .connecting, .streaming, .paused:
            return true
        case .idle, .stopped, .failed:
            return false
        }
    }
}

/// Real-time remote log tail streamer (`tail -n 500 -F -- <quotedPath>`) with ANSI stripping,
/// bounded ring buffer, pause/resume buffering, live keyword/regex filter, and clean process termination.
@MainActor
public final class RemoteLogTailStreamer: ObservableObject {
    public typealias StreamFactory = @Sendable (_ remotePath: String, _ initialLines: Int) -> AsyncThrowingStream<String, Error>

    @Published public private(set) var lines: [RemoteLogLine] = []
    @Published public private(set) var state: RemoteLogTailState = .idle
    @Published public var isAutoScrollEnabled: Bool = true
    @Published public private(set) var isPaused: Bool = false
    @Published public var filterQuery: String = "" {
        didSet { recomputeFilterRegex() }
    }
    @Published public var isRegexFilter: Bool = false {
        didSet { recomputeFilterRegex() }
    }
    @Published public var wrapLines: Bool = false
    @Published public private(set) var droppedLineCount: Int = 0
    @Published public private(set) var pendingPausedCount: Int = 0
    @Published public private(set) var regexError: String? = nil

    public let remotePath: String
    public let initialLines: Int
    public let maxLines: Int

    private let session: SSHSessionProtocol?
    private let streamFactory: StreamFactory?
    private var nextLineID: Int = 1
    private var pausedBuffer: [RemoteLogLine] = []
    private var streamTask: Task<Void, Never>?
    private var compiledRegex: NSRegularExpression?

    public init(
        remotePath: String,
        session: SSHSessionProtocol? = nil,
        initialLines: Int = 500,
        maxLines: Int = 10_000,
        streamFactory: StreamFactory? = nil
    ) {
        self.remotePath = remotePath
        self.session = session
        self.initialLines = max(1, initialLines)
        self.maxLines = max(1, maxLines)
        self.streamFactory = streamFactory
    }

    deinit {
        streamTask?.cancel()
    }

    // MARK: - Pure Helpers

    /// Builds a shell-safe `tail -n <N> -F -- <quotedPath>` command.
    nonisolated public static func buildTailCommand(remotePath: String, initialLines: Int = 500) -> String? {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\0"),
              !trimmed.split(separator: "/").contains("..") else {
            return nil
        }
        let lineCount = max(1, initialLines)
        let quoted = SFTPRemoteOperations.shellQuotedRemotePath(trimmed)
        return "tail -n \(lineCount) -F -- \(quoted)"
    }

    /// Strips ANSI CSI/OSC escape sequences and trailing carriage returns from a streamed log line.
    nonisolated public static func cleanLogLine(_ rawLine: String) -> String {
        let stripped = SessionLogger.stripANSI(from: rawLine)
        return stripped.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    }

    // MARK: - Filtering & Export

    public var filteredLines: [RemoteLogLine] {
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return lines }
        if isRegexFilter {
            guard let regex = compiledRegex else { return [] }
            return lines.filter { line in
                let range = NSRange(location: 0, length: (line.text as NSString).length)
                return regex.firstMatch(in: line.text, options: [], range: range) != nil
            }
        } else {
            return lines.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
        }
    }

    public var filteredOutputText: String {
        filteredLines.map(\.text).joined(separator: "\n")
    }

    private func recomputeFilterRegex() {
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRegexFilter, !trimmed.isEmpty else {
            compiledRegex = nil
            regexError = nil
            return
        }
        do {
            compiledRegex = try NSRegularExpression(pattern: trimmed, options: [.caseInsensitive])
            regexError = nil
        } catch {
            compiledRegex = nil
            regexError = error.localizedDescription
        }
    }

    // MARK: - Stream Lifecycle

    public func start() {
        stop(resetState: false)
        state = .connecting

        let factory: StreamFactory
        if let streamFactory {
            factory = streamFactory
        } else if let session {
            factory = { path, count in
                Self.makeSessionStream(session: session, remotePath: path, initialLines: count)
            }
        } else {
            state = .failed("未提供可用的 SSH 会话")
            return
        }

        let targetPath = remotePath
        let count = initialLines
        let stream = factory(targetPath, count)

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = self.isPaused ? .paused : .streaming
            do {
                for try await rawChunk in stream {
                    if Task.isCancelled { break }
                    let sublines = rawChunk
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                        .components(separatedBy: "\n")
                    self.appendLines(sublines, skipTrailingEmptyFromSplit: rawChunk.hasSuffix("\n"))
                }
                if !Task.isCancelled && self.state.isActive {
                    self.state = .stopped
                }
            } catch is CancellationError {
                if self.state != .stopped {
                    self.state = .stopped
                }
            } catch {
                if Task.isCancelled {
                    self.state = .stopped
                } else {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    public func stop() {
        stop(resetState: true)
    }

    private func stop(resetState: Bool) {
        streamTask?.cancel()
        streamTask = nil
        isPaused = false
        pausedBuffer.removeAll()
        pendingPausedCount = 0
        if resetState {
            state = .stopped
        }
    }

    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        if state == .streaming {
            state = .paused
        }
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        if !pausedBuffer.isEmpty {
            appendEntriesToRingBuffer(pausedBuffer)
            pausedBuffer.removeAll()
            pendingPausedCount = 0
        }
        if state == .paused {
            state = .streaming
        }
    }

    public func togglePause() {
        if isPaused {
            resume()
        } else {
            pause()
        }
    }

    public func clear() {
        lines.removeAll()
        pausedBuffer.removeAll()
        pendingPausedCount = 0
        droppedLineCount = 0
    }

    // MARK: - Line Ingestion & Ring Buffer

    public func appendLine(_ rawLine: String) {
        let cleaned = Self.cleanLogLine(rawLine)
        let entry = RemoteLogLine(id: nextLineID, text: cleaned)
        nextLineID += 1
        ingest([entry])
    }

    private func appendLines(_ rawLines: [String], skipTrailingEmptyFromSplit: Bool) {
        let count = skipTrailingEmptyFromSplit ? max(0, rawLines.count - 1) : rawLines.count
        guard count > 0 else { return }
        var entries: [RemoteLogLine] = []
        entries.reserveCapacity(count)
        for idx in 0..<count {
            let cleaned = Self.cleanLogLine(rawLines[idx])
            entries.append(RemoteLogLine(id: nextLineID, text: cleaned))
            nextLineID += 1
        }
        ingest(entries)
    }

    private func ingest(_ entries: [RemoteLogLine]) {
        guard !entries.isEmpty else { return }
        if isPaused {
            pausedBuffer.append(contentsOf: entries)
            if pausedBuffer.count > maxLines {
                let overflow = pausedBuffer.count - maxLines
                pausedBuffer.removeFirst(overflow)
                droppedLineCount += overflow
            }
            pendingPausedCount = pausedBuffer.count
        } else {
            appendEntriesToRingBuffer(entries)
        }
    }

    private func appendEntriesToRingBuffer(_ entries: [RemoteLogLine]) {
        lines.append(contentsOf: entries)
        if lines.count > maxLines {
            let overflow = lines.count - maxLines
            lines.removeFirst(overflow)
            droppedLineCount += overflow
        }
    }

    // MARK: - SSH / Local / Mock Stream Runners

    nonisolated private static func makeSessionStream(
        session: SSHSessionProtocol,
        remotePath: String,
        initialLines: Int
    ) -> AsyncThrowingStream<String, Error> {
        guard let tailCommand = buildTailCommand(remotePath: remotePath, initialLines: initialLines) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(
                    domain: "ApexSSH.RemoteLogTail",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "无效的远程日志路径"]
                ))
            }
        }

        if let nativeSession = session as? NativeSSHSession {
            return makeNativeSSHStream(nativeSession: nativeSession, tailCommand: tailCommand)
        }

        if session is LocalTerminalSession {
            return makeLocalTailStream(remotePath: remotePath, initialLines: initialLines)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = try await session.executeCommand(tailCommand)
                    if !output.isEmpty {
                        continuation.yield(output)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    nonisolated private static func makeLocalTailStream(
        remotePath: String,
        initialLines: Int
    ) -> AsyncThrowingStream<String, Error> {
        let expandedPath = LocalTerminalSession.expandPath(remotePath)
        return makeProcessLineStream(
            executableURL: URL(fileURLWithPath: "/usr/bin/tail"),
            arguments: ["-n", "\(max(1, initialLines))", "-F", "--", expandedPath],
            grants: nil,
            accesses: []
        )
    }

    nonisolated private static func makeNativeSSHStream(
        nativeSession: NativeSSHSession,
        tailCommand: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let processBox = OSAllocatedUnfairLock<Process?>(initialState: nil)
            let grantsBox = OSAllocatedUnfairLock<ChildProcessFileGrants?>(initialState: nil)
            let accessesBox = OSAllocatedUnfairLock<[FileAccessLease]>(initialState: [])

            let task = Task.detached(priority: .userInitiated) {
                do {
                    let resolvedSecret = await SSHTunnelManager.resolveSecret(for: nativeSession.session)
                    let keyAccess = try nativeSession.acquirePrivateKeyAccess()
                    let certAccess = try nativeSession.acquireCertificateAccess()
                    let leases = [keyAccess, certAccess].compactMap { $0 }
                    accessesBox.withLock { $0 = leases }

                    let authArgs = nativeSession.sshAuthArgs(
                        privateKeyURL: keyAccess?.url,
                        certificateURL: certAccess?.url
                    )
                    let jumpArgs = nativeSession.advancedConnectionArgs(channel: .nonInteractiveSSH)
                    let ctrlArgs = nativeSession.controlMasterArguments
                    let host = strippedDestinationHost(nativeSession.session.host)
                    let target = "\(nativeSession.session.username)@\(host)"
                    let channel = DistributionChannel.current

                    var binaryPath = "/usr/bin/ssh"
                    var args: [String]
                    let hasStoreAuth = channel == .appStore && !(resolvedSecret?.isEmpty ?? true)
                    if let secret = resolvedSecret, !secret.isEmpty,
                       let passBin = nativeSession.sshpassExecutablePath {
                        binaryPath = passBin
                        args = nativeSession.sshpassArguments(secret: secret, tool: "/usr/bin/ssh") + [
                            "-o", "StrictHostKeyChecking=accept-new",
                            "-o", "ConnectTimeout=10",
                        ] + authArgs + jumpArgs + ctrlArgs + [
                            "-p", "\(nativeSession.session.port)",
                            target,
                            tailCommand
                        ]
                    } else {
                        args = (hasStoreAuth ? [] : ["-o", "BatchMode=yes"]) + [
                            "-o", "StrictHostKeyChecking=accept-new",
                            "-o", "ConnectTimeout=10",
                        ] + authArgs + jumpArgs + ctrlArgs + [
                            "-p", "\(nativeSession.session.port)",
                            target,
                            tailCommand
                        ]
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: binaryPath)
                    process.arguments = args
                    process.standardInput = FileHandle.nullDevice

                    if channel == .appStore,
                       let prepared = try nativeSession.prepareStoreCommand(
                           binaryPath: binaryPath,
                           arguments: args,
                           accesses: [keyAccess, certAccess],
                           authenticationSecret: resolvedSecret
                       ) {
                        process.executableURL = URL(fileURLWithPath: prepared.binaryPath)
                        process.arguments = prepared.arguments
                        var env = ProcessInfo.processInfo.environment
                        env[ChildProcessFileGrants.environmentKey] = prepared.grants.fileURL.path
                        process.environment = env
                        grantsBox.withLock { $0 = prepared.grants }
                    }

                    if Task.isCancelled {
                        grantsBox.withLock { $0?.close(); $0 = nil }
                        accessesBox.withLock { $0.forEach { $0.close() }; $0.removeAll() }
                        continuation.finish()
                        return
                    }

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    processBox.withLock { $0 = process }

                    try streamProcessPipes(
                        process: process,
                        stdoutPipe: stdoutPipe,
                        stderrPipe: stderrPipe,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
                grantsBox.withLock { $0?.close(); $0 = nil }
                accessesBox.withLock { $0.forEach { $0.close() }; $0.removeAll() }
            }

            continuation.onTermination = { _ in
                task.cancel()
                if let process = processBox.withLock({ $0 }) {
                    terminateProcessTree(process)
                }
                grantsBox.withLock { $0?.close(); $0 = nil }
                accessesBox.withLock { $0.forEach { $0.close() }; $0.removeAll() }
            }
        }
    }

    nonisolated private static func makeProcessLineStream(
        executableURL: URL,
        arguments: [String],
        grants: ChildProcessFileGrants?,
        accesses: [FileAccessLease]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let task = Task.detached(priority: .userInitiated) {
                defer {
                    grants?.close()
                    accesses.forEach { $0.close() }
                }
                do {
                    try streamProcessPipes(
                        process: process,
                        stdoutPipe: stdoutPipe,
                        stderrPipe: stderrPipe,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                terminateProcessTree(process)
                grants?.close()
                accesses.forEach { $0.close() }
            }
        }
    }

    private final class PipeLineAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var utf8Decoder = UTF8StreamDecoder()
        private var pendingLineBuffer = ""

        func appendChunk(_ chunk: Data) -> String? {
            lock.withLock {
                let decoded = utf8Decoder.decode(chunk)
                pendingLineBuffer.append(decoded)
                if let lastNL = pendingLineBuffer.lastIndex(of: "\n") {
                    let upToNL = String(pendingLineBuffer[...lastNL])
                    pendingLineBuffer = String(pendingLineBuffer[pendingLineBuffer.index(after: lastNL)...])
                    return upToNL
                }
                if pendingLineBuffer.count > 16_384 {
                    let flush = pendingLineBuffer
                    pendingLineBuffer = ""
                    return flush
                }
                return nil
            }
        }

        func finish() -> String {
            lock.withLock {
                let rem = utf8Decoder.finish()
                pendingLineBuffer.append(rem)
                let out = pendingLineBuffer
                pendingLineBuffer = ""
                return out
            }
        }
    }

    nonisolated private static func streamProcessPipes(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws {
        let stderrTail = OSAllocatedUnfairLock(initialState: Data())
        let accumulator = PipeLineAccumulator()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                let trailing = accumulator.finish()
                if !trailing.isEmpty {
                    continuation.yield(trailing)
                }
                return
            }
            if let readyLines = accumulator.appendChunk(chunk), !readyLines.isEmpty {
                continuation.yield(readyLines)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrTail.withLock { buf in
                buf.append(chunk)
                if buf.count > 16_384 {
                    buf = Data(buf.suffix(16_384))
                }
            }
        }

        try process.run()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let trailing = accumulator.finish()
        if !trailing.isEmpty {
            continuation.yield(trailing)
        }

        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        if Task.isCancelled {
            continuation.finish()
            return
        }

        let status = process.terminationStatus
        if status != 0 {
            let errText = stderrTail.withLock { String(decoding: $0, as: UTF8.self) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = errText.isEmpty ? "远程日志追踪进程异常退出 (exit \(status))" : errText
            continuation.finish(throwing: NSError(
                domain: "ApexSSH.RemoteLogTail",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: msg]
            ))
        } else {
            continuation.finish()
        }
    }

    nonisolated private static func strippedDestinationHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    nonisolated private static func descendantPIDs(of parent: pid_t) -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        let direct = children.prefix(Int(count)).filter { $0 > 0 }
        return direct.flatMap { [$0] + descendantPIDs(of: $0) }
    }

    nonisolated private static func terminateProcessTree(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if pid > 0 {
            for child in descendantPIDs(of: pid).reversed() {
                kill(child, SIGTERM)
            }
            kill(pid, SIGTERM)
            usleep(50_000)
            if process.isRunning {
                for child in descendantPIDs(of: pid).reversed() {
                    kill(child, SIGKILL)
                }
                kill(pid, SIGKILL)
            }
        }
    }
}
