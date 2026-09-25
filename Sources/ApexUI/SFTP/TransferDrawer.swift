import SwiftUI
import ApexCore
import ApexSSH

/// Floating transfer status capsule & collapsible task drawer for SFTP operations
public struct TransferDrawer: View {
    @ObservedObject var manager = TransferManager.shared
    @Binding var isExpanded: Bool
    
    public init(isExpanded: Binding<Bool>) {
        self._isExpanded = isExpanded
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
                        
                        if manager.tasks.contains(where: { $0.status == .completed || $0.status == .cancelled }) {
                            Button("清空已完成") {
                                manager.clearCompleted()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }
                        
                        Button(action: { withAnimation(.spring(duration: 0.25)) { isExpanded = false } }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(ApexStyle.surface)
                    
                    Divider()
                    
                    // Task List
                    if manager.tasks.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "tray")
                                .font(.system(size: 24))
                                .foregroundColor(.secondary)
                            Text("暂无传输任务")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .frame(height: 140)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(manager.tasks) { task in
                                    TransferTaskRow(task: task) {
                                        manager.cancelTask(id: task.id)
                                    }
                                }
                            }
                            .padding(10)
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .background(ApexStyle.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
            
            // Collapsed Floating Pill Trigger
            if manager.activeCount > 0 || !manager.tasks.isEmpty {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: manager.activeCount > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(manager.activeCount > 0 ? ApexStyle.accent : ApexStyle.success)
                            .rotationEffect(.degrees(manager.activeCount > 0 ? 360 : 0))
                            .animation(manager.activeCount > 0 ? .linear(duration: 1.5).repeatForever(autoreverses: false) : .default, value: manager.activeCount)
                        
                        Text(manager.activeCount > 0 ? "传输中 (\(manager.activeCount))" : "传输完成")
                            .font(.system(size: 11, weight: .medium))
                    }
                    
                    if manager.activeCount > 0 {
                        Text("·")
                            .foregroundColor(.secondary)
                        Text(manager.formattedTotalSpeed)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(ApexStyle.accent)
                    }
                    
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(ApexStyle.surface, in: Capsule())
                .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct TransferTaskRow: View {
    let task: TransferTask
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: task.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundColor(task.direction == .upload ? ApexStyle.accent : .green)
                    .font(.system(size: 15))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.fileName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        Text(statusLabel)
                            .font(.system(size: 10))
                            .foregroundColor(statusColor)
                        
                        if task.status == .transferring {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text(task.formattedSpeed)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("·")
                                .foregroundColor(.secondary)
                            Text("\(formattedBytes(task.transferredBytes)) / \(formattedBytes(task.totalBytes))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                if task.status == .transferring || task.status == .queued {
                    Text(task.formattedProgress)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(ApexStyle.accent)
                    
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                } else if task.status == .completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(ApexStyle.success)
                } else if case .failed = task.status {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
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
        case .queued: return .secondary
        case .transferring: return ApexStyle.accent
        case .completed: return ApexStyle.success
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
    
    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
