import AppKit
import Carbon // EnableSecureEventInput / DisableSecureEventInput
import HarnessCore

/// The reference-counted accounting for process-global secure keyboard entry, isolated from AppKit
/// so the enable/disable balance is unit-testable. `EnableSecureEventInput` / `DisableSecureEventInput`
/// are **process-global and stack-counted** by the OS: every enable must be balanced by exactly one
/// disable, or the global lock leaks and secure input stays forced on system-wide until the process
/// exits. `apply` is idempotent — it takes the lock at most once and releases it at most once.
final class SecureInputLock {
    private(set) var isHeld = false
    private let enable: () -> Void
    private let disable: () -> Void

    /// Closures default to the real OS calls; tests inject counters so no global state is touched.
    init(enable: @escaping () -> Void = { EnableSecureEventInput() },
         disable: @escaping () -> Void = { DisableSecureEventInput() }) {
        self.enable = enable
        self.disable = disable
    }

    func apply(shouldHold: Bool) {
        if shouldHold, !isHeld {
            enable()
            isHeld = true
        } else if !shouldHold, isHeld {
            disable()
            isHeld = false
        }
    }
}

/// Ties the secure-input lock to the user setting AND app-active state, so Harness holds the global
/// lock only while it is the frontmost app with the setting on — never in the background (which
/// would needlessly keep secure input forced on for the whole system). Without this, any local
/// process can keylog keystrokes typed at a sudo / ssh-passphrase prompt inside Harness.
@MainActor
final class SecureKeyboardEntry {
    static let shared = SecureKeyboardEntry()

    private let lock: SecureInputLock

    init(lock: SecureInputLock = SecureInputLock()) {
        self.lock = lock
    }

    /// Start observing app-active transitions and apply the current desired state. Idempotent.
    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appActiveChanged),
                           name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appResignedActive),
                           name: NSApplication.willResignActiveNotification, object: nil)
        sync()
    }

    /// Re-evaluate after the user toggles the setting.
    func settingChanged() { sync() }

    /// Release the global lock unconditionally — called on app termination so the lock never
    /// outlives the process (a leaked enable would keep secure input on system-wide).
    func releaseForShutdown() { lock.apply(shouldHold: false) }

    @objc private func appActiveChanged() { sync() }

    /// On resign-active the desired state is always "released", regardless of the setting, so we
    /// never hold the global lock while backgrounded.
    @objc private func appResignedActive() { lock.apply(shouldHold: false) }

    private func sync() {
        lock.apply(shouldHold: SessionCoordinator.shared.settings.secureKeyboardEntry && NSApp.isActive)
    }
}
