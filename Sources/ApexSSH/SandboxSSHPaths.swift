import Foundation
import Darwin
import ApexCore

/// OpenSSH uses passwd's home directory rather than the application's container.
/// Select writable application paths explicitly for the sandboxed distribution.
struct SandboxSSHPaths: Sendable {
    let directory: URL
    let knownHosts: URL
    let controlSocket: URL

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
         temporary: URL = FileManager.default.temporaryDirectory, identifier: String = UUID().uuidString) {
        directory = home.appendingPathComponent("Library/Application Support/ApexTerm/SSH", isDirectory: true)
        knownHosts = directory.appendingPathComponent("known_hosts")
        controlSocket = temporary.appendingPathComponent("apx-" + identifier.replacingOccurrences(of: "-", with: "").prefix(16))
    }

    func prepare() throws {
        // Darwin sockaddr_un.sun_path is 104 bytes, including the terminating NUL.
        guard controlSocket.path.utf8.count < 104 else {
            throw NSError(domain: "ApexSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "SSH 临时目录路径过长，无法创建控制连接。"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let fd = open(knownHosts.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func arguments(prependingTo arguments: [String], tool: String) throws -> [String] {
        // Imported hosts use explicit session fields. A selected -F file remains
        // supported; otherwise do not implicitly read the real user's ~/.ssh.
        let localIndices = try ChildProcessGrantPayload.localFileArgumentIndices(in: arguments, tool: tool)
        let hasConfig = localIndices.contains { $0 > 0 && arguments[$0 - 1] == "-F" }
        let config = hasConfig ? [] : ["-F", "/dev/null"]
        return config + ["-o", "UserKnownHostsFile=\(Self.quotedPath(knownHosts.path))"] + arguments
    }

    static func quotedPath(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
