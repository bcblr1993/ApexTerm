import SwiftUI
import Charts
import ApexCore

/// FinalShell-style live performance monitoring capsule (CPU, RAM, Network, Disk) with Chinese localization
public struct MetricCapsuleView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @ObservedObject public var historyStore: ObservableMetricsHistory
    @State private var localShowingDetail = false
    @State private var isCapsuleHovered = false
    private let externalShowingDetail: Binding<Bool>?
    private let compact: Bool
    private let monitoringEnabled: Bool
    private let connectionActive: Bool
    private let connectionConnecting: Bool

    /// Pass `isDetailPresented` when the capsule lives in a toolbar: the host then presents the
    /// detail itself. SwiftUI rebuilds toolbar item hosts on unrelated state changes, which
    /// tears down a popover anchored there (it closes or re-presents as a non-key window).
    public init(historyStore: ObservableMetricsHistory, compact: Bool = false, monitoringEnabled: Bool = true, connectionActive: Bool = true, connectionConnecting: Bool = false, isDetailPresented: Binding<Bool>? = nil) {
        self.historyStore = historyStore
        self.compact = compact
        self.monitoringEnabled = monitoringEnabled
        self.connectionActive = connectionActive
        self.connectionConnecting = connectionConnecting
        self.externalShowingDetail = isDetailPresented
    }

    private var showingDetail: Binding<Bool> {
        externalShowingDetail ?? $localShowingDetail
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            capsule(at: context.date)
        }
    }

    private func capsule(at date: Date) -> some View {
        let isStale = latest.map { date.timeIntervalSince($0.timestamp) > 30 } ?? false
        return Button(action: {
            withAnimation(ApexStyle.springSnappy) {
                showingDetail.wrappedValue.toggle()
            }
        }) {
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
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 3 : 4)
            .background(
                Capsule()
                    .fill(isCapsuleHovered ? ApexStyle.subtleSurface : ApexStyle.subtleSurface.opacity(0.75))
            )
            .overlay(
                Capsule()
                    .stroke(isCapsuleHovered ? ApexStyle.accent.opacity(0.5) : ApexStyle.border.opacity(0.6), lineWidth: 0.75)
            )
            .scaleEffect(isCapsuleHovered ? 1.02 : 1.0)
            .animation(ApexStyle.springSnappy, value: isCapsuleHovered)
        }
        .buttonStyle(.plain)
        .onHover { isCapsuleHovered = $0 }
        .accessibilityIdentifier("metrics.summary")
        .controlSize(compact ? .regular : .small)
        .help(isStale ? "超过 30 秒未收到新指标，详情为最后一次采样" : "查看服务器性能")
        .modifier(InlineDetailPopover(isEnabled: externalShowingDetail == nil, isPresented: $localShowingDetail) {
            MetricDetailView(historyStore: historyStore, monitoringEnabled: monitoringEnabled, connectionActive: connectionActive, connectionConnecting: connectionConnecting)
        })
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

    public func clear() {
        store.clear()
        self.snapshots.removeAll(keepingCapacity: false)
    }
}

/// Standalone capsules (outside a toolbar) keep presenting their own popover.
private struct InlineDetailPopover<Detail: View>: ViewModifier {
    let isEnabled: Bool
    @Binding var isPresented: Bool
    @ViewBuilder let detail: () -> Detail

    func body(content: Content) -> some View {
        if isEnabled {
            content.popover(isPresented: $isPresented, arrowEdge: .bottom) {
                detail()
                    .frame(width: 416)
                    .onExitCommand { isPresented = false }
            }
        } else {
            content
        }
    }
}

/// Smooth native capsule progress bar with high-contrast track in both Light and Dark themes
private struct ApexMetricProgressBar: View {
    let percentage: Double
    let tint: Color

    private var clampedFraction: CGFloat {
        CGFloat(min(max(percentage, 0), 100) / 100.0)
    }

    var body: some View {
        GeometryReader { geo in
            let fullWidth = max(0, geo.size.width)
            let fillWidth = clampedFraction > 0 ? max(6, fullWidth * clampedFraction) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ApexStyle.primary.opacity(0.08))
                    .overlay(
                        Capsule()
                            .stroke(ApexStyle.border.opacity(0.45), lineWidth: 0.5)
                    )

                if fillWidth > 0 {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.85), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: min(fullWidth, fillWidth))
                        .shadow(color: tint.opacity(0.25), radius: 2, x: 0, y: 0)
                }
            }
            .animation(ApexStyle.springSmooth, value: clampedFraction)
        }
        .frame(height: 6)
    }
}

/// Native metric details are rendered only while the popover is visible.
public struct MetricDetailView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var historyStore: ObservableMetricsHistory
    let monitoringEnabled: Bool
    let connectionActive: Bool
    let connectionConnecting: Bool
    /// Hosts that present the detail outside a popover supply their own close action.
    var onDismiss: (() -> Void)? = nil

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            details(at: context.date)
        }
    }

    private func details(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "gauge.with.needle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(ApexStyle.accent)
                Text(L10n.serverPerformance)
                    .accessibilityIdentifier("metrics.detail.title")
                    .font(.system(size: 12, weight: .bold))

                if let cpuModel = latest?.cpuModel, !cpuModel.isEmpty {
                    Text(cpuModel)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(ApexStyle.primary.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(ApexStyle.border.opacity(0.45), lineWidth: 0.5)
                        )
                        .foregroundColor(ApexStyle.secondary)
                        .cornerRadius(4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if let uptime = latest?.uptimeSeconds {
                    Text(formatUptime(uptime))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            HStack(alignment: .center, spacing: 6) {
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
                    HStack(spacing: 5) {
                        Circle()
                            .fill(stale ? ApexStyle.warning : ApexStyle.success)
                            .frame(width: 6, height: 6)
                            .shadow(color: (stale ? ApexStyle.warning : ApexStyle.success).opacity(0.45), radius: 2)
                        Text(stale ? "数据已过期 · 最后采样 \(snapshot.timestamp.formatted(date: .omitted, time: .standard))" : "实时采样 · \(snapshot.timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11, design: .monospaced))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(ApexStyle.secondary)
                    }
                }

                Spacer()

                if let l1 = latest?.loadAvg1m, let l5 = latest?.loadAvg5m, let l15 = latest?.loadAvg15m {
                    Text(String(format: "负载 %.2f · %.2f · %.2f", l1, l5, l15))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                }
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
                // Core Resource Gauges (CPU, Memory, Swap, Disk)
                VStack(spacing: 6) {
                    // CPU Row
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(cpuColor)
                                .frame(width: 12)
                            Text("CPU")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .frame(width: 46, alignment: .leading)

                        ApexMetricProgressBar(percentage: latest?.cpuUsagePercent ?? 0, tint: cpuColor)

                        Text(String(format: "%.1f%% (%d核)", latest?.cpuUsagePercent ?? 0, latest?.cpuCores ?? 1))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundColor(ApexStyle.primary)
                            .lineLimit(1)
                            .frame(width: 146, alignment: .trailing)
                    }

                    // Memory Row
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "memorychip")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(memColor)
                                .frame(width: 12)
                            Text("内存")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .frame(width: 46, alignment: .leading)

                        ApexMetricProgressBar(percentage: latest?.memoryUsagePercent ?? 0, tint: memColor)

                        Text(formattedMemoryShort)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundColor(ApexStyle.primary)
                            .lineLimit(1)
                            .frame(width: 146, alignment: .trailing)
                    }

                    // Swap Memory Row
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(swapColor)
                                .frame(width: 12)
                            Text("交换")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .frame(width: 46, alignment: .leading)

                        ApexMetricProgressBar(percentage: latest?.swapUsagePercent ?? 0, tint: swapColor)

                        Text(formattedSwapShort)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundColor((latest?.swapTotalBytes ?? 0) > 0 ? ApexStyle.primary : ApexStyle.secondary)
                            .lineLimit(1)
                            .frame(width: 146, alignment: .trailing)
                    }

                    // Disk Row with SSD/NVMe/HDD Badge (single-line guaranteed)
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "internaldrive.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(diskColor)
                                .frame(width: 12)
                            Text("磁盘")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        }
                        .frame(width: 46, alignment: .leading)

                        ApexMetricProgressBar(percentage: latest?.diskUsagePercent ?? 0, tint: diskColor)

                        HStack(spacing: 4) {
                            if let badge = latest?.diskBadgeText {
                                Text(badge)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background((latest?.isSSD ?? true) ? ApexStyle.accent.opacity(0.16) : ApexStyle.warning.opacity(0.18))
                                    .foregroundColor((latest?.isSSD ?? true) ? ApexStyle.accent : ApexStyle.warning)
                                    .cornerRadius(3)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Text(formattedDiskShort)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundColor(ApexStyle.primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(width: 146, alignment: .trailing)
                    }
                }
                .padding(.vertical, 2)

                // Real-Time Network Throughput Card & Smooth Curve
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(ApexStyle.accent)
                            Text("网络实时吞吐")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(ApexStyle.primary)
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            HStack(spacing: 3) {
                                Text("↓")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(ApexStyle.success)
                                Text(formatRate(latest?.networkRxBytesPerSec ?? 0))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .foregroundColor(ApexStyle.success)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ApexStyle.success.opacity(0.10), in: Capsule())

                            HStack(spacing: 3) {
                                Text("↑")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(ApexStyle.accent)
                                Text(formatRate(latest?.networkTxBytesPerSec ?? 0))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .foregroundColor(ApexStyle.accent)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ApexStyle.accent.opacity(0.10), in: Capsule())
                        }
                    }

                    if chartSnapshots.count >= 2 {
                        let netPeak = networkChartUpperBound
                        Chart {
                            ForEach(chartSnapshots) { snapshot in
                                AreaMark(
                                    x: .value("时间", snapshot.timestamp),
                                    y: .value("速率", snapshot.networkRxBytesPerSec),
                                    series: .value("方向", "下载")
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [ApexStyle.success.opacity(0.24), ApexStyle.success.opacity(0.02)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("时间", snapshot.timestamp),
                                    y: .value("速率", snapshot.networkRxBytesPerSec),
                                    series: .value("方向", "下载")
                                )
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(ApexStyle.success)

                                AreaMark(
                                    x: .value("时间", snapshot.timestamp),
                                    y: .value("速率", snapshot.networkTxBytesPerSec),
                                    series: .value("方向", "上传")
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [ApexStyle.accent.opacity(0.20), ApexStyle.accent.opacity(0.02)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("时间", snapshot.timestamp),
                                    y: .value("速率", snapshot.networkTxBytesPerSec),
                                    series: .value("方向", "上传")
                                )
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(ApexStyle.accent)
                            }

                            if let last = chartSnapshots.last {
                                PointMark(
                                    x: .value("时间", last.timestamp),
                                    y: .value("速率", last.networkRxBytesPerSec)
                                )
                                .symbolSize(20)
                                .foregroundStyle(ApexStyle.success)

                                PointMark(
                                    x: .value("时间", last.timestamp),
                                    y: .value("速率", last.networkTxBytesPerSec)
                                )
                                .symbolSize(20)
                                .foregroundStyle(ApexStyle.accent)
                            }
                        }
                        .chartYScale(domain: 0...netPeak)
                        .chartYAxis {
                            AxisMarks(position: .trailing, values: [0, netPeak * 0.5, netPeak]) { value in
                                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                                    .foregroundStyle(ApexStyle.border.opacity(0.45))
                                AxisValueLabel {
                                    if let v = value.as(Double.self) {
                                        Text(formatCompactAxisRate(v))
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(ApexStyle.secondary)
                                    }
                                }
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartLegend(.hidden)
                        .frame(height: 62)
                        .animation(ApexStyle.springSmooth, value: latest?.timestamp)
                        .accessibilityIdentifier("metrics.network.chart")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(ApexStyle.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ApexStyle.border.opacity(0.45), lineWidth: 0.75)
                )

                // CPU, Memory & Swap History Chart
                if historyStore.snapshots.count >= 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("CPU / 内存 / 交换 历史 (%)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ApexStyle.secondary)
                            Spacer()
                            HStack(spacing: 10) {
                                HStack(spacing: 4) {
                                    Circle().fill(ApexStyle.accent).frame(width: 6, height: 6)
                                    Text("CPU").font(.system(size: 10)).foregroundColor(ApexStyle.secondary)
                                }
                                HStack(spacing: 4) {
                                    Circle().fill(ApexStyle.success).frame(width: 6, height: 6)
                                    Text("内存").font(.system(size: 10)).foregroundColor(ApexStyle.secondary)
                                }
                                if (latest?.swapTotalBytes ?? 0) > 0 {
                                    HStack(spacing: 4) {
                                        Circle().fill(ApexStyle.warning).frame(width: 6, height: 6)
                                        Text("交换").font(.system(size: 10)).foregroundColor(ApexStyle.secondary)
                                    }
                                }
                            }
                        }

                        Chart(historyStore.snapshots) { snapshot in
                            AreaMark(
                                x: .value("采样时间", snapshot.timestamp),
                                y: .value("使用率", snapshot.cpuUsagePercent)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [ApexStyle.accent.opacity(0.18), ApexStyle.accent.opacity(0.01)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            LineMark(
                                x: .value("采样时间", snapshot.timestamp),
                                y: .value("使用率", snapshot.cpuUsagePercent)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(by: .value("指标", "CPU"))
                            .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))

                            LineMark(
                                x: .value("采样时间", snapshot.timestamp),
                                y: .value("使用率", snapshot.memoryUsagePercent)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(by: .value("指标", "内存"))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                            if snapshot.swapTotalBytes > 0 {
                                LineMark(
                                    x: .value("采样时间", snapshot.timestamp),
                                    y: .value("使用率", snapshot.swapUsagePercent)
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(by: .value("指标", "交换"))
                                .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [2, 2]))
                            }
                        }
                        .chartYScale(domain: 0...100)
                        .chartForegroundStyleScale(["CPU": ApexStyle.accent, "内存": ApexStyle.success, "交换": ApexStyle.warning])
                        .chartLegend(.hidden)
                        .frame(height: 82)
                        .animation(ApexStyle.springSmooth, value: latest?.timestamp)
                        .accessibilityIdentifier("metrics.history.chart")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(ApexStyle.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ApexStyle.border.opacity(0.4), lineWidth: 0.75)
                    )
                }

                // Top 3 Processes
                if let procs = latest?.topProcesses, !procs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            HStack(spacing: 4) {
                                Text("Top 进程占用")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(ApexStyle.secondary)
                                ApexIconButton(
                                    icon: "arrow.up.right.square",
                                    label: "打开进程与服务监视中心 (⌘⌥K)",
                                    size: 20,
                                    iconSize: 10
                                ) {
                                    // Close the popover first so the inspector sheet is not stacked under it.
                                    if let onDismiss { onDismiss() } else { dismiss() }
                                    NotificationCenter.default.post(name: NSNotification.Name("TriggerProcessInspector"), object: nil)
                                }
                            }
                            Spacer()
                            HStack(spacing: 0) {
                                Text("PID")
                                    .frame(width: 58, alignment: .leading)
                                Spacer()
                                Text("CPU")
                                    .frame(width: 46, alignment: .trailing)
                                Text("内存")
                                    .frame(width: 42, alignment: .trailing)
                            }
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(ApexStyle.secondary.opacity(0.75))
                            .frame(width: 170)
                        }

                        VStack(spacing: 3) {
                            ForEach(procs.prefix(3)) { p in
                                HStack(spacing: 6) {
                                    Text(String(p.pid))
                                        .font(.system(size: 11, design: .monospaced))
                                        .monospacedDigit()
                                        .foregroundColor(ApexStyle.secondary)
                                        .lineLimit(1)
                                        .frame(width: 58, alignment: .leading)
                                    Text(p.command)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(String(format: "%.1f%%", p.cpuPercent))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                        .foregroundColor(p.cpuPercent > 50 ? ApexStyle.error : (p.cpuPercent > 20 ? ApexStyle.warning : ApexStyle.primary))
                                        .lineLimit(1)
                                        .frame(width: 46, alignment: .trailing)
                                    Text(String(format: "%.1f%%", p.memPercent))
                                        .font(.system(size: 11, design: .monospaced))
                                        .monospacedDigit()
                                        .contentTransition(.numericText())
                                        .foregroundColor(ApexStyle.secondary)
                                        .lineLimit(1)
                                        .frame(width: 42, alignment: .trailing)
                                }
                                .padding(.vertical, 1)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(ApexStyle.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(ApexStyle.border.opacity(0.4), lineWidth: 0.75)
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(ApexStyle.surface)
        .animation(ApexStyle.springSmooth, value: latest?.timestamp)
    }

    private var latest: ServerMetricsSnapshot? {
        monitoringEnabled ? historyStore.latest : nil
    }

    /// Ensures the network curve renders immediately on first open by synthesizing a 1.5s baseline point when needed.
    private var chartSnapshots: [ServerMetricsSnapshot] {
        let snaps = historyStore.snapshots
        if snaps.count == 1, let first = snaps.first {
            var baseline = first
            baseline.id = UUID()
            baseline.timestamp = first.timestamp.addingTimeInterval(-1.5)
            return [baseline, first]
        }
        return snaps
    }

    private var networkChartUpperBound: Double {
        let peak = chartSnapshots.reduce(0.0) { acc, snap in
            max(acc, snap.networkRxBytesPerSec, snap.networkTxBytesPerSec)
        }
        return max(peak * 1.25, 4096)
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

    private var swapColor: Color {
        guard let s = latest, s.swapTotalBytes > 0 else { return ApexStyle.secondary.opacity(0.5) }
        let usage = s.swapUsagePercent
        if usage > 80 { return ApexStyle.error }
        if usage > 50 { return ApexStyle.warning }
        return ApexStyle.accent.opacity(0.85)
    }

    private var diskColor: Color {
        let usage = latest?.diskUsagePercent ?? 0
        if usage > 85 { return ApexStyle.error }
        if usage > 70 { return ApexStyle.warning }
        return ApexStyle.accent
    }

    private var formattedMemoryShort: String {
        guard let m = latest, m.memoryTotalBytes > 0 else { return "--" }
        let usedGB = Double(m.memoryUsedBytes) / 1073741824.0
        let totalGB = Double(m.memoryTotalBytes) / 1073741824.0
        return String(format: "%.1f/%.0fG (%.0f%%)", usedGB, totalGB, m.memoryUsagePercent)
    }

    private var formattedSwapShort: String {
        guard let s = latest else { return "--" }
        guard s.swapTotalBytes > 0 else { return "0.0/0G (未启用)" }
        let usedGB = Double(s.swapUsedBytes) / 1073741824.0
        let totalGB = Double(s.swapTotalBytes) / 1073741824.0
        if totalGB < 1.0 {
            let usedMB = Double(s.swapUsedBytes) / 1048576.0
            let totalMB = Double(s.swapTotalBytes) / 1048576.0
            return String(format: "%.0f/%.0fM (%.0f%%)", usedMB, totalMB, s.swapUsagePercent)
        }
        return String(format: "%.1f/%.1fG (%.0f%%)", usedGB, totalGB, s.swapUsagePercent)
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

    private func formatCompactAxisRate(_ b: Double) -> String {
        if b <= 0 { return "0" }
        if b < 1024 { return String(format: "%.0fB", b) }
        if b < 1024 * 1024 {
            let kb = b / 1024
            return kb >= 10 ? String(format: "%.0fK", kb) : String(format: "%.1fK", kb)
        }
        return String(format: "%.1fM", b / 1024 / 1024)
    }

    private func formatUptime(_ s: UInt64) -> String {
        let days = s / 86400
        let hours = (s % 86400) / 3600
        let mins = (s % 3600) / 60
        if days > 0 { return "运行 \(days)天 \(hours)时" }
        return "运行 \(hours)时 \(mins)分"
    }
}
