import Foundation

/// Protocol abstracting storage persistence for iCloud documents (allowing isolated hermetic unit testing)
public protocol iCloudStorageBackend: Sendable {
    func isCloudAvailable() -> Bool
    func readPayloadData() throws -> Data?
    func writePayloadData(_ data: Data) throws
    func removePayloadData() throws
    func lastModifiedDate() -> Date?
    func cloudVaultURL() -> URL?
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

/// Production iCloud Drive Ubiquity Container backend for macOS
public final class UbiquityCloudStorageBackend: iCloudStorageBackend, @unchecked Sendable {
    private let fallbackDirectory: URL
    private let fileName = "cloud_vault.json"
    private let backupFileName = "cloud_vault.backup.json"
    private let lock = NSLock()
    
    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Standard macOS CloudDocs directory for iCloud Drive
        self.fallbackDirectory = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/AetherTerm", isDirectory: true)
    }
    
    private var activeContainerURL: URL? {
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
    
    public func readPayloadData() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let container = activeContainerURL else {
            throw iCloudSyncError.cloudUnavailable("当前未检测到活跃的 iCloud 容器或 iCloud Drive 未登录")
        }
        let fileURL = container.appendingPathComponent(fileName)
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
        
        guard let container = activeContainerURL else {
            throw iCloudSyncError.cloudUnavailable("当前未检测到活跃的 iCloud 容器或 iCloud Drive 未登录")
        }
        let fileURL = container.appendingPathComponent(fileName)
        let backupURL = container.appendingPathComponent(backupFileName)
        
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
        
        guard let container = activeContainerURL else { return }
        let fileURL = container.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
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
