import Foundation
import LocalAuthentication

/// Abstraction over macOS Touch ID / device-owner password authentication for testability.
public protocol BiometricAuthenticating: Sendable {
    func authenticate(reason: String) async -> Result<Void, Error>
}

/// Errors produced by `AppLockManager` and `LocalAuthenticationBiometricProvider`.
public enum AppLockError: LocalizedError, Sendable {
    case authenticationFailed
    case authenticationCancelled
    case authenticationUnavailable(String?)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "身份验证未通过，请重试"
        case .authenticationCancelled:
            return "已取消身份验证"
        case .authenticationUnavailable(let detail):
            if let detail, !detail.isEmpty {
                return "当前设备无法使用 Touch ID 或系统密码验证：\(detail)"
            }
            return "当前设备未启用系统密码或 Touch ID 验证"
        }
    }
}

/// Production Touch ID / system password authenticator backed by `LocalAuthentication`.
public struct LocalAuthenticationBiometricProvider: BiometricAuthenticating, Sendable {
    public init() {}

    public func authenticate(reason: String) async -> Result<Void, Error> {
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            return .failure(authError ?? AppLockError.authenticationUnavailable(nil))
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success {
                return .success(())
            }
            return .failure(AppLockError.authenticationFailed)
        } catch {
            return .failure(error)
        }
    }
}

/// Centralized application lock & sensitive-action security gate manager.
@MainActor
public final class AppLockManager: ObservableObject {
    public static let shared = AppLockManager()

    private enum Keys {
        static let appLockEnabled = "security.appLock.enabled"
        static let idleTimeoutSeconds = "security.appLock.idleTimeoutSeconds"
        static let lockOnAppBackground = "security.appLock.lockOnAppBackground"
        static let requireAuthForSensitiveActions = "security.appLock.requireAuthForSensitiveActions"
    }

    public static let defaultIdleTimeoutSeconds: TimeInterval = 300

    private let userDefaults: UserDefaults
    private let authenticator: any BiometricAuthenticating

    @Published public var appLockEnabled: Bool {
        didSet {
            userDefaults.set(appLockEnabled, forKey: Keys.appLockEnabled)
            if appLockEnabled {
                lastActivityDate = Date()
            } else {
                isLocked = false
                lastErrorMessage = nil
            }
        }
    }

    /// Idle timeout in seconds (`0` disables idle auto-locking).
    @Published public var idleTimeoutSeconds: TimeInterval {
        didSet {
            let sanitized = max(0, idleTimeoutSeconds)
            userDefaults.set(sanitized, forKey: Keys.idleTimeoutSeconds)
        }
    }

    @Published public var lockOnAppBackground: Bool {
        didSet {
            userDefaults.set(lockOnAppBackground, forKey: Keys.lockOnAppBackground)
        }
    }

    @Published public var requireAuthForSensitiveActions: Bool {
        didSet {
            userDefaults.set(requireAuthForSensitiveActions, forKey: Keys.requireAuthForSensitiveActions)
        }
    }

    @Published public private(set) var isLocked: Bool = false
    @Published public private(set) var isAuthenticating: Bool = false
    @Published public private(set) var lastErrorMessage: String? = nil

    public private(set) var lastActivityDate: Date

    public init(
        userDefaults: UserDefaults = .standard,
        authenticator: any BiometricAuthenticating = LocalAuthenticationBiometricProvider(),
        now: Date = Date()
    ) {
        self.userDefaults = userDefaults
        self.authenticator = authenticator
        self.lastActivityDate = now

        self.appLockEnabled = userDefaults.object(forKey: Keys.appLockEnabled) != nil
            ? userDefaults.bool(forKey: Keys.appLockEnabled)
            : false

        let persistedIdle = userDefaults.object(forKey: Keys.idleTimeoutSeconds) != nil
            ? userDefaults.double(forKey: Keys.idleTimeoutSeconds)
            : Self.defaultIdleTimeoutSeconds
        self.idleTimeoutSeconds = max(0, persistedIdle)

        self.lockOnAppBackground = userDefaults.object(forKey: Keys.lockOnAppBackground) != nil
            ? userDefaults.bool(forKey: Keys.lockOnAppBackground)
            : false

        self.requireAuthForSensitiveActions = userDefaults.object(forKey: Keys.requireAuthForSensitiveActions) != nil
            ? userDefaults.bool(forKey: Keys.requireAuthForSensitiveActions)
            : true
    }

    /// Resets all security lock preferences to factory defaults.
    public func resetPreferences() {
        appLockEnabled = false
        idleTimeoutSeconds = Self.defaultIdleTimeoutSeconds
        lockOnAppBackground = false
        requireAuthForSensitiveActions = true
        isLocked = false
        lastErrorMessage = nil
        lastActivityDate = Date()
    }

    /// Refreshes the user activity timestamp to postpone idle auto-lock.
    public func recordUserActivity() {
        lastActivityDate = Date()
    }

    /// Locks the application if app lock is enabled and the idle duration has reached `idleTimeoutSeconds`.
    public func checkIdleLock(now: Date = Date()) {
        guard appLockEnabled, !isLocked, idleTimeoutSeconds > 0 else { return }
        if now.timeIntervalSince(lastActivityDate) >= idleTimeoutSeconds {
            lockNow()
        }
    }

    /// Immediately locks the application UI.
    public func lockNow() {
        isLocked = true
        lastErrorMessage = nil
    }

    /// Handles `NSApplication.willResignActiveNotification`, locking only when both `appLockEnabled` and `lockOnAppBackground` are true.
    public func handleAppDidResignActive() {
        guard appLockEnabled, lockOnAppBackground else { return }
        lockNow()
    }

    /// Enables or disables app lock, prompting Touch ID / system password before enabling.
    @discardableResult
    public func setAppLockEnabled(
        _ enabled: Bool,
        reason: String = "验证身份以启用 AetherTerm 应用锁"
    ) async -> Bool {
        if !enabled {
            appLockEnabled = false
            return true
        }
        if appLockEnabled {
            return true
        }
        guard !isAuthenticating else { return false }

        isAuthenticating = true
        lastErrorMessage = nil
        defer { isAuthenticating = false }

        let result = await authenticator.authenticate(reason: reason)
        switch result {
        case .success:
            appLockEnabled = true
            lastErrorMessage = nil
            lastActivityDate = Date()
            return true
        case .failure(let error):
            lastErrorMessage = Self.formattedErrorMessage(for: error)
            return false
        }
    }

    /// Attempts to unlock the application using Touch ID or system password.
    @discardableResult
    public func unlockWithAuthentication(
        reason: String = "使用 Touch ID 或系统密码解锁 AetherTerm"
    ) async -> Bool {
        guard !isAuthenticating else { return false }

        isAuthenticating = true
        lastErrorMessage = nil
        defer { isAuthenticating = false }

        let result = await authenticator.authenticate(reason: reason)
        switch result {
        case .success:
            isLocked = false
            lastErrorMessage = nil
            lastActivityDate = Date()
            return true
        case .failure(let error):
            isLocked = true
            lastErrorMessage = Self.formattedErrorMessage(for: error)
            return false
        }
    }

    /// Gates sensitive operations (revealing passwords, exporting credentials, copying/exporting private keys).
    public func authorizeSensitiveAction(reason: String) async -> Bool {
        guard requireAuthForSensitiveActions else { return true }
        guard !isAuthenticating else { return false }

        isAuthenticating = true
        lastErrorMessage = nil
        defer { isAuthenticating = false }

        let result = await authenticator.authenticate(reason: reason)
        switch result {
        case .success:
            lastErrorMessage = nil
            lastActivityDate = Date()
            return true
        case .failure(let error):
            lastErrorMessage = Self.formattedErrorMessage(for: error)
            return false
        }
    }

    private static func formattedErrorMessage(for error: Error) -> String {
        if let lockError = error as? AppLockError {
            return lockError.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain == LAErrorDomain {
            switch LAError.Code(rawValue: nsError.code) {
            case .userCancel, .appCancel, .systemCancel:
                return AppLockError.authenticationCancelled.localizedDescription
            case .authenticationFailed:
                return AppLockError.authenticationFailed.localizedDescription
            case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled:
                return AppLockError.authenticationUnavailable(nsError.localizedDescription).localizedDescription
            default:
                break
            }
        }
        let desc = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return desc.isEmpty ? AppLockError.authenticationFailed.localizedDescription : desc
    }
}
