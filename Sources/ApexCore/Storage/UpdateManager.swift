import Foundation
import Combine
import AppKit

/// Release information payload
public struct ReleaseInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String { version }
    public let version: String
    public let releaseDate: String
    public let title: String
    public let notes: String
    public let downloadUrl: String
    public let packageUrl: String?
    public let packageName: String?
    public let packageSize: Int64?
    public let mandatory: Bool
    
    public init(
        version: String,
        releaseDate: String,
        title: String,
        notes: String,
        downloadUrl: String,
        packageUrl: String? = nil,
        packageName: String? = nil,
        packageSize: Int64? = nil,
        mandatory: Bool = false
    ) {
        self.version = version
        self.releaseDate = releaseDate
        self.title = title
        self.notes = notes
        self.downloadUrl = downloadUrl
        self.packageUrl = packageUrl
        self.packageName = packageName
        self.packageSize = packageSize
        self.mandatory = mandatory
    }
}

/// Status of update checks and in-app update progression
public enum UpdateCheckStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case updateAvailable(ReleaseInfo)
    case downloading(progress: Double, totalBytes: Int64, receivedBytes: Int64)
    case preparing(message: String)
    case readyToRestart(version: String, stagingAppURL: URL)
    case failed(String)
}

/// Central Update Manager handling version queries, semantic version diffing,
/// in-app background downloading, staging verification, and relaunch installation.
@MainActor
public final class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()
    public let distributionChannel: DistributionChannel
    
    @Published public var status: UpdateCheckStatus = .idle
    @Published public var isUpdateSheetPresented: Bool = false
    @Published public var latestRelease: ReleaseInfo? = nil
    @Published public var lastCheckedDate: Date? = nil
    @Published public var isChecking: Bool = false
    @Published public var isDownloading: Bool = false
    @Published public var currentStagedAppURL: URL? = nil
    
    public var customCurrentVersion: String? = nil
    
    public var currentVersion: String {
        if let custom = customCurrentVersion {
            return custom
        }
        if let bundleId = Bundle.main.bundleIdentifier, bundleId.lowercased().contains("apexterm"),
           let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return ver
        }
        return "1.4.0"
    }
    
    public var currentBuild: String {
        if let bundleId = Bundle.main.bundleIdentifier, bundleId.lowercased().contains("apexterm"),
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return build
        }
        return "2026092801"
    }
    
    /// Default releases URL (GitHub Releases API)
    public var updateManifestURL: URL? = URL(string: "https://api.github.com/repos/bcblr1993/ApexTerm/releases/latest")
    
    public typealias FetchHandler = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias DownloadHandler = @Sendable (
        URL,
        @escaping @Sendable (_ receivedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws -> URL
    public typealias ExtractHandler = @Sendable (URL, String) throws -> URL

    private let fetch: FetchHandler
    private let downloadFileHandler: DownloadHandler?
    private let extractPackageHandler: ExtractHandler?
    
    private var activeDownloadSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?

    public init(distributionChannel: DistributionChannel = .current) {
        self.distributionChannel = distributionChannel
        self.fetch = { try await URLSession.shared.data(for: $0) }
        self.downloadFileHandler = nil
        self.extractPackageHandler = nil
    }

    public init(
        distributionChannel: DistributionChannel = .current,
        fetch: @escaping FetchHandler,
        downloadHandler: DownloadHandler? = nil,
        extractHandler: ExtractHandler? = nil
    ) {
        self.distributionChannel = distributionChannel
        self.fetch = fetch
        self.downloadFileHandler = downloadHandler
        self.extractPackageHandler = extractHandler
    }
    
    /// Compares two semver strings like "1.2.1" and "1.2.0" or "v2.0.0" and "1.9.9"
    /// Returns true if `v1` is strictly newer/higher than `v2`.
    nonisolated public static func isVersion(_ v1: String, higherThan v2: String) -> Bool {
        let clean1 = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        let clean2 = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        
        guard let core1 = clean1.split(separator: "-").first,
              let core2 = clean2.split(separator: "-").first else { return false }
        let parts1 = core1.split(separator: ".").compactMap { Int($0) }
        let parts2 = core2.split(separator: ".").compactMap { Int($0) }
        
        let maxCount = max(parts1.count, parts2.count)
        for i in 0..<maxCount {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        return false
    }
    
    /// Trigger an update check. If `manual` is true, prompts sheet even when up-to-date.
    public func checkForUpdates(manual: Bool = false) async {
        guard distributionChannel == .direct else {
            status = .failed("更新由 App Store 管理，请在 App Store 查看。")
            return
        }
        guard !isChecking else { return }
        isChecking = true
        status = .checking
        if manual { isUpdateSheetPresented = true }
        lastCheckedDate = Date()
        
        guard let url = updateManifestURL else {
            isChecking = false
            status = .failed("未配置更新检查地址")
            if manual { isUpdateSheetPresented = true }
            return
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8.0
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            request.setValue("AetherTerm-Updater", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await fetch(request)
            
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                self.isChecking = false
                self.status = .failed("更新服务器返回错误，请稍后重试")
                if manual { self.isUpdateSheetPresented = true }
                return
            }
            
            if let release = try? parseGitHubRelease(data: data) {
                self.latestRelease = release
                if Self.isVersion(release.version, higherThan: self.currentVersion) {
                    self.status = .updateAvailable(release)
                    self.isUpdateSheetPresented = true
                } else {
                    self.status = .upToDate(currentVersion: self.currentVersion)
                    if manual { self.isUpdateSheetPresented = true }
                }
            } else {
                self.status = .failed("无法读取更新信息，请稍后重试")
                if manual { self.isUpdateSheetPresented = true }
            }
        } catch {
            self.status = .failed(error.localizedDescription)
            if manual { self.isUpdateSheetPresented = true }
        }
        
        isChecking = false
    }
    
    /// Starts in-app one-click update: downloads archive, verifies bundle, and prepares for relaunch
    public func startInAppUpdate(release: ReleaseInfo? = nil) async {
        guard distributionChannel == .direct else {
            status = .failed("更新由 App Store 管理，请在 App Store 查看。")
            return
        }
        let rel = release ?? latestRelease
        guard let rel = rel else {
            self.status = .failed("未找到可更新的发布信息")
            return
        }
        
        guard let rawUrl = rel.packageUrl ?? (
            (rel.downloadUrl.hasSuffix(".tar.gz") || rel.downloadUrl.hasSuffix(".dmg")) ? rel.downloadUrl : nil
        ), let packageURL = URL(string: rawUrl) else {
            self.status = .failed("当前发布中未检测到直接二进制更新包，请前往 GitHub 网页下载。")
            return
        }
        
        let filename = rel.packageName ?? packageURL.lastPathComponent
        self.isDownloading = true
        self.status = .downloading(progress: 0.0, totalBytes: rel.packageSize ?? 0, receivedBytes: 0)
        self.isUpdateSheetPresented = true
        
        do {
            let downloadedArchive: URL
            if let customDownloader = self.downloadFileHandler {
                downloadedArchive = try await customDownloader(packageURL) { [weak self] received, total in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.isDownloading else { return }
                        let progress = total > 0 ? min(1.0, max(0.0, Double(received) / Double(total))) : 0.0
                        self.status = .downloading(progress: progress, totalBytes: total, receivedBytes: received)
                    }
                }
            } else {
                downloadedArchive = try await performDownload(from: packageURL, suggestedFilename: filename) { [weak self] received, total in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.isDownloading else { return }
                        let progress = total > 0 ? min(1.0, max(0.0, Double(received) / Double(total))) : 0.0
                        self.status = .downloading(progress: progress, totalBytes: total, receivedBytes: received)
                    }
                }
            }
            
            guard isDownloading else {
                try? FileManager.default.removeItem(at: downloadedArchive)
                return
            }
            
            self.status = .preparing(message: "正在校验并解压安装包...")
            
            let extractor = self.extractPackageHandler ?? Self.defaultExtractPackage
            let stagedAppURL = try await Task.detached(priority: .userInitiated) {
                try extractor(downloadedArchive, rel.version)
            }.value
            
            // Clean up temporary downloaded archive
            try? FileManager.default.removeItem(at: downloadedArchive)
            
            self.currentStagedAppURL = stagedAppURL
            self.isDownloading = false
            self.status = .readyToRestart(version: rel.version, stagingAppURL: stagedAppURL)
            self.isUpdateSheetPresented = true
        } catch is CancellationError {
            self.isDownloading = false
            self.status = .updateAvailable(rel)
        } catch {
            self.isDownloading = false
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                self.status = .updateAvailable(rel)
            } else {
                self.status = .failed("更新包处理失败: \(error.localizedDescription)")
            }
        }
    }
    
    /// Cancels active in-app download
    public func cancelUpdate() {
        guard isDownloading else { return }
        isDownloading = false
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadSession = nil
        if let rel = latestRelease {
            status = .updateAvailable(rel)
        } else {
            status = .idle
        }
    }
    
    /// Returns the target application URL to replace
    nonisolated public static func defaultTargetAppURL() -> URL {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" && !bundle.path.contains("/.build/") && !bundle.path.contains("/DerivedData/") {
            return bundle
        }
        return URL(fileURLWithPath: "/Applications/AetherTerm.app")
    }
    
    /// Executes detached update replacement script and restarts the application
    public func relaunchAndInstall(targetURL: URL? = nil) {
        guard distributionChannel == .direct else {
            status = .failed("更新由 App Store 管理，请在 App Store 查看。")
            return
        }
        guard case .readyToRestart(_, let stagingAppURL) = status else {
            return
        }
        
        let destination = targetURL ?? Self.defaultTargetAppURL()
        let pid = ProcessInfo.processInfo.processIdentifier
        
        let script = """
        #!/bin/bash
        PID=\(pid)
        STAGING="\(stagingAppURL.path)"
        TARGET="\(destination.path)"
        LOG="/tmp/apexterm_update.log"

        echo "[$(date)] Starting update replacement for PID $PID..." > "$LOG"
        echo "[$(date)] Staging: $STAGING" >> "$LOG"
        echo "[$(date)] Target:  $TARGET" >> "$LOG"

        WAIT_COUNT=0
        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.1
            WAIT_COUNT=$((WAIT_COUNT + 1))
            if [ "$WAIT_COUNT" -ge 100 ]; then
                kill -9 "$PID" 2>/dev/null || true
                break
            fi
        done

        sleep 0.2

        if [ -d "$TARGET" ]; then
            rm -rf "$TARGET" 2>> "$LOG"
        fi

        cp -R "$STAGING" "$TARGET" 2>> "$LOG"
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

        STAGING_PARENT="$(dirname "$STAGING")"
        rm -rf "$STAGING_PARENT" 2>/dev/null

        echo "[$(date)] Launching updated application..." >> "$LOG"
        open "$TARGET" 2>> "$LOG"

        rm -f "$0" 2>/dev/null
        exit 0
        """
        
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apexterm_relaunch_\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptURL.path]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let app = NSApp {
                    app.terminate(nil)
                }
                exit(0)
            }
        } catch {
            self.status = .failed("启动更新安装进程失败: \(error.localizedDescription)")
        }
    }
    
    /// Unpacks, verifies, and stages the downloaded update archive
    nonisolated public static func defaultExtractPackage(archiveURL: URL, version: String) throws -> URL {
        let fileManager = FileManager.default
        let stagingDir = fileManager.temporaryDirectory
            .appendingPathComponent("ApexTerm_Staging_\(UUID().uuidString)")
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        
        let pathLower = archiveURL.path.lowercased()
        let isTar = pathLower.hasSuffix(".tar.gz") || pathLower.hasSuffix(".tgz")
        let isDmg = pathLower.hasSuffix(".dmg")
        
        if isTar {
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xzf", archiveURL.path, "-C", stagingDir.path]
            try tarProcess.run()
            tarProcess.waitUntilExit()
            guard tarProcess.terminationStatus == 0 else {
                throw NSError(domain: "UpdateManager", code: 101, userInfo: [NSLocalizedDescriptionKey: "解压更新包失败 (tar 退出码: \(tarProcess.terminationStatus))"])
            }
        } else if isDmg {
            let mountPoint = stagingDir.appendingPathComponent("mnt")
            try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            
            let hdiutil = Process()
            hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            hdiutil.arguments = ["attach", archiveURL.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
            try hdiutil.run()
            hdiutil.waitUntilExit()
            guard hdiutil.terminationStatus == 0 else {
                throw NSError(domain: "UpdateManager", code: 102, userInfo: [NSLocalizedDescriptionKey: "挂载更新磁盘镜像失败 (hdiutil 退出码: \(hdiutil.terminationStatus))"])
            }
            
            defer {
                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", mountPoint.path, "-force"]
                try? detach.run()
                detach.waitUntilExit()
            }
            
            let sourceApp = try Self.bundledUpdateApp(in: mountPoint)
            let destApp = stagingDir.appendingPathComponent(sourceApp.lastPathComponent)
            try fileManager.copyItem(at: sourceApp, to: destApp)
        } else {
            // Attempt tar extraction as fallback
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xzf", archiveURL.path, "-C", stagingDir.path]
            try tarProcess.run()
            tarProcess.waitUntilExit()
            guard tarProcess.terminationStatus == 0 else {
                throw NSError(domain: "UpdateManager", code: 104, userInfo: [NSLocalizedDescriptionKey: "不支持的更新包格式"])
            }
        }
        
        let appURL = try Self.bundledUpdateApp(in: stagingDir)
        
        // Validate Info.plist
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path),
              let plistData = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw NSError(domain: "UpdateManager", code: 106, userInfo: [NSLocalizedDescriptionKey: "安装包 Info.plist 损坏或缺失"])
        }
        
        guard plist["CFBundleIdentifier"] as? String == "com.apexterm.app" else {
            throw NSError(domain: "UpdateManager", code: 107, userInfo: [NSLocalizedDescriptionKey: "安装包应用标识不符 (非官方 AetherTerm)"])
        }
        
        // Validate executable file
        let execURL = appURL.appendingPathComponent("Contents/MacOS/ApexTerm")
        guard fileManager.fileExists(atPath: execURL.path) else {
            throw NSError(domain: "UpdateManager", code: 108, userInfo: [NSLocalizedDescriptionKey: "更新包中可执行主程序缺失"])
        }
        
        return appURL
    }

    // Keep reading old release archives while new disk images use the public name.
    nonisolated static func bundledUpdateApp(in directory: URL) throws -> URL {
        for name in ["AetherTerm.app", "ApexTerm.app"] {
            let app = directory.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return app
            }
        }
        throw NSError(domain: "UpdateManager", code: 105, userInfo: [NSLocalizedDescriptionKey: "更新包中未包含 AetherTerm.app"])
    }

    private func performDownload(
        from url: URL,
        suggestedFilename: String,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = DownloadCoordinator(
                suggestedFilename: suggestedFilename,
                onProgress: onProgress,
                continuation: continuation
            )
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60.0
            config.timeoutIntervalForResource = 600.0
            let session = URLSession(configuration: config, delegate: coordinator, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            
            Task { @MainActor in
                self.activeDownloadSession = session
                self.activeDownloadTask = task
                task.resume()
            }
        }
    }
    
    private func parseGitHubRelease(data: Data) throws -> ReleaseInfo? {
        struct GHAsset: Decodable {
            let name: String
            let size: Int64?
            let browser_download_url: String
        }
        
        struct GHRelease: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let published_at: String?
            let html_url: String
            let assets: [GHAsset]?
        }
        
        guard let gh = try? JSONDecoder().decode(GHRelease.self, from: data) else {
            return nil
        }
        
        let version = gh.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard let core = version.split(separator: "-", omittingEmptySubsequences: false).first else { return nil }
        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0) != nil }) else { return nil }
        let title = gh.name ?? "AetherTerm \(gh.tag_name)"
        let notes = gh.body ?? "包含稳定性增强与性能优化。"
        let date = gh.published_at?.prefix(10).description ?? ""
        
        var packageUrl: String? = nil
        var packageName: String? = nil
        var packageSize: Int64? = nil
        
        if let assets = gh.assets {
            // Prefer macOS arm64 tar.gz, then any tar.gz
            if let tarGz = assets.first(where: {
                let lower = $0.name.lowercased()
                return (lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")) && (lower.contains("arm64") || lower.contains("macos"))
            }) ?? assets.first(where: {
                let lower = $0.name.lowercased()
                return lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
            }) {
                packageUrl = tarGz.browser_download_url
                packageName = tarGz.name
                packageSize = tarGz.size
            } else if let dmg = assets.first(where: {
                let lower = $0.name.lowercased()
                return lower.hasSuffix(".dmg") && (lower.contains("arm64") || lower.contains("macos"))
            }) ?? assets.first(where: {
                $0.name.lowercased().hasSuffix(".dmg")
            }) {
                packageUrl = dmg.browser_download_url
                packageName = dmg.name
                packageSize = dmg.size
            }
        }
        
        return ReleaseInfo(
            version: version,
            releaseDate: date,
            title: title,
            notes: notes,
            downloadUrl: gh.html_url,
            packageUrl: packageUrl,
            packageName: packageName,
            packageSize: packageSize
        )
    }
}

private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let suggestedFilename: String
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()
    private var downloadedURL: URL?
    
    init(
        suggestedFilename: String,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.suggestedFilename = suggestedFilename
        self.onProgress = onProgress
        self.continuation = continuation
    }
    
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }
    
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexTermDownload_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let dest = tempDir.appendingPathComponent(suggestedFilename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            lock.lock()
            self.downloadedURL = dest
            lock.unlock()
        } catch {
            lock.lock()
            let cont = self.continuation
            self.continuation = nil
            lock.unlock()
            cont?.resume(throwing: error)
        }
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let cont = self.continuation
        let url = self.downloadedURL
        self.continuation = nil
        lock.unlock()
        
        session.finishTasksAndInvalidate()
        
        if let error = error {
            cont?.resume(throwing: error)
        } else if let url = url {
            cont?.resume(returning: url)
        } else {
            cont?.resume(throwing: URLError(.unknown))
        }
    }
}
