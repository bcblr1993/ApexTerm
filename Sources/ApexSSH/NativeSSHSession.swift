import Foundation
import ApexCore

#if canImport(Darwin)
import Darwin
#endif

/// Real native SSH session implementation using Darwin POSIX PTY, bundled standalone sshpass, and real-time probe
public final class NativeSSHSession: SSHSessionProtocol, @unchecked Sendable {
    public let session: Session
    public private(set) var connectionState: SSHConnectionState = .disconnected
    
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var metricsHandler: (@Sendable (ServerMetricsSnapshot) -> Void)?
    private var directoryChangeHandler: (@Sendable (String) -> Void)?
    
    private var ptyMasterFd: Int32 = -1
    private var childPid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var probeTask: Task<Void, Never>?
    
    private let monitor = AgentlessMonitor()
    private var prevCpu: AgentlessMonitor.CpuTickState?
    private var prevNet: AgentlessMonitor.NetTickState?
    private var resolvedPassword: String?
    private var passwordFeedSent = false
    private var recentPromptBuffer = ""
    private var lastReportedDirectory: String?
    private var remoteHomeDirectory: String?
    
    /// Locate bundled sshpass first, then Homebrew/system locations
    public var sshpassExecutablePath: String? {
        let inBundle = Bundle.main.bundlePath + "/Contents/MacOS/sshpass"
        if FileManager.default.isExecutableFile(atPath: inBundle) {
            return inBundle
        }
        let candidates = [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/usr/bin/sshpass"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    
    public init(session: Session) {
        self.session = session
    }
    
    public func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) {
        self.outputHandler = handler
    }
    
    public func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) {
        self.metricsHandler = handler
    }
    
    public func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) {
        self.directoryChangeHandler = handler
    }
    
    private func resolvePasswordIfNeeded() async {
        if resolvedPassword != nil { return }
        switch session.authMethod {
        case .password(let ref):
            if let pw = try? await KeychainStore.shared.get(key: ref) {
                self.resolvedPassword = pw
            } else {
                self.resolvedPassword = ref
            }
        default:
            break
        }
    }
    
    public func connect() async throws {
        self.connectionState = .connecting(step: "Initializing native Darwin PTY...")
        self.passwordFeedSent = false
        
        await resolvePasswordIfNeeded()
        
        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(ws_row: 35, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        
        guard openpty(&master, &slave, nil, nil, &win) == 0 else {
            self.connectionState = .failed("Failed to allocate Darwin PTY")
            throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }
        
        self.ptyMasterFd = master
        
        // Setup command & arguments
        var binaryPath = "/usr/bin/ssh"
        var sshArgs = [
            "-tt",
            "-o", "ServerAliveInterval=\(session.keepAliveIntervalSeconds)",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "\(session.port)",
            "\(session.username)@\(session.host)"
        ]
        
        if let pw = resolvedPassword, !pw.isEmpty, let sshpass = sshpassExecutablePath {
            binaryPath = sshpass
            sshArgs = ["-p", pw, "/usr/bin/ssh"] + sshArgs
        }
        
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        
        var pid: pid_t = 0
        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(binaryPath)]
        for arg in sshArgs {
            cArgs.append(strdup(arg))
        }
        cArgs.append(nil)
        
        var envVars = [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8"
        ]
        let currentEnv = ProcessInfo.processInfo.environment
        if let path = currentEnv["PATH"] {
            envVars.append("PATH=\(path):/usr/local/bin:/opt/homebrew/bin")
        } else {
            envVars.append("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin")
        }
        for (k, v) in currentEnv {
            if k != "TERM" && k != "COLORTERM" && k != "LANG" && k != "LC_ALL" && k != "PATH" {
                envVars.append("\(k)=\(v)")
            }
        }
        var cEnv: [UnsafeMutablePointer<CChar>?] = envVars.map { strdup($0) }
        cEnv.append(nil)
        
        let spawnResult = posix_spawnp(&pid, binaryPath, &fileActions, nil, cArgs, cEnv)
        for ptr in cArgs {
            if let p = ptr { free(p) }
        }
        for ptr in cEnv {
            if let p = ptr { free(p) }
        }
        close(slave)
        
        guard spawnResult == 0 else {
            self.connectionState = .failed("posix_spawn failed with error: \(spawnResult)")
            close(master)
            return
        }
        
        self.childPid = pid
        self.connectionState = .connected
        
        // Setup asynchronous kqueue read source
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue.global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = read(master, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer.prefix(bytesRead))
                self.outputHandler?(data)
                self.parseOSC7DirectoryChange(data: data)
                
                // Fallback auto-feed password if remote prompt asks for password
                if !self.passwordFeedSent, let pw = self.resolvedPassword, !pw.isEmpty {
                    if let str = String(data: data, encoding: .utf8) {
                        let isPrompt = str.range(of: #"[pP]assword\s*:"#, options: .regularExpression) != nil ||
                                       str.range(of: #"[pP]assphrase.*:"#, options: .regularExpression) != nil
                        if isPrompt {
                            self.passwordFeedSent = true
                            let toSend = pw + "\n"
                            if let d = toSend.data(using: .utf8) {
                                _ = d.withUnsafeBytes { raw in
                                    write(master, raw.baseAddress!, raw.count)
                                }
                            }
                        }
                    }
                }
            } else if bytesRead <= 0 {
                source.cancel()
            }
        }
        source.setCancelHandler {
            close(master)
        }
        source.resume()
        self.readSource = source
        
        // Probe user's real home directory after connection
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if let home = await self?.probeRemoteHome(), !home.isEmpty {
                self?.remoteHomeDirectory = home
                self?.directoryChangeHandler?(home)
            }
        }
        
        // Start agentless metrics probe if enabled
        if session.agentlessMonitorEnabled {
            startAgentlessProbeLoop()
        }
    }
    
    public func disconnect() async {
        self.connectionState = .disconnected
        probeTask?.cancel()
        probeTask = nil
        readSource?.cancel()
        readSource = nil
        
        if childPid > 0 {
            kill(childPid, SIGHUP)
            var status: Int32 = 0
            waitpid(childPid, &status, WNOHANG)
            childPid = -1
        }
        
        if ptyMasterFd >= 0 {
            close(ptyMasterFd)
            ptyMasterFd = -1
        }
        
        // Clean up multiplex socket
        let socket = controlSocketPath
        if FileManager.default.fileExists(atPath: socket) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = ["-O", "exit", "-o", "ControlPath=\(socket)", "\(session.username)@\(session.host)"]
            try? proc.run()
            proc.waitUntilExit()
            try? FileManager.default.removeItem(atPath: socket)
        }
    }
    
    public func sendInputSync(_ data: Data) {
        guard ptyMasterFd >= 0 else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = write(ptyMasterFd, baseAddress, rawBuffer.count)
        }
    }
    
    public func sendInput(_ data: Data) async throws {
        sendInputSync(data)
    }
    
    public func resizeTerminal(columns: Int, rows: Int) async throws {
        guard ptyMasterFd >= 0 else { return }
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(ptyMasterFd, TIOCSWINSZ, &win)
    }
    
    private var controlSocketPath: String {
        let safeHost = session.host.replacingOccurrences(of: "/", with: "_")
        let safeUser = session.username.replacingOccurrences(of: "/", with: "_")
        return "/tmp/apex_ctrl_\(safeHost)_\(session.port)_\(safeUser)"
    }
    
    public func probeRemoteHome() async -> String? {
        await resolvePasswordIfNeeded()
        let process = Process()
        let cmd = "pwd"
        let ctrlArgs = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlSocketPath)",
            "-o", "ControlPersist=60s"
        ]
        if let pw = resolvedPassword, !pw.isEmpty, let sshpass = sshpassExecutablePath {
            process.executableURL = URL(fileURLWithPath: sshpass)
            process.arguments = [
                "-p", pw,
                "/usr/bin/ssh",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=3",
            ] + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=3",
            ] + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), output.hasPrefix("/") {
                return output
            }
        } catch {
            return nil
        }
        return nil
    }
    
    private func resolveAndDispatchDirectory(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // A valid directory path must start with '/' or '~'.
        // This strictly prevents metrics like '36' from 'Swap usage: 36%' being parsed as directories.
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return }
        
        let home = self.remoteHomeDirectory ?? (session.username == "root" ? "/root" : (session.username.isEmpty ? "/" : "/home/\(session.username)"))
        var path = trimmed
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            let sub = String(path.dropFirst(2))
            path = home == "/" ? "/\(sub)" : "\(home)/\(sub)"
        }
        
        // Must resolve to a valid Unix absolute path
        guard path.hasPrefix("/") else { return }
        
        if !path.isEmpty && path != lastReportedDirectory {
            lastReportedDirectory = path
            directoryChangeHandler?(path)
        }
    }
    
    private static let promptRegex: NSRegularExpression? = {
        let pattern = #"(?:[:\s]|^)((?:/|~)[a-zA-Z0-9_\-\./]*)\s*(?:\([^\)]+\)\s*)?[\$#%>](?:\s|$)"#
        return try? NSRegularExpression(pattern: pattern)
    }()
    
    private static let stripCsiRegex: NSRegularExpression? = {
        return try? NSRegularExpression(pattern: #"\x1b\[[0-9;?]*[a-zA-Z]"#)
    }()
    
    private static let stripOscRegex: NSRegularExpression? = {
        return try? NSRegularExpression(pattern: #"\x1b\][^\u0007\x1b]*(\u0007|\x1b\\)"#)
    }()

    private func parseOSC7DirectoryChange(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        
        // Fast path: skip directory parsing for normal keystroke echoes and pure text streams
        let hasTrigger = text.contains("\u{001B}]") || text.contains("\n") || text.contains("\r") ||
                         text.contains("$") || text.contains("#") || text.contains("%") || text.contains(">")
        guard hasTrigger else { return }
        
        // 1. Standard OSC 7 format (\e]7;file://hostname/path\a or \e\\)
        if let start = text.range(of: "\u{001B}]7;file://") {
            let rest = text[start.upperBound...]
            if let end = rest.firstIndex(of: "\u{0007}") ?? rest.range(of: "\u{001B}\\")?.lowerBound {
                let urlString = String(rest[..<end])
                if let slash = urlString.firstIndex(of: "/") {
                    let path = String(urlString[slash...])
                    resolveAndDispatchDirectory(path)
                    return
                }
            }
        }
        
        // 2. OSC 0 & OSC 2 Window Title format (\e]0;user@host: ~/dir\a - default in Ubuntu/Debian/CentOS bash PS1)
        if let start = text.range(of: "\u{001B}]0;") ?? text.range(of: "\u{001B}]2;") {
            let rest = text[start.upperBound...]
            if let end = rest.firstIndex(of: "\u{0007}") ?? rest.range(of: "\u{001B}\\")?.lowerBound {
                let title = String(rest[..<end])
                if let colon = title.range(of: ": ") {
                    let rawPath = String(title[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                    resolveAndDispatchDirectory(rawPath)
                    return
                } else if let colon = title.firstIndex(of: ":") {
                    let rawPath = String(title[title.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    resolveAndDispatchDirectory(rawPath)
                    return
                }
            }
        }
        
        // 3. Shell prompt CWD tracking fallback using sliding window to handle packet fragmentation
        var clean = text
        if let csi = Self.stripCsiRegex {
            clean = csi.stringByReplacingMatches(in: clean, range: NSRange(location: 0, length: (clean as NSString).length), withTemplate: "")
        }
        if let osc = Self.stripOscRegex {
            clean = osc.stringByReplacingMatches(in: clean, range: NSRange(location: 0, length: (clean as NSString).length), withTemplate: "")
        }
        
        recentPromptBuffer.append(clean)
        if recentPromptBuffer.count > 2048 {
            recentPromptBuffer = String(recentPromptBuffer.suffix(1024))
        }
        
        // Match prompt pattern like ubuntu@host:~/services$ or user@host /var/log % or root@host:/etc#
        if let regex = Self.promptRegex {
            let nsStr = recentPromptBuffer as NSString
            let matches = regex.matches(in: recentPromptBuffer, range: NSRange(location: 0, length: nsStr.length))
            if let lastMatch = matches.last, lastMatch.numberOfRanges > 1 {
                let raw = nsStr.substring(with: lastMatch.range(at: 1))
                resolveAndDispatchDirectory(raw)
            }
        }
    }
    
    private func startAgentlessProbeLoop() {
        probeTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.connectionState == .connected else { break }
                
                let process = Process()
                let sshpass = self.sshpassExecutablePath
                let ctrlArgs = [
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=\(self.controlSocketPath)",
                    "-o", "ControlPersist=60s"
                ]
                
                if let pw = self.resolvedPassword, !pw.isEmpty, let passBin = sshpass {
                    process.executableURL = URL(fileURLWithPath: passBin)
                    process.arguments = [
                        "-p", pw,
                        "/usr/bin/ssh",
                        "-o", "StrictHostKeyChecking=accept-new",
                        "-o", "ConnectTimeout=3",
                    ] + ctrlArgs + [
                        "-p", "\(self.session.port)",
                        "\(self.session.username)@\(self.session.host)",
                        AgentlessMonitor.autoProbeCommand
                    ]
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = [
                        "-o", "BatchMode=yes",
                        "-o", "StrictHostKeyChecking=accept-new",
                        "-o", "ConnectTimeout=3",
                    ] + ctrlArgs + [
                        "-p", "\(self.session.port)",
                        "\(self.session.username)@\(self.session.host)",
                        AgentlessMonitor.autoProbeCommand
                    ]
                }
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                        if let output = String(data: outData, encoding: .utf8) {
                            let snapshot = self.monitor.parseOutput(
                                output,
                                prevCpu: &self.prevCpu,
                                prevNet: &self.prevNet
                            )
                            self.metricsHandler?(snapshot)
                        }
                    }
                } catch {
                    // Silently wait for next interval
                }
                
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2.0s interval
            }
        }
    }
    
    // SFTP implementation
    public func listDirectory(path: String) async throws -> [SFTPItem] {
        await resolvePasswordIfNeeded()
        let process = Process()
        let sshpass = self.sshpassExecutablePath
        // Ensure trailing slash so that symbolic links pointing to directories are properly traversed by ls
        let targetPath = path.hasSuffix("/") ? path : "\(path)/"
        let escapedPath = targetPath.replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = "ls -la --time-style=+%s \"\(escapedPath)\" 2>/dev/null || ls -la \"\(escapedPath)\""
        let ctrlArgs = [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlSocketPath)",
            "-o", "ControlPersist=60s"
        ]
        
        if let pw = resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = [
                "-p", pw,
                "/usr/bin/ssh",
                "-o", "StrictHostKeyChecking=accept-new",
            ] + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "StrictHostKeyChecking=accept-new",
            ] + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        }
        
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        
        var items: [SFTPItem] = []
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 7 else { continue }
            let perms = String(parts[0])
            guard perms.hasPrefix("-") || perms.hasPrefix("d") || perms.hasPrefix("l") else { continue }
            
            let isDir = perms.hasPrefix("d")
            let isLink = perms.hasPrefix("l")
            let size = UInt64(parts[4]) ?? 0
            
            // Check if parts[5] is a unix epoch timestamp (--time-style=+%s)
            let isEpoch = parts[5].allSatisfy { $0.isNumber } && parts[5].count >= 9
            let nameIndex = isEpoch ? 6 : (parts.count >= 9 ? 8 : 7)
            guard parts.count > nameIndex else { continue }
            
            let rawName = parts.dropFirst(nameIndex).joined(separator: " ")
            if rawName == "." || rawName == ".." || rawName.isEmpty { continue }
            
            var name = rawName
            if isLink, let arrow = rawName.range(of: " -> ") {
                name = String(rawName[..<arrow.lowerBound])
            }
            
            let modDate: Date
            if isEpoch, let epoch = Double(parts[5]) {
                modDate = Date(timeIntervalSince1970: epoch)
            } else {
                modDate = Date()
            }
            
            let normalizedPath = path == "/" ? "" : (path.hasSuffix("/") ? String(path.dropLast()) : path)
            let fullPath = "\(normalizedPath)/\(name)"
            
            items.append(SFTPItem(
                name: name,
                path: fullPath,
                isDirectory: isDir,
                isSymlink: isLink,
                size: size,
                modificationDate: modDate
            ))
        }
        return items
    }
    
    public func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {
        await resolvePasswordIfNeeded()
        let process = Process()
        let sshpass = self.sshpassExecutablePath
        
        var baseArgs: [String] = [
            "-r",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if case .privateKey(let keyPath, _) = session.authMethod, !keyPath.isEmpty {
            baseArgs.append(contentsOf: ["-i", keyPath])
        }
        baseArgs.append(contentsOf: [
            "-P", "\(session.port)",
            "\(session.username)@\(session.host):\(remotePath)",
            localURL.path
        ])
        
        if let pw = resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = ["-p", pw, "/usr/bin/scp"] + baseArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = baseArgs
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "scp download failed"
            throw NSError(domain: "ApexSSH", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
        progress(1.0)
    }
    
    public func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {
        await resolvePasswordIfNeeded()
        let process = Process()
        let sshpass = self.sshpassExecutablePath
        
        var baseArgs: [String] = [
            "-r",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if case .privateKey(let keyPath, _) = session.authMethod, !keyPath.isEmpty {
            baseArgs.append(contentsOf: ["-i", keyPath])
        }
        baseArgs.append(contentsOf: [
            "-P", "\(session.port)",
            localURL.path,
            "\(session.username)@\(session.host):\(remotePath)"
        ])
        
        if let pw = resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = ["-p", pw, "/usr/bin/scp"] + baseArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = baseArgs
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "scp upload failed"
            throw NSError(domain: "ApexSSH", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
        progress(1.0)
    }
}
