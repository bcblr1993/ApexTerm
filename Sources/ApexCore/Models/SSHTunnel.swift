import Foundation

/// Type of SSH port forwarding tunnel
public enum SSHTunnelType: String, CaseIterable, Codable, Identifiable, Sendable {
    case local = "local"       // -L [bindHost:]bindPort:targetHost:targetPort
    case remote = "remote"     // -R [bindHost:]bindPort:targetHost:targetPort
    case dynamic = "dynamic"   // -D [bindHost:]bindPort (SOCKS5 Proxy)
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .local: return "本地端口转发 (Local -L)"
        case .remote: return "远程端口转发 (Remote -R)"
        case .dynamic: return "动态 SOCKS5 代理 (Dynamic -D)"
        }
    }
    
    public var shortDescription: String {
        switch self {
        case .local: return "将本地端口流量转发至远程内网服务（如访问内网数据库）"
        case .remote: return "将远程端口流量转发至本地端口（临时内网穿透）"
        case .dynamic: return "在本地开放 SOCKS5 代理网关，直接穿透访问远程内网网段"
        }
    }
}

/// Lifecycle state of an SSH tunnel
public enum SSHTunnelState: Codable, Sendable, Equatable {
    case stopped
    case starting
    case active
    case failed(String)
    
    public var isRunning: Bool {
        if case .active = self { return true }
        return false
    }
}

/// Represents an SSH Port Forwarding configuration
public struct SSHTunnel: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var type: SSHTunnelType
    public var sessionId: UUID
    public var bindHost: String
    public var bindPort: Int
    public var targetHost: String
    public var targetPort: Int
    public var autoStart: Bool
    
    public init(
        id: UUID = UUID(),
        name: String,
        type: SSHTunnelType = .local,
        sessionId: UUID,
        bindHost: String = "127.0.0.1",
        bindPort: Int = 3306,
        targetHost: String = "localhost",
        targetPort: Int = 3306,
        autoStart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.sessionId = sessionId
        self.bindHost = bindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : bindHost
        self.bindPort = bindPort
        self.targetHost = targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "localhost" : targetHost
        self.targetPort = targetPort
        self.autoStart = autoStart
    }
    
    /// Returns the standard OpenSSH command line parameter for this tunnel specification
    public var openSSHSpecifier: String {
        switch type {
        case .local:
            return "-L \(bindHost):\(bindPort):\(targetHost):\(targetPort)"
        case .remote:
            return "-R \(bindHost):\(bindPort):\(targetHost):\(targetPort)"
        case .dynamic:
            return "-D \(bindHost):\(bindPort)"
        }
    }
    
    /// Validates ports and host parameters
    public var isValid: Bool {
        guard bindPort >= 1 && bindPort <= 65535 else { return false }
        if type == .dynamic {
            return !bindHost.isEmpty
        } else {
            guard targetPort >= 1 && targetPort <= 65535 else { return false }
            return !bindHost.isEmpty && !targetHost.isEmpty
        }
    }
}
