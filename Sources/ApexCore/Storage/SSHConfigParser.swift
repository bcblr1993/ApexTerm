import Foundation

/// Represents a parsed SSH host entry from ~/.ssh/config
public struct SSHConfigHost: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let hostPattern: String
    public let hostName: String
    public let user: String
    public let port: Int
    public let identityFile: String?
    
    public init(
        id: UUID = UUID(),
        hostPattern: String,
        hostName: String,
        user: String,
        port: Int = 22,
        identityFile: String? = nil
    ) {
        self.id = id
        self.hostPattern = hostPattern
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
    
    /// Converts this parsed config entry into a ready-to-use ApexTerm Session
    public func toSession(folder: String = "SSH Config") -> Session {
        let auth: SSHAuthMethod
        if let keyPath = identityFile, !keyPath.isEmpty {
            auth = .privateKey(keychainRef: keyPath, passphraseRef: nil)
        } else {
            auth = .agent
        }
        
        return Session(
            name: hostPattern,
            host: hostName.isEmpty ? hostPattern : hostName,
            port: port,
            username: user.isEmpty ? NSUserName() : user,
            authMethod: auth,
            folder: folder,
            tags: ["ssh-config", "imported"],
            agentlessMonitorEnabled: true,
            sftpAutoSyncEnabled: true
        )
    }
}

/// Parser for standard OpenSSH configuration files (`~/.ssh/config`)
public final class SSHConfigParser: Sendable {
    
    public static let standardConfigURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ssh").appendingPathComponent("config")
    }()
    
    public init() {}
    
    /// Parses standard ~/.ssh/config from default disk path
    public static func parseDefaultConfig() -> [SSHConfigHost] {
        guard FileManager.default.fileExists(atPath: standardConfigURL.path) else {
            return []
        }
        do {
            let content = try String(contentsOf: standardConfigURL, encoding: .utf8)
            return parse(content: content)
        } catch {
            return []
        }
    }
    
    /// Parses raw string contents of an SSH configuration file
    public static func parse(content: String) -> [SSHConfigHost] {
        var results: [SSHConfigHost] = []
        let lines = content.components(separatedBy: .newlines)
        
        var currentHostPatterns: [String] = []
        var currentHostName = ""
        var currentUser = ""
        var currentPort = 22
        var currentIdentityFile: String? = nil
        
        func flushCurrent() {
            guard !currentHostPatterns.isEmpty else { return }
            for pattern in currentHostPatterns {
                let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                // Filter wildcard patterns like "*" or "*.*"
                if trimmed.isEmpty || trimmed == "*" || trimmed.contains("*") || trimmed.contains("?") {
                    continue
                }
                
                let targetHost = currentHostName.isEmpty ? trimmed : currentHostName
                let entry = SSHConfigHost(
                    hostPattern: trimmed,
                    hostName: targetHost,
                    user: currentUser,
                    port: currentPort,
                    identityFile: currentIdentityFile
                )
                results.append(entry)
            }
            currentHostPatterns = []
            currentHostName = ""
            currentUser = ""
            currentPort = 22
            currentIdentityFile = nil
        }
        
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip comments and empty lines
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            
            // Tokens can be separated by whitespace (spaces, tabs) or '='
            let directive: String
            let rawValue: String
            
            if let eqIndex = line.firstIndex(of: "=") {
                let key = line[..<eqIndex].trimmingCharacters(in: .whitespaces)
                let val = line[line.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)
                directive = key.lowercased()
                rawValue = val
            } else if let spaceIndex = line.firstIndex(where: { $0.isWhitespace }) {
                let key = line[..<spaceIndex].trimmingCharacters(in: .whitespaces)
                let val = line[line.index(after: spaceIndex)...].trimmingCharacters(in: .whitespaces)
                directive = key.lowercased()
                rawValue = val
            } else {
                directive = line.lowercased()
                rawValue = ""
            }
            
            guard !directive.isEmpty else { continue }
            
            var cleanValue = rawValue
            if (cleanValue.hasPrefix("\"") && cleanValue.hasSuffix("\"")) || (cleanValue.hasPrefix("'") && cleanValue.hasSuffix("'")) {
                cleanValue = String(cleanValue.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            
            switch directive {
            case "host":
                flushCurrent()
                let patterns: [String]
                if (rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"")) || (rawValue.hasPrefix("'") && rawValue.hasSuffix("'")) {
                    patterns = [cleanValue]
                } else {
                    patterns = cleanValue.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                }
                currentHostPatterns = patterns
                
            case "hostname":
                currentHostName = cleanValue
                
            case "user":
                currentUser = cleanValue
                
            case "port":
                if let p = Int(cleanValue), p > 0 && p <= 65535 {
                    currentPort = p
                }
                
            case "identityfile":
                let expanded = (cleanValue as NSString).expandingTildeInPath
                currentIdentityFile = expanded
                
            default:
                break
            }
        }
        
        flushCurrent()
        return results
    }
}
