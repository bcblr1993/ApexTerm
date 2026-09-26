import SwiftUI
import ApexCore
import ApexSSH

/// Floating transfer status capsule & collapsible task drawer for SFTP operations
public struct TransferDrawer: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    public enum TransferFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case uploads = "上传"
        case downloads = "下载"
        public var id: String { rawValue }
    }
    
    @ObservedObject var manager = TransferManager.shared
    @Binding var isExpanded: Bool
    @State private var filter: TransferFilter = .all
    
    public init(isExpanded: Binding<Bool>) {
        self._isExpanded = isExpanded
    }
    
    private var filteredTasks: [TransferTask] {
        switch filter {
        case .all: return manager.tasks
        case .uploads: return manager.tasks.filter { $0.direction == .upload }
        case .downloads: return manager.tasks.filter { $0.direction == .download }
        }
    }
    
    private func count(for f: TransferFilter) -> Int {
        switch f {
        case .all: return manager.tasks.count
        case .uploads: return manager.tasks.filter { $0.direction == .upload }.count
        case .downloads: return manager.tasks.filter { $0.direction == .download }.count
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .foregroundColor(ApexStyle.accent)
                                .font(.system(size: 14))
                            Text("传输任务 (\(manager.tasks.count))")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        
                        Spacer()
                        
                        // Category Segmented Filter
                        Picker("", selection: $filter) {
                            ForEach(TransferFilter.allCases) { f in
                                Text("\(f.rawValue) (\(count(for: f)))").tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 200)
                        
                        if manager.tasks.contains(where: { $0.status == .completed || $0.status == .cancelled }) {
                            Button("清空记录") {
                                manager.clearCompleted()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                        
                        Button(action: { withAnimation(.spring(duration: 0.25)) { isExpanded = false } }) {
                            Label("收起传输任务", systemImage: "xmark")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(ApexStyle.surface)
                    
                    Divider()
                    
                    // Task List
                    if filteredTasks.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "tray")
                                .font(.system(size: 24))
                                .foregroundColor(ApexStyle.secondary)
                            Text(manager.tasks.isEmpty ? "暂无传输任务 (支持拖拽/点击上传与下载)" : "当前分类暂无任务")
                                .font(.system(size: 12))
                                .foregroundColor(ApexStyle.secondary)
                            Spacer()
                        }
                        .frame(height: 140)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(filteredTasks) { task in
                                    TransferTaskRow(task: task) {
                                        manager.cancelTask(id: task.id)
                                    }
                                }
                            }
                            .padding(10)
                        }
                        .frame(maxHeight: 240)
                    }
                }
                .background(ApexStyle.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(ApexStyle.secondary.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
            
            // Collapsed Floating Pill Trigger
            if manager.activeCount > 0 || !manager.tasks.isEmpty {
                Button {
                    withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: manager.activeCount > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(manager.activeCount > 0 ? ApexStyle.accent : ApexStyle.success)
                                .rotationEffect(.degrees(manager.activeCount > 0 ? 360 : 0))
                                .animation(manager.activeCount > 0 ? .linear(duration: 1.5).repeatForever(autoreverses: false) : .default, value: manager.activeCount)

                            Text(manager.activeCount > 0 ? "传输中 (\(manager.activeCount))" : "传输记录 (\(manager.tasks.count))")
                                .font(.system(size: 11, weight: .medium))
                        }

                        if manager.activeCount > 0 {
                            Text("·")
                                .foregroundColor(ApexStyle.secondary)
                            Text(manager.formattedTotalSpeed)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(ApexStyle.accent)
                        }

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(ApexStyle.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(ApexStyle.surface, in: Capsule())
                    .overlay(Capsule().stroke(ApexStyle.secondary.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起传输任务" : "展开传输任务")
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                .padding(.trailing, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct TransferTaskRow: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    let task: TransferTask
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Direction tag
                Text(task.direction == .upload ? "上传" : "下载")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(task.direction == .upload ? ApexStyle.accent.opacity(0.18) : ApexStyle.success.opacity(0.18))
                    .foregroundColor(task.direction == .upload ? ApexStyle.accent : ApexStyle.success)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                
                Image(systemName: task.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(task.direction == .upload ? ApexStyle.accent : ApexStyle.success)
                    .font(.system(size: 14))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.fileName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    
                    // Path detail
                    Text(pathDescription)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    HStack(spacing: 6) {
                        Text(statusLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(statusColor)
                        
                        if task.status == .transferring {
                            Text("·")
                                .foregroundColor(ApexStyle.secondary)
                            Text(task.formattedSpeed)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(ApexStyle.accent)
                            Text("·")
                                .foregroundColor(ApexStyle.secondary)
                            Text("\(formattedBytes(task.transferredBytes)) / \(formattedBytes(task.totalBytes))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(ApexStyle.secondary)
                        } else {
                            if task.totalBytes > 0 {
                                Text("·")
                                    .foregroundColor(ApexStyle.secondary)
                                Text(formattedBytes(task.totalBytes))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(ApexStyle.secondary)
                            }
                            if let date = task.completedAt ?? task.startedAt as Date? {
                                Text("·")
                                    .foregroundColor(ApexStyle.secondary)
                                Text(formatTime(date))
                                    .font(.system(size: 10))
                                    .foregroundColor(ApexStyle.secondary)
                            }
                        }
                    }
                }
                
                Spacer()
                
                if task.status == .transferring || task.status == .queued {
                    Text(task.formattedProgress)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(ApexStyle.accent)
                    
                    Button(action: onCancel) {
                        Label("取消传输 \(task.fileName)", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.leading, 4)
                } else if task.status == .completed {
                    HStack(spacing: 6) {
                        // Reveal in Finder button for downloads
                        if task.direction == .download && FileManager.default.fileExists(atPath: task.localURL.path) {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([task.localURL])
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .help("在访达中显示此文件")
                        }
                        
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(ApexStyle.success)
                    }
                } else if case .failed = task.status {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(ApexStyle.error)
                }
            }
            
            if task.status == .transferring || task.status == .queued {
                ProgressView(value: task.progress)
                    .progressViewStyle(.linear)
                    .tint(ApexStyle.accent)
            }
        }
        .padding(8)
        .background(ApexStyle.subtleSurface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var pathDescription: String {
        if task.direction == .upload {
            return "\(task.localURL.lastPathComponent) → \(task.remotePath)"
        } else {
            return "\(task.remotePath) → \(task.localURL.path)"
        }
    }
    
    private var statusLabel: String {
        switch task.status {
        case .queued: return "等待中"
        case .transferring: return task.direction == .upload ? "正在上传" : "正在下载"
        case .completed: return "传输完成"
        case .failed(let err): return "传输失败: \(err)"
        case .cancelled: return "已取消"
        }
    }
    
    private var statusColor: Color {
        switch task.status {
        case .queued: return ApexStyle.secondary
        case .transferring: return ApexStyle.accent
        case .completed: return ApexStyle.success
        case .failed: return ApexStyle.error
        case .cancelled: return ApexStyle.secondary
        }
    }
    
    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
