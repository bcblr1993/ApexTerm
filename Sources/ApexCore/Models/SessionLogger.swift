import Foundation

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
    
    public var activeFileURL: URL? {
        queue.sync { currentFileURL }
    }
    
    private func setupLogFile() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let dir = URL(fileURLWithPath: self.config.logDirectoryPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let dateStr = formatter.string(from: Date())
            let safeName = self.sessionName.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "_")
            let fileName = "\(dateStr)_\(safeName)_\(self.username)@\(self.host).log"
            let fileURL = dir.appendingPathComponent(fileName)
            
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            self.currentFileURL = fileURL
            self.fileHandle = try? FileHandle(forWritingTo: fileURL)
            self.currentFileSize = 0
            
            // Header stamp
            let header = "=== AetherTerm Session Log Started at \(Date()) ===\n" +
                         "=== Target: \(self.username)@\(self.host) [\(self.sessionName)] ===\n\n"
            if let data = header.data(using: .utf8) {
                self.fileHandle?.seekToEndOfFile()
                self.fileHandle?.write(data)
                self.currentFileSize += UInt64(data.count)
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
                if let string = String(data: rawData, encoding: .utf8) {
                    let cleaned = Self.stripANSI(from: string)
                    dataToWrite = Data(cleaned.utf8)
                } else {
                    dataToWrite = rawData
                }
            } else {
                dataToWrite = rawData
            }
            
            handle.seekToEndOfFile()
            handle.write(dataToWrite)
            self.currentFileSize += UInt64(dataToWrite.count)
            
            // Rotate if exceeds threshold
            let limitBytes = UInt64(self.config.maxFileSizeMB) * 1024 * 1024
            if self.currentFileSize >= limitBytes {
                self.rotateLogFile()
            }
        }
    }
    
    private func rotateLogFile() {
        guard let oldURL = currentFileURL else { return }
        fileHandle?.closeFile()
        fileHandle = nil
        
        // Find next rotation index .1, .2...
        var index = 1
        var rotatedURL: URL
        repeat {
            rotatedURL = oldURL.appendingPathExtension("\(index)")
            index += 1
        } while FileManager.default.fileExists(atPath: rotatedURL.path)
        
        try? FileManager.default.moveItem(at: oldURL, to: rotatedURL)
        
        // Re-open clean active file
        FileManager.default.createFile(atPath: oldURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: oldURL)
        currentFileSize = 0
    }
    
    public func close() {
        queue.sync {
            guard !isClosed else { return }
            isClosed = true
            let footer = "\n=== AetherTerm Session Log Ended at \(Date()) ===\n"
            if let data = footer.data(using: .utf8) {
                fileHandle?.seekToEndOfFile()
                fileHandle?.write(data)
            }
            fileHandle?.closeFile()
            fileHandle = nil
        }
    }
    
    /// Strips ANSI CSI sequences, OSC hyperlinks, and non-printable control bytes
    public static func stripANSI(from text: String) -> String {
        // Regex pattern matches standard ANSI escape sequences: \x1b\[[0-9;]*[a-zA-Z] and OSC \x1b\].*?\x07
        let pattern = "\\x1B(?:\\[[0-?]*[ -/]*[@-~]|\\].*?(?:\\x07|\\x1B\\\\))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        
        // Remove trailing carriage returns
        return stripped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
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
        let promptMarkers = ["$", "#", "%", "❯", "➜", ">"]
        
        var promptIndices: [Int] = []
        for (i, line) in activeLines.enumerated().reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if promptMarkers.contains(where: { marker in
                trimmed.hasSuffix(marker) || trimmed.contains("\(marker) ")
            }) {
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
