import Foundation
import ApexCore
import os

#if canImport(Darwin)
import Darwin
#endif

/// High-performance local terminal session for macOS using Darwin POSIX PTY and user's default login shell
public final class LocalTerminalSession: SSHSessionProtocol, @unchecked Sendable {
    public let session: Session
    
    private let stateLock = NSLock()
    private var storedConnectionState: SSHConnectionState = .disconnected
    public private(set) var connectionState: SSHConnectionState {
        get { stateLock.withLock { storedConnectionState } }
        set {
            let changed: Bool = stateLock.withLock {
                if storedConnectionState != newValue {
                    storedConnectionState = newValue
                    return true
                }
                return false
            }
            if changed {
                stateChangeHandler?(newValue)
            }
        }
    }
    
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var metricsHandler: (@Sendable (ServerMetricsSnapshot) -> Void)?
    private var directoryChangeHandler: (@Sendable (String) -> Void)?
    private var stateChangeHandler: (@Sendable (SSHConnectionState) -> Void)?
    
    private var ptyMasterFd: Int32 = -1
    private var childPid: pid_t = -1
    private var currentDimensions: (columns: Int, rows: Int) = (120, 35)
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private var metricsTimer: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.apexterm.local-pty", qos: .userInteractive)
    private var directoryStream = DirectoryChangeStreamParser()
    private var prevNet: AgentlessMonitor.NetTickState?
    
    public init(session: Session = .local()) {
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
    
    public func setStateChangeHandler(_ handler: @Sendable @escaping (SSHConnectionState) -> Void) {
        self.stateChangeHandler = handler
    }
    
    /// Detect user's preferred login shell
    public static func resolveShellPath() -> String {
        if let envShell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: envShell) {
            return envShell
        }
        if let pw = getpwuid(getuid()), let shellStr = pw.pointee.pw_shell {
            let s = String(cString: shellStr)
            if FileManager.default.isExecutableFile(atPath: s) {
                return s
            }
        }
        if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
            return "/bin/zsh"
        }
        if FileManager.default.isExecutableFile(atPath: "/bin/bash") {
            return "/bin/bash"
        }
        return "/bin/sh"
    }
    
    public func connect() async throws {
        if ptyMasterFd != -1 || childPid > 0 {
            await disconnect()
        }
        
        connectionState = .connecting(step: "启动本地终端...")
        
        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(
            ws_row: UInt16(currentDimensions.rows),
            ws_col: UInt16(currentDimensions.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        
        guard openpty(&master, &slave, nil, nil, &win) == 0 else {
            let err = NSError(domain: "ApexLocalTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法分配 Darwin PTY"])
            connectionState = .failed(err.localizedDescription)
            throw err
        }
        
        // Non-blocking PTY master
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        
        let homeDir = NSHomeDirectory()
        posix_spawn_file_actions_addchdir_np(&fileActions, homeDir)
        
        var spawnAttributes: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttributes)
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        posix_spawnattr_setsigmask(&spawnAttributes, &signalMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGWINCH)
        posix_spawnattr_setsigdefault(&spawnAttributes, &defaultSignals)
        posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&spawnAttributes, 0)
        
        let shellPath = Self.resolveShellPath()
        let shellName = (shellPath as NSString).lastPathComponent
        let loginArgv0 = "-" + shellName
        
        let cArgs: [UnsafeMutablePointer<CChar>?] = [
            strdup(loginArgv0),
            nil
        ]
        
        var envVars = ProcessInfo.processInfo.environment
        envVars["TERM"] = "xterm-256color"
        envVars["COLORTERM"] = "truecolor"
        envVars["LANG"] = "en_US.UTF-8"
        envVars["LC_ALL"] = "en_US.UTF-8"
        envVars["HOME"] = homeDir
        envVars["PWD"] = homeDir
        let currentUser = ProcessInfo.processInfo.userName
        if !currentUser.isEmpty {
            envVars["USER"] = currentUser
            envVars["LOGNAME"] = currentUser
        }
        
        var cEnv: [UnsafeMutablePointer<CChar>?] = envVars.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        
        var pid: pid_t = 0
        let spawnResult = posix_spawnp(&pid, shellPath, &fileActions, &spawnAttributes, cArgs, cEnv)
        
        for p in cArgs { if let ptr = p { free(ptr) } }
        for p in cEnv { if let ptr = p { free(ptr) } }
        close(slave)
        
        guard spawnResult == 0 else {
            close(master)
            let err = NSError(domain: "ApexLocalTerminal", code: Int(spawnResult), userInfo: [NSLocalizedDescriptionKey: "启动本地 Shell 失败 (code: \(spawnResult))"])
            connectionState = .failed(err.localizedDescription)
            throw err
        }
        
        stateLock.withLock {
            self.ptyMasterFd = master
            self.childPid = pid
        }
        
        // Setup read source
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let bytesRead = read(master, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                self.outputHandler?(data)
                let parsed = self.directoryStream.consume(data)
                for path in parsed.paths {
                    self.directoryChangeHandler?(path)
                }
            } else if bytesRead == 0 {
                source?.cancel()
            }
        }
        
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            self.stateLock.withLock {
                if self.ptyMasterFd != -1 {
                    close(self.ptyMasterFd)
                    self.ptyMasterFd = -1
                }
            }
            Task { @MainActor [weak self] in
                self?.connectionState = .disconnected
            }
        }
        
        self.readSource = source
        source.resume()
        
        // Setup process exit listener
        let procSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        procSource.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.disconnect()
            }
        }
        self.processSource = procSource
        procSource.resume()
        
        self.connectionState = .connected
        startLocalMetricsCollector()
    }
    
    public func disconnect() async {
        metricsTimer?.cancel()
        metricsTimer = nil
        
        if let procSource = processSource {
            procSource.cancel()
            processSource = nil
        }
        
        if let readSource = readSource {
            readSource.cancel()
            self.readSource = nil
        }
        
        let pid = stateLock.withLock { self.childPid }
        if pid > 0 {
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
            var status: Int32 = 0
            for _ in 0..<10 {
                if waitpid(pid, &status, WNOHANG) != 0 { break }
                usleep(5000)
            }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            waitpid(pid, &status, WNOHANG)
            stateLock.withLock { self.childPid = -1 }
        }
        
        let fd = stateLock.withLock { self.ptyMasterFd }
        if fd != -1 {
            close(fd)
            stateLock.withLock { self.ptyMasterFd = -1 }
        }
        
        connectionState = .disconnected
    }
    
    deinit {
        metricsTimer?.cancel()
        if let procSource = processSource {
            procSource.cancel()
        }
        if let readSource = readSource {
            readSource.cancel()
        }
        let pid = stateLock.withLock { self.childPid }
        if pid > 0 {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
        }
        let fd = stateLock.withLock { self.ptyMasterFd }
        if fd != -1 {
            close(fd)
        }
    }
    
    public func sendInput(_ data: Data) async throws {
        sendInputSync(data)
    }
    
    public func sendInputSync(_ data: Data) {
        let fd = stateLock.withLock { self.ptyMasterFd }
        guard fd != -1 else { return }
        data.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                _ = write(fd, base, ptr.count)
            }
        }
    }
    
    public func resizeTerminal(columns: Int, rows: Int) async throws {
        currentDimensions = (columns, rows)
        let fd = stateLock.withLock { self.ptyMasterFd }
        let pid = stateLock.withLock { self.childPid }
        guard fd != -1 else { return }
        
        var win = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(fd, TIOCSWINSZ, &win)
        if pid > 0 {
            kill(-pid, SIGWINCH)
            kill(pid, SIGWINCH)
        }
    }
    
    // MARK: - Local File System Implementation (Instant Native SFTP)
    
    public static func expandPath(_ path: String) -> String {
        if path == "~" {
            return NSHomeDirectory()
        }
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + "/" + String(path.dropFirst(2))
        }
        return path
    }
    
    public func listDirectory(path: String) async throws -> [SFTPItem] {
        let target = Self.expandPath(path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "ApexLocalTerminal", code: 2, userInfo: [NSLocalizedDescriptionKey: "目录不存在: \(target)"])
        }
        
        let fileNames = try fm.contentsOfDirectory(atPath: target)
        var result: [SFTPItem] = []
        
        for name in fileNames {
            let fullPath = (target as NSString).appendingPathComponent(name)
            do {
                let attrs = try fm.attributesOfItem(atPath: fullPath)
                let type = attrs[.type] as? FileAttributeType
                let isDirectory = type == .typeDirectory
                let isSymlink = type == .typeSymbolicLink
                let size = (attrs[.size] as? UInt64) ?? 0
                let permissions = (attrs[.posixPermissions] as? UInt32) ?? (isDirectory ? 0o755 : 0o644)
                let date = (attrs[.modificationDate] as? Date) ?? Date()
                
                result.append(SFTPItem(
                    name: name,
                    path: fullPath,
                    isDirectory: isDirectory,
                    isSymlink: isSymlink,
                    size: size,
                    permissions: permissions,
                    modificationDate: date
                ))
            } catch {
                // If single file attributes fail (e.g. permission denied), return item with basic info
                result.append(SFTPItem(
                    name: name,
                    path: fullPath,
                    isDirectory: false,
                    isSymlink: false,
                    size: 0,
                    permissions: 0o644,
                    modificationDate: Date()
                ))
            }
        }
        
        // Sort directories first, then alphabetical
        return result.sorted {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    
    public func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {
        let sourcePath = Self.expandPath(remotePath)
        let fm = FileManager.default
        if fm.fileExists(atPath: localURL.path) {
            try fm.removeItem(at: localURL)
        }
        try fm.copyItem(atPath: sourcePath, toPath: localURL.path)
        progress(1.0)
    }
    
    public func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {
        let targetPath = Self.expandPath(remotePath)
        let fm = FileManager.default
        if fm.fileExists(atPath: targetPath) {
            try fm.removeItem(atPath: targetPath)
        }
        try fm.copyItem(atPath: localURL.path, toPath: targetPath)
        progress(1.0)
    }
    
    public func removeFile(remotePath: String) async throws {
        let target = Self.expandPath(remotePath)
        try FileManager.default.removeItem(atPath: target)
    }
    
    public func removeDirectory(remotePath: String, recursive: Bool) async throws {
        let target = Self.expandPath(remotePath)
        try FileManager.default.removeItem(atPath: target)
    }
    
    public func createDirectory(remotePath: String) async throws {
        let target = Self.expandPath(remotePath)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    }
    
    public func createFile(remotePath: String) async throws {
        let target = Self.expandPath(remotePath)
        guard FileManager.default.createFile(atPath: target, contents: Data()) else {
            throw NSError(domain: "ApexLocalTerminal", code: 3, userInfo: [NSLocalizedDescriptionKey: "创建本地文件失败: \(target)"])
        }
    }
    
    public func rename(oldPath: String, newPath: String) async throws {
        let oldTarget = Self.expandPath(oldPath)
        let newTarget = Self.expandPath(newPath)
        try FileManager.default.moveItem(atPath: oldTarget, toPath: newTarget)
    }
    
    public func changePermissions(remotePath: String, permissions: String) async throws {
        let target = Self.expandPath(remotePath)
        guard let perm = UInt32(permissions, radix: 8) else {
            throw NSError(domain: "ApexLocalTerminal", code: 4, userInfo: [NSLocalizedDescriptionKey: "无效的权限代码: \(permissions)"])
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: perm)], ofItemAtPath: target)
    }
    
    // MARK: - Local Performance Metrics Sampling
    
    private func startLocalMetricsCollector() {
        guard session.agentlessMonitorEnabled else { return }
        metricsTimer?.cancel()
        metricsTimer = Task { [weak self] in
            let monitor = AgentlessMonitor()
            while !Task.isCancelled {
                guard let self = self, self.connectionState == .connected else { break }
                let rawOutput = await self.sampleLocalMacOSMetrics()
                if !rawOutput.isEmpty {
                    var net = self.prevNet
                    let snapshot = monitor.parseMacOSOutput(rawOutput, prevNet: &net)
                    self.prevNet = net
                    self.metricsHandler?(snapshot)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s interval
            }
        }
    }
    
    private func sampleLocalMacOSMetrics() async -> String {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", AgentlessMonitor.macosProbeCommand]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
