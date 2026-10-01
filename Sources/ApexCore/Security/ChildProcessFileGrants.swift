import Foundation
import Darwin

public struct ChildProcessFileGrant: Codable, Sendable {
    public let path: String
    public let bookmark: Data
    public init(path: String, bookmark: Data) { self.path = path; self.bookmark = bookmark }
}

public struct ChildProcessGrantPayload: Codable, Sendable {
    public let version: Int
    public let files: [ChildProcessFileGrant]
    public init(files: [ChildProcessFileGrant]) { self.version = 1; self.files = files }

    /// Resolve implicit grants in the process which will exec the system SSH tool.
    public func resolve() throws -> [(originalPath: String, url: URL)] {
        guard version == 1, files.count <= 32 else { throw CocoaError(.fileReadCorruptFile) }
        return try files.map { file in
            guard file.path.hasPrefix("/"), !file.bookmark.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            var stale = false
            let url = try URL(resolvingBookmarkData: file.bookmark, options: [.withoutUI], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
            return (file.path, url)
        }
    }

    /// Select local file operands only; SSH command text after the host stays literal.
    public static func localFileArgumentIndices(in arguments: [String], tool: String) throws -> Set<Int> {
        guard tool == "ssh" || tool == "scp" else { throw CocoaError(.fileReadCorruptFile) }
        let optionsWithValues: Set<String> = tool == "ssh"
            ? ["-b", "-B", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-P", "-p", "-Q", "-R", "-S", "-W", "-w"]
            : ["-c", "-D", "-F", "-i", "-J", "-l", "-o", "-P", "-S", "-X"]
        var selected = Set<Int>()
        var index = 0
        while index < arguments.count, arguments[index].hasPrefix("-"),
              arguments[index] != "--", arguments[index] != "-" {
            let option = arguments[index]
            if optionsWithValues.contains(option) {
                guard index + 1 < arguments.count else { throw CocoaError(.fileReadCorruptFile) }
                if option == "-i" || option == "-F" { selected.insert(index + 1) }
                index += 2
            } else { index += 1 }
        }
        if tool == "scp" { selected.formUnion(arguments.indices.suffix(2)) }
        return selected
    }

    public static func rebaseArguments(_ arguments: [String], using grants: [(originalPath: String, url: URL)],
                                       at localPathIndices: Set<Int>) -> [String] {
        let longestFirst = grants.sorted { $0.originalPath.count > $1.originalPath.count }
        return arguments.enumerated().map { index, argument in
            guard localPathIndices.contains(index), argument.hasPrefix("/") else { return argument }
            for grant in longestFirst {
                let prefix = grant.originalPath.hasSuffix("/") ? grant.originalPath : grant.originalPath + "/"
                if argument == grant.originalPath { return grant.url.path }
                if argument.hasPrefix(prefix) {
                    return grant.url.appendingPathComponent(String(argument.dropFirst(prefix.count))).path
                }
            }
            return argument
        }
    }
}

/// Runtime-only capability data in a private app temporary directory; never bundle resources.
public final class ChildProcessFileGrants: @unchecked Sendable {
    public static let environmentKey = "APEX_SSH_GRANTS_FILE"
    public static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("ApexSSHGrants", isDirectory: true) }
    public let fileURL: URL
    private let lock = NSLock()
    private var closed = false

    public init(files: [ChildProcessFileGrant]) throws {
        guard files.count <= 32 else { throw CocoaError(.fileWriteUnknown) }
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        fileURL = directory.appendingPathComponent("grant-" + UUID().uuidString + ".json")
        var created = false
        do {
            let data = try JSONEncoder().encode(ChildProcessGrantPayload(files: files))
            guard data.count <= 1_048_576 else { throw CocoaError(.fileWriteUnknown) }
            let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            created = true
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        } catch {
            if created { try? FileManager.default.removeItem(at: fileURL) }
            throw error
        }
    }

    public static func read(from fileURL: URL) throws -> ChildProcessGrantPayload {
        guard fileURL.isFileURL,
              fileURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              fileURL.lastPathComponent.hasPrefix("grant-"), fileURL.pathExtension == "json" else {
            throw CocoaError(.fileReadNoPermission)
        }
        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == getuid(),
              attributes.st_mode & 0o077 == 0, attributes.st_size <= 1_048_576 else {
            throw CocoaError(.fileReadNoPermission)
        }
        var data = Data()
        while data.count <= 1_048_576, let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
        }
        guard data.count <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
        let payload = try JSONDecoder().decode(ChildProcessGrantPayload.self, from: data)
        guard payload.version == 1, payload.files.count <= 32 else { throw CocoaError(.fileReadCorruptFile) }
        return payload
    }

    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
    deinit { close() }
}
