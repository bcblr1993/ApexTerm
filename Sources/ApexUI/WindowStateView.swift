import AppKit
import SwiftUI

/// Restore window geometry without reopening or reconnecting SSH sessions.
public struct WindowStateView: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView { WindowStateAnchor() }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class WindowStateAnchor: NSView {
    private weak var configuredWindow: NSWindow?
    private var eventMonitor: Any?

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
        setupTitlebarDoubleClickHandler(for: window)
    }

    private func setupTitlebarDoubleClickHandler(for window: NSWindow) {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak window] event in
            guard let _ = self, let targetWindow = window else { return event }
            guard event.window === targetWindow, event.clickCount == 2 else { return event }

            if TitlebarZoomHelper.isTitlebarEmptyArea(at: event.locationInWindow, in: targetWindow) {
                TitlebarZoomHelper.performDoubleClickAction(for: targetWindow)
                return nil
            }
            return event
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    isolated deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

@MainActor
public enum TitlebarZoomHelper {
    public static func isTitlebarEmptyArea(at loc: NSPoint, in window: NSWindow) -> Bool {
        let contentMaxY = window.contentLayoutRect.maxY
        guard loc.y >= contentMaxY && loc.y <= window.frame.height else {
            return false
        }

        // Traffic lights (close, miniaturize, zoom buttons)
        if let closeBtn = window.standardWindowButton(.closeButton),
           let zoomBtn = window.standardWindowButton(.zoomButton) {
            let left = closeBtn.convert(closeBtn.bounds, to: nil)
            let right = zoomBtn.convert(zoomBtn.bounds, to: nil)
            let trafficLightsRect = NSRect(
                x: 0,
                y: min(left.minY, right.minY) - 6,
                width: right.maxX + 14,
                height: max(left.height, right.height) + 12
            )
            if trafficLightsRect.contains(loc) { return false }
        }

        // Toolbar items (buttons, menus, etc.)
        for item in window.toolbar?.items ?? [] {
            if let v = item.view, v.window === window {
                let frameInWindow = v.convert(v.bounds, to: nil)
                if frameInWindow.insetBy(dx: -2, dy: -2).contains(loc) {
                    return false
                }
            }
        }

        // Any other controls in theme frame
        if let hit = window.contentView?.superview?.hitTest(loc) {
            var cur: NSView? = hit
            while let c = cur {
                if c is NSControl { return false }
                cur = c.superview
            }
        }

        return true
    }

    public static func performDoubleClickAction(for window: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch action {
        case "Minimize":
            window.miniaturize(nil)
        case "None":
            break
        default:
            window.performZoom(nil)
        }
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
