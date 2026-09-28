import SwiftUI
import AppKit
import ApexCore

/// Interactive sheet presenting update status, release notes, download progress, and restart installation
public struct UpdateSheetView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var updateManager = UpdateManager.shared
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            contentView
        }
        .background(ApexStyle.surface)
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch updateManager.status {
        case .checking:
            checkingView
            
        case .updateAvailable(let release):
            updateAvailableView(release: release)
            
        case .downloading(let progress, let totalBytes, let receivedBytes):
            downloadingView(progress: progress, totalBytes: totalBytes, receivedBytes: receivedBytes)
            
        case .preparing(let message):
            preparingView(message: message)
            
        case .readyToRestart(let version, _):
            readyToRestartView(version: version)
            
        case .upToDate(let currentVersion):
            upToDateView(currentVersion: currentVersion)
            
        case .failed(let message):
            failedView(message: message)
            
        case .idle:
            EmptyView()
        }
    }
    
    // MARK: - Checking View
    private var checkingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(L10n.checkingForUpdates)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(ApexStyle.secondary)
        }
        .frame(width: 400, height: 180)
        .padding(24)
    }
    
    // MARK: - Update Available View
    private func updateAvailableView(release: ReleaseInfo) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 42))
                    .foregroundColor(ApexStyle.accent)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.updateAvailableTitle)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text("新版本: v\(release.version)")
                            .font(.subheadline)
                            .foregroundColor(ApexStyle.primary)
                        Text("(当前: v\(updateManager.currentVersion))")
                            .font(.caption)
                            .foregroundColor(ApexStyle.secondary)
                    }
                    if let size = release.packageSize, size > 0 {
                        Text("\(L10n.packageSizeLabel) \(formatBytes(size))")
                            .font(.caption2)
                            .foregroundColor(ApexStyle.secondary)
                    }
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
                .frame(height: 130)
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
                    Task {
                        await updateManager.startInAppUpdate(release: release)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line.compact")
                        Text(L10n.updateNow)
                    }
                }
                .apexProminentButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
    
    // MARK: - Downloading View
    private func downloadingView(progress: Double, totalBytes: Int64, receivedBytes: Int64) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(ApexStyle.accent.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(ApexStyle.accent)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.downloadingUpdate)
                        .font(.headline)
                    Text("版本 v\(updateManager.latestRelease?.version ?? "")")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
                Spacer()
            }
            
            VStack(spacing: 8) {
                if totalBytes > 0 {
                    ProgressView(value: min(1.0, max(0.0, progress)))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                
                HStack {
                    let receivedStr = formatBytes(receivedBytes)
                    let totalStr = totalBytes > 0 ? formatBytes(totalBytes) : "--"
                    Text("\(receivedStr) / \(totalStr)")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                    
                    Spacer()
                    
                    if totalBytes > 0 {
                        Text("\(Int(progress * 100))%")
                            .font(.caption.bold())
                            .foregroundColor(ApexStyle.primary)
                    }
                }
            }
            .padding(.vertical, 4)
            
            HStack {
                Spacer()
                Button(L10n.cancelDownload) {
                    updateManager.cancelUpdate()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
    
    // MARK: - Preparing View
    private func preparingView(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(L10n.preparingUpdate)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(ApexStyle.secondary)
        }
        .frame(width: 400, height: 160)
        .padding(24)
    }
    
    // MARK: - Ready To Restart View
    private func readyToRestartView(version: String) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(ApexStyle.success)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.readyToRestartTitle)
                        .font(.headline)
                    Text(String(format: L10n.readyToRestartDesc, version))
                        .font(.subheadline)
                        .foregroundColor(ApexStyle.secondary)
                }
                Spacer()
            }
            
            HStack {
                Button(L10n.restartLater) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button {
                    updateManager.relaunchAndInstall()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                        Text(L10n.restartAndInstall)
                    }
                }
                .apexProminentButton()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 450)
    }
    
    // MARK: - Up-to-Date View
    private func upToDateView(currentVersion: String) -> some View {
        VStack(spacing: 16) {
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
    }
    
    // MARK: - Failed View
    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(ApexStyle.warning)
            
            Text(L10n.updateFailedTitle)
                .font(.headline)
            
            Text(message)
                .font(.caption)
                .foregroundColor(ApexStyle.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
            
            HStack(spacing: 10) {
                Button(L10n.closeWindow) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                if let release = updateManager.latestRelease, let url = URL(string: release.downloadUrl) {
                    Button(L10n.openGitHubDownload) {
                        NSWorkspace.shared.open(url)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                
                Button(L10n.retry) {
                    Task {
                        await updateManager.checkForUpdates(manual: true)
                    }
                }
                .apexProminentButton()
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 440)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
