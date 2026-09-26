import SwiftUI
import AppKit
import ApexCore

/// Interactive sheet presenting update status, release notes, and download actions
public struct UpdateSheetView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var updateManager = UpdateManager.shared
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 18) {
            switch updateManager.status {
            case .checking:
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(L10n.checkingForUpdates)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(ApexStyle.secondary)
                }
                .frame(width: 380, height: 180)
                
            case .updateAvailable(let release):
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 38))
                            .foregroundColor(.accentColor)
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.updateAvailableTitle)
                                .font(.headline)
                            Text("新版本: v\(release.version) (当前: v\(updateManager.currentVersion))")
                                .font(.subheadline)
                                .foregroundColor(ApexStyle.secondary)
                        }
                        Spacer()
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("更新日志与新特性：")
                            .font(.caption)
                            .foregroundColor(ApexStyle.secondary)
                        
                        ScrollView {
                            Text(release.notes)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(height: 120)
                        .background(ApexStyle.subtleSurface)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ApexStyle.border, lineWidth: 1)
                        )
                    }
                    
                    HStack {
                        Button(L10n.remindLater) {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                        
                        Spacer()
                        
                        Button {
                            if let url = URL(string: release.downloadUrl) {
                                NSWorkspace.shared.open(url)
                            }
                            dismiss()
                        } label: {
                            Text(L10n.updateNow)
                        }
                        .apexProminentButton()
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 440)
                
            case .upToDate(let currentVersion):
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 42))
                        .foregroundColor(ApexStyle.success)
                    
                    Text(L10n.upToDateTitle)
                        .font(.headline)
                    
                    Text(String(format: L10n.upToDateDesc, currentVersion as CVarArg))
                        .font(.subheadline)
                        .foregroundColor(ApexStyle.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                    
                    Button("完成") {
                        dismiss()
                    }
                    .apexProminentButton()
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
                }
                .padding(24)
                .frame(width: 380)
                
            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(ApexStyle.warning)
                    
                    Text("检查更新失败")
                        .font(.headline)
                    
                    Text(message)
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                    
                    HStack {
                        Button(L10n.closeWindow) {
                            dismiss()
                        }
                        
                        Button("重试") {
                            Task {
                                await updateManager.checkForUpdates(manual: true)
                            }
                        }
                        .apexProminentButton()
                    }
                    .padding(.top, 6)
                }
                .padding(24)
                .frame(width: 380)
                
            case .idle:
                EmptyView()
            }
        }
        .background(ApexStyle.surface)
    }
}
