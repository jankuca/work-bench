import Foundation
import PRStackCore

/// The scheduler: one state machine, one timer, never scattered timers (PRD §9).
///
/// What it decides is not decided here. The interval table, the backoff arithmetic and the
/// staleness threshold are `SyncPolicy` and `Backoff`, in `PRStackCore`, pure and
/// clock-injected. This class is the part that needs a Mac — it watches sleep and power,
/// keeps the conditions up to date, and arms exactly one timer against the answer.
///
/// It does not poll. It says *when* to poll and hands that to ``onPoll``, so the panel
/// controller stays the only thing that talks to the network and the only writer of local
/// state.
@MainActor
final class SyncEngine {
    /// Fired when a poll is due. Synchronous by design: the callback starts the work and
    /// returns, and the next tick is scheduled from when this one *started* rather than
    /// from when its request finished.
    var onPoll: () -> Void = {}

    /// The schedule as it currently stands, for the footer's staleness threshold and for
    /// the diagnostic line.
    private(set) var schedule: SyncSchedule = .suspended

    private let configuration: SyncConfiguration
    private let power: PowerMonitor
    private let sleep: SleepMonitor
    private let clock: () -> Date
    /// `0...1`, one draw per recorded failure. Injected so the engine stays as testable as
    /// the policy it drives, and so the randomness lives at the edge rather than in core.
    private let jitter: () -> Double

    private var conditions = SyncConditions()
    /// Per source, never one global flag: an expired Linear key must not slow GitHub down,
    /// and a GitHub outage must not stop project headings resolving
    /// (IMPLEMENTATION_PLAN §4).
    private var backoffs: [EventSource: Backoff] = [:]
    /// When the last poll *started*. A poll that took four seconds does not push the next
    /// one four seconds later.
    private var lastPollAt: Date?
    private var timer: Task<Void, Never>?
    private var isRunning = false

    init(
        configuration: SyncConfiguration = .standard,
        power: PowerMonitor = PowerMonitor(),
        sleep: SleepMonitor = SleepMonitor(),
        clock: @escaping () -> Date = { Date() },
        jitter: @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        self.configuration = configuration
        self.power = power
        self.sleep = sleep
        self.clock = clock
        self.jitter = jitter
    }

    // MARK: - Lifecycle

    /// Begins observing and arms the first poll, which is due immediately: the menu bar
    /// icon has to mean something before the first interval has elapsed.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        sleep.onChange = { [weak self] in self?.machineDidChange() }
        power.onChange = { [weak self] in self?.machineDidChange() }
        sleep.start()
        power.start()
        machineDidChange()
    }

    func stop() {
        isRunning = false
        cancelTimer()
        sleep.stop()
        power.stop()
        schedule = .suspended
    }

    // MARK: - Conditions

    func setPanelOpen(_ isOpen: Bool) {
        guard conditions.isPanelOpen != isOpen else { return }
        conditions.isPanelOpen = isOpen
        reschedule()
    }

    /// Whether a merged pull request is still waiting for a tag to contain it — row 4 of
    /// the table, and the reason a release cut minutes from now is noticed in a minute
    /// rather than in five.
    func setAwaitingRelease(_ isAwaiting: Bool) {
        guard conditions.isAwaitingRelease != isAwaiting else { return }
        conditions.isAwaitingRelease = isAwaiting
        reschedule()
    }

    /// The most recent change the app has seen. Monotonic — an older timestamp never walks
    /// the window backwards, so a poll that returns a stale page cannot make an active
    /// stack look idle.
    func noteActivity(at date: Date?) {
        guard let date, date > (conditions.lastActivityAt ?? .distantPast) else { return }
        conditions.lastActivityAt = date
        reschedule()
    }

    /// Sleep and power, re-read together. The notifications say that *something* changed,
    /// not what, so both are refreshed on either.
    private func machineDidChange() {
        conditions.isSystemAsleep = sleep.isSystemAsleep
        conditions.isDisplayAsleep = sleep.isDisplayAsleep
        conditions.power = power.read()
        // No special case for waking: the last poll is by then older than any interval, so
        // the schedule below is already overdue and fires at once. Waking from sleep syncs
        // immediately and then re-evaluates the table from the top, which is what §4 asks
        // for, and it falls out of the ordinary arithmetic rather than out of a branch.
        reschedule()
    }

    // MARK: - Results

    /// Folds one source's outcome into its backoff.
    ///
    /// Only a transient failure escalates. A rejected credential is not retried into
    /// submission — see ``Backoff/backsOff(_:)`` — and a source that has not been asked at
    /// all this poll keeps whatever hold it already had, since nothing was learned.
    func record(_ health: SourceHealth, for source: EventSource) {
        if health.isConnected {
            guard backoffs[source] != nil else { return }
            backoffs[source]?.clear()
        } else {
            guard Backoff.backsOff(health) else { return }
            var backoff = backoffs[source] ?? Backoff()
            backoff.recordFailure(at: clock(), jitter: jitter())
            backoffs[source] = backoff
        }
        reschedule()
    }

    /// Whether the next poll may send a Linear request.
    ///
    /// False while Linear is backing off. The poll still runs and the rows still resolve
    /// from the cache — Linear's failure never blocks GitHub's list from rendering — so
    /// what this defers is one request, not the panel.
    var resolvesLinear: Bool {
        !(backoffs[.linear]?.isHolding(at: clock()) ?? false)
    }

    // MARK: - Manual

    /// The refresh control, and the poll an open panel starts with.
    ///
    /// Syncs immediately and restarts the current interval's timer from zero. It never
    /// changes which interval applies, and it deliberately does **not** clear a backoff: a
    /// user asking for one poll now is not a claim that the service has recovered.
    func refreshNow() {
        fire()
    }

    /// Reconnecting a source: everything ``refreshNow()`` does, and its backoff cleared.
    ///
    /// `nil` clears both, which is what a credential change in Settings means — either
    /// token may have been the one that was replaced.
    func reconnect(_ source: EventSource? = nil) {
        for key in EventSource.allCases where source == nil || source == key {
            backoffs[key]?.clear()
        }
        fire()
    }

    // MARK: - The timer

    /// Polls now and restarts the interval from this instant.
    ///
    /// Deliberately not gated on ``isRunning``: the two callers that reach it directly are
    /// the refresh control and a reconnect, and a control that silently does nothing is
    /// worse than a poll the scheduler did not ask for. What `isRunning` gates is the
    /// *timer*, in ``reschedule()``.
    private func fire() {
        lastPollAt = clock()
        onPoll()
        reschedule()
    }

    /// Re-evaluates the table and arms the one timer.
    ///
    /// Called after every input change, which is what keeps the app to a single timer: the
    /// pending fire is cancelled and replaced rather than added to.
    private func reschedule() {
        cancelTimer()
        guard isRunning else { return }

        let now = clock()
        schedule = SyncPolicy.schedule(
            conditions: conditions,
            configuration: configuration,
            // GitHub's alone. Linear's holds back its own request inside a poll rather than
            // the poll itself, because every row renders without it.
            backoff: backoffs[.github] ?? Backoff(),
            lastPollAt: lastPollAt,
            now: now
        )
        // Suspended: no interval, no timer. The next wake notification re-evaluates.
        guard let delay = schedule.delay(from: now) else { return }

        timer = Task { [weak self] in
            // Throws only on cancellation, which is how a re-schedule replaces a pending
            // fire; the guard below covers a cancellation that lands after the sleep.
            try? await Task.sleep(nanoseconds: SyncEngine.nanoseconds(delay))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Nothing legitimately waits longer than the 15-minute low-power interval, so a
    /// longer one means the system clock moved under us — a manual change, or a wake with a
    /// corrected time. Waking early costs one poll; waiting on a wrong clock costs the
    /// panel until the user notices it stopped.
    private static let maximumWait: TimeInterval = 30 * 60

    private static func nanoseconds(_ delay: TimeInterval) -> UInt64 {
        UInt64((min(max(0, delay), maximumWait) * 1_000_000_000).rounded())
    }
}
