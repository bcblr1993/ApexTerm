import AppKit
import SwiftUI

/// AppKit owns editing, undo, IME, selection and the standard find bar.
struct NativeCodeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var showsFindBar: Bool
    var isReloading: Bool

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
        coordinator.findObservation?.invalidate()
        coordinator.findObservation = nil
        (scroll.documentView as? NSTextView)?.delegate = nil
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            context.coordinator.ruler?.reindex()
        }
        editor.isEditable = !isReloading
        editor.backgroundColor = .textBackgroundColor
        editor.textColor = .textColor
        editor.insertionPointColor = .textColor
        if context.coordinator.lastFindVisibility != showsFindBar {
            context.coordinator.lastFindVisibility = showsFindBar
            let action = NSMenuItem()
            action.tag = (showsFindBar ? NSTextFinder.Action.showFindInterface : .hideFindInterface).rawValue
            editor.performTextFinderAction(action)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeCodeEditor
        weak var ruler: CodeLineRuler?
        var lastFindVisibility = false
        var findObservation: NSKeyValueObservation?
        init(_ parent: NativeCodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            ruler?.reindex()
        }
    }
}

/// Only visible lines are drawn; the gutter uses the editor's own layout and scroll offset.
final class CodeLineRuler: NSRulerView {
    private weak var editor: NSTextView?
    private var lineStarts: [Int] = [0]

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
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
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
            .foregroundColor: NSColor.secondaryLabelColor
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
