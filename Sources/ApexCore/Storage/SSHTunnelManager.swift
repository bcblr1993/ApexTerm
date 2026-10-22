import Foundation

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
    
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private var processes: [UUID: Process] = [:]
    private var stderrPipes: [UUID: Pipe] = [:]
    
    public init(baseDirectory: URL? = nil) {
        if let baseDirectory = baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = SessionStore.defaultDirectory(appSupport: appSupport, bundleIdentifier: Bundle.main.bundleIdentifier)
        }
        
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
    
    public func addTunnel(_ tunnel: SSHTunnel) throws {
        guard tunnel.isValid else {
            throw SSHTunnelError.invalidConfiguration("端口必须在 1 ~ 65535 范围内且地址不能为空")
        }
        if tunnels.contains(where: { $0.id != tunnel.id && $0.bindPort == tunnel.bindPort && $0.bindHost == tunnel.bindHost }) {
            throw SSHTunnelError.portConflict(tunnel.bindPort)
        }
        tunnels.append(tunnel)
        saveTunnels()
    }
    
    public func updateTunnel(_ tunnel: SSHTunnel) throws {
        guard tunnel.isValid else {
            throw SSHTunnelError.invalidConfiguration("端口必须在 1 ~ 65535 范围内且地址不能为空")
        }
        if tunnels.contains(where: { $0.id != tunnel.id && $0.bindPort == tunnel.bindPort && $0.bindHost == tunnel.bindHost }) {
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
    
    /// Constructs the standard OpenSSH command line arguments for the tunnel
    nonisolated public static func buildSSHArguments(
        tunnel: SSHTunnel,
        session: Session,
        privateKeyPath: String? = nil
    ) -> [String] {
        var args = [
            "-N", // Do not execute remote command
            "-T", // Disable pseudo-terminal allocation
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=\(session.keepAliveIntervalSeconds)",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        
        // Tunnel specifier: -L, -R, or -D
        switch tunnel.type {
        case .local:
            args.append(contentsOf: ["-L", "\(tunnel.bindHost):\(tunnel.bindPort):\(tunnel.targetHost):\(tunnel.targetPort)"])
        case .remote:
            args.append(contentsOf: ["-R", "\(tunnel.bindHost):\(tunnel.bindPort):\(tunnel.targetHost):\(tunnel.targetPort)"])
        case .dynamic:
            args.append(contentsOf: ["-D", "\(tunnel.bindHost):\(tunnel.bindPort)"])
        }
        
        // Certificate and/or private key
        if let certPath = session.certificatePath, !certPath.isEmpty {
            args.append(contentsOf: ["-o", "CertificateFile=\(certPath)"])
        }
        if let keyPath = privateKeyPath ?? session.privateKeyPath, !keyPath.isEmpty {
            args.append(contentsOf: ["-i", keyPath])
        }
        
        // Port & host
        args.append(contentsOf: ["-p", "\(session.port)", "\(session.username)@\(session.host)"])
        return args
    }
    
    // MARK: - Credential Resolution

    /// Resolves the login password or key passphrase used to unlock a tunnel's SSH process.
    /// Mirrors the terminal connection: legacy inline passwords fall back to the stored reference.
    nonisolated public static func resolveSecret(
        for session: Session,
        lookup: @Sendable (String) async -> String? = { try? await KeychainStore.shared.get(key: $0) }
    ) async -> String? {
        switch session.authMethod {
        case .password(let ref):
            guard !ref.isEmpty else { return nil }
            if let found = await lookup(ref) { return found }
            return KeychainStore.isManagedReference(ref) ? nil : ref
        case .privateKey(_, let passphraseRef), .certificate(_, _, let passphraseRef):
            guard let ref = passphraseRef, !ref.isEmpty else { return nil }
            if let found = await lookup(ref) { return found }
            return KeychainStore.isManagedReference(ref) ? nil : ref
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
        sshpassPath: String? = nil
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
        
        var binaryPath = "/usr/bin/ssh"
        var sshArgs = Self.buildSSHArguments(tunnel: tunnel, session: session, privateKeyPath: privateKeyPath)
        
        if let pw = password, !pw.isEmpty, let sshpass = sshpassPath, FileManager.default.isExecutableFile(atPath: sshpass) {
            binaryPath = sshpass
            sshArgs = Self.sshpassArguments(secret: pw, session: session) + sshArgs
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = sshArgs
        
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        
        stderrPipes[id] = pipe
        processes[id] = process
        
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.processes.removeValue(forKey: id)
                let stderrData = self.stderrPipes[id]?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                self.stderrPipes.removeValue(forKey: id)
                
                let errString = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if proc.terminationStatus != 0 {
                    let reason = errString.isEmpty ? "进程异常退出 (状态码 \(proc.terminationStatus))" : errString
                    self.activeStates[id] = .failed(reason)
                } else {
                    self.activeStates[id] = .stopped
                }
            }
        }
        
        do {
            try process.run()
            // Mark active once launched
            self.activeStates[id] = .active
        } catch {
            self.processes.removeValue(forKey: id)
            self.stderrPipes.removeValue(forKey: id)
            self.activeStates[id] = .failed(error.localizedDescription)
            throw SSHTunnelError.processStartFailed(error.localizedDescription)
        }
    }
    
    public func stopTunnel(id: UUID) {
        if let proc = processes.removeValue(forKey: id) {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
            }
        }
        stderrPipes.removeValue(forKey: id)
        activeStates[id] = .stopped
    }
    
    public func stopAll() {
        for (id, proc) in processes {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
            }
            activeStates[id] = .stopped
        }
        processes.removeAll()
        stderrPipes.removeAll()
    }
    
    /// Test helper to simulate state updates
    public func setSimulatedState(id: UUID, state: SSHTunnelState) {
        activeStates[id] = state
    }
}
