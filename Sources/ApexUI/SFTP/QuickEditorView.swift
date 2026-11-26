import SwiftUI
import CoreFoundation
import ApexCore
import ApexSSH

public enum QuickEditorEncoding: String, Sendable, Equatable, CaseIterable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    case gb18030
    case latin1

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .gb18030: return "GB18030"
        case .latin1: return "Latin1"
        }
    }
}

public enum QuickEditorLineEnding: String, Sendable, Equatable, CaseIterable {
    case lf = "LF"
    case crlf = "CRLF"
}

public struct QuickEditorDocumentMeta: Sendable, Equatable {
    public var encoding: QuickEditorEncoding
    public var lineEnding: QuickEditorLineEnding
    public var hasBOM: Bool

    public init(
        encoding: QuickEditorEncoding = .utf8,
        lineEnding: QuickEditorLineEnding = .lf,
        hasBOM: Bool = false
    ) {
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
    }
}

public enum QuickEditorCodecError: LocalizedError, Equatable, Sendable {
    case binaryFileDetected
    case unencodableCharacters(String)

    public var errorDescription: String? {
        switch self {
        case .binaryFileDetected:
            return "检测到二进制内容（包含 NUL 字节或高比例控制字符），不支持在线文本编辑"
        case .unencodableCharacters(let encodingName):
            return "内容包含无法以 \(encodingName) 编码保存的字符"
        }
    }
}

public enum QuickEditorTextCodec: Sendable {
    private static var gb18030Encoding: String.Encoding {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    public struct DecodedDocument: Sendable, Equatable {
        public let text: String
        public let meta: QuickEditorDocumentMeta

        public init(text: String, meta: QuickEditorDocumentMeta) {
            self.text = text
            self.meta = meta
        }
    }

    public static func decode(_ data: Data) throws -> DecodedDocument {
        if data.isEmpty {
            return DecodedDocument(text: "", meta: QuickEditorDocumentMeta(encoding: .utf8, lineEnding: .lf, hasBOM: false))
        }

        // 1. UTF-16 BOM check (must precede raw 0x00 NUL scan because UTF-16 naturally contains zero bytes)
        if data.count >= 2 {
            let b0 = data[data.startIndex]
            let b1 = data[data.index(after: data.startIndex)]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                let isLE = (b0 == 0xFF && b1 == 0xFE)
                let encoding: QuickEditorEncoding = isLE ? .utf16LittleEndian : .utf16BigEndian
                let cocoaEncoding: String.Encoding = isLE ? .utf16LittleEndian : .utf16BigEndian
                let payload = data.dropFirst(2)
                if payload.count % 2 == 0,
                   let decoded = String(data: Data(payload), encoding: cocoaEncoding),
                   !containsBinaryScalars(decoded) {
                    let lineEnding = detectLineEnding(in: decoded)
                    let normalized = normalizeToLF(decoded)
                    return DecodedDocument(
                        text: normalized,
                        meta: QuickEditorDocumentMeta(encoding: encoding, lineEnding: lineEnding, hasBOM: true)
                    )
                }
                throw QuickEditorCodecError.binaryFileDetected
            }
        }

        // 2. Binary byte guard (NUL byte or >5% non-text control bytes)
        if isBinaryRawBytes(data) {
            throw QuickEditorCodecError.binaryFileDetected
        }

        // 3. UTF-8 (with optional BOM)
        var utf8Slice = data
        var hasUTF8BOM = false
        if data.count >= 3,
           data[data.startIndex] == 0xEF,
           data[data.index(data.startIndex, offsetBy: 1)] == 0xBB,
           data[data.index(data.startIndex, offsetBy: 2)] == 0xBF {
            utf8Slice = data.dropFirst(3)
            hasUTF8BOM = true
        }
        if let utf8Text = String(data: Data(utf8Slice), encoding: .utf8) {
            let lineEnding = detectLineEnding(in: utf8Text)
            return DecodedDocument(
                text: normalizeToLF(utf8Text),
                meta: QuickEditorDocumentMeta(encoding: .utf8, lineEnding: lineEnding, hasBOM: hasUTF8BOM)
            )
        }

        // 4. GB18030
        if let gbText = String(data: data, encoding: gb18030Encoding) {
            let lineEnding = detectLineEnding(in: gbText)
            return DecodedDocument(
                text: normalizeToLF(gbText),
                meta: QuickEditorDocumentMeta(encoding: .gb18030, lineEnding: lineEnding, hasBOM: false)
            )
        }

        // 5. ISO Latin-1 fallback
        if let latinText = String(data: data, encoding: .isoLatin1) {
            let lineEnding = detectLineEnding(in: latinText)
            return DecodedDocument(
                text: normalizeToLF(latinText),
                meta: QuickEditorDocumentMeta(encoding: .latin1, lineEnding: lineEnding, hasBOM: false)
            )
        }

        throw QuickEditorCodecError.binaryFileDetected
    }

    public static func encode(_ text: String, meta: QuickEditorDocumentMeta) throws -> Data {
        let lfText = normalizeToLF(text)
        let targetText = meta.lineEnding == .crlf
            ? lfText.replacingOccurrences(of: "\n", with: "\r\n")
            : lfText

        switch meta.encoding {
        case .utf8:
            var out = Data()
            if meta.hasBOM {
                out.append(contentsOf: [0xEF, 0xBB, 0xBF])
            }
            out.append(Data(targetText.utf8))
            return out
        case .utf16LittleEndian:
            guard let body = targetText.data(using: .utf16LittleEndian) else {
                throw QuickEditorCodecError.unencodableCharacters(meta.encoding.displayName)
            }
            var out = Data()
            if meta.hasBOM {
                out.append(contentsOf: [0xFF, 0xFE])
            }
            out.append(body)
            return out
        case .utf16BigEndian:
            guard let body = targetText.data(using: .utf16BigEndian) else {
                throw QuickEditorCodecError.unencodableCharacters(meta.encoding.displayName)
            }
            var out = Data()
            if meta.hasBOM {
                out.append(contentsOf: [0xFE, 0xFF])
            }
            out.append(body)
            return out
        case .gb18030:
            guard let body = targetText.data(using: gb18030Encoding) else {
                throw QuickEditorCodecError.unencodableCharacters(meta.encoding.displayName)
            }
            return body
        case .latin1:
            guard let body = targetText.data(using: .isoLatin1) else {
                throw QuickEditorCodecError.unencodableCharacters(meta.encoding.displayName)
            }
            return body
        }
    }

    public static func detectLineEnding(in text: String) -> QuickEditorLineEnding {
        var crlfCount = 0
        var lfOnlyCount = 0
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                previousWasCR = true
            } else if scalar == "\n" {
                if previousWasCR {
                    crlfCount += 1
                } else {
                    lfOnlyCount += 1
                }
                previousWasCR = false
            } else {
                previousWasCR = false
            }
        }
        return (crlfCount > 0 && crlfCount >= lfOnlyCount) ? .crlf : .lf
    }

    public static func normalizeToLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    public static func isBinaryRawBytes(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sampleCount = min(data.count, 64 * 1024)
        var controlBytes = 0
        for byte in data.prefix(sampleCount) {
            if byte == 0x00 {
                return true
            }
            // Count suspicious non-whitespace/non-ANSI-ESC control bytes.
            if (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x0C && byte != 0x1B) || byte == 0x7F {
                controlBytes += 1
            }
        }
        return Double(controlBytes) / Double(sampleCount) > 0.05
    }

    private static func containsBinaryScalars(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var total = 0
        var control = 0
        for scalar in text.unicodeScalars.prefix(32 * 1024) {
            total += 1
            let v = scalar.value
            if v == 0 {
                return true
            }
            if (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D && v != 0x0C && v != 0x1B) || v == 0x7F {
                control += 1
            }
        }
        return total > 0 && (Double(control) / Double(total) > 0.05)
    }
}

/// Native remote-file editor with undo, search, synchronized line numbers and safe asynchronous save.
public struct QuickEditorView: View {
    @ObservedObject private var themeSettings = AppSettings.shared
    public let item: SFTPItem
    @Binding public var content: String
    @Binding public var documentMeta: QuickEditorDocumentMeta
    public let initialLine: Int?
    public let onSave: (String) async throws -> Void
    public let onReload: () async throws -> String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var isSaving = false
    @State private var isReloading = false
    @State private var isComparingRemote = false
    @State private var saveNotice: String?
    @State private var saveNoticeIsError = false
    @State private var isSearchVisible = false
    @State private var hasUnsavedChanges = false
    @State private var initialContent = ""
    @State private var initialLineEnding: QuickEditorLineEnding = .lf
    @State private var pendingDiscard: DiscardAction?
    @State private var remoteDiffComparison: QuickEditorDiffSnapshot?
    @State private var metricsTask: Task<Void, Never>?

    private enum DiscardAction: String, Identifiable {
        case close, reload
        var id: String { rawValue }
    }
    
    public init(
        item: SFTPItem,
        content: Binding<String>,
        documentMeta: Binding<QuickEditorDocumentMeta> = .constant(QuickEditorDocumentMeta()),
        initialLine: Int? = nil,
        onSave: @escaping (String) async throws -> Void,
        onReload: @escaping () async throws -> String
    ) {
        self.item = item
        self._content = content
        self._documentMeta = documentMeta
        self.initialLine = initialLine
        self.onSave = onSave
        self.onReload = onReload
    }
    
    @State private var lineCount = 1
    @State private var contentByteCount = 0

    /// The editing area follows the active theme like the header and footer around it.
    private var editorPalette: NativeCodeEditor.EditorPalette? {
        guard !themeSettings.followsSystemAppearance else { return nil }
        let selectionColor: NSColor
        if themeSettings.themePreset == .solarized || ApexStyle.selection == ApexStyle.surface {
            selectionColor = NSColor(ApexStyle.accent.opacity(0.24))
        } else {
            selectionColor = NSColor(ApexStyle.selection)
        }
        return NativeCodeEditor.EditorPalette(
            background: NSColor(ApexStyle.surface),
            text: NSColor(ApexStyle.primary),
            gutter: NSColor(ApexStyle.subtleSurface),
            gutterText: NSColor(ApexStyle.secondary),
            selection: selectionColor,
            gutterBorder: NSColor(ApexStyle.border.opacity(0.75))
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                Image(systemName: fileIcon(for: item.name))
                    .font(.system(size: 16))
                    .foregroundColor(ApexStyle.accent)
                    .frame(width: 34, height: 34)
                    .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ApexStyle.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        if hasUnsavedChanges {
                            Circle()
                                .fill(ApexStyle.warning)
                                .frame(width: 7, height: 7)
                                .shadow(color: ApexStyle.warning.opacity(0.6), radius: 2)
                                .help("包含未保存更改 (按 ⌘S 保存)")
                                .accessibilityLabel("有未保存的更改")
                        }
                    }
                    
                    Text(item.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                // File specs pill
                HStack(spacing: 6) {
                    Text(fileTypeTag(for: item.name))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ApexStyle.accent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ApexStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    
                    Text("\(lineCount) 行 · \(ByteCountFormatter.string(fromByteCount: Int64(contentByteCount), countStyle: .file))")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                
                Divider().frame(height: 18)
                
                // Search toggle
                ApexIconButton(
                    icon: "magnifyingglass",
                    label: "查找 (⌘F)",
                    size: 24,
                    iconSize: 11,
                    isSelected: isSearchVisible
                ) {
                    withAnimation { isSearchVisible.toggle() }
                }
                .keyboardShortcut("f", modifiers: .command)
                
                // Reload button
                if isReloading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 24, height: 24)
                } else {
                    ApexIconButton(
                        icon: "arrow.clockwise",
                        label: "从服务器重新加载",
                        size: 24,
                        iconSize: 11
                    ) {
                        requestReload()
                    }
                    .disabled(isReloading || isSaving)
                }
                
                ApexIconButton(
                    icon: "xmark",
                    label: "关闭编辑器 (Esc)",
                    size: 24,
                    iconSize: 11
                ) {
                    requestClose()
                }
                .keyboardShortcut(isSearchVisible ? nil : .cancelAction)
                .disabled(isSaving || isReloading)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 10)
            .background(ApexStyle.surface)
            
            Divider()
            
            let detectedLanguage = SyntaxLanguage.detect(filename: item.name)
            let effectiveDark = themeSettings.followsSystemAppearance ? (colorScheme == .dark) : themeSettings.themePreset.isDark
            let effectiveHighlightPalette = themeSettings.followsSystemAppearance ? nil : themeSettings.themePreset.palette

            NativeCodeEditor(
                text: $content,
                showsFindBar: $isSearchVisible,
                isReloading: isReloading,
                palette: editorPalette,
                language: detectedLanguage,
                highlightPalette: effectiveHighlightPalette,
                isDarkTheme: effectiveDark,
                jumpToLine: initialLine
            )
                .onChange(of: content) { _, newValue in
                    scheduleMetricsUpdate(for: newValue)
                }

            Divider()

            // Bottom Status & Action Bar
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(ApexStyle.success).frame(width: 6, height: 6)
                    Text("\(documentMeta.encoding.displayName) ·")
                        .font(.caption.monospaced())
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Menu {
                        Section("转换为 LF / CRLF") {
                            Button {
                                setLineEnding(.lf)
                            } label: {
                                Label(
                                    "转换为 LF (\\n · Unix/macOS)",
                                    systemImage: documentMeta.lineEnding == .lf ? "checkmark" : "arrow.turn.down.left"
                                )
                            }
                            Button {
                                setLineEnding(.crlf)
                            } label: {
                                Label(
                                    "转换为 CRLF (\\r\\n · Windows)",
                                    systemImage: documentMeta.lineEnding == .crlf ? "checkmark" : "return"
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(documentMeta.lineEnding.rawValue)
                                .font(.caption.monospaced())
                                .fontWeight(.semibold)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .foregroundColor(ApexStyle.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ApexStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("转换为 LF / CRLF 换行符格式")
                    .accessibilityLabel("转换为 LF / CRLF")

                    Text("· 远程文件")
                        .font(.caption.monospaced())
                        .foregroundColor(ApexStyle.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    if contentByteCount > SyntaxHighlighter.defaultMaxBytes {
                        Text("大文件高亮已禁用")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ApexStyle.warning)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ApexStyle.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                
                if let notice = saveNotice {
                    HStack(spacing: 4) {
                        Image(systemName: saveNoticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 11))
                        Text(notice)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        ApexIconButton(
                            icon: "xmark",
                            label: "关闭提示",
                            size: 18,
                            iconSize: 8.5,
                            tint: saveNoticeIsError ? ApexStyle.error : ApexStyle.success
                        ) {
                            withAnimation(ApexStyle.hoverTransition) {
                                saveNotice = nil
                            }
                        }
                    }
                    .foregroundColor(saveNoticeIsError ? ApexStyle.error : ApexStyle.success)
                    .help(notice)
                    .transition(.opacity)
                }
                
                Spacer(minLength: 8)

                ApexActionButton(
                    "重新拉取对比",
                    icon: "arrow.left.arrow.right",
                    tint: ApexStyle.secondary,
                    size: .small,
                    isLoading: isComparingRemote,
                    action: compareWithRemoteLatest
                )
                .fixedSize(horizontal: true, vertical: false)
                .help("从服务器拉取最新内容并与当前编辑文本逐行对比")
                .disabled(isSaving || isReloading || isComparingRemote)
                
                ApexActionButton(
                    "关闭",
                    tint: ApexStyle.secondary,
                    size: .small,
                    action: requestClose
                )
                .fixedSize(horizontal: true, vertical: false)
                .keyboardShortcut("w", modifiers: .command)
                .disabled(isSaving || isReloading)
                
                ApexActionButton(
                    "保存 (⌘S)",
                    icon: "square.and.arrow.down",
                    tint: ApexStyle.accent,
                    size: .small,
                    isProminent: true,
                    isLoading: isSaving,
                    action: saveChanges
                )
                .fixedSize(horizontal: true, vertical: false)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(isSaving || isReloading)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 8)
            .background(ApexStyle.surface)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onExitCommand {
            if isSearchVisible {
                isSearchVisible = false
            } else {
                requestClose()
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges || isSaving || isReloading)
        .alert(item: $pendingDiscard) { action in
            Alert(title: Text("放弃未保存的更改？"),
                  message: Text(action == .close ? "关闭后，尚未上传的更改将丢失。" : "重新加载会用服务器上的内容替换当前更改。"),
                  primaryButton: .destructive(Text("放弃更改")) {
                      if action == .close { dismiss() } else { reloadContent() }
                  }, secondaryButton: .cancel(Text("继续编辑")))
        }
        .sheet(item: $remoteDiffComparison) { snapshot in
            QuickEditorDiffSheet(
                fileName: item.name,
                snapshot: snapshot,
                onUseRemote: {
                    content = snapshot.remoteText
                    initialContent = snapshot.remoteText
                    initialLineEnding = documentMeta.lineEnding
                    hasUnsavedChanges = false
                    saveNoticeIsError = false
                    saveNotice = "已应用远端最新内容"
                }
            )
            .apexTheme()
        }
        .onAppear {
            initialContent = content
            initialLineEnding = documentMeta.lineEnding
            updateMetricsImmediately(for: content)
        }
        .onDisappear {
            metricsTask?.cancel()
            metricsTask = nil
        }
    }

    private func scheduleMetricsUpdate(for newValue: String) {
        metricsTask?.cancel()
        let baseline = initialContent
        let lineEndingChanged = documentMeta.lineEnding != initialLineEnding
        metricsTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let computed = await Task.detached(priority: .utility) {
                let lines = 1 + newValue.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                let bytes = newValue.utf8.count
                let dirty = (newValue != baseline) || lineEndingChanged
                return (lines, bytes, dirty)
            }.value
            guard !Task.isCancelled else { return }
            self.lineCount = computed.0
            self.contentByteCount = computed.1
            self.hasUnsavedChanges = computed.2
        }
    }

    private func updateMetricsImmediately(for text: String) {
        lineCount = 1 + text.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        contentByteCount = text.utf8.count
        hasUnsavedChanges = (text != initialContent) || (documentMeta.lineEnding != initialLineEnding)
    }

    private func setLineEnding(_ target: QuickEditorLineEnding) {
        guard documentMeta.lineEnding != target else { return }
        documentMeta.lineEnding = target
        updateMetricsImmediately(for: content)
        saveNoticeIsError = false
        saveNotice = "已将换行符切换为 \(target.rawValue)（保存后生效）"
    }

    private func compareWithRemoteLatest() {
        guard !isComparingRemote && !isReloading && !isSaving else { return }
        isComparingRemote = true
        let localSnapshot = content
        Task {
            do {
                let remoteLatest = try await onReload()
                await MainActor.run {
                    self.isComparingRemote = false
                    self.remoteDiffComparison = QuickEditorDiffSnapshot.build(
                        localText: localSnapshot,
                        remoteText: remoteLatest
                    )
                }
            } catch {
                await MainActor.run {
                    self.isComparingRemote = false
                    self.saveNoticeIsError = true
                    self.saveNotice = "拉取远端对比失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func requestClose() {
        guard !isSaving && !isReloading else { return }
        metricsTask?.cancel()
        updateMetricsImmediately(for: content)
        if hasUnsavedChanges { pendingDiscard = .close } else { dismiss() }
    }

    private func requestReload() {
        guard !isSaving && !isReloading else { return }
        metricsTask?.cancel()
        updateMetricsImmediately(for: content)
        if hasUnsavedChanges { pendingDiscard = .reload } else { reloadContent() }
    }

    private func saveChanges() {
        guard !isSaving else { return }
        isSaving = true
        let savedContent = content
        saveNotice = nil
        Task {
            do {
                try await onSave(savedContent)
                await MainActor.run {
                    self.isSaving = false
                    self.initialContent = savedContent
                    self.initialLineEnding = self.documentMeta.lineEnding
                    self.hasUnsavedChanges = self.content != savedContent
                    self.saveNoticeIsError = false
                    let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                    self.saveNotice = self.hasUnsavedChanges
                        ? "已上传保存时的内容；仍有新更改待保存 (\(time))"
                        : "已保存并上传至服务器 (\(time))"
                }
            } catch {
                await MainActor.run {
                    self.isSaving = false
                    self.saveNoticeIsError = true
                    self.saveNotice = "保存失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func reloadContent() {
        guard !isReloading else { return }
        isReloading = true
        Task {
            do {
                let reloaded = try await onReload()
                await MainActor.run {
                    self.content = reloaded
                    self.initialContent = reloaded
                    self.initialLineEnding = self.documentMeta.lineEnding
                    self.hasUnsavedChanges = false
                    self.isReloading = false
                    self.saveNotice = "已重新拉取远端最新内容"
                    self.saveNoticeIsError = false
                }
            } catch {
                await MainActor.run {
                    self.isReloading = false
                    self.saveNoticeIsError = true
                    self.saveNotice = "拉取失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func fileTypeTag(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh": return "SHELL"
        case "yaml", "yml": return "YAML"
        case "json": return "JSON"
        case "conf", "ini", "toml": return "CONFIG"
        case "py": return "PYTHON"
        case "swift": return "SWIFT"
        case "go": return "GO"
        case "js", "ts": return "JAVASCRIPT"
        case "log": return "LOG"
        case "md": return "MARKDOWN"
        default: return "TEXT"
        }
    }
    
    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "sh", "bash", "zsh": return "terminal.fill"
        case "yaml", "yml", "json", "toml", "conf", "ini": return "slider.horizontal.3"
        case "log": return "doc.text.fill"
        default: return "doc.text"
        }
    }
}

private struct QuickEditorDiffLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case context
        case removed
        case added
    }
    let id: Int
    let kind: Kind
    let text: String
}

private struct QuickEditorDiffSnapshot: Identifiable {
    let id = UUID()
    let remoteText: String
    let lines: [QuickEditorDiffLine]
    let addedCount: Int
    let removedCount: Int

    var hasChanges: Bool {
        addedCount > 0 || removedCount > 0
    }

    static func build(localText: String, remoteText: String) -> QuickEditorDiffSnapshot {
        let localLines = localText.components(separatedBy: "\n")
        let remoteLines = remoteText.components(separatedBy: "\n")
        let diff = remoteLines.difference(from: localLines)

        var removedIndices = Set<Int>()
        var insertionsByOffset: [Int: [String]] = [:]
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedIndices.insert(offset)
            case .insert(let offset, let element, _):
                insertionsByOffset[offset, default: []].append(element)
            }
        }

        // Rebuild unified line stream in display order
        var result: [QuickEditorDiffLine] = []
        var nextID = 0
        var localIdx = 0
        var remoteIdx = 0
        let totalLocal = localLines.count

        while localIdx < totalLocal || insertionsByOffset[remoteIdx] != nil {
            if let inserted = insertionsByOffset[remoteIdx], !inserted.isEmpty {
                for line in inserted {
                    result.append(QuickEditorDiffLine(id: nextID, kind: .added, text: line))
                    nextID += 1
                    remoteIdx += 1
                }
                continue
            }
            if localIdx < totalLocal {
                if removedIndices.contains(localIdx) {
                    result.append(QuickEditorDiffLine(id: nextID, kind: .removed, text: localLines[localIdx]))
                    nextID += 1
                } else {
                    result.append(QuickEditorDiffLine(id: nextID, kind: .context, text: localLines[localIdx]))
                    nextID += 1
                    remoteIdx += 1
                }
                localIdx += 1
            } else {
                break
            }
        }

        return QuickEditorDiffSnapshot(
            remoteText: remoteText,
            lines: result,
            addedCount: diff.insertions.count,
            removedCount: diff.removals.count
        )
    }
}

private struct QuickEditorDiffSheet: View {
    let fileName: String
    let snapshot: QuickEditorDiffSnapshot
    let onUseRemote: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ApexStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("与服务器最新内容对比 · \(fileName)")
                        .font(.system(size: 14, weight: .semibold))
                    Text(snapshot.hasChanges
                         ? "远端相对当前编辑：+\(snapshot.addedCount) 行 / -\(snapshot.removedCount) 行"
                         : "当前编辑内容与服务器完全一致")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(snapshot.hasChanges ? ApexStyle.warning : ApexStyle.success)
                }
                Spacer()
                ApexIconButton(icon: "xmark", label: "关闭对比", size: 24, iconSize: 11) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 10)
            .background(ApexStyle.surface)

            Divider()

            if !snapshot.hasChanges {
                ContentUnavailableView(
                    "无差异",
                    systemImage: "checkmark.circle",
                    description: Text("当前编辑器中的文本与远端服务器上的最新版本一致。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(snapshot.lines) { line in
                            HStack(spacing: 8) {
                                Text(prefix(for: line.kind))
                                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(color(for: line.kind))
                                    .frame(width: 12, alignment: .center)
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(line.kind == .context ? ApexStyle.secondary : ApexStyle.primary)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .background(background(for: line.kind))
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(ApexStyle.surface)
            }

            Divider()

            HStack(spacing: 8) {
                Spacer()
                ApexActionButton("保留本地继续编辑", tint: ApexStyle.secondary, size: .small) {
                    dismiss()
                }
                if snapshot.hasChanges {
                    ApexActionButton("采用远端最新内容", icon: "arrow.down.doc", tint: ApexStyle.accent, size: .small, isProminent: true) {
                        onUseRemote()
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, ApexStyle.s4)
            .padding(.vertical, 8)
            .background(ApexStyle.surface)
        }
        .frame(minWidth: 680, idealWidth: 780, minHeight: 440, idealHeight: 520)
        .background(ApexStyle.surface)
    }

    private func prefix(for kind: QuickEditorDiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func color(for kind: QuickEditorDiffLine.Kind) -> Color {
        switch kind {
        case .added: return ApexStyle.success
        case .removed: return ApexStyle.error
        case .context: return ApexStyle.secondary
        }
    }

    private func background(for kind: QuickEditorDiffLine.Kind) -> Color {
        switch kind {
        case .added: return ApexStyle.success.opacity(0.10)
        case .removed: return ApexStyle.error.opacity(0.10)
        case .context: return Color.clear
        }
    }
}
