import Foundation
import Darwin
import os

@_silgen_name("proc_listchildpids")
private func tunnel_proc_listchildpids(_ ppid: pid_t, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

/// Per-tunnel policy persisted alongside `tunnels.json`.
public struct SSHTunnelPolicy: Codable, Sendable, Equatable {
    public var autoReconnect: Bool

    public init(autoReconnect: Bool = false) {
        self.autoReconnect = autoReconnect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? false
    }
}

/// Diagnostic result for a single hop in an SSH jump chain or target endpoint.
public struct SSHHopDiagnosticResult: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let hopIndex: Int
    public let label: String
    public let host: String
    public let port: Int
    public let isReachable: Bool
    public let latencyMs: Int?
    public let hasHostKeyConflict: Bool
    public let message: String

    public init(
        id: UUID = UUID(),
        hopIndex: Int,
        label: String,
        host: String,
        port: Int,
        isReachable: Bool,
        latencyMs: Int? = nil,
        hasHostKeyConflict: Bool = false,
        message: String
    ) {
        self.id = id
        self.hopIndex = hopIndex
        self.label = label
        self.host = host
        self.port = port
        self.isReachable = isReachable
        self.latencyMs = latencyMs
        self.hasHostKeyConflict = hasHostKeyConflict
        self.message = message
    }
}

/// Comprehensive route, port-bind, SSH agent, and host-key diagnostic report for an SSH tunnel.
public struct SSHTunnelDiagnosticReport: Sendable, Equatable {
    public let tunnelID: UUID
    public let localBindHost: String
    public let localBindPort: Int
    public let isLocalPortAvailable: Bool
    public let localPortMessage: String
    public let sshAuthSockPath: String?
    public let isSSHAuthSockAvailable: Bool
    public let forwardAgentEnabled: Bool
    public let hopResults: [SSHHopDiagnosticResult]
    public let hasHostKeyConflict: Bool
    public let conflictHost: String?
    public let conflictPort: Int?
    public let generatedAt: Date

    public init(
        tunnelID: UUID,
        localBindHost: String,
        localBindPort: Int,
        isLocalPortAvailable: Bool,
        localPortMessage: String,
        sshAuthSockPath: String?,
        isSSHAuthSockAvailable: Bool,
        forwardAgentEnabled: Bool,
        hopResults: [SSHHopDiagnosticResult],
        hasHostKeyConflict: Bool,
        conflictHost: String?,
        conflictPort: Int?,
        generatedAt: Date = Date()
    ) {
        self.tunnelID = tunnelID
        self.localBindHost = localBindHost
        self.localBindPort = localBindPort
        self.isLocalPortAvailable = isLocalPortAvailable
        self.localPortMessage = localPortMessage
        self.sshAuthSockPath = sshAuthSockPath
        self.isSSHAuthSockAvailable = isSSHAuthSockAvailable
        self.forwardAgentEnabled = forwardAgentEnabled
        self.hopResults = hopResults
        self.hasHostKeyConflict = hasHostKeyConflict
        self.conflictHost = conflictHost
        self.conflictPort = conflictPort
        self.generatedAt = generatedAt
    }
}

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

    private struct TunnelStartParameters {
        let session: Session
        let password: String?
        let privateKeyPath: String?
        let sshpassPath: String?
        let jumpChain: [Session]
        let customExecutableURL: URL?
        let customArguments: [String]?
    }

    public static let maxAutoReconnectAttempts = 5
    private static let maxStderrLinesPerTunnel = 200

    public typealias LocalPortBindChecker = @Sendable (_ host: String, _ port: Int) -> (available: Bool, message: String)
    public typealias TCPReachabilityProber = @Sendable (_ host: String, _ port: Int, _ timeoutSeconds: TimeInterval) async -> (reachable: Bool, latencyMs: Int?, message: String)

    @Published public private(set) var tunnelPolicies: [UUID: SSHTunnelPolicy] = [:]
    @Published public private(set) var stderrLogs: [UUID: [String]] = [:]
    @Published public private(set) var reconnectAttempts: [UUID: Int] = [:]
    @Published public private(set) var reconnectStatusNotes: [UUID: String] = [:]

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
    private let baseReconnectDelaySeconds: TimeInterval
    private let maxReconnectDelaySeconds: TimeInterval
    private var processes: [UUID: Process] = [:]
    private var stderrPipes: [UUID: Pipe] = [:]
    private var runtimeResources: [UUID: TunnelRuntimeResources] = [:]
    private var lastStartParameters: [UUID: TunnelStartParameters] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var manualStopIDs: Set<UUID> = []
    
    public init(
        baseDirectory: URL? = nil,
        distributionChannel: DistributionChannel = .current,
        fileAccessStore: FileAccessStore = .shared,
        bridgeExecutableURL: URL? = nil,
        sandboxHomeURL: URL? = nil,
        baseReconnectDelaySeconds: TimeInterval = 2.0,
        maxReconnectDelaySeconds: TimeInterval = 30.0
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
        self.baseReconnectDelaySeconds = max(0.01, baseReconnectDelaySeconds)
        self.maxReconnectDelaySeconds = max(self.baseReconnectDelaySeconds, maxReconnectDelaySeconds)
        
        try? fileManager.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
        loadTunnels()
    }
    
    private var tunnelsFileURL: URL {
        baseDirectory.appendingPathComponent("tunnels.json")
    }

    private var policiesFileURL: URL {
        baseDirectory.appendingPathComponent("tunnel_policies.json")
    }
    
    // MARK: - Persistence & CRUD
    
    public func loadTunnels() {
        if let data = try? Data(contentsOf: tunnelsFileURL),
           let decoded = try? JSONDecoder().decode([SSHTunnel].self, from: data) {
            self.tunnels = decoded
        }
        if let policyData = try? Data(contentsOf: policiesFileURL),
           let decodedPolicies = try? JSONDecoder().decode([UUID: SSHTunnelPolicy].self, from: policyData) {
            self.tunnelPolicies = decodedPolicies
        }
    }
    
    public func saveTunnels() {
        if let data = try? JSONEncoder().encode(tunnels) {
            try? data.write(to: tunnelsFileURL, options: .atomic)
        }
    }

    public func savePolicies() {
        if let data = try? JSONEncoder().encode(tunnelPolicies) {
            try? data.write(to: policiesFileURL, options: .atomic)
        }
    }

    public func isAutoReconnectEnabled(for tunnelId: UUID) -> Bool {
        tunnelPolicies[tunnelId]?.autoReconnect ?? false
    }

    public func setAutoReconnect(_ enabled: Bool, for tunnelId: UUID) {
        tunnelPolicies[tunnelId] = SSHTunnelPolicy(autoReconnect: enabled)
        savePolicies()
    }

    nonisolated public static func reconnectBackoffDelaySeconds(
        attempt: Int,
        baseDelay: TimeInterval = 2.0,
        maxDelay: TimeInterval = 30.0
    ) -> TimeInterval {
        let clampedAttempt = max(1, attempt)
        let multiplier = pow(2.0, Double(clampedAttempt - 1))
        return min(maxDelay, max(0.01, baseDelay) * multiplier)
    }

    public func stderrLogText(for tunnelId: UUID) -> String {
        (stderrLogs[tunnelId] ?? []).joined(separator: "\n")
    }

    public func clearStderrLog(for tunnelId: UUID) {
        stderrLogs[tunnelId] = []
    }

    private func appendStderrChunk(_ chunkText: String, for tunnelId: UUID) {
        let lines = chunkText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        var current = stderrLogs[tunnelId] ?? []
        current.append(contentsOf: lines)
        if current.count > Self.maxStderrLinesPerTunnel {
            current = Array(current.suffix(Self.maxStderrLinesPerTunnel))
        }
        stderrLogs[tunnelId] = current
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
        tunnelPolicies.removeValue(forKey: id)
        stderrLogs.removeValue(forKey: id)
        reconnectAttempts.removeValue(forKey: id)
        reconnectStatusNotes.removeValue(forKey: id)
        lastStartParameters.removeValue(forKey: id)
        saveTunnels()
        savePolicies()
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
        try startTunnelInternal(
            id: id,
            session: session,
            password: password,
            privateKeyPath: privateKeyPath,
            sshpassPath: sshpassPath,
            jumpSession: jumpSession,
            jumpChain: jumpChain,
            isAutoReconnectAttempt: false
        )
    }

    private func startTunnelInternal(
        id: UUID,
        session: Session,
        password: String? = nil,
        privateKeyPath: String? = nil,
        sshpassPath: String? = nil,
        jumpSession: Session? = nil,
        jumpChain: [Session]? = nil,
        isAutoReconnectAttempt: Bool
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
        
        // Stop any existing process for this tunnel without wiping retry counter on auto-reconnect
        let preservedAttempt = isAutoReconnectAttempt ? (reconnectAttempts[id] ?? 0) : 0
        stopTunnelProcessOnly(id: id)
        manualStopIDs.remove(id)
        if !isAutoReconnectAttempt {
            reconnectAttempts[id] = 0
            reconnectStatusNotes.removeValue(forKey: id)
            stderrLogs[id] = []
        } else {
            reconnectAttempts[id] = preservedAttempt
        }
        activeStates[id] = .starting
        
        let resolvedChain: [Session]
        if let jumpChain {
            resolvedChain = jumpChain
        } else if let jumpSession {
            resolvedChain = [jumpSession]
        } else {
            resolvedChain = SSHArgumentBuilder.resolveJumpChain(for: session, availableSessions: SessionStore.shared.sessions).hops
        }

        lastStartParameters[id] = TunnelStartParameters(
            session: session,
            password: password,
            privateKeyPath: privateKeyPath,
            sshpassPath: sshpassPath,
            jumpChain: resolvedChain,
            customExecutableURL: nil,
            customArguments: nil
        )

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
        
        if logFd >= 0 {
            let expectedProcessID = ObjectIdentifier(process)
            let logSource = Self.makeLogDispatchSource(
                manager: self,
                id: id,
                logFd: logFd,
                logPath: logPath,
                expectedProcessID: expectedProcessID
            )
            resources.logSource = logSource
            logSource.resume()
        }
        
        stderrPipes[id] = pipe
        processes[id] = process
        runtimeResources[id] = resources
        
        Self.attachStderrAndTerminationHandlers(
            manager: self,
            id: id,
            process: process,
            pipe: pipe,
            logFd: logFd
        )
        
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
                reconnectAttempts[id] = 0
                reconnectStatusNotes.removeValue(forKey: id)
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
    
    private func stopTunnelProcessOnly(id: UUID) {
        reconnectTasks.removeValue(forKey: id)?.cancel()
        if let pipe = stderrPipes.removeValue(forKey: id) {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        if let proc = processes.removeValue(forKey: id) {
            proc.terminationHandler = nil
            Self.terminateTunnelProcessTree(proc)
        }
        cleanupTunnelResources(for: id)
    }

    public func stopTunnel(id: UUID) {
        manualStopIDs.insert(id)
        stopTunnelProcessOnly(id: id)
        reconnectAttempts[id] = 0
        reconnectStatusNotes.removeValue(forKey: id)
        activeStates[id] = .stopped
    }
    
    public func stopAll() {
        for id in Set(processes.keys).union(reconnectTasks.keys) {
            manualStopIDs.insert(id)
        }
        for (_, task) in reconnectTasks {
            task.cancel()
        }
        reconnectTasks.removeAll()
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
        reconnectStatusNotes.removeAll()
    }

    private func scheduleAutoReconnectIfNeeded(tunnelId: UUID, exitCode: Int32, failureDetail: String) {
        let shouldSuppressReconnect = manualStopIDs.contains(tunnelId)
            || !isAutoReconnectEnabled(for: tunnelId)
            || exitCode != 255
            || Self.isPermanentTunnelFailure(failureDetail)
            || lastStartParameters[tunnelId] == nil

        guard !shouldSuppressReconnect else {
            reconnectStatusNotes.removeValue(forKey: tunnelId)
            activeStates[tunnelId] = .failed(failureDetail)
            return
        }

        let nextAttempt = (reconnectAttempts[tunnelId] ?? 0) + 1
        guard nextAttempt <= Self.maxAutoReconnectAttempts else {
            reconnectStatusNotes.removeValue(forKey: tunnelId)
            activeStates[tunnelId] = .failed("自动重连已达上限 (\(Self.maxAutoReconnectAttempts) 次): \(failureDetail)")
            return
        }

        reconnectAttempts[tunnelId] = nextAttempt
        let delay = Self.reconnectBackoffDelaySeconds(
            attempt: nextAttempt,
            baseDelay: baseReconnectDelaySeconds,
            maxDelay: maxReconnectDelaySeconds
        )
        let delayLabel = delay >= 1 ? "\(Int(delay.rounded()))s" : "\(Int((delay * 1000).rounded()))ms"
        let note = "连接中断 (exit 255)，\(delayLabel) 后第 \(nextAttempt)/\(Self.maxAutoReconnectAttempts) 次自动重连…"
        reconnectStatusNotes[tunnelId] = note
        appendStderrChunk("[AetherTerm] \(note)", for: tunnelId)
        activeStates[tunnelId] = .starting

        reconnectTasks[tunnelId]?.cancel()
        reconnectTasks[tunnelId] = Task { @MainActor [weak self] in
            let nanos = UInt64(max(0.01, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled, !self.manualStopIDs.contains(tunnelId) else { return }
            guard let params = self.lastStartParameters[tunnelId] else { return }
            do {
                if let customExe = params.customExecutableURL {
                    try self.startCustomProcessInternal(
                        id: tunnelId,
                        executableURL: customExe,
                        arguments: params.customArguments ?? [],
                        session: params.session,
                        isAutoReconnectAttempt: true
                    )
                } else {
                    try self.startTunnelInternal(
                        id: tunnelId,
                        session: params.session,
                        password: params.password,
                        privateKeyPath: params.privateKeyPath,
                        sshpassPath: params.sshpassPath,
                        jumpChain: params.jumpChain,
                        isAutoReconnectAttempt: true
                    )
                }
            } catch {
                self.reconnectStatusNotes.removeValue(forKey: tunnelId)
                self.activeStates[tunnelId] = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated private static func isPermanentTunnelFailure(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return lower.contains("address already in use")
            || lower.contains("host key verification failed")
            || lower.contains("remote host identification has changed")
            || lower.contains("permission denied")
    }

    /// Test-accessible launcher allowing custom executable & arguments to test live stderr + exit-255 backoff.
    func startCustomProcessForTesting(
        id: UUID,
        executableURL: URL,
        arguments: [String],
        session: Session
    ) throws {
        try startCustomProcessInternal(
            id: id,
            executableURL: executableURL,
            arguments: arguments,
            session: session,
            isAutoReconnectAttempt: false
        )
    }

    private func startCustomProcessInternal(
        id: UUID,
        executableURL: URL,
        arguments: [String],
        session: Session,
        isAutoReconnectAttempt: Bool
    ) throws {
        guard tunnels.contains(where: { $0.id == id }) else {
            throw SSHTunnelError.tunnelNotFound
        }
        let preservedAttempt = isAutoReconnectAttempt ? (reconnectAttempts[id] ?? 0) : 0
        stopTunnelProcessOnly(id: id)
        manualStopIDs.remove(id)
        if !isAutoReconnectAttempt {
            reconnectAttempts[id] = 0
            reconnectStatusNotes.removeValue(forKey: id)
            stderrLogs[id] = []
        } else {
            reconnectAttempts[id] = preservedAttempt
        }
        lastStartParameters[id] = TunnelStartParameters(
            session: session,
            password: nil,
            privateKeyPath: nil,
            sshpassPath: nil,
            jumpChain: [],
            customExecutableURL: executableURL,
            customArguments: arguments
        )
        activeStates[id] = .starting

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice

        stderrPipes[id] = pipe
        processes[id] = process
        Self.attachStderrAndTerminationHandlers(
            manager: self,
            id: id,
            process: process,
            pipe: pipe,
            logFd: -1
        )
        try process.run()
    }

    nonisolated private static func makeLogDispatchSource(
        manager: SSHTunnelManager,
        id: UUID,
        logFd: Int32,
        logPath: String,
        expectedProcessID: ObjectIdentifier
    ) -> DispatchSourceFileSystemObject {
        let logSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: logFd,
            eventMask: [.write, .extend, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        logSource.setEventHandler { [weak manager] in
            Task { @MainActor [weak manager] in
                manager?.drainTunnelLog(id: id, fd: logFd, expectedProcessID: expectedProcessID)
            }
        }
        logSource.setCancelHandler {
            Darwin.close(logFd)
            unlink(logPath)
        }
        return logSource
    }

    nonisolated private static func attachStderrAndTerminationHandlers(
        manager: SSHTunnelManager,
        id: UUID,
        process: Process,
        pipe: Pipe,
        logFd: Int32
    ) {
        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        pipe.fileHandleForReading.readabilityHandler = { [weak manager] handle in
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
            if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                Task { @MainActor [weak manager] in
                    manager?.appendStderrChunk(text, for: id)
                }
            }
        }

        process.terminationHandler = { [weak manager] proc in
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
            let status = proc.terminationStatus
            Task { @MainActor [weak manager] in
                guard let manager, manager.processes[id].map(ObjectIdentifier.init) == procID else { return }
                if logFd >= 0 {
                    manager.drainTunnelLog(id: id, fd: logFd, expectedProcessID: procID)
                }
                let logDiagnostics = manager.consumeTunnelLogDiagnostics(id: id)
                manager.cleanupTunnelResources(for: id)
                manager.processes.removeValue(forKey: id)
                manager.stderrPipes.removeValue(forKey: id)

                let errString = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !errString.isEmpty {
                    manager.appendStderrChunk(errString, for: id)
                }
                if status != 0 {
                    let detail = !errString.isEmpty ? errString : logDiagnostics
                    let reason = detail.isEmpty ? "进程异常退出 (状态码 \(status))" : detail
                    manager.scheduleAutoReconnectIfNeeded(tunnelId: id, exitCode: status, failureDetail: reason)
                } else {
                    manager.reconnectAttempts[id] = 0
                    manager.reconnectStatusNotes.removeValue(forKey: id)
                    manager.activeStates[id] = .stopped
                }
            }
        }
    }

    // MARK: - Bastion & Route Diagnostics ("诊断链路")

    nonisolated public static func checkLocalPortAvailability(host: String, port: Int) -> (available: Bool, message: String) {
        guard (1...65535).contains(port) else {
            return (false, "端口 \(port) 超出合法范围 (1-65535)")
        }
        var cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.hasPrefix("[") && cleanHost.hasSuffix("]") && cleanHost.count >= 2 {
            cleanHost = String(cleanHost.dropFirst().dropLast())
        }
        if cleanHost.isEmpty || cleanHost == "localhost" {
            cleanHost = "127.0.0.1"
        }

        let isIPv6 = cleanHost.contains(":")
        let family = isIPv6 ? AF_INET6 : AF_INET
        let sock = Darwin.socket(family, SOCK_STREAM, 0)
        guard sock >= 0 else {
            return (false, "无法创建测试套接字 (errno=\(errno))")
        }
        defer { Darwin.close(sock) }

        let bindResult: Int32
        if isIPv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = UInt16(port).bigEndian
            if cleanHost == "::" {
                addr.sin6_addr = in6addr_any
            } else {
                var in6 = in6_addr()
                guard inet_pton(AF_INET6, cleanHost, &in6) == 1 else {
                    return (false, "无效的 IPv6 本地监听地址: \(cleanHost)")
                }
                addr.sin6_addr = in6
            }
            bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            if cleanHost == "0.0.0.0" || cleanHost == "*" {
                addr.sin_addr.s_addr = INADDR_ANY.bigEndian
            } else {
                var in4 = in_addr()
                guard inet_pton(AF_INET, cleanHost, &in4) == 1 else {
                    return (false, "无效的 IPv4 本地监听地址: \(cleanHost)")
                }
                addr.sin_addr = in4
            }
            bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if bindResult == 0 {
            return (true, "本地端口 \(cleanHost):\(port) 可绑定")
        }
        let err = errno
        if err == EADDRINUSE {
            return (false, "本地端口 \(cleanHost):\(port) 已被占用 (EADDRINUSE)")
        }
        if err == EACCES {
            return (false, "绑定本地端口 \(cleanHost):\(port) 权限不足 (EACCES)")
        }
        return (false, "绑定本地端口 \(cleanHost):\(port) 失败 (errno=\(err))")
    }

    nonisolated public static func probeTCPReachability(
        host: String,
        port: Int,
        timeoutSeconds: TimeInterval = 2.5
    ) async -> (reachable: Bool, latencyMs: Int?, message: String) {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !cleanHost.isEmpty, (1...65535).contains(port) else {
            return (false, nil, "无效的主机或端口: \(host):\(port)")
        }

        return await Task.detached(priority: .utility) {
            let startNs = DispatchTime.now().uptimeNanoseconds
            var hints = addrinfo(
                ai_flags: 0,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var resultPtr: UnsafeMutablePointer<addrinfo>?
            let gaiErr = getaddrinfo(cleanHost, String(port), &hints, &resultPtr)
            guard gaiErr == 0, let firstAddr = resultPtr else {
                let errMsg = gaiErr != 0 ? String(cString: gai_strerror(gaiErr)) : "DNS 解析失败"
                return (false, nil, "域名解析失败: \(errMsg)")
            }
            defer { freeaddrinfo(resultPtr) }

            var current: UnsafeMutablePointer<addrinfo>? = firstAddr
            var lastError = "连接不可达"
            let timeoutMs = Int32(max(100, min(10_000, Int(timeoutSeconds * 1000))))

            while let info = current {
                let fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
                if fd >= 0 {
                    let flags = fcntl(fd, F_GETFL, 0)
                    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                    let rc = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                    if rc == 0 {
                        let ms = max(1, Int((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000))
                        Darwin.close(fd)
                        return (true, ms, "TCP 可达 (\(ms) ms)")
                    }
                    if errno == EINPROGRESS {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let pollRc = Darwin.poll(&pfd, 1, timeoutMs)
                        if pollRc > 0 {
                            var soError: Int32 = 0
                            var soLen = socklen_t(MemoryLayout<Int32>.size)
                            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soLen)
                            if soError == 0 {
                                let ms = max(1, Int((DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000))
                                Darwin.close(fd)
                                return (true, ms, "TCP 可达 (\(ms) ms)")
                            }
                            lastError = String(cString: strerror(soError))
                        } else if pollRc == 0 {
                            lastError = "TCP 连接超时"
                        } else {
                            lastError = String(cString: strerror(errno))
                        }
                    } else {
                        lastError = String(cString: strerror(errno))
                    }
                    Darwin.close(fd)
                }
                current = info.pointee.ai_next
            }
            return (false, nil, lastError)
        }.value
    }

    nonisolated public static func diagnoseRouteHops(
        for session: Session,
        jumpChain: [Session],
        knownHostsManager: KnownHostsManager = .shared,
        timeoutSeconds: TimeInterval = 2.5,
        reachabilityProber: TCPReachabilityProber? = nil
    ) async -> [SSHHopDiagnosticResult] {
        let prober = reachabilityProber ?? { host, port, timeout in
            await probeTCPReachability(host: host, port: port, timeoutSeconds: timeout)
        }
        knownHostsManager.reload()
        let conflicts = knownHostsManager.conflicts

        let chain = jumpChain + [session]
        var results: [SSHHopDiagnosticResult] = []
        for (index, hop) in chain.enumerated() {
            let isTarget = (index == chain.count - 1)
            let label = isTarget ? "目标主机 (\(hop.name))" : "跳板机 #\(index + 1) (\(hop.name))"
            let probe = await prober(hop.host, hop.port, timeoutSeconds)

            let cleanHopHost = hop.host.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased()
            let hasConflict = conflicts.contains { conflict in
                let endpoint = conflict.endpoint.lowercased()
                if hop.port == 22 {
                    return endpoint == cleanHopHost || endpoint == "[\(cleanHopHost)]:22"
                }
                return endpoint == "[\(cleanHopHost)]:\(hop.port)"
            }

            let message: String
            if hasConflict {
                message = "\(probe.message)；检测到 known_hosts 主机指纹冲突"
            } else {
                message = probe.message
            }

            results.append(
                SSHHopDiagnosticResult(
                    hopIndex: index + 1,
                    label: label,
                    host: hop.host,
                    port: hop.port,
                    isReachable: probe.reachable,
                    latencyMs: probe.latencyMs,
                    hasHostKeyConflict: hasConflict,
                    message: message
                )
            )
        }
        return results
    }

    public func diagnoseTunnel(
        _ tunnel: SSHTunnel,
        session: Session,
        jumpChain: [Session],
        knownHostsManager: KnownHostsManager = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        localPortChecker: LocalPortBindChecker? = nil,
        reachabilityProber: TCPReachabilityProber? = nil
    ) async -> SSHTunnelDiagnosticReport {
        let portResult: (available: Bool, message: String)
        if tunnel.type == .remote {
            portResult = (true, "远程转发 (-R) 无需绑定本地监听端口")
        } else if let checker = localPortChecker {
            portResult = checker(tunnel.bindHost, tunnel.bindPort)
        } else {
            portResult = Self.checkLocalPortAvailability(host: tunnel.bindHost, port: tunnel.bindPort)
        }

        let authSock = environment["SSH_AUTH_SOCK"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sockAvailable = authSock.map { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) } ?? false

        let hops = await Self.diagnoseRouteHops(
            for: session,
            jumpChain: jumpChain,
            knownHostsManager: knownHostsManager,
            reachabilityProber: reachabilityProber
        )

        let conflictHop = hops.first(where: \.hasHostKeyConflict)
        let stderrHasHostKeyConflict = stderrLogText(for: tunnel.id).contains("Host key verification failed")
            || stderrLogText(for: tunnel.id).contains("REMOTE HOST IDENTIFICATION HAS CHANGED")

        let finalConflict = (conflictHop != nil) || stderrHasHostKeyConflict
        return SSHTunnelDiagnosticReport(
            tunnelID: tunnel.id,
            localBindHost: tunnel.bindHost,
            localBindPort: tunnel.bindPort,
            isLocalPortAvailable: portResult.available,
            localPortMessage: portResult.message,
            sshAuthSockPath: authSock,
            isSSHAuthSockAvailable: sockAvailable,
            forwardAgentEnabled: session.forwardAgent,
            hopResults: hops,
            hasHostKeyConflict: finalConflict,
            conflictHost: conflictHop?.host ?? (stderrHasHostKeyConflict ? session.host : nil),
            conflictPort: conflictHop?.port ?? (stderrHasHostKeyConflict ? session.port : nil)
        )
    }

    nonisolated public static func clearHostKeyConflict(
        host: String,
        port: Int = 22,
        knownHostsManager: KnownHostsManager = .shared
    ) throws -> Int {
        try knownHostsManager.removeEntries(matchingEndpoint: host, port: port)
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
