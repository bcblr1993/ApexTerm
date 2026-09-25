import Foundation
import Combine

/// Release information payload
public struct ReleaseInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String { version }
    public let version: String
    public let releaseDate: String
    public let title: String
    public let notes: String
    public let downloadUrl: String
    public let mandatory: Bool
    
    public init(
        version: String,
        releaseDate: String,
        title: String,
        notes: String,
        downloadUrl: String,
        mandatory: Bool = false
    ) {
        self.version = version
        self.releaseDate = releaseDate
        self.title = title
        self.notes = notes
        self.downloadUrl = downloadUrl
        self.mandatory = mandatory
    }
}

/// Status of update checks
public enum UpdateCheckStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case updateAvailable(ReleaseInfo)
    case failed(String)
}

/// Central Update Manager handling version queries, semantic version diffing, and download links
@MainActor
public final class UpdateManager: ObservableObject {
    public static let shared = UpdateManager()
    
    @Published public var status: UpdateCheckStatus = .idle
    @Published public var isUpdateSheetPresented: Bool = false
    @Published public var latestRelease: ReleaseInfo? = nil
    @Published public var lastCheckedDate: Date? = nil
    @Published public var isChecking: Bool = false
    
    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0"
    }
    
    public var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    /// Default releases URL (GitHub Releases API or static JSON manifest)
    public var updateManifestURL: URL? = URL(string: "https://api.github.com/repos/apexterm/apexterm/releases/latest")
    
    public init() {}
    
    /// Compares two semver strings like "1.2.1" and "1.2.0" or "v2.0.0" and "1.9.9"
    /// Returns true if `v1` is strictly newer/higher than `v2`.
    public static func isVersion(_ v1: String, higherThan v2: String) -> Bool {
        let clean1 = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        let clean2 = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\r\n"))
        
        let parts1 = clean1.split(separator: "-")[0].split(separator: ".").compactMap { Int($0) }
        let parts2 = clean2.split(separator: "-")[0].split(separator: ".").compactMap { Int($0) }
        
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
        isChecking = true
        status = .checking
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
            request.setValue("ApexTerm-Updater", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let current = self.currentVersion
                self.isChecking = false
                self.status = .upToDate(currentVersion: current)
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
                self.status = .upToDate(currentVersion: self.currentVersion)
                if manual { self.isUpdateSheetPresented = true }
            }
        } catch {
            // On network failure or offline, if manual, inform user gracefully
            self.status = manual ? .upToDate(currentVersion: self.currentVersion) : .failed(error.localizedDescription)
            if manual { self.isUpdateSheetPresented = true }
        }
        
        isChecking = false
    }
    
    private func parseGitHubRelease(data: Data) throws -> ReleaseInfo? {
        struct GHRelease: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let published_at: String?
            let html_url: String
        }
        
        guard let gh = try? JSONDecoder().decode(GHRelease.self, from: data) else {
            return nil
        }
        
        let version = gh.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let title = gh.name ?? "ApexTerm \(gh.tag_name)"
        let notes = gh.body ?? "包含稳定性增强与性能优化。"
        let date = gh.published_at?.prefix(10).description ?? ""
        
        return ReleaseInfo(
            version: version,
            releaseDate: date,
            title: title,
            notes: notes,
            downloadUrl: gh.html_url
        )
    }
}
