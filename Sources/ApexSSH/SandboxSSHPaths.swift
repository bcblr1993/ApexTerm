import Foundation
import Darwin
import ApexCore

/// OpenSSH uses passwd's home directory rather than the application's container.
/// Select writable application paths explicitly for the sandboxed distribution.
struct SandboxSSHPaths: Sendable {
    let home: URL
    let directory: URL
    let knownHosts: URL
    let controlSocket: URL

    // OpenSSH first binds path + "." + 16 random ASCII characters, then links
    // the listener into place. Darwin's 104-byte sun_path also includes NUL.
    var canUseControlSocket: Bool { controlSocket.path.utf8.count + 17 < 104 }

    var controlSocketOption: String {
        canUseControlSocket ? "ControlPath=" + Self.quotedPath(controlSocket.path) : "ControlPath=none"
    }

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
         temporary: URL = FileManager.default.temporaryDirectory, identifier: String = UUID().uuidString) {
        self.home = home
        directory = SandboxSSHEnvironment.directory(home: home)
        knownHosts = SandboxSSHEnvironment.knownHostsURL(home: home)
        controlSocket = temporary.appendingPathComponent("apx-" + identifier.replacingOccurrences(of: "-", with: "").prefix(16))
    }

    func prepare() throws {
        // Long sandbox temporary paths can still authenticate and transfer files
        // without multiplexing; never fall back to a shared non-container socket.
        _ = try SandboxSSHEnvironment.prepareKnownHosts(home: home)
    }

    func arguments(prependingTo arguments: [String], tool: String) throws -> [String] {
        // Imported hosts use explicit session fields. A selected -F file remains
        // supported; otherwise do not implicitly read the real user's ~/.ssh.
        try SandboxSSHEnvironment.arguments(prependingTo: arguments, tool: tool, knownHosts: knownHosts)
    }

    static func quotedPath(_ path: String) -> String {
        SandboxSSHEnvironment.quotedPath(path)
    }
}
