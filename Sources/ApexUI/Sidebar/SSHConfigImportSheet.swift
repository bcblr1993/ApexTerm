import SwiftUI
import ApexCore

/// Modal sheet for discovering, previewing, and importing hosts from ~/.ssh/config
public struct SSHConfigImportSheet: View {
    @ObservedObject private var themeSettings = AppSettings.shared
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
                        .font(.headline)
                    Text("自动扫描系统已知配置与密钥，一键导入 ApexTerm 会话库")
                        .font(.subheadline)
                        .foregroundColor(ApexStyle.secondary)
                }
                Spacer()
            }
            .padding(18)
            .background(ApexStyle.surface)
            
            Divider()
            
            // Configuration & Toolbar
            HStack(spacing: 12) {
                Text("分组名称:")
                    .font(.subheadline)
                    .foregroundColor(ApexStyle.secondary)
                TextField("目标文件夹", text: $targetFolder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                
                Spacer()
                
                if !discoveredHosts.isEmpty {
                    Button(selectedHostIds.count == discoveredHosts.count ? "取消全选" : "全选",
                           action: toggleSelectAll)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(ApexStyle.subtleSurface.opacity(0.6))
            
            Divider()
            
            // Discovered Hosts List
            if discoveredHosts.isEmpty {
                ContentUnavailableView(
                    "没有找到主机配置",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("请检查 \(configPath) 中的 Host 与 HostName 配置。")
                )
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
                                        .foregroundColor(ApexStyle.secondary)
                                }
                            }
                            
                            HStack(spacing: 10) {
                                Text("\(host.user.isEmpty ? "当前用户" : host.user):\(host.port)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(ApexStyle.secondary)
                                
                                if let key = host.identityFile {
                                    HStack(spacing: 3) {
                                        Image(systemName: "key.fill")
                                            .font(.system(size: 9))
                                        Text((key as NSString).lastPathComponent)
                                            .font(.system(size: 10, design: .monospaced))
                                    }
                                    .foregroundColor(ApexStyle.warning)
                                }
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
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
                .apexProminentButton()
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
