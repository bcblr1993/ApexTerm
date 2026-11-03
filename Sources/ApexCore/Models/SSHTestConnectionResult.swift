import Foundation

/// Result of an SSH connection & authentication preflight test
public struct SSHTestConnectionResult: Sendable, Equatable {
    public let isSuccess: Bool
    public let latencyMs: Int
    public let serverInfo: String?
    public let errorMessage: String?
    
    public init(isSuccess: Bool, latencyMs: Int = 0, serverInfo: String? = nil, errorMessage: String? = nil) {
        self.isSuccess = isSuccess
        self.latencyMs = latencyMs
        self.serverInfo = serverInfo
        self.errorMessage = errorMessage
    }
}
