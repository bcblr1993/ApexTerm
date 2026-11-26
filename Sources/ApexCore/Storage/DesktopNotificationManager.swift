import Foundation
import Combine
import AppKit
import UserNotifications

/// Normalized notification payload produced by `DesktopNotificationManager`.
public struct DesktopNotificationPayload: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case commandCompleted(exitCode: Int?, durationMs: Int?)
        case oscSequence
    }

    public let id: String
    public let tabID: UUID
    public let title: String
    public let subtitle: String?
    public let body: String
    public let userInfo: [String: String]
    public let playSound: Bool
    public let kind: Kind

    public init(
        id: String = UUID().uuidString,
        tabID: UUID,
        title: String,
        subtitle: String? = nil,
        body: String,
        userInfo: [String: String],
        playSound: Bool,
        kind: Kind
    ) {
        self.id = id
        self.tabID = tabID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.userInfo = userInfo
        self.playSound = playSound
        self.kind = kind
    }
}

/// Sink abstraction allowing production delivery via `UNUserNotificationCenter` and deterministic test mocks.
public protocol DesktopNotificationDelivering: Sendable {
    func deliver(_ payload: DesktopNotificationPayload)
}

/// Production macOS notification deliverer guarded against non-bundled CLI test processes.
public struct UNUserNotificationDeliverer: DesktopNotificationDelivering {
    public init() {}

    public func deliver(_ payload: DesktopNotificationPayload) {
        guard DesktopNotificationManager.isUserNotificationCenterSupported else { return }
        Task {
            await Self.deliverToUserNotificationCenter(payload)
        }
    }

    private static func deliverToUserNotificationCenter(_ payload: DesktopNotificationPayload) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var status = settings.authorizationStatus
        if status == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            status = .authorized
        }
        guard status == .authorized || status == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        if let subtitle = payload.subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = payload.body
        content.userInfo = payload.userInfo
        if payload.playSound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: payload.id,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

/// Closure-backed notification sink for tests and custom integrations.
public struct ClosureDesktopNotificationDeliverer: DesktopNotificationDelivering {
    private let handler: @Sendable (DesktopNotificationPayload) -> Void

    public init(_ handler: @escaping @Sendable (DesktopNotificationPayload) -> Void) {
        self.handler = handler
    }

    public func deliver(_ payload: DesktopNotificationPayload) {
        handler(payload)
    }
}

/// Manages desktop notifications for background long-running commands (OSC 133) and OSC 9/777 sequences.
@MainActor
public final class DesktopNotificationManager: ObservableObject {
    public static let shared = DesktopNotificationManager()

    public static let focusTabNotification = Notification.Name("ApexTermFocusTabFromNotification")
    nonisolated public static let maxPayloadBytes = 1024

    /// `UNUserNotificationCenter.current()` throws `NSInternalInconsistencyException` outside `.app` bundles (e.g. `swift test`).
    nonisolated public static var isUserNotificationCenterSupported: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            return false
        }
        return Bundle.main.bundleURL.pathExtension == "app"
    }

    private enum Keys {
        static let notificationsEnabled = "settings.notifications.enabled"
        static let onlyWhenInactiveOrBackgroundTab = "settings.notifications.onlyWhenInactiveOrBackgroundTab"
        static let minimumCommandDurationSeconds = "settings.notifications.minimumCommandDurationSeconds"
        static let notifyOnOSCSequences = "settings.notifications.notifyOnOSCSequences"
        static let playSound = "settings.notifications.playSound"
    }

    private let defaults: UserDefaults
    private let deliverer: any DesktopNotificationDelivering
    private let now: () -> Date
    private let rateLimitWindow: TimeInterval
    private let maxNotificationsPerTabInWindow: Int
    private var recentNotificationsByTab: [UUID: [Date]] = [:]

    public var isAppActive: () -> Bool
    public var activeTabID: () -> UUID?
    public var isAppLocked: () -> Bool
    public var trackedActiveTabID: UUID?

    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published public var onlyWhenInactiveOrBackgroundTab: Bool {
        didSet { defaults.set(onlyWhenInactiveOrBackgroundTab, forKey: Keys.onlyWhenInactiveOrBackgroundTab) }
    }

    @Published public var minimumCommandDurationSeconds: Double {
        didSet {
            let clamped = max(0.0, minimumCommandDurationSeconds)
            if clamped != minimumCommandDurationSeconds {
                minimumCommandDurationSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.minimumCommandDurationSeconds)
        }
    }

    @Published public var notifyOnOSCSequences: Bool {
        didSet { defaults.set(notifyOnOSCSequences, forKey: Keys.notifyOnOSCSequences) }
    }

    @Published public var playSound: Bool {
        didSet { defaults.set(playSound, forKey: Keys.playSound) }
    }

    public init(
        defaults: UserDefaults = .standard,
        deliverer: (any DesktopNotificationDelivering)? = nil,
        isAppActive: (() -> Bool)? = nil,
        activeTabID: (() -> UUID?)? = nil,
        isAppLocked: (() -> Bool)? = nil,
        now: @escaping () -> Date = { Date() },
        rateLimitWindow: TimeInterval = 10.0,
        maxNotificationsPerTabInWindow: Int = 3
    ) {
        self.defaults = defaults
        self.deliverer = deliverer ?? UNUserNotificationDeliverer()
        self.now = now
        self.rateLimitWindow = max(0.0, rateLimitWindow)
        self.maxNotificationsPerTabInWindow = max(1, maxNotificationsPerTabInWindow)
        self.isAppActive = isAppActive ?? { NSApp?.isActive ?? false }
        self.activeTabID = { nil }
        self.isAppLocked = isAppLocked ?? { AppLockManager.shared.isLocked }

        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) != nil
            ? defaults.bool(forKey: Keys.notificationsEnabled)
            : true
        self.onlyWhenInactiveOrBackgroundTab = defaults.object(forKey: Keys.onlyWhenInactiveOrBackgroundTab) != nil
            ? defaults.bool(forKey: Keys.onlyWhenInactiveOrBackgroundTab)
            : true
        let persistedDuration = defaults.object(forKey: Keys.minimumCommandDurationSeconds) != nil
            ? defaults.double(forKey: Keys.minimumCommandDurationSeconds)
            : 10.0
        self.minimumCommandDurationSeconds = max(0.0, persistedDuration)
        self.notifyOnOSCSequences = defaults.object(forKey: Keys.notifyOnOSCSequences) != nil
            ? defaults.bool(forKey: Keys.notifyOnOSCSequences)
            : true
        self.playSound = defaults.object(forKey: Keys.playSound) != nil
            ? defaults.bool(forKey: Keys.playSound)
            : false

        if let activeTabID {
            self.activeTabID = activeTabID
        } else {
            self.activeTabID = { [weak self] in self?.trackedActiveTabID }
        }
    }

    public func resetPreferences() {
        notificationsEnabled = true
        onlyWhenInactiveOrBackgroundTab = true
        minimumCommandDurationSeconds = 10.0
        notifyOnOSCSequences = true
        playSound = false
    }

    public func resetRateLimits() {
        recentNotificationsByTab.removeAll()
    }

    /// Strips C0/DEL/C1 control characters and caps output to `maxUTF8Bytes` without splitting UTF-8 characters.
    nonisolated public static func sanitize(_ text: String, maxUTF8Bytes: Int = maxPayloadBytes) -> String {
        guard maxUTF8Bytes > 0, !text.isEmpty else { return "" }

        var cleaned = String()
        cleaned.reserveCapacity(min(text.count, maxUTF8Bytes))
        var pendingSpace = false

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D {
                if !cleaned.isEmpty {
                    pendingSpace = true
                }
                continue
            }
            if v < 0x20 || v == 0x7F || (v >= 0x80 && v <= 0x9F) {
                continue
            }
            if pendingSpace {
                cleaned.append(" ")
                pendingSpace = false
            }
            cleaned.unicodeScalars.append(scalar)
        }

        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maxUTF8Bytes else { return trimmed }

        var truncated = String()
        var currentBytes = 0
        for ch in trimmed {
            let chBytes = String(ch).utf8.count
            if currentBytes + chBytes > maxUTF8Bytes {
                break
            }
            truncated.append(ch)
            currentBytes += chBytes
        }
        return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Evaluates whether a completed shell command should emit a desktop notification.
    public func handleCommandCompleted(
        commandText: String?,
        durationMs: Int?,
        exitCode: Int?,
        workingDirectory: String? = nil,
        formattedDuration: String? = nil,
        tabID: UUID,
        sessionTitle: String
    ) {
        _ = workingDirectory
        guard notificationsEnabled else { return }
        guard let durationMs else { return }

        let durationSeconds = Double(durationMs) / 1000.0
        guard durationSeconds >= minimumCommandDurationSeconds else { return }
        guard !shouldSuppressForFocus(tabID: tabID) else { return }
        guard consumeRateLimitSlot(for: tabID) else { return }

        let payload: DesktopNotificationPayload
        if isAppLocked() {
            payload = DesktopNotificationPayload(
                tabID: tabID,
                title: "AetherTerm 已锁定",
                body: "安全提示：终端任务已完成",
                userInfo: ["tabID": tabID.uuidString],
                playSound: playSound,
                kind: .commandCompleted(exitCode: exitCode, durationMs: durationMs)
            )
        } else {
            let safeSession = Self.sanitize(sessionTitle, maxUTF8Bytes: 128)
            let displaySession = safeSession.isEmpty ? "终端会话" : safeSession
            let durationLabel = formattedDuration ?? Self.formatDuration(ms: durationMs)
            let codeValue = exitCode ?? 0

            let title: String
            if codeValue == 0 {
                title = "命令执行完成 · \(displaySession)"
            } else {
                title = "命令执行失败 (退出码 \(codeValue)) · \(displaySession)"
            }

            let safeCommand = commandText.map { Self.sanitize($0, maxUTF8Bytes: 256) }.flatMap { $0.isEmpty ? nil : $0 }
            let rawBody: String
            if let safeCommand {
                rawBody = "\(safeCommand) — 退出码 \(codeValue)，耗时 \(durationLabel)"
            } else {
                rawBody = "退出码 \(codeValue)，耗时 \(durationLabel)"
            }
            let body = Self.sanitize(rawBody, maxUTF8Bytes: Self.maxPayloadBytes)

            payload = DesktopNotificationPayload(
                tabID: tabID,
                title: title,
                body: body,
                userInfo: ["tabID": tabID.uuidString],
                playSound: playSound,
                kind: .commandCompleted(exitCode: exitCode, durationMs: durationMs)
            )
        }
        deliverer.deliver(payload)
    }

    /// Evaluates whether an OSC 9 or OSC 777 sequence should emit a desktop notification.
    public func handleOSCNotification(
        title: String?,
        body: String,
        tabID: UUID,
        sessionTitle: String
    ) {
        guard notificationsEnabled, notifyOnOSCSequences else { return }

        let safeTitle = title.map { Self.sanitize($0, maxUTF8Bytes: 256) }.flatMap { $0.isEmpty ? nil : $0 }
        let safeBody = Self.sanitize(body, maxUTF8Bytes: Self.maxPayloadBytes)
        guard !safeBody.isEmpty || safeTitle != nil else { return }

        guard !shouldSuppressForFocus(tabID: tabID) else { return }
        guard consumeRateLimitSlot(for: tabID) else { return }

        let payload: DesktopNotificationPayload
        if isAppLocked() {
            payload = DesktopNotificationPayload(
                tabID: tabID,
                title: "AetherTerm 已锁定",
                subtitle: nil,
                body: "安全提示：终端任务已完成",
                userInfo: ["tabID": tabID.uuidString],
                playSound: playSound,
                kind: .oscSequence
            )
        } else {
            let safeSession = Self.sanitize(sessionTitle, maxUTF8Bytes: 128)
            let displaySession = safeSession.isEmpty ? "终端会话" : safeSession

            let resolvedTitle = safeTitle ?? displaySession
            let resolvedSubtitle = safeTitle != nil ? displaySession : nil
            let resolvedBody = safeBody.isEmpty ? (safeTitle ?? "") : safeBody

            payload = DesktopNotificationPayload(
                tabID: tabID,
                title: resolvedTitle,
                subtitle: resolvedSubtitle,
                body: resolvedBody,
                userInfo: ["tabID": tabID.uuidString],
                playSound: playSound,
                kind: .oscSequence
            )
        }
        deliverer.deliver(payload)
    }

    /// Routes a clicked system notification back to the workspace to focus the originating tab.
    public func routeNotificationClick(userInfo: [AnyHashable: Any]) {
        let tabID: UUID? = (userInfo["tabID"] as? UUID)
            ?? (userInfo["tabID"] as? String).flatMap(UUID.init(uuidString:))
        guard let tabID else { return }

        NotificationCenter.default.post(
            name: Self.focusTabNotification,
            object: tabID,
            userInfo: ["tabID": tabID]
        )
    }

    private func shouldSuppressForFocus(tabID: UUID) -> Bool {
        guard onlyWhenInactiveOrBackgroundTab else { return false }
        return isAppActive() && activeTabID() == tabID
    }

    private func consumeRateLimitSlot(for tabID: UUID) -> Bool {
        let current = now()
        if rateLimitWindow <= 0 {
            return true
        }
        var timestamps = (recentNotificationsByTab[tabID] ?? []).filter {
            current.timeIntervalSince($0) < rateLimitWindow
        }
        if timestamps.count >= maxNotificationsPerTabInWindow {
            recentNotificationsByTab[tabID] = timestamps
            return false
        }
        timestamps.append(current)
        recentNotificationsByTab[tabID] = timestamps
        return true
    }

    private static func formatDuration(ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else if ms < 60_000 {
            return String(format: "%.2fs", Double(ms) / 1000.0)
        } else {
            let mins = ms / 60_000
            let secs = (ms % 60_000) / 1000
            return "\(mins)m \(secs)s"
        }
    }
}
