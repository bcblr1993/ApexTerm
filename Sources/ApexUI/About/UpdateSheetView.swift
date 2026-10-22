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
                    .shadow(color: ApexStyle.accent.opacity(0.3), radius: 8)
                
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
                .apexGlassCard(cornerRadius: 8, material: .ultraThinMaterial, borderColor: ApexStyle.border.opacity(0.75), shadowRadius: 3)
            }
            
            HStack {
                ApexActionButton(
                    L10n.remindLater,
                    tint: ApexStyle.secondary,
                    size: .regular
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                ApexActionButton(
                    L10n.updateNow,
                    icon: "arrow.down.to.line.compact",
                    tint: ApexStyle.accent,
                    size: .regular,
                    isProminent: true
                ) {
                    Task {
                        await updateManager.startInAppUpdate(release: release)
                    }
                }
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
                ApexActionButton(
                    L10n.cancelDownload,
                    tint: ApexStyle.error,
                    size: .regular
                ) {
                    updateManager.cancelUpdate()
                }
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
                    .shadow(color: ApexStyle.success.opacity(0.3), radius: 8)
                
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
                ApexActionButton(
                    L10n.restartLater,
                    tint: ApexStyle.secondary,
                    size: .regular
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                ApexActionButton(
                    L10n.restartAndInstall,
                    icon: "arrow.clockwise.circle.fill",
                    tint: ApexStyle.success,
                    size: .regular,
                    isProminent: true
                ) {
                    updateManager.relaunchAndInstall()
                }
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
                .shadow(color: ApexStyle.success.opacity(0.3), radius: 8)
            
            Text(L10n.upToDateTitle)
                .font(.headline)
            
            Text(String(format: L10n.upToDateDesc, currentVersion as CVarArg))
                .font(.subheadline)
                .foregroundColor(ApexStyle.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
            
            ApexActionButton(
                "完成",
                tint: ApexStyle.accent,
                size: .regular,
                isProminent: true
            ) {
                dismiss()
            }
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
                ApexActionButton(
                    L10n.closeWindow,
                    tint: ApexStyle.secondary,
                    size: .regular
                ) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                if let release = updateManager.latestRelease, let url = URL(string: release.downloadUrl) {
                    ApexActionButton(
                        L10n.openGitHubDownload,
                        icon: "safari",
                        tint: ApexStyle.accent,
                        size: .regular
                    ) {
                        NSWorkspace.shared.open(url)
                        dismiss()
                    }
                }
                
                ApexActionButton(
                    L10n.retry,
                    icon: "arrow.clockwise",
                    tint: ApexStyle.accent,
                    size: .regular,
                    isProminent: true
                ) {
                    Task {
                        await updateManager.checkForUpdates(manual: true)
                    }
                }
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
