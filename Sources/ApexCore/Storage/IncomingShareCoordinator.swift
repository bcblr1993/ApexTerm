import Foundation
import UniformTypeIdentifiers

public extension UTType {
    /// Custom document UTType for encrypted or zero-credential `.aetherpack` connection share bundles.
    static var aetherPack: UTType {
        UTType(exportedAs: "com.apexterm.aetherpack", conformingTo: .json)
    }
}

/// Bridges menu commands, drag-and-drop, and Finder double-click document open events
/// into the active sidebar share export / import sheets, including cold-launch arrivals.
@MainActor
public final class IncomingShareCoordinator: ObservableObject {
    public static let shared = IncomingShareCoordinator()

    @Published public var pendingImportURL: URL?
    @Published public var openImportTrigger: Int = 0
    @Published public var openExportTrigger: Int = 0

    public init() {}

    /// Queues an optional share file URL and signals the UI to present the import wizard.
    public func requestImport(url: URL?) {
        pendingImportURL = url
        openImportTrigger += 1
    }

    /// Signals the UI to present the group share export wizard.
    public func requestExport() {
        openExportTrigger += 1
    }

    /// Returns and clears any queued URL awaiting initial presentation.
    public func consumePendingImportURL() -> URL? {
        let url = pendingImportURL
        pendingImportURL = nil
        return url
    }
}
