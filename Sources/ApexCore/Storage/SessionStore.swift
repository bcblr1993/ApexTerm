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
            self.baseDirectory = appSupport.appendingPathComponent("ApexTerm", isDirectory: true)
        }
        
        try? fileManager.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
        loadAll()
        
        if triggers.isEmpty {
            seedDefaultTriggers()
        }
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
            try? data.write(to: sessionsFileURL)
        }
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: snippetsFileURL)
        }
        if let data = try? JSONEncoder().encode(triggers) {
            try? data.write(to: triggersFileURL)
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
    
    public func deleteSession(id: UUID) {
        sessions.removeAll(where: { $0.id == id })
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
    
    private func seedDefaultTriggers() {
        self.triggers = [
            Trigger(name: "Error Highlighter", regexPattern: "(?i)(error|failed|fatal|exception)", action: .highlight(colorHex: "#FF453A")),
            Trigger(name: "IP Address Highlighter", regexPattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", action: .highlight(colorHex: "#0A84FF")),
            Trigger(name: "Success Highlighter", regexPattern: "(?i)(success|200 OK|active \\(running\\))", action: .highlight(colorHex: "#30D158"))
        ]
        saveAll()
    }
}

