import Foundation
import CryptoKit
import Darwin
import os
import ApexCore

/// Thread-safe, reference-counted pool of shared OpenSSH ControlMaster sockets.
///
/// Connections sharing the same `(user, host, port, jumpChainHash, keyFingerprint, proxyCommandHash)`
/// reuse a single authenticated ControlMaster socket, eliminating duplicate 2FA/TOTP prompts
/// and handshakes across PTY tabs, SFTP transfers, agentless probes, and connected batch hosts.
public final class SSHControlMasterPool: @unchecked Sendable {
    public static let shared = SSHControlMasterPool()

    private static let poolEnabledLock = OSAllocatedUnfairLock(initialState: true)

    /// Global toggle controlling whether `NativeSSHSession` acquires shared mux sockets from the pool.
    public static var isPoolEnabled: Bool {
        get { poolEnabledLock.withLock { $0 } }
        set { poolEnabledLock.withLock { $0 = newValue } }
    }

    /// Deterministic connection identity key governing ControlMaster socket sharing.
    public struct ConnectionKey: Hashable, Sendable, Equatable {
        public let user: String
        public let host: String
        public let port: Int
        public let jumpChainHash: String
        public let keyFingerprint: String
        public let proxyCommandHash: String

        public init(
            user: String,
            host: String,
            port: Int,
            jumpChainHash: String,
            keyFingerprint: String,
            proxyCommandHash: String
        ) {
            self.user = user
            self.host = host
            self.port = port
            self.jumpChainHash = jumpChainHash
            self.keyFingerprint = keyFingerprint
            self.proxyCommandHash = proxyCommandHash
        }

        /// Lowercase SHA-256 hex digest of all connection dimensions.
        public var digestHex: String {
            let canonical = [
                user,
                host,
                String(port),
                jumpChainHash,
                keyFingerprint,
                proxyCommandHash
            ].joined(separator: "\u{0000}")
            let digest = SHA256.hash(data: Data(canonical.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        /// Short 8-hex identifier (`s-<8hex>`) used for direct-distribution `/tmp` sockets.
        public var directSocketIdentifier: String {
            "s-\(String(digestHex.prefix(8)))"
        }

        /// Short 6-hex suffix used by `SandboxSSHPaths` to form `apx-<6hex>` under App Store containers.
        public var sandboxHexIdentifier: String {
            String(digestHex.prefix(6))
        }
    }

    /// Active lease token returned by `acquireSocket(...)`. Releasing all leases tears down the master.
    public struct Lease: Sendable, Equatable {
        public let id: UUID
        public let key: ConnectionKey
        public let shortID: String
        public let socketPath: String
        public let controlSocketOption: String
        public let canUseControlSocket: Bool

        public init(
            id: UUID = UUID(),
            key: ConnectionKey,
            shortID: String,
            socketPath: String,
            controlSocketOption: String,
            canUseControlSocket: Bool
        ) {
            self.id = id
            self.key = key
            self.shortID = shortID
            self.socketPath = socketPath
            self.controlSocketOption = controlSocketOption
            self.canUseControlSocket = canUseControlSocket
        }
    }

    typealias SocketTeardownHandler = @Sendable (
        _ socketPath: String,
        _ controlOption: String,
        _ destination: String,
        _ port: Int,
        _ distributionChannel: DistributionChannel,
        _ bridgeExecutableURL: URL,
        _ sandboxPaths: SandboxSSHPaths
    ) -> Void

    private struct PoolEntry {
        var leaseIDs: Set<UUID>
        let shortID: String
        let socketPath: String
        let controlSocketOption: String
        let canUseControlSocket: Bool
        let destination: String
        let port: Int
        let distributionChannel: DistributionChannel
        let bridgeExecutableURL: URL
        let sandboxPaths: SandboxSSHPaths
    }

    private let lock = NSLock()
    private var entries: [ConnectionKey: PoolEntry] = [:]
    private let directSocketDirectory: URL
    private let teardownHandler: SocketTeardownHandler

    public convenience init(directSocketDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)) {
        self.init(directSocketDirectory: directSocketDirectory, teardownHandler: nil)
    }

    init(
        directSocketDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true),
        teardownHandler: SocketTeardownHandler? = nil
    ) {
        self.directSocketDirectory = directSocketDirectory
        self.teardownHandler = teardownHandler ?? Self.defaultPerformControlSocketExit
    }

    // MARK: - Key Construction

    public static func makeKey(for session: Session, resolvedJumpHops: [Session] = []) -> ConnectionKey {
        let normalizedUser = session.username.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalizedHost = session.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedHost.hasPrefix("[") && normalizedHost.hasSuffix("]") && normalizedHost.count >= 2 {
            normalizedHost = String(normalizedHost.dropFirst().dropLast())
        }

        let jumpSpec: String
        if resolvedJumpHops.isEmpty {
            let chainIds = session.effectiveJumpServerChain
            jumpSpec = chainIds.isEmpty ? "none" : chainIds.map(\.uuidString).joined(separator: ",")
        } else {
            jumpSpec = resolvedJumpHops
                .map { "\($0.username)@\($0.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\($0.port)" }
                .joined(separator: ",")
        }
        let jumpChainHash = shortSHA256(jumpSpec)

        let keyFingerprintInput: String
        switch session.authMethod {
        case .privateKey(let keyRef, _):
            keyFingerprintInput = "key:\(normalizeAuthPath(keyRef))"
        case .certificate(let keyRef, let certPath, _):
            keyFingerprintInput = "cert:\(normalizeAuthPath(keyRef))|\(normalizeAuthPath(certPath))"
        case .password(let ref):
            keyFingerprintInput = "pw:\(ref)"
        case .agent:
            keyFingerprintInput = "agent"
        case .none:
            keyFingerprintInput = "none"
        }
        let keyFingerprint = shortSHA256(keyFingerprintInput)

        let proxyRaw = session.proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let proxyCommandHash = shortSHA256(proxyRaw.isEmpty ? "none" : proxyRaw)

        return ConnectionKey(
            user: normalizedUser,
            host: normalizedHost,
            port: session.port,
            jumpChainHash: jumpChainHash,
            keyFingerprint: keyFingerprint,
            proxyCommandHash: proxyCommandHash
        )
    }

    private static func normalizeAuthPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.path + "/" + String(trimmed.dropFirst(2))
        }
        if trimmed == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return trimmed
    }

    private static func shortSHA256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func destinationHost(for session: Session) -> String {
        let trimmed = session.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    // MARK: - Lease Lifecycle

    public func acquireSocket(
        for session: Session,
        resolvedJumpHops: [Session] = [],
        distributionChannel: DistributionChannel = .current,
        sandboxHomeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        sandboxTemporaryURL: URL = FileManager.default.temporaryDirectory,
        bridgeExecutableURL: URL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/MacOS/ApexSSHBridge")
    ) -> Lease {
        let key = Self.makeKey(for: session, resolvedJumpHops: resolvedJumpHops)
        let leaseID = UUID()
        let destination = "\(session.username)@\(Self.destinationHost(for: session))"

        lock.lock()
        defer { lock.unlock() }

        if var existing = entries[key] {
            existing.leaseIDs.insert(leaseID)
            entries[key] = existing
            return Lease(
                id: leaseID,
                key: key,
                shortID: existing.shortID,
                socketPath: existing.socketPath,
                controlSocketOption: existing.controlSocketOption,
                canUseControlSocket: existing.canUseControlSocket
            )
        }

        let sandboxPaths = SandboxSSHPaths(
            home: sandboxHomeURL,
            temporary: sandboxTemporaryURL,
            identifier: key.sandboxHexIdentifier
        )

        let shortID: String
        let socketPath: String
        let controlOpt: String
        let canUseSocket: Bool

        if distributionChannel == .appStore {
            shortID = sandboxPaths.controlSocket.lastPathComponent
            socketPath = sandboxPaths.controlSocket.path
            controlOpt = sandboxPaths.controlSocketOption
            canUseSocket = sandboxPaths.canUseControlSocket
        } else {
            shortID = key.directSocketIdentifier
            let url = directSocketDirectory.appendingPathComponent(shortID, isDirectory: false)
            socketPath = url.path
            canUseSocket = socketPath.utf8.count + 17 < 104
            controlOpt = canUseSocket ? "ControlPath=" + SandboxSSHEnvironment.quotedPath(socketPath) : "ControlPath=none"
        }

        let entry = PoolEntry(
            leaseIDs: [leaseID],
            shortID: shortID,
            socketPath: socketPath,
            controlSocketOption: controlOpt,
            canUseControlSocket: canUseSocket,
            destination: destination,
            port: session.port,
            distributionChannel: distributionChannel,
            bridgeExecutableURL: bridgeExecutableURL,
            sandboxPaths: sandboxPaths
        )
        entries[key] = entry

        return Lease(
            id: leaseID,
            key: key,
            shortID: shortID,
            socketPath: socketPath,
            controlSocketOption: controlOpt,
            canUseControlSocket: canUseSocket
        )
    }

    public func releaseSocket(_ lease: Lease) {
        releaseSocket(for: lease.key, leaseID: lease.id)
    }

    public func releaseSocket(for key: ConnectionKey, leaseID: UUID) {
        let entryToClose: PoolEntry? = {
            lock.lock()
            defer { lock.unlock() }
            guard var entry = entries[key] else { return nil }
            guard entry.leaseIDs.remove(leaseID) != nil else { return nil }
            if entry.leaseIDs.isEmpty {
                entries.removeValue(forKey: key)
                return entry
            }
            entries[key] = entry
            return nil
        }()

        if let entry = entryToClose {
            teardownHandler(
                entry.socketPath,
                entry.controlSocketOption,
                entry.destination,
                entry.port,
                entry.distributionChannel,
                entry.bridgeExecutableURL,
                entry.sandboxPaths
            )
        }
    }

    public func closeAll() {
        let drained: [PoolEntry] = {
            lock.lock()
            defer { lock.unlock() }
            let all = Array(entries.values)
            entries.removeAll()
            return all
        }()

        for entry in drained {
            teardownHandler(
                entry.socketPath,
                entry.controlSocketOption,
                entry.destination,
                entry.port,
                entry.distributionChannel,
                entry.bridgeExecutableURL,
                entry.sandboxPaths
            )
        }
    }

    public func activeLeaseCount(for key: ConnectionKey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.leaseIDs.count ?? 0
    }

    public func activeLeaseCount(for session: Session, resolvedJumpHops: [Session] = []) -> Int {
        activeLeaseCount(for: Self.makeKey(for: session, resolvedJumpHops: resolvedJumpHops))
    }

    public func hasActiveSocket(for session: Session, resolvedJumpHops: [Session] = []) -> Bool {
        let key = Self.makeKey(for: session, resolvedJumpHops: resolvedJumpHops)
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        guard let entry, !entry.leaseIDs.isEmpty, entry.canUseControlSocket else { return false }
        return FileManager.default.fileExists(atPath: entry.socketPath)
    }

    public var activeSocketCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var totalActiveLeaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.leaseIDs.count }
    }

    static func defaultPerformControlSocketExit(
        socketPath: String,
        controlOption: String,
        destination: String,
        port: Int,
        distributionChannel: DistributionChannel,
        bridgeExecutableURL: URL,
        sandboxPaths: SandboxSSHPaths
    ) {
        guard controlOption != "ControlPath=none",
              FileManager.default.fileExists(atPath: socketPath) else {
            return
        }
        let proc = Process()
        let args = ["-O", "exit", "-o", controlOption, "-p", "\(port)", destination]
        var grants: ChildProcessFileGrants?
        if distributionChannel == .appStore,
           FileManager.default.isExecutableFile(atPath: bridgeExecutableURL.path) {
            do {
                try sandboxPaths.prepare()
                let preparedArgs = try sandboxPaths.arguments(prependingTo: args, tool: "ssh")
                let createdGrants = try ChildProcessFileGrants(files: [], authentication: nil)
                grants = createdGrants
                proc.executableURL = bridgeExecutableURL
                proc.arguments = ["--tool", "ssh"] + preparedArgs
                var env = ProcessInfo.processInfo.environment
                env[ChildProcessFileGrants.environmentKey] = createdGrants.fileURL.path
                proc.environment = env
            } catch {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                proc.arguments = args
            }
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = args
        }
        defer { grants?.close() }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        if (try? proc.run()) != nil {
            for _ in 0..<30 where proc.isRunning {
                usleep(10_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                proc.waitUntilExit()
            }
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }
}
