import SwiftUI
import Charts
import ApexCore

/// FinalShell-style live performance monitoring capsule (CPU, RAM, Network, Disk) with Chinese localization
public struct MetricCapsuleView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject public var historyStore: ObservableMetricsHistory
    @State private var showingDetail = false
    private let compact: Bool
    private let monitoringEnabled: Bool
    private let connectionActive: Bool
    private let connectionConnecting: Bool

    public init(historyStore: ObservableMetricsHistory, compact: Bool = false, monitoringEnabled: Bool = true, connectionActive: Bool = true, connectionConnecting: Bool = false) {
        self.historyStore = historyStore
        self.compact = compact
        self.monitoringEnabled = monitoringEnabled
        self.connectionActive = connectionActive
        self.connectionConnecting = connectionConnecting
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            capsule(at: context.date)
        }
    }

    private func capsule(at date: Date) -> some View {
        let isStale = latest.map { date.timeIntervalSince($0.timestamp) > 30 } ?? false
        return Button(action: { showingDetail.toggle() }) {
            HStack(spacing: 12) {
                if monitoringEnabled && connectionConnecting {
                    ProgressView().controlSize(.mini)
                    Text("监控连接中")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ApexStyle.secondary)
                } else if monitoringEnabled && !connectionActive {
                    Image(systemName: "network.slash")
                    Text("监控连接已中断")
                        .foregroundStyle(ApexStyle.secondary)
                } else if latest == nil {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(ApexStyle.accent)
                    Text(monitoringEnabled ? "监控待命" : "监控已关闭")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ApexStyle.secondary)
                } else if isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                    Text("监控已过期")
                        .foregroundStyle(ApexStyle.secondary)
                } else if compact {
                    Image(systemName: "waveform.path.ecg")
                    Text(String(format: "CPU %.0f%%", latest?.cpuUsagePercent ?? 0))
                        .monospacedDigit()
                } else {
                    // CPU indicator
                    HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(cpuColor)

                    Text(L10n.cpuMetric)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)

                    Text(String(format: "%.1f%%", latest?.cpuUsagePercent ?? 0))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(ApexStyle.primary)
                    }

                    Divider().frame(height: 12)

                    // Memory indicator
                    HStack(spacing: 5) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(ApexStyle.accent)

                        Text(formattedMemory)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(ApexStyle.primary)
                    }

                    Divider().frame(height: 12)

                    // Disk indicator with SSD badge
                    HStack(spacing: 5) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(diskColor)

                        Text(L10n.diskMetric)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(ApexStyle.secondary)

                        Text(formattedDisk)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(ApexStyle.primary)

                        if let badge = latest?.diskBadgeText {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background((latest?.isSSD ?? true) ? ApexStyle.accent.opacity(0.18) : ApexStyle.warning.opacity(0.18))
                                .foregroundColor((latest?.isSSD ?? true) ? ApexStyle.accent : ApexStyle.warning)
                                .cornerRadius(3)
                        }
                    }
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(ApexStyle.secondary)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("metrics.summary")
        .controlSize(compact ? .regular : .small)
        .help(isStale ? "超过 30 秒未收到新指标，详情为最后一次采样" : "查看服务器性能")
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            MetricDetailView(historyStore: historyStore, monitoringEnabled: monitoringEnabled, connectionActive: connectionActive, connectionConnecting: connectionConnecting)
                .frame(width: 390)
        }
    }

    private var latest: ServerMetricsSnapshot? {
        monitoringEnabled ? historyStore.latest : nil
    }

    private var cpuColor: Color {
        let cpu = latest?.cpuUsagePercent ?? 0
        if cpu > 80 { return ApexStyle.error }
        if cpu > 50 { return ApexStyle.warning }
        return ApexStyle.success
    }

    private var diskColor: Color {
        let usage = latest?.diskUsagePercent ?? 0
        if usage > 85 { return ApexStyle.error }
        if usage > 70 { return ApexStyle.warning }
        return ApexStyle.accent
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

/// Native metric details are rendered only while the popover is visible.
public struct MetricDetailView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject var historyStore: ObservableMetricsHistory
    let monitoringEnabled: Bool
    let connectionActive: Bool
    let connectionConnecting: Bool

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            details(at: context.date)
        }
    }

    private func details(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            // Header
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "gauge.with.needle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                Text(L10n.serverPerformance)
                    .accessibilityIdentifier("metrics.detail.title")
                    .font(.system(size: 11.5, weight: .bold))

                if let cpuModel = latest?.cpuModel, !cpuModel.isEmpty {
                    Text(cpuModel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(ApexStyle.secondary.opacity(0.12))
                        .foregroundColor(ApexStyle.secondary)
                        .cornerRadius(3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if let uptime = latest?.uptimeSeconds {
                    Text(formatUptime(uptime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                }
            }

            if monitoringEnabled && connectionConnecting {
                Label("正在连接，等待新监控数据", systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(ApexStyle.secondary)
            } else if monitoringEnabled && !connectionActive {
                Label("连接已中断，以下为最后一次采样", systemImage: "network.slash")
                    .font(.caption)
                    .foregroundStyle(ApexStyle.secondary)
            } else if let snapshot = latest {
                let stale = date.timeIntervalSince(snapshot.timestamp) > 30
                Label(stale ? "数据已过期 · 最后采样 \(snapshot.timestamp.formatted(date: .omitted, time: .shortened))" : "最后采样 \(snapshot.timestamp.formatted(date: .omitted, time: .shortened))", systemImage: stale ? "clock.badge.exclamationmark" : "clock")
                    .font(.caption)
                    .foregroundStyle(ApexStyle.secondary)
            }

            Divider()

            if latest == nil {
                VStack(spacing: 8) {
                    if monitoringEnabled && (connectionActive || connectionConnecting) { ProgressView().controlSize(.small) }
                    Text(!monitoringEnabled ? "监控已关闭，可在会话设置中开启" : connectionConnecting ? "正在连接，等待监控数据…" : connectionActive ? "等待监控数据…" : "连接已中断，暂无监控数据")
                        .font(.caption)
                        .foregroundColor(ApexStyle.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 5) {
                    // CPU Row
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(cpuColor)
                            .frame(width: 10)
                        Text("CPU")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .frame(width: 44, alignment: .leading)

                    ProgressView(value: min(max(latest?.cpuUsagePercent ?? 0, 0), 100), total: 100)
                        .progressViewStyle(.linear)
                        .tint(cpuColor)

                    Text(String(format: "%.1f%% (%d核)", latest?.cpuUsagePercent ?? 0, latest?.cpuCores ?? 1))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(ApexStyle.primary)
                        .frame(width: 120, alignment: .trailing)
                }

                    // Memory Row
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(memColor)
                                .frame(width: 10)
                            Text("内存")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .frame(width: 44, alignment: .leading)

                        ProgressView(value: min(max(latest?.memoryUsagePercent ?? 0, 0), 100), total: 100)
                            .progressViewStyle(.linear)
                            .tint(memColor)

                        Text(formattedMemoryShort)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(ApexStyle.primary)
                            .frame(width: 120, alignment: .trailing)
                    }

                    // Disk Row with SSD/NVMe/HDD Badge
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "internaldrive.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(diskColor)
                                .frame(width: 10)
                            Text("磁盘")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .frame(width: 44, alignment: .leading)

                        ProgressView(value: min(max(latest?.diskUsagePercent ?? 0, 0), 100), total: 100)
                            .progressViewStyle(.linear)
                            .tint(diskColor)

                        HStack(spacing: 3) {
                            if let badge = latest?.diskBadgeText {
                                Text(badge)
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 0.5)
                                    .background((latest?.isSSD ?? true) ? ApexStyle.accent.opacity(0.18) : ApexStyle.warning.opacity(0.18))
                                    .foregroundColor((latest?.isSSD ?? true) ? ApexStyle.accent : ApexStyle.warning)
                                    .cornerRadius(2.5)
                            }
                            Text(formattedDiskShort)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(ApexStyle.primary)
                        }
                        .frame(width: 120, alignment: .trailing)
                    }

                    // Network Row
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(ApexStyle.accent)
                                .frame(width: 10)
                            Text("网络")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .frame(width: 44, alignment: .leading)

                        Spacer()

                        HStack(spacing: 12) {
                            HStack(spacing: 3) {
                                Text("↓")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(ApexStyle.success)
                                Text(formatRate(latest?.networkRxBytesPerSec ?? 0))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(ApexStyle.success)
                            }
                            HStack(spacing: 3) {
                                Text("↑")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(ApexStyle.accent)
                                Text(formatRate(latest?.networkTxBytesPerSec ?? 0))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(ApexStyle.accent)
                            }
                        }
                    }
                }

                Divider()

                if historyStore.snapshots.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CPU 与内存历史 (%)")
                            .font(.caption)
                            .foregroundStyle(ApexStyle.secondary)
                        Chart(historyStore.snapshots) { snapshot in
                            LineMark(x: .value("采样时间", snapshot.timestamp),
                                     y: .value("使用率", snapshot.cpuUsagePercent))
                                .foregroundStyle(by: .value("指标", "CPU"))
                            LineMark(x: .value("采样时间", snapshot.timestamp),
                                     y: .value("使用率", snapshot.memoryUsagePercent))
                                .foregroundStyle(by: .value("指标", "内存"))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                        .chartYScale(domain: 0...100)
                        .chartForegroundStyleScale(["CPU": ApexStyle.accent, "内存": ApexStyle.success])
                        .frame(height: 100)
                        .accessibilityIdentifier("metrics.history.chart")
                    }
                }

                // Top 3 Processes & Load Average
                if let procs = latest?.topProcesses, !procs.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Top 进程占用")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(ApexStyle.secondary)
                            Spacer()
                            if let l1 = latest?.loadAvg1m, let l5 = latest?.loadAvg5m, let l15 = latest?.loadAvg15m {
                                Text(String(format: "系统负载: %.2f  %.2f  %.2f", l1, l5, l15))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(ApexStyle.secondary)
                            }
                        }

                        VStack(spacing: 2) {
                            ForEach(procs.prefix(3)) { p in
                                HStack(spacing: 4) {
                                    Text("\(p.pid)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(ApexStyle.secondary)
                                        .frame(width: 34, alignment: .leading)
                                    Text(p.command)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(String(format: "%.1f%%", p.cpuPercent))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundColor(p.cpuPercent > 50 ? ApexStyle.error : (p.cpuPercent > 20 ? ApexStyle.warning : ApexStyle.primary))
                                        .frame(width: 40, alignment: .trailing)
                                    Text(String(format: "%.1f%%", p.memPercent))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(ApexStyle.secondary)
                                        .frame(width: 36, alignment: .trailing)
                                }
                                .padding(.vertical, 0.5)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ApexStyle.surface.opacity(0.6))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(11)
        .background(ApexStyle.surface)
    }

    private var latest: ServerMetricsSnapshot? {
        monitoringEnabled ? historyStore.latest : nil
    }

    private var cpuColor: Color {
        let cpu = latest?.cpuUsagePercent ?? 0
        if cpu > 80 { return ApexStyle.error }
        if cpu > 50 { return ApexStyle.warning }
        return ApexStyle.success
    }

    private var memColor: Color {
        let mem = latest?.memoryUsagePercent ?? 0
        if mem > 85 { return ApexStyle.error }
        if mem > 70 { return ApexStyle.warning }
        return ApexStyle.accent
    }

    private var diskColor: Color {
        let usage = latest?.diskUsagePercent ?? 0
        if usage > 85 { return ApexStyle.error }
        if usage > 70 { return ApexStyle.warning }
        return (latest?.isSSD ?? true) ? ApexStyle.accent : ApexStyle.accent
    }

    private var formattedMemoryShort: String {
        guard let m = latest, m.memoryTotalBytes > 0 else { return "--" }
        let usedGB = Double(m.memoryUsedBytes) / 1073741824.0
        let totalGB = Double(m.memoryTotalBytes) / 1073741824.0
        return String(format: "%.1f/%.0fG (%.0f%%)", usedGB, totalGB, m.memoryUsagePercent)
    }

    private var formattedDiskShort: String {
        guard let d = latest, d.diskTotalBytes > 0 else { return "--" }
        let usedGB = Double(d.diskUsedBytes) / 1e9
        let totalGB = Double(d.diskTotalBytes) / 1e9
        return String(format: "%.0f/%.0fG", usedGB, totalGB)
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
        if days > 0 { return "运行 \(days)天 \(hours)时" }
        return "运行 \(hours)时 \(mins)分"
    }
}
