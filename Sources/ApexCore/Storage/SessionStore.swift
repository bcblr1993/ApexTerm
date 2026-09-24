import Foundation

/// Persistent store for sessions, folders, and snippets
@MainActor
public final class SessionStore: ObservableObject {
    public static let shared = SessionStore()
    
    @Published public var sessions: [Session] = []
    @Published public var snippets: [Snippet] = []
    @Published public var triggers: [Trigger] = []
    @Published public var folders: [String] = ["Production", "Staging", "Database"]
    
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    
    public init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseDirectory = appSupport.appendingPathComponent("ApexTerm", isDirectory: true)
        
        try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        loadAll()
        
        if sessions.isEmpty {
            seedDefaultData()
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
    
    private func seedDefaultData() {
        let prod1 = Session(
            name: "k8s-prod-master-01",
            host: "10.0.1.10",
            port: 22,
            username: "root",
            folder: "Production",
            tags: ["k8s", "prod", "master"],
            colorHex: "#FF453A"
        )
        let prod2 = Session(
            name: "k8s-prod-worker-02",
            host: "10.0.1.11",
            port: 22,
            username: "root",
            folder: "Production",
            tags: ["k8s", "prod", "worker"],
            colorHex: "#FF9F0A"
        )
        let redisStaging = Session(
            name: "staging-redis-cluster",
            host: "192.168.1.50",
            port: 22,
            username: "ubuntu",
            folder: "Staging",
            tags: ["redis", "staging"],
            colorHex: "#30D158"
        )
        let dbMaster = Session(
            name: "pg-master-primary",
            host: "172.16.0.4",
            port: 22,
            username: "postgres",
            folder: "Database",
            tags: ["db", "postgresql"],
            colorHex: "#0A84FF"
        )
        self.sessions = [prod1, prod2, redisStaging, dbMaster]
        
        self.snippets = [
            Snippet(title: "Check Systemctl Nginx", command: "systemctl status nginx", category: "Nginx"),
            Snippet(title: "Tail App Log", command: "tail -f -n 100 /var/log/app.log", category: "Logging"),
            Snippet(title: "Top Memory Processes", command: "ps aux --sort=-%mem | head -n 10", category: "Diagnosis"),
            Snippet(title: "Disk Space Check", command: "df -h", category: "Diagnosis")
        ]
        
        self.triggers = [
            Trigger(name: "Error Highlighter", regexPattern: "(?i)(error|failed|fatal|exception)", action: .highlight(colorHex: "#FF453A")),
            Trigger(name: "IP Address Highlighter", regexPattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", action: .highlight(colorHex: "#0A84FF")),
            Trigger(name: "Success Highlighter", regexPattern: "(?i)(success|200 OK|active \\(running\\))", action: .highlight(colorHex: "#30D158"))
        ]
        
        saveAll()
    }
}
