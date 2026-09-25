import SwiftUI
import AppKit
import ApexCore

/// High-performance native AppKit Terminal View wrapper for SwiftUI
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
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

public final class NativeTerminalView: NSTextView {
    public var ringBuffer: TerminalRingBuffer?
    public var onInput: ((Data) -> Void)?
    
    private let parser = VTParser()
    private var lastRenderedCount = 0
    
    override public init(frame frameRect: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: textContainer)
        setupTerminalView()
    }
    
    public convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }
    
    private func setupTerminalView() {
        self.isEditable = false
        self.isSelectable = true
        self.drawsBackground = true
        self.backgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        self.textColor = NSColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1.0)
        self.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        self.autoresizingMask = [.width]
        self.textContainer?.widthTracksTextView = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public var acceptsFirstResponder: Bool { true }
    
    override public func keyDown(with event: NSEvent) {
        guard let characters = event.characters else {
            super.keyDown(with: event)
            return
        }
        
        // Handle arrow keys and special codes
        var data: Data?
        if event.keyCode == 126 { // Up arrow
            data = "\u{001B}[A".data(using: .utf8)
        } else if event.keyCode == 125 { // Down arrow
            data = "\u{001B}[B".data(using: .utf8)
        } else if event.keyCode == 124 { // Right arrow
            data = "\u{001B}[C".data(using: .utf8)
        } else if event.keyCode == 123 { // Left arrow
            data = "\u{001B}[D".data(using: .utf8)
        } else {
            data = characters.data(using: .utf8)
        }
        
        if let d = data {
            onInput?(d)
        }
    }
    
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
    
    public func refresh() {
        guard let buffer = ringBuffer else { return }
        let total = buffer.lineCount
        if total != lastRenderedCount {
            lastRenderedCount = total
            let all = buffer.allLines().joined(separator: "\n")
            self.string = ""
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
