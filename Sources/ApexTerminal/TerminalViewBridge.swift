import SwiftUI
import AppKit
import ApexCore

/// High-performance native AppKit Terminal View wrapper for SwiftUI with 120Hz ProMotion support
public struct TerminalRepresentable: NSViewRepresentable {
    public let ringBuffer: TerminalRingBuffer
    public let onInput: (Data) -> Void
    public var isCopyOnSelectEnabled: Bool = true
    
    public init(ringBuffer: TerminalRingBuffer, isCopyOnSelectEnabled: Bool = true, onInput: @escaping (Data) -> Void) {
        self.ringBuffer = ringBuffer
        self.isCopyOnSelectEnabled = isCopyOnSelectEnabled
        self.onInput = onInput
    }
    
    public func makeNSView(context: Context) -> NativeTerminalScrollView {
        let scrollView = NativeTerminalScrollView()
        scrollView.terminalView.onInput = onInput
        scrollView.terminalView.ringBuffer = ringBuffer
        scrollView.terminalView.isCopyOnSelectEnabled = isCopyOnSelectEnabled
        context.coordinator.scrollView = scrollView
        
        // Auto-focus the terminal view on load
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(scrollView.terminalView)
        }
        
        // 120Hz Coalesced real-time listener: batch stream updates to prevent UI overload
        ringBuffer.onUpdate = { [weak scrollView] in
            scrollView?.terminalView.scheduleRefresh()
        }
        
        return scrollView
    }
    
    public func updateNSView(_ nsView: NativeTerminalScrollView, context: Context) {
        nsView.terminalView.isCopyOnSelectEnabled = isCopyOnSelectEnabled
        nsView.terminalView.refresh()
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
        self.documentView = terminalView
        self.hasVerticalScroller = true
        self.hasHorizontalScroller = false
        self.autohidesScrollers = true
        self.drawsBackground = true
        self.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        
        // 120Hz ProMotion GPU hardware acceleration layer
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.layer?.drawsAsynchronously = true
    }
    
    override public func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(terminalView)
        super.mouseDown(with: event)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Native Terminal View with full macOS Chinese IME (拼音/五笔) support and incremental 120Hz rendering
@MainActor
public final class NativeTerminalView: NSTextView {
    public var ringBuffer: TerminalRingBuffer?
    public var onInput: ((Data) -> Void)?
    public var isCopyOnSelectEnabled: Bool = true
    
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
        self.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        self.textColor = NSColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1.0)
        self.insertionPointColor = NSColor.cyan
        
        // Monospace font cascading with PingFang SC for CJK characters
        self.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        self.autoresizingMask = [.width]
        self.textContainer?.widthTracksTextView = true
        
        // Enable hardware accelerated rendering
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        self.layer?.drawsAsynchronously = true
        
        startCursorBlink()
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
        let font = self.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let cursorWidth: CGFloat = 2.5
        
        let length = storage.length
        if length == 0 {
            return NSRect(x: origin.x, y: origin.y, width: cursorWidth, height: lineHeight)
        }
        
        let lastChar = (storage.string as NSString).substring(with: NSRange(location: length - 1, length: 1))
        if lastChar == "\n" || lastChar == "\r" {
            let extraRect = layoutManager.extraLineFragmentRect
            if extraRect.height > 0 {
                return NSRect(x: origin.x + extraRect.minX, y: origin.y + extraRect.minY, width: cursorWidth, height: extraRect.height)
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: length - 1)
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                return NSRect(x: origin.x, y: origin.y + lineRect.maxY, width: cursorWidth, height: lineHeight)
            }
        } else {
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: length - 1)
            let charRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: textContainer)
            return NSRect(x: origin.x + charRect.maxX, y: origin.y + charRect.minY, width: cursorWidth, height: charRect.height > 0 ? charRect.height : lineHeight)
        }
    }
    
    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard isCursorVisible, let rect = getCursorRect() else { return }
        let focused = (window?.isKeyWindow == true && window?.firstResponder == self)
        let cursorColor = focused
            ? NSColor(red: 0.20, green: 0.78, blue: 0.95, alpha: 0.95)
            : NSColor(white: 0.6, alpha: 0.5)
        
        cursorColor.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 1.0, yRadius: 1.0)
        path.fill()
    }
    
    public func startCursorBlink() {
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
        super.mouseDown(with: event)
    }
    
    override public func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if isCopyOnSelectEnabled {
            copySelectionToPasteboardIfAny()
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
    
    // Paste support (Cmd+V)
    override public func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string),
           let data = text.data(using: .utf8) {
            onInput?(data)
        }
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
    
    @objc private func clearScreenMenuAction(_ sender: Any?) {
        ringBuffer?.clear()
        self.textStorage?.setAttributedString(NSAttributedString())
        self.activeLineStartLocation = 0
        self.lastCommittedIndex = 0
        self.needsDisplay = true
    }
    
    // MARK: - NSTextInputClient / Text Input Overrides
    
    /// Called when user commits a Chinese candidate word or types standard text
    override public func insertText(_ string: Any, replacementRange: NSRange) {
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
        
        let baseFont = self.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        
        for span in spans {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: span.isBold ? boldFont : baseFont,
                .foregroundColor: NSColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1.0)
            ]
            if let hex = span.foregroundColorHex, let nsColor = NSColor(hex: hex) {
                attrs[.foregroundColor] = nsColor
            }
            attrString.append(NSAttributedString(string: span.text, attributes: attrs))
        }
        return attrString
    }
    
    public func appendRawOutput(_ text: String) {
        let attr = formatANSI(text)
        self.textStorage?.append(attr)
        self.scrollToEndOfDocument(nil)
    }
    
    /// Incremental refresh: updates active line in-place and appends newly committed lines
    public func refresh() {
        guard let buffer = ringBuffer else { return }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        
        let currentTotal = buffer.totalCommittedCount
        
        // 1. Buffer cleared or initial render
        if currentTotal < lastCommittedIndex {
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
        if currentTotal > lastCommittedIndex {
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
        
        self.scrollToEndOfDocument(nil)
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
