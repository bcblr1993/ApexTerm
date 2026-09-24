import SwiftUI
import Charts
import ApexCore

/// FinalShell-style live performance monitoring capsule (CPU, RAM, Network, Disk)
public struct MetricCapsuleView: View {
    @ObservedObject public var historyStore: ObservableMetricsHistory
    @State private var showingDetail = false
    
    public init(historyStore: ObservableMetricsHistory) {
        self.historyStore = historyStore
    }
    
    public var body: some View {
        Button(action: { showingDetail.toggle() }) {
            HStack(spacing: 12) {
                // CPU indicator
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(cpuColor)
                    
                    Text("CPU")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Text(String(format: "%.1f%%", latest?.cpuUsagePercent ?? 0))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                }
                
                Divider()
                    .frame(height: 12)
                
                // Memory indicator
                HStack(spacing: 5) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.cyan)
                    
                    Text(formattedMemory)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary)
                }
                
                Divider()
                    .frame(height: 12)
                
                // Network indicator
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.green)
                        Text(formatNetworkRate(latest?.networkRxBytesPerSec ?? 0))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.blue)
                        Text(formatNetworkRate(latest?.networkTxBytesPerSec ?? 0))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                }
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            MetricDetailView(historyStore: historyStore)
                .frame(width: 440, height: 320)
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
    
    private var formattedMemory: String {
        guard let m = latest, m.memoryTotalBytes > 0 else { return "0.0/0.0 GB" }
        let usedGB = Double(m.memoryUsedBytes) / (1024 * 1024 * 1024)
        let totalGB = Double(m.memoryTotalBytes) / (1024 * 1024 * 1024)
        return String(format: "%.1f/%.0fG (%.0f%%)", usedGB, totalGB, m.memoryUsagePercent)
    }
    
    private func formatNetworkRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return String(format: "%.0f B/s", bytesPerSec)
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f K/s", bytesPerSec / 1024)
        } else {
            return String(format: "%.1f M/s", bytesPerSec / (1024 * 1024))
        }
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

/// Detailed Swift Charts popup with hardware accelerated metrics curves
public struct MetricDetailView: View {
    @ObservedObject var historyStore: ObservableMetricsHistory
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Label("Live Server Performance", systemImage: "gauge.with.needle")
                    .font(.headline)
                Spacer()
                if let uptime = historyStore.latest?.uptimeSeconds {
                    Text("Uptime: \(formatUptime(uptime))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // CPU Chart
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("CPU Utilization")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(String(format: "%.1f%% (Cores: %d)", historyStore.latest?.cpuUsagePercent ?? 0, historyStore.latest?.cpuCores ?? 1))
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
                .frame(height: 90)
            }
            
            // Network Waterfall Chart
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Network Throughput (Rx / Tx)")
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
                            series: .value("Stream", "Download")
                        )
                        .foregroundStyle(Color.green)
                        
                        LineMark(
                            x: .value("Time", item.timestamp),
                            y: .value("Tx KB/s", item.networkTxBytesPerSec / 1024),
                            series: .value("Stream", "Upload")
                        )
                        .foregroundStyle(Color.blue)
                    }
                }
                .frame(height: 80)
            }
            
            // Disk Bar
            if let disk = historyStore.latest, disk.diskTotalBytes > 0 {
                HStack {
                    Text("Root Storage: \(String(format: "%.1f", Double(disk.diskUsedBytes) / 1e9)) GB / \(String(format: "%.1f", Double(disk.diskTotalBytes) / 1e9)) GB (\(String(format: "%.0f%%", disk.diskUsagePercent)))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                ProgressView(value: disk.diskUsagePercent, total: 100)
                    .progressViewStyle(.linear)
                    .tint(disk.diskUsagePercent > 85 ? .red : .blue)
            }
        }
        .padding(14)
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
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h \(mins)m"
    }
}
