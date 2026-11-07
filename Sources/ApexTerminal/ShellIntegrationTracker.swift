import Foundation

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
            return encodedPath.removingPercentEncoding ?? encodedPath
        } else if rawURI.hasPrefix("/") {
            return rawURI
        }
        return nil
    }

    /// Processes a raw OSC payload and updates prompt bookmarks and command execution records.
    public func handleOSCPayload(
        _ payload: String,
        currentLineIndex: Int,
        activeLineText: String? = nil,
        timestamp: Date = Date()
    ) {
        guard let event = Self.parseOSCPayload(payload) else { return }
        lock.lock()
        defer { lock.unlock() }

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
            if extractedCommand == nil, let rawActive = activeLineText {
                let cleanActive = Self.stripANSI(rawActive)
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

            activeRecord = CommandExecutionRecord(
                commandText: extractedCommand,
                promptStartLine: pLine,
                commandStartLine: cLine,
                outputStartLine: currentLineIndex + 1,
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
            }
            currentPromptLine = nil
            currentCommandLine = nil
            promptPrefixSnapshot = nil

        case .workingDirectory(let path):
            _workingDirectory = path
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
