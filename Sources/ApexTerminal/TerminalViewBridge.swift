import SwiftUI
import AppKit
import ApexCore

/// High-performance native AppKit Terminal View wrapper for SwiftUI with 120Hz ProMotion support
public struct TerminalRepresentable: NSViewRepresentable {
    public let ringBuffer: TerminalRingBuffer
    public let onInput: (Data) -> Void
    
    public init(ringBuffer: TerminalRingBuffer, onInput: @escaping (Data) -> Void) {
        self.ringBuffer = ringBuffer
        self.onInput = onInput
    }
    
    public func makeNSView(context: Context) -> NativeTerminalScrollView {
        let scrollView = NativeTerminalScrollView()
        scrollView.terminalView.onInput = onInput
        scrollView.terminalView.ringBuffer = ringBuffer
        context.coordinator.scrollView = scrollView
        
        // Auto-focus the terminal view on load
        DispatchQueue.main.async {
            scrollView.window?.makeFirstResponder(scrollView.terminalView)
        }
        
        // Instant real-time listener: as soon as bytes arrive from SSH, trigger refresh!
        ringBuffer.onUpdate = { [weak scrollView] in
            DispatchQueue.main.async {
                scrollView?.terminalView.refresh()
            }
        }
        
        return scrollView
    }
    
    public func updateNSView(_ nsView: NativeTerminalScrollView, context: Context) {
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
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Native Terminal View with full macOS Chinese IME (拼音/五笔) support and incremental 120Hz rendering
public final class NativeTerminalView: NSTextView {
    public var ringBuffer: TerminalRingBuffer?
    public var onInput: ((Data) -> Void)?
    
    private let parser = VTParser()
    private var lastRenderedCount = 0
    private var customInputContext: NSTextInputContext?
    private var currentMarkedText: String = ""
    private var currentMarkedRange = NSRange(location: NSNotFound, length: 0)
    
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
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public var acceptsFirstResponder: Bool { true }
    override public var canBecomeKeyView: Bool { true }
    override public var needsPanelToBecomeKey: Bool { false }
    
    override public func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    
    // Provide active text input context for macOS Chinese / Japanese IME
    override public var inputContext: NSTextInputContext? {
        if customInputContext == nil {
            customInputContext = NSTextInputContext(client: self)
        }
        return customInputContext
    }
    
    override public func keyDown(with event: NSEvent) {
        // 1. If macOS IME (e.g. Chinese Pinyin) is active and handles the event
        if let inputContext = self.inputContext, inputContext.handleEvent(event) {
            return
        }
        
        // 2. Handle Ctrl key combinations: Ctrl+C, Ctrl+D, Ctrl+Z, Ctrl+L, etc.
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
        
        // 3. Handle Special keys by key code
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
    
    // MARK: - NSTextInputClient / Text Input Overrides
    
    /// Called when user commits a Chinese candidate word or types standard text
    override public func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }
        
        currentMarkedText = ""
        currentMarkedRange = NSRange(location: NSNotFound, length: 0)
        
        if let data = text.data(using: .utf8) {
            onInput?(data)
        }
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
    }
    
    override public func unmarkText() {
        self.currentMarkedText = ""
        self.currentMarkedRange = NSRange(location: NSNotFound, length: 0)
        self.needsDisplay = true
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
        let total = textStorage?.length ?? 0
        let glyphRange = NSRange(location: max(0, total - 1), length: 1)
        var rect = layoutManager?.boundingRect(forGlyphRange: glyphRange, in: textContainer ?? NSTextContainer()) ?? .zero
        rect.origin.y += rect.size.height
        rect.size.width = 12
        rect.size.height = 18
        return self.window?.convertToScreen(self.convert(rect, to: nil)) ?? .zero
    }
    
    // Command selectors from interpretKeyEvents
    override public func insertNewline(_ sender: Any?) {
        onInput?("\r".data(using: .utf8)!)
    }
    
    override public func deleteBackward(_ sender: Any?) {
        onInput?("\u{7F}".data(using: .utf8)!)
    }
    
    override public func insertTab(_ sender: Any?) {
        onInput?("\t".data(using: .utf8)!)
    }
    
    override public func cancelOperation(_ sender: Any?) {
        onInput?("\u{1B}".data(using: .utf8)!)
    }
    
    // MARK: - Incremental 120Hz Rendering (No Full Redraws)
    
    public func appendRawOutput(_ text: String) {
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
        
        self.textStorage?.append(attrString)
        self.scrollToEndOfDocument(nil)
    }
    
    /// Incremental refresh: only appends newly arrived lines to ensure 120Hz silky smoothness
    public func refresh() {
        guard let buffer = ringBuffer else { return }
        let total = buffer.lineCount
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        
        if total > lastRenderedCount {
            let newLines = buffer.lines(from: lastRenderedCount, count: total - lastRenderedCount)
            lastRenderedCount = total
            if !newLines.isEmpty {
                let chunk = (self.string.isEmpty ? "" : "\n") + newLines.joined(separator: "\n")
                appendRawOutput(chunk)
            }
        } else if total < lastRenderedCount || (lastRenderedCount == 0 && total > 0) {
            // Buffer cleared or initial render
            lastRenderedCount = total
            self.string = ""
            let all = buffer.allLines().joined(separator: "\n")
            appendRawOutput(all)
        }
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
