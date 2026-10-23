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
}

/// Type of terminal session: SSH remote or local system shell
public enum SessionType: String, Codable, Sendable, Equatable, Hashable {
    case ssh = "ssh"
    case local = "local"
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
    
    // Jump Server / ProxyJump
    public var jumpServerId: UUID?
    
    // Features configuration
    public var agentlessMonitorEnabled: Bool
    public var sftpAutoSyncEnabled: Bool
    public var keepAliveIntervalSeconds: Int
    public var terminalType: TerminalType
    
    // Timestamps
    public var createdAt: Date
    public var lastConnectedAt: Date?
    
    public var isLocal: Bool { sessionType == .local }
    public var certificatePath: String? { authMethod.certificatePath }
    public var privateKeyPath: String? { authMethod.privateKeyPath }
    
    public enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, authMethod, sessionType
        case folder, tags, colorHex, jumpServerId
        case agentlessMonitorEnabled, sftpAutoSyncEnabled, keepAliveIntervalSeconds, terminalType
        case createdAt, lastConnectedAt
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
        jumpServerId: UUID? = nil,
        agentlessMonitorEnabled: Bool = true,
        sftpAutoSyncEnabled: Bool = true,
        keepAliveIntervalSeconds: Int = 30,
        terminalType: TerminalType = .default,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
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
        self.jumpServerId = jumpServerId
        self.agentlessMonitorEnabled = agentlessMonitorEnabled
        self.sftpAutoSyncEnabled = sftpAutoSyncEnabled
        self.keepAliveIntervalSeconds = keepAliveIntervalSeconds
        self.terminalType = terminalType
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.host = try container.decode(String.self, forKey: .host)
        self.port = try container.decode(Int.self, forKey: .port)
        self.username = try container.decode(String.self, forKey: .username)
        self.authMethod = try container.decode(SSHAuthMethod.self, forKey: .authMethod)
        self.sessionType = try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .ssh
        self.folder = try container.decodeIfPresent(String.self, forKey: .folder)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        self.jumpServerId = try container.decodeIfPresent(UUID.self, forKey: .jumpServerId)
        self.agentlessMonitorEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentlessMonitorEnabled) ?? true
        self.sftpAutoSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .sftpAutoSyncEnabled) ?? true
        self.keepAliveIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .keepAliveIntervalSeconds) ?? 30
        // Older builds never wrote this key; unknown values from newer builds also fall back.
        let rawTerminalType = try? container.decodeIfPresent(String.self, forKey: .terminalType)
        self.terminalType = rawTerminalType.flatMap { TerminalType(rawValue: $0) } ?? .default
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
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
        try container.encodeIfPresent(jumpServerId, forKey: .jumpServerId)
        try container.encode(agentlessMonitorEnabled, forKey: .agentlessMonitorEnabled)
        try container.encode(sftpAutoSyncEnabled, forKey: .sftpAutoSyncEnabled)
        try container.encode(keepAliveIntervalSeconds, forKey: .keepAliveIntervalSeconds)
        try container.encode(terminalType, forKey: .terminalType)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
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

