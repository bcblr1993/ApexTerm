import SwiftUI
import AppKit
import CoreText
import ApexCore

/// High-performance native AppKit Terminal View wrapper for SwiftUI with 120Hz ProMotion support
public struct TerminalRepresentable: NSViewRepresentable {
    public let ringBuffer: TerminalRingBuffer
    public var isFocused: Bool = false
    public var onFocus: (() -> Void)? = nil
    public var isCopyOnSelectEnabled: Bool = true
    public var triggers: [Trigger] = []
    public var onResize: ((Int, Int) -> Void)? = nil
    public var onFileDrop: ((URL) -> Void)? = nil
    public let onInput: (Data) -> Void
    
    public init(
        ringBuffer: TerminalRingBuffer,
        isFocused: Bool = false,
        onFocus: (() -> Void)? = nil,
        isCopyOnSelectEnabled: Bool = true,
        triggers: [Trigger] = [],
        onResize: ((Int, Int) -> Void)? = nil,
        onFileDrop: ((URL) -> Void)? = nil,
        onInput: @escaping (Data) -> Void
    ) {
        self.ringBuffer = ringBuffer
        self.isFocused = isFocused
        self.onFocus = onFocus
        self.isCopyOnSelectEnabled = isCopyOnSelectEnabled
        self.triggers = triggers
        self.onResize = onResize
        self.onFileDrop = onFileDrop
        self.onInput = onInput
    }
    
    public func makeNSView(context: Context) -> NativeTerminalScrollView {
        let scrollView = NativeTerminalScrollView()
        scrollView.requestsInitialFocus = isFocused
        scrollView.terminalView.onInput = onInput
        scrollView.terminalView.ringBuffer = ringBuffer
        scrollView.terminalView.setTriggers(triggers)
        scrollView.terminalView.isCopyOnSelectEnabled = isCopyOnSelectEnabled
        scrollView.terminalView.onResize = onResize
        scrollView.terminalView.onFileDrop = onFileDrop
        scrollView.terminalView.onFocus = onFocus
        context.coordinator.scrollView = scrollView
        context.coordinator.wasFocused = isFocused
        
        // 120Hz Coalesced real-time listener: batch stream updates to prevent UI overload
        ringBuffer.onUpdate = { [weak scrollView] in
            scrollView?.terminalView.scheduleRefresh()
        }
        
        // Immediate full rehydration of any existing buffer content (fixes blank pane after split)
        scrollView.terminalView.refresh()
        
        // Auto-focus if this pane is focused and sync initial PTY window size
        DispatchQueue.main.async {
            if isFocused, let window = scrollView.window {
                // Initial mounting can finish after the user starts editing a path or search field.
                // Do not let this deferred first focus overwrite an existing editing responder.
                let isEditingControl = (window.firstResponder as? NSTextView)?.isFieldEditor == true
                    || window.firstResponder is NSTextField
                if !isEditingControl { window.makeFirstResponder(scrollView.terminalView) }
            }
            scrollView.terminalView.notifyDimensionsChangedIfNeeded(immediate: true)
            if scrollView.terminalView.ringBuffer?.isInAlternateScreen != true {
                scrollView.terminalView.scrollToBottom(forceLayout: true)
            }
        }
        
        return scrollView
    }
    
    public func updateNSView(_ nsView: NativeTerminalScrollView, context: Context) {
        let terminal = nsView.terminalView
        nsView.requestsInitialFocus = isFocused
        let bufferChanged = terminal.ringBuffer !== ringBuffer
        if bufferChanged {
            terminal.ringBuffer = ringBuffer
        }
        terminal.onInput = onInput
        terminal.setTriggers(triggers)
        terminal.isCopyOnSelectEnabled = isCopyOnSelectEnabled
        terminal.onResize = onResize
        terminal.onFileDrop = onFileDrop
        terminal.onFocus = onFocus
        
        ringBuffer.onUpdate = { [weak nsView] in
            nsView?.terminalView.scheduleRefresh()
        }
        
        // If textStorage is empty but ringBuffer already contains output, force immediate rehydration
        if (terminal.textStorage?.length ?? 0) == 0 && (ringBuffer.totalCommittedCount > 0 || !ringBuffer.currentActiveLine.isEmpty) {
            terminal.refresh()
        }
        
        nsView.terminalView.notifyDimensionsChangedIfNeeded(immediate: false)
        
        let shouldFocus = isFocused && (!context.coordinator.wasFocused || bufferChanged)
        context.coordinator.wasFocused = isFocused
        if shouldFocus {
            if let window = nsView.window, window.firstResponder != terminal {
                DispatchQueue.main.async {
                    window.makeFirstResponder(terminal)
                }
            }
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public class Coordinator {
        var scrollView: NativeTerminalScrollView?
        var wasFocused = false
    }
}

/// Floating Find Bar overlay for Terminal with search field, match count and navigation
public final class TerminalFindBarView: NSView, NSTextFieldDelegate {
    public weak var terminalView: NativeTerminalView?
    
    public let searchField = NSTextField()
    public let matchLabel = NSTextField(labelWithString: "")
    public let prevButton = NSButton()
    public let nextButton = NSButton()
    public let closeButton = NSButton()
    
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented", file: #fileID)
    }
    
    public func applyTheme() {
        let p = AppSettings.shared.themePreset.palette
        appearance = NSAppearance(named: AppSettings.shared.themePreset.isDark ? .darkAqua : .aqua)
        layer?.backgroundColor = NSColor(hex: p.surface)?.cgColor
        layer?.borderColor = NSColor(hex: p.border)?.cgColor
        searchField.backgroundColor = NSColor(hex: p.sidebar) ?? .controlBackgroundColor
        searchField.textColor = NSColor(hex: p.foreground)
        matchLabel.textColor = NSColor(hex: p.secondary)
        for button in [prevButton, nextButton, closeButton] {
            button.contentTintColor = NSColor(hex: p.foreground)
        }
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor(hex: AppSettings.shared.themePreset.palette.surface)?.cgColor
        
        searchField.placeholderString = "查找 (⌘F)..."
        searchField.isBezeled = false
        searchField.drawsBackground = true
        searchField.backgroundColor = NSColor(hex: AppSettings.shared.themePreset.palette.sidebar) ?? .controlBackgroundColor
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 5
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.textColor = .labelColor
        searchField.focusRingType = .none
        searchField.delegate = self
        
        matchLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.alignment = .right
        
        configureButton(prevButton, symbolName: "chevron.up", tooltip: "上一个 (⇧Enter)", action: #selector(prevClicked))
        configureButton(nextButton, symbolName: "chevron.down", tooltip: "下一个 (Enter)", action: #selector(nextClicked))
        configureButton(closeButton, symbolName: "xmark", tooltip: "关闭 (Esc)", action: #selector(closeClicked))
        
        addSubview(searchField)
        addSubview(matchLabel)
        addSubview(prevButton)
        addSubview(nextButton)
        addSubview(closeButton)
    }
    
    private func configureButton(_ btn: NSButton, symbolName: String, tooltip: String, action: Selector) {
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        btn.imageScaling = .scaleProportionallyDown
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        btn.contentTintColor = .secondaryLabelColor
    }
    
    override public func layout() {
        super.layout()
        let h = bounds.height
        let btnW: CGFloat = 22
        let closeW: CGFloat = 22
        let margin: CGFloat = 6
        let matchW: CGFloat = 55
        
        closeButton.frame = NSRect(x: bounds.width - closeW - margin, y: (h - 20) / 2, width: closeW, height: 20)
        nextButton.frame = NSRect(x: closeButton.frame.minX - btnW - 2, y: (h - 20) / 2, width: btnW, height: 20)
        prevButton.frame = NSRect(x: nextButton.frame.minX - btnW - 2, y: (h - 20) / 2, width: btnW, height: 20)
        matchLabel.frame = NSRect(x: prevButton.frame.minX - matchW - 4, y: (h - 16) / 2, width: matchW, height: 16)
        
        let searchW = matchLabel.frame.minX - margin - 4
        searchField.frame = NSRect(x: margin, y: (h - 22) / 2, width: max(50, searchW), height: 22)
    }
    
    public func show(withInitialText text: String? = nil) {
        isHidden = false
        if let t = text, !t.isEmpty {
            searchField.stringValue = t
            updateSearch()
        } else if !searchField.stringValue.isEmpty {
            updateSearch()
        }
        window?.makeFirstResponder(searchField)
    }
    
    public func hide() {
        isHidden = true
        terminalView?.clearFind()
        matchLabel.stringValue = ""
        if let term = terminalView {
            window?.makeFirstResponder(term)
        }
    }
    
    @objc private func prevClicked() {
        guard let term = terminalView else { return }
        _ = term.findPrevious()
        updateMatchLabel()
    }
    
    @objc private func nextClicked() {
        guard let term = terminalView else { return }
        _ = term.findNext()
        updateMatchLabel()
    }
    
    @objc private func closeClicked() {
        hide()
    }
    
    public func controlTextDidChange(_ obj: Notification) {
        updateSearch()
    }
    
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) {
                prevClicked()
            } else {
                nextClicked()
            }
            return true
        } else if commandSelector == #selector(cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }
    
    private func updateSearch() {
        guard let term = terminalView else { return }
        let query = searchField.stringValue
        _ = term.performFind(query: query)
        updateMatchLabel()
    }
    
    public func updateMatchLabel() {
        guard let term = terminalView else {
            matchLabel.stringValue = ""
            return
        }
        let total = term.currentMatches.count
        if total == 0 {
            matchLabel.stringValue = searchField.stringValue.isEmpty ? "" : "0 结果"
        } else {
            matchLabel.stringValue = "\(term.currentMatchIndex + 1)/\(total)"
        }
    }
}

/// Dedicated Flipped ClipView for Terminal ensuring 1:1 coordinate alignment with NSTextView
/// and preventing negative origin drift or top-line clipping during layout and scrolling.
public final class TerminalClipView: NSClipView {
    override public var isFlipped: Bool { true }
    
    override public func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin = constrainPoint(rect.origin, in: proposedBounds.size)
        return rect
    }
    
    override public func scroll(to newOrigin: NSPoint) {
        let constrained = constrainPoint(newOrigin, in: bounds.size)
        super.scroll(to: constrained)
    }
    
    override public func layout() {
        super.layout()
        if let termView = documentView as? NativeTerminalView,
           termView.ringBuffer?.isInAlternateScreen == true {
            if termView.frame.origin != .zero {
                termView.frame.origin = .zero
            }
            if bounds.origin != .zero {
                bounds.origin = .zero
            }
        }
    }
    
    private func constrainPoint(_ p: NSPoint, in size: NSSize) -> NSPoint {
        guard size.height > 0 else { return .zero }
        
        // If terminal is in alternate screen mode (e.g. Vim, less, htop), origin MUST be locked to .zero
        if let termView = documentView as? NativeTerminalView,
           termView.ringBuffer?.isInAlternateScreen == true {
            return .zero
        }
        
        var targetY = p.y
        if let doc = documentView {
            let docHeight = doc.frame.height
            let clipHeight = size.height
            if docHeight <= clipHeight {
                targetY = 0
            } else {
                targetY = min(max(0, targetY), max(0, docHeight - clipHeight))
            }
        } else {
            targetY = max(0, targetY)
        }
        return NSPoint(x: 0, y: targetY)
    }
}

public final class NativeTerminalScrollView: NSScrollView {
    public let terminalView = NativeTerminalView()
    public let searchBarOverlay = TerminalFindBarView()
    var requestsInitialFocus = false

    override public var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set {
            // Input-device changes must not alter terminal columns or reflow the
            // entire scrollback. Overlay scrollers keep the viewport width stable.
            if super.scrollerStyle != .overlay { super.scrollerStyle = .overlay }
        }
    }
    
    override public init(frame frameRect: NSRect) {
        let initialFrame = (frameRect.width <= 0 || frameRect.height <= 0)
            ? NSRect(x: 0, y: 0, width: 800, height: 600)
            : frameRect
        super.init(frame: initialFrame)
        setupScrollView()
    }
    
    public convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }
    
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: nil)
        
        if let window = self.window {
            NotificationCenter.default.addObserver(self, selector: #selector(handleWindowBoundsChange), name: NSWindow.didResizeNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(handleWindowBoundsChange), name: NSWindow.didEnterFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(handleWindowBoundsChange), name: NSWindow.didExitFullScreenNotification, object: window)
        }
        
        guard requestsInitialFocus, let window else { return }
        if !window.isVisible {
            window.initialFirstResponder = terminalView
        } else {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      self.requestsInitialFocus, window.isVisible else { return }
                let isEditingControl = (window.firstResponder as? NSTextView)?.isFieldEditor == true
                    || window.firstResponder is NSTextField
                if !isEditingControl { window.makeFirstResponder(self.terminalView) }
            }
        }
    }

    @objc private func handleWindowBoundsChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.terminalView.notifyDimensionsChangedIfNeeded(immediate: true)
        }
    }

    private func setupScrollView() {
        self.contentView = TerminalClipView()
        self.hasVerticalScroller = true
        self.scrollerStyle = .overlay
        self.hasHorizontalScroller = false
        self.autohidesScrollers = true
        self.drawsBackground = true
        let bg = NSColor(hex: AppSettings.shared.themePreset.backgroundColorHex) ?? NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        self.backgroundColor = bg
        
        terminalView.minSize = NSSize(width: 0, height: 0)
        terminalView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        terminalView.isVerticallyResizable = true
        terminalView.isHorizontallyResizable = false
        terminalView.autoresizingMask = [.width]
        terminalView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        terminalView.textContainer?.widthTracksTextView = true
        
        self.documentView = terminalView
        
        // AppKit owns synchronous text drawing; the compositor handles layer updates.
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.contentView.wantsLayer = true
        self.contentView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        
        // Find Bar Overlay
        searchBarOverlay.terminalView = terminalView
        searchBarOverlay.isHidden = true
        searchBarOverlay.wantsLayer = true
        searchBarOverlay.layer?.zPosition = 1000
        self.addSubview(searchBarOverlay)
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleTriggerFindNotification), name: NSNotification.Name("TriggerTerminalFind"), object: nil)
        
        // Register for file drop
        self.registerForDraggedTypes([.fileURL])
    }
    
    override public func layout() {
        super.layout()
        let barW: CGFloat = 300
        let barH: CGFloat = 32
        let x = max(8, bounds.width - barW - 14)
        let y = max(8, bounds.height - barH - 8)
        searchBarOverlay.frame = NSRect(x: x, y: y, width: barW, height: barH)
    }
    
    public func showFindBar() {
        var initialText: String? = nil
        if let sel = terminalView.selectedRangeText(), !sel.isEmpty, !sel.contains("\n") {
            initialText = sel
        }
        searchBarOverlay.show(withInitialText: initialText)
    }
    
    public func hideFindBar() {
        searchBarOverlay.hide()
    }
    
    @objc private func handleTriggerFindNotification(_ note: Notification) {
        if let win = window, win.isKeyWindow, win.firstResponder === terminalView {
            showFindBar()
        }
    }
    
    override public func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = (newSize != self.frame.size)
        super.setFrameSize(newSize)
        if sizeChanged {
            if terminalView.ringBuffer?.isInAlternateScreen == true {
                terminalView.frame.origin = .zero
                contentView.bounds.origin = .zero
                contentView.scroll(to: .zero)
                terminalView.isPinnedToBottom = false
            } else {
                if terminalView.frame.origin != .zero {
                    terminalView.frame.origin = .zero
                }
                if terminalView.isPinnedToBottom {
                    terminalView.scrollToBottom(forceLayout: true)
                }
            }
            terminalView.notifyDimensionsChangedIfNeeded(immediate: !inLiveResize)
        }
    }
    
    override public func tile() {
        super.tile()
        terminalView.notifyDimensionsChangedIfNeeded(immediate: false)
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        terminalView.notifyDimensionsChangedIfNeeded(immediate: true)
    }
    
    override public func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(terminalView)
        terminalView.onFocus?()
        super.mouseDown(with: event)
    }
    
    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            return .copy
        }
        return []
    }
    
    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        if let dropHandler = terminalView.onFileDrop {
            for url in urls {
                dropHandler(url)
            }
            return true
        }
        return false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented", file: #fileID)
    }
}

/// Native Terminal View with full macOS Chinese IME (拼音/五笔) support and incremental 120Hz rendering
@MainActor
public final class NativeTerminalView: NSTextView {
    public var ringBuffer: TerminalRingBuffer? {
        didSet {
            if oldValue !== ringBuffer {
                resizeDebounceTask?.cancel()
                resizeDebounceTask = nil
                pendingDimensions = nil
                lastReportedDimensions = nil
                lastCommittedIndex = 0
                activeLineStartLocation = 0
                textStorage?.setAttributedString(NSAttributedString())
                scheduleRefresh()
            }
        }
    }
    public var onInput: ((Data) -> Void)?
    public var isCopyOnSelectEnabled: Bool = true
    public var onResize: ((Int, Int) -> Void)?
    public var onFileDrop: ((URL) -> Void)?
    public var onFocus: (() -> Void)? = nil
    
    private var lastReportedDimensions: (cols: Int, rows: Int)? = nil
    private var renderedScreenRows: [NSAttributedString]?
    private var resizeDebounceTask: Task<Void, Never>? = nil
    private var pendingDimensions: (cols: Int, rows: Int)?
    
    private let parser = VTParser()
    private let keywordHighlighter = KeywordHighlighter()
    private var activeTriggers: [Trigger] = []

    public func setTriggers(_ triggers: [Trigger]) {
        guard triggers != activeTriggers else { return }
        activeTriggers = triggers
        keywordHighlighter.setTriggers(triggers)
        renderedScreenRows = nil
        if (textStorage?.length ?? 0) > 0 {
            textStorage?.setAttributedString(NSAttributedString())
            lastCommittedIndex = 0
            activeLineStartLocation = 0
            refresh()
        }
    }
    private var renderedActiveLine: String?
    private var renderedCommittedLineLengths: [Int] = []
    private var renderedLineHead = 0
    private var lastCommittedIndex: Int64 = 0 {
        didSet {
            if lastCommittedIndex == 0 {
                renderedActiveLine = nil
                renderedCommittedLineLengths.removeAll(keepingCapacity: true)
                renderedLineHead = 0
            }
        }
    }
    private var activeLineStartLocation = 0
    private var customInputContext: NSTextInputContext?
    private var currentMarkedText: String = ""
    private var currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    
    // Terminal frame coalescing & throttling
    private let refreshLock = NSLock()
    nonisolated(unsafe) private var isRefreshScheduled: Bool = false
    nonisolated(unsafe) private var refreshRequestedDuringRefresh: Bool = false
    
    // Terminal cursor and blinking state
    private var isCursorVisible: Bool = true
    private var cursorBlinkTimer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var isFocused: Bool = false
    private var lastRenderedCursorRect: NSRect? = nil
    
    // High-performance styling cache for zero-allocation 120Hz rendering
    private var cachedBaseFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var cachedBoldFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var glyphAdvanceCache: [String: CGFloat] = [:]
    private static var colorCache: [String: NSColor] = [:]
    private static let colorCacheLock = NSLock()
    
    /// Tracks whether viewport is pinned to the command prompt line at the bottom
    public var isPinnedToBottom: Bool = true
    
    /// Calculate current rows and columns based on visible scroll view bounds and font metrics
    public func calculateTerminalDimensions() -> (cols: Int, rows: Int) {
        let font = cachedBaseFont
        let layoutManager = self.layoutManager
        let lineHeight = max(12, layoutManager?.defaultLineHeight(for: font) ?? 16)
        let charWidth = max(6, ("M" as NSString).size(withAttributes: [.font: font]).width)
        
        // PTY dimensions describe the visible viewport, never the scrollback document.
        let viewport = enclosingScrollView?.contentView.bounds.size ?? bounds.size
        let containerWidth = viewport.width
        let containerHeight = viewport.height

        let visibleWidth = max(60, containerWidth)
        let visibleHeight = max(40, containerHeight)
        
        let horizontalInset = textContainerInset.width * 2
        let verticalInset = textContainerInset.height * 2
        let cols = max(10, Int((visibleWidth - horizontalInset) / charWidth))
        let rows = max(3, Int((visibleHeight - verticalInset) / lineHeight))
        return (cols, rows)
    }
    
    /// Check whether clipView is currently resting at the bottom of the document
    public func isScrolledToBottom() -> Bool {
        guard let clipView = self.enclosingScrollView?.contentView else { return true }
        let clipHeight = clipView.bounds.height
        guard clipHeight > 0 else { return true }
        let docHeight = self.frame.height
        let targetY = max(0, docHeight - clipHeight)
        return abs(clipView.bounds.origin.y - targetY) <= 1.0
    }
    
    /// Canonical rock-solid scroll to bottom ensuring prompt line is always visible without flicker.
    /// forceLayout is only needed when geometry changed (e.g. divider drag / setFrameSize).
    public func scrollToBottom(forceLayout: Bool = false) {
        if ringBuffer?.isInAlternateScreen == true {
            self.frame.origin = .zero
            if let clipView = self.enclosingScrollView?.contentView, clipView.bounds.origin != .zero {
                clipView.bounds.origin = .zero
                clipView.scroll(to: .zero)
            }
            return
        }
        guard let storage = self.textStorage, storage.length > 0 else { return }
        guard let clipView = self.enclosingScrollView?.contentView else { return }
        
        let clipHeight = clipView.bounds.height
        // Prevent scrolling on zero/unmounted clipView: scrolling with zero height corrupts
        // documentView.frame.origin into negative space in AppKit.
        guard clipHeight > 0 else { return }
        
        // Ensure documentView origin is never negative (which pushes the first line off-screen)
        if self.frame.origin.y < 0 || self.frame.origin.x != 0 {
            self.frame.origin = NSPoint(x: 0, y: max(0, self.frame.origin.y))
        }
        
        if forceLayout {
            let endRange = NSRange(location: storage.length - 1, length: 1)
            self.layoutManager?.ensureLayout(forCharacterRange: endRange)
        }
        
        let docHeight = self.frame.height
        guard docHeight > 0 else { return }
        
        // If content fits within the viewport, the canonical resting position is always 0 (top line visible)
        let targetY = max(0, docHeight - clipHeight)
        
        // Only scroll if the offset actually changed, avoiding jitter and scroll feedback loops
        if abs(clipView.bounds.origin.y - targetY) > 0.5 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clipView.scroll(to: NSPoint(x: 0, y: targetY))
            self.enclosingScrollView?.reflectScrolledClipView(clipView)
            CATransaction.commit()
        }
    }
    
    /// Notify remote PTY of new dimensions with debounce (prevents SIGWINCH storm during drag)
    public func notifyDimensionsChangedIfNeeded(immediate: Bool = false) {
        let (cols, rows) = calculateTerminalDimensions()
        ringBuffer?.setDimensions(columns: cols, rows: rows)
        if lastReportedDimensions?.cols != cols || lastReportedDimensions?.rows != rows {
            if !immediate, pendingDimensions?.cols == cols, pendingDimensions?.rows == rows { return }
            resizeDebounceTask?.cancel()
            resizeDebounceTask = nil
            pendingDimensions = nil
            
            if immediate {
                self.lastReportedDimensions = (cols, rows)
                self.onResize?(cols, rows)
            } else {
                pendingDimensions = (cols, rows)
                resizeDebounceTask = Task { @MainActor [weak self] in
                    // 100ms debounce ensures remote PTY only resizes after active dragging pauses
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled, let self = self else { return }
                    self.pendingDimensions = nil
                    self.resizeDebounceTask = nil
                    self.lastReportedDimensions = (cols, rows)
                    self.onResize?(cols, rows)
                }
            }
        } else if pendingDimensions != nil {
            // The divider returned to the already-reported size before the timer fired.
            resizeDebounceTask?.cancel()
            resizeDebounceTask = nil
            pendingDimensions = nil
        }
    }
    
    override public func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipView = enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsDidChange), name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }
    
    @objc private func clipViewBoundsDidChange() {
        if let clipView = enclosingScrollView?.contentView {
            let docHeight = self.frame.height
            let clipHeight = clipView.bounds.height
            let currentBottom = clipView.bounds.origin.y + clipHeight
            
            // If user scrolled up by more than 25 points, unpin so we don't disrupt their reading
            if docHeight <= clipHeight || (docHeight - currentBottom) <= 25.0 {
                isPinnedToBottom = true
            } else {
                isPinnedToBottom = false
            }
        }
    }
    
    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            return .copy
        }
        return []
    }
    
    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        if let dropHandler = onFileDrop {
            for url in urls {
                dropHandler(url)
            }
            return true
        }
        return false
    }
    
    /// Coalesced refresh on the main thread for high-framerate batching (thread-safe, nonisolated)
    nonisolated public func scheduleRefresh() {
        refreshLock.lock()
        if isRefreshScheduled {
            refreshRequestedDuringRefresh = true
            refreshLock.unlock()
            return
        }
        isRefreshScheduled = true
        refreshLock.unlock()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            guard let self = self else { return }
            self.refreshLock.lock()
            self.refreshRequestedDuringRefresh = false
            self.refreshLock.unlock()
            self.refresh()
            self.refreshLock.lock()
            let needsAnotherRefresh = self.refreshRequestedDuringRefresh
            self.isRefreshScheduled = false
            self.refreshLock.unlock()
            // Start the next deadline after this layout completes, so slow frames
            // cannot leave an already-due refresh continuously draining the main queue.
            if needsAnotherRefresh { self.scheduleRefresh() }
        }
    }
    
    override public init(frame frameRect: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: textContainer)
        setupTerminalView()
    }
    
    public convenience init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }
    
    private func setupTerminalView() {
        self.isEditable = false
        self.isSelectable = true
        self.drawsBackground = true
        self.insertionPointColor = NSColor.cyan
        
        // Apply settings initially
        applyAppSettings()
        
        // Terminal padding / insets: 10px horizontal and vertical breathing room
        self.textContainerInset = NSSize(width: 10, height: 10)
        self.textContainer?.lineFragmentPadding = 0
        
        // Critical for AppKit NSTextView vertical auto-resizing in NSScrollView
        self.minSize = NSSize(width: 0, height: 0)
        self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        self.isVerticallyResizable = true
        self.isHorizontallyResizable = false
        self.autoresizingMask = [.width]
        self.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        self.textContainer?.widthTracksTextView = true
        
        // Enable hardware accelerated rendering
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        
        self.registerForDraggedTypes([.fileURL])
        
        settingsObserver = NotificationCenter.default.addObserver(forName: AppSettings.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyAppSettings()
            }
        }
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        startCursorBlink()
    }

    @objc private func accessibilityOptionsChanged() {
        startCursorBlink()
        needsDisplay = true
    }

    public func applyAppSettings() {
        let settings = AppSettings.shared
        let wasPinned = isPinnedToBottom
        let previousScrollOrigin = enclosingScrollView?.contentView.bounds.origin
        ringBuffer?.setHistoryLimit(settings.scrollbackMaxLines)
        
        // 1. Font
        let baseSize = CGFloat(settings.fontSize)
        let resolvedFont: NSFont
        if settings.fontName == "SF Mono" || settings.fontName == "System Monospaced" {
            resolvedFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
        } else if let custom = NSFont(name: settings.fontName, size: baseSize) {
            resolvedFont = custom
        } else {
            resolvedFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
        }
        let fontChanged = cachedBaseFont.fontName != resolvedFont.fontName || cachedBaseFont.pointSize != resolvedFont.pointSize
        if fontChanged || (textStorage?.length ?? 0) == 0 { self.font = resolvedFont }
        self.cachedBaseFont = resolvedFont
        self.cachedBoldFont = NSFontManager.shared.convert(resolvedFont, toHaveTrait: .boldFontMask)
        glyphAdvanceCache.removeAll(keepingCapacity: true)
        
        // 2. Theme & Colors
        let theme = settings.themePreset
        let bg = NSColor(hex: theme.backgroundColorHex) ?? NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        let fg = NSColor(hex: theme.foregroundColorHex) ?? NSColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1.0)
        self.backgroundColor = bg
        self.enclosingScrollView?.backgroundColor = bg
        self.typingAttributes[.foregroundColor] = fg
        self.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        self.insertionPointColor = NSColor(hex: theme.cursorColorHex) ?? fg
        self.selectedTextAttributes = [.backgroundColor: NSColor(hex: theme.palette.selection) ?? bg, .foregroundColor: fg]
        if let scroll = enclosingScrollView as? NativeTerminalScrollView { scroll.searchBarOverlay.applyTheme() }
        // Recolor already-rendered scrollback without reconnecting or clearing the buffer.
        if let storage = textStorage {
            storage.beginEditing()
            storage.enumerateAttribute(NSAttributedString.Key("ApexThemeColor"), in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let index = value as? Int else { return }
                if index == -1 { storage.addAttribute(.foregroundColor, value: fg, range: range) }
                else if index == -3 { storage.addAttribute(.foregroundColor, value: bg, range: range) }
                else if index >= 0, let color = NSColor(hex: theme.palette.terminalColor(at: index)) {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            storage.enumerateAttribute(NSAttributedString.Key("ApexThemeBackground"), in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let index = value as? Int else { return }
                if index == -1 { storage.addAttribute(.backgroundColor, value: fg, range: range) }
                else if index >= 0, let color = NSColor(hex: theme.palette.terminalColor(at: index)) { storage.addAttribute(.backgroundColor, value: color, range: range) }
            }
            storage.endEditing()
        }
        
        // 3. Cursor
        if !settings.isCursorBlinkEnabled {
            stopCursorBlink()
            isCursorVisible = true
        } else if isFocused {
            startCursorBlink()
        }
        
        renderedScreenRows = nil
        if ringBuffer?.isInAlternateScreen == true { refresh() }
        else if fontChanged, ringBuffer != nil {
            // Recompute wide-glyph advances and ANSI font traits for existing output.
            textStorage?.setAttributedString(NSAttributedString())
            lastCommittedIndex = 0
            activeLineStartLocation = 0
            isPinnedToBottom = wasPinned
            refresh()
            if !wasPinned, let origin = previousScrollOrigin, let clip = enclosingScrollView?.contentView {
                clip.scroll(to: origin)
                enclosingScrollView?.reflectScrolledClipView(clip)
                isPinnedToBottom = false
            }
        }

        // 4. Copy behavior
        self.isCopyOnSelectEnabled = settings.isCopyOnSelectEnabled
        
        if !currentMatches.isEmpty { highlightAllMatches() }
        self.notifyDimensionsChangedIfNeeded()
        self.needsDisplay = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented", file: #fileID)
    }
    
    override public var acceptsFirstResponder: Bool { true }
    override public var canBecomeKeyView: Bool { true }
    override public var needsPanelToBecomeKey: Bool { false }
    
    override public func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            isFocused = true
            inputContext?.activate()
            startCursorBlink()
            onFocus?()
        }
        return ok
    }
    
    override public func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            inputContext?.deactivate()
            isFocused = false
            stopCursorBlink()
        }
        return ok
    }
    
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let win = window {
            startCursorBlink()
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: win)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: win)
            scheduleRefresh()
        } else {
            stopCursorBlink()
        }
    }
    
    @objc private func windowDidBecomeKey() {
        startCursorBlink()
    }
    
    @objc private func windowDidResignKey() {
        stopCursorBlink()
        needsDisplay = true
    }
    
    isolated deinit {
        cursorBlinkTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }
    
    // MARK: - Terminal Cursor Implementation
    
    /// Cursor geometry is also used by IME positioning and viewport regression checks.
    var terminalCursorRect: NSRect? { getCursorRect() }

    private func getCursorRect() -> NSRect? {
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer,
              let storage = self.textStorage else { return nil }
        
        let origin = self.textContainerOrigin
        let font = cachedBaseFont
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let shape = AppSettings.shared.cursorShape
        let charWidth = max(6, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let cursorWidth: CGFloat = (shape == .bar) ? 2.5 : charWidth
        
        // 1. Alternate screen buffer mode (Vim, Less, Htop): precise 2D cell grid coordinates
        if let buffer = ringBuffer, buffer.isInAlternateScreen {
            let pos = buffer.cursorPosition
            let row = max(0, pos.row)
            let col = max(0, pos.column)
            let x = origin.x + CGFloat(col) * charWidth
            let y = origin.y + CGFloat(row) * lineHeight
            if shape == .underline {
                return NSRect(x: x, y: y + lineHeight - 2.5, width: cursorWidth, height: 2.5)
            } else {
                return NSRect(x: x, y: y, width: cursorWidth, height: lineHeight)
            }
        }
        
        // 2. Normal scrollback mode:
        let length = storage.length
        if length == 0 {
            if shape == .underline {
                return NSRect(x: origin.x, y: origin.y + lineHeight - 2.5, width: cursorWidth, height: 2.5)
            } else {
                return NSRect(x: origin.x, y: origin.y, width: cursorWidth, height: lineHeight)
            }
        }
        
        let cursorCol = ringBuffer?.activeCursorUTF16Offset ?? (length - activeLineStartLocation)
        let cursorCharIndex = min(length, max(0, activeLineStartLocation + cursorCol))
        
        let x: CGFloat
        let y: CGFloat
        let h: CGFloat
        
        if cursorCharIndex < length {
            let glyph = layoutManager.glyphIndexForCharacter(at: cursorCharIndex)
            let charRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            x = origin.x + charRect.minX
            y = origin.y + charRect.minY
            h = charRect.height > 0 ? charRect.height : lineHeight
        } else {
            let lastChar = (storage.string as NSString).substring(with: NSRange(location: length - 1, length: 1))
            if lastChar == "\n" || lastChar == "\r" {
                let extraRect = layoutManager.extraLineFragmentRect
                if extraRect.height > 0 {
                    x = origin.x + extraRect.minX
                    y = origin.y + extraRect.minY
                    h = extraRect.height
                } else {
                    let glyph = layoutManager.glyphIndexForCharacter(at: length - 1)
                    let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    x = origin.x
                    y = origin.y + lineRect.maxY
                    h = lineHeight
                }
            } else {
                let lastGlyph = layoutManager.glyphIndexForCharacter(at: length - 1)
                let charRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: textContainer)
                x = origin.x + charRect.maxX
                y = origin.y + charRect.minY
                h = charRect.height > 0 ? charRect.height : lineHeight
            }
        }
        
        if shape == .underline {
            return NSRect(x: x, y: y + h - 2.5, width: cursorWidth, height: 2.5)
        } else {
            return NSRect(x: x, y: y, width: cursorWidth, height: h)
        }
    }
    
    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        if !currentMarkedText.isEmpty {
            drawComposition()
            return
        }
        guard ringBuffer?.isCursorHidden != true, let rect = getCursorRect() else { return }
        let focused = (window?.isKeyWindow == true && window?.firstResponder == self)
        if focused {
            guard isCursorVisible else { return }
        }
        lastRenderedCursorRect = rect
        let themeCursor = NSColor(hex: AppSettings.shared.themePreset.cursorColorHex)
        let shape = AppSettings.shared.cursorShape
        if focused {
            let baseColor = themeCursor ?? NSColor(red: 0.20, green: 0.78, blue: 0.95, alpha: 0.95)
            let cursorColor = (shape == .block) ? baseColor.withAlphaComponent(0.70) : baseColor
            cursorColor.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.0, yRadius: 1.0)
            path.fill()
        } else {
            // Unfocused: render clear hollow outline border so cursor position is never lost
            let unfocusedColor = (themeCursor ?? NSColor.textColor).withAlphaComponent(0.55)
            unfocusedColor.setStroke()
            let strokeRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: strokeRect, xRadius: 1.0, yRadius: 1.0)
            path.lineWidth = 1.2
            path.stroke()
        }
    }
    
    /// Preedit is an overlay: it must never enter the remote-output storage or SSH stream.
    private func drawComposition() {
        let font = cachedBaseFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor ?? .textColor,
            .backgroundColor: backgroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let rect = compositionRect()
        backgroundColor.setFill()
        rect.fill()
        (currentMarkedText as NSString).draw(at: rect.origin, withAttributes: attributes)
    }

    private func compositionRect() -> NSRect {
        let font = cachedBaseFont
        let height = layoutManager?.defaultLineHeight(for: font) ?? 18
        var rect = getCursorRect() ?? NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: 12, height: height)
        if AppSettings.shared.cursorShape == .underline { rect.origin.y -= height - 2.5 }
        // CJK fallback fonts can have a taller line than the terminal's monospaced font.
        // A constrained text rectangle must not suppress the entire preedit line.
        let measured = (currentMarkedText as NSString).size(withAttributes: [.font: font])
        rect.size = NSSize(width: max(12, ceil(measured.width) + 2), height: max(height, ceil(measured.height) + 2))
        return rect
    }

    public func startCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        guard isFocused, window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            isCursorVisible = true
            needsDisplay = true
            return
        }
        guard AppSettings.shared.isCursorBlinkEnabled else {
            isCursorVisible = true
            needsDisplay = true
            return
        }
        cursorBlinkTimer?.invalidate()
        isCursorVisible = true
        needsDisplay = true
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isCursorVisible.toggle()
                if let rect = self.getCursorRect() {
                    if let old = self.lastRenderedCursorRect, old != rect {
                        self.setNeedsDisplay(old.insetBy(dx: -4, dy: -4))
                    }
                    self.setNeedsDisplay(rect.insetBy(dx: -4, dy: -4))
                } else {
                    self.needsDisplay = true
                }
            }
        }
    }
    
    public func stopCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        needsDisplay = true
    }
    
    public func resetCursorBlink() {
        isCursorVisible = true
        let newRect = getCursorRect()
        if let old = lastRenderedCursorRect {
            setNeedsDisplay(old.insetBy(dx: -4, dy: -4))
        }
        if let current = newRect {
            setNeedsDisplay(current.insetBy(dx: -4, dy: -4))
            lastRenderedCursorRect = current
        } else {
            needsDisplay = true
        }
    }
    
    // MARK: - Terminal In-View Search State & Navigation
    
    public private(set) var currentMatches: [NSRange] = []
    public private(set) var currentMatchIndex: Int = -1
    
    public func selectedRangeText() -> String? {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage, range.location + range.length <= storage.length else { return nil }
        return (storage.string as NSString).substring(with: range)
    }
    
    public func performFind(query: String) -> Int {
        clearHighlightAttributes()
        currentMatches.removeAll()
        currentMatchIndex = -1
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let storage = self.textStorage else {
            return 0
        }
        
        let string = storage.string as NSString
        let totalLength = string.length
        var searchRange = NSRange(location: 0, length: totalLength)
        
        while searchRange.location < totalLength {
            searchRange.length = totalLength - searchRange.location
            let found = string.range(of: trimmed, options: .caseInsensitive, range: searchRange)
            if found.location != NSNotFound {
                currentMatches.append(found)
                searchRange.location = found.location + max(1, found.length)
            } else {
                break
            }
        }
        
        if !currentMatches.isEmpty {
            currentMatchIndex = 0
            highlightAllMatches()
            scrollToCurrentMatch()
        }
        return currentMatches.count
    }
    
    public func findNext() -> NSRange? {
        guard !currentMatches.isEmpty else { return nil }
        currentMatchIndex = (currentMatchIndex + 1) % currentMatches.count
        highlightAllMatches()
        scrollToCurrentMatch()
        return currentMatches[currentMatchIndex]
    }
    
    public func findPrevious() -> NSRange? {
        guard !currentMatches.isEmpty else { return nil }
        currentMatchIndex = (currentMatchIndex - 1 + currentMatches.count) % currentMatches.count
        highlightAllMatches()
        scrollToCurrentMatch()
        return currentMatches[currentMatchIndex]
    }
    
    public func clearFind() {
        clearHighlightAttributes()
        currentMatches.removeAll()
        currentMatchIndex = -1
    }
    
    private func highlightAllMatches() {
        guard let layoutManager = self.layoutManager, let storage = self.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        let palette = AppSettings.shared.themePreset.palette
        let matchBg = NSColor(hex: palette.selection) ?? .selectedTextBackgroundColor
        let currentBg = NSColor(hex: palette.accent) ?? .selectedTextBackgroundColor
        let currentForeground = NSColor(hex: ThemePalette.contrast("#FFFFFF", palette.accent) >= 4.5 ? "#FFFFFF" : "#000000") ?? .labelColor
        
        for (index, range) in currentMatches.enumerated() {
            guard range.location + range.length <= storage.length else { continue }
            let color = (index == currentMatchIndex) ? currentBg : matchBg
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            layoutManager.addTemporaryAttribute(.foregroundColor, value: index == currentMatchIndex ? currentForeground : (NSColor(hex: palette.foreground) ?? .labelColor), forCharacterRange: range)
        }
    }
    
    private func clearHighlightAttributes() {
        guard let layoutManager = self.layoutManager, let storage = self.textStorage, storage.length > 0 else { return }
        let range = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
    }
    
    private func scrollToCurrentMatch() {
        guard currentMatchIndex >= 0 && currentMatchIndex < currentMatches.count else { return }
        let range = currentMatches[currentMatchIndex]
        self.scrollRangeToVisible(range)
    }
    
    // MARK: - URL Detection & Cmd+Click Support
    
    public struct DetectedURLMatch: Equatable, Sendable {
        public let url: URL
        public let range: NSRange
        public let originalString: String
        
        public init(url: URL, range: NSRange, originalString: String) {
            self.url = url
            self.range = range
            self.originalString = originalString
        }
    }
    
    public nonisolated static func detectURLs(in text: String) -> [DetectedURLMatch] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let nsText = text as NSString
        let rawMatches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        
        var results: [DetectedURLMatch] = []
        let trailingPunctuation = CharacterSet(charactersIn: ".,;:)]}>'\"")
        
        for match in rawMatches {
            guard let url = match.url else { continue }
            var range = match.range
            var matchStr = nsText.substring(with: range)
            
            while let last = matchStr.unicodeScalars.last, trailingPunctuation.contains(last) {
                matchStr.removeLast()
                range.length -= 1
            }
            
            if let cleanURL = URL(string: matchStr), (cleanURL.scheme == "http" || cleanURL.scheme == "https" || cleanURL.scheme == "ssh" || cleanURL.scheme == "ftp") {
                results.append(DetectedURLMatch(url: cleanURL, range: range, originalString: matchStr))
            } else if let validScheme = url.scheme, validScheme == "http" || validScheme == "https" {
                results.append(DetectedURLMatch(url: url, range: range, originalString: matchStr))
            }
        }
        return results
    }
    
    public func urlAtPoint(_ point: NSPoint) -> URL? {
        guard let storage = self.textStorage, storage.length > 0,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return nil }
        
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { return nil }
        
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard lineRect.insetBy(dx: -4, dy: -4).contains(containerPoint) else { return nil }
        
        let text = storage.string as NSString
        let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
        let lineText = text.substring(with: lineRange)
        
        let matches = Self.detectURLs(in: lineText)
        for match in matches {
            let globalRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
            if NSLocationInRange(charIndex, globalRange) {
                return match.url
            }
        }
        return nil
    }
    
    public func getSelectedURL() -> URL? {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage, range.location + range.length <= storage.length else { return nil }
        let str = (storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: str), url.scheme == "http" || url.scheme == "https" {
            return url
        }
        return nil
    }
    
    private var trackingArea: NSTrackingArea?
    
    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea {
            removeTrackingArea(old)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    
    override public func mouseMoved(with event: NSEvent) {
        if ringBuffer?.mouseTrackingMode == 1003, sendMouseReport(event, button: 35) { return }
        super.mouseMoved(with: event)
        updateCursorForEvent(event)
    }
    
    override public func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCursorForEvent(event)
    }
    
    private func updateCursorForEvent(_ event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let pt = convert(event.locationInWindow, from: nil)
            if urlAtPoint(pt) != nil {
                NSCursor.pointingHand.set()
                return
            }
        }
        NSCursor.iBeam.set()
    }
    
    override public func cursorUpdate(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let pt = convert(event.locationInWindow, from: nil)
            if urlAtPoint(pt) != nil {
                NSCursor.pointingHand.set()
                return
            }
        }
        super.cursorUpdate(with: event)
    }
    
    /// Shift temporarily restores local selection while an application owns the mouse.
    private func mouseReport(_ event: NSEvent, button: Int, release: Bool = false) -> Data? {
        guard let buffer = ringBuffer, buffer.mouseTrackingMode != 0,
              !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let font = cachedBaseFont
        let width = max(6, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let height = max(12, layoutManager?.defaultLineHeight(for: font) ?? 16)
        let dimensions = buffer.dimensions
        let column = min(dimensions.columns, max(1, Int(floor((point.x - textContainerOrigin.x) / width)) + 1))
        let row = min(dimensions.rows, max(1, Int(floor((point.y - textContainerOrigin.y) / height)) + 1))
        let modifiers = (event.modifierFlags.contains(.option) ? 8 : 0) + (event.modifierFlags.contains(.control) ? 16 : 0)
        let code = button + modifiers
        if buffer.isSGRMouseEnabled {
            return Data("\u{1B}[<\(code);\(column);\(row)\(release ? "m" : "M")".utf8)
        }
        return Data([0x1B, 0x5B, 0x4D, UInt8((release ? 3 + modifiers : code) + 32), UInt8(min(column, 223) + 32), UInt8(min(row, 223) + 32)])
    }

    private func sendMouseReport(_ event: NSEvent, button: Int, release: Bool = false) -> Bool {
        guard let report = mouseReport(event, button: button, release: release) else { return false }
        onInput?(report)
        return true
    }

    override public func mouseDragged(with event: NSEvent) {
        if let buffer = ringBuffer, buffer.mouseTrackingMode != 0,
           !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
            if buffer.mouseTrackingMode != 1000 { _ = sendMouseReport(event, button: 32) }
            return
        }
        super.mouseDragged(with: event)
    }

    override public func rightMouseUp(with event: NSEvent) {
        if sendMouseReport(event, button: 2, release: true) { return }
        super.rightMouseUp(with: event)
    }

    override public func rightMouseDragged(with event: NSEvent) {
        if let buffer = ringBuffer, buffer.mouseTrackingMode != 0,
           !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
            if buffer.mouseTrackingMode != 1000 { _ = sendMouseReport(event, button: 34) }
            return
        }
        super.rightMouseDragged(with: event)
    }

    override public func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2, sendMouseReport(event, button: 1) { return }
        super.otherMouseDown(with: event)
    }

    override public func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, sendMouseReport(event, button: 1, release: true) { return }
        super.otherMouseUp(with: event)
    }

    override public func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2, let buffer = ringBuffer, buffer.mouseTrackingMode != 0,
           !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
            if buffer.mouseTrackingMode != 1000 { _ = sendMouseReport(event, button: 33) }
            return
        }
        super.otherMouseDragged(with: event)
    }

    override public func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
        onFocus?()
        
        if sendMouseReport(event, button: 0) { return }
        if event.modifierFlags.contains(.command) {
            let pt = convert(event.locationInWindow, from: nil)
            if let url = urlAtPoint(pt) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        super.mouseDown(with: event)
    }
    
    override public func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag && isCopyOnSelectEnabled {
            copySelectionToPasteboardIfAny()
        }
    }
    
    override public func mouseUp(with event: NSEvent) {
        if sendMouseReport(event, button: 0, release: true) { return }
        super.mouseUp(with: event)
        if isCopyOnSelectEnabled {
            copySelectionToPasteboardIfAny()
        }
    }
    
    override public func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > 0.1,
           sendMouseReport(event, button: event.scrollingDeltaY > 0 ? 64 : 65) { return }
        if let buffer = ringBuffer, buffer.isInAlternateScreen {
            // When in alternate screen mode (e.g. Vim, less, htop), scrolling trackpad/mouse
            // should send Up/Down arrow sequences to navigate the document instead of scrolling the clipview
            let deltaY = event.scrollingDeltaY
            if abs(deltaY) > 0.1 {
                let isUp = deltaY > 0
                let count = max(1, min(5, Int(abs(deltaY) / 4.0)))
                let isApp = buffer.isApplicationCursorKeys
                let seq = isUp ? (isApp ? "\u{1B}OA" : "\u{1B}[A") : (isApp ? "\u{1B}OB" : "\u{1B}[B")
                var fullSeq = ""
                for _ in 0..<count { fullSeq.append(seq) }
                if let data = fullSeq.data(using: .utf8) {
                    onInput?(data)
                }
            }
            return
        }
        super.scrollWheel(with: event)
    }
    
    override public func rightMouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
        onFocus?()
        if sendMouseReport(event, button: 2) { return }
        
        // If Shift is pressed or right-click paste is disabled in settings, allow standard context menu popup
        if event.modifierFlags.contains(.shift) || !AppSettings.shared.isRightClickPasteEnabled {
            super.rightMouseDown(with: event)
            return
        }
        
        // PuTTY / Xshell / SecureCRT style: Right-Click directly pastes from clipboard
        _ = pasteFromClipboard()
        // Clear text selection after pasting so terminal view stays clean
        if let len = self.textStorage?.length {
            self.setSelectedRange(NSRange(location: len, length: 0))
        }
    }
    
    // Provide active text input context for macOS Chinese / Japanese IME
    override public var inputContext: NSTextInputContext? {
        if customInputContext == nil {
            customInputContext = NSTextInputContext(client: self)
        }
        return customInputContext
    }
    
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if window?.firstResponder === self,
           modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "v" {
            _ = pasteFromClipboard()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override public func keyDown(with event: NSEvent) {
        if ringBuffer?.isInAlternateScreen != true {
            self.isPinnedToBottom = true
        }
        
        // Preserve the system full-screen shortcut while terminal input has focus.
        let shortcutModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if shortcutModifiers == [.command, .control],
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            window?.toggleFullScreen(nil)
            return
        }

        // 0. Handle Cmd shortcuts: Cmd+K (Clear), Cmd+F (Find), Cmd+G (Next Match), Cmd+Shift+G (Prev Match)
        if event.modifierFlags.contains(.command) {
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                if shortcutModifiers == [.command] || shortcutModifiers == [.command, .shift] {
                    if chars == "+" || chars == "=" {
                        AppSettings.shared.fontSize = min(22, AppSettings.shared.fontSize + 1)
                        return
                    }
                    if chars == "-" {
                        AppSettings.shared.fontSize = max(10, AppSettings.shared.fontSize - 1)
                        return
                    }
                    if shortcutModifiers == [.command] && chars == "0" {
                        AppSettings.shared.fontSize = 13
                        return
                    }
                }
                if shortcutModifiers == [.command] && chars == "c" {
                    copySelectionToPasteboardIfAny()
                    return
                }
                if shortcutModifiers == [.command] && chars == "a" {
                    selectAll(nil)
                    return
                }
                if shortcutModifiers == [.command] && chars == "v" {
                    _ = pasteFromClipboard()
                    return
                }
                if !event.modifierFlags.contains(.shift) && chars == "k" {
                    clearScreen()
                    return
                } else if !event.modifierFlags.contains(.shift) && chars == "f" {
                    (self.enclosingScrollView as? NativeTerminalScrollView)?.showFindBar()
                    return
                } else if chars == "g" {
                    let sv = self.enclosingScrollView as? NativeTerminalScrollView
                    if event.modifierFlags.contains(.shift) {
                        _ = findPrevious()
                    } else {
                        _ = findNext()
                    }
                    sv?.searchBarOverlay.updateMatchLabel()
                    return
                }
            }
            // Unhandled application shortcuts must never become Vim editing commands.
            super.keyDown(with: event)
            return
        }
        
        // 1. Handle Ctrl key combinations: Ctrl+C, Ctrl+D, Ctrl+Z, Ctrl+L, etc. (HIGHEST PRIORITY)
        if event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers,
           let firstChar = chars.unicodeScalars.first {
            let val = firstChar.value
            if val >= 65 && val <= 90 { // A-Z
                let ctrlByte = UInt8(val - 64)
                onInput?(Data([ctrlByte]))
                return
            } else if val >= 97 && val <= 122 { // a-z
                let ctrlByte = UInt8(val - 96)
                onInput?(Data([ctrlByte]))
                return
            }
        }
        
        // 2. Handle Escape key with priority: if composing IME text, discard and cancel without sending to shell
        if event.keyCode == 53 { // ESC
            let hadMarked = hasMarkedText()
            if hadMarked {
                inputContext?.discardMarkedText()
                unmarkText()
            }
            if let sv = self.enclosingScrollView as? NativeTerminalScrollView, !sv.searchBarOverlay.isHidden {
                sv.hideFindBar()
                return
            }
            // In alternate screen buffer (Vim, less, nano), ALWAYS pass ESC to remote shell
            // even if marked text was just discarded so user reliably exits insert/command mode.
            if ringBuffer?.isInAlternateScreen == true || !hadMarked {
                onInput?("\u{1B}".data(using: .utf8)!)
            }
            return
        }
        
        // Option/Alt navigation (Meta key behavior for bash/zsh/fish)
        if event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
            switch event.keyCode {
            case 123: // Option + Left arrow -> Meta-b (word backward)
                onInput?("\u{1B}b".data(using: .utf8)!)
                return
            case 124: // Option + Right arrow -> Meta-f (word forward)
                onInput?("\u{1B}f".data(using: .utf8)!)
                return
            case 126: // Option + Up arrow
                onInput?("\u{1B}[1;3A".data(using: .utf8)!)
                return
            case 125: // Option + Down arrow
                onInput?("\u{1B}[1;3B".data(using: .utf8)!)
                return
            case 51: // Option + Backspace -> Meta-DEL (delete word backward)
                onInput?("\u{1B}\u{7F}".data(using: .utf8)!)
                return
            case 117: // Option + Forward Delete -> Meta-d (delete word forward)
                onInput?("\u{1B}d".data(using: .utf8)!)
                return
            default:
                if let chars = event.charactersIgnoringModifiers?.lowercased(), let first = chars.first, first.isASCII {
                    onInput?("\u{1B}\(first)".data(using: .utf8)!)
                    return
                }
            }
        }

        // Handle Special keys by key code when not composing marked IME text
        if !hasMarkedText() {
            let isAppCursor = ringBuffer?.isApplicationCursorKeys == true
            switch event.keyCode {
            case 36, 76: // Return / Enter / Numpad Enter
                onInput?("\r".data(using: .utf8)!)
                return
            case 51: // Backspace / Delete
                onInput?("\u{7F}".data(using: .utf8)!)
                return
            case 117: // Forward Delete
                onInput?("\u{1B}[3~".data(using: .utf8)!)
                return
            case 48: // Tab
                if event.modifierFlags.contains(.shift) {
                    onInput?("\u{1B}[Z".data(using: .utf8)!) // Back-tab
                } else {
                    onInput?("\t".data(using: .utf8)!)
                }
                return
            case 126: // Up arrow
                if event.modifierFlags.contains(.shift) { onInput?("\u{1B}[1;2A".data(using: .utf8)!); return }
                if event.modifierFlags.contains(.control) { onInput?("\u{1B}[1;5A".data(using: .utf8)!); return }
                onInput?((isAppCursor ? "\u{1B}OA" : "\u{1B}[A").data(using: .utf8)!)
                return
            case 125: // Down arrow
                if event.modifierFlags.contains(.shift) { onInput?("\u{1B}[1;2B".data(using: .utf8)!); return }
                if event.modifierFlags.contains(.control) { onInput?("\u{1B}[1;5B".data(using: .utf8)!); return }
                onInput?((isAppCursor ? "\u{1B}OB" : "\u{1B}[B").data(using: .utf8)!)
                return
            case 124: // Right arrow
                if event.modifierFlags.contains(.shift) { onInput?("\u{1B}[1;2C".data(using: .utf8)!); return }
                if event.modifierFlags.contains(.control) { onInput?("\u{1B}[1;5C".data(using: .utf8)!); return }
                onInput?((isAppCursor ? "\u{1B}OC" : "\u{1B}[C").data(using: .utf8)!)
                return
            case 123: // Left arrow
                if event.modifierFlags.contains(.shift) { onInput?("\u{1B}[1;2D".data(using: .utf8)!); return }
                if event.modifierFlags.contains(.control) { onInput?("\u{1B}[1;5D".data(using: .utf8)!); return }
                onInput?((isAppCursor ? "\u{1B}OD" : "\u{1B}[D").data(using: .utf8)!)
                return
            case 115: // Home
                onInput?((isAppCursor ? "\u{1B}OH" : "\u{1B}[H").data(using: .utf8)!)
                return
            case 119: // End
                onInput?((isAppCursor ? "\u{1B}OF" : "\u{1B}[F").data(using: .utf8)!)
                return
            case 116: // Page Up
                onInput?("\u{1B}[5~".data(using: .utf8)!)
                return
            case 121: // Page Down
                onInput?("\u{1B}[6~".data(using: .utf8)!)
                return
            // Function Keys F1 - F12
            case 122: // F1
                onInput?("\u{1B}OP".data(using: .utf8)!)
                return
            case 120: // F2
                onInput?("\u{1B}OQ".data(using: .utf8)!)
                return
            case 99: // F3
                onInput?("\u{1B}OR".data(using: .utf8)!)
                return
            case 118: // F4
                onInput?("\u{1B}OS".data(using: .utf8)!)
                return
            case 96: // F5
                onInput?("\u{1B}[15~".data(using: .utf8)!)
                return
            case 97: // F6
                onInput?("\u{1B}[17~".data(using: .utf8)!)
                return
            case 98: // F7
                onInput?("\u{1B}[18~".data(using: .utf8)!)
                return
            case 100: // F8
                onInput?("\u{1B}[19~".data(using: .utf8)!)
                return
            case 101: // F9
                onInput?("\u{1B}[20~".data(using: .utf8)!)
                return
            case 109: // F10
                onInput?("\u{1B}[21~".data(using: .utf8)!)
                return
            case 103: // F11
                onInput?("\u{1B}[23~".data(using: .utf8)!)
                return
            case 111: // F12
                onInput?("\u{1B}[24~".data(using: .utf8)!)
                return
            default:
                break
            }
        }
        
        // 3. If macOS IME (e.g. Chinese Pinyin) is active and handles the event
        if let inputContext = self.inputContext, inputContext.handleEvent(event) {
            return
        }
        
        // 4. Standard character typing: letters, numbers, symbols, space
        if let chars = event.characters, !chars.isEmpty {
            if let data = chars.data(using: .utf8) {
                onInput?(data)
                return
            }
        }
        
        // 5. Fallback to interpretKeyEvents
        self.interpretKeyEvents([event])
    }
    
    // Paste support (Cmd+V and Right-Click direct paste, with Bracketed Paste Mode support)
    @discardableResult
    public func pasteFromClipboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        let isAltScreen = ringBuffer?.isInAlternateScreen == true
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let toSend: String
        if ringBuffer?.isBracketedPasteEnabled == true {
            let pasteContent = normalized.replacingOccurrences(of: "\n", with: "\r")
            toSend = "\u{1B}[200~" + pasteContent + "\u{1B}[201~"
        } else {
            toSend = normalized.replacingOccurrences(of: "\n", with: "\r")
        }
        guard let data = toSend.data(using: .utf8) else { return false }
        self.isPinnedToBottom = !isAltScreen
        onInput?(data)
        return true
    }
    
    override public func paste(_ sender: Any?) {
        pasteFromClipboard()
    }
    
    // MARK: - Copy on Select & Right-Click Context Menu
    
    @discardableResult
    public func copySelectionToPasteboardIfAny() -> Bool {
        let range = self.selectedRange()
        guard range.length > 0, let storage = self.textStorage else { return false }
        if range.location + range.length <= storage.length {
            let selectedText = (storage.string as NSString).substring(with: range)
            if !selectedText.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(selectedText, forType: .string)
                return true
            }
        }
        return false
    }
    
    @objc override public func copy(_ sender: Any?) {
        copySelectionToPasteboardIfAny()
    }
    
    override public func menu(for event: NSEvent) -> NSMenu? {
        // If there is an active selection, ensure it is copied
        copySelectionToPasteboardIfAny()
        
        let menu = NSMenu(title: "Terminal")
        let hasSelection = self.selectedRange().length > 0
        let pt = convert(event.locationInWindow, from: nil)
        
        // Check if clicked or selected a URL
        if let clickedURL = urlAtPoint(pt) {
            let shortURL = clickedURL.absoluteString.count > 30 ? String(clickedURL.absoluteString.prefix(28)) + "..." : clickedURL.absoluteString
            let urlItem = NSMenuItem(title: "在浏览器中打开链接 (\(shortURL))", action: #selector(openURLAction(_:)), keyEquivalent: "")
            urlItem.target = self
            urlItem.representedObject = clickedURL
            menu.addItem(urlItem)
            menu.addItem(NSMenuItem.separator())
        } else if let selectedURL = getSelectedURL() {
            let shortURL = selectedURL.absoluteString.count > 30 ? String(selectedURL.absoluteString.prefix(28)) + "..." : selectedURL.absoluteString
            let urlItem = NSMenuItem(title: "在浏览器中打开链接 (\(shortURL))", action: #selector(openURLAction(_:)), keyEquivalent: "")
            urlItem.target = self
            urlItem.representedObject = selectedURL
            menu.addItem(urlItem)
            menu.addItem(NSMenuItem.separator())
        }
        
        // 1. 复制 (Copy)
        let copyItem = NSMenuItem(title: "复制 (Copy)", action: #selector(copyMenuAction(_:)), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = hasSelection
        menu.addItem(copyItem)
        
        // 2. 粘贴 (Paste)
        let hasPasteboard = NSPasteboard.general.string(forType: .string) != nil
        let pasteItem = NSMenuItem(title: "粘贴 (Paste)", action: #selector(pasteMenuAction(_:)), keyEquivalent: "v")
        pasteItem.target = self
        pasteItem.isEnabled = hasPasteboard
        menu.addItem(pasteItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. 查找 (Find)
        let findItem = NSMenuItem(title: "查找 (Find)...", action: #selector(findMenuAction(_:)), keyEquivalent: "f")
        findItem.target = self
        menu.addItem(findItem)
        
        // 4. 全选 (Select All)
        let selectAllItem = NSMenuItem(title: "全选 (Select All)", action: #selector(selectAllMenuAction(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        
        // 5. 清屏 (Clear Screen)
        let clearItem = NSMenuItem(title: "清屏 (Clear Screen)", action: #selector(clearScreenMenuAction(_:)), keyEquivalent: "k")
        clearItem.target = self
        menu.addItem(clearItem)
        
        return menu
    }
    
    @objc private func openURLAction(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func findMenuAction(_ sender: Any?) {
        (self.enclosingScrollView as? NativeTerminalScrollView)?.showFindBar()
    }
    
    @objc private func copyMenuAction(_ sender: Any?) {
        copySelectionToPasteboardIfAny()
    }
    
    @objc private func pasteMenuAction(_ sender: Any?) {
        self.paste(sender)
    }
    
    @objc override public func selectAll(_ sender: Any?) {
        selectAllMenuAction(sender)
    }
    
    @objc private func selectAllMenuAction(_ sender: Any?) {
        if let storage = self.textStorage, storage.length > 0 {
            self.setSelectedRange(NSRange(location: 0, length: storage.length))
            if isCopyOnSelectEnabled {
                copySelectionToPasteboardIfAny()
            }
        }
    }
    
    public func clearScreen() {
        ringBuffer?.clear()
        self.textStorage?.setAttributedString(NSAttributedString())
        self.activeLineStartLocation = 0
        self.lastCommittedIndex = 0
        self.needsDisplay = true
        self.scrollToBottom()
        onInput?(Data([0x0C])) // Send Ctrl+L (FF) to remote shell to redraw prompt at top
    }
    
    @objc private func clearScreenMenuAction(_ sender: Any?) {
        clearScreen()
    }
    
    // MARK: - NSTextInputClient / Text Input Overrides
    
    /// Called when user commits a Chinese candidate word or types standard text
    override public func insertText(_ string: Any, replacementRange: NSRange) {
        if ringBuffer?.isInAlternateScreen != true {
            self.isPinnedToBottom = true
        }
        var text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }
        
        currentMarkedText = ""
        currentMarkedRange = NSRange(location: NSNotFound, length: 0)
        needsDisplay = true
        
        if !text.isEmpty {
            // Normalize full-width symbols commonly entered by Chinese/CJK input methods that break terminal commands and Vim
            text = text.replacingOccurrences(of: "：", with: ":")
                       .replacingOccurrences(of: "；", with: ";")
            text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
            if let data = text.data(using: .utf8) {
                onInput?(data)
            }
        }
        resetCursorBlink()
    }
    
    override public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            text = ""
        }
        self.currentMarkedText = text
        let length = text.utf16.count
        let location = min(length, selectedRange.location == NSNotFound ? length : selectedRange.location)
        self.currentMarkedRange = NSRange(location: location, length: min(selectedRange.length, length - location))
        self.needsDisplay = true
        resetCursorBlink()
    }
    
    override public func unmarkText() {
        self.currentMarkedText = ""
        self.currentMarkedRange = NSRange(location: NSNotFound, length: 0)
        self.needsDisplay = true
        resetCursorBlink()
    }
    
    override public func hasMarkedText() -> Bool {
        return !currentMarkedText.isEmpty
    }
    
    override public func markedRange() -> NSRange {
        if currentMarkedText.isEmpty {
            return NSRange(location: NSNotFound, length: 0)
        }
        let total = textStorage?.length ?? 0
        return NSRange(location: total, length: currentMarkedText.utf16.count)
    }
    
    override public func selectedRange() -> NSRange {
        guard hasMarkedText() else { return super.selectedRange() }
        return NSRange(location: markedRange().location + currentMarkedRange.location,
                       length: currentMarkedRange.length)
    }

    override public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard hasMarkedText() else {
            return super.attributedSubstring(forProposedRange: range, actualRange: actualRange)
        }
        guard range.location != NSNotFound else { return nil }
        let virtualText = NSMutableAttributedString(attributedString: textStorage ?? NSAttributedString(string: ""))
        virtualText.append(NSAttributedString(string: currentMarkedText))
        guard range.location <= virtualText.length else { return nil }
        let available = NSRange(location: range.location, length: min(range.length, virtualText.length - range.location))
        actualRange?.pointee = available
        return virtualText.attributedSubstring(from: available)
    }

    override public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = hasMarkedText() ? markedRange() : NSRange(location: textStorage?.length ?? 0, length: 0)
        let rect = compositionRect()
        let windowRect = convert(rect, to: nil)
        return window?.convertToScreen(windowRect) ?? .zero
    }

    // Command selectors from interpretKeyEvents & NSTextInputClient
    override public func doCommand(by selector: Selector) {
        resetCursorBlink()
        switch selector {
        case #selector(insertNewline(_:)):
            onInput?("\r".data(using: .utf8)!)
        case #selector(deleteBackward(_:)):
            onInput?("\u{7F}".data(using: .utf8)!)
        case #selector(deleteForward(_:)):
            onInput?("\u{1B}[3~".data(using: .utf8)!)
        case #selector(insertTab(_:)):
            onInput?("\t".data(using: .utf8)!)
        case #selector(cancelOperation(_:)):
            if hasMarkedText() {
                inputContext?.discardMarkedText()
                unmarkText()
                return
            }
            onInput?("\u{1B}".data(using: .utf8)!)
        case #selector(moveUp(_:)):
            onInput?((ringBuffer?.isApplicationCursorKeys == true ? "\u{1B}OA" : "\u{1B}[A").data(using: .utf8)!)
        case #selector(moveDown(_:)):
            onInput?((ringBuffer?.isApplicationCursorKeys == true ? "\u{1B}OB" : "\u{1B}[B").data(using: .utf8)!)
        case #selector(moveLeft(_:)):
            onInput?((ringBuffer?.isApplicationCursorKeys == true ? "\u{1B}OD" : "\u{1B}[D").data(using: .utf8)!)
        case #selector(moveRight(_:)):
            onInput?((ringBuffer?.isApplicationCursorKeys == true ? "\u{1B}OC" : "\u{1B}[C").data(using: .utf8)!)
        default:
            super.doCommand(by: selector)
        }
    }
    
    override public func insertNewline(_ sender: Any?) {
        resetCursorBlink()
        onInput?("\r".data(using: .utf8)!)
    }
    
    override public func deleteBackward(_ sender: Any?) {
        resetCursorBlink()
        onInput?("\u{7F}".data(using: .utf8)!)
    }
    
    override public func insertTab(_ sender: Any?) {
        resetCursorBlink()
        onInput?("\t".data(using: .utf8)!)
    }
    
    override public func cancelOperation(_ sender: Any?) {
        resetCursorBlink()
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
            return
        }
        onInput?("\u{1B}".data(using: .utf8)!)
    }
    
    // MARK: - Incremental 120Hz Rendering (No Full Redraws)
    
    public func formatANSI(_ text: String) -> NSAttributedString {
        let spans = parser.parseANSI(text)
        let attrString = NSMutableAttributedString()
        
        // NSTextView.font can become a fallback font after Chinese/emoji output.
        // All terminal cells must retain the configured monospaced grid.
        let baseFont = cachedBaseFont
        let boldFont = self.cachedBoldFont
        let palette = AppSettings.shared.themePreset.palette
        let defaultColor = NSColor(hex: palette.foreground) ?? .labelColor
        
        for span in spans {
            var textColor = defaultColor
            if let hex = span.foregroundColorHex {
                Self.colorCacheLock.lock()
                if let cached = Self.colorCache[hex] {
                    textColor = cached
                    Self.colorCacheLock.unlock()
                } else {
                    Self.colorCacheLock.unlock()
                    if let parsed = NSColor(hex: hex) {
                        Self.colorCacheLock.lock()
                        Self.colorCache[hex] = parsed
                        Self.colorCacheLock.unlock()
                        textColor = parsed
                    }
                }
            }
            if let index = span.ansiColorIndex {
                textColor = NSColor(hex: palette.terminalColor(at: index)) ?? defaultColor
            }
            var renderFont = span.isBold ? boldFont : baseFont
            if span.isItalic { renderFont = NSFontManager.shared.convert(renderFont, toHaveTrait: .italicFontMask) }
            var background = span.backgroundColorHex.flatMap(NSColor.init(hex:))
            if let index = span.backgroundANSIColorIndex { background = NSColor(hex: palette.terminalColor(at: index)) }
            if span.isInverse {
                let originalForeground = textColor
                textColor = background ?? NSColor(hex: AppSettings.shared.themePreset.backgroundColorHex) ?? self.backgroundColor
                background = originalForeground
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: renderFont, .foregroundColor: textColor, .ligature: 0, .kern: 0]
            if let background { attrs[.backgroundColor] = background }
            if span.isUnderlined { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if span.isStrikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attrs[NSAttributedString.Key("ApexThemeColor")] = span.isInverse
                ? (span.backgroundANSIColorIndex ?? (span.backgroundColorHex == nil ? -3 : -2))
                : (span.ansiColorIndex ?? (span.foregroundColorHex == nil ? -1 : -2))
            if background != nil {
                attrs[NSAttributedString.Key("ApexThemeBackground")] = span.isInverse
                    ? (span.ansiColorIndex ?? (span.foregroundColorHex == nil ? -1 : -2))
                    : (span.backgroundANSIColorIndex ?? -2)
            }
            let run = NSMutableAttributedString(string: span.text, attributes: attrs)
            if !span.text.utf8.allSatisfy({ $0 < 128 }) {
                let columnWidth = max(6, ("M" as NSString).size(withAttributes: [.font: baseFont]).width)
                var offset = 0
                for character in span.text {
                    let grapheme = String(character)
                    let length = grapheme.utf16.count
                    if character != "\n" && character != "\r" && !grapheme.utf8.allSatisfy({ $0 < 128 }) {
                        let key = "\(renderFont.fontName):\(renderFont.pointSize):\(grapheme)"
                        let advance: CGFloat
                        if let cached = glyphAdvanceCache[key] { advance = cached }
                        else {
                            let line = CTLineCreateWithAttributedString(NSAttributedString(string: grapheme, attributes: [.font: renderFont, .ligature: 0, .kern: 0]))
                            advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                            if glyphAdvanceCache.count < 4096 { glyphAdvanceCache[key] = advance }
                        }
                        let target = CGFloat(TerminalCharacterWidth.columns(character)) * columnWidth
                        run.addAttribute(.kern, value: target - advance, range: NSRange(location: offset, length: length))
                    }
                    offset += length
                }
            }
            attrString.append(run)
        }
        for match in keywordHighlighter.findMatches(in: attrString.string) {
            guard let color = NSColor(hex: match.colorHex) else { continue }
            attrString.addAttribute(.foregroundColor, value: color, range: match.range)
            // Keep explicit trigger colors when the theme recolors ANSI runs.
            attrString.addAttribute(NSAttributedString.Key("ApexThemeColor"), value: -2, range: match.range)
        }
        return attrString
    }
    
    public func appendRawOutput(_ text: String) {
        let attr = formatANSI(text)
        self.textStorage?.append(attr)
        if self.isPinnedToBottom {
            self.scrollToBottom(forceLayout: false)
        }
    }
    
    /// Incremental refresh: updates active line in-place and appends newly committed lines
    public func refresh() {
        guard let buffer = ringBuffer else { return }

        if let screenLines = buffer.screenLines {
            let lineHeight = layoutManager?.defaultLineHeight(for: cachedBaseFont) ?? 16
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            let rows = screenLines.enumerated().map { index, line -> NSAttributedString in
                let row = NSMutableAttributedString(attributedString: formatANSI(line))
                if index < screenLines.count - 1 { row.append(formatANSI("\n")) }
                row.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: row.length))
                return row
            }
            if let storage = textStorage {
                storage.beginEditing()
                if let previous = renderedScreenRows, previous.count == rows.count,
                   previous.reduce(0, { $0 + $1.length }) == storage.length {
                    var offset = storage.length
                    for index in rows.indices.reversed() {
                        offset -= previous[index].length
                        if !previous[index].isEqual(to: rows[index]) {
                            storage.replaceCharacters(in: NSRange(location: offset, length: previous[index].length), with: rows[index])
                        }
                    }
                } else {
                    let rendered = NSMutableAttributedString()
                    for row in rows { rendered.append(row) }
                    storage.setAttributedString(rendered)
                }
                storage.endEditing()
                renderedScreenRows = rows
            }
            activeLineStartLocation = self.textStorage?.length ?? 0
            lastCommittedIndex = buffer.totalCommittedCount
            isPinnedToBottom = false
            self.frame.origin = .zero
            if let clipView = self.enclosingScrollView?.contentView {
                if clipView.bounds.origin != .zero {
                    clipView.bounds.origin = .zero
                    clipView.scroll(to: .zero)
                    self.enclosingScrollView?.reflectScrolledClipView(clipView)
                }
            }
            self.needsDisplay = true
            resetCursorBlink()
            return
        }
        
        renderedScreenRows = nil
        let currentTotal = buffer.totalCommittedCount
        let isCleared = buffer.consumeClearFlag() || (currentTotal < lastCommittedIndex)
        let active = buffer.currentActiveLine
        if !isCleared, currentTotal == lastCommittedIndex, active == renderedActiveLine {
            // Cursor/control-only packets do not invalidate the entire scrollback layout.
            self.needsDisplay = true
            self.resetCursorBlink()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Active-line replacement, appended history and eviction form one edit.
        // Avoid repeated TextKit layout and document resizing for each packet.
        textStorage?.beginEditing()
        
        // 1. Buffer cleared or initial render
        if isCleared {
            lastCommittedIndex = 0
            self.textStorage?.setAttributedString(NSAttributedString())
            activeLineStartLocation = 0
        }
        
        // 2. Remove previously drawn active line (if any)
        if let storage = self.textStorage, storage.length > activeLineStartLocation {
            let activeRange = NSRange(location: activeLineStartLocation, length: storage.length - activeLineStartLocation)
            storage.deleteCharacters(in: activeRange)
        }
        
        // 3. Append newly committed lines using tailLines
        let hasNewCommittedLines = (currentTotal > lastCommittedIndex)
        if hasNewCommittedLines {
            let delta = Int(currentTotal - lastCommittedIndex)
            lastCommittedIndex = currentTotal
            if delta > 0 {
                let countToFetch = min(delta, buffer.maxLines)
                let newLines = buffer.tailLines(count: countToFetch)
                if !newLines.isEmpty {
                    let joined = newLines.joined(separator: "\n") + "\n"
                    let attr = formatANSI(joined)
                    self.textStorage?.append(attr)
                    renderedCommittedLineLengths.append(contentsOf: attr.string.components(separatedBy: "\n").dropLast().map { $0.utf16.count + 1 })
                }
            }

            // Evict complete rendered lines along with the buffer and keep UTF-16 boundaries intact.
            if let storage = textStorage {
                let lineLimit = buffer.maxLines
                let characterLimit = storage.length > 2_500_000 ? 1_500_000 : Int.max
                var removedCharacters = 0
                while renderedLineHead < renderedCommittedLineLengths.count &&
                      (renderedCommittedLineLengths.count - renderedLineHead > lineLimit || storage.length - removedCharacters > characterLimit) {
                    removedCharacters += renderedCommittedLineLengths[renderedLineHead]
                    renderedLineHead += 1
                }
                if removedCharacters > 0 {
                    storage.deleteCharacters(in: NSRange(location: 0, length: min(removedCharacters, storage.length)))
                }
                if renderedLineHead > 4096 && renderedLineHead * 2 > renderedCommittedLineLengths.count {
                    renderedCommittedLineLengths.removeFirst(renderedLineHead)
                    renderedLineHead = 0
                }
            }
            activeLineStartLocation = self.textStorage?.length ?? 0
        }
        
        // 4. Render current active line at the bottom
        if !active.isEmpty {
            let attr = formatANSI(active)
            self.textStorage?.append(attr)
        }
        
        renderedActiveLine = active
        textStorage?.endEditing()
        CATransaction.commit()
        
        if self.isPinnedToBottom && (hasNewCommittedLines || isCleared || !self.isScrolledToBottom()) {
            // NSTextView may not have resized its document frame for the appended lines yet.
            self.scrollToBottom(forceLayout: true)
        }
        self.resetCursorBlink()
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") { clean.removeFirst() }
        guard clean.count == 6, let rgb = UInt64(clean, radix: 16) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
