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
    private let connectionLogDirectory: URL
    private let stateLock = NSLock()
    private var storedConnectionState: SSHConnectionState = .disconnected
    public private(set) var connectionState: SSHConnectionState {
        get { stateLock.withLock { storedConnectionState } }
        set {
            let handler = stateLock.withLock { () -> (@Sendable (SSHConnectionState) -> Void)? in
                guard storedConnectionState != newValue else { return nil }
                storedConnectionState = newValue
                return stateChangeHandler
            }
            handler?(newValue)
        }
    }

    public enum ConnectionLogEvent: Sendable, Equatable {
        case step(String)
        case established
        case diagnostic(String)
        case ignore
    }

    private final class HandshakeTracker: @unchecked Sendable {
        let id: UUID
        var remainderBytes = Data()
        var diagnosticLines: [String] = []
        var isEstablished: Bool = false
        var isResolved: Bool = false
        var isResolvingTermination: Bool = false
        var terminalResult: Result<Void, Error>?
        var continuation: CheckedContinuation<Void, Error>?
        var ptyCloseFallbackTimer: DispatchSourceTimer?
        var ptyPromptDecoder = UTF8StreamDecoder()
        var ptyPromptTail = ""

        init(id: UUID) {
            self.id = id
        }
    }

    enum PTYPromptKind: Equatable {
        case none
        case password
        case passphrase
        case twoFactor
        case hostConfirm
    }

    static func classifyPTYPrompt(_ text: String) -> PTYPromptKind {
        if ChildProcessAuthentication.isTwoFactorPrompt(text) {
            return .twoFactor
        }
        if text.localizedCaseInsensitiveContains("continue connecting") {
            return .hostConfirm
        }
        if text.range(of: #"[pP]assphrase.*:"#, options: .regularExpression) != nil {
            return .passphrase
        }
        if text.range(of: #"[pP]assword\s*:"#, options: .regularExpression) != nil {
            return .password
        }
        return .none
    }
    
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var metricsHandler: (@Sendable (ServerMetricsSnapshot) -> Void)?
    private var directoryChangeHandler: (@Sendable (String) -> Void)?
    private var stateChangeHandler: (@Sendable (SSHConnectionState) -> Void)?
    
    private var ptyMasterFd: Int32 = -1
    private var connectionLogFd: Int32 = -1
    private var connectionLogPath: String?
    private var logReadSource: DispatchSourceFileSystemObject?
    private var handshakeProcessSource: DispatchSourceProcess?
    private var handshakeState: HandshakeTracker?
    private var activeAttemptId: UUID?
    private var isActiveAttemptEstablished = false
    private var isPTYClosed = false
    private var storedConnectTimeoutSeconds: Int = 15
    private let controlSocketIdentifier: String
    private let disableControlPersist: Bool
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

    public var connectTimeoutSeconds: Int {
        get { stateLock.withLock { storedConnectTimeoutSeconds } }
        set { stateLock.withLock { storedConnectTimeoutSeconds = newValue } }
    }
    
    public func setTerminalType(_ type: TerminalType) {
        stateLock.withLock { storedTerminalType = type }
    }

    /// Maps an OpenSSH `-E` debug1/diagnostic log line to a connection lifecycle milestone.
    public static func classifyConnectionLogLine(_ rawLine: String, host: String, port: Int) -> ConnectionLogEvent {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .ignore }
        if line.contains("Entering interactive session.") || line.contains("mux_client_request_session: master session id:") {
            return .established
        }
        if line.contains("auto-mux: Trying existing master") {
            return .step("正在复用已有 SSH 连接通道...")
        }
        if line.contains("Connecting to ") {
            return .step("正在建立连接 (\(host):\(port))...")
        }
        if line.contains("Connection established.") {
            return .step("已建立 TCP 连接，正在握手与验证身份...")
        }
        if line.contains("Offering public key:") || line.contains("Next authentication method: publickey") {
            return .step("正在验证密钥凭证...")
        }
        if line.contains("Next authentication method: password") || line.contains("Next authentication method: keyboard-interactive") {
            return .step("正在验证登录口令...")
        }
        if line.hasPrefix("Authenticated to ") {
            return .step("身份验证通过，正在开启远程终端...")
        }
        if line.hasPrefix("debug1:") || line.hasPrefix("debug2:") || line.hasPrefix("debug3:")
            || line.hasPrefix("OpenSSH_") || line.hasPrefix("Transferred: sent ")
            || line.hasPrefix("Bytes per second: sent ") {
            return .ignore
        }
        return .diagnostic(line)
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
                sandboxHomeURL: URL? = nil, sandboxTemporaryURL: URL? = nil,
                availableSessions: [Session]? = nil, disableControlPersist: Bool = false) {
        self.session = session
        self.storedTerminalType = session.terminalType
        self.distributionChannel = distributionChannel
        self.fileAccessStore = fileAccessStore
        self.disableControlPersist = disableControlPersist
        self.bridgeExecutableURL = bridgeExecutableURL ?? URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/MacOS/ApexSSHBridge")
        let tempDir = sandboxTemporaryURL ?? FileManager.default.temporaryDirectory
        self.connectionLogDirectory = tempDir
        let socketID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        self.controlSocketIdentifier = socketID
        self.sandboxPaths = SandboxSSHPaths(home: sandboxHomeURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            temporary: tempDir, identifier: socketID)
        if let availableSessions {
            let resolved = SSHArgumentBuilder.resolveJumpChain(for: session, availableSessions: availableSessions)
            self.resolvedJumpChain = resolved.hops
            self.didResolveJumpServer = true
        } else if !session.effectiveJumpServerChain.isEmpty, Thread.isMainThread {
            let resolved = MainActor.assumeIsolated {
                SSHArgumentBuilder.resolveJumpChain(for: session, availableSessions: SessionStore.shared.sessions)
            }
            self.resolvedJumpChain = resolved.hops
            self.didResolveJumpServer = true
        }
    }

    deinit {
        terminatePTYProcess()
    }
    
    public func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void) {
        stateLock.withLock { self.outputHandler = handler }
    }
    
    public func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void) {
        stateLock.withLock { self.metricsHandler = handler }
    }
    
    public func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void) {
        stateLock.withLock { self.directoryChangeHandler = handler }
    }
    
    public func setStateChangeHandler(_ handler: @Sendable @escaping (SSHConnectionState) -> Void) {
        stateLock.withLock { self.stateChangeHandler = handler }
    }

    private var currentResolvedPassword: String? {
        stateLock.withLock { resolvedPassword }
    }

    private func transitionConnectionState(
        for attemptId: UUID,
        to newState: SSHConnectionState,
        requirePending: Bool = false,
        requireEstablished: Bool = false
    ) {
        let handler = stateLock.withLock { () -> (@Sendable (SSHConnectionState) -> Void)? in
            guard self.activeAttemptId == attemptId else { return nil }
            if requirePending {
                guard !self.isActiveAttemptEstablished, !(self.handshakeState?.isResolved ?? true) else {
                    return nil
                }
            }
            if requireEstablished {
                guard self.isActiveAttemptEstablished else { return nil }
            }
            guard self.storedConnectionState != newState else { return nil }
            self.storedConnectionState = newState
            return self.stateChangeHandler
        }
        handler?(newState)
    }

    public static func expandPath(_ path: String) -> String {
        if KeychainStore.isVaultPrivateKeyReference(path) {
            return SSHKeyVaultManager.materializePrivateKeyPath(for: path) ?? path
        }
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
                let formattedCert = expandedCert.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" })
                    ? SandboxSSHPaths.quotedPath(expandedCert)
                    : expandedCert
                args.append(contentsOf: ["-o", "CertificateFile=\(formattedCert)"])
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
              let path = session.privateKeyPath, !path.isEmpty,
              !KeychainStore.isVaultPrivateKeyReference(path) else { return nil }
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
        let hasAuthentication: Bool
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
                                    grants: grants,
                                    hasAuthentication: authentication != nil)
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

    private var resolvedJumpChain: [Session] = []
    private var didResolveJumpServer = false
    public var customJumpSession: Session? {
        get { stateLock.withLock { resolvedJumpChain.first } }
        set {
            stateLock.withLock {
                resolvedJumpChain = newValue.map { [$0] } ?? []
                didResolveJumpServer = true
            }
        }
    }

    public var customJumpChain: [Session] {
        get { stateLock.withLock { resolvedJumpChain } }
        set {
            stateLock.withLock {
                resolvedJumpChain = newValue
                didResolveJumpServer = true
            }
        }
    }

    public func jumpServerArgs() -> [String] {
        let hops = stateLock.withLock { resolvedJumpChain }
        return SSHArgumentBuilder.jumpFlagArguments(hops: hops, proxyCommand: session.proxyCommand)
    }

    public func advancedConnectionArgs(channel: SSHInvocationChannel) -> [String] {
        let hops = stateLock.withLock { resolvedJumpChain }
        return SSHArgumentBuilder.buildAdvancedOptions(for: session, channel: channel, resolvedJumpHops: hops)
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
        await resolveJumpChainIfNeeded()
    }

    private var sshDestinationHost: String {
        let trimmed = session.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private func resolveJumpChainIfNeeded() async {
        if stateLock.withLock({ !resolvedJumpChain.isEmpty || didResolveJumpServer }) { return }
        guard !session.effectiveJumpServerChain.isEmpty else {
            stateLock.withLock { didResolveJumpServer = true }
            return
        }
        let resolution: (hops: [Session], completed: Bool) = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(_ value: ([Session], Bool)) {
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
                let result = SSHArgumentBuilder.resolveJumpChain(for: session, availableSessions: SessionStore.shared.sessions)
                resumeOnce((result.hops, true))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) {
                resumeOnce(([], false))
            }
        }
        stateLock.withLock {
            if resolution.completed {
                if !resolution.hops.isEmpty { self.resolvedJumpChain = resolution.hops }
                self.didResolveJumpServer = true
            }
        }
    }
    
    public func connect() async throws {
        guard !Task.isCancelled else { throw CancellationError() }
        let attemptId = UUID()

        // Clean up any existing connection resources to prevent fd or process leaks on reconnect
        let needsCleanup = stateLock.withLock {
            ptyMasterFd != -1 || readSource != nil || childPid > 0 || connectionLogFd != -1 || handshakeState != nil || activeAttemptId != nil
        }
        if needsCleanup {
            await disconnect()
        }
        guard !Task.isCancelled else { throw CancellationError() }
        
        // A peer disconnect may leave the previous probe finishing cancellation.
        let (previousKeepAlive, previousProbe) = stateLock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?) in
            let ka = keepAliveTask
            keepAliveTask = nil
            let pr = probeTask
            probeTask = nil
            return (ka, pr)
        }
        previousKeepAlive?.cancel()
        previousProbe?.cancel()
        await previousProbe?.value

        prevCpu = nil
        prevNet = nil
        let initialStep = SSHConnectionState.connecting(step: "正在准备连接 \(session.host):\(session.port)...")
        let initialHandler = stateLock.withLock { () -> (@Sendable (SSHConnectionState) -> Void)? in
            activeAttemptId = attemptId
            isActiveAttemptEstablished = false
            isPTYClosed = false
            explicitDisconnectRequested = false
            passwordFeedSent = false
            recentInputLineBuffer = ""
            lastUserExitCommandAt = .distantPast
            lastPTYActivityTime = ProcessInfo.processInfo.systemUptime
            directoryStream = DirectoryChangeStreamParser()
            recentPromptBuffer = ""
            lastReportedDirectory = ""
            hasPendingCommandExecution = false
            guard storedConnectionState != initialStep else { return nil }
            storedConnectionState = initialStep
            return stateChangeHandler
        }
        initialHandler?(initialStep)
        
        await resolvePasswordIfNeeded()
        if Task.isCancelled || stateLock.withLock({ self.activeAttemptId != attemptId || self.explicitDisconnectRequested }) {
            transitionConnectionState(for: attemptId, to: .disconnected)
            throw CancellationError()
        }
        let keyAccess: FileAccessLease?
        do { keyAccess = try acquirePrivateKeyAccess() }
        catch {
            transitionConnectionState(for: attemptId, to: .failed(error.localizedDescription))
            throw error
        }
        var transferredKeyAccess = false
        defer { if !transferredKeyAccess { keyAccess?.close() } }

        let certAccess: FileAccessLease?
        do { certAccess = try acquireCertificateAccess() }
        catch {
            transitionConnectionState(for: attemptId, to: .failed(error.localizedDescription))
            throw error
        }
        var transferredCertAccess = false
        defer { if !transferredCertAccess { certAccess?.close() } }

        try? FileManager.default.createDirectory(at: connectionLogDirectory, withIntermediateDirectories: true)
        let logPath = connectionLogDirectory
            .appendingPathComponent("apx-conn-\(UUID().uuidString).log")
            .path
        let logFd = open(logPath, O_RDONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard logFd >= 0 else {
            let err = NSError(domain: "ApexSSH", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "无法创建连接状态通道"])
            transitionConnectionState(for: attemptId, to: .failed(err.localizedDescription))
            throw err
        }
        var transferredLogFd = false
        defer {
            if !transferredLogFd {
                close(logFd)
                unlink(logPath)
            }
        }

        // Setup command & arguments
        let timeoutSec = max(2, connectTimeoutSeconds)
        var binaryPath = "/usr/bin/ssh"
        var sshArgs = ["-tt"] + Self.sshKeepAliveArguments(configuredInterval: session.keepAliveIntervalSeconds) + [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=\(timeoutSec)",
            "-o", "LogLevel=DEBUG1",
            "-E", logPath
        ]
        sshArgs.append(contentsOf: sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url))
        sshArgs.append(contentsOf: advancedConnectionArgs(channel: .interactiveSSH))
        sshArgs.append(contentsOf: [
            "-p", "\(session.port)",
            "\(session.username)@\(sshDestinationHost)"
        ])
        
        let usesSSHPAss = (currentResolvedPassword?.isEmpty == false) && (sshpassExecutablePath != nil)
        if let pw = currentResolvedPassword, !pw.isEmpty, let sshpass = sshpassExecutablePath {
            binaryPath = sshpass
            sshArgs = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + sshArgs
        }
        
        let storeCommand: PreparedStoreCommand?
        do { storeCommand = try prepareStoreCommand(binaryPath: binaryPath, arguments: sshArgs, accesses: [keyAccess, certAccess]) }
        catch {
            transitionConnectionState(for: attemptId, to: .failed(error.localizedDescription))
            throw error
        }
        defer { if !transferredKeyAccess { storeCommand?.grants.close() } }
        if let command = storeCommand { binaryPath = command.binaryPath; sshArgs = command.arguments }
        let usesExternalAuthHelper = usesSSHPAss || (storeCommand?.hasAuthentication ?? false)

        var master: Int32 = 0
        var slave: Int32 = 0
        let dims = stateLock.withLock { currentDimensions }
        var win = winsize(
            ws_row: UInt16(dims.rows),
            ws_col: UInt16(dims.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&master, &slave, nil, nil, &win) == 0 else {
            transitionConnectionState(for: attemptId, to: .failed("Failed to allocate Darwin PTY"))
            throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }

        let masterFlags = fcntl(master, F_GETFL, 0)
        if masterFlags >= 0 {
            _ = fcntl(master, F_SETFL, masterFlags | O_NONBLOCK)
        }

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
            let err = NSError(domain: "ApexSSH", code: Int(spawnResult), userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed with error: \(spawnResult)"])
            transitionConnectionState(for: attemptId, to: .failed("posix_spawn failed with error: \(spawnResult)"))
            close(master)
            throw err
        }

        let tracker = HandshakeTracker(id: attemptId)
        let connectingState = SSHConnectionState.connecting(step: "正在连接 \(session.host):\(session.port)...")
        let activation: (activated: Bool, stateHandler: (@Sendable (SSHConnectionState) -> Void)?) = stateLock.withLock {
            guard self.activeAttemptId == attemptId, !self.explicitDisconnectRequested, !Task.isCancelled else {
                return (false, nil)
            }

            let logSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: logFd,
                eventMask: [.write, .extend, .attrib],
                queue: DispatchQueue.global(qos: .userInteractive)
            )
            let processSource = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: DispatchQueue.global(qos: .userInteractive)
            )
            let source = DispatchSource.makeReadSource(
                fileDescriptor: master,
                queue: DispatchQueue.global(qos: .userInteractive)
            )

            logSource.setEventHandler { [weak self] in
                self?.consumeConnectionLog(attemptId: attemptId)
            }
            logSource.setCancelHandler { [weak self] in
                if let self {
                    self.stateLock.withLock {
                        if self.connectionLogFd == logFd {
                            self.connectionLogFd = -1
                        }
                        if self.connectionLogPath == logPath {
                            self.connectionLogPath = nil
                        }
                    }
                }
                close(logFd)
                unlink(logPath)
            }

            processSource.setEventHandler { [weak self] in
                self?.resolvePendingHandshakeFromTermination(attemptId: attemptId, processExited: true)
            }

            // Setup asynchronous kqueue read source
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                var buffer = [UInt8](repeating: 0, count: 8192)
                let bytesRead = read(master, &buffer, buffer.count)
                if bytesRead > 0 {
                    self.recordPTYActivity()
                    let data = Data(buffer.prefix(bytesRead))
                    let outHandler = self.stateLock.withLock { self.outputHandler }
                    outHandler?(data)
                    self.parseOSC7DirectoryChange(data: data)

                    let promptAction: (kind: PTYPromptKind, secret: String?) = self.stateLock.withLock {
                        guard self.activeAttemptId == attemptId,
                              !self.isActiveAttemptEstablished,
                              let currentTracker = self.handshakeState,
                              currentTracker.id == attemptId else {
                            return (.none, nil)
                        }
                        let decoded = currentTracker.ptyPromptDecoder.decode(data)
                        guard !decoded.isEmpty else { return (.none, nil) }
                        currentTracker.ptyPromptTail.append(decoded)
                        if currentTracker.ptyPromptTail.count > 1024 {
                            currentTracker.ptyPromptTail = String(currentTracker.ptyPromptTail.suffix(512))
                        }
                        let kind = Self.classifyPTYPrompt(currentTracker.ptyPromptTail)
                        guard kind != .none else { return (.none, nil) }
                        currentTracker.ptyPromptTail = ""
                        if (kind == .password || kind == .passphrase),
                           !usesExternalAuthHelper,
                           !self.passwordFeedSent,
                           let pw = self.resolvedPassword, !pw.isEmpty {
                            self.passwordFeedSent = true
                            return (kind, pw)
                        }
                        return (kind, nil)
                    }

                    if let pw = promptAction.secret,
                       let d = (pw + "\n").data(using: .utf8) {
                        Self.writePTYInput(d, to: master)
                    } else if promptAction.kind == .twoFactor {
                        self.transitionConnectionState(
                            for: attemptId,
                            to: .connecting(step: "等待动态口令 / 2FA 验证码输入..."),
                            requirePending: true
                        )
                    } else if promptAction.kind == .hostConfirm ||
                                (!usesExternalAuthHelper && (promptAction.kind == .password || promptAction.kind == .passphrase)) {
                        self.transitionConnectionState(
                            for: attemptId,
                            to: .connecting(step: "等待终端交互输入确认..."),
                            requirePending: true
                        )
                    }
                } else {
                    let err = errno
                    if Self.shouldKeepReadingAfterReadResult(bytesRead: bytesRead, errnoValue: err) {
                        return
                    }
                    struct EOFAction {
                        var isCurrent: Bool
                        var wasEstablished: Bool
                        var keepAlive: Task<Void, Never>?
                        var probe: Task<Void, Never>?
                        var keyAccess: FileAccessLease?
                        var certAccess: FileAccessLease?
                        var grants: ChildProcessFileGrants?
                        var pidToReap: pid_t = -1
                        var stateHandler: (@Sendable (SSHConnectionState) -> Void)?
                    }
                    let action: EOFAction = self.stateLock.withLock {
                        guard self.activeAttemptId == attemptId else {
                            return EOFAction(isCurrent: false, wasEstablished: false)
                        }
                        self.isPTYClosed = true
                        if self.isActiveAttemptEstablished {
                            let ka = self.keepAliveTask
                            self.keepAliveTask = nil
                            let pr = self.probeTask
                            self.probeTask = nil
                            let kAccess = self.connectionKeyAccess
                            let cAccess = self.connectionCertAccess
                            let gReq = self.connectionGrantRequest
                            self.connectionKeyAccess = nil
                            self.connectionCertAccess = nil
                            self.connectionGrantRequest = nil
                            let exitedPid = self.childPid
                            self.childPid = -1
                            self.readSource = nil
                            var sHandler: (@Sendable (SSHConnectionState) -> Void)?
                            if self.storedConnectionState != .disconnected {
                                self.storedConnectionState = .disconnected
                                sHandler = self.stateChangeHandler
                            }
                            return EOFAction(
                                isCurrent: true,
                                wasEstablished: true,
                                keepAlive: ka,
                                probe: pr,
                                keyAccess: kAccess,
                                certAccess: cAccess,
                                grants: gReq,
                                pidToReap: exitedPid,
                                stateHandler: sHandler
                            )
                        } else {
                            if let currentTracker = self.handshakeState,
                               currentTracker.id == attemptId,
                               !currentTracker.isResolved,
                               !currentTracker.isResolvingTermination,
                               currentTracker.ptyCloseFallbackTimer == nil {
                                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
                                timer.schedule(deadline: .now() + .milliseconds(500))
                                timer.setEventHandler { [weak self] in
                                    self?.resolvePendingHandshakeFromTermination(attemptId: attemptId, processExited: false)
                                }
                                currentTracker.ptyCloseFallbackTimer = timer
                                timer.resume()
                            }
                            return EOFAction(isCurrent: true, wasEstablished: false)
                        }
                    }
                    if !action.isCurrent {
                        source.cancel()
                        return
                    }
                    if action.wasEstablished {
                        action.keepAlive?.cancel()
                        action.probe?.cancel()
                        self.endSessionActivityAssertion()
                        action.grants?.close()
                        action.keyAccess?.close()
                        action.certAccess?.close()
                        if action.pidToReap > 0 {
                            let pidToReap = action.pidToReap
                            var status: Int32 = 0
                            if waitpid(pidToReap, &status, WNOHANG) == 0 {
                                DispatchQueue.global(qos: .utility).async {
                                    Self.killProcessTreeAndReap(pidToReap, maxWaitIterations: 15)
                                }
                            }
                        }
                        action.stateHandler?(.disconnected)
                    }
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

            self.ptyMasterFd = master
            self.childPid = pid
            self.connectionKeyAccess = keyAccess
            self.connectionCertAccess = certAccess
            self.connectionGrantRequest = storeCommand?.grants
            self.isActiveAttemptEstablished = false
            self.isPTYClosed = false
            self.handshakeState = tracker
            self.connectionLogFd = logFd
            self.connectionLogPath = logPath
            self.logReadSource = logSource
            self.handshakeProcessSource = processSource
            self.readSource = source
            logSource.resume()
            processSource.resume()
            source.resume()

            var handler: (@Sendable (SSHConnectionState) -> Void)?
            if self.storedConnectionState != connectingState {
                self.storedConnectionState = connectingState
                handler = self.stateChangeHandler
            }
            return (true, handler)
        }

        guard activation.activated else {
            Self.killProcessTreeAndReap(pid, maxWaitIterations: 15)
            close(master)
            transitionConnectionState(for: attemptId, to: .disconnected)
            throw CancellationError()
        }

        transferredKeyAccess = true
        transferredCertAccess = true
        transferredLogFd = true
        beginSessionActivityAssertion()
        activation.stateHandler?(connectingState)
        consumeConnectionLog(attemptId: attemptId)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediateResult: Result<Void, Error>? = stateLock.withLock {
                    guard self.activeAttemptId == attemptId,
                          let currentTracker = self.handshakeState,
                          currentTracker.id == attemptId else {
                        return .failure(CancellationError())
                    }
                    if currentTracker.isResolved {
                        let result = currentTracker.terminalResult ?? .failure(CancellationError())
                        self.handshakeState = nil
                        return result
                    }
                    currentTracker.continuation = continuation
                    return nil
                }
                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
            }
        } onCancel: {
            self.cancelAttempt(attemptId: attemptId, markExplicitDisconnect: true)
        }

        guard stateLock.withLock({ self.activeAttemptId == attemptId && self.isActiveAttemptEstablished && self.storedConnectionState == .connected }) else {
            return
        }

        startChannelKeepAliveLoop()
        
        // Probe user's real home directory after connection
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.connectionState == .connected else { return }
            if let home = await self.probeRemoteHome(), !home.isEmpty, self.connectionState == .connected {
                let dirHandler: (@Sendable (String) -> Void)? = self.stateLock.withLock {
                    self.remoteHomeDirectory = home
                    return self.directoryChangeHandler
                }
                dirHandler?(home)
            }
        }
        
        // Start agentless metrics probe if enabled
        if session.agentlessMonitorEnabled {
            startAgentlessProbeLoop()
        }
    }

    private func consumeConnectionLog(attemptId: UUID, flushRemainder: Bool = false) {
        var pendingSteps: [String] = []
        var pendingDiagnostics: [String] = []
        var didEstablish = false
        var continuationToResume: CheckedContinuation<Void, Error>?
        var logSourceToCancel: DispatchSourceFileSystemObject?
        var processSourceToCancel: DispatchSourceProcess?
        var fallbackTimerToCancel: DispatchSourceTimer?
        var pathToUnlink: String?
        var outHandler: (@Sendable (Data) -> Void)?
        var stateTransition: (state: SSHConnectionState, handler: (@Sendable (SSHConnectionState) -> Void)?)?
        var shouldEndAssertion = false

        stateLock.withLock {
            guard self.activeAttemptId == attemptId,
                  let tracker = self.handshakeState,
                  tracker.id == attemptId,
                  !tracker.isResolved,
                  self.connectionLogFd >= 0 else {
                return
            }

            outHandler = self.outputHandler
            let fd = self.connectionLogFd
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let bytesRead = read(fd, &buffer, buffer.count)
                if bytesRead > 0 {
                    collected.append(contentsOf: buffer.prefix(bytesRead))
                } else if bytesRead < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }

            if !collected.isEmpty {
                tracker.remainderBytes.append(collected)
            }

            var lines: [String] = []
            while let newlineIndex = tracker.remainderBytes.firstIndex(of: UInt8(ascii: "\n")) {
                var lineSlice = tracker.remainderBytes[tracker.remainderBytes.startIndex..<newlineIndex]
                if lineSlice.last == UInt8(ascii: "\r") {
                    lineSlice = lineSlice.dropLast()
                }
                lines.append(String(decoding: lineSlice, as: UTF8.self))
                tracker.remainderBytes.removeSubrange(tracker.remainderBytes.startIndex...newlineIndex)
            }
            if flushRemainder && !tracker.remainderBytes.isEmpty {
                var lineSlice = tracker.remainderBytes[...]
                if lineSlice.last == UInt8(ascii: "\r") {
                    lineSlice = lineSlice.dropLast()
                }
                lines.append(String(decoding: lineSlice, as: UTF8.self))
                tracker.remainderBytes.removeAll(keepingCapacity: false)
            }

            for rawLine in lines {
                switch Self.classifyConnectionLogLine(rawLine, host: session.host, port: session.port) {
                case .step(let stepText):
                    pendingSteps.append(stepText)
                case .diagnostic(let diag):
                    if !diag.hasPrefix("Warning: Permanently added ") {
                        tracker.diagnosticLines.append(diag)
                    }
                    pendingDiagnostics.append(diag)
                case .established:
                    tracker.isEstablished = true
                    tracker.isResolved = true
                    tracker.terminalResult = .success(())
                    fallbackTimerToCancel = tracker.ptyCloseFallbackTimer
                    tracker.ptyCloseFallbackTimer = nil
                    self.isActiveAttemptEstablished = true
                    continuationToResume = tracker.continuation
                    tracker.continuation = nil
                    if continuationToResume != nil {
                        self.handshakeState = nil
                    }
                    logSourceToCancel = self.logReadSource
                    processSourceToCancel = self.handshakeProcessSource
                    pathToUnlink = self.connectionLogPath
                    self.logReadSource = nil
                    self.handshakeProcessSource = nil
                    self.connectionLogPath = nil
                    didEstablish = true
                    let targetState: SSHConnectionState = self.isPTYClosed ? .disconnected : .connected
                    shouldEndAssertion = self.isPTYClosed
                    if self.storedConnectionState != targetState {
                        self.storedConnectionState = targetState
                        stateTransition = (targetState, self.stateChangeHandler)
                    }
                case .ignore:
                    break
                }
                if didEstablish { break }
            }

            if !didEstablish, let lastStep = pendingSteps.last {
                let nextState = SSHConnectionState.connecting(step: lastStep)
                if self.storedConnectionState != nextState {
                    self.storedConnectionState = nextState
                    stateTransition = (nextState, self.stateChangeHandler)
                }
            }
        }

        for diag in pendingDiagnostics {
            outHandler?(Data((diag + "\r\n").utf8))
        }

        if didEstablish {
            fallbackTimerToCancel?.cancel()
            if let pathToUnlink {
                unlink(pathToUnlink)
            }
            logSourceToCancel?.cancel()
            processSourceToCancel?.cancel()
            if shouldEndAssertion {
                self.endSessionActivityAssertion()
            }
            if let transition = stateTransition {
                transition.handler?(transition.state)
            }
            continuationToResume?.resume()
        } else if let transition = stateTransition {
            transition.handler?(transition.state)
        }
    }

    private func resolvePendingHandshakeFromTermination(attemptId: UUID, processExited: Bool) {
        let initial: (pid: pid_t, fallbackTimer: DispatchSourceTimer?)? = stateLock.withLock {
            guard self.activeAttemptId == attemptId,
                  let tracker = self.handshakeState,
                  tracker.id == attemptId,
                  !tracker.isResolved,
                  !tracker.isResolvingTermination else {
                return nil
            }
            tracker.isResolvingTermination = true
            let timer = tracker.ptyCloseFallbackTimer
            tracker.ptyCloseFallbackTimer = nil
            return (self.childPid, timer)
        }
        guard let initial else { return }
        initial.fallbackTimer?.cancel()
        let pid = initial.pid

        consumeConnectionLog(attemptId: attemptId, flushRemainder: false)
        if stateLock.withLock({ self.activeAttemptId != attemptId || (self.handshakeState?.isResolved ?? true) }) {
            return
        }

        var reaped = false
        var exitCode: Int32 = 255
        if pid > 0 {
            if processExited {
                let result = Self.reapExitedProcess(pid)
                reaped = result.reaped
                exitCode = result.exitCode
            } else {
                var rawStatus: Int32 = 0
                let waited = waitpid(pid, &rawStatus, WNOHANG)
                if waited == pid {
                    reaped = true
                    exitCode = ((rawStatus & 0x7f) == 0) ? ((rawStatus >> 8) & 0xff) : 255
                } else {
                    Self.killProcessTreeAndReap(pid, maxWaitIterations: 15)
                    reaped = true
                    exitCode = 255
                }
            }
            if reaped {
                stateLock.withLock {
                    if self.childPid == pid {
                        self.childPid = -1
                    }
                }
            }
        }

        consumeConnectionLog(attemptId: attemptId, flushRemainder: true)

        struct TerminationCleanup {
            var continuation: CheckedContinuation<Void, Error>?
            var logSource: DispatchSourceFileSystemObject?
            var processSource: DispatchSourceProcess?
            var readSource: DispatchSourceRead?
            var masterFd: Int32 = -1
            var logPath: String?
            var keyAccess: FileAccessLease?
            var certAccess: FileAccessLease?
            var grants: ChildProcessFileGrants?
            var stateTransition: (state: SSHConnectionState, handler: (@Sendable (SSHConnectionState) -> Void)?)?
            var error: Error
        }

        let cleanup: TerminationCleanup? = stateLock.withLock {
            guard self.activeAttemptId == attemptId,
                  let tracker = self.handshakeState,
                  tracker.id == attemptId,
                  !tracker.isResolved else {
                return nil
            }

            let lSource = self.logReadSource
            let pSource = self.handshakeProcessSource
            let rSource = self.readSource
            let master = self.ptyMasterFd
            let lPath = self.connectionLogPath
            let kAccess = self.connectionKeyAccess
            let cAccess = self.connectionCertAccess
            let gReq = self.connectionGrantRequest

            self.logReadSource = nil
            self.handshakeProcessSource = nil
            self.readSource = nil
            self.ptyMasterFd = -1
            self.connectionLogPath = nil
            self.connectionKeyAccess = nil
            self.connectionCertAccess = nil
            self.connectionGrantRequest = nil

            tracker.isResolved = true
            let cont = tracker.continuation
            tracker.continuation = nil

            if self.explicitDisconnectRequested {
                let cancelErr = CancellationError()
                tracker.terminalResult = .failure(cancelErr)
                if cont != nil { self.handshakeState = nil }
                var transition: (SSHConnectionState, (@Sendable (SSHConnectionState) -> Void)?)?
                if self.storedConnectionState != .disconnected {
                    self.storedConnectionState = .disconnected
                    transition = (.disconnected, self.stateChangeHandler)
                }
                return TerminationCleanup(
                    continuation: cont,
                    logSource: lSource,
                    processSource: pSource,
                    readSource: rSource,
                    masterFd: master,
                    logPath: lPath,
                    keyAccess: kAccess,
                    certAccess: cAccess,
                    grants: gReq,
                    stateTransition: transition,
                    error: cancelErr
                )
            }

            let diagnostics = tracker.diagnosticLines.joined(separator: "\n")
            let diagnostic: String
            if exitCode == 5 && usesKeyPassphrase && !diagnostics.lowercased().contains("password") {
                diagnostic = "私钥口令 (Passphrase) 错误"
            } else {
                diagnostic = Self.parseSSHErrorMessage(exitCode: exitCode, stderr: diagnostics)
            }
            let err = NSError(domain: "ApexSSH", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: diagnostic])
            tracker.terminalResult = .failure(err)
            if cont != nil { self.handshakeState = nil }
            let failedState = SSHConnectionState.failed(diagnostic)
            var transition: (SSHConnectionState, (@Sendable (SSHConnectionState) -> Void)?)?
            if self.storedConnectionState != failedState {
                self.storedConnectionState = failedState
                transition = (failedState, self.stateChangeHandler)
            }
            return TerminationCleanup(
                continuation: cont,
                logSource: lSource,
                processSource: pSource,
                readSource: rSource,
                masterFd: master,
                logPath: lPath,
                keyAccess: kAccess,
                certAccess: cAccess,
                grants: gReq,
                stateTransition: transition,
                error: err
            )
        }

        guard let cleanup else { return }
        if let lPath = cleanup.logPath { unlink(lPath) }
        cleanup.logSource?.cancel()
        cleanup.processSource?.cancel()
        cleanup.readSource?.cancel()
        if cleanup.readSource == nil, cleanup.masterFd >= 0 { close(cleanup.masterFd) }
        endSessionActivityAssertion()
        cleanup.grants?.close()
        cleanup.keyAccess?.close()
        cleanup.certAccess?.close()
        if let transition = cleanup.stateTransition {
            transition.handler?(transition.state)
        }
        cleanup.continuation?.resume(throwing: cleanup.error)
    }

    /// Synchronously cancels a specific connection attempt without disturbing any newer attempt.
    private func cancelAttempt(attemptId: UUID, markExplicitDisconnect: Bool) {
        struct CancelBundle {
            var continuation: CheckedContinuation<Void, Error>?
            var logSource: DispatchSourceFileSystemObject?
            var processSource: DispatchSourceProcess?
            var readSource: DispatchSourceRead?
            var fallbackTimer: DispatchSourceTimer?
            var masterFd: Int32 = -1
            var pid: pid_t = -1
            var logPath: String?
            var keyAccess: FileAccessLease?
            var certAccess: FileAccessLease?
            var grants: ChildProcessFileGrants?
            var stateHandler: (@Sendable (SSHConnectionState) -> Void)?
        }

        let bundle: CancelBundle? = stateLock.withLock {
            guard self.activeAttemptId == attemptId else { return nil }
            if markExplicitDisconnect {
                self.explicitDisconnectRequested = true
            }
            let tracker = self.handshakeState
            self.handshakeState = nil
            self.activeAttemptId = nil
            self.isActiveAttemptEstablished = false

            let lSource = self.logReadSource
            let pSource = self.handshakeProcessSource
            let rSource = self.readSource
            let master = self.ptyMasterFd
            let pid = self.childPid
            let lPath = self.connectionLogPath
            let kAccess = self.connectionKeyAccess
            let cAccess = self.connectionCertAccess
            let gReq = self.connectionGrantRequest

            self.logReadSource = nil
            self.handshakeProcessSource = nil
            self.readSource = nil
            self.ptyMasterFd = -1
            self.childPid = -1
            self.connectionLogPath = nil
            self.connectionKeyAccess = nil
            self.connectionCertAccess = nil
            self.connectionGrantRequest = nil

            var cont: CheckedContinuation<Void, Error>?
            var timer: DispatchSourceTimer?
            if let tracker {
                timer = tracker.ptyCloseFallbackTimer
                tracker.ptyCloseFallbackTimer = nil
                if !tracker.isResolved {
                    tracker.isResolved = true
                    tracker.terminalResult = .failure(CancellationError())
                    cont = tracker.continuation
                    tracker.continuation = nil
                }
            }

            var sHandler: (@Sendable (SSHConnectionState) -> Void)?
            if self.storedConnectionState != .disconnected {
                self.storedConnectionState = .disconnected
                sHandler = self.stateChangeHandler
            }

            return CancelBundle(
                continuation: cont,
                logSource: lSource,
                processSource: pSource,
                readSource: rSource,
                fallbackTimer: timer,
                masterFd: master,
                pid: pid,
                logPath: lPath,
                keyAccess: kAccess,
                certAccess: cAccess,
                grants: gReq,
                stateHandler: sHandler
            )
        }

        guard let bundle else { return }
        bundle.fallbackTimer?.cancel()
        if let path = bundle.logPath {
            unlink(path)
        }
        bundle.logSource?.cancel()
        bundle.processSource?.cancel()
        bundle.readSource?.cancel()
        if bundle.readSource == nil, bundle.masterFd >= 0 {
            close(bundle.masterFd)
        }
        endSessionActivityAssertion()
        bundle.grants?.close()
        bundle.keyAccess?.close()
        bundle.certAccess?.close()
        if bundle.pid > 0 {
            Self.killProcessTreeAndReap(bundle.pid, maxWaitIterations: 25)
        }
        bundle.stateHandler?(.disconnected)
        bundle.continuation?.resume(throwing: CancellationError())
    }

    private func cancelPendingHandshakeOnDisconnect() {
        let pending: (CheckedContinuation<Void, Error>?, DispatchSourceFileSystemObject?, DispatchSourceProcess?, DispatchSourceTimer?, String?) = stateLock.withLock {
            let tracker = self.handshakeState
            self.handshakeState = nil
            self.activeAttemptId = nil
            self.isActiveAttemptEstablished = false
            let lSource = self.logReadSource
            let pSource = self.handshakeProcessSource
            let lPath = self.connectionLogPath
            self.logReadSource = nil
            self.handshakeProcessSource = nil
            self.connectionLogPath = nil

            var cont: CheckedContinuation<Void, Error>?
            var timer: DispatchSourceTimer?
            if let tracker {
                timer = tracker.ptyCloseFallbackTimer
                tracker.ptyCloseFallbackTimer = nil
                if !tracker.isResolved {
                    tracker.isResolved = true
                    tracker.terminalResult = .failure(CancellationError())
                    cont = tracker.continuation
                    tracker.continuation = nil
                }
            }
            return (cont, lSource, pSource, timer, lPath)
        }

        pending.3?.cancel()
        if let path = pending.4 {
            unlink(path)
        }
        pending.1?.cancel()
        pending.2?.cancel()
        pending.0?.resume(throwing: CancellationError())
    }

    private static func reapExitedProcess(_ pid: pid_t) -> (reaped: Bool, exitCode: Int32) {
        var rawStatus: Int32 = 0
        for _ in 0..<5 {
            let waited = waitpid(pid, &rawStatus, WNOHANG)
            if waited == pid {
                let code: Int32 = ((rawStatus & 0x7f) == 0) ? ((rawStatus >> 8) & 0xff) : 255
                return (true, code)
            }
            if waited < 0 {
                return (false, 255)
            }
            sched_yield()
        }
        let waited = waitpid(pid, &rawStatus, 0)
        if waited == pid {
            let code: Int32 = ((rawStatus & 0x7f) == 0) ? ((rawStatus >> 8) & 0xff) : 255
            return (true, code)
        }
        return (false, 255)
    }

    private static func killProcessTreeAndReap(_ pid: pid_t, maxWaitIterations: Int = 25) {
        guard pid > 0 else { return }
        // sshpass can place its SSH child in a separate session; include descendants
        // before terminating the helper, otherwise its child can be reparented to launchd.
        let descendants = ptyDescendants(of: pid)
        for child in descendants.reversed() { kill(child, SIGKILL) }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        var status: Int32 = 0
        for _ in 0..<maxWaitIterations {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited != 0 { break }
            usleep(2_000)
        }
    }
    
    public func disconnect() async {
        stateLock.withLock { explicitDisconnectRequested = true }
        cancelPendingHandshakeOnDisconnect()
        self.connectionState = .disconnected
        endSessionActivityAssertion()
        let (pendingKeepAlive, pendingProbe) = stateLock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?) in
            let ka = keepAliveTask
            keepAliveTask = nil
            let pr = probeTask
            probeTask = nil
            return (ka, pr)
        }
        pendingKeepAlive?.cancel()
        pendingProbe?.cancel()
        await pendingProbe?.value
        let (source, master) = stateLock.withLock { () -> (DispatchSourceRead?, Int32) in
            let s = readSource
            readSource = nil
            let descriptor = ptyMasterFd
            ptyMasterFd = -1
            return (s, descriptor)
        }
        source?.cancel()
        await cleanupControlSocketAsync()
        terminatePTYProcess()
        // Once a read source owns the descriptor, only its cancel handler closes it.
        // Closing twice can close an unrelated descriptor reused by another connection.
        if source == nil, master >= 0 { close(master) }
    }

    private static func performControlSocketExit(
        socket: String,
        controlOpt: String,
        destination: String,
        port: Int,
        distributionChannel: DistributionChannel,
        bridgeExecutableURL: URL,
        sandboxPaths: SandboxSSHPaths
    ) {
        guard controlOpt != "ControlPath=none",
              FileManager.default.fileExists(atPath: socket) else {
            return
        }
        let proc = Process()
        let args = ["-O", "exit", "-o", controlOpt, "-p", "\(port)", destination]
        var grants: ChildProcessFileGrants?
        if distributionChannel == .appStore,
           FileManager.default.isExecutableFile(atPath: bridgeExecutableURL.path) {
            do {
                try sandboxPaths.prepare()
                let preparedArgs = try sandboxPaths.arguments(prependingTo: args, tool: "ssh")
                let createdGrants = try ChildProcessFileGrants(files: [], authentication: nil)
                grants = createdGrants
                proc.executableURL = bridgeExecutableURL
                proc.arguments = ["--tool", "ssh"] + preparedArgs
                var env = ProcessInfo.processInfo.environment
                env[ChildProcessFileGrants.environmentKey] = createdGrants.fileURL.path
                proc.environment = env
            } catch {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = args
            }
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = args
        }
        defer { grants?.close() }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        if (try? proc.run()) != nil {
            for _ in 0..<30 where proc.isRunning {
                usleep(10_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                proc.waitUntilExit()
            }
        }
        try? FileManager.default.removeItem(atPath: socket)
    }

    private func cleanupControlSocketAsync() async {
        guard !disableControlPersist else { return }
        let socket = controlSocketPath
        let controlOpt = controlSocketOption
        guard controlOpt != "ControlPath=none",
              FileManager.default.fileExists(atPath: socket) else {
            return
        }
        let destination = "\(session.username)@\(sshDestinationHost)"
        let port = session.port
        let channel = distributionChannel
        let bridgeURL = bridgeExecutableURL
        let paths = sandboxPaths
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                Self.performControlSocketExit(
                    socket: socket,
                    controlOpt: controlOpt,
                    destination: destination,
                    port: port,
                    distributionChannel: channel,
                    bridgeExecutableURL: bridgeURL,
                    sandboxPaths: paths
                )
                continuation.resume()
            }
        }
    }
    
    /// Synchronous exit cleanup: SSH ignores ordinary termination signals while attached to a PTY.
    /// Each spawned connection owns a process group, so this cannot target another session.
    public func terminatePTYProcess() {
        stateLock.withLock { explicitDisconnectRequested = true }
        cancelPendingHandshakeOnDisconnect()
        endSessionActivityAssertion()
        let (ka, pr, source, master, keyAccess, certAccess, grants, pid) = stateLock.withLock {
            () -> (Task<Void, Never>?, Task<Void, Never>?, DispatchSourceRead?, Int32, FileAccessLease?, FileAccessLease?, ChildProcessFileGrants?, pid_t) in
            let ka = keepAliveTask; keepAliveTask = nil
            let pr = probeTask; probeTask = nil
            let s = readSource; readSource = nil
            let descriptor = ptyMasterFd; ptyMasterFd = -1
            let kAccess = connectionKeyAccess; connectionKeyAccess = nil
            let cAccess = connectionCertAccess; connectionCertAccess = nil
            let gReq = connectionGrantRequest; connectionGrantRequest = nil
            let p = childPid; childPid = -1
            return (ka, pr, s, descriptor, kAccess, cAccess, gReq, p)
        }
        ka?.cancel()
        pr?.cancel()
        source?.cancel()
        if source == nil, master >= 0 { close(master) }
        if !disableControlPersist {
            let socket = controlSocketPath
            let controlOpt = controlSocketOption
            if controlOpt != "ControlPath=none", FileManager.default.fileExists(atPath: socket) {
                let destination = "\(session.username)@\(sshDestinationHost)"
                let port = session.port
                let channel = distributionChannel
                let bridgeURL = bridgeExecutableURL
                let paths = sandboxPaths
                DispatchQueue.global(qos: .utility).async {
                    Self.performControlSocketExit(
                        socket: socket,
                        controlOpt: controlOpt,
                        destination: destination,
                        port: port,
                        distributionChannel: channel,
                        bridgeExecutableURL: bridgeURL,
                        sandboxPaths: paths
                    )
                }
            }
        }
        defer { grants?.close(); keyAccess?.close(); certAccess?.close() }
        guard pid > 0 else { return }
        Self.killProcessTreeAndReap(pid, maxWaitIterations: 25)
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
        let hasNewline = data.contains(13) || data.contains(10)
        let descriptor = stateLock.withLock { () -> Int32 in
            lastPTYActivityTime = ProcessInfo.processInfo.systemUptime
            if Self.recordExitIntent(data: data, lineBuffer: &recentInputLineBuffer) {
                lastUserExitCommandAt = Date()
            }
            if hasNewline {
                hasPendingCommandExecution = true
            }
            return ptyMasterFd >= 0 ? dup(ptyMasterFd) : -1
        }
        guard descriptor >= 0 else { return }
        // A duplicated descriptor prevents queued input from reaching a reused fd after reconnect.
        inputQueue.async {
            defer { close(descriptor) }
            Self.writePTYInput(data, to: descriptor)
        }
    }

    public static func writePTYInput(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            var eagainRetries = 0
            while offset < raw.count {
                let written = write(descriptor, base.advanced(by: offset), min(4096, raw.count - offset))
                if written > 0 {
                    offset += written
                    eagainRetries = 0
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && eagainRetries < 500 {
                    eagainRetries += 1
                    usleep(1_000)
                } else {
                    return
                }
            }
        }
    }

    public func sendInput(_ data: Data) async throws {
        sendInputSync(data)
    }
    
    public func resizeTerminal(columns: Int, rows: Int) async throws {
        let validCols = max(10, columns)
        let validRows = max(3, rows)
        let target: (fd: Int32, pid: pid_t) = stateLock.withLock {
            currentDimensions = (validCols, validRows)
            let dupFd = ptyMasterFd >= 0 ? dup(ptyMasterFd) : -1
            return (dupFd, childPid)
        }
        guard target.fd >= 0 else { return }
        defer { close(target.fd) }
        var win = winsize(ws_row: UInt16(validRows), ws_col: UInt16(validCols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(target.fd, TIOCSWINSZ, &win)
        if target.pid > 0 {
            kill(target.pid, SIGWINCH)
            kill(-target.pid, SIGWINCH)
            for child in Self.ptyDescendants(of: target.pid) {
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
        if disableControlPersist {
            return [
                "-o", "TCPKeepAlive=yes",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=6",
                "-o", "ControlMaster=no",
                "-o", "ControlPersist=no"
            ]
        }
        return [
            "-o", "TCPKeepAlive=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=6",
            "-o", "ControlMaster=auto",
            "-o", controlSocketOption,
            "-o", "ControlPersist=4h"
        ]
    }

    private func withControlSocketGate<T>(_ operation: () async throws -> T) async rethrows -> T {
        let needsGate = !disableControlPersist
            && controlSocketOption != "ControlPath=none"
            && !FileManager.default.fileExists(atPath: controlSocketPath)
        if needsGate { await controlSocketGate.acquire() }
        do {
            let value = try await operation()
            if needsGate { await controlSocketGate.release() }
            return value
        } catch {
            if needsGate { await controlSocketGate.release() }
            throw error
        }
    }

    public func probeRemoteHome() async -> String? {
        await resolvePasswordIfNeeded()
        return await withControlSocketGate {
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
            let jumpArgs = advancedConnectionArgs(channel: .nonInteractiveSSH)
            let pw = currentResolvedPassword
            let hasStoreAuth = distributionChannel == .appStore && !(pw?.isEmpty ?? true)
            if let pw = pw, !pw.isEmpty, let sshpass = sshpassExecutablePath {
                process.executableURL = URL(fileURLWithPath: sshpass)
                process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=5",
                ] + authArgs + jumpArgs + ctrlArgs + [
                    "-p", "\(session.port)",
                    "\(session.username)@\(sshDestinationHost)",
                    cmd
                ]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = (hasStoreAuth ? [] : ["-o", "BatchMode=yes"]) + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=5",
                ] + authArgs + jumpArgs + ctrlArgs + [
                    "-p", "\(session.port)",
                    "\(session.username)@\(sshDestinationHost)",
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
    }
    
    private func resolveAndDispatchDirectory(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // A valid directory path must start with '/' or '~'.
        // This strictly prevents metrics like '36' from 'Swap usage: 36%' being parsed as directories.
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return }
        
        let dispatch: (path: String, handler: (@Sendable (String) -> Void)?)? = stateLock.withLock {
            guard let home = remoteHomeDirectory else {
                if trimmed.hasPrefix("/") && trimmed != lastReportedDirectory {
                    lastReportedDirectory = trimmed
                    return (trimmed, directoryChangeHandler)
                }
                return nil
            }
            var path = trimmed
            if path == "~" {
                path = home
            } else if path.hasPrefix("~/") {
                let sub = String(path.dropFirst(2))
                path = home == "/" ? "/\(sub)" : "\(home)/\(sub)"
            }
            
            // Must resolve to a valid Unix absolute path
            guard path.hasPrefix("/"), !path.isEmpty else { return nil }
            
            if path != lastReportedDirectory {
                lastReportedDirectory = path
                hasPendingCommandExecution = false
                return (path, directoryChangeHandler)
            } else if hasPendingCommandExecution {
                hasPendingCommandExecution = false
                return (path, directoryChangeHandler)
            }
            return nil
        }
        if let dispatch {
            dispatch.handler?(dispatch.path)
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
        let parsed = stateLock.withLock { directoryStream.consume(data) }
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
        
        let promptSnapshot: String = stateLock.withLock {
            recentPromptBuffer.append(clean)
            if recentPromptBuffer.count > 2048 {
                recentPromptBuffer = String(recentPromptBuffer.suffix(1024))
            }
            return recentPromptBuffer
        }
        
        // Match prompt pattern like ubuntu@host:~/services$ or user@host /var/log % or root@host:/etc#
        if let raw = Self.directoryFromPrompt(promptSnapshot) {
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
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds) * 1_000_000_000)
                guard let self = self, !Task.isCancelled, self.connectionState == .connected else { break }
                guard Self.isEnhancedKeepAliveEnabled() else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                let shouldPulse: (fd: Int32, pid: pid_t, cols: Int, rows: Int, pixel: UInt16)? = self.stateLock.withLock {
                    guard self.ptyMasterFd >= 0, self.childPid > 0 else { return nil }
                    guard now - self.lastPTYActivityTime >= Double(intervalSeconds - 1) else { return nil }
                    let dupFd = dup(self.ptyMasterFd)
                    guard dupFd >= 0 else { return nil }
                    self.keepAlivePixelToggle = self.keepAlivePixelToggle == 0 ? 1 : 0
                    return (dupFd, self.childPid, self.currentDimensions.columns, self.currentDimensions.rows, self.keepAlivePixelToggle)
                }
                if let pulse = shouldPulse {
                    defer { close(pulse.fd) }
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
        stateLock.withLock { keepAliveTask = task }
    }

    private func runSingleAgentlessProbeCycle() async -> Bool {
        await withControlSocketGate {
            let process = Process()
            let sshpass = self.sshpassExecutablePath
            let ctrlArgs = self.controlMasterArguments

            let keyAccess: FileAccessLease?
            do { keyAccess = try self.acquirePrivateKeyAccess() }
            catch { return true }
            defer { keyAccess?.close() }

            let certAccess: FileAccessLease?
            do { certAccess = try self.acquireCertificateAccess() }
            catch { return true }
            defer { certAccess?.close() }

            let authArgs = self.sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url)
            let jumpArgs = self.advancedConnectionArgs(channel: .nonInteractiveSSH)
            let pw = self.currentResolvedPassword
            let hasStoreAuth = self.distributionChannel == .appStore && !(pw?.isEmpty ?? true)
            if let pw = pw, !pw.isEmpty, let passBin = sshpass {
                process.executableURL = URL(fileURLWithPath: passBin)
                process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=3",
                ] + authArgs + jumpArgs + ctrlArgs + [
                    "-p", "\(self.session.port)",
                    "\(self.session.username)@\(self.sshDestinationHost)",
                    AgentlessMonitor.autoProbeCommand
                ]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = (hasStoreAuth ? [] : ["-o", "BatchMode=yes"]) + [
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=3",
                ] + authArgs + jumpArgs + ctrlArgs + [
                    "-p", "\(self.session.port)",
                    "\(self.session.username)@\(self.sshDestinationHost)",
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
                        let mHandler = self.stateLock.withLock { self.metricsHandler }
                        mHandler?(snapshot)
                    }
                }
            } catch {
                // Silently wait for next interval
            }
            return false
        }
    }

    private func startAgentlessProbeLoop() {
        let task = Task.detached(priority: .background) { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            while !Task.isCancelled {
                guard let self = self, self.connectionState == .connected else { break }
                // Release controlSocketGate before sleeping so one-shot commands / SFTP are never blocked.
                let hadAccessError = await self.runSingleAgentlessProbeCycle()
                guard !Task.isCancelled else { break }
                if hadAccessError {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                let intervalNs: UInt64 = (self.distributionChannel == .appStore && !self.sandboxPaths.canUseControlSocket)
                    ? 8_000_000_000
                    : 1_500_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
        stateLock.withLock { probeTask = task }
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
    
    private func configureOneShotCommandProcess(
        _ process: Process,
        command: String,
        keyAccess: FileAccessLease?,
        certAccess: FileAccessLease?,
        connectTimeout: Int = 5
    ) {
        let sshpass = self.sshpassExecutablePath
        let ctrlArgs = controlMasterArguments
        let authArgs = self.sshAuthArgs(privateKeyURL: keyAccess?.url, certificateURL: certAccess?.url)
        let jumpArgs = self.advancedConnectionArgs(channel: .nonInteractiveSSH)
        let pw = self.currentResolvedPassword
        let hasStoreAuth = self.distributionChannel == .appStore && !(pw?.isEmpty ?? true)
        if let pw = pw, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=\(connectTimeout)",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(self.session.port)",
                "\(self.session.username)@\(self.sshDestinationHost)",
                command
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = (hasStoreAuth ? [] : ["-o", "BatchMode=yes"]) + [
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ConnectTimeout=\(connectTimeout)",
            ] + authArgs + jumpArgs + ctrlArgs + [
                "-p", "\(self.session.port)",
                "\(self.session.username)@\(self.sshDestinationHost)",
                command
            ]
        }
    }

    /// Executes a one-shot remote command over multiplexed SSH socket
    public func executeCommand(_ command: String) async throws -> String {
        await resolvePasswordIfNeeded()
        return try await withControlSocketGate {
            let process = Process()

            let keyAccess = try self.acquirePrivateKeyAccess()
            defer { keyAccess?.close() }
            let certAccess = try self.acquireCertificateAccess()
            defer { certAccess?.close() }
            configureOneShotCommandProcess(process, command: command, keyAccess: keyAccess, certAccess: certAccess)

            process.standardError = FileHandle.nullDevice
            let grants = try self.configureStoreProcess(process, accesses: [keyAccess, certAccess])
            defer { grants?.close() }
            let outData = try await Self.runProbeProcess(process)
            return String(data: outData, encoding: .utf8) ?? ""
        }
    }

    /// Executes a one-shot remote command and captures stdout, stderr, exit code, and duration in milliseconds.
    public func executeCommandWithResult(_ command: String) async throws -> SSHCommandResult {
        await resolvePasswordIfNeeded()
        return try await withControlSocketGate {
            let process = Process()

            let keyAccess = try self.acquirePrivateKeyAccess()
            defer { keyAccess?.close() }
            let certAccess = try self.acquireCertificateAccess()
            defer { certAccess?.close() }
            configureOneShotCommandProcess(process, command: command, keyAccess: keyAccess, certAccess: certAccess, connectTimeout: 10)

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outPipe
            process.standardError = errPipe

            let grants = try self.configureStoreProcess(process, accesses: [keyAccess, certAccess])
            defer { grants?.close() }

            let startNs = DispatchTime.now().uptimeNanoseconds
            let (outData, errData) = try await Self.runProcessWithOutput(process, outPipe: outPipe, errPipe: errPipe)
            let durationMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0
            return SSHCommandResult(
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self),
                exitCode: process.terminationStatus,
                durationMs: durationMs
            )
        }
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
        
        if let keyPath = self.session.privateKeyPath, !keyPath.isEmpty,
           distributionChannel != .appStore || KeychainStore.isVaultPrivateKeyReference(keyPath) {
            let expanded = Self.expandPath(keyPath)
            if !FileManager.default.fileExists(atPath: expanded) {
                return SSHTestConnectionResult(isSuccess: false, latencyMs: 0, errorMessage: "指定的私钥文件不存在: \(keyPath)")
            }
        }
        if let certPath = self.session.certificatePath, !certPath.isEmpty,
           distributionChannel != .appStore {
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
        let jumpArgs = self.advancedConnectionArgs(channel: .nonInteractiveSSH)
        
        let probeCommand = "uname -s -m 2>/dev/null || echo ok"
        let baseSSHArgs = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=\(timeoutSeconds)",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ControlMaster=no",
        ] + authArgs + jumpArgs + [
            "-p", "\(self.session.port)",
            "\(self.session.username)@\(self.sshDestinationHost)",
            probeCommand
        ]
        
        let pw = stateLock.withLock { self.resolvedPassword }
        let hasStoreAuth = self.distributionChannel == .appStore && !(pw?.isEmpty ?? true)
        if let pw = pw, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + baseSSHArgs
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = (hasStoreAuth ? [] : ["-o", "BatchMode=yes"]) + baseSSHArgs
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
        
        if cleanErr.contains("Two-factor verification code required") ||
           cleanErr.localizedCaseInsensitiveContains("verification code") ||
           cleanErr.localizedCaseInsensitiveContains("one-time password") {
            return "双因素认证 (2FA/TOTP) 需要动态验证码，请在终端交互中输入验证码"
        }
        if cleanErr.contains("Bad passphrase") || cleanErr.contains("passphrase") {
            return "私钥口令 (Passphrase) 错误"
        }
        if cleanErr.contains("No such file or directory") || cleanErr.contains("not accessible") {
            return "指定的私钥或证书文件不存在"
        }
        if cleanErr.contains("Host key verification failed") || cleanErr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return "主机密钥校验冲突 (Host key verification failed)：远端服务器公钥已变更。若确认变更安全，请在「设置 → 密钥保险库 → 主机指纹」中移除旧指纹后重试。"
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
        if cleanErr.localizedCaseInsensitiveContains("timed out") {
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

    static let defaultMaxOutputBytesPerStream = 512 * 1024

    static func readCappedStream(from handle: FileHandle, maxBytes: Int) -> Data {
        let cap = max(64, maxBytes)
        var collected = Data()
        var wasTruncated = false
        while let chunk = try? handle.read(upToCount: 32_768), !chunk.isEmpty {
            if collected.count < cap {
                let remaining = cap - collected.count
                if chunk.count <= remaining {
                    collected.append(chunk)
                } else {
                    collected.append(chunk.prefix(remaining))
                    wasTruncated = true
                }
            } else {
                wasTruncated = true
            }
        }
        if wasTruncated {
            let notice = "\n... [输出已截断：超过 \(cap) 字节上限]"
            collected.append(Data(notice.utf8))
        }
        return collected
    }

    /// Drain stdout and stderr while process runs without deadlocking on full pipe buffers
    static func runProcessWithOutput(
        _ process: Process,
        outPipe: Pipe,
        errPipe: Pipe,
        maxBytesPerStream: Int = defaultMaxOutputBytesPerStream
    ) async throws -> (Data, Data) {
        let outReader = Task.detached(priority: .utility) { () -> Data in
            Self.readCappedStream(from: outPipe.fileHandleForReading, maxBytes: maxBytesPerStream)
        }
        let errReader = Task.detached(priority: .utility) { () -> Data in
            Self.readCappedStream(from: errPipe.fileHandleForReading, maxBytes: maxBytesPerStream)
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
            var home = stateLock.withLock { remoteHomeDirectory }
            if home == nil { home = await probeRemoteHome() }
            guard let home, home.hasPrefix("/") else {
                throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取远程主目录"])
            }
            let dirHandler: (@Sendable (String) -> Void)? = stateLock.withLock {
                remoteHomeDirectory = home
                return directoryChangeHandler
            }
            path = path == "~" ? home : home + "/" + String(path.dropFirst(2))
            dirHandler?(path)
        }
        let (data, errorData, status): (Data, Data, Int32) = try await withControlSocketGate {
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
            let jumpArgs = advancedConnectionArgs(channel: .nonInteractiveSSH)
            let pw = currentResolvedPassword
            let hasStoreAuth = distributionChannel == .appStore && !(pw?.isEmpty ?? true)
            if let pw = pw, !pw.isEmpty, let passBin = sshpass {
                process.executableURL = URL(fileURLWithPath: passBin)
                process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
                    "-o", "StrictHostKeyChecking=accept-new",
                ] + authArgs + jumpArgs + ctrlArgs + [
                    "-p", "\(session.port)",
                    "\(session.username)@\(sshDestinationHost)",
                    cmd
                ]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = (hasStoreAuth ? [] : ["-o", "BatchMode=yes"]) + [
                    "-o", "StrictHostKeyChecking=accept-new",
                ] + authArgs + jumpArgs + ctrlArgs + [
                    "-p", "\(session.port)",
                    "\(session.username)@\(sshDestinationHost)",
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
            let out = await outReader.value
            let err = await errReader.value
            try? pipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            return (out, err, process.terminationStatus)
        }
        
        guard status == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "ApexSSH", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
                message.isEmpty ? "无法读取远程目录（退出码 \(status)）" : String(message.prefix(512))])
        }
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return Self.parseDirectoryListing(output, path: path)
    }

    private static let lsMonthTokens: Set<String> = [
        "jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec"
    ]

    private static func parseLSDirectoryDate(
        isEpoch: Bool,
        isISO: Bool,
        parts: [Substring],
        now: Date = Date()
    ) -> Date {
        if isEpoch, let epoch = Double(parts[5]) {
            return Date(timeIntervalSince1970: epoch)
        }

        let posixLocale = Locale(identifier: "en_US_POSIX")
        if isISO {
            let candidate = "\(parts[5]) \(parts[6])"
            let formatter = DateFormatter()
            formatter.locale = posixLocale
            formatter.timeZone = .current
            formatter.dateFormat = parts[6].count >= 8 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
            if let parsed = formatter.date(from: candidate) {
                return parsed
            }
        }

        if parts.count >= 8 {
            let p5 = String(parts[5])
            let p6 = String(parts[6])
            let p7 = String(parts[7])
            let monthFirst = lsMonthTokens.contains(p5.lowercased())
            let dayFirst = lsMonthTokens.contains(p6.lowercased())
            if monthFirst || dayFirst {
                let month = monthFirst ? p5 : p6
                let day = monthFirst ? p6 : p5
                let formatter = DateFormatter()
                formatter.locale = posixLocale
                formatter.timeZone = .current
                if p7.count == 4, p7.allSatisfy(\.isNumber) {
                    formatter.dateFormat = "MMM d yyyy"
                    if let parsed = formatter.date(from: "\(month) \(day) \(p7)") {
                        return parsed
                    }
                } else if p7.contains(":") {
                    let calendar = Calendar.current
                    let currentYear = calendar.component(.year, from: now)
                    formatter.dateFormat = p7.count >= 8 ? "MMM d HH:mm:ss yyyy" : "MMM d HH:mm yyyy"
                    if var parsed = formatter.date(from: "\(month) \(day) \(p7) \(currentYear)") {
                        if parsed.timeIntervalSince(now) > 180 * 86_400,
                           let adjusted = calendar.date(byAdding: .year, value: -1, to: parsed) {
                            parsed = adjusted
                        }
                        return parsed
                    }
                }
            }
        }

        return now
    }

    static func parseDirectoryListing(_ output: String, path: String) -> [SFTPItem] {
        var items: [SFTPItem] = []
        let lines = output.components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 7 else { continue }
            let perms = String(parts[0])
            guard perms.hasPrefix("-") || perms.hasPrefix("d") || perms.hasPrefix("l") else { continue }
            
            let isDir = perms.hasPrefix("d")
            let isLink = perms.hasPrefix("l")
            let size = UInt64(parts[4]) ?? 0
            
            // Check if parts[5] is a unix epoch timestamp (--time-style=+%s or -D '%s')
            let isEpoch = !parts[5].isEmpty && parts[5].allSatisfy(\.isNumber)
            let isISO = !isEpoch
                && parts.count >= 8
                && parts[5].count == 10
                && parts[5].filter({ $0 == "-" }).count == 2
                && parts[6].contains(":")
            let isStandardThreeTokenDate = !isEpoch && !isISO && parts.count >= 8 && (
                lsMonthTokens.contains(parts[5].lowercased()) || lsMonthTokens.contains(parts[6].lowercased())
            )
            let lastDateIndex = isEpoch ? 5 : (isISO ? 6 : ((isStandardThreeTokenDate || parts.count >= 9) ? 7 : 6))
            guard parts.count > lastDateIndex else { continue }

            // Scan immediately after the timestamp token and consume exactly ONE column-separator
            // whitespace so filenames starting with spaces (e.g. " foo.txt") are preserved intact.
            let afterDate = parts[lastDateIndex].endIndex
            guard afterDate < line.endIndex else { continue }
            let nameStart = line[afterDate].isWhitespace ? line.index(after: afterDate) : afterDate
            let rawName = String(line[nameStart...])
            if rawName == "." || rawName == ".." || rawName.isEmpty { continue }
            
            var name = rawName
            if isLink, let arrow = rawName.range(of: " -> ") {
                name = String(rawName[..<arrow.lowerBound])
            }
            
            let modDate = parseLSDirectoryDate(isEpoch: isEpoch, isISO: isISO, parts: parts)
            
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

    public static func expandTildeForSCP(_ path: String, homeDirectory: String?) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        if let home = homeDirectory, home.hasPrefix("/") {
            let trimmedHome = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
            return path == "~" ? trimmedHome : trimmedHome + "/" + String(path.dropFirst(2))
        }
        // In OpenSSH scp (SFTP mode), a relative path after `user@host:` is resolved relative
        // to the remote user's home directory, whereas a literal `~/` can fail on servers
        // without expand-path@openssh.com.
        let relative = path == "~" ? "." : String(path.dropFirst(2))
        return relative.isEmpty ? "." : relative
    }

    private func resolveRemotePathForTransfer(_ path: String) async -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        var home = stateLock.withLock { remoteHomeDirectory }
        if home == nil { home = await probeRemoteHome() }
        if let home, home.hasPrefix("/") {
            stateLock.withLock { remoteHomeDirectory = home }
        }
        return Self.expandTildeForSCP(path, homeDirectory: home)
    }

    public func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws {
        await resolvePasswordIfNeeded()
        let resolvedRemotePath = await resolveRemotePathForTransfer(remotePath)
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
        baseArgs.append(contentsOf: advancedConnectionArgs(channel: .scp))
        // Modern scp uses SFTP: the remote path is already one argv operand.
        // Shell quote characters would become part of the filename.
        let escapedRemote = resolvedRemotePath
        baseArgs.append(contentsOf: [
            "-P", "\(session.port)",
            Self.scpRemoteSpecifier(username: session.username, host: session.host, path: escapedRemote),
            accessibleURL.path
        ])
        
        if let pw = currentResolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/scp") + baseArgs
        } else {
            let hasStoreAuth = distributionChannel == .appStore && !(currentResolvedPassword?.isEmpty ?? true)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = (hasStoreAuth ? [] : ["-o", "BatchMode=yes"]) + baseArgs
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
        let resolvedRemotePath = await resolveRemotePathForTransfer(remotePath)
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
        baseArgs.append(contentsOf: advancedConnectionArgs(channel: .scp))
        // Modern scp uses SFTP: the remote path is already one argv operand.
        // Shell quote characters would become part of the filename.
        let escapedRemote = resolvedRemotePath
        baseArgs.append(contentsOf: [
            "-P", "\(session.port)",
            accessibleURL.path,
            Self.scpRemoteSpecifier(username: session.username, host: session.host, path: escapedRemote)
        ])
        
        if let pw = currentResolvedPassword, !pw.isEmpty, let passBin = sshpass {
            process.executableURL = URL(fileURLWithPath: passBin)
            process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/scp") + baseArgs
        } else {
            let hasStoreAuth = distributionChannel == .appStore && !(currentResolvedPassword?.isEmpty ?? true)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = (hasStoreAuth ? [] : ["-o", "BatchMode=yes"]) + baseArgs
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
        try await withControlSocketGate {
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
            let jumpArgs = advancedConnectionArgs(channel: .nonInteractiveSSH)
            let pw = currentResolvedPassword
            let hasStoreAuth = distributionChannel == .appStore && !(pw?.isEmpty ?? true)
            if let pw = pw, !pw.isEmpty, let passBin = sshpass {
                process.executableURL = URL(fileURLWithPath: passBin)
                process.arguments = sshpassArguments(secret: pw, tool: "/usr/bin/ssh") + [
                    "-o", "StrictHostKeyChecking=accept-new",
                ] + authArgs + jumpArgs + ctrlArgs + [
                    "-p", "\(session.port)",
                    "\(session.username)@\(sshDestinationHost)",
                    cmd
                ]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = (hasStoreAuth ? [] : ["-o", "BatchMode=yes"]) + [
                    "-o", "StrictHostKeyChecking=accept-new",
                ] + authArgs + jumpArgs + ctrlArgs + [
                    "-p", "\(session.port)",
                    "\(session.username)@\(sshDestinationHost)",
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

    private func quoteRemoteShellOperand(_ value: String) async -> String {
        if value == "~" || value.hasPrefix("~/") {
            let resolved = await resolveRemotePathForTransfer(value)
            if resolved.hasPrefix("/") {
                return Self.quoteRemotePath(resolved)
            }
            return SFTPRemoteOperations.shellQuotedRemotePath(value)
        }
        return Self.quoteRemotePath(value)
    }

    public func removeFile(remotePath: String) async throws {
        let target = await quoteRemoteShellOperand(remotePath)
        try await executeRemoteCommand("rm -f -- \(target)")
    }

    public func removeDirectory(remotePath: String, recursive: Bool) async throws {
        let command = recursive ? "rm -rf --" : "rmdir --"
        let target = await quoteRemoteShellOperand(remotePath)
        try await executeRemoteCommand("\(command) \(target)")
    }

    public func createDirectory(remotePath: String) async throws {
        let target = await quoteRemoteShellOperand(remotePath)
        try await executeRemoteCommand("mkdir -p -- \(target)")
    }

    public func createFile(remotePath: String) async throws {
        let target = await quoteRemoteShellOperand(remotePath)
        try await executeRemoteCommand("touch -- \(target)")
    }

    public func rename(oldPath: String, newPath: String) async throws {
        let oldTarget = await quoteRemoteShellOperand(oldPath)
        let newTarget = await quoteRemoteShellOperand(newPath)
        try await executeRemoteCommand("mv -- \(oldTarget) \(newTarget)")
    }

    public func changePermissions(remotePath: String, permissions: String) async throws {
        let target = await quoteRemoteShellOperand(remotePath)
        try await executeRemoteCommand("chmod -- \(Self.quoteRemotePath(permissions)) \(target)")
    }
}
