import SwiftUI
import ApexCore

/// Full-window privacy lock overlay shown while `AppLockManager.isLocked` is true.
public struct AppLockOverlayView: View {
    @ObservedObject private var lockManager: AppLockManager
    @ObservedObject private var themeSettings = AppSettings.shared

    public init(lockManager: AppLockManager = .shared) {
        self.lockManager = lockManager
    }

    public var body: some View {
        if lockManager.isLocked {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(ApexStyle.surface.opacity(0.68))
                    .ignoresSafeArea()

                VStack(spacing: ApexStyle.s4) {
                    ZStack {
                        Circle()
                            .fill(ApexStyle.accent.opacity(0.14))
                            .frame(width: 72, height: 72)

                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(ApexStyle.accent)
                    }

                    VStack(spacing: ApexStyle.s1) {
                        Text("AetherTerm 已锁定")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(ApexStyle.primary)

                        Text("终端会话、SFTP 视图与凭据内容已隐藏，请验证身份继续")
                            .font(.system(size: 12.5))
                            .foregroundStyle(ApexStyle.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if let errorMessage = lockManager.lastErrorMessage, !errorMessage.isEmpty {
                        HStack(spacing: ApexStyle.s2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(ApexStyle.error)
                            Text(errorMessage)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(ApexStyle.error)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, ApexStyle.s3)
                        .padding(.vertical, ApexStyle.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ApexStyle.error.opacity(0.10), in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                                .stroke(ApexStyle.error.opacity(0.32), lineWidth: 0.75)
                        )
                    }

                    ApexActionButton(
                        lockManager.isAuthenticating ? "正在验证身份..." : "使用 Touch ID / 系统密码解锁",
                        icon: "touchid",
                        tint: ApexStyle.accent,
                        size: .regular,
                        isProminent: true,
                        isLoading: lockManager.isAuthenticating
                    ) {
                        Task {
                            await lockManager.unlockWithAuthentication()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(lockManager.isAuthenticating)

                    HStack(spacing: ApexStyle.sCompact) {
                        Text("⌘⇧L")
                            .apexKeycap()
                        Text("可随时锁定应用")
                            .font(.caption)
                            .foregroundStyle(ApexStyle.secondary)
                    }
                }
                .padding(ApexStyle.s6)
                .frame(width: 380)
                .apexGlassCard(cornerRadius: ApexStyle.panelRadius, material: .regularMaterial, shadowRadius: 18)
                .padding(ApexStyle.s4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("AetherTerm 应用锁定界面")
        }
    }
}
