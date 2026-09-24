import Foundation
import ApexCore

#if canImport(Darwin)
import Darwin
#endif

/// Real native SSH session implementation using Darwin POSIX PTY and background metrics probe
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
    
    public func connect() async throws {
        self.connectionState = .connecting(step: "Initializing native Darwin PTY...")
        
        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        
        guard openpty(&master, &slave, nil, nil, &win) == 0 else {
            self.connectionState = .failed("Failed to allocate Darwin PTY")
            throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }
        
        self.ptyMasterFd = master
        
        // Spawn ssh client process
        let sshPath = "/usr/bin/ssh"
        let args = [
            "-tt", // Force pseudo-terminal allocation
            "-o", "ServerAliveInterval=\(session.keepAliveIntervalSeconds)",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "\(session.port)",
            "\(session.username)@\(session.host)"
        ]
        
        if let jumpId = session.jumpServerId {
            // Future jump server proxy support
            _ = jumpId
        }
        
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        
        var pid: pid_t = 0
        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(sshPath)]
        for arg in args {
            cArgs.append(strdup(arg))
        }
        cArgs.append(nil)
        
        let spawnResult = posix_spawnp(&pid, sshPath, &fileActions, nil, cArgs, nil)
        for ptr in cArgs {
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
            } else if bytesRead <= 0 {
                source.cancel()
            }
        }
        source.setCancelHandler {
            close(master)
        }
        source.resume()
        self.readSource = source
        
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
            childPid = -1
        }
    }
    
    public func sendInput(_ data: Data) async throws {
        guard ptyMasterFd >= 0 else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = write(ptyMasterFd, baseAddress, rawBuffer.count)
        }
    }
    
    public func resizeTerminal(columns: Int, rows: Int) async throws {
        guard ptyMasterFd >= 0 else { return }
        var win = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(ptyMasterFd, TIOCSWINSZ, &win)
    }
    
    private func parseOSC7DirectoryChange(data: Data) {
        guard let text = String(data: data, encoding: .utf8), text.contains("\u{001B}]7;file://") else { return }
        // \u{001B}]7;file://hostname/path\u{0007}
        if let start = text.range(of: "\u{001B}]7;file://") {
            let rest = text[start.upperBound...]
            if let end = rest.firstIndex(of: "\u{0007}") {
                let urlString = String(rest[..<end])
                if let slash = urlString.firstIndex(of: "/") {
                    let path = String(urlString[slash...])
                    directoryChangeHandler?(path)
                }
            }
        }
    }
    
    private func startAgentlessProbeLoop() {
        probeTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.connectionState == .connected else { break }
                
                // Execute non-interactive probe command via ssh
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=2",
                    "-p", "\(self.session.port)",
                    "\(self.session.username)@\(self.session.host)",
                    AgentlessMonitor.linuxProbeCommand
                ]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                        if let output = String(data: outData, encoding: .utf8) {
                            let snapshot = self.monitor.parseLinuxOutput(
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-p", "\(session.port)",
            "\(session.username)@\(session.host)",
            "ls -la --time-style=+%s \(path)"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        
        var items: [SFTPItem] = []
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 7 {
                let perms = String(parts[0])
                guard perms.hasPrefix("-") || perms.hasPrefix("d") || perms.hasPrefix("l") else { continue }
                let isDir = perms.hasPrefix("d")
                let isLink = perms.hasPrefix("l")
                let size = UInt64(parts[4]) ?? 0
                let timestamp = Double(parts[5]) ?? Date().timeIntervalSince1970
                let name = parts.dropFirst(6).joined(separator: " ")
                if name == "." { continue }
                
                let fullPath = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
                items.append(SFTPItem(
                    name: name,
                    path: fullPath,
                    isDirectory: isDir,
                    isSymlink: isLink,
                    size: size,
                    modificationDate: Date(timeIntervalSince1970: timestamp)
                ))
            }
        }
        return items
    }
    
    public func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = [
            "-P", "\(session.port)",
            "\(session.username)@\(session.host):\(remotePath)",
            localURL.path
        ]
        try process.run()
        process.waitUntilExit()
        progress(1.0)
    }
    
    public func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = [
            "-P", "\(session.port)",
            localURL.path,
            "\(session.username)@\(session.host):\(remotePath)"
        ]
        try process.run()
        process.waitUntilExit()
        progress(1.0)
    }
}
