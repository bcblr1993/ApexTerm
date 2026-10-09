import Foundation
import Darwin

/// Keeps a security-scoped URL alive until an asynchronous operation has ended.
public final class FileAccessLease: @unchecked Sendable {
    public let url: URL
    private let grantURL: URL
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?

    init(url: URL, grantURL: URL? = nil, release: @escaping @Sendable () -> Void) {
        self.url = url
        self.grantURL = grantURL ?? url
        self.release = release
    }

    /// A normal bookmark carries an implicit grant to an inheriting child process.
    /// Persistent app-scoped bookmarks cannot be replaced by passing a path alone.
    public func childProcessGrant() throws -> ChildProcessFileGrant {
        try lock.withLock {
            guard release != nil else { throw CocoaError(.fileReadNoPermission) }
            let root = FileManager.default.fileExists(atPath: grantURL.path)
                ? grantURL : grantURL.deletingLastPathComponent()
            return ChildProcessFileGrant(path: root.path,
                bookmark: try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
    }

    public func close() {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { release = nil }
            return release
        }
        callback?()
    }

    deinit { close() }
}

struct BookmarkBackend: Sendable {
    let make: @Sendable (URL, Bool) throws -> Data
    let resolve: @Sendable (Data) throws -> (URL, Bool)
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    static let system = Self(
        make: { url, readOnly in
            var options: URL.BookmarkCreationOptions = [.withSecurityScope]
            if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
            return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        },
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Bookmarks are app preferences, never distributed resources or server credentials.
public final class FileAccessStore: @unchecked Sendable {
    public static let shared = FileAccessStore()
    private let defaults: UserDefaults
    private let backend: BookmarkBackend
    private let lock = NSLock()
    private let prefix = "sandbox.fileGrant."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backend = .system
    }

    init(defaults: UserDefaults, backend: BookmarkBackend) {
        self.defaults = defaults
        self.backend = backend
    }

    public func remember(_ url: URL, isDirectory: Bool = false, readOnly: Bool = false) throws {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let normalized = url.standardizedFileURL
        let started = backend.start(url)
        defer { if started { backend.stop(url) } }
        let data = try backend.make(url, readOnly)
        lock.withLock {
            defaults.set(["data": data, "directory": isDirectory, "readOnly": readOnly], forKey: prefix + normalized.path)
        }
    }

    public func acquire(_ url: URL) throws -> FileAccessLease {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let requested = url.standardizedFileURL
        var ancestor = requested
        while true {
            let record = lock.withLock { defaults.dictionary(forKey: prefix + ancestor.path) }
            if let record, let data = record["data"] as? Data,
               ancestor == requested || record["directory"] as? Bool == true {
                let (granted, stale) = try backend.resolve(data)
                guard granted.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                let started = backend.start(granted)
                do {
                    if stale || granted.standardizedFileURL.path != ancestor.path {
                        let updated = try backend.make(granted, record["readOnly"] as? Bool ?? false)
                        var refreshed = record
                        refreshed["data"] = updated
                        lock.withLock {
                            // Keep the old path alias and add the moved location for later transfers.
                            defaults.set(refreshed, forKey: prefix + ancestor.path)
                            defaults.set(refreshed, forKey: prefix + granted.standardizedFileURL.path)
                        }
                    }
                    let suffix = requested.pathComponents.dropFirst(ancestor.pathComponents.count)
                    let resolved = suffix.reduce(granted) { $0.appendingPathComponent($1) }
                    let backend = self.backend
                    return FileAccessLease(url: resolved, grantURL: granted) { if started { backend.stop(granted) } }
                } catch {
                    if started { backend.stop(granted) }
                    throw error
                }
            }
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }
        // Open/Save panels and Finder may provide a transient scoped URL without a saved bookmark.
        return try acquireSelected(url)
    }

    /// Use the exact URL returned by a panel, ignoring any moved bookmark alias.
    public func acquireSelected(_ url: URL) throws -> FileAccessLease {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let started = backend.start(url)
        let backend = self.backend
        return FileAccessLease(url: url) { if started { backend.stop(url) } }
    }

    /// Establish a bookmarkable file for an inheriting SSH helper. A Save panel
    /// can authorize a new file, but a bookmark to its unselected parent cannot
    /// carry that file grant. Existing content is never truncated here.
    public func prepareSelectedSave(_ url: URL) throws -> FileAccessLease {
        let lease = try acquireSelected(url)
        do {
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if descriptor >= 0 {
                Darwin.close(descriptor)
            } else if errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try remember(url)
            return lease
        } catch {
            lease.close()
            throw error
        }
    }
}
