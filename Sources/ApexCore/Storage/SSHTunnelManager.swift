import Foundation
import Darwin
import os

@_silgen_name("proc_listchildpids")
private func tunnel_proc_listchildpids(_ ppid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

public enum SSHTunnelError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case portConflict(Int)
    case tunnelNotFound
    case processStartFailed(String)
    case sessionHostMissing
    
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "隧道配置无效：\(reason)"
        case .portConflict(let port):
            return "本地端口 \(port) 已被其他隧道占用，请更换端口"
        case .tunnelNotFound:
            return "未找到指定的 SSH 端口转发隧道"
        case .processStartFailed(let reason):
            return "启动 SSH 隧道进程失败：\(reason)"
        case .sessionHostMissing:
            return "关联的会话缺少主机地址"
        }
    }
}

/// Central manager for SSH Port Forwarding tunnels, persistence, and process lifecycle
@MainActor
public final class SSHTunnelManager: ObservableObject {
    public static let shared = SSHTunnelManager()
    
    @Published public private(set) var tunnels: [SSHTunnel] = []
    @Published public private(set) var activeStates: [UUID: SSHTunnelState] = [:]
    
    private struct TunnelRuntimeResources {
        var leases: [FileAccessLease] = []
        var grants: ChildProcessFileGrants?
        var logSource: DispatchSourceFileSystemObject?
        var logPath: String?
        var logBuffer = Data()
    }

    struct PreparedStoreTunnelCommand {
        let binaryPath: String
        let arguments: [String]
        let environment: [String: String]
        let grants: ChildProcessFileGrants
        let leases: [FileAccessLease]
    }

    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let distributionChannel: DistributionChannel
    private let fileAccessStore: FileAccessStore
    private let bridgeExecutableURL: URL
    private let sandboxHomeURL: URL
    private var processes: [UUID: Process] = [:]
    private var stderrPipes: [UUID: Pipe] = [:]
    private var runtimeResources: [UUID: TunnelRuntimeResources] = [:]
    
    public init(
        baseDirectory: URL? = nil,
        distributionChannel: DistributionChannel = .current,
        fileAccessStore: FileAccessStore = .shared,
        bridgeExecutableURL: URL? = nil,
        sandboxHomeURL: URL? = nil
    ) {
        if let baseDirectory = baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = SessionStore.defaultDirectory(appSupport: appSupport, bundleIdentifier: Bundle.main.bundleIdentifier)
        }
        self.distributionChannel = distributionChannel
        self.fileAccessStore = fileAccessStore
        self.bridgeExecutableURL = bridgeExecutableURL ?? URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/MacOS/ApexSSHBridge")
        self.sandboxHomeURL = sandboxHomeURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        
        try? fileManager.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
        loadTunnels()
    }
    
    private var tunnelsFileURL: URL {
        baseDirectory.appendingPathComponent("tunnels.json")
    }
    
    // MARK: - Persistence & CRUD
    
    public func loadTunnels() {
        guard let data = try? Data(contentsOf: tunnelsFileURL),
              let decoded = try? JSONDecoder().decode([SSHTunnel].self, from: data) else {
            return
        }
        self.tunnels = decoded
    }
    
    public func saveTunnels() {
        if let data = try? JSONEncoder().encode(tunnels) {
            try? data.write(to: tunnelsFileURL, options: .atomic)
        }
    }
    
    nonisolated private static func normalizeBindHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "localhost" { return "127.0.0.1" }
        return trimmed
    }

    nonisolated private static func isWildcardBindHost(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::" || host == "[::]" || host == "*"
    }

    nonisolated public static func hasPortConflict(_ candidate: SSHTunnel, existing: SSHTunnel) -> Bool {
        guard candidate.id != existing.id,
              candidate.bindPort == existing.bindPort else {
            return false
        }
        let candHost = normalizeBindHost(candidate.bindHost)
        let existHost = normalizeBindHost(existing.bindHost)
        let hostOverlaps = candHost == existHost || isWildcardBindHost(candHost) || isWildcardBindHost(existHost)
        guard hostOverlaps else {
            return false
        }
        // Remote (-R) tunnels bind on the remote SSH server (scoped by sessionId),
        // whereas Local (-L) and Dynamic (-D) tunnels bind on the local client machine.
        let candidateIsRemote = candidate.type == .remote
        let existingIsRemote = existing.type == .remote
        guard candidateIsRemote == existingIsRemote else {
            return false
        }
        if candidateIsRemote {
            return candidate.sessionId == existing.sessionId
        }
        return true
    }

    public func addTunnel(_ tunnel: SSHTunnel) throws {
        guard tunnel.isValid else {
            throw SSHTunnelError.invalidConfiguration("端口必须在 1 ~ 65535 范围内且地址不能为空")
        }
        if tunnels.contains(where: { Self.hasPortConflict(tunnel, existing: $0) }) {
            throw SSHTunnelError.portConflict(tunnel.bindPort)
        }
        tunnels.append(tunnel)
        saveTunnels()
    }
    
    public func updateTunnel(_ tunnel: SSHTunnel) throws {
        guard tunnel.isValid else {
            throw SSHTunnelError.invalidConfiguration("端口必须在 1 ~ 65535 范围内且地址不能为空")
        }
        if tunnels.contains(where: { Self.hasPortConflict(tunnel, existing: $0) }) {
            throw SSHTunnelError.portConflict(tunnel.bindPort)
        }
        if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels[index] = tunnel
            saveTunnels()
        } else {
            throw SSHTunnelError.tunnelNotFound
        }
    }
    
    public func deleteTunnel(id: UUID) {
        stopTunnel(id: id)
        tunnels.removeAll(where: { $0.id == id })
        activeStates.removeValue(forKey: id)
        saveTunnels()
    }
    
    public func replaceAllTunnels(_ newTunnels: [SSHTunnel]) {
        let newIDs = Set(newTunnels.map(\.id))
        for existing in tunnels where !newIDs.contains(existing.id) {
            stopTunnel(id: existing.id)
            activeStates.removeValue(forKey: existing.id)
        }
        self.tunnels = newTunnels
        saveTunnels()
    }
    
    public func tunnels(for sessionId: UUID) -> [SSHTunnel] {
        tunnels.filter { $0.sessionId == sessionId }
    }
    
    public func state(for tunnelId: UUID) -> SSHTunnelState {
        activeStates[tunnelId] ?? .stopped
    }
    
    // MARK: - Command Line Argument Generation

    nonisolated public static func expandPath(_ path: String) -> String {
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
    
    /// Constructs the standard OpenSSH command line arguments for the tunnel
    nonisolated public static func buildSSHArguments(
        tunnel: SSHTunnel,
        session: Session,
        privateKeyPath: String? = nil,
        certificatePath: String? = nil,
        jumpSession: Session? = nil,
        jumpChain: [Session] = []
    ) -> [String] {
        let interval = session.keepAliveIntervalSeconds > 0 ? min(max(session.keepAliveIntervalSeconds, 5), 60) : 15
        var args = [
            "-N", // Do not execute remote command
            "-T", // Disable pseudo-terminal allocation
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "TCPKeepAlive=yes",
            "-o", "ServerAliveInterval=\(interval)",
            "-o", "ServerAliveCountMax=10",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        
        // Tunnel specifier: -L, -R, or -D
        let bHost = SSHTunnel.formatForwardingHost(tunnel.bindHost)
        let tHost = SSHTunnel.formatForwardingHost(tunnel.targetHost)
        switch tunnel.type {
        case .local:
            args.append(contentsOf: ["-L", "\(bHost):\(tunnel.bindPort):\(tHost):\(tunnel.targetPort)"])
        case .remote:
            args.append(contentsOf: ["-R", "\(bHost):\(tunnel.bindPort):\(tHost):\(tunnel.targetPort)"])
        case .dynamic:
            args.append(contentsOf: ["-D", "\(bHost):\(tunnel.bindPort)"])
        }
        
        // Certificate and/or private key
        if let certPath = certificatePath ?? session.certificatePath, !certPath.isEmpty {
            let expandedCert = expandPath(certPath)
            let formattedCert = expandedCert.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" })
                ? SandboxSSHEnvironment.quotedPath(expandedCert)
                : expandedCert
            args.append(contentsOf: ["-o", "CertificateFile=\(formattedCert)"])
        }
        if let keyPath = privateKeyPath ?? session.privateKeyPath, !keyPath.isEmpty {
            args.append(contentsOf: ["-i", expandPath(keyPath)])
        }
        let effectiveHops: [Session] = !jumpChain.isEmpty ? jumpChain : (jumpSession.map { [$0] } ?? [])
        args.append(contentsOf: SSHArgumentBuilder.buildAdvancedOptions(
            for: session,
            channel: .nonInteractiveSSH,
            resolvedJumpHops: effectiveHops
        ))
        
        // Port & host
        let destHost = SSHTunnel.formatForwardingHost(session.host)
        args.append(contentsOf: ["-p", "\(session.port)", "\(session.username)@\(destHost)"])
        return args
    }

    nonisolated static func isTunnelLogLineReady(_ rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        return line.contains("Entering interactive session.")
            || line.contains("Local forwarding listening on")
            || line.contains("All remote forwarding requests processed")
            || line.contains("pledge: network")
            || line.contains("mux_client_request_session: master session id:")
            || line.contains("mux_client_forward:")
    }

    nonisolated static func prepareStoreTunnelCommand(
        tunnel: SSHTunnel,
        session: Session,
        password: String?,
        privateKeyPath: String?,
        jumpChain: [Session],
        extraSSHOptions: [String] = [],
        fileAccessStore: FileAccessStore,
        bridgeExecutableURL: URL,
        sandboxHomeURL: URL
    ) throws -> PreparedStoreTunnelCommand {
        guard FileManager.default.isExecutableFile(atPath: bridgeExecutableURL.path) else {
            throw SSHTunnelError.processStartFailed("商店版 SSH 文件授权组件缺失，请重新安装应用")
        }

        var leases: [FileAccessLease] = []
        do {
            var resolvedKeyPath = privateKeyPath
            if let keyPath = privateKeyPath ?? session.privateKeyPath,
               !keyPath.isEmpty,
               !KeychainStore.isVaultPrivateKeyReference(keyPath) {
                let lease = try fileAccessStore.acquire(URL(fileURLWithPath: expandPath(keyPath)))
                guard FileManager.default.isReadableFile(atPath: lease.url.path) else {
                    lease.close()
                    throw SSHTunnelError.processStartFailed("无法读取私钥，请在会话设置中通过「浏览」重新授权私钥文件")
                }
                leases.append(lease)
                resolvedKeyPath = lease.url.path
            }

            var resolvedCertPath: String? = nil
            if let certPath = session.certificatePath, !certPath.isEmpty {
                let lease = try fileAccessStore.acquire(URL(fileURLWithPath: expandPath(certPath)))
                guard FileManager.default.isReadableFile(atPath: lease.url.path) else {
                    lease.close()
                    throw SSHTunnelError.processStartFailed("无法读取 SSH 证书，请在会话设置中通过「浏览」重新授权证书文件")
                }
                leases.append(lease)
                resolvedCertPath = lease.url.path
            }

            let knownHosts = try SandboxSSHEnvironment.prepareKnownHosts(home: sandboxHomeURL)
            let baseArgs = extraSSHOptions + buildSSHArguments(
                tunnel: tunnel,
                session: session,
                privateKeyPath: resolvedKeyPath,
                certificatePath: resolvedCertPath,
                jumpChain: jumpChain
            )
            let sandboxArgs = try SandboxSSHEnvironment.arguments(
                prependingTo: baseArgs,
                tool: "ssh",
                knownHosts: knownHosts
            )

            let authentication: ChildProcessAuthentication?
            if let password, !password.isEmpty {
                let kind: ChildProcessAuthentication.Kind
                switch session.authMethod {
                case .privateKey, .certificate:
                    kind = .passphrase
                default:
                    kind = .password
                }
                authentication = ChildProcessAuthentication(kind: kind, secret: password)
            } else {
                authentication = nil
            }

            let grants = try ChildProcessFileGrants(
                files: try leases.map { try $0.childProcessGrant() },
                authentication: authentication
            )
            var env = ProcessInfo.processInfo.environment
            env[ChildProcessFileGrants.environmentKey] = grants.fileURL.path
            return PreparedStoreTunnelCommand(
                binaryPath: bridgeExecutableURL.path,
                arguments: ["--tool", "ssh"] + sandboxArgs,
                environment: env,
                grants: grants,
                leases: leases
            )
        } catch {
            leases.forEach { $0.close() }
            throw error
        }
    }
    
    // MARK: - Credential Resolution

    /// Resolves the login password or key passphrase used to unlock a tunnel's SSH process.
    /// Mirrors the terminal connection: legacy inline passwords fall back to the stored reference,
    /// and SSH Key Vault keys (`vault.priv.<UUID>`) fall back to their paired `vault.pass.<UUID>` passphrase.
    nonisolated public static func resolveSecret(
        for session: Session,
        lookup: @Sendable (String) async -> String? = { try? await KeychainStore.shared.get(key: $0) }
    ) async -> String? {
        switch session.authMethod {
        case .password(let ref):
            guard !ref.isEmpty else { return nil }
            if let found = await lookup(ref) { return found }
            return KeychainStore.isManagedReference(ref) ? nil : ref
        case .privateKey(let keyRef, let passphraseRef), .certificate(let keyRef, _, let passphraseRef):
            if let ref = passphraseRef, !ref.isEmpty {
                if let found = await lookup(ref) { return found }
                return KeychainStore.isManagedReference(ref) ? nil : ref
            }
            if let vaultPassRef = KeychainStore.vaultPassphraseReference(forPrivateKeyRef: keyRef) {
                return await lookup(vaultPassRef)
            }
            return nil
        default:
            return nil
        }
    }

    /// sshpass matches "assword" by default; key-based sessions answer the passphrase prompt instead.
    nonisolated public static func sshpassArguments(secret: String, session: Session) -> [String] {
        var args = ["-p", secret]
        if session.privateKeyPath != nil { args.append(contentsOf: ["-P", "passphrase"]) }
        args.append("/usr/bin/ssh")
        return args
    }

    // MARK: - Lifecycle Management
    
    public func startTunnel(
        id: UUID,
        session: Session,
        password: String? = nil,
        privateKeyPath: String? = nil,
        sshpassPath: String? = nil,
        jumpSession: Session? = nil,
        jumpChain: [Session]? = nil
    ) throws {
        guard let tunnel = tunnels.first(where: { $0.id == id }) else {
            throw SSHTunnelError.tunnelNotFound
        }
        guard !session.host.isEmpty else {
            throw SSHTunnelError.sessionHostMissing
        }
        guard tunnel.isValid else {
            throw SSHTunnelError.invalidConfiguration("端口或主机地址无效")
        }
        
        // Stop any existing process for this tunnel
        stopTunnel(id: id)
        activeStates[id] = .starting
        
        let resolvedChain: [Session]
        if let jumpChain {
            resolvedChain = jumpChain
        } else if let jumpSession {
            resolvedChain = [jumpSession]
        } else {
            resolvedChain = SSHArgumentBuilder.resolveJumpChain(for: session, availableSessions: SessionStore.shared.sessions).hops
        }

        let logPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("apx-tun-\(UUID().uuidString).log")
            .path
        let logFd = open(logPath, O_RDONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        let extraOptions = logFd >= 0 ? ["-o", "LogLevel=DEBUG1", "-E", logPath] : []

        var binaryPath = "/usr/bin/ssh"
        var sshArgs: [String]
        var processEnvironment: [String: String]? = nil
        var resources = TunnelRuntimeResources(logPath: logFd >= 0 ? logPath : nil)

        do {
            if distributionChannel == .appStore {
                let prepared = try Self.prepareStoreTunnelCommand(
                    tunnel: tunnel,
                    session: session,
                    password: password,
                    privateKeyPath: privateKeyPath,
                    jumpChain: resolvedChain,
                    extraSSHOptions: extraOptions,
                    fileAccessStore: fileAccessStore,
                    bridgeExecutableURL: bridgeExecutableURL,
                    sandboxHomeURL: sandboxHomeURL
                )
                binaryPath = prepared.binaryPath
                sshArgs = prepared.arguments
                processEnvironment = prepared.environment
                resources.grants = prepared.grants
                resources.leases = prepared.leases
            } else {
                sshArgs = extraOptions + Self.buildSSHArguments(
                    tunnel: tunnel,
                    session: session,
                    privateKeyPath: privateKeyPath,
                    jumpChain: resolvedChain
                )
                if let pw = password, !pw.isEmpty, let sshpass = sshpassPath, FileManager.default.isExecutableFile(atPath: sshpass) {
                    binaryPath = sshpass
                    sshArgs = Self.sshpassArguments(secret: pw, session: session) + sshArgs
                }
            }
        } catch {
            if logFd >= 0 {
                Darwin.close(logFd)
                unlink(logPath)
            }
            activeStates[id] = .failed(error.localizedDescription)
            throw error
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = sshArgs
        if let processEnvironment {
            process.environment = processEnvironment
        }
        
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        
        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.withLock { buf in
                buf.append(chunk)
                if buf.count > 8192 {
                    buf = Data(buf.suffix(8192))
                }
            }
        }

        if logFd >= 0 {
            let expectedProcessID = ObjectIdentifier(process)
            let logSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: logFd,
                eventMask: [.write, .extend, .attrib],
                queue: DispatchQueue.global(qos: .utility)
            )
            logSource.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.drainTunnelLog(id: id, fd: logFd, expectedProcessID: expectedProcessID)
                }
            }
            logSource.setCancelHandler {
                Darwin.close(logFd)
                unlink(logPath)
            }
            resources.logSource = logSource
            logSource.resume()
        }
        
        stderrPipes[id] = pipe
        processes[id] = process
        runtimeResources[id] = resources
        
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let remaining = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderrData = stderrBuffer.withLock { buf -> Data in
                if !remaining.isEmpty {
                    buf.append(remaining)
                    if buf.count > 8192 { buf = Data(buf.suffix(8192)) }
                }
                return buf
            }
            let procID = ObjectIdentifier(proc)
            Task { @MainActor [weak self] in
                guard let self = self, self.processes[id].map(ObjectIdentifier.init) == procID else { return }
                if logFd >= 0 {
                    self.drainTunnelLog(id: id, fd: logFd, expectedProcessID: procID)
                }
                let logDiagnostics = self.consumeTunnelLogDiagnostics(id: id)
                self.cleanupTunnelResources(for: id)
                self.processes.removeValue(forKey: id)
                self.stderrPipes.removeValue(forKey: id)
                
                let errString = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus != 0 {
                    let detail = !errString.isEmpty ? errString : logDiagnostics
                    let reason = detail.isEmpty ? "进程异常退出 (状态码 \(proc.terminationStatus))" : detail
                    self.activeStates[id] = .failed(reason)
                } else {
                    self.activeStates[id] = .stopped
                }
            }
        }
        
        do {
            try process.run()
            if logFd < 0 {
                self.activeStates[id] = .active
            } else {
                drainTunnelLog(id: id, fd: logFd, expectedProcessID: ObjectIdentifier(process))
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            cleanupTunnelResources(for: id)
            self.processes.removeValue(forKey: id)
            self.stderrPipes.removeValue(forKey: id)
            self.activeStates[id] = .failed(error.localizedDescription)
            throw SSHTunnelError.processStartFailed(error.localizedDescription)
        }
    }

    private func drainTunnelLog(id: UUID, fd: Int32, expectedProcessID: ObjectIdentifier) {
        guard processes[id].map(ObjectIdentifier.init) == expectedProcessID,
              var res = runtimeResources[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                res.logBuffer.append(contentsOf: buffer.prefix(bytesRead))
                if res.logBuffer.count > 16_384 {
                    res.logBuffer = Data(res.logBuffer.suffix(16_384))
                }
            } else if bytesRead < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        let text = String(decoding: res.logBuffer, as: UTF8.self)
        runtimeResources[id] = res
        if activeStates[id] == .starting {
            for line in text.components(separatedBy: .newlines) where Self.isTunnelLogLineReady(line) {
                activeStates[id] = .active
                break
            }
        }
    }

    private func consumeTunnelLogDiagnostics(id: UUID) -> String {
        guard let res = runtimeResources[id] else { return "" }
        let text = String(decoding: res.logBuffer, as: UTF8.self)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty
                    && !line.hasPrefix("debug1:")
                    && !line.hasPrefix("debug2:")
                    && !line.hasPrefix("debug3:")
                    && !line.hasPrefix("OpenSSH_")
                    && !line.hasPrefix("Warning: Permanently added ")
            }
        return lines.joined(separator: "\n")
    }

    private func cleanupTunnelResources(for id: UUID) {
        guard let res = runtimeResources.removeValue(forKey: id) else { return }
        res.logSource?.cancel()
        if res.logSource == nil, let logPath = res.logPath {
            unlink(logPath)
        }
        res.grants?.close()
        res.leases.forEach { $0.close() }
    }
    
    public func stopTunnel(id: UUID) {
        if let pipe = stderrPipes.removeValue(forKey: id) {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if let proc = processes.removeValue(forKey: id) {
            proc.terminationHandler = nil
            Self.terminateTunnelProcessTree(proc)
        }
        cleanupTunnelResources(for: id)
        activeStates[id] = .stopped
    }
    
    public func stopAll() {
        for (_, pipe) in stderrPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        for (id, proc) in processes {
            proc.terminationHandler = nil
            Self.terminateTunnelProcessTree(proc)
            cleanupTunnelResources(for: id)
            activeStates[id] = .stopped
        }
        processes.removeAll()
        stderrPipes.removeAll()
    }

    nonisolated private static func terminateTunnelProcessTree(_ proc: Process) {
        guard proc.isRunning else { return }
        let pid = proc.processIdentifier
        guard pid > 0 else {
            proc.terminate()
            return
        }
        let children = childPIDs(of: pid)
        for child in children.reversed() {
            kill(child, SIGTERM)
        }
        proc.terminate()

        for _ in 0..<15 {
            if !proc.isRunning {
                return
            }
            usleep(10_000)
        }
        for child in children.reversed() {
            kill(child, SIGKILL)
        }
        kill(pid, SIGKILL)
    }

    nonisolated private static func childPIDs(of parent: pid_t) -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 64)
        let count = tunnel_proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        let direct = children.prefix(Int(count)).filter { $0 > 0 }
        return direct.flatMap { [$0] + childPIDs(of: $0) }
    }
    
    /// Test helper to simulate state updates
    public func setSimulatedState(id: UUID, state: SSHTunnelState) {
        activeStates[id] = state
    }
}
