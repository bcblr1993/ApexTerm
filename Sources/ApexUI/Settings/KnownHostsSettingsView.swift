import SwiftUI
import AppKit
import ApexCore

/// Visual inspector and trust manager for `~/.ssh/known_hosts` fingerprints and host key conflicts.
public struct KnownHostsSettingsView: View {
    @ObservedObject private var manager = KnownHostsManager.shared
    @State private var searchQuery: String = ""
    @State private var entryToDelete: KnownHostEntry?
    @State private var showingDeleteAlert: Bool = false
    @State private var toastMessage: String?

    public init() {}

    private var filteredEntries: [KnownHostEntry] {
        KnownHostsManager.filter(manager.entries, query: searchQuery)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(ApexStyle.secondary)
                    TextField("搜索主机名、端口、SHA256 指纹或算法...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(ApexStyle.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                        .stroke(ApexStyle.border, lineWidth: 0.75)
                )

                Text("共 \(filteredEntries.count) 条指纹")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(ApexStyle.secondary)

                ApexIconButton(
                    icon: "arrow.clockwise",
                    label: "重新加载 known_hosts",
                    size: 26,
                    iconSize: 11
                ) {
                    manager.reload()
                    showToast("已重新加载 ~/.ssh/known_hosts")
                }
            }

            if !manager.conflicts.isEmpty {
                conflictBanner
            }

            if filteredEntries.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 30))
                        .foregroundColor(ApexStyle.secondary.opacity(0.5))
                    Text(searchQuery.isEmpty ? "尚未记录任何 ~/.ssh/known_hosts 主机指纹" : "未找到匹配的已知主机指纹")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ApexStyle.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            entryRow(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let toast = toastMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(ApexStyle.success)
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ApexStyle.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear {
            manager.reload()
        }
        .alert("移除已知主机指纹", isPresented: $showingDeleteAlert, presenting: entryToDelete) { entry in
            Button("移除并备份", role: .destructive) {
                if (try? manager.removeEntry(id: entry.id)) == true {
                    showToast("已移除主机指纹并自动备份 known_hosts.bak")
                }
            }
            Button("取消", role: .cancel) {}
        } message: { entry in
            Text("确定要从 ~/.ssh/known_hosts 中移除「\(entry.displayHostTitle)」的 \(entry.algorithmBadge) 指纹（第 \(entry.lineNumber) 行）吗？下次连接该主机时将重新验证公钥。")
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 15))
                .foregroundColor(ApexStyle.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("检测到 \(manager.conflicts.count) 处主机指纹冲突 (REMOTE HOST IDENTIFICATION HAS CHANGED)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(ApexStyle.primary)
                Text(manager.conflicts.map(\.endpoint).joined(separator: ", "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(ApexStyle.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let firstConflict = manager.conflicts.first {
                ApexActionButton("一键清理冲突项", icon: "wand.and.stars", tint: ApexStyle.warning, size: .small) {
                    for conflict in manager.conflicts {
                        for item in conflict.conflictingEntries {
                            _ = try? manager.removeEntry(id: item.id)
                        }
                    }
                    showToast("已清理冲突主机指纹（比如重装系统后的旧公钥），请重新连接确认新指纹")
                }
                .help("清理 \(firstConflict.endpoint) 等冲突条目并自动生成 known_hosts.bak 备份")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ApexStyle.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: ApexStyle.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ApexStyle.cardRadius)
                .stroke(ApexStyle.warning.opacity(0.45), lineWidth: 1)
        )
    }

    private func entryRow(_ entry: KnownHostEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isHashed ? "number.shield" : "server.rack")
                .font(.system(size: 14))
                .foregroundColor(entry.marker == .revoked ? ApexStyle.error : ApexStyle.accent)
                .frame(width: 28, height: 28)
                .background(ApexStyle.surface, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.displayHostTitle)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(ApexStyle.primary)
                        .lineLimit(1)

                    Text(entry.algorithmBadge)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(entry.algorithmBadge == "ED25519" ? ApexStyle.success : ApexStyle.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((entry.algorithmBadge == "ED25519" ? ApexStyle.success : ApexStyle.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))

                    if entry.marker != .standard {
                        Text(entry.marker.rawValue)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(entry.marker == .revoked ? ApexStyle.error : ApexStyle.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((entry.marker == .revoked ? ApexStyle.error : ApexStyle.accent).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    }

                    Text("#\(entry.lineNumber)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary.opacity(0.75))
                }

                Text(entry.fingerprintSHA256)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(ApexStyle.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            HStack(spacing: 8) {
                ApexActionButton("复制指纹", icon: "doc.on.doc", tint: ApexStyle.accent, size: .small) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.fingerprintSHA256, forType: .string)
                    showToast("已复制 SHA-256 指纹到剪贴板")
                }

                ApexIconButton(
                    icon: "trash",
                    label: "移除此主机指纹",
                    size: 24,
                    iconSize: 11
                ) {
                    entryToDelete = entry
                    showingDeleteAlert = true
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: ApexStyle.cardRadius)
                .stroke(ApexStyle.border, lineWidth: 1)
        )
    }

    private func showToast(_ message: String) {
        withAnimation {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation {
                if toastMessage == message {
                    toastMessage = nil
                }
            }
        }
    }
}
