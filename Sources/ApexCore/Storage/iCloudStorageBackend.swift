import Foundation

/// Protocol abstracting storage persistence for iCloud documents (allowing isolated hermetic unit testing)
public protocol iCloudStorageBackend: Sendable {
    func isCloudAvailable() -> Bool
    func readPayloadData() throws -> Data?
    func writePayloadData(_ data: Data) throws
    func removePayloadData() throws
    func lastModifiedDate() -> Date?
    func cloudVaultURL() -> URL?

    func readPayloadDataAsync() async throws -> Data?
    func writePayloadDataAsync(_ data: Data) async throws
}

public extension iCloudStorageBackend {
    func readPayloadDataAsync() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.readPayloadData())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func writePayloadDataAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.writePayloadData(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Standard file-system directory backed storage (ideal for hermetic testing or custom cloud folders)
public final class FileSystemCloudStorageBackend: iCloudStorageBackend, @unchecked Sendable {
    public let cloudDirectory: URL
    private let fileName = "cloud_vault.json"
    private let backupFileName = "cloud_vault.backup.json"
    private let lock = NSLock()
    
    public init(cloudDirectory: URL) {
        self.cloudDirectory = cloudDirectory
        try? FileManager.default.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
    }
    
    public func isCloudAvailable() -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: cloudDirectory.path, isDirectory: &isDir) && isDir.boolValue
    }
    
    public func cloudVaultURL() -> URL? {
        cloudDirectory.appendingPathComponent(fileName)
    }
    
    public func readPayloadData() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        
        let fileURL = cloudDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw iCloudSyncError.payloadCorrupted(error.localizedDescription)
        }
    }
    
    public func writePayloadData(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let fileURL = cloudDirectory.appendingPathComponent(fileName)
        let backupURL = cloudDirectory.appendingPathComponent(backupFileName)
        
        // If existing file is valid, backup first
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw iCloudSyncError.writeFailed(error.localizedDescription)
        }
    }
    
    public func removePayloadData() throws {
        lock.lock()
        defer { lock.unlock() }
        
        let fileURL = cloudDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
    
    public func lastModifiedDate() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        
        let fileURL = cloudDirectory.appendingPathComponent(fileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modDate
    }
}

/// Production iCloud Drive Ubiquity Container backend for macOS using `NSFileCoordinator`
/// and `.icloud` evicted-placeholder detection off-MainActor.
public final class UbiquityCloudStorageBackend: iCloudStorageBackend, @unchecked Sendable {
    private let fallbackDirectory: URL
    private let customContainerURL: URL?
    private let downloadTrigger: @Sendable (URL) throws -> Void
    private let fileName = "cloud_vault.json"
    private let backupFileName = "cloud_vault.backup.json"
    private let lock = NSLock()
    
    public init(
        customContainerURL: URL? = nil,
        downloadTrigger: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.customContainerURL = customContainerURL
        self.downloadTrigger = downloadTrigger ?? { url in
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Standard macOS CloudDocs directory for iCloud Drive
        self.fallbackDirectory = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/AetherTerm", isDirectory: true)
    }

    /// Returns the iCloud evicted placeholder URL (`.cloud_vault.json.icloud`) for a target file URL.
    public static func placeholderURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).icloud")
    }
    
    private var activeContainerURL: URL? {
        if let customContainerURL {
            try? FileManager.default.createDirectory(at: customContainerURL, withIntermediateDirectories: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: customContainerURL.path, isDirectory: &isDir), isDir.boolValue {
                return customContainerURL
            }
            return nil
        }

        if let ubiquity = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let documents = ubiquity.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            return documents
        }
        
        // Fallback to Mobile Documents/com~apple~CloudDocs/AetherTerm
        let cloudDocsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: cloudDocsRoot.path) {
            try? FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
            return fallbackDirectory
        }
        
        return nil
    }
    
    public func isCloudAvailable() -> Bool {
        return activeContainerURL != nil
    }
    
    public func cloudVaultURL() -> URL? {
        activeContainerURL?.appendingPathComponent(fileName)
    }

    public func readPayloadDataAsync() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.readPayloadData())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func writePayloadDataAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.writePayloadData(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func readPayloadData() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let container = activeContainerURL else {
            throw iCloudSyncError.cloudUnavailable("当前未检测到活跃的 iCloud 容器或 iCloud Drive 未登录")
        }
        let fileURL = container.appendingPathComponent(fileName)
        let placeholder = Self.placeholderURL(for: fileURL)

        let hasFile = FileManager.default.fileExists(atPath: fileURL.path)
        let hasPlaceholder = FileManager.default.fileExists(atPath: placeholder.path)

        if !hasFile && hasPlaceholder {
            // Trigger ubiquitous download before attempting coordinated read so evicted cloud vaults
            // are never mistaken for empty cloud state and overwritten.
            try? downloadTrigger(fileURL)
        } else if !hasFile && !hasPlaceholder {
            return nil
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readResult: Result<Data?, Error>?

        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { coordinatedURL in
            if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                do {
                    readResult = .success(try Data(contentsOf: coordinatedURL))
                } catch {
                    readResult = .failure(iCloudSyncError.payloadCorrupted(error.localizedDescription))
                }
            } else if FileManager.default.fileExists(atPath: placeholder.path) {
                readResult = .failure(
                    iCloudSyncError.cloudDownloadingPlaceholder(
                        "检测到未下载完成的 iCloud 占位文件 (\(placeholder.lastPathComponent))，已触发下载并中止本次写入以防覆盖云端数据"
                    )
                )
            } else {
                readResult = .success(nil)
            }
        }

        if let coordinationError {
            throw iCloudSyncError.payloadCorrupted(coordinationError.localizedDescription)
        }
        if let readResult {
            return try readResult.get()
        }
        return nil
    }
    
    public func writePayloadData(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard let container = activeContainerURL else {
            throw iCloudSyncError.cloudUnavailable("当前未检测到活跃的 iCloud 容器或 iCloud Drive 未登录")
        }
        let fileURL = container.appendingPathComponent(fileName)
        let backupURL = container.appendingPathComponent(backupFileName)
        let placeholder = Self.placeholderURL(for: fileURL)

        if !FileManager.default.fileExists(atPath: fileURL.path),
           FileManager.default.fileExists(atPath: placeholder.path) {
            try? downloadTrigger(fileURL)
            throw iCloudSyncError.cloudDownloadingPlaceholder(
                "云端存在尚未下载的 \(placeholder.lastPathComponent)，已拒绝覆盖写入"
            )
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?

        coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: coordinatedURL, to: backupURL)
            }

            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = iCloudSyncError.writeFailed(error.localizedDescription)
            }
        }

        if let coordinationError {
            throw iCloudSyncError.writeFailed(coordinationError.localizedDescription)
        }
        if let writeError {
            throw writeError
        }
    }
    
    public func removePayloadData() throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard let container = activeContainerURL else { return }
        let fileURL = container.appendingPathComponent(fileName)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var deleteError: Error?

        coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                do {
                    try FileManager.default.removeItem(at: coordinatedURL)
                } catch {
                    deleteError = error
                }
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let deleteError {
            throw deleteError
        }
    }
    
    public func lastModifiedDate() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let container = activeContainerURL else { return nil }
        let fileURL = container.appendingPathComponent(fileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modDate
    }
}
