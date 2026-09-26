import SwiftUI
import Charts
import ApexCore

/// FinalShell-style live performance monitoring capsule (CPU, RAM, Network, Disk) with Chinese localization & no-stutter charts
public struct MetricCapsuleView: View {
    @ObservedObject public var historyStore: ObservableMetricsHistory
    @State private var showingDetail = false
    
    public init(historyStore: ObservableMetricsHistory) {
        self.historyStore = historyStore
    }
    
    public var body: some View {
        Button(action: { showingDetail.toggle() }) {
            HStack(spacing: 12) {
                if latest == nil {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(ApexStyle.accent)
                    Text("监控待命")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    // CPU indicator
                    HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(cpuColor)
                    
                    Text(L10n.cpuMetric)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Text(String(format: "%.1f%%", latest?.cpuUsagePercent ?? 0))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                    }

                    Divider().frame(height: 12)

                    // Memory indicator
                    HStack(spacing: 5) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(ApexStyle.accent)
                        
                        Text(formattedMemory)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary)
                    }

                    Divider().frame(height: 12)

                    // Disk indicator with SSD badge
                    HStack(spacing: 5) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(diskColor)
                        
                        Text(L10n.diskMetric)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                        
                        Text(formattedDisk)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.primary)
                        
                        if let badge = latest?.diskBadgeText {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background((latest?.isSSD ?? true) ? Color.teal.opacity(0.18) : Color.orange.opacity(0.18))
                                .foregroundColor((latest?.isSSD ?? true) ? .teal : .orange)
                                .cornerRadius(3)
                        }
                    }
                }
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("查看服务器性能")
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            MetricDetailView(historyStore: historyStore)
                .frame(width: 500, height: 480)
        }
    }
    
    private var latest: ServerMetricsSnapshot? {
        historyStore.latest
    }
    
    private var cpuColor: Color {
        let cpu = latest?.cpuUsagePercent ?? 0
        if cpu > 80 { return .red }
        if cpu > 50 { return .orange }
        return .green
    }
    
    private var diskColor: Color {
        let usage = latest?.diskUsagePercent ?? 0
        if usage > 85 { return .red }
        if usage > 70 { return .orange }
        return .teal
    }
    
    private var formattedMemory: String {
        guard let m = latest, m.memoryTotalBytes > 0 else { return "0.0/0.0 GB" }
        let usedGB = Double(m.memoryUsedBytes) / (1024 * 1024 * 1024)
        let totalGB = Double(m.memoryTotalBytes) / (1024 * 1024 * 1024)
        return String(format: "%.1f/%.0fG (%.0f%%)", usedGB, totalGB, m.memoryUsagePercent)
    }
    
    private var formattedDisk: String {
        guard let d = latest, d.diskTotalBytes > 0 else { return "0/0G" }
        let usedGB = Double(d.diskUsedBytes) / 1e9
        let totalGB = Double(d.diskTotalBytes) / 1e9
        return String(format: "%.0f/%.0fG", usedGB, totalGB)
    }
    
}

/// Observable wrapper for SwiftUI reactivity
@MainActor
public final class ObservableMetricsHistory: ObservableObject {
    public let store = MetricsHistoryStore(maxEntries: 40)
    @Published public var snapshots: [ServerMetricsSnapshot] = []
    
    public init() {}
    
    public var latest: ServerMetricsSnapshot? {
        snapshots.last
    }
    
    public func append(_ snapshot: ServerMetricsSnapshot) {
        store.append(snapshot)
        self.snapshots = store.allSnapshots
    }
}

/// Detailed Swift Charts popup with hardware accelerated metrics curves and no-bounce animation
public struct MetricDetailView: View {
    @ObservedObject var historyStore: ObservableMetricsHistory
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                // Header
                HStack(alignment: .center, spacing: 8) {
                    Label(L10n.serverPerformance, systemImage: "gauge.with.needle")
                        .font(.headline)
                    if let cpuModel = historyStore.latest?.cpuModel, !cpuModel.isEmpty {
                        Text(cpuModel)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.secondary)
                            .cornerRadius(4)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let uptime = historyStore.latest?.uptimeSeconds {
                        Text("\(L10n.uptime): \(formatUptime(uptime))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Divider()

                if historyStore.snapshots.isEmpty {
                    ContentUnavailableView("等待监控数据", systemImage: "waveform.path.ecg", description: Text("连接建立后，指标会显示在这里。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                
                // CPU Chart
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L10n.cpuUtilization)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(String(format: "%.1f%% (%@: %d)", historyStore.latest?.cpuUsagePercent ?? 0, L10n.cpuCores, historyStore.latest?.cpuCores ?? 1))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Chart(historyStore.snapshots) { item in
                        LineMark(
                            x: .value("Time", item.timestamp),
                            y: .value("CPU %", item.cpuUsagePercent)
                        )
                        .foregroundStyle(Color.green.gradient)
                        .interpolationMethod(.monotone)
                        
                        AreaMark(
                            x: .value("Time", item.timestamp),
                            y: .value("CPU %", item.cpuUsagePercent)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.green.opacity(0.35), Color.green.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 0...100)
                    .animation(nil, value: historyStore.snapshots.count) // Disable bouncy re-interpolation
                    .frame(height: 90)
                }
                
                // Memory Bar
                if let mem = historyStore.latest, mem.memoryTotalBytes > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.ramMetric)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("\(String(format: "%.1f", Double(mem.memoryUsedBytes) / 1073741824.0)) GB / \(String(format: "%.1f", Double(mem.memoryTotalBytes) / 1073741824.0)) GB (\(String(format: "%.0f%%", mem.memoryUsagePercent)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        ProgressView(value: mem.memoryUsagePercent, total: 100)
                            .progressViewStyle(.linear)
                            .tint(mem.memoryUsagePercent > 85 ? .red : ApexStyle.accent)
                    }
                }
                
                // Network Waterfall Chart
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(L10n.networkThroughput)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        HStack(spacing: 8) {
                            Text("↓ \(formatRate(historyStore.latest?.networkRxBytesPerSec ?? 0))")
                                .font(.caption)
                                .foregroundColor(.green)
                            Text("↑ \(formatRate(historyStore.latest?.networkTxBytesPerSec ?? 0))")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    Chart {
                        ForEach(historyStore.snapshots) { item in
                            LineMark(
                                x: .value("Time", item.timestamp),
                                y: .value("Rx KB/s", item.networkRxBytesPerSec / 1024),
                                series: .value("Stream", L10n.downloadStream)
                            )
                            .foregroundStyle(Color.green)
                            
                            LineMark(
                                x: .value("Time", item.timestamp),
                                y: .value("Tx KB/s", item.networkTxBytesPerSec / 1024),
                                series: .value("Stream", L10n.uploadStream)
                            )
                            .foregroundStyle(Color.blue)
                        }
                    }
                    .animation(nil, value: historyStore.snapshots.count) // Disable bouncy re-interpolation
                    .frame(height: 80)
                }
                
                // Disk Storage & Hardware Type (SSD vs HDD)
                if let disk = historyStore.latest, disk.diskTotalBytes > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center) {
                            HStack(spacing: 5) {
                                Image(systemName: "internaldrive.fill")
                                    .foregroundColor(disk.isSSD ? .teal : .orange)
                                Text("磁盘存储")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            
                            // Prominent SSD/HDD Tag
                            HStack(spacing: 3) {
                                Image(systemName: disk.isSSD ? "bolt.horizontal.fill" : "opticaldisc")
                                    .font(.system(size: 9))
                                Text(disk.diskBadgeText)
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(disk.isSSD ? Color.teal.opacity(0.18) : Color.orange.opacity(0.18))
                            .foregroundColor(disk.isSSD ? .teal : .orange)
                            .cornerRadius(4)
                            
                            if !disk.diskDevice.isEmpty {
                                Text(disk.diskDevice)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Text("\(String(format: "%.1f", Double(disk.diskUsedBytes) / 1e9)) GB / \(String(format: "%.1f", Double(disk.diskTotalBytes) / 1e9)) GB (\(String(format: "%.0f%%", disk.diskUsagePercent)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        ProgressView(value: disk.diskUsagePercent, total: 100)
                            .progressViewStyle(.linear)
                            .tint(disk.diskUsagePercent > 85 ? .red : (disk.diskUsagePercent > 70 ? .orange : (disk.isSSD ? .teal : .blue)))
                        
                        HStack {
                            Text("挂载点: \(disk.diskMountPoint)")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("可用空间: \(String(format: "%.1f GB", Double(disk.diskFreeBytes) / 1e9))")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                    .cornerRadius(8)
                }
                
                // Top 5 Processes Table
                if let procs = historyStore.latest?.topProcesses, !procs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Top 进程资源占用")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Text("按 CPU 占用排序")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(spacing: 3) {
                            HStack {
                                Text("PID").frame(width: 46, alignment: .leading)
                                Text("用户").frame(width: 55, alignment: .leading)
                                Text("CPU %").frame(width: 52, alignment: .trailing)
                                Text("内存 %").frame(width: 52, alignment: .trailing)
                                Text("命令").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 2)
                            
                            Divider()
                            
                            ForEach(procs) { p in
                                HStack {
                                    Text("\(p.pid)").frame(width: 46, alignment: .leading)
                                    Text(p.user).frame(width: 55, alignment: .leading)
                                    Text(String(format: "%.1f%%", p.cpuPercent))
                                        .frame(width: 52, alignment: .trailing)
                                        .foregroundColor(p.cpuPercent > 50 ? .red : (p.cpuPercent > 20 ? .orange : .primary))
                                    Text(String(format: "%.1f%%", p.memPercent))
                                        .frame(width: 52, alignment: .trailing)
                                    Text(p.command)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.vertical, 1)
                            }
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                        .cornerRadius(6)
                    }
                }
                }
            }
            .padding(18)
        }
        .background(ApexStyle.surface)
    }
    
    private func formatRate(_ b: Double) -> String {
        if b < 1024 { return String(format: "%.0f B/s", b) }
        if b < 1024 * 1024 { return String(format: "%.1f KB/s", b / 1024) }
        return String(format: "%.2f MB/s", b / 1024 / 1024)
    }
    
    private func formatUptime(_ s: UInt64) -> String {
        let days = s / 86400
        let hours = (s % 86400) / 3600
        let mins = (s % 3600) / 60
        if days > 0 { return "\(days)天 \(hours)小时" }
        return "\(hours)小时 \(mins)分"
    }
}
