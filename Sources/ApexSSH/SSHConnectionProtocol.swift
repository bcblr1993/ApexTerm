import Foundation
import ApexCore

/// Connection state of an SSH session
public enum SSHConnectionState: Sendable, Equatable {
    case disconnected
    case connecting(step: String)
    case connected
    case failed(String)
}

/// Protocol defining the SSH Client engine capabilities
public protocol SSHSessionProtocol: AnyObject, Sendable {
    var session: Session { get }
    var connectionState: SSHConnectionState { get }
    
    /// Connect to remote host
    func connect() async throws
    
    /// Disconnect from remote host
    func disconnect() async
    
    /// Send user keystrokes / input to remote PTY
    func sendInput(_ data: Data) async throws
    
    /// Immediate zero-latency synchronous write to PTY file descriptor
    func sendInputSync(_ data: Data)
    
    /// Resize remote PTY window (cols, rows)
    func resizeTerminal(columns: Int, rows: Int) async throws
    
    // SFTP subsystem
    func listDirectory(path: String) async throws -> [SFTPItem]
    func downloadFile(remotePath: String, localURL: URL, progress: @Sendable @escaping (Double) -> Void) async throws
    func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws
    
    // Callbacks
    func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void)
    func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void)
    func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void)
}

public extension SSHSessionProtocol {
    func sendInputSync(_ data: Data) {
        Task { try? await sendInput(data) }
    }
}
