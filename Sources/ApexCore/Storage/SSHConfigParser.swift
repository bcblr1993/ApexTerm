import Foundation

/// Represents a parsed SSH host entry from ~/.ssh/config
public struct SSHConfigHost: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let hostPattern: String
    public let hostName: String
    public let user: String
    public let port: Int
    public let identityFile: String?
    public let certificateFile: String?
    public let remoteCommand: String?
    public let environmentVariables: [String: String]
    
    public init(
        id: UUID = UUID(),
        hostPattern: String,
        hostName: String,
        user: String,
        port: Int = 22,
        identityFile: String? = nil,
        certificateFile: String? = nil,
        remoteCommand: String? = nil,
        environmentVariables: [String: String] = [:]
    ) {
        self.id = id
        self.hostPattern = hostPattern
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.certificateFile = certificateFile
        self.remoteCommand = remoteCommand
        self.environmentVariables = environmentVariables
    }
    
    /// Converts this parsed config entry into a ready-to-use ApexTerm Session
    public func toSession(folder: String = "SSH Config") -> Session {
        let auth: SSHAuthMethod
        // OpenSSH pairs `<key>-cert.pub` with `<key>`; derive the key when only CertificateFile is given.
        let derivedKeyPath = certificateFile.flatMap { cert -> String? in
            cert.hasSuffix("-cert.pub") ? String(cert.dropLast("-cert.pub".count)) : nil
        }
        if let certPath = certificateFile, !certPath.isEmpty, let keyPath = identityFile ?? derivedKeyPath, !keyPath.isEmpty {
            auth = .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: nil)
        } else if let keyPath = identityFile, !keyPath.isEmpty {
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
            sftpAutoSyncEnabled: true,
            startupCommand: remoteCommand,
            environmentVariables: environmentVariables
        )
    }

    /// Merges updated `~/.ssh/config` connection parameters into an existing `Session` while
    /// preserving the user's existing ID, folder, color, keep-alive interval, terminal type,
    /// jump server, custom tags, timestamps, and stored Keychain passphrase/password reference.
    public func mergedSession(updating existing: Session, folder: String = "SSH Config") -> Session {
        let base = toSession(folder: folder)
        let mergedAuth: SSHAuthMethod
        switch base.authMethod {
        case .certificate(let keyRef, let certPath, _):
            let preservedPassRef = (existing.privateKeyPath == keyRef) ? existing.passphraseRef : nil
            mergedAuth = .certificate(keychainRef: keyRef, certificatePath: certPath, passphraseRef: preservedPassRef)
        case .privateKey(let keyRef, _):
            let preservedPassRef = (existing.privateKeyPath == keyRef) ? existing.passphraseRef : nil
            mergedAuth = .privateKey(keychainRef: keyRef, passphraseRef: preservedPassRef)
        case .agent:
            // Keep existing password/key auth if ~/.ssh/config did not specify an IdentityFile/CertificateFile
            switch existing.authMethod {
            case .password, .privateKey, .certificate:
                mergedAuth = existing.authMethod
            default:
                mergedAuth = .agent
            }
        default:
            mergedAuth = base.authMethod
        }

        var mergedTags = existing.tags
        for tag in base.tags where !mergedTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            mergedTags.append(tag)
        }

        let existingFolder = existing.folder?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preservedFolder = existingFolder.isEmpty ? folder : existingFolder
        return Session(
            id: existing.id,
            name: base.name,
            host: base.host,
            port: base.port,
            username: base.username,
            authMethod: mergedAuth,
            folder: preservedFolder,
            tags: mergedTags,
            colorHex: existing.colorHex,
            jumpServerId: existing.jumpServerId,
            agentlessMonitorEnabled: existing.agentlessMonitorEnabled,
            sftpAutoSyncEnabled: existing.sftpAutoSyncEnabled,
            keepAliveIntervalSeconds: existing.keepAliveIntervalSeconds,
            terminalType: existing.terminalType,
            initialWorkingDirectory: existing.initialWorkingDirectory,
            startupCommand: existing.startupCommand,
            environmentVariables: existing.environmentVariables,
            createdAt: existing.createdAt,
            lastConnectedAt: existing.lastConnectedAt
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
        var currentCertificateFile: String? = nil
        var currentRemoteCommand: String? = nil
        var currentEnvVars: [String: String] = [:]
        var portWasSet = false
        // `Match` blocks are conditional; their directives must not leak into the preceding Host.
        var insideMatchBlock = false
        
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
                    identityFile: currentIdentityFile,
                    certificateFile: currentCertificateFile,
                    remoteCommand: currentRemoteCommand,
                    environmentVariables: currentEnvVars
                )
                results.append(entry)
            }
            currentHostPatterns = []
            currentHostName = ""
            currentUser = ""
            currentPort = 22
            currentIdentityFile = nil
            currentCertificateFile = nil
            currentRemoteCommand = nil
            currentEnvVars = [:]
            portWasSet = false
        }
        
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip comments and empty lines
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            
            // Tokens can be separated by whitespace (spaces, tabs) or '=' (when key before '=' has no internal spaces)
            let directive: String
            let rawValue: String
            
            if let eqIndex = line.firstIndex(of: "="),
               line[..<eqIndex].trimmingCharacters(in: .whitespaces).allSatisfy({ !$0.isWhitespace }) {
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
            
            if directive == "match" {
                flushCurrent()
                insideMatchBlock = true
                continue
            }
            if insideMatchBlock && directive != "host" { continue }
            
            // OpenSSH semantics: the first obtained value for each parameter wins.
            switch directive {
            case "host":
                flushCurrent()
                insideMatchBlock = false
                let patterns: [String]
                if (rawValue.hasPrefix("\"") && rawValue.hasSuffix("\"")) || (rawValue.hasPrefix("'") && rawValue.hasSuffix("'")) {
                    patterns = [cleanValue]
                } else {
                    patterns = cleanValue.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                }
                currentHostPatterns = patterns
                
            case "hostname":
                if currentHostName.isEmpty { currentHostName = cleanValue }
                
            case "user":
                if currentUser.isEmpty { currentUser = cleanValue }
                
            case "port":
                if !portWasSet, let p = Int(cleanValue), p > 0 && p <= 65535 {
                    currentPort = p
                    portWasSet = true
                }
                
            case "identityfile":
                if currentIdentityFile == nil {
                    currentIdentityFile = (cleanValue as NSString).expandingTildeInPath
                }
                
            case "certificatefile":
                if currentCertificateFile == nil {
                    currentCertificateFile = (cleanValue as NSString).expandingTildeInPath
                }
                
            case "remotecommand":
                if currentRemoteCommand == nil && cleanValue.lowercased() != "none" && !cleanValue.isEmpty {
                    currentRemoteCommand = cleanValue
                }
                
            case "setenv":
                let parsed = SessionStartupHelper.parseEnvLines(rawValue)
                for (k, v) in parsed.variables where currentEnvVars[k] == nil {
                    currentEnvVars[k] = v
                }
                
            default:
                break
            }
        }
        
        flushCurrent()
        return results
    }
}
