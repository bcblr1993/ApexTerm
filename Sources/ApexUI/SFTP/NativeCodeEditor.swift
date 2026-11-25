import AppKit
import SwiftUI
import ApexCore

/// AppKit owns editing, undo, IME, selection and the standard find bar.
struct NativeCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var showsFindBar: Bool
    var isReloading: Bool
    /// Theme colors; nil keeps the system text colors (used when following the system appearance).
    var palette: EditorPalette? = nil
    var language: SyntaxLanguage = .plain
    var highlightPalette: ThemePalette? = nil
    var isDarkTheme: Bool = false
    var jumpToLine: Int? = nil

    struct EditorPalette: Equatable {
        let background: NSColor
        let text: NSColor
        let gutter: NSColor
        let gutterText: NSColor
        let selection: NSColor
        let gutterBorder: NSColor?

        init(
            background: NSColor,
            text: NSColor,
            gutter: NSColor,
            gutterText: NSColor,
            selection: NSColor,
            gutterBorder: NSColor? = nil
        ) {
            self.background = background
            self.text = text
            self.gutter = gutter
            self.gutterText = gutterText
            self.selection = selection
            self.gutterBorder = gutterBorder
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 10, height: 10)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = true
        editor.textContainer?.containerSize = editor.maxSize
        editor.textContainer?.widthTracksTextView = false
        editor.autoresizingMask = [.width]
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("文件内容")
        scroll.documentView = editor
        let ruler = CodeLineRuler(editor: editor)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        if !showsFindBar {
            DispatchQueue.main.async { [weak editor] in
                guard let editor else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
        context.coordinator.ruler = ruler
        context.coordinator.findObservation = scroll.observe(\.isFindBarVisible, options: [.new]) { [weak coordinator = context.coordinator] _, change in
            guard let visible = change.newValue else { return }
            Task { @MainActor [weak coordinator] in
                guard let coordinator else { return }
                coordinator.lastFindVisibility = visible
                if coordinator.parent.showsFindBar != visible {
                    coordinator.parent.showsFindBar = visible
                }
            }
        }
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.highlightTask?.cancel()
        coordinator.highlightTask = nil
        coordinator.findObservation?.invalidate()
        coordinator.findObservation = nil
        (scroll.documentView as? NSTextView)?.delegate = nil
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        var textReplaced = false
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            context.coordinator.ruler?.reindex()
            textReplaced = true
        }
        editor.isEditable = !isReloading
        let background = palette?.background ?? .textBackgroundColor
        editor.backgroundColor = background
        editor.textColor = palette?.text ?? .textColor
        editor.insertionPointColor = palette?.text ?? .textColor
        let selectionColor: NSColor
        if let palette {
            selectionColor = Self.colorsVisuallyMatch(palette.selection, background)
                ? NSColor.controlAccentColor.withAlphaComponent(0.28)
                : palette.selection
        } else {
            selectionColor = .selectedTextBackgroundColor
        }
        editor.selectedTextAttributes = [.backgroundColor: selectionColor]
        scroll.backgroundColor = editor.backgroundColor
        let gutterFill = palette?.gutter ?? .controlBackgroundColor
        let gutterLabel = palette?.gutterText ?? .secondaryLabelColor
        let gutterSeparator = palette?.gutterBorder ?? (palette?.gutterText.withAlphaComponent(0.22) ?? .separatorColor)
        if let ruler = context.coordinator.ruler,
           ruler.fillColor != gutterFill || ruler.labelColor != gutterLabel || ruler.separatorColor != gutterSeparator {
            ruler.fillColor = gutterFill
            ruler.labelColor = gutterLabel
            ruler.separatorColor = gutterSeparator
            ruler.needsDisplay = true
        }
        let paletteKey = "\(highlightPalette?.surface ?? "sys")_\(highlightPalette?.accent ?? "sys")_\(highlightPalette?.ansi.first ?? "sys")_\(isDarkTheme)"
        if textReplaced || context.coordinator.lastLanguage != language || context.coordinator.lastPaletteKey != paletteKey {
            context.coordinator.applyHighlighting(to: editor)
        }
        if let line = jumpToLine, line > 0, !context.coordinator.didJumpToInitialLine, !editor.string.isEmpty {
            context.coordinator.didJumpToInitialLine = true
            DispatchQueue.main.async { [weak editor] in
                guard let editor else { return }
                Self.scrollEditor(editor, toLine: line)
            }
        }
        if context.coordinator.lastFindVisibility != showsFindBar {
            context.coordinator.lastFindVisibility = showsFindBar
            let action = NSMenuItem()
            action.tag = (showsFindBar ? NSTextFinder.Action.showFindInterface : .hideFindInterface).rawValue
            editor.performTextFinderAction(action)
        }
    }

    private static func colorsVisuallyMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.sRGB),
              let b = rhs.usingColorSpace(.sRGB) else {
            return lhs == rhs
        }
        return abs(a.redComponent - b.redComponent) < 0.01 &&
               abs(a.greenComponent - b.greenComponent) < 0.01 &&
               abs(a.blueComponent - b.blueComponent) < 0.01 &&
               abs(a.alphaComponent - b.alphaComponent) < 0.01
    }

    private static func scrollEditor(_ editor: NSTextView, toLine targetLine: Int) {
        let nsText = editor.string as NSString
        guard nsText.length > 0 else { return }
        var currentLine = 1
        var offset = 0
        while currentLine < targetLine && offset < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(lineRange)
            currentLine += 1
        }
        let clampedLoc = min(offset, max(0, nsText.length - 1))
        let targetRange = nsText.lineRange(for: NSRange(location: clampedLoc, length: 0))
        editor.setSelectedRange(targetRange)
        editor.scrollRangeToVisible(targetRange)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditor
        weak var ruler: CodeLineRuler?
        var lastFindVisibility = false
        var findObservation: NSKeyValueObservation?
        var highlightTask: Task<Void, Never>?
        var lastLanguage: SyntaxLanguage = .plain
        var lastPaletteKey: String = ""
        var didJumpToInitialLine = false

        init(_ parent: NativeCodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            ruler?.reindex()
            scheduleHighlighting(for: editor)
        }

        func scheduleHighlighting(for editor: NSTextView) {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self, weak editor] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, let editor else { return }
                self.applyHighlighting(to: editor)
            }
        }

        func applyHighlighting(to editor: NSTextView) {
            guard let layoutManager = editor.layoutManager,
                  let storage = editor.textStorage else { return }
            lastLanguage = parent.language
            lastPaletteKey = "\(parent.highlightPalette?.surface ?? "sys")_\(parent.highlightPalette?.accent ?? "sys")_\(parent.highlightPalette?.ansi.first ?? "sys")_\(parent.isDarkTheme)"

            let fullRange = NSRange(location: 0, length: storage.length)
            if fullRange.length > 0 {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            }
            let tokens = SyntaxHighlighter.tokenize(editor.string, language: parent.language)
            guard !tokens.isEmpty else { return }

            let activePalette = parent.highlightPalette
                ?? (parent.isDarkTheme ? TerminalThemePreset.modern.palette : TerminalThemePreset.nativeLight.palette)
            for token in tokens {
                guard token.range.location + token.range.length <= storage.length else { continue }
                let color = SyntaxHighlighter.color(for: token.kind, palette: activePalette, isDark: parent.isDarkTheme)
                layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
            }
        }
    }
}

/// Only visible lines are drawn; the gutter uses the editor's own layout and scroll offset.
final class CodeLineRuler: NSRulerView {
    override var wantsDefaultClipping: Bool { true }
    private weak var editor: NSTextView?
    private var lineStarts: [Int] = [0]
    var fillColor: NSColor = .controlBackgroundColor
    var labelColor: NSColor = .secondaryLabelColor
    var separatorColor: NSColor = .separatorColor

    init(editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 48
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reindex() {
        lineStarts = [0]
        guard let editor else { return }
        for (offset, unit) in editor.string.utf16.enumerated() where unit == 10 {
            lineStarts.append(offset + 1)
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let viewport = convert(editor.visibleRect, from: editor)
        NSBezierPath(rect: bounds.intersection(NSRect(
            x: bounds.minX, y: viewport.minY,
            width: bounds.width, height: viewport.height
        ))).addClip()
        fillColor.setFill()
        bounds.fill()
        separatorColor.setStroke()
        let borderPath = NSBezierPath()
        borderPath.lineWidth = 1.0
        let separatorX = bounds.maxX - 0.5
        borderPath.move(to: NSPoint(x: separatorX, y: bounds.minY))
        borderPath.line(to: NSPoint(x: separatorX, y: bounds.maxY))
        borderPath.stroke()
        let visible = editor.visibleRect.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var low = 0
        var high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] < characters.location { low = mid + 1 } else { high = mid }
        }
        let start = max(0, low - 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: labelColor
        ]
        for index in start..<lineStarts.count {
            let offset = lineStarts[index]
            if offset > NSMaxRange(characters) { break }
            let position: NSRect
            if offset < (editor.string as NSString).length {
                let glyph = layout.glyphIndexForCharacter(at: offset)
                position = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                position = layout.extraLineFragmentRect
            }
            let label = "\(index + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            let point = convert(NSPoint(x: 0, y: position.minY + editor.textContainerOrigin.y), from: editor)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: point.y + 1), withAttributes: attrs)
        }
    }
}
