import SwiftUI
import AppKit
import ApexCore
import ApexSSH

/// Modal sheet inspecting a remote SFTP file or directory's metadata, permissions, and remote SHA-256 / MD5 checksums.
public struct SFTPFileInspectorSheet: View {
    public let item: SFTPItem
    public let session: SSHSessionProtocol?

    @Environment(\.dismiss) private var dismiss
    @State private var algorithm: SFTPChecksumAlgorithm = .sha256
    @State private var computedDigest: String?
    @State private var isComputingChecksum = false
    @State private var checksumError: String?
    @State private var expectedDigestInput: String = ""
    @State private var copyFeedback: String?

    public init(item: SFTPItem, session: SSHSessionProtocol?) {
        self.item = item
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: item.isDirectory ? "folder.fill" : (item.isSymlink ? "link" : "doc.text.fill"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(item.isDirectory ? ApexStyle.accent : ApexStyle.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ApexStyle.primary)
                        .lineLimit(1)
                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                ApexIconButton(icon: "xmark", label: "关闭属性面板", size: 24, iconSize: 11) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 12)
            .background(ApexStyle.subtleSurface.opacity(0.8))

            Divider()

            Form {
                Section("基本属性与权限") {
                    inspectorRow(label: "完整路径", value: item.path, copyable: true)
                    inspectorRow(
                        label: "类型",
                        value: item.isDirectory ? "目录 (Directory)" : (item.isSymlink ? "符号链接 (Symlink)" : "常规文件 (File)")
                    )
                    if !item.isDirectory {
                        inspectorRow(
                            label: "文件大小",
                            value: "\(item.formattedSize) (\(NumberFormatter.localizedString(from: NSNumber(value: item.size), number: .decimal)) 字节)"
                        )
                    }
                    inspectorRow(
                        label: "权限掩码",
                        value: "\(item.octalPermissionString) · \(item.permissionString)",
                        copyable: true
                    )
                    inspectorRow(
                        label: "最后修改时间",
                        value: item.modificationDate.formatted(date: .numeric, time: .standard)
                    )
                }

                if !item.isDirectory {
                    Section("远端文件完整性校验 (SHA-256 / MD5)") {
                        HStack {
                            Picker("算法", selection: $algorithm) {
                                ForEach(SFTPChecksumAlgorithm.allCases) { algo in
                                    Text(algo.rawValue).tag(algo)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                            .onChange(of: algorithm) { _, _ in
                                computeChecksum()
                            }

                            Spacer()

                            ApexActionButton(
                                isComputingChecksum ? "计算中..." : "重新计算",
                                icon: "arrow.clockwise",
                                tint: ApexStyle.accent,
                                size: .small
                            ) {
                                computeChecksum()
                            }
                            .disabled(isComputingChecksum)
                        }

                        if isComputingChecksum {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在远端服务器计算 \(algorithm.rawValue) 摘要...")
                                    .font(.caption)
                                    .foregroundColor(ApexStyle.secondary)
                            }
                        } else if let digest = computedDigest {
                            HStack(spacing: 8) {
                                Text(digest)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(ApexStyle.primary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                Spacer()
                                ApexActionButton("复制摘要", icon: "doc.on.doc", tint: ApexStyle.secondary, size: .small) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(digest, forType: .string)
                                    copyFeedback = "已复制 \(algorithm.rawValue) 摘要"
                                }
                            }
                        } else if let err = checksumError {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(ApexStyle.warning)
                        }

                        TextField("粘贴期望的 \(algorithm.rawValue) 值或 SHA256SUMS 行进行比对...", text: $expectedDigestInput)
                            .font(.system(size: 11.5, design: .monospaced))
                            .accessibilityLabel("期望校验值比对输入框")
                            .accessibilityIdentifier("sftp.inspector.expectedDigest")

                        if let computed = computedDigest,
                           let matched = SFTPInspectorHelper.verifyChecksum(computed: computed, expectedInput: expectedDigestInput) {
                            HStack(spacing: 6) {
                                Image(systemName: matched ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                    .foregroundColor(matched ? ApexStyle.success : ApexStyle.error)
                                Text(matched ? "校验一致：远端文件哈希与期望值完全匹配" : "哈希不匹配：远端文件可能已损坏或版本不一致")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(matched ? ApexStyle.success : ApexStyle.error)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let feedback = copyFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundColor(ApexStyle.accent)
                }
                Spacer()
                ApexActionButton("完成", icon: "checkmark", tint: ApexStyle.accent, size: .regular, isProminent: true) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 10)
            .background(ApexStyle.surface)
        }
        .frame(width: 520, height: item.isDirectory ? 320 : 480)
        .onAppear {
            if !item.isDirectory {
                computeChecksum()
            }
        }
    }

    @ViewBuilder
    private func inspectorRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundColor(ApexStyle.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(ApexStyle.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if copyable {
                ApexIconButton(icon: "doc.on.doc", label: "复制 \(label)", size: 20, iconSize: 10) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copyFeedback = "已复制\(label)"
                }
            }
        }
    }

    private func computeChecksum() {
        guard !item.isDirectory else { return }
        isComputingChecksum = true
        computedDigest = nil
        checksumError = nil

        let currentAlgo = algorithm
        Task {
            let digest = await SFTPInspectorHelper.computeRemoteChecksum(for: item, algorithm: currentAlgo, session: session)
            await MainActor.run {
                self.isComputingChecksum = false
                if let digest = digest {
                    self.computedDigest = digest
                } else {
                    self.checksumError = "无法获取远端文件摘要（请确认会话已连接且具备读取权限）"
                }
            }
        }
    }
}
