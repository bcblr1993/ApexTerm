import Foundation
import ApexCore
import os

#if canImport(Darwin)
import Darwin
#endif

/// Real native SSH session implementation using Darwin POSIX PTY, bundled standalone sshpass, and real-time probe
public final class NativeSSHSession: SSHSessionProtocol, @unchecked Sendable {
    public let session: Session
    private let distributionChannel: DistributionChannel
    private let fileAccessStore: FileAccessStore
    private var connectionKeyAccess: FileAccessLease?
    private var connectionGrantRequest: ChildProcessFileGrants?
    private let bridgeExecutableURL: URL
    private let sandboxPaths: SandboxSSHPaths
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
    private let controlSocketIdentifier = UUID().uuidString
    private let inputQueue = DispatchQueue(label: "com.apexterm.pty-input", qos: .userInteractive)
    private var childPid: pid_t = -1
    private var currentDimensions: (columns: Int, rows: Int) = (120, 35)
    private var readSource: DispatchSourceRead?
    private var probeTask: Task<Void, Never>?
    
    private let monitor = AgentlessMonitor()
    private var prevCpu: AgentlessMonitor.CpuTickState?
    private var prevNet: AgentlessMonitor.NetTickState?
    private var resolvedPassword: String?
    private var passwordFeedSent = false
    private var recentPromptBuffer = ""
    private var directoryStream = DirectoryChangeStreamParser()
    private var lastReportedDirectory: String?
    private var hasPendingCommandExecution = false
    private var remoteHomeDirectory: String?
    
    /// Locate bundled sshpass first, then Homebrew/system locations
    public var sshpassExecutablePath: String? {
        let inBundle = Bundle.main.bundlePath + "/Contents/MacOS/sshpass"
        if FileManager.default.isExecutableFile(atPath: inBundle) {
            return inBundle
        }
        if distributionChannel == .appStore { return nil }
        let candidates = [
            "/opt/homebrew/bin/sshpass",
            "/usr/local/bin/sshpass",
            "/usr/bin/sshpass"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    
    public init(session: Session, distributionChannel: DistributionChannel = .current,
                fileAccessStore: FileAccessStore = .shared, bridgeExecutableURL: URL? = nil,
                sandboxHomeURL: URL? = nil, sandboxTemporaryURL: URL? = nil) {
        self.session = session
        self.distributionChannel = distributionChannel
        self.fileAccessStore = fileAccessStore
        self.bridgeExecutableURL = bridgeExecutableURL ?? URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/MacOS/ApexSSHBridge")
        self.sandboxPaths = SandboxSSHPaths(home: sandboxHomeURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            temporary: sandboxTemporaryURL ?? FileManager.default.temporaryDirectory)
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

    public static func expandPath(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + "/" + String(path.dropFirst(2))
        } else if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return path
    }

    public func sshAuthArgs(privateKeyURL: URL? = nil) -> [String] {
        var args: [String] = []
        if case .privateKey(let keyPath, _) = session.authMethod, !keyPath.isEmpty {
            let connectedURL = stateLock.withLock { connectionKeyAccess?.url }
            let expanded = (privateKeyURL ?? connectedURL)?.path ?? Self.expandPath(keyPath)
            args.append(contentsOf: ["-i", expanded])
        }
        return args
    }

    /// Every child operation owns its grant independently, including cancellation cleanup.
    func acquirePrivateKeyAccess() throws -> FileAccessLease? {
        guard distributionChannel == .appStore,
              case .privateKey(let path, _) = session.authMethod, !path.isEmpty else { return nil }
        let access = try fileAccessStore.acquire(URL(fileURLWithPath: Self.expandPath(path)))
        guard FileManager.default.isReadableFile(atPath: access.url.path) else {
            access.close()
            throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "无法读取私钥，请在会话设置中通过「浏览」重新授权私钥文件。"])
        }
        return access
    }

    struct PreparedStoreCommand {
        let binaryPath: String
        let arguments: [String]
        let grants: ChildProcessFileGrants
    }

    func prepareStoreCommand(binaryPath: String, arguments: [String], accesses: [FileAccessLease?]) throws -> PreparedStoreCommand? {
        guard distributionChannel == .appStore else { return nil }
        guard FileManager.default.isExecutableFile(atPath: bridgeExecutableURL.path) else {
            throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "商店版 SSH 文件授权组件缺失，请重新安装应用。"])
        }
        var toolPath = binaryPath
        var toolArguments = arguments
        let usesPasswordHelper = binaryPath != "/usr/bin/ssh" && binaryPath != "/usr/bin/scp"
        if usesPasswordHelper {
            guard binaryPath == sshpassExecutablePath, arguments.count >= 3,
                  arguments[0] == "-p" else { throw CocoaError(.fileReadCorruptFile) }
            toolPath = arguments[2]
            toolArguments = Array(arguments.dropFirst(3))
        }
        guard toolPath == "/usr/bin/ssh" || toolPath == "/usr/bin/scp" else { throw CocoaError(.fileReadNoPermission) }
        let tool = toolPath == "/usr/bin/scp" ? "scp" : "ssh"
        try sandboxPaths.prepare()
        toolArguments = try sandboxPaths.arguments(prependingTo: toolArguments, tool: tool)
        if tool == "scp" { toolArguments = ["-S", bridgeExecutableURL.path] + toolArguments }
        let grants = try ChildProcessFileGrants(files: accesses.compactMap { try $0?.childProcessGrant() })
        let bridgeArguments = ["--tool", tool] + toolArguments
        return PreparedStoreCommand(binaryPath: usesPasswordHelper ? binaryPath : bridgeExecutableURL.path,
                                    arguments: usesPasswordHelper ? Array(arguments.prefix(2)) + [bridgeExecutableURL.path] + bridgeArguments : bridgeArguments,
                                    grants: grants)
    }

    private func configureStoreProcess(_ process: Process, accesses: [FileAccessLease?]) throws -> ChildProcessFileGrants? {
        guard distributionChannel == .appStore else { return nil }
        guard let executable = process.executableURL,
              let command = try prepareStoreCommand(binaryPath: executable.path, arguments: process.arguments ?? [], accesses: accesses) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        process.executableURL = URL(fileURLWithPath: command.binaryPath)
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        environment[ChildProcessFileGrants.environmentKey] = command.grants.fileURL.path
        process.environment = environment
        return command.grants
    }

    private var resolvedJumpServer: Session?
    public var customJumpSession: Session? {
        get { stateLock.withLock { resolvedJumpServer } }
        set { stateLock.withLock { resolvedJumpServer = newValue } }
    }

    public func jumpServerArgs() -> [String] {
        let jumpSession = stateLock.withLock { resolvedJumpServer }
        guard let jumpSession else { return [] }
        let host = jumpSession.host.contains(":") && !jumpSession.host.hasPrefix("[") ? "[\(jumpSession.host)]" : jumpSession.host
        let target = "\(jumpSession.username)@\(host):\(jumpSession.port)"
        return ["-J", target]
    }

    private func resolvePasswordIfNeeded() async {
        if stateLock.withLock({ resolvedPassword != nil }) {
            await resolveJumpServerIfNeeded()
            return
        }
        var foundPassword: String? = nil
        switch session.authMethod {
        case .password(let ref):
            if let pw = try? await KeychainStore.shared.get(key: ref) {
                foundPassword = pw
            } else {
                foundPassword = ref
            }
        case .privateKey(_, let passphraseRef):
            if let ref = passphraseRef, !ref.isEmpty {
                if let pw = try? await KeychainStore.shared.get(key: ref) {
                    foundPassword = pw
                } else {
                    foundPassword = ref
                }
            }
        default:
            break
        }
        stateLock.withLock { self.resolvedPassword = foundPassword }
        await resolveJumpServerIfNeeded()
    }

    private func resolveJumpServerIfNeeded() async {
        if stateLock.withLock({ resolvedJumpServer != nil }) { return }
        guard let jumpId = session.jumpServerId else { return }
        let found = await MainActor.run {
            SessionStore.shared.sessions.first(where: { $0.id == jumpId })
        }
        stateLock.withLock { self.resolvedJumpServer = found }
    }
    
    public func connect() async throws {
        // Clean up any existing connection resources to prevent fd or process leaks on reconnect
        if ptyMasterFd != -1 || readSource != nil || childPid > 0 {
            await disconnect()
        }
        
        // A peer disconnect may leave the previous probe finishing cancellation.
        let previousProbe = probeTask
        previousProbe?.cancel()
        probeTask = nil
        await previousProbe?.value
        prevCpu = nil
        prevNet = nil
        directoryStream = DirectoryChangeStreamParser()
        recentPromptBuffer = ""
        lastReportedDirectory = ""
        self.connectionState = .connecting(step: "Initializing native Darwin PTY...")
        self.passwordFeedSent = false
        
        await resolvePasswordIfNeeded()
        let keyAccess: FileAccessLease?
        do { keyAccess = try acquirePrivateKeyAccess() }
        catch {
            self.connectionState = .failed(error.localizedDescription)
            throw error
        }
        var transferredKeyAccess = false
        defer { if !transferredKeyAccess { keyAccess?.close() } }

        // Setup command & arguments
        var binaryPath = "/usr/bin/ssh"
        var sshArgs = [
            "-tt",
            "-o", "ServerAliveInterval=\(session.keepAliveIntervalSeconds)",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        sshArgs.append(contentsOf: sshAuthArgs(privateKeyURL: keyAccess?.url))
        sshArgs.append(contentsOf: jumpServerArgs())
        sshArgs.append(contentsOf: [
            "-p", "\(session.port)",
            "\(session.username)@\(session.host)"
        ])
        
        if let pw = resolvedPassword, !pw.isEmpty, let sshpass = sshpassExecutablePath {
            binaryPath = sshpass
            sshArgs = ["-p", pw, "/usr/bin/ssh"] + sshArgs
        }
        
        let storeCommand: PreparedStoreCommand?
        do { storeCommand = try prepareStoreCommand(binaryPath: binaryPath, arguments: sshArgs, accesses: [keyAccess]) }
        catch {
            self.connectionState = .failed(error.localizedDescription)
            throw error
        }
        defer { if !transferredKeyAccess { storeCommand?.grants.close() } }
        if let command = storeCommand { binaryPath = command.binaryPath; sshArgs = command.arguments }

        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(
            ws_row: UInt16(currentDimensions.rows),
            ws_col: UInt16(currentDimensions.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&master, &slave, nil, nil, &win) == 0 else {
            self.connectionState = .failed("Failed to allocate Darwin PTY")
            throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }

        stateLock.withLock { self.ptyMasterFd = master }
        _ = ioctl(master, TIOCSWINSZ, &win)

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
        if let request = storeCommand?.grants {
            envVars.append("\(ChildProcessFileGrants.environmentKey)=\(request.fileURL.path)")
        }
        for (k, v) in currentEnv {
            if k != "TERM" && k != "COLORTERM" && k != "LANG" && k != "LC_ALL" && k != "PATH" && k != ChildProcessFileGrants.environmentKey {
                envVars.append("\(k)=\(v)")
            }
        }
        var cEnv: [UnsafeMutablePointer<CChar>?] = envVars.map { strdup($0) }
        cEnv.append(nil)
        
        var spawnAttributes: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttributes)
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        // Swift concurrency workers may inherit blocked signals. SSH must receive SIGWINCH.
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        posix_spawnattr_setsigmask(&spawnAttributes, &signalMask)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGWINCH)
        posix_spawnattr_setsigdefault(&spawnAttributes, &defaultSignals)
        posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&spawnAttributes, 0)
        let spawnResult = posix_spawnp(&pid, binaryPath, &fileActions, &spawnAttributes, cArgs, cEnv)
        for ptr in cArgs {
            if let p = ptr { free(p) }
        }
        for ptr in cEnv {
            if let p = ptr { free(p) }
        }
        close(slave)
        
        guard spawnResult == 0 else {
            self.connectionState = .failed("posix_spawn failed with error: \(spawnResult)")
            stateLock.withLock { self.ptyMasterFd = -1 }
            close(master)
            return
        }
        
        self.childPid = pid
        stateLock.withLock { connectionKeyAccess = keyAccess; connectionGrantRequest = storeCommand?.grants }
        transferredKeyAccess = true
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
                self.connectionState = .disconnected
                self.probeTask?.cancel()
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            if let self {
                self.stateLock.withLock {
                    if self.ptyMasterFd == master { self.ptyMasterFd = -1 }
                    close(master)
                }
            } else {
                close(master)
            }
        }
        source.resume()
        self.readSource = source
        
        // Probe user's real home directory after connection
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.connectionState == .connected else { return }
            if let home = await self.probeRemoteHome(), !home.isEmpty, self.connectionState == .connected {
                self.remoteHomeDirectory = home
                self.directoryChangeHandler?(home)
            }
        }
        
        // Start agentless metrics probe if enabled
        if session.agentlessMonitorEnabled {
            startAgentlessProbeLoop()
        }
    }
    
    public func disconnect() async {
        self.connectionState = .disconnected
        let pendingProbe = probeTask
        pendingProbe?.cancel()
        probeTask = nil
        await pendingProbe?.value
        let source = readSource
        readSource = nil
        let master = stateLock.withLock { () -> Int32 in
            let descriptor = ptyMasterFd
            ptyMasterFd = -1
            return descriptor
        }
        source?.cancel()
        terminatePTYProcess()
        // Once a read source owns the descriptor, only its cancel handler closes it.
        // Closing twice can close an unrelated descriptor reused by another connection.
        if source == nil, master >= 0 { close(master) }

        // Clean up multiplex socket
        let socket = controlSocketPath
        if FileManager.default.fileExists(atPath: socket) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = ["-O", "exit", "-o", controlSocketOption, "\(session.username)@\(session.host)"]
            do {
                let grants = try configureStoreProcess(proc, accesses: [])
                defer { grants?.close() }
                try proc.run()
                proc.waitUntilExit()
            } catch { /* The control master may already have exited. */ }
            try? FileManager.default.removeItem(atPath: socket)
        }
    }
    
    /// Synchronous exit cleanup: SSH ignores ordinary termination signals while attached to a PTY.
    /// Each spawned connection owns a process group, so this cannot target another session.
    public func terminatePTYProcess() {
        let access = stateLock.withLock { () -> FileAccessLease? in
            defer { connectionKeyAccess = nil }
            return connectionKeyAccess
        }
        let grants = stateLock.withLock { () -> ChildProcessFileGrants? in
            defer { connectionGrantRequest = nil }
            return connectionGrantRequest
        }
        defer { grants?.close(); access?.close() }
        guard childPid > 0 else { return }
        let pid = childPid
        childPid = -1
        // sshpass can place its SSH child in a separate session; include descendants
        // before terminating the helper, otherwise its child can be reparented to launchd.
        let descendants = Self.ptyDescendants(of: pid)
        for child in descendants.reversed() { kill(child, SIGKILL) }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }

    private static func ptyDescendants(of parent: pid_t) -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        let direct = children.prefix(Int(count)).filter { $0 > 0 }
        return direct.flatMap { [$0] + ptyDescendants(of: $0) }
    }

    public func sendInputSync(_ data: Data) {
        guard !data.isEmpty else { return }
        let descriptor = stateLock.withLock { ptyMasterFd >= 0 ? dup(ptyMasterFd) : -1 }
        guard descriptor >= 0 else { return }
        if data.contains(13) || data.contains(10) { hasPendingCommandExecution = true }
        // A duplicated descriptor prevents queued input from reaching a reused fd after reconnect.
        inputQueue.async {
            defer { close(descriptor) }
            Self.writePTYInput(data, to: descriptor)
        }
    }

    static func writePTYInput(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base.advanced(by: offset), min(4096, raw.count - offset))
                if written > 0 { offset += written }
                else if written < 0 && errno == EINTR { continue }
                else { return }
            }
        }
    }

    public func sendInput(_ data: Data) async throws {
        sendInputSync(data)
    }
    
    public func resizeTerminal(columns: Int, rows: Int) async throws {
        let validCols = max(10, columns)
        let validRows = max(3, rows)
        currentDimensions = (validCols, validRows)
        guard ptyMasterFd >= 0 else { return }
        var win = winsize(ws_row: UInt16(validRows), ws_col: UInt16(validCols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(ptyMasterFd, TIOCSWINSZ, &win)
        if childPid > 0 {
            kill(childPid, SIGWINCH)
            kill(-childPid, SIGWINCH)
            for child in Self.ptyDescendants(of: childPid) {
                kill(child, SIGWINCH)
                kill(-child, SIGWINCH)
            }
        }
    }
    
    var controlSocketPath: String {
        distributionChannel == .appStore ? sandboxPaths.controlSocket.path : "/tmp/apex_ctrl_\(controlSocketIdentifier)"
    }

    private var controlSocketOption: String {
        distributionChannel == .appStore ? sandboxPaths.controlSocketOption : "ControlPath=" + controlSocketPath
    }

    public func probeRemoteHome() async -> String? {
        await resolvePasswordIfNeeded()
        let keyAccess: FileAccessLease?
        do { keyAccess = try acquirePrivateKeyAccess() }
        catch { return nil }
        defer { keyAccess?.close() }
        let process = Process()
        let cmd = "printf '%s\\n' \"$HOME\""
        let ctrlArgs = [
            "-o", "ControlMaster=auto",
            "-o", controlSocketOption,
            "-o", "ControlPersist=60s"
        ]
        let authArgs = sshAuthArgs(privateKeyURL: keyAccess?.url)
        let jumpArgs = jumpServerArgs()
        if let pw = resolvedPassword, !pw.isEmpty, let sshpass = sshpassExecutablePath {
            process.executableURL = URL(fileURLWithPath: sshpass)
            process.arguments = [
                "-p", pw,
                "/usr/bin/ssh",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=5",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=5",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            let grants = try configureStoreProcess(process, accesses: [keyAccess])
            defer { grants?.close() }
            try process.run()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
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
        
        guard let home = remoteHomeDirectory else {
            if trimmed.hasPrefix("/") && trimmed != lastReportedDirectory {
                lastReportedDirectory = trimmed
                directoryChangeHandler?(trimmed)
            }
            return
        }
        var path = trimmed
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            let sub = String(path.dropFirst(2))
            path = home == "/" ? "/\(sub)" : "\(home)/\(sub)"
        }
        
        // Must resolve to a valid Unix absolute path
        guard path.hasPrefix("/") else { return }
        
        if !path.isEmpty {
            if path != lastReportedDirectory {
                lastReportedDirectory = path
                hasPendingCommandExecution = false
                directoryChangeHandler?(path)
            } else if hasPendingCommandExecution {
                hasPendingCommandExecution = false
                directoryChangeHandler?(path)
            }
        }
    }
    
    private static let promptRegex: NSRegularExpression? = {
        let pattern = #"(?:[: \t]|^)((?:/|~)[a-zA-Z0-9_\-\./]*)[ \t]*(?:\([^\)\r\n]+\)[ \t]*)?[\$#%>](?:[ \t]|$)"#
        return try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }()
    
    private static let stripCsiRegex: NSRegularExpression? = {
        return try? NSRegularExpression(pattern: #"\x1b\[[0-9;?]*[a-zA-Z]"#)
    }()
    
    private static let stripOscRegex: NSRegularExpression? = {
        return try? NSRegularExpression(pattern: #"\x1b\][^\u0007\x1b]*(\u0007|\x1b\\)"#)
    }()

    private func parseOSC7DirectoryChange(data: Data) {
        let parsed = directoryStream.consume(data)
        for path in parsed.paths { resolveAndDispatchDirectory(path) }
        let text = parsed.text
        guard !text.isEmpty else { return }

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
        if let raw = Self.directoryFromPrompt(recentPromptBuffer) {
            resolveAndDispatchDirectory(raw)
        }
    }

    static func directoryFromPrompt(_ text: String) -> String? {
        guard let regex = promptRegex else { return nil }
        let nsText = text as NSString
        guard let match = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).last,
              match.numberOfRanges > 1 else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }

    /// Shells also put the running command in OSC titles. Only a host-prefixed title is a CWD hint.
    static func directoryFromWindowTitle(_ title: String) -> String? {
        guard let colon = title.firstIndex(of: ":") else { return nil }
        let identity = title[..<colon]
        guard !identity.isEmpty,
              identity.allSatisfy({ $0.isLetter || $0.isNumber || "@._-".contains($0) }) else { return nil }
        let path = title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !path.hasPrefix("//") else { return nil }
        guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else { return nil }
        return path
    }
    
    private func startAgentlessProbeLoop() {
        probeTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.connectionState == .connected else { break }
                
                let process = Process()
                let sshpass = self.sshpassExecutablePath
                let ctrlArgs = [
                    "-o", "ControlMaster=auto",
                    "-o", self.controlSocketOption,
                    "-o", "ControlPersist=60s"
                ]
                
                let keyAccess: FileAccessLease?
                do { keyAccess = try self.acquirePrivateKeyAccess() }
                catch {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                defer { keyAccess?.close() }
                let authArgs = self.sshAuthArgs(privateKeyURL: keyAccess?.url)
                let jumpArgs = self.jumpServerArgs()
                if let pw = self.resolvedPassword, !pw.isEmpty, let passBin = sshpass {
                    process.executableURL = URL(fileURLWithPath: passBin)
                    process.arguments = [
                        "-p", pw,
                        "/usr/bin/ssh",
                        "-o", "StrictHostKeyChecking=accept-new",
                        "-o", "ConnectTimeout=3",
                    ] + authArgs + jumpArgs + ctrlArgs + [
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
                    ] + authArgs + jumpArgs + ctrlArgs + [
                        "-p", "\(self.session.port)",
                        "\(self.session.username)@\(self.session.host)",
                        AgentlessMonitor.autoProbeCommand
                    ]
                }
                
                process.standardError = FileHandle.nullDevice
                
                do {
                    let grants = try self.configureStoreProcess(process, accesses: [keyAccess])
                    defer { grants?.close() }
                    let outData = try await Self.runProbeProcess(process)
                    
                    if process.terminationStatus == 0, !Task.isCancelled,
                       self.connectionState == .connected {
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
        let keyAccess = try acquirePrivateKeyAccess()
        defer { keyAccess?.close() }
        var path = path
        if path == "~" || path.hasPrefix("~/") {
            var home = remoteHomeDirectory
            if home == nil { home = await probeRemoteHome() }
            guard let home, home.hasPrefix("/") else {
                throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取远程主目录"])
            }
            remoteHomeDirectory = home
            path = path == "~" ? home : home + "/" + String(path.dropFirst(2))
            directoryChangeHandler?(path)
        }
        let process = Process()
        let sshpass = self.sshpassExecutablePath
        // Ensure trailing slash so that symbolic links pointing to directories are properly traversed by ls
        let targetPath = path.hasSuffix("/") ? path : "\(path)/"
        let quotedPath = Self.quoteRemotePath(targetPath)
        let cmd = "LC_ALL=C ls -la --time-style=+%s \(quotedPath) 2>/dev/null || LC_ALL=C ls -la -D '%s' \(quotedPath) 2>/dev/null || LC_ALL=C ls -la \(quotedPath)"
        let ctrlArgs = [
            "-o", "ControlMaster=auto",
            "-o", controlSocketOption,
            "-o", "ControlPersist=60s"
        ]
        
        let authArgs = sshAuthArgs(privateKeyURL: keyAccess?.url)
        let jumpArgs = jumpServerArgs()
        if let pw = resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = [
                "-p", pw,
                "/usr/bin/ssh",
                "-o", "StrictHostKeyChecking=accept-new",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "StrictHostKeyChecking=accept-new",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        }
        
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        let grants = try configureStoreProcess(process, accesses: [keyAccess])
        defer { grants?.close() }
        try process.run()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errorData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "ApexSSH", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey:
                message.isEmpty ? "无法读取远程目录（退出码 \(process.terminationStatus)）" : String(message.prefix(512))])
        }
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return Self.parseDirectoryListing(output, path: path)
    }

    static func parseDirectoryListing(_ output: String, path: String) -> [SFTPItem] {
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
            
            // Keep the original filename suffix; joining tokens destroys repeated spaces.
            let rawName = String(line[parts[nameIndex].startIndex...])
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
                permissions: Self.permissionMode(from: perms),
                modificationDate: modDate
            ))
        }
        return items
    }
    
    static func scpRemoteSpecifier(username: String, host: String, path: String) -> String {
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(username)@\(address):\(path)"
    }

    public func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {
        await resolvePasswordIfNeeded()
        let keyAccess = try acquirePrivateKeyAccess()
        defer { keyAccess?.close() }
        let localAccess = distributionChannel == .appStore ? try fileAccessStore.acquire(localURL) : nil
        defer { localAccess?.close() }
        let accessibleURL = localAccess?.url ?? localURL
        let process = Process()
        process.standardInput = FileHandle.nullDevice
        let sshpass = self.sshpassExecutablePath
        
        var baseArgs: [String] = [
            "-r",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3"
        ]
        baseArgs.append(contentsOf: sshAuthArgs(privateKeyURL: keyAccess?.url))
        baseArgs.append(contentsOf: jumpServerArgs())
        // Modern scp uses SFTP: the remote path is already one argv operand.
        // Shell quote characters would become part of the filename.
        let escapedRemote = remotePath
        baseArgs.append(contentsOf: [
            "-P", "\(session.port)",
            Self.scpRemoteSpecifier(username: session.username, host: session.host, path: escapedRemote),
            accessibleURL.path
        ])
        
        if let pw = resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = ["-p", pw, "/usr/bin/scp"] + baseArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = baseArgs
        }
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        let grants = try configureStoreProcess(process, accesses: [keyAccess, localAccess])
        defer { grants?.close() }
        let errorOutput = try await Self.runSCPProcess(process, standardError: errPipe)
        guard process.terminationStatus == 0 else {
            let errMsg = String(data: errorOutput, encoding: .utf8) ?? "scp download failed"
            throw NSError(domain: "ApexSSH", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
        progress(1.0)
    }
    
    public func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws {
        await resolvePasswordIfNeeded()
        let keyAccess = try acquirePrivateKeyAccess()
        defer { keyAccess?.close() }
        let localAccess = distributionChannel == .appStore ? try fileAccessStore.acquire(localURL) : nil
        defer { localAccess?.close() }
        let accessibleURL = localAccess?.url ?? localURL
        let process = Process()
        process.standardInput = FileHandle.nullDevice
        let sshpass = self.sshpassExecutablePath
        
        var baseArgs: [String] = [
            "-r",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3"
        ]
        baseArgs.append(contentsOf: sshAuthArgs(privateKeyURL: keyAccess?.url))
        baseArgs.append(contentsOf: jumpServerArgs())
        // Modern scp uses SFTP: the remote path is already one argv operand.
        // Shell quote characters would become part of the filename.
        let escapedRemote = remotePath
        baseArgs.append(contentsOf: [
            "-P", "\(session.port)",
            accessibleURL.path,
            Self.scpRemoteSpecifier(username: session.username, host: session.host, path: escapedRemote)
        ])
        
        if let pw = resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = ["-p", pw, "/usr/bin/scp"] + baseArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = baseArgs
        }
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        let grants = try configureStoreProcess(process, accesses: [keyAccess, localAccess])
        defer { grants?.close() }
        let errorOutput = try await Self.runSCPProcess(process, standardError: errPipe)
        guard process.terminationStatus == 0 else {
            let errMsg = String(data: errorOutput, encoding: .utf8) ?? "scp upload failed"
            throw NSError(domain: "ApexSSH", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
        progress(1.0)
    }
    
    /// Drain probe output while SSH runs, rather than waiting with a full pipe.
    static func runProbeProcess(_ process: Process) async throws -> Data {
        let pipe = Pipe()
        process.standardOutput = pipe
        let reader = Task.detached { (try? pipe.fileHandleForReading.readToEnd()) ?? Data() }
        do {
            try await runTransferProcess(process)
            try? pipe.fileHandleForWriting.close()
            let output = await reader.value
            try? pipe.fileHandleForReading.close()
            try Task.checkCancellation()
            return output
        } catch {
            try? pipe.fileHandleForWriting.close()
            _ = await reader.value
            try? pipe.fileHandleForReading.close()
            throw error
        }
    }

    /// Cancel the underlying transfer or metrics process as well as its Swift task without blocking threads.
    static func runTransferProcess(_ process: Process) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let lock = OSAllocatedUnfairLock(initialState: false)
                process.terminationHandler = { _ in
                    let shouldResume = lock.withLock { isResumed in
                        let prev = isResumed
                        isResumed = true
                        return !prev
                    }
                    if shouldResume {
                        continuation.resume()
                    }
                }
                do {
                    try process.run()
                    if Task.isCancelled { stopCancelledProcess(process) }
                } catch {
                    let shouldResume = lock.withLock { isResumed in
                        let prev = isResumed
                        isResumed = true
                        return !prev
                    }
                    if shouldResume {
                        continuation.resume(throwing: error)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            stopCancelledProcess(process)
        }
    }

    /// Drain scp's stderr while it runs. Waiting first can deadlock once the pipe fills.
    static func runSCPProcess(_ process: Process, standardError pipe: Pipe) async throws -> Data {
        let reader = Task.detached(priority: .utility) { () -> Data in
            var tail = Data()
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16_384),
                  !chunk.isEmpty {
                tail.append(chunk)
                if tail.count > 65_536 { tail = Data(tail.suffix(65_536)) }
            }
            return tail
        }
        do {
            try await runTransferProcess(process)
            try? pipe.fileHandleForWriting.close()
            let output = await reader.value
            try? pipe.fileHandleForReading.close()
            return output
        } catch {
            try? pipe.fileHandleForWriting.close()
            _ = await reader.value
            try? pipe.fileHandleForReading.close()
            throw error
        }
    }

    private static func stopCancelledProcess(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // sshpass can own an SSH child in another process group. Stop the
        // descendants before their parent so they cannot outlive cancellation.
        for child in ptyDescendants(of: pid).reversed() { kill(child, SIGKILL) }
        kill(pid, SIGKILL)
    }

    private func executeRemoteCommand(_ cmd: String) async throws {
        await resolvePasswordIfNeeded()
        let keyAccess = try acquirePrivateKeyAccess()
        defer { keyAccess?.close() }
        let process = Process()
        let sshpass = self.sshpassExecutablePath
        let ctrlArgs = [
            "-o", "ControlMaster=auto",
            "-o", controlSocketOption,
            "-o", "ControlPersist=60s"
        ]
        
        let authArgs = sshAuthArgs(privateKeyURL: keyAccess?.url)
        let jumpArgs = jumpServerArgs()
        if let pw = resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = [
                "-p", pw,
                "/usr/bin/ssh",
                "-o", "StrictHostKeyChecking=accept-new",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "StrictHostKeyChecking=accept-new",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(session.port)",
                "\(session.username)@\(session.host)",
                cmd
            ]
        }
        
        let errPipe = Pipe()
        process.standardError = errPipe
        let grants = try configureStoreProcess(process, accesses: [keyAccess])
        defer { grants?.close() }
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Remote command execution failed"
            throw NSError(domain: "ApexSSH", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg.isEmpty ? "Operation failed with exit code \(process.terminationStatus)" : errMsg])
        }
    }
    
    static func permissionMode(from symbolic: String) -> UInt32 {
        let chars = Array(symbolic.dropFirst().prefix(9))
        guard chars.count == 9 else { return 0 }
        var mode: UInt32 = 0
        for (index, char) in chars.enumerated() {
            if char == "r" || char == "w" || char == "x" || char == "s" || char == "t" {
                mode |= 1 << (8 - index)
            }
        }
        if chars[2] == "s" || chars[2] == "S" { mode |= 0o4000 }
        if chars[5] == "s" || chars[5] == "S" { mode |= 0o2000 }
        if chars[8] == "t" || chars[8] == "T" { mode |= 0o1000 }
        return mode
    }

    /// Quote a remote shell argument without expanding filenames as shell syntax.
    static func quoteRemotePath(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public func removeFile(remotePath: String) async throws {
        try await executeRemoteCommand("rm -f \(Self.quoteRemotePath(remotePath))")
    }

    public func removeDirectory(remotePath: String, recursive: Bool) async throws {
        let command = recursive ? "rm -rf" : "rmdir"
        try await executeRemoteCommand("\(command) \(Self.quoteRemotePath(remotePath))")
    }

    public func createDirectory(remotePath: String) async throws {
        try await executeRemoteCommand("mkdir -p \(Self.quoteRemotePath(remotePath))")
    }

    public func createFile(remotePath: String) async throws {
        try await executeRemoteCommand("touch \(Self.quoteRemotePath(remotePath))")
    }

    public func rename(oldPath: String, newPath: String) async throws {
        try await executeRemoteCommand("mv \(Self.quoteRemotePath(oldPath)) \(Self.quoteRemotePath(newPath))")
    }

    public func changePermissions(remotePath: String, permissions: String) async throws {
        try await executeRemoteCommand("chmod \(Self.quoteRemotePath(permissions)) \(Self.quoteRemotePath(remotePath))")
    }
}
