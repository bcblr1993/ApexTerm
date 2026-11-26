import Foundation
import ApexCore

/// Represents a parsed shell integration or directory notification OSC sequence.
public enum OSC133Event: Sendable, Equatable {
    /// `OSC 133 ; A` — Fresh prompt started
    case promptStart
    /// `OSC 133 ; B` — Prompt ended, command input started
    case commandStart
    /// `OSC 133 ; C [; commandLine]` — Command execution started (output begins)
    case commandExecuted(commandLine: String?)
    /// `OSC 133 ; D [; exitCode]` — Command finished with optional exit code
    case commandFinished(exitCode: Int)
    /// `OSC 7 ; file://host/path` or `OSC 1337 ; CurrentDir=/path` — Working directory update
    case workingDirectory(path: String)
}

/// Metadata record for a single shell command lifecycle tracked via OSC 133.
public struct CommandExecutionRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var commandText: String?
    public var promptStartLine: Int
    public var commandStartLine: Int
    public var outputStartLine: Int
    public var outputEndLine: Int?
    public var startedAt: Date
    public var finishedAt: Date?
    public var durationMs: Int?
    public var exitCode: Int?
    public var workingDirectory: String?

    public init(
        id: UUID = UUID(),
        commandText: String? = nil,
        promptStartLine: Int,
        commandStartLine: Int,
        outputStartLine: Int,
        outputEndLine: Int? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        durationMs: Int? = nil,
        exitCode: Int? = nil,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.commandText = commandText
        self.promptStartLine = promptStartLine
        self.commandStartLine = commandStartLine
        self.outputStartLine = outputStartLine
        self.outputEndLine = outputEndLine
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMs = durationMs
        self.exitCode = exitCode
        self.workingDirectory = workingDirectory
    }

    public var isSuccess: Bool {
        exitCode == 0
    }

    public var isFailed: Bool {
        guard let code = exitCode else { return false }
        return code != 0
    }

    public var formattedDuration: String {
        guard let ms = durationMs else { return "运行中" }
        if ms < 1000 {
            return "\(ms)ms"
        } else if ms < 60_000 {
            return String(format: "%.2fs", Double(ms) / 1000.0)
        } else {
            let mins = ms / 60_000
            let secs = (ms % 60_000) / 1000
            return "\(mins)m \(secs)s"
        }
    }
}

/// Thread-safe tracker for OSC 133 FinalTerm / iTerm2 / VSCode shell integration markers,
/// command duration & exit codes, and prompt line bookmarks.
public final class ShellIntegrationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let maxRecords: Int
    private var records: [CommandExecutionRecord] = []
    private var promptLines: [Int] = []
    private var currentPromptLine: Int?
    private var currentCommandLine: Int?
    private var promptPrefixSnapshot: String?
    private var activeRecord: CommandExecutionRecord?
    private var _workingDirectory: String?
    private var _onCommandCompleted: (@Sendable (CommandExecutionRecord) -> Void)?

    /// Optional callback invoked strictly outside the internal lock whenever an OSC 133 `D` command finishes.
    public var onCommandCompleted: (@Sendable (CommandExecutionRecord) -> Void)? {
        get { lock.withLock { _onCommandCompleted } }
        set { lock.withLock { _onCommandCompleted = newValue } }
    }

    public init(maxRecords: Int = 500) {
        self.maxRecords = max(1, maxRecords)
    }

    /// Parses the inner payload of an OSC sequence (between `\e]` and `\a` or `\e\\`).
    public static func parseOSCPayload(_ payload: String) -> OSC133Event? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("133;") {
            let body = String(trimmed.dropFirst(4))
            let parts = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard let marker = parts.first?.uppercased(), let firstChar = marker.first else {
                return nil
            }
            switch firstChar {
            case "A":
                return .promptStart
            case "B":
                return .commandStart
            case "C":
                if parts.count >= 2 {
                    let cmd = parts.dropFirst().joined(separator: ";").trimmingCharacters(in: .whitespacesAndNewlines)
                    return .commandExecuted(commandLine: cmd.isEmpty ? nil : cmd)
                }
                return .commandExecuted(commandLine: nil)
            case "D":
                if parts.count >= 2, let code = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return .commandFinished(exitCode: code)
                }
                return .commandFinished(exitCode: 0)
            default:
                return nil
            }
        } else if trimmed.hasPrefix("7;") {
            let rawURI = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = parseOSC7FileURI(rawURI) {
                return .workingDirectory(path: path)
            }
            return nil
        } else if trimmed.hasPrefix("1337;") {
            let body = String(trimmed.dropFirst(5))
            for segment in body.split(separator: ";") {
                let s = String(segment).trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("CurrentDir=") {
                    let dir = String(s.dropFirst("CurrentDir=".count))
                    if !dir.isEmpty {
                        return .workingDirectory(path: dir)
                    }
                }
            }
            return nil
        }
        return nil
    }

    private static func parseOSC7FileURI(_ rawURI: String) -> String? {
        if rawURI.hasPrefix("file://") {
            let withoutScheme = String(rawURI.dropFirst("file://".count))
            guard let slashIdx = withoutScheme.firstIndex(of: "/") else { return nil }
            let encodedPath = String(withoutScheme[slashIdx...])
            let decoded = encodedPath.removingPercentEncoding ?? encodedPath
            return decoded.isEmpty ? nil : decoded
        } else if rawURI.hasPrefix("/") {
            return rawURI.isEmpty ? nil : rawURI
        }
        return nil
    }

    /// Returns the line index recorded by `OSC 133;B` if a command input is active.
    public var activeCommandLineIndex: Int? {
        lock.withLock { currentCommandLine }
    }

    /// Processes a raw OSC payload and updates prompt bookmarks and command execution records.
    public func handleOSCPayload(
        _ payload: String,
        currentLineIndex: Int,
        activeLineText: String? = nil,
        timestamp: Date = Date(),
        fallbackCommandLineText: String? = nil
    ) {
        guard let event = Self.parseOSCPayload(payload) else { return }
        var completedRecord: CommandExecutionRecord?
        var completionCallback: (@Sendable (CommandExecutionRecord) -> Void)?
        lock.lock()

        switch event {
        case .promptStart:
            // If a previous command never emitted D before next prompt A, close its output boundary
            if var dangling = activeRecord {
                dangling.outputEndLine = currentLineIndex
                dangling.finishedAt = timestamp
                dangling.durationMs = max(0, Int((timestamp.timeIntervalSince(dangling.startedAt) * 1000.0).rounded()))
                appendRecordLocked(dangling)
                activeRecord = nil
            }
            currentPromptLine = currentLineIndex
            currentCommandLine = nil
            promptPrefixSnapshot = nil
            appendPromptLineLocked(currentLineIndex)

        case .commandStart:
            currentCommandLine = currentLineIndex
            if currentPromptLine == nil {
                currentPromptLine = currentLineIndex
            }
            appendPromptLineLocked(currentPromptLine ?? currentLineIndex)
            promptPrefixSnapshot = activeLineText

        case .commandExecuted(let explicitCommand):
            let pLine = currentPromptLine ?? currentLineIndex
            let cLine = currentCommandLine ?? currentLineIndex
            appendPromptLineLocked(pLine)

            var extractedCommand = explicitCommand
            if extractedCommand == nil {
                let candidateRaw = [activeLineText, fallbackCommandLineText].compactMap { $0 }.first {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if let rawSource = candidateRaw {
                    let cleanActive = Self.stripANSI(rawSource)
                    if let prefix = promptPrefixSnapshot {
                        let cleanPrefix = Self.stripANSI(prefix)
                        if cleanActive.hasPrefix(cleanPrefix) {
                            let candidate = String(cleanActive.dropFirst(cleanPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !candidate.isEmpty {
                                extractedCommand = candidate
                            }
                        }
                    }
                    if extractedCommand == nil {
                        let candidate = Self.stripCommonPromptPrefix(cleanActive)
                        if !candidate.isEmpty {
                            extractedCommand = candidate
                        }
                    }
                }
            }

            let outputStart = (currentLineIndex > cLine) ? currentLineIndex : currentLineIndex + 1
            activeRecord = CommandExecutionRecord(
                commandText: extractedCommand,
                promptStartLine: pLine,
                commandStartLine: cLine,
                outputStartLine: outputStart,
                outputEndLine: nil,
                startedAt: timestamp,
                finishedAt: nil,
                durationMs: nil,
                exitCode: nil,
                workingDirectory: _workingDirectory
            )

        case .commandFinished(let exitCode):
            if var current = activeRecord {
                current.exitCode = exitCode
                current.finishedAt = timestamp
                current.outputEndLine = max(current.outputStartLine, currentLineIndex)
                current.durationMs = max(0, Int((timestamp.timeIntervalSince(current.startedAt) * 1000.0).rounded()))
                appendRecordLocked(current)
                completedRecord = current
                activeRecord = nil
            } else if let pLine = currentPromptLine {
                // Standalone D without C (e.g., empty return or minimal shell integration)
                let record = CommandExecutionRecord(
                    commandText: nil,
                    promptStartLine: pLine,
                    commandStartLine: currentCommandLine ?? pLine,
                    outputStartLine: pLine + 1,
                    outputEndLine: max(pLine + 1, currentLineIndex),
                    startedAt: timestamp,
                    finishedAt: timestamp,
                    durationMs: 0,
                    exitCode: exitCode,
                    workingDirectory: _workingDirectory
                )
                appendRecordLocked(record)
                completedRecord = record
            }
            completionCallback = _onCommandCompleted
            currentPromptLine = nil
            currentCommandLine = nil
            promptPrefixSnapshot = nil

        case .workingDirectory(let path):
            _workingDirectory = path
        }
        lock.unlock()

        if let completedRecord {
            completionCallback?(completedRecord)
        }
    }

    private func appendRecordLocked(_ record: CommandExecutionRecord) {
        records.append(record)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
    }

    private func appendPromptLineLocked(_ line: Int) {
        guard line >= 0 else { return }
        if promptLines.last != line {
            if let insertIdx = promptLines.firstIndex(where: { $0 >= line }) {
                if promptLines[insertIdx] != line {
                    promptLines.insert(line, at: insertIdx)
                }
            } else {
                promptLines.append(line)
            }
            if promptLines.count > maxRecords {
                promptLines.removeFirst(promptLines.count - maxRecords)
            }
        }
    }

    private static func stripANSI(_ raw: String) -> String {
        let spans = VTParser().parseANSI(raw)
        return spans.map(\.text).joined()
    }

    private static func stripCommonPromptPrefix(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        for marker in ["$ ", "# ", "% ", "❯ ", "➜ "] {
            if let range = trimmed.range(of: marker) {
                return String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    // MARK: - Queries & Prompt Bookmark Navigation

    public func allRecords() -> [CommandExecutionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    public func failedRecords() -> [CommandExecutionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.filter(\.isFailed)
    }

    public var lastCompletedRecord: CommandExecutionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.last
    }

    public var inFlightRecord: CommandExecutionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return activeRecord
    }

    public var workingDirectory: String? {
        lock.lock()
        defer { lock.unlock() }
        return _workingDirectory
    }

    public func allPromptLines() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return promptLines
    }

    /// Returns the nearest prompt bookmark strictly before `lineIndex`.
    public func previousPromptLine(before lineIndex: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return promptLines.last(where: { $0 < lineIndex })
    }

    /// Returns the nearest prompt bookmark strictly after `lineIndex`.
    public func nextPromptLine(after lineIndex: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return promptLines.first(where: { $0 > lineIndex })
    }

    /// Returns the command execution record whose prompt or output span covers `lineIndex`.
    public func record(atLine lineIndex: Int) -> CommandExecutionRecord? {
        lock.lock()
        defer { lock.unlock() }
        if let active = activeRecord {
            let activeEnd = max(active.outputStartLine, active.promptStartLine)
            if lineIndex >= active.promptStartLine && lineIndex <= activeEnd {
                return active
            }
        }
        return records.last { rec in
            let endLine = rec.outputEndLine ?? max(rec.outputStartLine, rec.promptStartLine)
            return lineIndex >= rec.promptStartLine && lineIndex <= endLine
        }
    }

    /// Returns the most recent failed command record strictly before `lineIndex`.
    public func previousFailedRecord(before lineIndex: Int) -> CommandExecutionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.last { $0.isFailed && $0.promptStartLine < lineIndex }
    }

    /// Returns the earliest failed command record strictly after `lineIndex`.
    public func nextFailedRecord(after lineIndex: Int) -> CommandExecutionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.isFailed && $0.promptStartLine > lineIndex }
    }

    /// Returns the latest failed command record regardless of scroll position.
    public func latestFailedRecord() -> CommandExecutionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records.last(where: \.isFailed)
    }

    /// Returns the most recent `limit` command records in chronological order.
    public func timelineRecords(limit: Int = 50) -> [CommandExecutionRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0 else { return [] }
        return Array(records.suffix(limit))
    }

    public func reset() {
        lock.lock()
        records.removeAll()
        promptLines.removeAll()
        currentPromptLine = nil
        currentCommandLine = nil
        promptPrefixSnapshot = nil
        activeRecord = nil
        _workingDirectory = nil
        lock.unlock()
    }
}

@MainActor
extension DesktopNotificationManager {
    /// Evaluates a completed OSC 133 `CommandExecutionRecord` against user notification rules.
    public func handleCommandCompleted(
        record: CommandExecutionRecord,
        tabID: UUID,
        sessionTitle: String
    ) {
        handleCommandCompleted(
            commandText: record.commandText,
            durationMs: record.durationMs,
            exitCode: record.exitCode,
            workingDirectory: record.workingDirectory,
            formattedDuration: record.formattedDuration,
            tabID: tabID,
            sessionTitle: sessionTitle
        )
    }
}
