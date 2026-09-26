import SwiftUI
import AppKit
import ApexCore

/// Custom native macOS About dialog
public struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var updateManager = UpdateManager.shared
    
    public init() {}
    
    public var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 20) {
                // Header: App Icon & Name
                HStack(spacing: 20) {
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80, height: 80)
                            .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 3)
                    } else {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 80, height: 80)
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 38))
                                .foregroundColor(.white)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.appName)
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                            
                            Text("v\(updateManager.currentVersion)")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(ApexStyle.accent.opacity(0.15))
                                .foregroundColor(ApexStyle.accent)
                                .clipShape(Capsule())
                        }
                        
                        Text("\(L10n.buildNumber) \(updateManager.currentBuild) • Apple Silicon arm64")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        Text(L10n.appTagline)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                .padding(.top, 10)
                
                // Tech badges
                HStack(spacing: 10) {
                    techBadge(icon: "bolt.fill", title: "Apple Silicon", color: .orange)
                    techBadge(icon: "display", title: "Metal 120Hz", color: .blue)
                    techBadge(icon: "lock.shield.fill", title: "Native SSH / SFTP", color: .green)
                    techBadge(icon: "swift", title: "Swift 6 Native", color: .red)
                }
                
                Divider()
                    .padding(.horizontal, 10)
                
                // Action links
                HStack(spacing: 12) {
                    Button {
                        Task {
                            await updateManager.checkForUpdates(manual: true)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if updateManager.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(L10n.checkUpdatesNow)
                        }
                        .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(updateManager.isChecking)
                    
                    Button {
                        if let url = URL(string: "https://github.com/apexterm/apexterm") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "network")
                            Text(L10n.openGitHub)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    
                    Button("关闭") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
                }
                
                // Inline update status notification
                Group {
                    switch updateManager.status {
                    case .checking:
                        Text(L10n.checkingForUpdates)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .upToDate(let ver):
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            Text(String(format: L10n.upToDateDesc, ver as CVarArg))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .updateAvailable(let rel):
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("发现新版本 v\(rel.version)")
                                .font(.caption.bold())
                            Button("前往下载") {
                                if let url = URL(string: rel.downloadUrl) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .controlSize(.small)
                        }
                    case .failed(let err):
                        Text("检查失败: \(err)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .idle:
                        EmptyView()
                    }
                }
                .animation(.easeInOut, value: updateManager.status)
                
                // Footer: Copyright
                VStack(spacing: 4) {
                    Text(L10n.copyright)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Text("Designed with ❤️ for Mac developers & engineers")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .padding(.bottom, 6)
            }
            .padding(24)
            
            // Top-right Close Button (X)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(14)
            .help("关闭 (Esc / ⌘W)")
        }
        .frame(width: 520)
        .background(ApexStyle.surface)
        .onExitCommand {
            dismiss()
        }
        .background(
            // Hidden button for Command+W shortcut
            Button("") {
                dismiss()
            }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)
        )
    }
    
    private func techBadge(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.primary.opacity(0.85))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(ApexStyle.subtleSurface)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ApexStyle.border, lineWidth: 0.8)
        )
    }
}
