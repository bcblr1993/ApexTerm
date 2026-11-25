import Foundation

/// Invocation channel governing which OpenSSH CLI flags are valid for the spawned tool.
/// In particular, macOS `/usr/bin/scp` does not accept `-A` (`ForwardAgent`).
public enum SSHInvocationChannel: Sendable, Equatable {
    case interactiveSSH
    case nonInteractiveSSH
    case scp
}

/// Pure, `Sendable` OpenSSH argument builder shared by PTY sessions and port-forwarding tunnels.
public enum SSHArgumentBuilder: Sendable {
    public static let maxJumpHops = 5

    public static func formatHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    public static func formatJumpSpecifier(_ hop: Session) -> String {
        "\(hop.username)@\(formatHost(hop.host)):\(hop.port)"
    }

    /// Resolves ordered jump hops up to `maxJumpHops`, detecting direct self-references and nested cycles.
    public static func resolveJumpChain(
        for session: Session,
        availableSessions: [Session],
        overrideSingleJump: Session? = nil
    ) -> (hops: [Session], hasCycle: Bool) {
        if let overrideSingleJump, session.jumpServerChain.count <= 1 {
            if overrideSingleJump.id == session.id {
                return ([], true)
            }
            return ([overrideSingleJump], false)
        }
        let chainIds = session.effectiveJumpServerChain
        guard !chainIds.isEmpty else { return ([], false) }

        let sessionById = Dictionary(uniqueKeysWithValues: availableSessions.map { ($0.id, $0) })
        var seen: Set<UUID> = [session.id]
        var resolved: [Session] = []

        func containsTransitiveCycle(_ id: UUID, visiting: inout Set<UUID>, safe: inout Set<UUID>) -> Bool {
            if id == session.id || visiting.contains(id) {
                return true
            }
            if safe.contains(id) {
                return false
            }
            visiting.insert(id)
            defer { visiting.remove(id) }
            if let node = sessionById[id] {
                for nextId in node.effectiveJumpServerChain {
                    if containsTransitiveCycle(nextId, visiting: &visiting, safe: &safe) {
                        return true
                    }
                }
            }
            safe.insert(id)
            return false
        }

        var safeNodes: Set<UUID> = []
        for jumpId in chainIds {
            if seen.contains(jumpId) {
                return (resolved, true)
            }
            seen.insert(jumpId)
            guard let hop = sessionById[jumpId], !hop.host.isEmpty else { continue }
            var visiting: Set<UUID> = []
            if containsTransitiveCycle(hop.id, visiting: &visiting, safe: &safeNodes) {
                return (resolved, true)
            }
            resolved.append(hop)
            if resolved.count >= maxJumpHops {
                break
            }
        }
        return (resolved, false)
    }

    /// Checks whether configuring `jumpChain` on `sessionId` introduces a direct or indirect jump cycle.
    public static func hasJumpCycle(
        startingAt sessionId: UUID,
        jumpChain: [UUID],
        allSessions: [Session]
    ) -> Bool {
        guard !jumpChain.isEmpty else { return false }
        let sessionById = Dictionary(uniqueKeysWithValues: allSessions.map { ($0.id, $0) })
        var seenDirect: Set<UUID> = [sessionId]
        var safeNodes: Set<UUID> = []

        func dfs(_ id: UUID, visiting: inout Set<UUID>) -> Bool {
            if id == sessionId || visiting.contains(id) {
                return true
            }
            if safeNodes.contains(id) {
                return false
            }
            visiting.insert(id)
            defer { visiting.remove(id) }
            guard let node = sessionById[id] else {
                safeNodes.insert(id)
                return false
            }
            for nextId in node.effectiveJumpServerChain {
                if dfs(nextId, visiting: &visiting) {
                    return true
                }
            }
            safeNodes.insert(id)
            return false
        }

        for hopId in jumpChain {
            if !seenDirect.insert(hopId).inserted { return true }
            var visiting: Set<UUID> = []
            if dfs(hopId, visiting: &visiting) {
                return true
            }
        }
        return false
    }

    /// Builds `-J user1@h1:p1,...` arguments when `proxyCommand` is not overriding proxy routing.
    public static func jumpFlagArguments(hops: [Session], proxyCommand: String?) -> [String] {
        let trimmedProxy = proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedProxy.isEmpty, !hops.isEmpty else { return [] }
        let spec = hops.prefix(maxJumpHops).map(formatJumpSpecifier).joined(separator: ",")
        guard !spec.isEmpty else { return [] }
        return ["-J", spec]
    }

    /// Builds `-A` (interactive SSH only), `-C`, and either `-o ProxyCommand=...` or multi-hop `-J`.
    public static func buildAdvancedOptions(
        for session: Session,
        channel: SSHInvocationChannel,
        resolvedJumpHops: [Session]
    ) -> [String] {
        var args: [String] = []
        // `/usr/bin/scp` rejects `-A`; non-interactive probes do not need agent forwarding.
        if channel == .interactiveSSH && session.forwardAgent {
            args.append("-A")
        }
        if session.compression {
            args.append("-C")
        }
        if let rawProxy = session.proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawProxy.isEmpty {
            let singleLine = rawProxy
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !singleLine.isEmpty {
                args.append(contentsOf: ["-o", "ProxyCommand=\(singleLine)"])
            }
        } else {
            args.append(contentsOf: jumpFlagArguments(hops: resolvedJumpHops, proxyCommand: nil))
        }
        return args
    }
}

/// Validates `ProxyCommand` binaries against App Store App Sandbox constraints.
public enum ProxyCommandValidator: Sendable {
    private static let sandboxAllowedCommands: Set<String> = [
        "nc", "/usr/bin/nc",
        "ssh", "/usr/bin/ssh",
        "openssl", "/usr/bin/openssl",
        "sh", "/bin/sh",
        "zsh", "/bin/zsh",
        "bash", "/bin/bash",
        "none"
    ]

    public static func sandboxWarning(for command: String?, isAppStore: Bool) -> String? {
        guard isAppStore,
              let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let firstToken = String(trimmed.split(whereSeparator: { $0.isWhitespace }).first ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !firstToken.isEmpty else { return nil }
        if sandboxAllowedCommands.contains(firstToken) {
            return nil
        }
        return "App Store 沙盒版仅支持系统内置工具（如 /usr/bin/nc、ssh）；外部工具（\(firstToken)）请使用直装 DMG 版。"
    }
}
