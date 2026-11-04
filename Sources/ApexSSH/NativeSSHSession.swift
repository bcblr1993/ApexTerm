import Foundation
import ApexCore
import os

#if canImport(Darwin)
import Darwin
#endif

/// Serializes ControlMaster socket establishment per session so concurrent probes/SFTP commands
/// never spawn duplicate `[mux]` processes that overwrite and later unlink the active socket.
actor ControlSocketGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isLocked = false
        }
    }
}

/// Real native SSH session implementation using Darwin POSIX PTY, bundled standalone sshpass, and real-time probe
public final class NativeSSHSession: SSHSessionProtocol, @unchecked Sendable {
    public let session: Session
    private let distributionChannel: DistributionChannel
    private let fileAccessStore: FileAccessStore
    private var connectionKeyAccess: FileAccessLease?
    private var connectionCertAccess: FileAccessLease?
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
    private let controlSocketGate = ControlSocketGate()
    private let inputQueue = DispatchQueue(label: "com.apexterm.pty-input", qos: .userInteractive)
    private var childPid: pid_t = -1
    private var currentDimensions: (columns: Int, rows: Int) = (120, 35)
    private var readSource: DispatchSourceRead?
    private var probeTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var processActivityToken: NSObjectProtocol?
    private var lastPTYActivityTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var keepAlivePixelToggle: UInt16 = 0
    private var explicitDisconnectRequested = false
    private var recentInputLineBuffer = ""
    private var lastUserExitCommandAt: Date = .distantPast
    
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
    private var storedTerminalType: TerminalType
    
    public var terminalType: TerminalType { stateLock.withLock { storedTerminalType } }
    
    public func setTerminalType(_ type: TerminalType) {
        stateLock.withLock { storedTerminalType = type }
    }
    
    public var wasUserInitiatedDisconnect: Bool {
        stateLock.withLock {
            if explicitDisconnectRequested { return true }
            return Date().timeIntervalSince(lastUserExitCommandAt) < 4.0
        }
    }

    /// Evaluates the return value of `read(ptyMasterFd, ...)` on a Darwin PTY.
    /// Returns `true` when the read source must stay active (either data was read or the read was
    /// transiently interrupted by `EINTR`/`EAGAIN`/`EWOULDBLOCK`, e.g. `SIGCHLD` from background probes),
    /// and `false` only on genuine EOF (`bytesRead == 0`) or terminal hangup (`EIO`, `EBADF`, `ENXIO`).
    public static func shouldKeepReadingAfterReadResult(bytesRead: Int, errnoValue: Int32) -> Bool {
        if bytesRead > 0 { return true }
        if bytesRead == 0 { return false }
        return errnoValue == EINTR || errnoValue == EAGAIN || errnoValue == EWOULDBLOCK
    }

    /// Effective keep-alive interval in seconds (clamped to 5...60s; defaults to 15s when <= 0).
    public static func effectiveKeepAliveInterval(configured: Int) -> Int {
        guard configured > 0 else { return 15 }
        return min(max(configured, 5), 60)
    }

    /// Standard OpenSSH transport keep-alive options for interactive PTY sessions.
    /// Sends an encrypted SSH global keep-alive request every `interval` seconds and tolerates up to
    /// 10 consecutive missed responses so brief Wi-Fi roams or VPN blips do not drop the session.
    public static func sshKeepAliveArguments(configuredInterval: Int) -> [String] {
        let interval = effectiveKeepAliveInterval(configured: configuredInterval)
        return [
            "-o", "TCPKeepAlive=yes",
            "-o", "ServerAliveInterval=\(interval)",
            "-o", "ServerAliveCountMax=10"
        ]
    }

    /// Detects whether user input represents an intentional shell exit (`Ctrl+D`, `exit`, `logout`).
    public static func recordExitIntent(data: Data, lineBuffer: inout String) -> Bool {
        if data.contains(4) && lineBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        guard let str = String(data: data, encoding: .utf8) else { return false }
        var detected = false
        for ch in str {
            if ch == "\r" || ch == "\n" {
                let cmd = lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if cmd == "exit" || cmd == "logout" || cmd.hasPrefix("exit ") {
                    detected = true
                }
                lineBuffer = ""
            } else if ch == "\u{7F}" || ch == "\u{08}" {
                if !lineBuffer.isEmpty { lineBuffer.removeLast() }
            } else if ch == "\u{03}" || ch == "\u{15}" {
                lineBuffer = ""
            } else if !ch.isNewline {
                lineBuffer.append(ch)
                if lineBuffer.count > 128 {
                    lineBuffer = String(lineBuffer.suffix(64))
                }
            }
        }
        return detected
    }

    /// Reads user preference for enhanced dual-layer PTY & App Nap keep-alive (defaults to true).
    public static func isEnhancedKeepAliveEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "settings.ssh.keepAliveEnhanced") as? Bool ?? true
    }

    private func beginSessionActivityAssertion() {
        guard Self.isEnhancedKeepAliveEnabled() else { return }
        stateLock.withLock {
            if processActivityToken == nil {
                processActivityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                    reason: "Active SSH Terminal Session (\(session.host))"
                )
            }
        }
    }

    private func endSessionActivityAssertion() {
        stateLock.withLock {
            if let token = processActivityToken {
                ProcessInfo.processInfo.endActivity(token)
                processActivityToken = nil
            }
        }
    }

    private func recordPTYActivity() {
        stateLock.withLock {
            lastPTYActivityTime = ProcessInfo.processInfo.systemUptime
        }
    }
    
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
        self.storedTerminalType = session.terminalType
        self.distributionChannel = distributionChannel
        self.fileAccessStore = fileAccessStore
        self.bridgeExecutableURL = bridgeExecutableURL ?? URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/MacOS/ApexSSHBridge")
        self.sandboxPaths = SandboxSSHPaths(home: sandboxHomeURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            temporary: sandboxTemporaryURL ?? FileManager.default.temporaryDirectory)
        if let jumpId = session.jumpServerId, Thread.isMainThread {
            self.resolvedJumpServer = MainActor.assumeIsolated {
                SessionStore.shared.sessions.first(where: { $0.id == jumpId })
            }
            self.didResolveJumpServer = true
        }
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

    public func sshAuthArgs(privateKeyURL: URL? = nil, certificateURL: URL? = nil) -> [String] {
        var args: [String] = []
        switch session.authMethod {
        case .privateKey(let keyPath, _):
            if !keyPath.isEmpty {
                let connectedURL = stateLock.withLock { connectionKeyAccess?.url }
                let expanded = (privateKeyURL ?? connectedURL)?.path ?? Self.expandPath(keyPath)
                args.append(contentsOf: ["-i", expanded])
            }
        case .certificate(let keyPath, let certPath, _):
            if !keyPath.isEmpty {
                let connectedURL = stateLock.withLock { connectionKeyAccess?.url }
                let expanded = (privateKeyURL ?? connectedURL)?.path ?? Self.expandPath(keyPath)
                args.append(contentsOf: ["-i", expanded])
            }
            if !certPath.isEmpty {
                let connectedCertURL = stateLock.withLock { connectionCertAccess?.url }
                let expandedCert = (certificateURL ?? connectedCertURL)?.path ?? Self.expandPath(certPath)
                args.append(contentsOf: ["-o", "CertificateFile=\(expandedCert)"])
            }
        default:
            break
        }
        return args
    }

    /// Key and certificate sessions resolve a key passphrase rather than a login password.
    var usesKeyPassphrase: Bool {
        switch session.authMethod {
        case .privateKey, .certificate: return true
        default: return false
        }
    }

    /// sshpass only matches "assword" by default; OpenSSH asks "Enter passphrase for key".
    func sshpassArguments(secret: String, tool: String) -> [String] {
        var args = ["-p", secret]
        if usesKeyPassphrase { args.append(contentsOf: ["-P", "passphrase"]) }
        args.append(tool)
        return args
    }

    /// Every child operation owns its grant independently, including cancellation cleanup.
    func acquirePrivateKeyAccess() throws -> FileAccessLease? {
        guard distributionChannel == .appStore,
              let path = session.privateKeyPath, !path.isEmpty else { return nil }
        let access = try fileAccessStore.acquire(URL(fileURLWithPath: Self.expandPath(path)))
        guard FileManager.default.isReadableFile(atPath: access.url.path) else {
            access.close()
            throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "无法读取私钥，请在会话设置中通过「浏览」重新授权私钥文件。"])
        }
        return access
    }

    func acquireCertificateAccess() throws -> FileAccessLease? {
        guard distributionChannel == .appStore,
              let certPath = session.certificatePath, !certPath.isEmpty else { return nil }
        let access = try fileAccessStore.acquire(URL(fileURLWithPath: Self.expandPath(certPath)))
        guard FileManager.default.isReadableFile(atPath: access.url.path) else {
            access.close()
            throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "无法读取 SSH 证书，请在会话设置中通过「浏览」重新授权证书文件。"])
        }
        return access
    }

    struct PreparedStoreCommand {
        let binaryPath: String
        let arguments: [String]
        let grants: ChildProcessFileGrants
    }

    func prepareStoreCommand(binaryPath: String, arguments: [String], accesses: [FileAccessLease?], authenticationSecret: String? = nil) throws -> PreparedStoreCommand? {
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
            // Optional `-P <prompt>` follows the secret for key passphrases.
            let toolIndex = arguments[2] == "-P" ? 4 : 2
            guard arguments.count > toolIndex else { throw CocoaError(.fileReadCorruptFile) }
            toolPath = arguments[toolIndex]
            toolArguments = Array(arguments.dropFirst(toolIndex + 1))
        }
        guard toolPath == "/usr/bin/ssh" || toolPath == "/usr/bin/scp" else { throw CocoaError(.fileReadNoPermission) }
        let tool = toolPath == "/usr/bin/scp" ? "scp" : "ssh"
        try sandboxPaths.prepare()
        toolArguments = try sandboxPaths.arguments(prependingTo: toolArguments, tool: tool)
        if tool == "scp" { toolArguments = ["-S", bridgeExecutableURL.path] + toolArguments }
        let authentication: ChildProcessAuthentication?
        if let secret = usesPasswordHelper ? arguments[1] : authenticationSecret ?? stateLock.withLock({ resolvedPassword }), !secret.isEmpty {
            let kind: ChildProcessAuthentication.Kind
            kind = usesKeyPassphrase ? .passphrase : .password
            authentication = ChildProcessAuthentication(kind: kind, secret: secret)
        } else { authentication = nil }
        let grants = try ChildProcessFileGrants(files: accesses.compactMap { try $0?.childProcessGrant() }, authentication: authentication)
        let bridgeArguments = ["--tool", tool] + toolArguments
        // OpenSSH invokes this inherited helper for authentication; sshpass's
        // controlling-terminal ioctl is forbidden by App Sandbox.
        return PreparedStoreCommand(binaryPath: bridgeExecutableURL.path,
                                    arguments: bridgeArguments,
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
    private var didResolveJumpServer = false
    public var customJumpSession: Session? {
        get { stateLock.withLock { resolvedJumpServer } }
        set {
            stateLock.withLock {
                resolvedJumpServer = newValue
                didResolveJumpServer = true
            }
        }
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
        let foundPassword = await SSHTunnelManager.resolveSecret(for: session)
        stateLock.withLock { self.resolvedPassword = foundPassword }
        await resolveJumpServerIfNeeded()
    }

    private func resolveJumpServerIfNeeded() async {
        if stateLock.withLock({ resolvedJumpServer != nil || didResolveJumpServer }) { return }
        guard let jumpId = session.jumpServerId else {
            stateLock.withLock { didResolveJumpServer = true }
            return
        }
        let found: Session? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(_ value: Session?) {
                let shouldResume = resumed.withLock { state -> Bool in
                    guard !state else { return false }
                    state = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: value)
                }
            }
            Task { @MainActor in
                let matched = SessionStore.shared.sessions.first(where: { $0.id == jumpId })
                resumeOnce(matched)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(25)) {
                resumeOnce(nil)
            }
        }
        stateLock.withLock {
            if let found { self.resolvedJumpServer = found }
            self.didResolveJumpServer = true
        }
    }
    
    public func connect() async throws {
        // Clean up any existing connection resources to prevent fd or process leaks on reconnect
        if ptyMasterFd != -1 || readSource != nil || childPid > 0 {
            await disconnect()
        }
        
        // A peer disconnect may leave the previous probe finishing cancellation.
        let previousKeepAlive = keepAliveTask
        previousKeepAlive?.cancel()
        keepAliveTask = nil
        let previousProbe = probeTask
        previousProbe?.cancel()
        probeTask = nil
        await previousProbe?.value
        prevCpu = nil
        prevNet = nil
        directoryStream = DirectoryChangeStreamParser()
        recentPromptBuffer = ""
        lastReportedDirectory = ""
        stateLock.withLock {
            explicitDisconnectRequested = false
            recentInputLineBuffer = ""
            lastUserExitCommandAt = .distantPast
            lastPTYActivityTime = ProcessInfo.processInfo.systemUptime
        }
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

        let certAccess: FileAccessLease?
        do { certAccess = try acquireCertificateAccess() }
        catch {
            self.connectionState = .failed(error.localizedDescription)
            throw error
        }
        var transferredCertAccess = false
        defer { if !transferredCertAccess { certAccess?.close() } }

        // Setup command & arguments
        var binaryPath = "/usr/bin/ssh"
        var sshArgs = ["-tt"] + Self.sshKeepAliveArguments(configuredInterval: session.keepAliveIntervalSeconds) + [
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        sshArgs.append(contentsOf: sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url))
        sshArgs.append(contentsOf: jumpServerArgs())
        sshArgs.append(contentsOf: [
            "-p", "\(session.port)",
            "\(session.username)@\(session.host)"
        ])
        
        if let pw = resolvedPassword, !pw.isEmpty, let sshpass = sshpassExecutablePath {
            binaryPath = sshpass
            sshArgs = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + sshArgs
        }
        
        let storeCommand: PreparedStoreCommand?
        do { storeCommand = try prepareStoreCommand(binaryPath: binaryPath, arguments: sshArgs, accesses: [keyAccess, certAccess]) }
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

        let masterFlags = fcntl(master, F_GETFL, 0)
        if masterFlags >= 0 {
            _ = fcntl(master, F_SETFL, masterFlags | O_NONBLOCK)
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
        
        let envVars = Self.ptyEnvironment(
            terminalType: terminalType,
            inherited: ProcessInfo.processInfo.environment,
            grantsPath: storeCommand?.grants.fileURL.path
        )
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
        stateLock.withLock {
            connectionKeyAccess = keyAccess
            connectionCertAccess = certAccess
            connectionGrantRequest = storeCommand?.grants
        }
        transferredKeyAccess = true
        transferredCertAccess = true
        beginSessionActivityAssertion()
        self.connectionState = .connected
        
        // Setup asynchronous kqueue read source
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: DispatchQueue.global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = read(master, &buffer, buffer.count)
            if bytesRead > 0 {
                self.recordPTYActivity()
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
            } else {
                let err = errno
                if Self.shouldKeepReadingAfterReadResult(bytesRead: bytesRead, errnoValue: err) {
                    return
                }
                self.keepAliveTask?.cancel()
                self.probeTask?.cancel()
                self.endSessionActivityAssertion()
                self.connectionState = .disconnected
                source.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            if let self {
                self.endSessionActivityAssertion()
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
        startChannelKeepAliveLoop()
        
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
        stateLock.withLock { explicitDisconnectRequested = true }
        self.connectionState = .disconnected
        endSessionActivityAssertion()
        let pendingKeepAlive = keepAliveTask
        pendingKeepAlive?.cancel()
        keepAliveTask = nil
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

        // Clean up multiplex socket without blocking the caller if the socket is wedged
        let socket = controlSocketPath
        if FileManager.default.fileExists(atPath: socket) {
            let controlOpt = controlSocketOption
            let destination = "\(session.username)@\(session.host)"
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = ["-O", "exit", "-o", controlOpt, destination]
                proc.standardInput = FileHandle.nullDevice
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                let grants = try? self?.configureStoreProcess(proc, accesses: [])
                defer { grants?.close() }
                if (try? proc.run()) != nil {
                    for _ in 0..<20 where proc.isRunning {
                        usleep(10_000)
                    }
                    if proc.isRunning {
                        kill(proc.processIdentifier, SIGKILL)
                    }
                }
                try? FileManager.default.removeItem(atPath: socket)
            }
        }
    }
    
    /// Synchronous exit cleanup: SSH ignores ordinary termination signals while attached to a PTY.
    /// Each spawned connection owns a process group, so this cannot target another session.
    public func terminatePTYProcess() {
        stateLock.withLock { explicitDisconnectRequested = true }
        endSessionActivityAssertion()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        probeTask?.cancel()
        probeTask = nil
        try? FileManager.default.removeItem(atPath: controlSocketPath)

        let (keyAccess, certAccess) = stateLock.withLock { () -> (FileAccessLease?, FileAccessLease?) in
            defer { connectionKeyAccess = nil; connectionCertAccess = nil }
            return (connectionKeyAccess, connectionCertAccess)
        }
        let grants = stateLock.withLock { () -> ChildProcessFileGrants? in
            defer { connectionGrantRequest = nil }
            return connectionGrantRequest
        }
        defer { grants?.close(); keyAccess?.close(); certAccess?.close() }
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
        for _ in 0..<25 {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited != 0 { break }
            usleep(2_000)
        }
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
        let descriptor = stateLock.withLock { () -> Int32 in
            lastPTYActivityTime = ProcessInfo.processInfo.systemUptime
            if Self.recordExitIntent(data: data, lineBuffer: &recentInputLineBuffer) {
                lastUserExitCommandAt = Date()
            }
            return ptyMasterFd >= 0 ? dup(ptyMasterFd) : -1
        }
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

    public var controlMasterArguments: [String] {
        [
            "-o", "TCPKeepAlive=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=6",
            "-o", "ControlMaster=auto",
            "-o", controlSocketOption,
            "-o", "ControlPersist=4h"
        ]
    }

    public func probeRemoteHome() async -> String? {
        await resolvePasswordIfNeeded()
        let needsGate = !FileManager.default.fileExists(atPath: controlSocketPath)
        if needsGate { await controlSocketGate.acquire() }
        defer { if needsGate { Task { await controlSocketGate.release() } } }
        let keyAccess: FileAccessLease?
        do { keyAccess = try acquirePrivateKeyAccess() }
        catch { return nil }
        defer { keyAccess?.close() }
        let certAccess: FileAccessLease?
        do { certAccess = try acquireCertificateAccess() }
        catch { return nil }
        defer { certAccess?.close() }
        let process = Process()
        let cmd = "printf '%s\\n' \"$HOME\""
        let ctrlArgs = controlMasterArguments
        let authArgs = sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url)
        let jumpArgs = jumpServerArgs()
        if let pw = resolvedPassword, !pw.isEmpty, let sshpass = sshpassExecutablePath {
            process.executableURL = URL(fileURLWithPath: sshpass)
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
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
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            let grants = try configureStoreProcess(process, accesses: [keyAccess, certAccess])
            defer { grants?.close() }
            let data = try await Self.runProbeProcess(process)
            guard process.terminationStatus == 0 else { return nil }
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
    
    /// Periodically sends a zero-character PTY channel window-change keep-alive when idle
    /// so intermediate firewalls, bastion hosts, and remote PTY channels stay active without
    /// injecting any bytes into the user's shell or editor.
    private func startChannelKeepAliveLoop() {
        let intervalSeconds = max(15, Self.effectiveKeepAliveInterval(configured: session.keepAliveIntervalSeconds))
        keepAliveTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                guard let self = self, !Task.isCancelled, self.connectionState == .connected else { break }
                guard Self.isEnhancedKeepAliveEnabled() else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                let shouldPulse: (fd: Int32, pid: pid_t, cols: Int, rows: Int, pixel: UInt16)? = self.stateLock.withLock {
                    guard self.ptyMasterFd >= 0, self.childPid > 0 else { return nil }
                    guard now - self.lastPTYActivityTime >= Double(intervalSeconds - 1) else { return nil }
                    self.keepAlivePixelToggle = self.keepAlivePixelToggle == 0 ? 1 : 0
                    return (self.ptyMasterFd, self.childPid, self.currentDimensions.columns, self.currentDimensions.rows, self.keepAlivePixelToggle)
                }
                if let pulse = shouldPulse {
                    var win = winsize(
                        ws_row: UInt16(max(3, pulse.rows)),
                        ws_col: UInt16(max(10, pulse.cols)),
                        ws_xpixel: pulse.pixel,
                        ws_ypixel: 0
                    )
                    _ = ioctl(pulse.fd, TIOCSWINSZ, &win)
                    kill(pulse.pid, SIGWINCH)
                    kill(-pulse.pid, SIGWINCH)
                    for child in Self.ptyDescendants(of: pulse.pid) {
                        kill(child, SIGWINCH)
                    }
                }
            }
        }
    }

    private func startAgentlessProbeLoop() {
        probeTask = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            while !Task.isCancelled {
                guard let self = self, self.connectionState == .connected else { break }
                
                let needsGate = !FileManager.default.fileExists(atPath: self.controlSocketPath)
                if needsGate { await self.controlSocketGate.acquire() }
                defer { if needsGate { Task { await self.controlSocketGate.release() } } }
                
                let process = Process()
                let sshpass = self.sshpassExecutablePath
                let ctrlArgs = self.controlMasterArguments
                
                let keyAccess: FileAccessLease?
                do { keyAccess = try self.acquirePrivateKeyAccess() }
                catch {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                defer { keyAccess?.close() }
                let certAccess: FileAccessLease?
                do { certAccess = try self.acquireCertificateAccess() }
                catch {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                defer { certAccess?.close() }
                let authArgs = self.sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url)
                let jumpArgs = self.jumpServerArgs()
                if let pw = self.resolvedPassword, !pw.isEmpty, let passBin = sshpass {
                    process.executableURL = URL(fileURLWithPath: passBin)
                    process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
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
                    let grants = try self.configureStoreProcess(process, accesses: [keyAccess, certAccess])
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
                
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s smooth sampling interval
            }
        }
    }
    
    /// Environment for the ssh child; ssh forwards TERM to the remote PTY request.
    static func ptyEnvironment(terminalType: TerminalType, inherited: [String: String], grantsPath: String?) -> [String] {
        var envVars = [
            "TERM=\(terminalType.rawValue)",
            "COLORTERM=truecolor",
            "LANG=en_US.UTF-8",
            "LC_ALL=en_US.UTF-8"
        ]
        if let path = inherited["PATH"] {
            envVars.append("PATH=\(path):/usr/local/bin:/opt/homebrew/bin")
        } else {
            envVars.append("PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin")
        }
        if let grantsPath {
            envVars.append("\(ChildProcessFileGrants.environmentKey)=\(grantsPath)")
        }
        let overridden: Set<String> = ["TERM", "COLORTERM", "LANG", "LC_ALL", "PATH", ChildProcessFileGrants.environmentKey]
        for (k, v) in inherited where !overridden.contains(k) {
            envVars.append("\(k)=\(v)")
        }
        return envVars
    }
    
    /// Executes a one-shot remote command over multiplexed SSH socket
    public func executeCommand(_ command: String) async throws -> String {
        await resolvePasswordIfNeeded()
        let needsGate = !FileManager.default.fileExists(atPath: controlSocketPath)
        if needsGate { await controlSocketGate.acquire() }
        defer { if needsGate { Task { await controlSocketGate.release() } } }
        let process = Process()
        let sshpass = self.sshpassExecutablePath
        let ctrlArgs = controlMasterArguments
        
        let keyAccess: FileAccessLease?
        keyAccess = try? self.acquirePrivateKeyAccess()
        defer { keyAccess?.close() }
        let certAccess = try? self.acquireCertificateAccess()
        defer { certAccess?.close() }
        let authArgs = self.sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url)
        let jumpArgs = self.jumpServerArgs()
        if let pw = self.resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=5",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(self.session.port)",
                "\(self.session.username)@\(self.session.host)",
                command
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=5",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(self.session.port)",
                "\(self.session.username)@\(self.session.host)",
                command
            ]
        }
        
        process.standardError = FileHandle.nullDevice
        let grants = try? self.configureStoreProcess(process, accesses: [keyAccess, certAccess])
        defer { grants?.close() }
        let outData = try await Self.runProbeProcess(process)
        return String(data: outData, encoding: .utf8) ?? ""
    }
    
    public func setExplicitPassword(_ password: String?) {
        stateLock.withLock {
            self.resolvedPassword = password
        }
    }

    /// Tests connectivity and credential authentication to the remote SSH server
    public func testConnection(explicitPassword: String? = nil, timeoutSeconds: Int = 5) async -> SSHTestConnectionResult {
        if let explicitPassword {
            stateLock.withLock { self.resolvedPassword = explicitPassword }
            await resolveJumpServerIfNeeded()
        } else {
            await resolvePasswordIfNeeded()
        }
        
        let start = Date()
        
        if let keyPath = self.session.privateKeyPath, !keyPath.isEmpty {
            let expanded = Self.expandPath(keyPath)
            if !FileManager.default.fileExists(atPath: expanded) {
                return SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: "指定的私钥文件不存在: \(keyPath)")
            }
        }
        if let certPath = self.session.certificatePath, !certPath.isEmpty {
            let expanded = Self.expandPath(certPath)
            if !FileManager.default.fileExists(atPath: expanded) {
                return SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: "指定的证书文件不存在: \(certPath)")
            }
        }
        
        let process = Process()
        let sshpass = self.sshpassExecutablePath
        
        let keyAccess: FileAccessLease?
        do {
            keyAccess = try self.acquirePrivateKeyAccess()
        } catch {
            return SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: "私钥文件无法读取或缺少权限: \(error.localizedDescription)")
        }
        defer { keyAccess?.close() }
        
        let certAccess: FileAccessLease?
        do {
            certAccess = try self.acquireCertificateAccess()
        } catch {
            return SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: "证书文件无法读取或缺少权限: \(error.localizedDescription)")
        }
        defer { certAccess?.close() }
        
        let authArgs = self.sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url)
        let jumpArgs = self.jumpServerArgs()
        
        let probeCommand = "uname -s -m 2>/dev/null || echo ok"
        let baseSSHArgs = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=\(timeoutSeconds)",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ControlMaster=no",
        ] + authArgs + jumpArgs + [
            "-p", "\(self.session.port)",
            "\(self.session.username)@\(self.session.host)",
            probeCommand
        ]
        
        let pw = stateLock.withLock { self.resolvedPassword }
        if let pw = pw, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + baseSSHArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes"] + baseSSHArgs
        }
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        let grants: ChildProcessFileGrants?
        do {
            grants = try self.configureStoreProcess(process, accesses: [keyAccess, certAccess])
        } catch {
            return SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: "沙盒安全授权配置失败: \(error.localizedDescription)")
        }
        defer { grants?.close() }
        
        do {
            let (stdoutData, stderrData) = try await Self.runProcessWithOutput(process, outPipe: outPipe, errPipe: errPipe)
            let elapsedMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
            
            if process.terminationStatus == 0 {
                let info = String(data: stdoutData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanInfo = (info == "ok" || info?.isEmpty == true) ? nil : info
                return SSHTestConnectionResult(
                    isSuccess: true,
                    latencyMs: elapsedMs,
                    serverInfo: cleanInfo,
                    errorMessage: nil
                )
            } else {
                let errString = String(data: stderrData, encoding: .utf8) ?? ""
                let diagnostic = Self.parseSSHErrorMessage(exitCode: process.terminationStatus, stderr: errString)
                return SSHTestConnectionResult(
                    isSuccess: false,
                    latencyMs: elapsedMs,
                    serverInfo: nil,
                    errorMessage: diagnostic
                )
            }
        } catch {
            let elapsedMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
            return SSHTestConnectionResult(
                isSuccess: false,
                latencyMs: elapsedMs,
                serverInfo: nil,
                errorMessage: "连接测试执行失败: \(error.localizedDescription)"
            )
        }
    }
    
    public static func testConnection(
        session: Session,
        explicitPassword: String? = nil,
        timeoutSeconds: Int = 5,
        distributionChannel: DistributionChannel = .current
    ) async -> SSHTestConnectionResult {
        let client = NativeSSHSession(session: session, distributionChannel: distributionChannel)
        return await client.testConnection(explicitPassword: explicitPassword, timeoutSeconds: timeoutSeconds)
    }

    public static func parseSSHErrorMessage(exitCode: Int32, stderr: String) -> String {
        let cleanErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if cleanErr.contains("Bad passphrase") || cleanErr.contains("passphrase") {
            return "私钥口令 (Passphrase) 错误"
        }
        if cleanErr.contains("No such file or directory") || cleanErr.contains("not accessible") {
            return "指定的私钥或证书文件不存在"
        }
        if cleanErr.contains("Host key verification failed") {
            return "主机密钥校验冲突 (Host key verification failed)"
        }
        if exitCode == 5 {
            return "认证失败：用户名或密码错误 (Invalid password)"
        }
        if cleanErr.contains("Permission denied (password)") {
            return "认证失败：用户名或密码错误 (Permission denied)"
        }
        if cleanErr.contains("Permission denied (publickey)") {
            return "认证失败：用户名、私钥或证书不匹配 (Permission denied: publickey)"
        }
        if cleanErr.contains("Permission denied") {
            return "认证失败：用户名、密码或私钥/证书不匹配"
        }
        if cleanErr.contains("Connection refused") {
            return "连接被拒绝：请确认主机上的 SSH 端口是否正确或服务是否运行"
        }
        if cleanErr.contains("timed out") || cleanErr.contains("Operation timed out") {
            return "连接超时：无法在规定时间内连接至主机，请检查 IP 与网络"
        }
        if cleanErr.contains("Could not resolve hostname") || cleanErr.contains("nodename nor servname provided") {
            return "主机域名解析失败：找不到该主机，请检查主机名拼写"
        }
        if cleanErr.contains("No route to host") {
            return "网络不可达 (No route to host)"
        }
        if !cleanErr.isEmpty {
            let lines = cleanErr.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let first = lines.first {
                return first
            }
        }
        return "连接失败 (退出码 \(exitCode))"
    }

    /// Drain stdout and stderr while process runs without deadlocking on full pipe buffers
    static func runProcessWithOutput(_ process: Process, outPipe: Pipe, errPipe: Pipe) async throws -> (Data, Data) {
        let outReader = Task.detached(priority: .utility) { () -> Data in
            (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        let errReader = Task.detached(priority: .utility) { () -> Data in
            (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        do {
            try await runTransferProcess(process)
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            let outData = await outReader.value
            let errData = await errReader.value
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            return (outData, errData)
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            _ = await outReader.value
            _ = await errReader.value
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            throw error
        }
    }
    
    // SFTP implementation
    public func listDirectory(path: String) async throws -> [SFTPItem] {
        await resolvePasswordIfNeeded()
        let keyAccess = try acquirePrivateKeyAccess()
        defer { keyAccess?.close() }
        let certAccess = try acquireCertificateAccess()
        defer { certAccess?.close() }
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
        let needsGate = !FileManager.default.fileExists(atPath: controlSocketPath)
        if needsGate { await controlSocketGate.acquire() }
        defer { if needsGate { Task { await controlSocketGate.release() } } }
        let process = Process()
        let sshpass = self.sshpassExecutablePath
        // Ensure trailing slash so that symbolic links pointing to directories are properly traversed by ls
        let targetPath = path.hasSuffix("/") ? path : "\(path)/"
        let quotedPath = Self.quoteRemotePath(targetPath)
        let cmd = "LC_ALL=C ls -la --time-style=+%s \(quotedPath) 2>/dev/null || LC_ALL=C ls -la -D '%s' \(quotedPath) 2>/dev/null || LC_ALL=C ls -la \(quotedPath)"
        let ctrlArgs = [
            "-o", "ConnectTimeout=10"
        ] + controlMasterArguments
        
        let authArgs = sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url)
        let jumpArgs = jumpServerArgs()
        if let pw = resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
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
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = errPipe
        let grants = try configureStoreProcess(process, accesses: [keyAccess, certAccess])
        defer { grants?.close() }
        let outReader = Task.detached(priority: .utility) { (try? pipe.fileHandleForReading.readToEnd()) ?? Data() }
        let errReader = Task.detached(priority: .utility) { (try? errPipe.fileHandleForReading.readToEnd()) ?? Data() }
        do {
            try await Self.runTransferProcess(process)
        } catch {
            try? pipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            _ = await outReader.value
            _ = await errReader.value
            try? pipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            throw error
        }
        try? pipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        let data = await outReader.value
        let errorData = await errReader.value
        try? pipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        
        guard process.terminationStatus == 0 else {
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
        let certAccess = try acquireCertificateAccess()
        defer { certAccess?.close() }
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
        baseArgs.append(contentsOf: sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url))
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
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/scp") + baseArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = baseArgs
        }
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        let grants = try configureStoreProcess(process, accesses: [keyAccess, certAccess, localAccess])
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
        let certAccess = try acquireCertificateAccess()
        defer { certAccess?.close() }
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
        baseArgs.append(contentsOf: sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url))
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
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/scp") + baseArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = baseArgs
        }
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        let grants = try configureStoreProcess(process, accesses: [keyAccess, certAccess, localAccess])
        defer { grants?.close() }
        let totalBytes = max(1, TransferManager.currentTransferredBytes(at: accessibleURL))
        let progressMonitor = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, process.isRunning else { continue }
                let pid = process.processIdentifier
                if pid > 0 {
                    let readBytes = Self.currentUploadReadBytes(forPid: pid, targetURL: accessibleURL)
                    if readBytes > 0 {
                        let fraction = min(0.99, Double(readBytes) / Double(totalBytes))
                        progress(fraction)
                    }
                }
            }
        }
        defer { progressMonitor.cancel() }
        let errorOutput = try await Self.runSCPProcess(process, standardError: errPipe)
        progressMonitor.cancel()
        guard process.terminationStatus == 0 else {
            let errMsg = String(data: errorOutput, encoding: .utf8) ?? "scp upload failed"
            throw NSError(domain: "ApexSSH", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg])
        }
        progress(1.0)
    }

    /// Inspects open vnode file descriptors of `rootPid` (and any child processes like `scp` under `sshpass`)
    /// to determine the current read offset of `targetURL` during an active upload.
    public static func currentUploadReadBytes(forPid rootPid: pid_t, targetURL: URL) -> Int64 {
        guard rootPid > 0 else { return 0 }
        let resolvedTarget = targetURL.resolvingSymlinksInPath().path
        let candidatePids = [rootPid] + ptyDescendants(of: rootPid)
        var maxOffset: Int64 = 0

        for pid in candidatePids where pid > 0 {
            let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bufSize > 0 else { continue }
            let count = Int(bufSize) / MemoryLayout<proc_fdinfo>.stride
            guard count > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
            let actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufSize)
            guard actual > 0 else { continue }
            let actualCount = Int(actual) / MemoryLayout<proc_fdinfo>.stride

            for i in 0..<actualCount where fds[i].proc_fdtype == PROX_FDTYPE_VNODE {
                var vinfo = vnode_fdinfowithpath()
                let sz = proc_pidfdinfo(
                    pid,
                    fds[i].proc_fd,
                    PROC_PIDFDVNODEPATHINFO,
                    &vinfo,
                    Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                )
                guard sz == MemoryLayout<vnode_fdinfowithpath>.size else { continue }
                let openPath = withUnsafePointer(to: &vinfo.pvip.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                        String(cString: $0)
                    }
                }
                guard !openPath.isEmpty else { continue }
                let resolvedOpen = URL(fileURLWithPath: openPath).resolvingSymlinksInPath().path
                if resolvedOpen == resolvedTarget || resolvedOpen.hasPrefix(resolvedTarget + "/") {
                    let offset = Int64(vinfo.pfi.fi_offset)
                    if offset > maxOffset {
                        maxOffset = offset
                    }
                }
            }
        }
        return maxOffset
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
        let needsGate = !FileManager.default.fileExists(atPath: controlSocketPath)
        if needsGate { await controlSocketGate.acquire() }
        defer { if needsGate { Task { await controlSocketGate.release() } } }
        let keyAccess = try acquirePrivateKeyAccess()
        defer { keyAccess?.close() }
        let certAccess = try acquireCertificateAccess()
        defer { certAccess?.close() }
        let process = Process()
        let sshpass = self.sshpassExecutablePath
        let ctrlArgs = [
            "-o", "ConnectTimeout=10"
        ] + controlMasterArguments
        
        let authArgs = sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url)
        let jumpArgs = jumpServerArgs()
        if let pw = resolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
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
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        let grants = try configureStoreProcess(process, accesses: [keyAccess, certAccess])
        defer { grants?.close() }
        let errData = try await Self.runSCPProcess(process, standardError: errPipe)
        
        guard process.terminationStatus == 0 else {
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
