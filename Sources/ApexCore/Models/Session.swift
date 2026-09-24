import Foundation

/// Authentication method for SSH connection
public enum SSHAuthMethod: Codable, Sendable, Equatable, Hashable {
    case password(keychainRef: String)
    case privateKey(keychainRef: String, passphraseRef: String?)
    case agent
    case none
}

/// Represents a configured remote SSH host session
public struct Session: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: SSHAuthMethod
    
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
    
    // Timestamps
    public var createdAt: Date
    public var lastConnectedAt: Date?
    
    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        authMethod: SSHAuthMethod = .agent,
        folder: String? = nil,
        tags: [String] = [],
        colorHex: String? = nil,
        jumpServerId: UUID? = nil,
        agentlessMonitorEnabled: Bool = true,
        sftpAutoSyncEnabled: Bool = true,
        keepAliveIntervalSeconds: Int = 30,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.folder = folder
        self.tags = tags
        self.colorHex = colorHex
        self.jumpServerId = jumpServerId
        self.agentlessMonitorEnabled = agentlessMonitorEnabled
        self.sftpAutoSyncEnabled = sftpAutoSyncEnabled
        self.keepAliveIntervalSeconds = keepAliveIntervalSeconds
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }
}
