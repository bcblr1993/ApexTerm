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
    /// `totalBytes` is the remote size known by the caller. It lets the session report intermediate
    /// fractions while scp is still streaming; pass 0 when the size is unknown.
    func downloadFile(remotePath: String, localURL: URL, totalBytes: Int64, progress: @Sendable @escaping (Double) -> Void) async throws
    func uploadFile(localURL: URL, remotePath: String, progress: @Sendable @escaping (Double) -> Void) async throws
    func removeFile(remotePath: String) async throws
    func removeDirectory(remotePath: String, recursive: Bool) async throws
    func createDirectory(remotePath: String) async throws
    func createFile(remotePath: String) async throws
    func rename(oldPath: String, newPath: String) async throws
    func changePermissions(remotePath: String, permissions: String) async throws
    
    /// Executes a one-shot command (remote over SSH or local shell)
    func executeCommand(_ command: String) async throws -> String
    
    /// TERM advertised to the PTY on the next connect
    var terminalType: TerminalType { get }
    
    /// Overrides the TERM used by subsequent connects without rebuilding the client
    func setTerminalType(_ type: TerminalType)
    
    // Callbacks
    func setOutputHandler(_ handler: @Sendable @escaping (Data) -> Void)
    func setMetricsHandler(_ handler: @Sendable @escaping (ServerMetricsSnapshot) -> Void)
    func setDirectoryChangeHandler(_ handler: @Sendable @escaping (String) -> Void)
    func setStateChangeHandler(_ handler: @Sendable @escaping (SSHConnectionState) -> Void)
}

public extension SSHSessionProtocol {
    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }
    
    func executeCommand(_ command: String) async throws -> String {
        return ""
    }
    
    func setStateChangeHandler(_ handler: @Sendable @escaping (SSHConnectionState) -> Void) {}
    var terminalType: TerminalType { session.terminalType }
    func setTerminalType(_ type: TerminalType) {}
    func sendInputSync(_ data: Data) {
        Task { try? await sendInput(data) }
    }
    
    func removeFile(remotePath: String) async throws {}
    func removeDirectory(remotePath: String, recursive: Bool) async throws {}
    func createDirectory(remotePath: String) async throws {}
    func createFile(remotePath: String) async throws {}
    func rename(oldPath: String, newPath: String) async throws {}
    func changePermissions(remotePath: String, permissions: String) async throws {}
}
