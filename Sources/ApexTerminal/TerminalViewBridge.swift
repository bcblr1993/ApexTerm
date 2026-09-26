import SwiftUI
import AppKit
import ApexCore

/// High-performance native AppKit Terminal View wrapper for SwiftUI with 120Hz ProMotion support
public struct TerminalRepresentable: NSViewRepresentable {
    public let ringBuffer: TerminalRingBuffer
    public var isFocused: Bool = false
    public var onFocus: (() -> Void)? = nil
    public var isCopyOnSelectEnabled: Bool = true
    public var onResize: ((Int, Int) -> Void)? = nil
    public var onFileDrop: ((URL) -> Void)? = nil
    public let onInput: (Data) -> Void
    
    public init(
        ringBuffer: TerminalRingBuffer,
        isFocused: Bool = false,
        onFocus: (() -> Void)? = nil,
        isCopyOnSelectEnabled: Bool = true,
        onResize: ((Int, Int) -> Void)? = nil,
        onFileDrop: ((URL) -> Void)? = nil,
        onInput: @escaping (Data) -> Void
    ) {
        self.ringBuffer = ringBuffer
        self.isFocused = isFocused
        self.onFocus = onFocus
        self.isCopyOnSelectEnabled = isCopyOnSelectEnabled
        self.onResize = onResize
        self.onFileDrop = onFileDrop
        self.onInput = onInput
    }
    
    public func makeNSView(context: Context) -> NativeTerminalScrollView {
        let scrollView = NativeTerminalScrollView()
        scrollView.terminalView.onInput = onInput
        scrollView.terminalView.ringBuffer = ringBuffer
        scrollView.terminalView.isCopyOnSelectEnabled = isCopyOnSelectEnabled
        scrollView.terminalView.onResize = onResize
        scrollView.terminalView.onFileDrop = onFileDrop
        scrollView.terminalView.onFocus = onFocus
        context.coordinator.scrollView = scrollView
        
        // 120Hz Coalesced real-time listener: batch stream updates to prevent UI overload
        ringBuffer.onUpdate = { [weak scrollView] in
            scrollView?.terminalView.scheduleRefresh()
        }
        
        // Immediate full rehydration of any existing buffer content (fixes blank pane after split)
        scrollView.terminalView.refresh()
        
        // Auto-focus if this pane is focused and sync initial PTY window size
        DispatchQueue.main.async {
            if isFocused {
                scrollView.window?.makeFirstResponder(scrollView.terminalView)
            }
            scrollView.terminalView.notifyDimensionsChangedIfNeeded()
            scrollView.terminalView.scrollToBottom(forceLayout: true)
        }
        
        return scrollView
    }
    
    public func updateNSView(_ nsView: NativeTerminalScrollView, context: Context) {
        let terminal = nsView.terminalView
        if terminal.ringBuffer !== ringBuffer {
            terminal.ringBuffer = ringBuffer
        }
        terminal.onInput = onInput
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
        
        if isFocused {
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
    }
}

public final class NativeTerminalScrollView: NSScrollView {
    public let terminalView = NativeTerminalView()
    
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupScrollView()
    }
    
    public convenience init() {
        self.init(frame: .zero)
    }
    
    private func setupScrollView() {
        self.hasVerticalScroller = true
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
        
        // 120Hz ProMotion GPU hardware acceleration layer
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.layer?.drawsAsynchronously = true
        self.contentView.wantsLayer = true
        self.contentView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        
        // Register for file drop
        self.registerForDraggedTypes([.fileURL])
    }
    
    override public func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = (newSize != self.frame.size)
        super.setFrameSize(newSize)
        if sizeChanged {
            if terminalView.isPinnedToBottom {
                terminalView.scrollToBottom(forceLayout: true)
            }
            terminalView.notifyDimensionsChangedIfNeeded()
        }
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
              let first = urls.first else { return false }
        if let dropHandler = terminalView.onFileDrop {
            dropHandler(first)
            return true
        }
        return false
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Native Terminal View with full macOS Chinese IME (拼音/五笔) support and incremental 120Hz rendering
@MainActor
public final class NativeTerminalView: NSTextView {
    public var ringBuffer: TerminalRingBuffer? {
        didSet {
            if oldValue !== ringBuffer {
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
    private var resizeDebounceTask: Task<Void, Never>? = nil
    
    private let parser = VTParser()
    private var lastCommittedIndex: Int64 = 0
    private var activeLineStartLocation = 0
    private var customInputContext: NSTextInputContext?
    private var currentMarkedText: String = ""
    private var currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    
    // Terminal frame coalescing & throttling
    private let refreshLock = NSLock()
    nonisolated(unsafe) private var isRefreshScheduled: Bool = false
    
    // Terminal cursor and blinking state
    private var isCursorVisible: Bool = true
    private var cursorBlinkTimer: Timer?
    private var isFocused: Bool = false
    
    // High-performance styling cache for zero-allocation 120Hz rendering
    private var cachedBaseFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var cachedBoldFont: NSFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private static let defaultTextColor = NSColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1.0)
    private static var colorCache: [String: NSColor] = [:]
    private static let colorCacheLock = NSLock()
    
    /// Tracks whether viewport is pinned to the command prompt line at the bottom
    public var isPinnedToBottom: Bool = true
    
    /// Calculate current rows and columns based on visible scroll view bounds and font metrics
    public func calculateTerminalDimensions() -> (cols: Int, rows: Int) {
        let font = self.font ?? cachedBaseFont
        let layoutManager = self.layoutManager
        let lineHeight = max(12, layoutManager?.defaultLineHeight(for: font) ?? 16)
        let charWidth = max(6, ("M" as NSString).size(withAttributes: [.font: font]).width)
        
        let visibleWidth = max(60, self.enclosingScrollView?.contentView.bounds.width ?? self.bounds.width)
        let visibleHeight = max(40, self.enclosingScrollView?.contentView.bounds.height ?? self.bounds.height)
        
        let cols = max(10, Int((visibleWidth - 8) / charWidth))
        let rows = max(3, Int((visibleHeight - 4) / lineHeight))
        return (cols, rows)
    }
    
    /// Check whether clipView is currently resting at the bottom of the document
    public func isScrolledToBottom() -> Bool {
        guard let clipView = self.enclosingScrollView?.contentView else { return true }
        let docHeight = self.frame.height
        let clipHeight = clipView.bounds.height
        let targetY = max(0, docHeight - clipHeight)
        return abs(clipView.bounds.origin.y - targetY) <= 1.0
    }
    
    /// Canonical rock-solid scroll to bottom ensuring prompt line is always visible without flicker.
    /// forceLayout is only needed when geometry changed (e.g. divider drag / setFrameSize).
    public func scrollToBottom(forceLayout: Bool = false) {
        guard let storage = self.textStorage, storage.length > 0 else { return }
        guard let clipView = self.enclosingScrollView?.contentView else { return }
        
        if forceLayout {
            let endRange = NSRange(location: storage.length - 1, length: 1)
            self.layoutManager?.ensureLayout(forCharacterRange: endRange)
        }
        
        let docHeight = self.frame.height
        let clipHeight = clipView.bounds.height
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
    public func notifyDimensionsChangedIfNeeded() {
        let (cols, rows) = calculateTerminalDimensions()
        if lastReportedDimensions?.cols != cols || lastReportedDimensions?.rows != rows {
            lastReportedDimensions = (cols, rows)
            resizeDebounceTask?.cancel()
            resizeDebounceTask = Task { @MainActor [weak self] in
                // 150ms debounce ensures remote PTY only resizes after active dragging pauses
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self = self else { return }
                self.onResize?(cols, rows)
            }
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
              let first = urls.first else { return false }
        if let dropHandler = onFileDrop {
            dropHandler(first)
            return true
        }
        return false
    }
    
    /// Coalesced refresh on the main thread for high-framerate batching (thread-safe, nonisolated)
    nonisolated public func scheduleRefresh() {
        refreshLock.lock()
        if isRefreshScheduled {
            refreshLock.unlock()
            return
        }
        isRefreshScheduled = true
        refreshLock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.refreshLock.lock()
            self.isRefreshScheduled = false
            self.refreshLock.unlock()
            self.refresh()
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
        self.layer?.drawsAsynchronously = true
        
        self.registerForDraggedTypes([.fileURL])
        
        NotificationCenter.default.addObserver(forName: AppSettings.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyAppSettings()
            }
        }
        
        startCursorBlink()
    }
    
    public func applyAppSettings() {
        let settings = AppSettings.shared
        
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
        self.font = resolvedFont
        self.cachedBaseFont = resolvedFont
        self.cachedBoldFont = NSFontManager.shared.convert(resolvedFont, toHaveTrait: .boldFontMask)
        
        // 2. Theme & Colors
        let theme = settings.themePreset
        let bg = NSColor(hex: theme.backgroundColorHex) ?? NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        let fg = NSColor(hex: theme.foregroundColorHex) ?? NSColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1.0)
        self.backgroundColor = bg
        self.enclosingScrollView?.backgroundColor = bg
        self.textColor = fg
        
        // 3. Cursor
        if !settings.isCursorBlinkEnabled {
            stopCursorBlink()
            isCursorVisible = true
        } else if isFocused {
            startCursorBlink()
        }
        
        // 4. Copy behavior
        self.isCopyOnSelectEnabled = settings.isCopyOnSelectEnabled
        
        self.notifyDimensionsChangedIfNeeded()
        self.needsDisplay = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public var acceptsFirstResponder: Bool { true }
    override public var canBecomeKeyView: Bool { true }
    override public var needsPanelToBecomeKey: Bool { false }
    
    override public func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            isFocused = true
            startCursorBlink()
            onFocus?()
        }
        return ok
    }
    
    override public func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
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
        needsDisplay = true
    }
    
    isolated deinit {
        cursorBlinkTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Terminal Cursor Implementation
    
    private func getCursorRect() -> NSRect? {
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer,
              let storage = self.textStorage else { return nil }
        
        let origin = self.textContainerOrigin
        let font = self.font ?? cachedBaseFont
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let shape = AppSettings.shared.cursorShape
        let charWidth = max(7, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let cursorWidth: CGFloat = (shape == .bar) ? 2.5 : charWidth
        
        let length = storage.length
        if length == 0 {
            if shape == .underline {
                return NSRect(x: origin.x, y: origin.y + lineHeight - 2.5, width: cursorWidth, height: 2.5)
            } else {
                return NSRect(x: origin.x, y: origin.y, width: cursorWidth, height: lineHeight)
            }
        }
        
        let cursorCol = ringBuffer?.cursorColumn ?? (length - activeLineStartLocation)
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
        
        guard isCursorVisible, let rect = getCursorRect() else { return }
        let focused = (window?.isKeyWindow == true && window?.firstResponder == self)
        let themeCursor = NSColor(hex: AppSettings.shared.themePreset.cursorColorHex)
        let cursorColor = focused
            ? (themeCursor ?? NSColor(red: 0.20, green: 0.78, blue: 0.95, alpha: 0.95))
            : NSColor(white: 0.6, alpha: 0.5)
        
        cursorColor.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 1.0, yRadius: 1.0)
        path.fill()
    }
    
    public func startCursorBlink() {
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
        isCursorVisible = false
        needsDisplay = true
    }
    
    public func resetCursorBlink() {
        isCursorVisible = true
        if let rect = getCursorRect() {
            setNeedsDisplay(rect.insetBy(dx: -4, dy: -4))
        } else {
            needsDisplay = true
        }
    }
    
    override public func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
        onFocus?()
        super.mouseDown(with: event)
    }
    
    override public func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag && isCopyOnSelectEnabled {
            copySelectionToPasteboardIfAny()
        }
    }
    
    override public func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if isCopyOnSelectEnabled {
            copySelectionToPasteboardIfAny()
        }
    }
    
    override public func rightMouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
        onFocus?()
        
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
    
    override public func keyDown(with event: NSEvent) {
        self.isPinnedToBottom = true
        
        // 0. Handle Cmd+K (Clear Screen)
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.shift) {
            if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "k" {
                clearScreen()
                return
            }
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
        
        // 2. Handle Special keys by key code when not composing marked IME text
        if !hasMarkedText() {
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
                onInput?("\t".data(using: .utf8)!)
                return
            case 53: // ESC
                onInput?("\u{1B}".data(using: .utf8)!)
                return
            case 126: // Up arrow
                onInput?("\u{1B}[A".data(using: .utf8)!)
                return
            case 125: // Down arrow
                onInput?("\u{1B}[B".data(using: .utf8)!)
                return
            case 124: // Right arrow
                onInput?("\u{1B}[C".data(using: .utf8)!)
                return
            case 123: // Left arrow
                onInput?("\u{1B}[D".data(using: .utf8)!)
                return
            case 115: // Home
                onInput?("\u{1B}[H".data(using: .utf8)!)
                return
            case 119: // End
                onInput?("\u{1B}[F".data(using: .utf8)!)
                return
            case 116: // Page Up
                onInput?("\u{1B}[5~".data(using: .utf8)!)
                return
            case 121: // Page Down
                onInput?("\u{1B}[6~".data(using: .utf8)!)
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
    
    // Paste support (Cmd+V and Right-Click direct paste)
    @discardableResult
    public func pasteFromClipboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return false }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        guard let data = normalized.data(using: .utf8) else { return false }
        self.isPinnedToBottom = true
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
        
        // 3. 全选 (Select All)
        let selectAllItem = NSMenuItem(title: "全选 (Select All)", action: #selector(selectAllMenuAction(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        
        // 4. 清屏 (Clear Screen)
        let clearItem = NSMenuItem(title: "清屏 (Clear Screen)", action: #selector(clearScreenMenuAction(_:)), keyEquivalent: "k")
        clearItem.target = self
        menu.addItem(clearItem)
        
        return menu
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
        self.isPinnedToBottom = true
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
        
        if !text.isEmpty {
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
        self.currentMarkedRange = selectedRange
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
        return NSRange(location: max(0, total - currentMarkedText.utf16.count), length: currentMarkedText.utf16.count)
    }
    
    override public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = getCursorRect() ?? NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: 12, height: 18)
        var screenRect = self.convert(rect, to: nil)
        screenRect.origin.y -= screenRect.size.height
        return self.window?.convertToScreen(screenRect) ?? .zero
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
            onInput?("\u{1B}".data(using: .utf8)!)
        case #selector(moveUp(_:)):
            onInput?("\u{1B}[A".data(using: .utf8)!)
        case #selector(moveDown(_:)):
            onInput?("\u{1B}[B".data(using: .utf8)!)
        case #selector(moveLeft(_:)):
            onInput?("\u{1B}[D".data(using: .utf8)!)
        case #selector(moveRight(_:)):
            onInput?("\u{1B}[C".data(using: .utf8)!)
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
        onInput?("\u{1B}".data(using: .utf8)!)
    }
    
    // MARK: - Incremental 120Hz Rendering (No Full Redraws)
    
    public func formatANSI(_ text: String) -> NSAttributedString {
        let spans = parser.parseANSI(text)
        let attrString = NSMutableAttributedString()
        
        let baseFont = self.font ?? cachedBaseFont
        let boldFont = self.cachedBoldFont
        let defaultColor = Self.defaultTextColor
        
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
            let attrs: [NSAttributedString.Key: Any] = [
                .font: span.isBold ? boldFont : baseFont,
                .foregroundColor: textColor
            ]
            attrString.append(NSAttributedString(string: span.text, attributes: attrs))
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
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        let currentTotal = buffer.totalCommittedCount
        let isCleared = buffer.consumeClearFlag() || (currentTotal < lastCommittedIndex)
        
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
                }
            }
            
            // Memory Guard: Bound textStorage length to prevent unbounded memory growth under massive streams
            if let storage = self.textStorage, storage.length > 2_500_000 {
                let excess = storage.length - 1_500_000
                storage.deleteCharacters(in: NSRange(location: 0, length: excess))
            }
            activeLineStartLocation = self.textStorage?.length ?? 0
        }
        
        // 4. Render current active line at the bottom
        let active = buffer.currentActiveLine
        if !active.isEmpty {
            let attr = formatANSI(active)
            self.textStorage?.append(attr)
        }
        
        CATransaction.commit()
        
        if self.isPinnedToBottom && (hasNewCommittedLines || isCleared || !self.isScrolledToBottom()) {
            self.scrollToBottom(forceLayout: false)
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
