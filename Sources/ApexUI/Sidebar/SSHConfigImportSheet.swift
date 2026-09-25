import SwiftUI
import ApexCore

/// Modal sheet for discovering, previewing, and importing hosts from ~/.ssh/config
public struct SSHConfigImportSheet: View {
    @ObservedObject public var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var discoveredHosts: [SSHConfigHost] = []
    @State private var selectedHostIds: Set<UUID> = []
    @State private var targetFolder = "SSH Config"
    @State private var configPath: String = SSHConfigParser.standardConfigURL.path
    @State private var importResultNotice: String?
    
    public init(store: SessionStore) {
        self.store = store
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down.on.square.fill")
                    .font(.system(size: 22))
                    .foregroundColor(ApexStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("从 ~/.ssh/config 导入主机")
                        .font(.system(size: 16, weight: .bold))
                    Text("自动扫描系统已知配置与密钥，一键导入 ApexTerm 会话库")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background(ApexStyle.surface)
            
            Divider()
            
            // Configuration & Toolbar
            HStack(spacing: 12) {
                Text("分组名称:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("目标文件夹", text: $targetFolder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .font(.system(size: 12))
                
                Spacer()
                
                if !discoveredHosts.isEmpty {
                    Button(action: toggleSelectAll) {
                        Text(selectedHostIds.count == discoveredHosts.count ? "取消全选" : "全选全部")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(ApexStyle.accent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(ApexStyle.subtleSurface.opacity(0.6))
            
            Divider()
            
            // Discovered Hosts List
            if discoveredHosts.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("未在 \(configPath) 中发现任何 Host 配置")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("请确认您的 ~/.ssh/config 文件中包含有效的 Host 与 HostName 配置。")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(discoveredHosts) { host in
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(
                            get: { selectedHostIds.contains(host.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedHostIds.insert(host.id)
                                } else {
                                    selectedHostIds.remove(host.id)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        
                        Image(systemName: "server.rack")
                            .foregroundColor(ApexStyle.accent)
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(host.hostPattern)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                if host.hostPattern != host.hostName {
                                    Text("(\(host.hostName))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            HStack(spacing: 10) {
                                Text("\(host.user.isEmpty ? "当前用户" : host.user):\(host.port)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                
                                if let key = host.identityFile {
                                    HStack(spacing: 3) {
                                        Image(systemName: "key.fill")
                                            .font(.system(size: 9))
                                        Text((key as NSString).lastPathComponent)
                                            .font(.system(size: 10, design: .monospaced))
                                    }
                                    .foregroundColor(.orange)
                                }
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            
            Divider()
            
            // Bottom Action Bar
            HStack {
                if let notice = importResultNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundColor(ApexStyle.success)
                }
                
                Spacer()
                
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                
                Button(action: performImport) {
                    Text("导入选中的 \(selectedHostIds.count) 台主机")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(ApexStyle.accent)
                .disabled(selectedHostIds.isEmpty)
            }
            .padding(16)
            .background(ApexStyle.surface)
        }
        .frame(minWidth: 540, minHeight: 440)
        .onAppear {
            scanHosts()
        }
    }
    
    private func scanHosts() {
        let hosts = SSHConfigParser.parseDefaultConfig()
        self.discoveredHosts = hosts
        self.selectedHostIds = Set(hosts.map(\.id))
    }
    
    private func toggleSelectAll() {
        if selectedHostIds.count == discoveredHosts.count {
            selectedHostIds.removeAll()
        } else {
            selectedHostIds = Set(discoveredHosts.map(\.id))
        }
    }
    
    private func performImport() {
        let toImport = discoveredHosts.filter { selectedHostIds.contains($0.id) }
        var importedCount = 0
        
        for host in toImport {
            let session = host.toSession(folder: targetFolder)
            if let existing = store.sessions.first(where: { $0.name == session.name && $0.host == session.host }) {
                var updated = session
                updated.id = existing.id
                store.updateSession(updated)
            } else {
                store.addSession(session)
            }
            importedCount += 1
        }
        
        importResultNotice = "已成功导入 \(importedCount) 台主机到分组 [\(targetFolder)]！"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            dismiss()
        }
    }
}
