import AppKit
import SwiftUI

/// Restore window geometry without reopening or reconnecting SSH sessions.
public struct WindowStateView: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView { WindowStateAnchor() }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowStateAnchor: NSView {
    private weak var configuredWindow: NSWindow?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, configuredWindow !== window else { return }
        configuredWindow = window
        // A second workspace keeps its own frame; the main workspace restores the last one.
        if NSApplication.shared.windows.contains(where: { $0 !== window && $0.frameAutosaveName == "ApexTerm.MainWorkspace" }) {
            return
        }
        window.setFrameUsingName("ApexTerm.MainWorkspace")
        window.setFrameAutosaveName("ApexTerm.MainWorkspace")
    }
}

@MainActor
final class WindowReference {
    weak var window: NSWindow?
}

struct WindowReferenceView: NSViewRepresentable {
    let reference: WindowReference
    func makeNSView(context: Context) -> NSView { Anchor(reference: reference) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? Anchor)?.reference.window = nil
    }
    final class Anchor: NSView {
        let reference: WindowReference
        init(reference: WindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference.window = window
        }
    }
}
