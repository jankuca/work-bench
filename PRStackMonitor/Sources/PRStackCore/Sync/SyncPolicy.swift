import Foundation

/// How often the app polls, and why.
///
/// The cases are the rows of IMPLEMENTATION_PLAN §4's table, in the order they are tested.
/// They are a *reason*, not a duration: what each one costs in seconds lives in
/// ``SyncConfiguration``, so the reason can be logged and asserted without pinning the
/// number, and the number can be changed without touching the rule.
public enum PollCadence: String, Hashable, Sendable, CaseIterable {
    /// Display or system asleep. No timer at all — a sleeping machine polls nothing.
    case suspended
    /// On battery, below the threshold.
    case lowPower
    case panelOpen
    /// A merged pull request is waiting for a release tag.
    case awaitingRelease
    /// Something changed within the activity window.
    case recentlyActive
    case idle

    /// What the diagnostic line says. Short enough for a log prefix, specific enough that
    /// "why is it polling every 15 minutes" has an answer without reading the table.
    public var label: String {
        switch self {
        case .suspended: return "asleep"
        case .lowPower: return "low battery"
        case .panelOpen: return "panel open"
        case .awaitingRelease: return "awaiting release"
        case .recentlyActive: return "recently active"
        case .idle: return "idle"
        }
    }
}

/// Where the machine's power is coming from.
public struct PowerState: Equatable, Sendable {
    public var isOnBattery: Bool
    /// `0...1`, or nil when there is no battery to read — a desktop, or a machine whose
    /// power source reports no capacity.
    public var batteryFraction: Double?

    public init(isOnBattery: Bool, batteryFraction: Double? = nil) {
        self.isOnBattery = isOnBattery
        self.batteryFraction = batteryFraction
    }

    /// Mains power, no battery. What a Mac mini reports, and the safe assumption when the
    /// power source cannot be read at all.
    public static let wired = PowerState(isOnBattery: false)

    /// Below the threshold **and** actually running off the battery.
    ///
    /// An unknown fraction reads as *not* low. The alternative — treating "no reading" as
    /// empty — would drop a machine whose power source this build cannot parse to a
    /// 15-minute interval permanently, which is a worse failure than polling a nearly-flat
    /// laptop too often for one release of the app.
    public func isLow(threshold: Double) -> Bool {
        guard isOnBattery, let fraction = batteryFraction else { return false }
        return fraction < threshold
    }
}

/// Everything the interval table asks about, gathered in one value.
///
/// Assembled by whoever can see the machine — `SyncEngine`, on a Mac — and consumed here,
/// where the decision is a pure function of it and can be tested in a Linux container.
public struct SyncConditions: Equatable, Sendable {
    /// `NSWorkspace.willSleepNotification` / `didWakeNotification`.
    public var isSystemAsleep: Bool
    /// `screensDidSleepNotification` / `screensDidWakeNotification`. A separate
    /// subscription from the one above, and not an optimisation: `willSleep` does not fire
    /// when only the display sleeps, so without it the app polls at full rate against a
    /// dark screen (IMPLEMENTATION_PLAN §4).
    public var isDisplayAsleep: Bool
    public var power: PowerState
    public var isPanelOpen: Bool
    /// At least one merged pull request is still waiting for a tag to contain it.
    public var isAwaitingRelease: Bool
    /// The most recent change the app has seen — a pull request's `updatedAt`, or the
    /// moment a transition was observed. Nil until the first poll lands.
    public var lastActivityAt: Date?

    public init(
        isSystemAsleep: Bool = false,
        isDisplayAsleep: Bool = false,
        power: PowerState = .wired,
        isPanelOpen: Bool = false,
        isAwaitingRelease: Bool = false,
        lastActivityAt: Date? = nil
    ) {
        self.isSystemAsleep = isSystemAsleep
        self.isDisplayAsleep = isDisplayAsleep
        self.power = power
        self.isPanelOpen = isPanelOpen
        self.isAwaitingRelease = isAwaitingRelease
        self.lastActivityAt = lastActivityAt
    }

    public var isAsleep: Bool { isSystemAsleep || isDisplayAsleep }
}

/// The durations behind the cadences, and the two thresholds that decide which one applies.
///
/// A value rather than constants so a test can compress an interval to a millisecond, and
/// so the numbers are all visible in one place. Nothing in v1 edits them — the plan lists
/// poll intervals among the `UserDefaults` keys, but no Settings control writes one, and a
/// preference nothing sets is a preference that will be wrong.
public struct SyncConfiguration: Equatable, Sendable {
    public var lowPower: TimeInterval
    public var panelOpen: TimeInterval
    public var awaitingRelease: TimeInterval
    public var recentlyActive: TimeInterval
    public var idle: TimeInterval
    /// Fraction of a full battery, below which the interval drops to ``lowPower``.
    public var batteryThreshold: Double
    /// How long a change counts as recent.
    public var activityWindow: TimeInterval

    public init(
        lowPower: TimeInterval = 15 * 60,
        panelOpen: TimeInterval = 30,
        awaitingRelease: TimeInterval = 60,
        recentlyActive: TimeInterval = 2 * 60,
        idle: TimeInterval = 5 * 60,
        batteryThreshold: Double = 0.20,
        activityWindow: TimeInterval = 15 * 60
    ) {
        self.lowPower = lowPower
        self.panelOpen = panelOpen
        self.awaitingRelease = awaitingRelease
        self.recentlyActive = recentlyActive
        self.idle = idle
        self.batteryThreshold = batteryThreshold
        self.activityWindow = activityWindow
    }

    /// IMPLEMENTATION_PLAN §4's table.
    public static let standard = SyncConfiguration()

    /// Nil for ``PollCadence/suspended``, which is the whole difference between it and the
    /// rest: there is no interval, so there is no timer.
    public func interval(for cadence: PollCadence) -> TimeInterval? {
        switch cadence {
        case .suspended: return nil
        case .lowPower: return lowPower
        case .panelOpen: return panelOpen
        case .awaitingRelease: return awaitingRelease
        case .recentlyActive: return recentlyActive
        case .idle: return idle
        }
    }
}

/// When the next poll is due, and under which cadence.
public struct SyncSchedule: Equatable, Sendable {
    public var cadence: PollCadence
    /// The cadence's interval, or nil while suspended. The footer reads this too — data
    /// older than one interval is what "stale" means (see ``PanelStatus/pollInterval``).
    public var interval: TimeInterval?
    /// Nil while suspended. May be in the past, which means "overdue" — use
    /// ``delay(from:)`` for a duration to wait.
    public var nextPollAt: Date?
    /// The next poll is waiting on a source's backoff rather than on the interval.
    /// Diagnostic only; the schedule is the same value either way.
    public var isHeldByBackoff: Bool

    public init(
        cadence: PollCadence,
        interval: TimeInterval?,
        nextPollAt: Date?,
        isHeldByBackoff: Bool = false
    ) {
        self.cadence = cadence
        self.interval = interval
        self.nextPollAt = nextPollAt
        self.isHeldByBackoff = isHeldByBackoff
    }

    /// Nothing is scheduled — the machine is asleep.
    public static let suspended = SyncSchedule(cadence: .suspended, interval: nil, nextPollAt: nil)

    /// How long to wait, never negative. Nil when nothing is scheduled at all.
    public func delay(from now: Date) -> TimeInterval? {
        guard let nextPollAt else { return nil }
        return max(0, nextPollAt.timeIntervalSince(now))
    }
}

/// The interval table, and the one rule that overrides it.
///
/// Pure and clock-injected, like everything else in this module: the same conditions and
/// the same instant always produce the same schedule, so the whole of §4's ordering is
/// pinned by a table test rather than by a laptop and a stopwatch.
public enum SyncPolicy {
    /// IMPLEMENTATION_PLAN §4, **strictly ordered — first match wins**.
    ///
    /// The two power conditions outrank everything, including an open panel: a sleeping
    /// machine polls nothing, and a low battery is not worth a 30-second loop no matter
    /// what is on screen. Below those, the fastest applicable interval wins by virtue of
    /// the ordering.
    public static func cadence(
        for conditions: SyncConditions,
        configuration: SyncConfiguration = .standard,
        now: Date
    ) -> PollCadence {
        if conditions.isAsleep { return .suspended }
        if conditions.power.isLow(threshold: configuration.batteryThreshold) { return .lowPower }
        if conditions.isPanelOpen { return .panelOpen }
        if conditions.isAwaitingRelease { return .awaitingRelease }
        if let last = conditions.lastActivityAt,
           now.timeIntervalSince(last) < configuration.activityWindow {
            return .recentlyActive
        }
        return .idle
    }

    /// The cadence, plus when its next poll lands.
    ///
    /// `lastPollAt` is when the last poll *started*, not when it finished: a poll that took
    /// four seconds should not push the next one four seconds later, and a poll still in
    /// flight should not be scheduled over.
    ///
    /// `backoff` is GitHub's. It can only ever push the next poll **later** — a source that
    /// is failing does not get polled sooner because the panel opened, and a healthy
    /// interval is never shortened by a cleared backoff. Linear's backoff is not here: it
    /// suppresses the Linear half of a poll rather than the poll itself, because every row
    /// renders without it (IMPLEMENTATION_PLAN §4).
    public static func schedule(
        conditions: SyncConditions,
        configuration: SyncConfiguration = .standard,
        backoff: Backoff = Backoff(),
        lastPollAt: Date?,
        now: Date
    ) -> SyncSchedule {
        let resolved = cadence(for: conditions, configuration: configuration, now: now)
        guard let interval = configuration.interval(for: resolved) else { return .suspended }

        // No poll yet this launch means one is due immediately: the icon has to mean
        // something before the first interval has elapsed.
        let due = lastPollAt.map { $0.addingTimeInterval(interval) } ?? now
        guard let retryAt = backoff.retryAt, retryAt > due else {
            return SyncSchedule(cadence: resolved, interval: interval, nextPollAt: due)
        }
        return SyncSchedule(
            cadence: resolved,
            interval: interval,
            nextPollAt: retryAt,
            // Only while it is still in the future. A hold whose instant has passed sets
            // the same overdue `nextPollAt` either way, and reporting that as "held" would
            // have the diagnostic line blaming backoff for a poll happening right now.
            isHeldByBackoff: retryAt > now
        )
    }
}
