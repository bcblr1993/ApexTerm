import XCTest
import os
@testable import ApexCore
@testable import ApexUI

@MainActor
final class AppLockAndSecurityGateTests: XCTestCase {

    private final class MockBiometricAuthenticator: BiometricAuthenticating, @unchecked Sendable {
        private struct State {
            var nextResult: Result<Void, Error>
            var callCount: Int = 0
            var lastReason: String?
        }

        private let state: OSAllocatedUnfairLock<State>

        init(nextResult: Result<Void, Error> = .success(())) {
            self.state = OSAllocatedUnfairLock(initialState: State(nextResult: nextResult))
        }

        func setResult(_ result: Result<Void, Error>) {
            state.withLock { $0.nextResult = result }
        }

        var callCount: Int {
            state.withLock { $0.callCount }
        }

        var lastReason: String? {
            state.withLock { $0.lastReason }
        }

        func authenticate(reason: String) async -> Result<Void, Error> {
            state.withLock {
                $0.callCount += 1
                $0.lastReason = reason
                return $0.nextResult
            }
        }
    }

    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "com.apexterm.tests.applock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    // MARK: - TC-V29-17: App Lock unlock with Touch ID and failure retention
    func testTCV29_17_AppLockUnlockSuccessAndFailureHandling() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let auth = MockBiometricAuthenticator(nextResult: .failure(AppLockError.authenticationFailed))
        let manager = AppLockManager(userDefaults: defaults, authenticator: auth)

        manager.appLockEnabled = true
        manager.lockNow()
        XCTAssertTrue(manager.isLocked)
        XCTAssertNil(manager.lastErrorMessage)

        let failedUnlock = await manager.unlockWithAuthentication(reason: "Test unlock fail")
        XCTAssertFalse(failedUnlock)
        XCTAssertTrue(manager.isLocked, "Failed Touch ID / password authentication must keep the app locked")
        XCTAssertNotNil(manager.lastErrorMessage)
        XCTAssertEqual(auth.callCount, 1)

        auth.setResult(.success(()))
        let succeededUnlock = await manager.unlockWithAuthentication(reason: "Test unlock success")
        XCTAssertTrue(succeededUnlock)
        XCTAssertFalse(manager.isLocked, "Successful Touch ID / password authentication must unlock the app")
        XCTAssertNil(manager.lastErrorMessage)
        XCTAssertEqual(auth.callCount, 2)
    }

    // MARK: - TC-V29-18: Idle timeout auto-lock and activity countdown reset
    func testTCV29_18_IdleTimeoutAndRecordUserActivityReset() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let manager = AppLockManager(
            userDefaults: defaults,
            authenticator: MockBiometricAuthenticator(),
            now: start
        )
        manager.appLockEnabled = true
        manager.idleTimeoutSeconds = 300

        // Setting appLockEnabled = true updates lastActivityDate to now; use a relative base from lastActivityDate.
        let base = manager.lastActivityDate
        manager.checkIdleLock(now: base.addingTimeInterval(299))
        XCTAssertFalse(manager.isLocked, "Elapsed time below idleTimeoutSeconds must not lock")

        // User activity resets the countdown cleanly.
        manager.recordUserActivity()
        let resetBase = manager.lastActivityDate
        XCTAssertGreaterThanOrEqual(resetBase, base)

        manager.checkIdleLock(now: resetBase.addingTimeInterval(150))
        XCTAssertFalse(manager.isLocked, "Countdown reset must prevent locking before full timeout from new activity")

        manager.checkIdleLock(now: resetBase.addingTimeInterval(300))
        XCTAssertTrue(manager.isLocked, "Elapsed time >= idleTimeoutSeconds must trigger lock")

        // Idle timeout = 0 disables idle auto-locking.
        manager.resetPreferences()
        manager.appLockEnabled = true
        manager.idleTimeoutSeconds = 0
        manager.checkIdleLock(now: Date().addingTimeInterval(86_400))
        XCTAssertFalse(manager.isLocked, "idleTimeoutSeconds == 0 must never auto-lock on idle")
    }

    // MARK: - TC-V29-19: Background lock requires both appLockEnabled and lockOnAppBackground
    func testTCV29_19_LockOnAppBackgroundRequiresBothFlagsEnabled() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = AppLockManager(userDefaults: defaults, authenticator: MockBiometricAuthenticator())

        // Neither enabled
        manager.appLockEnabled = false
        manager.lockOnAppBackground = false
        manager.handleAppDidResignActive()
        XCTAssertFalse(manager.isLocked)

        // Only lockOnAppBackground enabled
        manager.appLockEnabled = false
        manager.lockOnAppBackground = true
        manager.handleAppDidResignActive()
        XCTAssertFalse(manager.isLocked)

        // Only appLockEnabled enabled
        manager.appLockEnabled = true
        manager.lockOnAppBackground = false
        manager.handleAppDidResignActive()
        XCTAssertFalse(manager.isLocked)

        // Both enabled -> locks immediately on resign active
        manager.appLockEnabled = true
        manager.lockOnAppBackground = true
        manager.handleAppDidResignActive()
        XCTAssertTrue(manager.isLocked)
    }

    // MARK: - TC-V29-20: Sensitive action gate bypasses when disabled and enforces when enabled
    func testTCV29_20_SensitiveActionSecurityGateEnforcement() async {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let auth = MockBiometricAuthenticator(nextResult: .failure(AppLockError.authenticationCancelled))
        let manager = AppLockManager(userDefaults: defaults, authenticator: auth)

        // Default is true
        XCTAssertTrue(manager.requireAuthForSensitiveActions)

        // When disabled, immediately returns true without prompting
        manager.requireAuthForSensitiveActions = false
        let bypassed = await manager.authorizeSensitiveAction(reason: "Reveal password")
        XCTAssertTrue(bypassed)
        XCTAssertEqual(auth.callCount, 0, "Gate disabled must not invoke biometric authenticator")

        // When enabled, enforces auth result
        manager.requireAuthForSensitiveActions = true
        let denied = await manager.authorizeSensitiveAction(reason: "Reveal password")
        XCTAssertFalse(denied)
        XCTAssertEqual(auth.callCount, 1)
        XCTAssertEqual(manager.lastErrorMessage, AppLockError.authenticationCancelled.localizedDescription)

        auth.setResult(.success(()))
        let granted = await manager.authorizeSensitiveAction(reason: "Export encrypted share pack")
        XCTAssertTrue(granted)
        XCTAssertEqual(auth.callCount, 2)
        XCTAssertNil(manager.lastErrorMessage)
    }
}
