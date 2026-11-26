import SwiftUI
import AppKit
import ApexCore
import ApexSSH

/// Real-time remote log tail viewer (`tail -n 500 -F`) sheet with ANSI stripping,
/// follow/auto-scroll toggle, pause/resume buffering, live keyword/regex filtering,
/// line wrap toggle, and one-click filtered export.
public struct RemoteLogTailSheet: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    @StateObject private var streamer: RemoteLogTailStreamer
    @Environment(\.dismiss) private var dismiss

    @State private var copyFeedback: String?
    @FocusState private var isFilterFocused: Bool

    public let item: SFTPItem

    public init(item: SFTPItem, session: SSHSessionProtocol?) {
        self.item = item
        self._streamer = StateObject(wrappedValue: RemoteLogTailStreamer(remotePath: item.path, session: session))
    }

    private var statusTitle: String {
        switch streamer.state {
        case .idle: return "准备中"
        case .connecting: return "连接中…"
        case .streaming: return "实时追踪中"
        case .paused:
            return streamer.pendingPausedCount > 0 ? "已暂停 (+\(streamer.pendingPausedCount))" : "已暂停"
        case .stopped: return "已停止"
        case .failed: return "连接异常"
        }
    }

    private var statusColor: Color {
        switch streamer.state {
        case .streaming: return ApexStyle.success
        case .connecting: return ApexStyle.accent
        case .paused: return ApexStyle.warning
        case .failed: return ApexStyle.error
        case .idle, .stopped: return ApexStyle.secondary
        }
    }

    public var body: some View {
        let visibleLines = streamer.filteredLines
        VStack(spacing: 0) {
            headerBar(visibleCount: visibleLines.count)
            Divider()
            controlsBar(visibleLines: visibleLines)
            Divider()
            logViewport(visibleLines: visibleLines)
            Divider()
            footerBar(visibleCount: visibleLines.count)
        }
        .frame(minWidth: 760, idealWidth: 920, minHeight: 520, idealHeight: 620)
        .background(ApexStyle.surface)
        .onAppear {
            streamer.start()
        }
        .onDisappear {
            streamer.stop()
        }
    }

    private func headerBar(visibleCount: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ApexStyle.accent)
                .frame(width: 34, height: 34)
                .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ApexStyle.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(statusColor)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.12), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                }

                Text("tail -n \(streamer.initialLines) -F · \(item.path)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ApexStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text("\(visibleCount) / \(streamer.lines.count) 行")
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(ApexStyle.secondary)
                .fixedSize(horizontal: true, vertical: false)

            ApexIconButton(icon: "xmark", label: "关闭日志追踪", size: 24, iconSize: 11) {
                streamer.stop()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 10)
        .background(ApexStyle.surface)
    }

    private func controlsBar(visibleLines: [RemoteLogLine]) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(ApexStyle.secondary)
                    TextField(
                        streamer.isRegexFilter ? "正则过滤 (如 ERROR|50[0-9])..." : "实时关键词过滤...",
                        text: $streamer.filterQuery
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isFilterFocused)
                    .autocorrectionDisabled()

                    if !streamer.filterQuery.isEmpty {
                        ApexIconButton(icon: "xmark.circle.fill", label: "清除过滤", size: 18, iconSize: 10) {
                            streamer.filterQuery = ""
                        }
                    }

                    Button {
                        streamer.isRegexFilter.toggle()
                    } label: {
                        Text(".*")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(streamer.isRegexFilter ? ApexStyle.accent : ApexStyle.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                (streamer.isRegexFilter ? ApexStyle.accent.opacity(0.16) : Color.clear),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("切换正则表达式匹配")
                    .accessibilityLabel("正则表达式过滤")
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 160, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                .background(ApexStyle.subtleSurface, in: RoundedRectangle(cornerRadius: ApexStyle.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: ApexStyle.controlRadius)
                        .stroke(
                            streamer.regexError != nil
                                ? ApexStyle.error.opacity(0.8)
                                : (isFilterFocused ? ApexStyle.accent.opacity(0.85) : ApexStyle.border.opacity(0.65)),
                            lineWidth: 0.85
                        )
                )

                ApexActionButton(
                    streamer.isAutoScrollEnabled ? "跟随滚动" : "滚动已锁",
                    icon: streamer.isAutoScrollEnabled ? "arrow.down.to.line" : "lock",
                    tint: streamer.isAutoScrollEnabled ? ApexStyle.accent : ApexStyle.secondary,
                    size: .small
                ) {
                    streamer.isAutoScrollEnabled.toggle()
                }
                .help("开启或暂停自动滚动到底部")

                ApexActionButton(
                    streamer.isPaused ? "继续" : "暂停",
                    icon: streamer.isPaused ? "play.fill" : "pause.fill",
                    tint: streamer.isPaused ? ApexStyle.warning : ApexStyle.secondary,
                    size: .small
                ) {
                    streamer.togglePause()
                }
                .disabled(!streamer.state.isActive)

                ApexActionButton(
                    streamer.wrapLines ? "换行" : "单行",
                    icon: "text.word.spacing",
                    tint: streamer.wrapLines ? ApexStyle.accent : ApexStyle.secondary,
                    size: .small
                ) {
                    streamer.wrapLines.toggle()
                }
                .help("切换长行自动换行")

                ApexActionButton("清空", icon: "trash", tint: ApexStyle.secondary, size: .small) {
                    streamer.clear()
                }

                ApexActionButton(
                    streamer.state.isActive ? "停止" : "重连",
                    icon: streamer.state.isActive ? "stop.fill" : "arrow.clockwise",
                    tint: streamer.state.isActive ? ApexStyle.error : ApexStyle.accent,
                    size: .small
                ) {
                    if streamer.state.isActive {
                        streamer.stop()
                    } else {
                        streamer.start()
                    }
                }
            }

            if let regexErr = streamer.regexError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ApexStyle.error)
                    Text("正则表达式无效：\(regexErr)")
                        .font(.caption)
                        .foregroundStyle(ApexStyle.error)
                        .lineLimit(1)
                    Spacer()
                }
            } else if case .failed(let errorMessage) = streamer.state {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ApexStyle.error)
                    Text("追踪失败：\(errorMessage)")
                        .font(.caption)
                        .foregroundStyle(ApexStyle.error)
                        .lineLimit(2)
                    Spacer()
                    ApexActionButton("重试", icon: "arrow.clockwise", tint: ApexStyle.accent, size: .small) {
                        streamer.start()
                    }
                }
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 8)
        .background(ApexStyle.subtleSurface.opacity(0.65))
    }

    private func logViewport(visibleLines: [RemoteLogLine]) -> some View {
        ScrollViewReader { proxy in
            Group {
                if visibleLines.isEmpty {
                    ContentUnavailableView {
                        Label(
                            streamer.lines.isEmpty ? "等待日志输出…" : "没有匹配的日志行",
                            systemImage: streamer.lines.isEmpty ? "doc.text" : "magnifyingglass"
                        )
                    } description: {
                        Text(streamer.lines.isEmpty
                             ? "正在通过 SSH 实时读取 \(item.name) 的最新日志流"
                             : "尝试修改过滤关键词或关闭正则模式")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(streamer.wrapLines ? [.vertical] : [.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(visibleLines) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(lineColor(for: line.text))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: streamer.wrapLines ? .infinity : nil, alignment: .leading)
                                    .fixedSize(horizontal: !streamer.wrapLines, vertical: true)
                                    .id(line.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("remoteLogTailBottomAnchor")
                        }
                        .padding(.horizontal, ApexStyle.s4)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: visibleLines.last?.id) { _, _ in
                        guard streamer.isAutoScrollEnabled && !streamer.isPaused else { return }
                        proxy.scrollTo("remoteLogTailBottomAnchor", anchor: .bottom)
                    }
                    .onChange(of: streamer.isAutoScrollEnabled) { _, enabled in
                        if enabled && !streamer.isPaused {
                            proxy.scrollTo("remoteLogTailBottomAnchor", anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ApexStyle.surface)
        }
    }

    private func footerBar(visibleCount: Int) -> some View {
        HStack(spacing: 12) {
            Text("缓冲区上限 \(streamer.maxLines) 行 · 已自动剥离 ANSI 控制序列")
                .font(.caption)
                .foregroundStyle(ApexStyle.secondary)
                .lineLimit(1)

            if streamer.droppedLineCount > 0 {
                Text("已滚动淘汰 \(streamer.droppedLineCount) 行")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ApexStyle.secondary)
            }

            if let feedback = copyFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(ApexStyle.success)
                    .transition(.opacity)
            }

            Spacer()

            ApexActionButton(
                "复制筛选输出 (\(visibleCount))",
                icon: "doc.on.doc",
                tint: ApexStyle.accent,
                size: .small
            ) {
                let text = streamer.filteredOutputText
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copyFeedback = "已复制 \(visibleCount) 行日志"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    copyFeedback = nil
                }
            }
            .disabled(visibleCount == 0)

            ApexActionButton("关闭", tint: ApexStyle.secondary, size: .small) {
                streamer.stop()
                dismiss()
            }
        }
        .padding(.horizontal, ApexStyle.s4)
        .padding(.vertical, 8)
        .background(ApexStyle.surface)
    }

    private func lineColor(for text: String) -> Color {
        if text.localizedCaseInsensitiveContains("error")
            || text.localizedCaseInsensitiveContains("fatal")
            || text.localizedCaseInsensitiveContains("exception")
            || text.localizedCaseInsensitiveContains("panic") {
            return ApexStyle.error
        }
        if text.localizedCaseInsensitiveContains("warn") {
            return ApexStyle.warning
        }
        return ApexStyle.primary
    }
}
