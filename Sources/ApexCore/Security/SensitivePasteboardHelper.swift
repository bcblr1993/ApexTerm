import Foundation
import AppKit

/// Pasteboard abstraction allowing deterministic unit testing without mutating the system clipboard.
@MainActor
public protocol SensitivePasteboardWriting: AnyObject {
    var changeCount: Int { get }
    func clearContents()
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType)
    func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType)
}

@MainActor
public final class SystemGeneralPasteboardAdapter: SensitivePasteboardWriting {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int {
        pasteboard.changeCount
    }

    public func clearContents() {
        pasteboard.clearContents()
    }

    public func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) {
        pasteboard.setString(string, forType: dataType)
    }

    public func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) {
        pasteboard.setData(data, forType: dataType)
    }
}

/// Centralized clipboard protection helper for sensitive secrets (passwords, passphrases, private keys).
/// Marks entries with `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType` and schedules
/// conditional auto-clear that only clears the clipboard when `changeCount` still matches the copied secret.
@MainActor
public final class SensitivePasteboardHelper: ObservableObject {
    public static let shared = SensitivePasteboardHelper()

    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    public static let defaultAutoClearSeconds: TimeInterval = 30

    private enum Keys {
        static let autoClearSeconds = "security.pasteboard.autoClearSeconds"
    }

    public typealias ClearScheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    private let pasteboard: any SensitivePasteboardWriting
    private let userDefaults: UserDefaults
    private let scheduler: ClearScheduler
    private var cancelScheduledClear: (@MainActor () -> Void)?

    /// Configurable auto-clear delay in seconds (`0` disables scheduled clearing).
    @Published public var autoClearSeconds: TimeInterval {
        didSet {
            let clamped = max(0, autoClearSeconds)
            if clamped != autoClearSeconds {
                autoClearSeconds = clamped
                return
            }
            userDefaults.set(clamped, forKey: Keys.autoClearSeconds)
        }
    }

    @Published public private(set) var lastChangeCount: Int?

    public init(
        pasteboard: (any SensitivePasteboardWriting)? = nil,
        userDefaults: UserDefaults = .standard,
        scheduler: ClearScheduler? = nil
    ) {
        self.pasteboard = pasteboard ?? SystemGeneralPasteboardAdapter()
        self.userDefaults = userDefaults
        self.scheduler = scheduler ?? Self.defaultScheduler

        if userDefaults.object(forKey: Keys.autoClearSeconds) != nil {
            self.autoClearSeconds = max(0, userDefaults.double(forKey: Keys.autoClearSeconds))
        } else {
            self.autoClearSeconds = Self.defaultAutoClearSeconds
        }
    }

    private static let defaultScheduler: ClearScheduler = { delay, action in
        let task = Task { @MainActor in
            let nanos = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            action()
        }
        return {
            task.cancel()
        }
    }

    /// Copies a secret to the pasteboard with ConcealedType & TransientType metadata and schedules auto-clear.
    @discardableResult
    public func copySecret(_ secret: String, autoClearAfter overrideSeconds: TimeInterval? = nil) -> Int {
        cancelScheduledClear?()
        cancelScheduledClear = nil

        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)
        pasteboard.setData(Data(), forType: Self.transientType)

        let count = pasteboard.changeCount
        lastChangeCount = count

        let delay = max(0, overrideSeconds ?? autoClearSeconds)
        if delay > 0 {
            cancelScheduledClear = scheduler(delay) { [weak self] in
                self?.clearIfUnchanged(expectedChangeCount: count)
            }
        }
        return count
    }

    /// Clears the pasteboard ONLY if its current `changeCount` still matches `expectedChangeCount` (or `lastChangeCount`).
    @discardableResult
    public func clearIfUnchanged(expectedChangeCount: Int? = nil) -> Bool {
        let targetCount = expectedChangeCount ?? lastChangeCount
        guard let targetCount else { return false }
        guard pasteboard.changeCount == targetCount else {
            if lastChangeCount == targetCount {
                lastChangeCount = nil
            }
            return false
        }
        pasteboard.clearContents()
        lastChangeCount = nil
        cancelScheduledClear?()
        cancelScheduledClear = nil
        return true
    }

    /// Cancels any pending auto-clear timer and clears the pasteboard if our secret is still active.
    public func clearNowIfOwned() {
        _ = clearIfUnchanged()
    }

    public func resetPreferences() {
        autoClearSeconds = Self.defaultAutoClearSeconds
    }
}
