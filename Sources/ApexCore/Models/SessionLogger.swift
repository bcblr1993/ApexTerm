import Foundation
import Darwin

/// Output format for terminal session audit logging
public enum SessionLogFormat: String, CaseIterable, Codable, Sendable {
    case plainText = "纯文本 (过滤控制字符)"
    case rawAnsi   = "原始流 (保留色彩与控制符)"
}

/// Configuration options for automated session audit logging
public struct SessionLogConfig: Codable, Sendable, Equatable {
    public var autoLoggingEnabled: Bool
    public var logDirectoryPath: String
    public var format: SessionLogFormat
    public var maxFileSizeMB: Int
    
    public init(
        autoLoggingEnabled: Bool = false,
        logDirectoryPath: String? = nil,
        format: SessionLogFormat = .plainText,
        maxFileSizeMB: Int = 50
    ) {
        self.autoLoggingEnabled = autoLoggingEnabled
        if let path = logDirectoryPath {
            self.logDirectoryPath = path
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.logDirectoryPath = docs.appendingPathComponent("AetherTerm/Logs", isDirectory: true).path
        }
        self.format = format
        self.maxFileSizeMB = maxFileSizeMB
    }
}

/// Asynchronous, high-throughput session audit logger with automated log rotation
public final class SessionLogger: @unchecked Sendable {
    public let sessionId: UUID
    public let sessionName: String
    public let host: String
    public let username: String
    public let config: SessionLogConfig
    
    private let queue = DispatchQueue(label: "com.apexterm.session-logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentFileURL: URL?
    private var currentFileSize: UInt64 = 0
    private var isClosed = false
    private var _lastWriteError: String?
    private var utf8Decoder = UTF8StreamDecoder()
    private static let ansiRegex = try? NSRegularExpression(
        pattern: "\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\].*?(?:\\x07|\\x1B\\\\)|[()\\*+][0-9A-Za-z]|[78DEHMNOPVWXYZ=<>c~}|])",
        options: []
    )
    private static let controlCharRegex = try? NSRegularExpression(
        pattern: "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]",
        options: []
    )
    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()
    
    public init(
        session: Session,
        config: SessionLogConfig = SessionLogConfig()
    ) {
        self.sessionId = session.id
        self.sessionName = session.name
        self.host = session.host
        self.username = session.username
        self.config = config
        
        setupLogFile()
    }

    deinit {
        try? fileHandle?.close()
    }
    
    public var activeFileURL: URL? {
        queue.sync { currentFileURL }
    }

    public var lastWriteError: String? {
        queue.sync { _lastWriteError }
    }

    private func buildHeaderStamp(isRotation: Bool = false) -> String {
        let marker = isRotation ? "Rotated" : "Started"
        return "=== AetherTerm Session Log \(marker) at \(Date()) ===\n" +
               "=== Target: \(username)@\(host) [\(sessionName)] ===\n\n"
    }

    private func openPrivateLogFile(at fileURL: URL) -> FileHandle? {
        let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd >= 0 {
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        if errno == EEXIST {
            _ = chmod(fileURL.path, 0o600)
            return try? FileHandle(forWritingTo: fileURL)
        }
        _lastWriteError = String(cString: strerror(errno))
        return nil
    }

    private func writeLocked(_ data: Data, to handle: FileHandle) -> Bool {
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            currentFileSize += UInt64(data.count)
            return true
        } catch {
            _lastWriteError = error.localizedDescription
            return false
        }
    }
    
    private func setupLogFile() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let expandedDirPath = (self.config.logDirectoryPath as NSString).expandingTildeInPath
            let dir = URL(fileURLWithPath: expandedDirPath, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                _ = chmod(dir.path, 0o700)
            } catch {
                self._lastWriteError = error.localizedDescription
                return
            }
            
            let dateStr = Self.fileTimestampFormatter.string(from: Date())
            func sanitizeFilenameComponent(_ raw: String, fallback: String) -> String {
                let cleaned = raw
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "\0", with: "")
                    .replacingOccurrences(of: " ", with: "_")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? fallback : cleaned
            }
            let safeName = sanitizeFilenameComponent(self.sessionName, fallback: "session")
            let safeUser = sanitizeFilenameComponent(self.username, fallback: "user")
            let safeHost = sanitizeFilenameComponent(self.host, fallback: "host")
            let uniqueSuffix = UUID().uuidString.prefix(8)
            let fileName = "\(dateStr)_\(safeName)_\(safeUser)@\(safeHost)_\(uniqueSuffix).log"
            let fileURL = dir.appendingPathComponent(fileName)
            
            self.currentFileURL = fileURL
            self.fileHandle = self.openPrivateLogFile(at: fileURL)
            let existingSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
            self.currentFileSize = existingSize
            
            if let handle = self.fileHandle, let data = self.buildHeaderStamp(isRotation: false).data(using: .utf8) {
                _ = self.writeLocked(data, to: handle)
            }
        }
    }
    
    /// Asynchronously writes chunk of raw PTY bytes to the log file
    public func appendData(_ rawData: Data) {
        guard !rawData.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self, !self.isClosed, let handle = self.fileHandle else { return }
            
            let dataToWrite: Data
            if self.config.format == .plainText {
                let decoded = self.utf8Decoder.decode(rawData)
                let cleaned = Self.stripANSI(from: decoded)
                dataToWrite = Data(cleaned.utf8)
            } else {
                dataToWrite = rawData
            }
            
            _ = self.writeLocked(dataToWrite, to: handle)
            
            // Rotate if exceeds threshold
            let limitBytes = UInt64(max(1, self.config.maxFileSizeMB)) * 1024 * 1024
            if self.currentFileSize >= limitBytes {
                self.rotateLogFile()
            }
        }
    }
    
    private func rotateLogFile() {
        guard let oldURL = currentFileURL else { return }
        try? fileHandle?.close()
        fileHandle = nil
        
        // Find next rotation index .1, .2...
        var index = 1
        var rotatedURL: URL
        repeat {
            rotatedURL = oldURL.appendingPathExtension("\(index)")
            index += 1
        } while FileManager.default.fileExists(atPath: rotatedURL.path)
        
        do {
            try FileManager.default.moveItem(at: oldURL, to: rotatedURL)
        } catch {
            _lastWriteError = error.localizedDescription
        }
        
        currentFileSize = 0
        fileHandle = openPrivateLogFile(at: oldURL)
        if let handle = fileHandle, let data = buildHeaderStamp(isRotation: true).data(using: .utf8) {
            _ = writeLocked(data, to: handle)
        }
    }
    
    public func close() {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            if let handle = fileHandle {
                if config.format == .plainText {
                    let trailing = Self.stripANSI(from: utf8Decoder.finish())
                    if !trailing.isEmpty, let trailingData = trailing.data(using: .utf8) {
                        _ = writeLocked(trailingData, to: handle)
                    }
                }
                let footer = "\n=== AetherTerm Session Log Ended at \(Date()) ===\n"
                if let data = footer.data(using: .utf8) {
                    _ = writeLocked(data, to: handle)
                }
                try? handle.close()
            }
            fileHandle = nil
        }
    }
    
    /// Strips ANSI CSI sequences, OSC hyperlinks, and non-printable control bytes
    public static func stripANSI(from text: String) -> String {
        var stripped = text
        if let regex = ansiRegex {
            let range = NSRange(location: 0, length: (stripped as NSString).length)
            stripped = regex.stringByReplacingMatches(in: stripped, options: [], range: range, withTemplate: "")
        }
        
        // Normalize line endings before removing remaining non-printable C0/DEL control bytes.
        stripped = stripped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if let ctrlRegex = controlCharRegex {
            let range = NSRange(location: 0, length: (stripped as NSString).length)
            stripped = ctrlRegex.stringByReplacingMatches(in: stripped, options: [], range: range, withTemplate: "")
        }
        return stripped
    }
}

/// Helper to detect and extract the output block of the most recently executed terminal command
public enum CommandBoundaryDetector {
    
    /// Extracts output between the last command execution line and the trailing prompt
    public static func extractLastCommandOutput(from lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        
        // Filter out trailing blank lines
        var activeLines = lines
        while let last = activeLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            activeLines.removeLast()
        }
        guard activeLines.count >= 2 else { return nil }
        
        // Find last prompt index from bottom up
        // Standard prompt markers: $, #, >, %, ❯, ➜
        let inlineUnanchoredPrompts = ["❯", "➜"]
        let anchoredPrompts = ["$", "#", "%", ">"]
        
        var promptIndices: [Int] = []
        for (i, line) in activeLines.enumerated().reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isPrompt = inlineUnanchoredPrompts.contains { marker in
                trimmed.hasSuffix(marker) || trimmed.contains("\(marker) ")
            } || anchoredPrompts.contains { marker in
                if trimmed.hasSuffix(marker) { return true }
                var searchStart = trimmed.startIndex
                while let range = trimmed.range(of: "\(marker) ", range: searchStart..<trimmed.endIndex) {
                    if range.lowerBound > trimmed.startIndex {
                        let prev = trimmed[trimmed.index(before: range.lowerBound)]
                        if !prev.isWhitespace { return true }
                    }
                    searchStart = range.upperBound
                }
                return false
            }
            if isPrompt {
                promptIndices.append(i)
                if promptIndices.count >= 2 {
                    break
                }
            }
        }
        
        // If we found at least 2 prompts, the output is between promptIndices[1] + 1 and promptIndices[0] - 1
        if promptIndices.count >= 2 {
            let start = promptIndices[1] + 1
            let end = promptIndices[0]
            if start <= end {
                let slice = activeLines[start..<end]
                let joined = slice.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            }
        }
        
        // Fallback: take up to 30 lines preceding the last line
        let end = activeLines.count - 1
        let start = max(0, end - 30)
        let slice = activeLines[start..<end]
        let joined = slice.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}
