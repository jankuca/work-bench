import AppKit

/// System sleep and display sleep, which are **two** subscriptions rather than one.
///
/// `willSleepNotification` does not fire when only the display sleeps, so an app that
/// watched it alone would go on polling at full rate against a dark screen — the exact case
/// IMPLEMENTATION_PLAN §4 calls out. They are tracked as separate flags because they wake
/// separately: the screen can come back while the machine never slept, and both have to be
/// clear before polling resumes.
///
/// These are `NSWorkspace`'s notification centre, not `NotificationCenter.default`. The
/// workspace notifications are the only ones that carry sleep and wake.
@MainActor
final class SleepMonitor {
    private(set) var isSystemAsleep = false
    private(set) var isDisplayAsleep = false

    /// Called on the main actor after either flag changes.
    var onChange: () -> Void = {}

    private var tokens: [any NSObjectProtocol] = []

    /// Starts observing. Idempotent — a second call while running would otherwise register
    /// a second set of observers and report every transition twice.
    func start() {
        guard tokens.isEmpty else { return }
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification
        ] {
            observe(name)
        }
    }

    /// Stops observing and forgets both flags.
    ///
    /// The flags go back to awake deliberately: with nothing observing them, a `true` left
    /// behind would suspend the scheduler forever on the wake notification it can no longer
    /// hear.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens = []
        isSystemAsleep = false
        isDisplayAsleep = false
    }

    private func observe(_ name: Notification.Name) {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` is what makes this assertion true rather than hopeful: the
            // block is delivered on the main queue, which is the main actor's executor.
            MainActor.assumeIsolated { self?.handle(name) }
        }
        tokens.append(token)
    }

    private func handle(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification: isSystemAsleep = true
        case NSWorkspace.didWakeNotification: isSystemAsleep = false
        case NSWorkspace.screensDidSleepNotification: isDisplayAsleep = true
        case NSWorkspace.screensDidWakeNotification: isDisplayAsleep = false
        default: return
        }
        onChange()
    }
}
