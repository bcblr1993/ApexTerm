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

/// Live resource utilization metrics parsed from `docker/podman stats --no-stream`.
public struct ContainerStatsItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { containerIdOrName }
    public let containerIdOrName: String
    public let name: String
    public let cpuPercentText: String
    public let cpuPercent: Double
    public let memUsageText: String
    public let memPercentText: String
    public let memPercent: Double
    public let netIOText: String
    public let blockIOText: String
    public let pidsText: String

    public init(
        containerIdOrName: String,
        name: String,
        cpuPercentText: String,
        cpuPercent: Double,
        memUsageText: String,
        memPercentText: String,
        memPercent: Double,
        netIOText: String,
        blockIOText: String,
        pidsText: String = ""
    ) {
        self.containerIdOrName = containerIdOrName
        self.name = name
        self.cpuPercentText = cpuPercentText
        self.cpuPercent = cpuPercent
        self.memUsageText = memUsageText
        self.memPercentText = memPercentText
        self.memPercent = memPercent
        self.netIOText = netIOText
        self.blockIOText = blockIOText
        self.pidsText = pidsText
    }
}

/// Represents a Docker Compose project stack discovered via `docker compose ls`.
public struct DockerComposeStackItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { name }
    public let name: String
    public let status: String
    public let configFiles: String

    public var isRunning: Bool {
        status.lowercased().contains("running")
    }

    public init(name: String, status: String, configFiles: String = "") {
        self.name = name
        self.status = status
        self.configFiles = configFiles
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
    public var stats: ContainerStatsItem?

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
        runtime: ContainerRuntime = .docker,
        stats: ContainerStatsItem? = nil
    ) {
        self.id = id
        self.shortId = shortId ?? String(id.prefix(12))
        self.name = name
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.runtime = runtime
        self.stats = stats
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
