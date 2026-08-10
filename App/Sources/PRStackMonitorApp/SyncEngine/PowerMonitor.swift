import Foundation
import IOKit.ps
import PRStackCore

/// Where the machine's power is coming from, and a callback when that changes.
///
/// One of the two reasons `SyncEngine` cannot live in the portable package: this is IOKit,
/// and the rule it feeds — "on battery below 20%, poll every 15 minutes, ahead of
/// everything including an open panel" — is `SyncPolicy`'s, in core, where a Linux
/// container can test it (IMPLEMENTATION_PLAN §4).
@MainActor
final class PowerMonitor {
    /// Called on the main actor whenever a power source changes: plugged in, unplugged, or
    /// a charge level crossing whatever IOKit considers worth reporting.
    var onChange: () -> Void = {}

    private var runLoopSource: CFRunLoopSource?

    /// Starts observing. Idempotent — a second call while running does nothing rather than
    /// adding a second source to the run loop.
    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // A C callback, so it captures nothing: the monitor arrives through the context
        // pointer instead. Unretained, because the engine owns this object for the life of
        // the process and ``stop()`` takes the source back out of the run loop.
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            // Delivered on the main run loop, which is the main actor's own thread, so this
            // asserts an isolation that already holds rather than hopping to establish it.
            MainActor.assumeIsolated { monitor.onChange() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            // Nothing to be done about it, and nothing to warn the user about: the sync
            // engine re-reads the power state on every tick regardless, so a monitor that
            // could not be created costs promptness and not correctness.
            NSLog("PRStackMonitor: could not observe power sources; battery changes will be noticed at the next poll instead.")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    /// Stops observing. Safe to call twice, and safe to call without a matching ``start()``.
    func stop() {
        guard let source = runLoopSource else { return }
        runLoopSource = nil // clear BEFORE removing, so a second call is a no-op
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// The current power state, read fresh.
    ///
    /// Read rather than cached: the notification says *something* changed, not what, and a
    /// cached copy is one missed callback away from telling the scheduler the laptop is
    /// still plugged in.
    func read() -> PowerState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            // No power sources at all is a desktop. Mains, no battery, nothing to save.
            return .wired
        }

        var state = PowerState.wired
        for source in sources {
            // `Get`, not `Copy`: the description belongs to the blob above, so it is
            // unretained and must not be released with it.
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            let isOnBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            guard let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                  maximum > 0
            else {
                // A source that reports no capacity still reports whether it is the one
                // supplying power, and that half is worth keeping.
                state = PowerState(isOnBattery: state.isOnBattery || isOnBattery)
                continue
            }
            // First internal battery wins. A machine with two — or with a UPS listed
            // alongside one — is not a case worth a policy: the fraction is a threshold
            // input, and the first battery's charge is the one the user is watching.
            return PowerState(
                isOnBattery: isOnBattery,
                batteryFraction: min(1, max(0, current / maximum))
            )
        }
        return state
    }
}
