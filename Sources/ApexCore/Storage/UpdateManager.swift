import Foundation
import Combine
import AppKit
import CryptoKit

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
    public let expectedSHA256: String?
    public let sha256SumsUrl: String?
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
        expectedSHA256: String? = nil,
        sha256SumsUrl: String? = nil,
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
        self.expectedSHA256 = expectedSHA256
        self.sha256SumsUrl = sha256SumsUrl
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
        return Bundle.apexResolvedAppVersion
    }
    
    public var currentBuild: String {
        if let bundleId = Bundle.main.bundleIdentifier, bundleId.lowercased().contains("apexterm"),
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return build
        }
        return "2026112601"
    }
    
    /// Default releases URL (GitHub Releases API)
    public var updateManifestURL: URL? = URL(string: "https://api.github.com/repos/bcblr1993/ApexTerm/releases/latest")

    /// Optional synchronous pre-exit cleanup hook invoked immediately before terminating for update relaunch.
    public var onBeforeTerminateForUpdate: (() -> Void)?
    
    public typealias FetchHandler = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias DownloadHandler = @Sendable (
        URL,
        @escaping @Sendable (_ receivedBytes: Int64, _ totalBytes: Int64) -> Void
    ) async throws -> URL
    public typealias ExtractHandler = @Sendable (URL, String) throws -> URL
    public typealias SignatureValidator = @Sendable (URL) throws -> Void
    public typealias SHA256Validator = @Sendable (URL, String) throws -> Void

    nonisolated public static let expectedTeamIdentifier = "5984KQD4D7"
    nonisolated public static let expectedBundleIdentifier = "com.apexterm.app"

    private let fetch: FetchHandler
    private let downloadFileHandler: DownloadHandler?
    private let extractPackageHandler: ExtractHandler?
    private let signatureValidator: SignatureValidator?
    private let sha256Validator: SHA256Validator
    
    private var activeDownloadSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?

    public init(distributionChannel: DistributionChannel = .current) {
        self.distributionChannel = distributionChannel
        self.fetch = { try await URLSession.shared.data(for: $0) }
        self.downloadFileHandler = nil
        self.extractPackageHandler = nil
        self.signatureValidator = Self.verifyCodeSignature(at:)
        self.sha256Validator = Self.verifyArchiveSHA256(at:expectedHex:)
    }

    public init(
        distributionChannel: DistributionChannel = .current,
        fetch: @escaping FetchHandler,
        downloadHandler: DownloadHandler? = nil,
        extractHandler: ExtractHandler? = nil,
        signatureValidator: SignatureValidator? = nil,
        sha256Validator: SHA256Validator? = nil
    ) {
        self.distributionChannel = distributionChannel
        self.fetch = fetch
        self.downloadFileHandler = downloadHandler
        self.extractPackageHandler = extractHandler
        if let signatureValidator {
            self.signatureValidator = signatureValidator
        } else if extractHandler == nil {
            self.signatureValidator = Self.verifyCodeSignature(at:)
        } else {
            self.signatureValidator = nil
        }
        self.sha256Validator = sha256Validator ?? Self.verifyArchiveSHA256(at:expectedHex:)
    }
    
    /// Compares two semver strings like "1.2.1" and "1.2.0" or "v2.0.0" and "1.9.9"
    /// Returns true if `v1` is strictly newer/higher than `v2`.
    nonisolated public static func isVersion(_ v1: String, higherThan v2: String) -> Bool {
        func parse(_ raw: String) -> (parts: [Int], isPreRelease: Bool)? {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
            let withoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
            let splitPre = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = String(splitPre[0])
            let rawParts = core.split(separator: ".", omittingEmptySubsequences: false)
            guard !rawParts.isEmpty else { return nil }
            var nums: [Int] = []
            nums.reserveCapacity(rawParts.count)
            for token in rawParts {
                guard !token.isEmpty, token.allSatisfy(\.isNumber), let num = Int(token) else {
                    return nil
                }
                nums.append(num)
            }
            let hasPre = splitPre.count > 1 && !splitPre[1].isEmpty
            return (nums, hasPre)
        }

        guard let parsed1 = parse(v1), let parsed2 = parse(v2) else { return false }
        let maxCount = max(parsed1.parts.count, parsed2.parts.count)
        for i in 0..<maxCount {
            let p1 = i < parsed1.parts.count ? parsed1.parts[i] : 0
            let p2 = i < parsed2.parts.count ? parsed2.parts[i] : 0
            if p1 > p2 { return true }
            if p1 < p2 { return false }
        }
        // SemVer: a final release outranks a pre-release of the same core (1.2.0 > 1.2.0-beta).
        return !parsed1.isPreRelease && parsed2.isPreRelease
    }
    
    /// Trigger an update check. If `manual` is true, prompts sheet even when up-to-date.
    /// If `promptSheet` is explicitly provided, it controls whether `isUpdateSheetPresented` is raised.
    public func checkForUpdates(manual: Bool = false, promptSheet: Bool? = nil) async {
        let shouldPrompt = promptSheet ?? manual
        guard distributionChannel == .direct else {
            status = .failed("更新由 App Store 管理，请在 App Store 查看。")
            return
        }
        guard !isChecking else { return }
        isChecking = true
        status = .checking
        if shouldPrompt { isUpdateSheetPresented = true }
        lastCheckedDate = Date()
        
        guard let url = updateManifestURL else {
            isChecking = false
            status = .failed("未配置更新检查地址")
            if shouldPrompt { isUpdateSheetPresented = true }
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
                if shouldPrompt { self.isUpdateSheetPresented = true }
                return
            }
            
            if let release = try? parseGitHubRelease(data: data) {
                self.latestRelease = release
                if Self.isVersion(release.version, higherThan: self.currentVersion) {
                    self.status = .updateAvailable(release)
                    if promptSheet ?? true {
                        self.isUpdateSheetPresented = true
                    }
                } else {
                    self.status = .upToDate(currentVersion: self.currentVersion)
                    if shouldPrompt { self.isUpdateSheetPresented = true }
                }
            } else {
                self.status = .failed("无法读取更新信息，请稍后重试")
                if shouldPrompt { self.isUpdateSheetPresented = true }
            }
        } catch {
            self.status = .failed(error.localizedDescription)
            if shouldPrompt { self.isUpdateSheetPresented = true }
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

            do {
                let expectedDigest: String?
                if let explicit = rel.expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
                    expectedDigest = explicit
                } else if let sumsUrlStr = rel.sha256SumsUrl, let sumsURL = URL(string: sumsUrlStr) {
                    var req = URLRequest(url: sumsURL)
                    req.timeoutInterval = 15.0
                    req.setValue("AetherTerm-Updater", forHTTPHeaderField: "User-Agent")
                    let (sumsData, sumsResp) = try await fetch(req)
                    guard let http = sumsResp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                          let sumsText = String(data: sumsData, encoding: .utf8),
                          let parsed = Self.parseExpectedSHA256(from: sumsText, filename: filename) else {
                        throw NSError(domain: "UpdateManager", code: 109, userInfo: [NSLocalizedDescriptionKey: "更新包 SHA-256 校验清单解析失败"])
                    }
                    expectedDigest = parsed
                } else {
                    expectedDigest = nil
                }

                if let expectedDigest {
                    let shaValidator = self.sha256Validator
                    try await Task.detached(priority: .userInitiated) {
                        try shaValidator(downloadedArchive, expectedDigest)
                    }.value
                }
            } catch {
                try? FileManager.default.removeItem(at: downloadedArchive)
                throw error
            }
            
            let extractor = self.extractPackageHandler ?? Self.defaultExtractPackage
            let stagedAppURL: URL
            do {
                stagedAppURL = try await Task.detached(priority: .userInitiated) {
                    try extractor(downloadedArchive, rel.version)
                }.value
            } catch {
                try? FileManager.default.removeItem(at: downloadedArchive)
                throw error
            }
            
            // Clean up temporary downloaded archive
            try? FileManager.default.removeItem(at: downloadedArchive)

            if let sigValidator = self.signatureValidator {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try sigValidator(stagedAppURL)
                    }.value
                } catch {
                    try? FileManager.default.removeItem(at: stagedAppURL.deletingLastPathComponent())
                    throw error
                }
            }

            guard isDownloading else {
                try? FileManager.default.removeItem(at: stagedAppURL.deletingLastPathComponent())
                return
            }
            
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
    
    /// Distributed notification name used to wake and focus an already-running instance.
    nonisolated public static let activateMainWindowNotificationName = "com.apexterm.app.ActivateMainWindow"

    /// Determines whether single-instance enforcement should be active for the current launch environment.
    nonisolated public static func shouldEnforceSingleInstance(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return false
        }
        if environment["APEX_UI_TEST_REOPEN"] == "1"
            || environment["APEX_ALLOW_MULTIPLE_INSTANCES"] == "1"
            || environment["APEX_QA_UI_RUN_ID"] != nil {
            return false
        }
        return true
    }

    /// Returns true when the app bundle resides inside a transient build directory (`.build` or `DerivedData`).
    nonisolated public static func isTransientBuildBundleURL(_ bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        let path = bundleURL.path
        return path.contains("/.build/") || path.contains("/DerivedData/")
    }

    /// When launched from a transient build bundle while `/Applications/AetherTerm.app` is installed,
    /// returns the canonical `/Applications/AetherTerm.app` URL so LaunchServices/Dock never runs two bundles.
    nonisolated public static func canonicalRedirectAppURL(
        currentBundleURL: URL,
        installedAppURL: URL = URL(fileURLWithPath: "/Applications/AetherTerm.app"),
        installedExists: Bool
    ) -> URL? {
        guard installedExists, isTransientBuildBundleURL(currentBundleURL) else {
            return nil
        }
        guard currentBundleURL.standardizedFileURL != installedAppURL.standardizedFileURL else {
            return nil
        }
        return installedAppURL
    }

    /// Returns PIDs of other active instances matching the same bundle identifier.
    nonisolated public static func otherRunningInstancePIDs(
        bundleIdentifier: String = "com.apexterm.app",
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        runningApps: [(pid: pid_t, bundleIdentifier: String?, isTerminated: Bool)]
    ) -> [pid_t] {
        runningApps.compactMap { app in
            guard !app.isTerminated,
                  app.pid != currentPID,
                  app.bundleIdentifier == bundleIdentifier else {
                return nil
            }
            return app.pid
        }
    }

    /// Returns the target application URL to replace
    nonisolated public static func defaultTargetAppURL() -> URL {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" && !Self.isTransientBuildBundleURL(bundle) {
            return Self.brandedInstallationURL(for: bundle)
        }
        return URL(fileURLWithPath: "/Applications/AetherTerm.app")
    }
    
    /// Preserve custom installation folders while migrating the historical bundle name.
    nonisolated static func brandedInstallationURL(for current: URL) -> URL {
        guard current.lastPathComponent == "ApexTerm.app" else { return current }
        return current.deletingLastPathComponent().appendingPathComponent("AetherTerm.app", isDirectory: true)
    }

    /// Copy before replacing either installed name; keep rollback copies outside Launchpad.
    nonisolated static func replacementScript(staging: URL, current: URL, destination: URL) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        return """
        STAGING=\(quote(staging.path))
        CURRENT=\(quote(current.path))
        TARGET=\(quote(destination.path))
        WORK=$(mktemp -d "$(dirname "$TARGET")/.aetherterm-install.XXXXXX") || exit 1
        BACKUP=$(mktemp -d /tmp/aetherterm-rollback.XXXXXX) || { rmdir "$WORK"; exit 1; }
        rollback() {
            if [ -d "$BACKUP/previous" ]; then
                rm -rf "$TARGET"
                mv "$BACKUP/previous" "$TARGET"
            fi
            if [ -d "$BACKUP/legacy" ]; then mv "$BACKUP/legacy" "$CURRENT"; fi
            rm -rf "$WORK"
            rmdir "$BACKUP" 2>/dev/null || true
        }
        trap rollback EXIT
        cp -R "$STAGING" "$WORK/AetherTerm.app" || exit 1
        # Refuse to overwrite an unrelated application at the branded destination.
        if [ -e "$TARGET" ]; then
            ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist") || exit 1
            [ "$ID" = 'com.apexterm.app' ] || exit 1
            mv "$TARGET" "$BACKUP/previous" || exit 1
        fi
        if [ "$CURRENT" != "$TARGET" ] && { [ "$(basename "$CURRENT")" = "ApexTerm.app" ] || [ "$(basename "$CURRENT")" = "AetherTerm.app" ]; } && [ -d "$CURRENT" ]; then
            OLD_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CURRENT/Contents/Info.plist") || exit 1
            [ "$OLD_ID" = 'com.apexterm.app' ] || exit 1
            mv "$CURRENT" "$BACKUP/legacy" || exit 1
        fi
        mv "$WORK/AetherTerm.app" "$TARGET" || exit 1
        trap - EXIT
        rmdir "$WORK"
        # Backups have no .app suffix and remain available for rollback.
        """
    }

    /// Returns the private per-user update log file URL under `~/Library/Logs/AetherTerm/update.log` (0700 dir).
    nonisolated public static func defaultUpdateLogURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        let logDir = homeDirectory
            .appendingPathComponent("Library/Logs/AetherTerm", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(logDir.path, 0o700)
        return logDir.appendingPathComponent("update.log")
    }

    /// Invokes synchronous pre-exit cleanup before terminating for update installation.
    public func runPreExitCleanupForUpdate() {
        onBeforeTerminateForUpdate?()
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
        
        let current = targetURL ?? Bundle.main.bundleURL
        let destination = targetURL.map(Self.brandedInstallationURL(for:)) ?? Self.defaultTargetAppURL()
        let pid = ProcessInfo.processInfo.processIdentifier

        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let logURL: URL
        do {
            logURL = try Self.defaultUpdateLogURL()
        } catch {
            self.status = .failed("无法创建更新日志目录: \(error.localizedDescription)")
            return
        }
        
        let script = """
        #!/bin/bash
        PID=\(pid)
        LOG=\(quote(logURL.path))

        umask 077
        echo "[$(date)] Starting update replacement for PID $PID..." > "$LOG"

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

        \(Self.replacementScript(staging: stagingAppURL, current: current, destination: destination))

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
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.runPreExitCleanupForUpdate()
                if let app = NSApp {
                    app.terminate(nil)
                }
                exit(0)
            }
        } catch {
            self.status = .failed("启动更新安装进程失败: \(error.localizedDescription)")
        }
    }

    /// Computes streaming lowercase hex SHA-256 digest for `fileURL`.
    nonisolated public static func computeSHA256Hex(at fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies that `archiveURL` matches `expectedHex` (case-insensitive SHA-256).
    nonisolated public static func verifyArchiveSHA256(at archiveURL: URL, expectedHex: String) throws {
        let normalizedExpected = expectedHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedExpected.count == 64,
              normalizedExpected.allSatisfy({ $0.isHexDigit }) else {
            throw NSError(domain: "UpdateManager", code: 110, userInfo: [NSLocalizedDescriptionKey: "更新包 SHA-256 预期摘要格式无效"])
        }
        let actual = try computeSHA256Hex(at: archiveURL)
        guard actual == normalizedExpected else {
            throw NSError(domain: "UpdateManager", code: 111, userInfo: [NSLocalizedDescriptionKey: "更新包 SHA-256 完整性校验失败，文件可能已被损坏或篡改"])
        }
    }

    /// Parses `<sha256>  <filename>` lines from a `SHA256SUMS.txt` manifest.
    nonisolated public static func parseExpectedSHA256(from sumsText: String, filename: String) -> String? {
        let targetName = URL(fileURLWithPath: filename).lastPathComponent
        for rawLine in sumsText.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let hash = String(parts[0]).lowercased()
            var entryName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if entryName.hasPrefix("*") {
                entryName = String(entryName.dropFirst())
            }
            if URL(fileURLWithPath: entryName).lastPathComponent == targetName,
               hash.count == 64,
               hash.allSatisfy(\.isHexDigit) {
                return hash
            }
        }
        return nil
    }

    /// Verifies deep strict code signature, Bundle ID, and Apple Developer Team ID (`5984KQD4D7`) on a staged `.app`.
    nonisolated public static func verifyCodeSignature(at appURL: URL) throws {
        let requirement = "identifier \"\(expectedBundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""

        let verifyProc = Process()
        verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verifyProc.arguments = ["--verify", "--deep", "--strict", "--verbose=2", "-R", requirement, appURL.path]
        let verifyErr = Pipe()
        verifyProc.standardOutput = FileHandle.nullDevice
        verifyProc.standardError = verifyErr
        try verifyProc.run()
        let verifyData = verifyErr.fileHandleForReading.readDataToEndOfFile()
        verifyProc.waitUntilExit()

        guard verifyProc.terminationStatus == 0 else {
            let detail = String(data: verifyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "UpdateManager",
                code: 112,
                userInfo: [NSLocalizedDescriptionKey: "更新包代码签名或开发者团队校验失败 (\(expectedTeamIdentifier))\(detail.isEmpty ? "" : ": \(detail)")"]
            )
        }

        let infoProc = Process()
        infoProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        infoProc.arguments = ["-dv", "--verbose=4", appURL.path]
        let infoPipe = Pipe()
        infoProc.standardOutput = infoPipe
        infoProc.standardError = infoPipe
        try infoProc.run()
        let infoData = infoPipe.fileHandleForReading.readDataToEndOfFile()
        infoProc.waitUntilExit()

        let metadata = String(data: infoData, encoding: .utf8) ?? ""
        let lines = metadata.components(separatedBy: .newlines)
        let hasExpectedTeam = lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "TeamIdentifier=\(expectedTeamIdentifier)" }
        let hasExpectedId = lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Identifier=\(expectedBundleIdentifier)" }
        guard infoProc.terminationStatus == 0, hasExpectedTeam, hasExpectedId else {
            throw NSError(
                domain: "UpdateManager",
                code: 113,
                userInfo: [NSLocalizedDescriptionKey: "更新包开发者 Team ID (\(expectedTeamIdentifier)) 或应用标识不匹配"]
            )
        }
    }
    
    /// Unpacks, verifies, and stages the downloaded update archive
    nonisolated public static func defaultExtractPackage(archiveURL: URL, version: String) throws -> URL {
        let fileManager = FileManager.default
        let stagingDir = fileManager.temporaryDirectory
            .appendingPathComponent("ApexTerm_Staging_\(UUID().uuidString)")
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        var succeeded = false
        defer {
            if !succeeded {
                try? fileManager.removeItem(at: stagingDir)
            }
        }
        
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
        
        succeeded = true
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
        var sha256SumsUrl: String? = nil
        
        if let assets = gh.assets {
            sha256SumsUrl = assets.first(where: { $0.name.caseInsensitiveCompare("SHA256SUMS.txt") == .orderedSame })?.browser_download_url
            func isTarGz(_ name: String) -> Bool {
                let lower = name.lowercased()
                return lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
            }
            func isArm64(_ name: String) -> Bool {
                let lower = name.lowercased()
                return lower.contains("arm64") || lower.contains("aarch64")
            }
            // Prefer arm64 tar.gz, then macos/universal tar.gz, then any tar.gz
            if let tarGz = assets.first(where: { isTarGz($0.name) && isArm64($0.name) })
                ?? assets.first(where: { isTarGz($0.name) && ($0.name.lowercased().contains("universal") || $0.name.lowercased().contains("macos")) })
                ?? assets.first(where: { isTarGz($0.name) }) {
                packageUrl = tarGz.browser_download_url
                packageName = tarGz.name
                packageSize = tarGz.size
            } else if let dmg = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") && isArm64($0.name) })
                ?? assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") && ($0.name.lowercased().contains("universal") || $0.name.lowercased().contains("macos")) })
                ?? assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
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
            packageSize: packageSize,
            sha256SumsUrl: sha256SumsUrl
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
            if let url = url {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            cont?.resume(throwing: error)
        } else if let url = url {
            cont?.resume(returning: url)
        } else {
            cont?.resume(throwing: URLError(.unknown))
        }
    }
}
