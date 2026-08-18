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

    /// Fired when the *cadence* changes — not on every reschedule, which happens on every
    /// condition change and every tick.
    ///
    /// The panel reads ``schedule`` for its staleness threshold, and the two conditions
    /// that move it come from the machine rather than from a poll: unplugging a
    /// nearly-flat laptop, and waking one. Without this the footer would go on measuring
    /// against the previous interval until something else happened to rebuild it — which,
    /// at the 15-minute low-power interval, is exactly as long as the wrong threshold is
    /// most visible.
    var onCadenceChange: () -> Void = {}

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

    /// The two monitors are `nil`-defaulted and built in the body rather than defaulted to
    /// `PowerMonitor()` / `SleepMonitor()` in the signature.
    ///
    /// Both are `@MainActor` types, and a default argument is evaluated in the *caller's*
    /// context, which is nonisolated unless the language mode says otherwise — building one
    /// there is a call into the main actor from outside it. Swift 6 fixed this by giving
    /// default expressions the callee's isolation, but this package builds in the Swift 5
    /// language mode, where recent compilers have promoted the diagnostic from a warning to
    /// an error. The init body is isolated, so moving the construction into it costs one
    /// `??` per parameter and keeps the injection seam the tests use.
    init(
        configuration: SyncConfiguration = .standard,
        power: PowerMonitor? = nil,
        sleep: SleepMonitor? = nil,
        clock: @escaping () -> Date = { Date() },
        jitter: @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        self.configuration = configuration
        self.power = power ?? PowerMonitor()
        self.sleep = sleep ?? SleepMonitor()
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
        let wasAsleep = conditions.isAsleep
        conditions.isSystemAsleep = sleep.isSystemAsleep
        conditions.isDisplayAsleep = sleep.isDisplayAsleep
        conditions.power = power.read()

        // "Waking from sleep syncs immediately, then re-evaluates the table from the top"
        // (IMPLEMENTATION_PLAN §4) — unconditionally, which is why this is a branch rather
        // than a consequence of the arithmetic. After a night asleep the last poll is older
        // than any interval and the schedule below would be overdue anyway; after a
        // thirty-second display sleep it would not, and the panel the user is looking
        // straight at would wait out the rest of an interval before checking. Forgetting
        // the last poll is what makes both cases the same case.
        //
        // A backoff still holds through it: the schedule takes the later of the interval and
        // the retry instant, so a source that is failing is not hammered by a lid.
        if wasAsleep, !conditions.isAsleep { lastPollAt = nil }
        reschedule()
    }

    // MARK: - Results

    /// Folds one source's outcome into its backoff.
    ///
    /// Only a transient failure escalates. A rejected credential is not retried into
    /// submission — see ``Backoff/backsOff(_:)`` — and a source that has not been asked at
    /// all this poll keeps whatever hold it already had, since nothing was learned.
    ///
    /// Every other answer **clears** the hold, not just a healthy one. A `401` is an answer:
    /// the service was reached and replied, so a delay earned by an earlier timeout is
    /// describing a network that is demonstrably working again. Left in place it would hold
    /// back the poll that comes after the user pastes a new token, which is the one poll that
    /// matters at that moment.
    ///
    /// `notBefore` is when the service said it would answer again — a `Retry-After` on a
    /// secondary rate limit, or the instant the hourly allowance resets. The interval table
    /// does not know about either, so without this a poll blocked for the next ten minutes
    /// would be retried in thirty seconds; ``Backoff/recordFailure(at:jitter:notBefore:)``
    /// takes whichever is later.
    func record(_ health: SourceHealth, for source: EventSource, notBefore: Date? = nil) {
        guard !health.isConnected, Backoff.backsOff(health) else {
            guard backoffs.removeValue(forKey: source) != nil else { return }
            reschedule()
            return
        }
        var backoff = backoffs[source] ?? Backoff()
        backoff.recordFailure(at: clock(), jitter: jitter(), notBefore: notBefore)
        backoffs[source] = backoff
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
        // Dropped rather than reset in place, the same way ``record(_:for:)`` retires one:
        // an absent entry and a cleared one behave identically, and having only one spelling
        // of "not backing off" is what keeps them that way.
        for key in EventSource.allCases where source == nil || source == key {
            backoffs[key] = nil
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
    ///
    /// `lastPollAt` is when a poll was last **attempted**, not when one last started a
    /// request. The two differ only when a tick lands while the previous poll is still in
    /// flight, and the panel controller declines to start a second — which costs that tick,
    /// deliberately. The alternatives are both worse: not consuming the cadence leaves the
    /// next fire permanently overdue and spins the timer against a poll that has not
    /// finished, and re-firing the moment it does turns a run of requests slower than the
    /// interval into near-continuous polling against the hourly allowance. A skip is
    /// bounded — every request carries a 30-second timeout, so the poll holding the slot
    /// ends, and the tick after it starts normally.
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
        let previous = schedule
        schedule = SyncPolicy.schedule(
            conditions: conditions,
            configuration: configuration,
            // GitHub's alone. Linear's holds back its own request inside a poll rather than
            // the poll itself, because every row renders without it.
            backoff: backoffs[.github] ?? Backoff(),
            lastPollAt: lastPollAt,
            now: now
        )
        // The cadence, not the whole schedule: `nextPollAt` moves on every tick and means
        // nothing to the panel, so comparing the value would make this fire constantly.
        if schedule.cadence != previous.cadence { onCadenceChange() }
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
