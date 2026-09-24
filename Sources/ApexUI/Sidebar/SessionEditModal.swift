import SwiftUI
import ApexCore

/// Modal sheet for creating or editing an SSH session
public struct SessionEditModal: View {
    public let initialSession: Session?
    public let onSave: (Session) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = "root"
    @State private var folder: String = "Production"
    @State private var tags: String = "k8s, prod"
    @State private var colorHex: String = "#0A84FF"
    @State private var agentlessMonitor: Bool = true
    @State private var sftpAutoSync: Bool = true
    
    public init(session: Session?, onSave: @escaping (Session) -> Void) {
        self.initialSession = session
        self.onSave = onSave
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(initialSession == nil ? "New SSH Connection" : "Edit Connection", systemImage: "server.rack")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let newSession = Session(
                        id: initialSession?.id ?? UUID(),
                        name: name.isEmpty ? host : name,
                        host: host,
                        port: Int(port) ?? 22,
                        username: username,
                        authMethod: .agent,
                        folder: folder,
                        tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                        colorHex: colorHex,
                        agentlessMonitorEnabled: agentlessMonitor,
                        sftpAutoSyncEnabled: sftpAutoSync
                    )
                    onSave(newSession)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(host.isEmpty)
            }
            
            Divider()
            
            Form {
                Section("Host Details") {
                    TextField("Session Name (e.g. k8s-master)", text: $name)
                    TextField("Server Host / IP", text: $host)
                    TextField("SSH Port", text: $port)
                    TextField("Username", text: $username)
                }
                
                Section("Organization") {
                    TextField("Folder Group (e.g. Production)", text: $folder)
                    TextField("Tags (comma separated)", text: $tags)
                }
                
                Section("Performance & Features") {
                    Toggle("Enable Agentless Live Monitoring (FinalShell style)", isOn: $agentlessMonitor)
                    Toggle("Enable SFTP OSC 7 Shell Auto-Sync (electerm style)", isOn: $sftpAutoSync)
                }
            }
            .formStyle(.grouped)
        }
        .padding(18)
        .frame(width: 480, height: 420)
        .onAppear {
            if let s = initialSession {
                name = s.name
                host = s.host
                port = "\(s.port)"
                username = s.username
                folder = s.folder ?? "General"
                tags = s.tags.joined(separator: ", ")
                colorHex = s.colorHex ?? "#0A84FF"
                agentlessMonitor = s.agentlessMonitorEnabled
                sftpAutoSync = s.sftpAutoSyncEnabled
            }
        }
    }
}
