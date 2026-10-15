import SwiftUI
import AppKit
import ApexCore

/// Centralized SSH Key Vault Manager view for Settings
public struct SSHKeyVaultSettingsView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject private var vaultManager = SSHKeyVaultManager.shared
    
    @State private var showingImportSheet: Bool = false
    @State private var showingDeploySheet: Bool = false
    @State private var selectedKeyForDeploy: SSHKeyIdentity?
    @State private var keyToDelete: SSHKeyIdentity?
    @State private var showingDeleteAlert: Bool = false
    @State private var toastMessage: String?
    
    // Import Form State
    @State private var importName: String = ""
    @State private var importPrivateKey: String = ""
    @State private var importPublicKey: String = ""
    @State private var importPassphrase: String = ""
    @State private var importError: String?
    
    // Deploy Form State
    @State private var deployHost: String = ""
    @State private var deployUser: String = "root"
    @State private var deployPort: String = "22"
    @State private var generatedDeployCommand: String = ""
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SSH 密钥保险库 (Key Vault)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(ApexStyle.primary)
                    Text("集中管理 SSH 密钥对，私钥采用 macOS 官方 Keychain 安全加密隔离")
                        .font(.system(size: 11))
                        .foregroundColor(ApexStyle.secondary)
                }
                
                Spacer()
                
                Button(action: {
                    importName = ""
                    importPrivateKey = ""
                    importPublicKey = ""
                    importPassphrase = ""
                    importError = nil
                    showingImportSheet = true
                }) {
                    Label("导入密钥", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 4)
            
            Divider()
            
            // Key List
            if vaultManager.keys.isEmpty {
                emptyVaultPlaceholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vaultManager.keys) { key in
                            keyRow(key)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            if let toast = toastMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(ApexStyle.success)
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ApexStyle.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
                .transition(.opacity)
            }
        }
        .padding(ApexStyle.s4)
        .sheet(isPresented: $showingImportSheet) {
            importKeySheet
        }
        .sheet(isPresented: $showingDeploySheet) {
            deployKeySheet
        }
        .alert("确认删除密钥", isPresented: $showingDeleteAlert, presenting: keyToDelete) { key in
            Button("删除", role: .destructive) {
                vaultManager.deleteKey(id: key.id)
                showToast("已从保险库和钥匙串中永久删除密钥")
            }
            Button("取消", role: .cancel) {}
        } message: { key in
            Text("确定要删除密钥「\(key.name)」吗？该操作同时将私钥从 macOS 钥匙串中清除，不可恢复。")
        }
    }
    
    // MARK: - Key Row
    private func keyRow(_ key: SSHKeyIdentity) -> some View {
        HStack(spacing: 12) {
            Image(systemName: key.algorithm == .ed25519 ? "key.fill" : "key")
                .font(.system(size: 16))
                .foregroundColor(key.algorithm == .ed25519 ? ApexStyle.accent : ApexStyle.secondary)
                .frame(width: 28, height: 28)
                .background(ApexStyle.surface, in: RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(key.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(ApexStyle.primary)
                    
                    // Algorithm badge
                    Text(key.algorithm.rawValue)
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(key.algorithm == .ed25519 ? ApexStyle.success : ApexStyle.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((key.algorithm == .ed25519 ? ApexStyle.success : ApexStyle.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    
                    if key.hasPassphrase {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 10))
                            .foregroundColor(ApexStyle.accent)
                            .help("带口令保护 (Passphrase-Protected)")
                    }
                }
                
                Text(key.fingerprintSHA256)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ApexStyle.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 6) {
                Button(action: {
                    copyPublicKey(key)
                }) {
                    Label("复制公钥", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(ApexStyle.accent)
                .help("复制 OpenSSH 公钥到剪贴板")
                
                Button(action: {
                    selectedKeyForDeploy = key
                    generatedDeployCommand = key.generateDeployCommand()
                    showingDeploySheet = true
                }) {
                    Label("一键部署", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(ApexStyle.accent)
                .help("一键免密分发公钥到远程服务器 (ssh-copy-id)")
                
                Button(action: {
                    keyToDelete = key
                    showingDeleteAlert = true
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(ApexStyle.error)
                }
                .buttonStyle(.plain)
                .help("删除密钥")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: ApexStyle.cardRadius)
                .stroke(ApexStyle.border, lineWidth: 1)
        }
    }
    
    // MARK: - Empty Placeholder
    private var emptyVaultPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.viewfinder")
                .font(.system(size: 32))
                .foregroundColor(ApexStyle.secondary.opacity(0.5))
            Text("尚未导入任何 SSH 密钥")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ApexStyle.secondary)
            Text("点击右上角「导入密钥」收纳您的 Ed25519 或 RSA 密钥对")
                .font(.system(size: 11))
                .foregroundColor(ApexStyle.secondary.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Import Sheet
    private var importKeySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入 SSH 密钥到安全保险库")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(ApexStyle.primary)
            
            Form {
                TextField("密钥名称 (如 Production Bastion)", text: $importName)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("私钥内容 (PEM 格式)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ApexStyle.secondary)
                    TextEditor(text: $importPrivateKey)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(height: 90)
                        .border(ApexStyle.border, width: 1)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("公钥内容 (OpenSSH 格式，如 ssh-ed25519 AAAAC3...)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ApexStyle.secondary)
                    TextField("公钥内容", text: $importPublicKey)
                        .font(.system(size: 10, design: .monospaced))
                }
                
                SecureField("密钥口令 Passphrase (可选)", text: $importPassphrase)
            }
            
            if let err = importError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(ApexStyle.error)
            }
            
            HStack {
                Spacer()
                Button("取消") {
                    showingImportSheet = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("导入并安全保存") {
                    doImportKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(importPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          importPublicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }
    
    // MARK: - Deploy Sheet
    private var deployKeySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("一键免密公钥分发 (ssh-copy-id)")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(ApexStyle.primary)
            
            if let key = selectedKeyForDeploy {
                Text("将密钥「\(key.name)」追加到远程主机的 ~/.ssh/authorized_keys")
                    .font(.system(size: 11))
                    .foregroundColor(ApexStyle.secondary)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("自动生成的部署命令 (已设置 0700/0600 严格权限):")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ApexStyle.primary)
                    
                    Text(generatedDeployCommand)
                        .font(.system(size: 10.5, design: .monospaced))
                        .padding(8)
                        .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                }
            }
            
            HStack {
                Button("复制部署命令") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(generatedDeployCommand, forType: .string)
                    showingDeploySheet = false
                    showToast("已复制免密部署指令到剪贴板")
                }
                .buttonStyle(.borderedProminent)
                
                Spacer()
                
                Button("完成") {
                    showingDeploySheet = false
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 260)
    }
    
    // MARK: - Operations
    private func doImportKey() {
        do {
            _ = try vaultManager.importKey(
                name: importName,
                privateKeyPEM: importPrivateKey,
                publicKeyOpenSSH: importPublicKey,
                passphrase: importPassphrase.isEmpty ? nil : importPassphrase
            )
            showingImportSheet = false
            showToast("成功导入 SSH 密钥到安全保险库")
        } catch {
            importError = error.localizedDescription
        }
    }
    
    private func copyPublicKey(_ key: SSHKeyIdentity) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKeyOpenSSH, forType: .string)
        showToast("已复制公钥到剪贴板 (\(key.algorithm.rawValue))")
    }
    
    private func showToast(_ msg: String) {
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if self.toastMessage == msg {
                self.toastMessage = nil
            }
        }
    }
}
