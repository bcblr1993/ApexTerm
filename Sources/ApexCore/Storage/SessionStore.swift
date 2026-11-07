import Foundation

/// Persistent store for sessions, folders, and snippets
@MainActor
public final class SessionStore: ObservableObject {
    public static let shared = SessionStore()
    
    @Published public var sessions: [Session] = []
    @Published public var snippets: [Snippet] = []
    @Published public var triggers: [Trigger] = []
    @Published public var folders: [String] = []
    
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    
    public init(baseDirectory: URL? = nil) {
        if let baseDirectory = baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = Self.defaultDirectory(appSupport: appSupport, bundleIdentifier: Bundle.main.bundleIdentifier)
        }
        
        try? fileManager.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
        loadAll()
        
        if snippets.isEmpty {
            self.snippets = Snippet.defaultCuratedSnippets
            saveAll()
        }
        
        if triggers.isEmpty {
            seedDefaultTriggers()
        }
    }

    static func defaultDirectory(appSupport: URL, bundleIdentifier: String?) -> URL {
        if let bundleIdentifier, bundleIdentifier.hasPrefix("com.apexterm.qa.") {
            return appSupport.appendingPathComponent("ApexTerm QA", isDirectory: true)
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
        }
        let name = bundleIdentifier == "com.apexterm.candidate" ? "ApexTerm Candidate" : "ApexTerm"
        return appSupport.appendingPathComponent(name, isDirectory: true)
    }
    
    private var sessionsFileURL: URL {
        baseDirectory.appendingPathComponent("sessions.json")
    }
    
    private var snippetsFileURL: URL {
        baseDirectory.appendingPathComponent("snippets.json")
    }
    
    private var triggersFileURL: URL {
        baseDirectory.appendingPathComponent("triggers.json")
    }
    
    public func loadAll() {
        if let data = try? Data(contentsOf: sessionsFileURL),
           let decoded = try? JSONDecoder().decode([Session].self, from: data) {
            self.sessions = decoded
        }
        
        if let data = try? Data(contentsOf: snippetsFileURL),
           let decoded = try? JSONDecoder().decode([Snippet].self, from: data) {
            self.snippets = decoded
        }
        
        if let data = try? Data(contentsOf: triggersFileURL),
           let decoded = try? JSONDecoder().decode([Trigger].self, from: data) {
            self.triggers = decoded
        }
    }
    
    public func saveAll() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: sessionsFileURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: snippetsFileURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(triggers) {
            try? data.write(to: triggersFileURL, options: .atomic)
        }
    }
    
    public func addSession(_ session: Session) {
        sessions.append(session)
        saveAll()
    }
    
    public func updateSession(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
            saveAll()
        }
    }
    
    @discardableResult
    public func duplicateSession(
        _ session: Session,
        nameSuffix: String = " (副本)",
        secretCloner: ((String, String) -> String?)? = nil
    ) -> Session {
        let cloner: (String, String) -> String? = secretCloner ?? { oldRef, newRef in
            guard let secret = try? KeychainStore.shared.getSync(key: oldRef),
                  let savedRef = try? KeychainStore.shared.save(key: newRef, secret: secret) else {
                return newRef
            }
            return savedRef
        }

        var dup = session
        let newId = UUID()
        dup.id = newId
        dup.name += nameSuffix
        dup.createdAt = Date()
        dup.lastConnectedAt = nil

        switch session.authMethod {
        case .password(let ref):
            if KeychainStore.isSessionSecretReference(ref) {
                let candidateRef = "ssh_\(newId.uuidString)"
                let resolvedRef = cloner(ref, candidateRef) ?? candidateRef
                dup.authMethod = .password(keychainRef: resolvedRef)
            }
        case .privateKey(let keyPath, let passRef):
            if let ref = passRef, KeychainStore.isSessionSecretReference(ref) {
                let candidateRef = "passphrase_\(newId.uuidString)"
                let resolvedRef = cloner(ref, candidateRef) ?? candidateRef
                dup.authMethod = .privateKey(keychainRef: keyPath, passphraseRef: resolvedRef)
            }
        case .certificate(let keyPath, let certPath, let passRef):
            if let ref = passRef, KeychainStore.isSessionSecretReference(ref) {
                let candidateRef = "passphrase_\(newId.uuidString)"
                let resolvedRef = cloner(ref, candidateRef) ?? candidateRef
                dup.authMethod = .certificate(keychainRef: keyPath, certificatePath: certPath, passphraseRef: resolvedRef)
            }
        case .agent, .none:
            break
        }

        addSession(dup)
        return dup
    }

    public func deleteSession(
        id: UUID,
        tunnelManager: SSHTunnelManager? = nil,
        secretDeleter: ((String) -> Void)? = nil
    ) {
        let target = sessions.first(where: { $0.id == id })
        sessions.removeAll(where: { $0.id == id })

        // Clear dangling jumpServerId references on remaining sessions
        for idx in sessions.indices where sessions[idx].jumpServerId == id {
            sessions[idx].jumpServerId = nil
        }

        // Clean up session-owned Keychain secrets if no remaining session still shares the reference
        if let target {
            let candidateRef: String?
            switch target.authMethod {
            case .password(let ref):
                candidateRef = KeychainStore.isSessionSecretReference(ref) ? ref : nil
            case .privateKey(_, let passRef), .certificate(_, _, let passRef):
                if let ref = passRef, KeychainStore.isSessionSecretReference(ref) {
                    candidateRef = ref
                } else {
                    candidateRef = nil
                }
            case .agent, .none:
                candidateRef = nil
            }
            if let ref = candidateRef {
                let stillReferenced = sessions.contains { s in
                    switch s.authMethod {
                    case .password(let r): return r == ref
                    case .privateKey(_, let r), .certificate(_, _, let r): return r == ref
                    case .agent, .none: return false
                    }
                }
                if !stillReferenced {
                    let deleter = secretDeleter ?? { key in try? KeychainStore.shared.delete(key: key) }
                    deleter(ref)
                }
            }
        }

        // Stop and delete any SSH tunnels associated with the deleted session
        let manager = tunnelManager ?? SSHTunnelManager.shared
        for tunnel in manager.tunnels(for: id) {
            manager.deleteTunnel(id: tunnel.id)
        }

        saveAll()
    }
    
    // MARK: - Snippet Management
    
    public func addSnippet(_ snippet: Snippet) {
        snippets.append(snippet)
        saveAll()
    }
    
    public func updateSnippet(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
            saveAll()
        }
    }
    
    public func deleteSnippet(id: UUID) {
        snippets.removeAll(where: { $0.id == id })
        saveAll()
    }
    
    // MARK: - Export & Import Backup Operations
    
    /// Exports all sessions into pretty-printed JSON data
    public func exportSessionsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sessions)
    }
    
    /// Imports sessions from JSON data. Returns number of sessions imported.
    @discardableResult
    public func importSessionsJSON(from data: Data, overwrite: Bool = false) throws -> Int {
        let imported = try JSONDecoder().decode([Session].self, from: data)
        if overwrite {
            self.sessions = imported
        } else {
            for item in imported {
                if let index = self.sessions.firstIndex(where: { $0.id == item.id }) {
                    self.sessions[index] = item
                } else {
                    self.sessions.append(item)
                }
            }
        }
        saveAll()
        return imported.count
    }
    
    public func replaceAllSessions(_ newSessions: [Session]) {
        self.sessions = newSessions
        saveAll()
    }
    
    public func replaceAllSnippets(_ newSnippets: [Snippet]) {
        self.snippets = newSnippets
        saveAll()
    }
    
    public func replaceAllTriggers(_ newTriggers: [Trigger]) {
        self.triggers = newTriggers
        saveAll()
    }
    
    private func seedDefaultTriggers() {
        self.triggers = [
            Trigger(name: "Error Highlighter", regexPattern: "(?i)(error|failed|fatal|exception)", action: .highlight(colorHex: "#FF453A")),
            Trigger(name: "IP Address Highlighter", regexPattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", action: .highlight(colorHex: "#0A84FF")),
            Trigger(name: "Success Highlighter", regexPattern: "(?i)(success|200 OK|active \\(running\\))", action: .highlight(colorHex: "#30D158"))
        ]
        saveAll()
    }
}
