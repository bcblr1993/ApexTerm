import Foundation

/// Supported agentless container runtimes on remote hosts.
public enum ContainerRuntime: String, Codable, Sendable, Equatable, Hashable {
    case docker
    case podman

    public var displayName: String {
        switch self {
        case .docker: return "Docker"
        case .podman: return "Podman"
        }
    }
}

/// Represents a remote Docker or Podman container discovered via agentless SSH probe.
public struct ContainerItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let shortId: String
    public let name: String
    public let image: String
    public let state: String
    public let status: String
    public let ports: String
    public let runtime: ContainerRuntime

    public var isRunning: Bool {
        state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "running"
    }

    public init(
        id: String,
        shortId: String? = nil,
        name: String,
        image: String,
        state: String,
        status: String,
        ports: String = "",
        runtime: ContainerRuntime = .docker
    ) {
        self.id = id
        self.shortId = shortId ?? String(id.prefix(12))
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.runtime = runtime
    }
}

/// Lifecycle operations supported on remote containers.
public enum ContainerAction: String, Sendable, CaseIterable, Identifiable {
    case start
    case stop
    case restart

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        }
    }
}

/// Lifecycle operations supported on remote systemd units.
public enum SystemdServiceAction: String, Sendable, CaseIterable, Identifiable {
    case start
    case stop
    case restart
    case reload

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .start: return "启动 (start)"
        case .stop: return "停止 (stop)"
        case .restart: return "重启 (restart)"
        case .reload: return "重载 (reload)"
        }
    }
}

public extension SystemdServiceItem {
    /// Core system units that must never be stopped from the UI to prevent SSH/host lockouts.
    static let protectedStopUnitBases: Set<String> = [
        "sshd", "ssh", "systemd-journald", "systemd-udevd", "dbus", "dbus-broker", "systemd-logind"
    ]

    var normalizedUnitBase: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix(".service") {
            return String(trimmed.dropLast(".service".count))
        }
        return trimmed
    }

    var isProtectedForStop: Bool {
        Self.protectedStopUnitBases.contains(normalizedUnitBase)
    }
}
