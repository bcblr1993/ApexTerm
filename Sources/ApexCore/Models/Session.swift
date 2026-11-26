import Foundation

/// Authentication method for SSH connection
public enum SSHAuthMethod: Codable, Sendable, Equatable, Hashable {
    case password(keychainRef: String)
    case privateKey(keychainRef: String, passphraseRef: String?)
    case certificate(keychainRef: String, certificatePath: String, passphraseRef: String?)
    case agent
    case none
    
    public var isCertificate: Bool {
        if case .certificate = self { return true }
        return false
    }
    
    public var certificatePath: String? {
        if case .certificate(_, let cert, _) = self { return cert }
        return nil
    }
    
    public var privateKeyPath: String? {
        switch self {
        case .privateKey(let keyPath, _): return keyPath
        case .certificate(let keyPath, _, _): return keyPath
        default: return nil
        }
    }

    public var passphraseRef: String? {
        switch self {
        case .privateKey(_, let passRef): return passRef
        case .certificate(_, _, let passRef): return passRef
        default: return nil
        }
    }
}

/// Type of terminal session: SSH remote or local system shell
public enum SessionType: String, Codable, Sendable, Equatable, Hashable {
    case ssh = "ssh"
    case local = "local"
}

/// Optional deployment environment tier badge for visual safety and broadcast awareness.
public enum EnvironmentTier: String, CaseIterable, Codable, Sendable, Equatable, Hashable, Identifiable {
    case prod = "prod"
    case staging = "staging"
    case dev = "dev"

    public var id: String { rawValue }

    public var badgeText: String {
        switch self {
        case .prod: return "PROD"
        case .staging: return "STAGING"
        case .dev: return "DEV"
        }
    }

    public var displayName: String {
        switch self {
        case .prod: return "生产环境 [PROD]"
        case .staging: return "预发环境 [STAGING]"
        case .dev: return "开发环境 [DEV]"
        }
    }

    public var colorHex: String {
        switch self {
        case .prod: return "#FF453A"
        case .staging: return "#FF9F0A"
        case .dev: return "#30D158"
        }
    }
}

/// TERM value advertised to the remote PTY. Minimal distros may lack the
/// `xterm-256color` terminfo entry, which makes readline fall back to
/// horizontal scrolling, so sessions can pick a more widely available type.
public enum TerminalType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case xterm256Color = "xterm-256color"
    case xterm = "xterm"
    case vt100 = "vt100"
    case linux = "linux"

    public static let `default`: TerminalType = .xterm256Color

    /// Safer type to switch to when the remote lacks the terminfo for `self`.
    public var fallback: TerminalType {
        switch self {
        case .xterm256Color, .linux: return .xterm
        case .xterm, .vt100: return .vt100
        }
    }
}

/// Represents a configured remote SSH host session or local terminal session
public struct Session: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: SSHAuthMethod
    public var sessionType: SessionType
    
    // Organization
    public var folder: String?
    public var tags: [String]
    public var colorHex: String?
    public var environmentTier: EnvironmentTier?
    
    // Jump Server / ProxyJump & Advanced SSH Options
    public var jumpServerId: UUID?
    public var jumpServerChain: [UUID]
    public var forwardAgent: Bool
    public var compression: Bool
    public var proxyCommand: String?

    /// Ordered jump host IDs combining explicit `jumpServerChain` with legacy single `jumpServerId`.
    public var effectiveJumpServerChain: [UUID] {
        if !jumpServerChain.isEmpty {
            return jumpServerChain
        }
        if let legacy = jumpServerId {
            return [legacy]
        }
        return []
    }
    
    // Features configuration
    public var agentlessMonitorEnabled: Bool
    public var sftpAutoSyncEnabled: Bool
    public var keepAliveIntervalSeconds: Int
    public var terminalType: TerminalType
    public var initialWorkingDirectory: String?
    public var startupCommand: String?
    public var environmentVariables: [String: String]
    
    // Timestamps
    public var createdAt: Date
    public var lastConnectedAt: Date?
    public var updatedAt: Date?
    
    public var isLocal: Bool { sessionType == .local }
    public var certificatePath: String? { authMethod.certificatePath }
    public var privateKeyPath: String? { authMethod.privateKeyPath }
    public var passphraseRef: String? { authMethod.passphraseRef }
    
    public enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, sessionType
        case folder, tags, colorHex, environmentTier, jumpServerId, jumpServerChain
        case forwardAgent, compression, proxyCommand
        case agentlessMonitorEnabled, sftpAutoSyncEnabled, keepAliveIntervalSeconds, terminalType
        case initialWorkingDirectory, startupCommand, environmentVariables
        case createdAt, lastConnectedAt, updatedAt
    }
    
    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: SSHAuthMethod = .agent,
        sessionType: SessionType = .ssh,
        folder: String? = nil,
        tags: [String] = [],
        colorHex: String? = nil,
        environmentTier: EnvironmentTier? = nil,
        jumpServerId: UUID? = nil,
        jumpServerChain: [UUID] = [],
        forwardAgent: Bool = false,
        compression: Bool = false,
        proxyCommand: String? = nil,
        agentlessMonitorEnabled: Bool = true,
        sftpAutoSyncEnabled: Bool = true,
        keepAliveIntervalSeconds: Int = 30,
        terminalType: TerminalType = .default,
        initialWorkingDirectory: String? = nil,
        startupCommand: String? = nil,
        environmentVariables: [String: String] = [:],
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.sessionType = sessionType
        self.folder = folder
        self.tags = tags
        self.colorHex = colorHex
        self.environmentTier = environmentTier
        let normalizedChain: [UUID]
        if !jumpServerChain.isEmpty {
            var seen: Set<UUID> = []
            normalizedChain = jumpServerChain.filter { $0 != id && seen.insert($0).inserted }
        } else if let jumpServerId, jumpServerId != id {
            normalizedChain = [jumpServerId]
        } else {
            normalizedChain = []
        }
        self.jumpServerChain = normalizedChain
        self.jumpServerId = normalizedChain.first
        self.forwardAgent = forwardAgent
        self.compression = compression
        let cleanProxy = proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.proxyCommand = (cleanProxy?.isEmpty == true) ? nil : cleanProxy
        self.agentlessMonitorEnabled = agentlessMonitorEnabled
        self.sftpAutoSyncEnabled = sftpAutoSyncEnabled
        self.keepAliveIntervalSeconds = keepAliveIntervalSeconds
        self.terminalType = terminalType
        self.initialWorkingDirectory = initialWorkingDirectory
        self.startupCommand = startupCommand
        self.environmentVariables = environmentVariables
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.updatedAt = updatedAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedId = try container.decode(UUID.self, forKey: .id)
        self.id = decodedId
        self.name = try container.decode(String.self, forKey: .name)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(Int.self, forKey: .port)
        self.username = try container.decode(String.self, forKey: .username)
        self.authMethod = try container.decode(SSHAuthMethod.self, forKey: .authMethod)
        self.sessionType = try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .ssh
        self.folder = try container.decodeIfPresent(String.self, forKey: .folder)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        let rawTier = try? container.decodeIfPresent(String.self, forKey: .environmentTier)
        self.environmentTier = rawTier.flatMap { EnvironmentTier(rawValue: $0) }
        let decodedLegacyJump = try container.decodeIfPresent(UUID.self, forKey: .jumpServerId)
        let decodedChain = try container.decodeIfPresent([UUID].self, forKey: .jumpServerChain) ?? []
        if !decodedChain.isEmpty {
            var seen: Set<UUID> = []
            let cleanChain = decodedChain.filter { $0 != decodedId && seen.insert($0).inserted }
            self.jumpServerChain = cleanChain
            self.jumpServerId = cleanChain.first
        } else if let legacy = decodedLegacyJump, legacy != decodedId {
            self.jumpServerChain = [legacy]
            self.jumpServerId = legacy
        } else {
            self.jumpServerChain = []
            self.jumpServerId = nil
        }
        self.forwardAgent = try container.decodeIfPresent(Bool.self, forKey: .forwardAgent) ?? false
        self.compression = try container.decodeIfPresent(Bool.self, forKey: .compression) ?? false
        let rawProxy = try container.decodeIfPresent(String.self, forKey: .proxyCommand)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.proxyCommand = (rawProxy?.isEmpty == true) ? nil : rawProxy
        self.agentlessMonitorEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentlessMonitorEnabled) ?? true
        self.sftpAutoSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .sftpAutoSyncEnabled) ?? true
        self.keepAliveIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .keepAliveIntervalSeconds) ?? 30
        // Older builds never wrote this key; unknown values from newer builds also fall back.
        let rawTerminalType = try? container.decodeIfPresent(String.self, forKey: .terminalType)
        self.terminalType = rawTerminalType.flatMap { TerminalType(rawValue: $0) } ?? .default
        self.initialWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .initialWorkingDirectory)
        self.startupCommand = try container.decodeIfPresent(String.self, forKey: .startupCommand)
        self.environmentVariables = try container.decodeIfPresent([String: String].self, forKey: .environmentVariables) ?? [:]
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(sessionType, forKey: .sessionType)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(colorHex, forKey: .colorHex)
        try container.encodeIfPresent(environmentTier, forKey: .environmentTier)
        try container.encodeIfPresent(jumpServerId ?? jumpServerChain.first, forKey: .jumpServerId)
        if !jumpServerChain.isEmpty {
            try container.encode(jumpServerChain, forKey: .jumpServerChain)
        }
        if forwardAgent {
            try container.encode(forwardAgent, forKey: .forwardAgent)
        }
        if compression {
            try container.encode(compression, forKey: .compression)
        }
        try container.encodeIfPresent(proxyCommand, forKey: .proxyCommand)
        try container.encode(agentlessMonitorEnabled, forKey: .agentlessMonitorEnabled)
        try container.encode(sftpAutoSyncEnabled, forKey: .sftpAutoSyncEnabled)
        try container.encode(keepAliveIntervalSeconds, forKey: .keepAliveIntervalSeconds)
        try container.encode(terminalType, forKey: .terminalType)
        try container.encodeIfPresent(initialWorkingDirectory, forKey: .initialWorkingDirectory)
        try container.encodeIfPresent(startupCommand, forKey: .startupCommand)
        if !environmentVariables.isEmpty {
            try container.encode(environmentVariables, forKey: .environmentVariables)
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
    
    public static func local(
        id: UUID = UUID(),
        name: String = "本地终端",
        colorHex: String? = "#34C759"
    ) -> Session {
        let user = ProcessInfo.processInfo.userName
        return Session(
            id: id,
            name: name,
            host: "localhost",
            port: 0,
            username: user.isEmpty ? "local" : user,
            authMethod: .none,
            sessionType: .local,
            folder: nil,
            tags: ["本地"],
            colorHex: colorHex,
            jumpServerId: nil,
            agentlessMonitorEnabled: true,
            sftpAutoSyncEnabled: true,
            keepAliveIntervalSeconds: 0
        )
    }
}

