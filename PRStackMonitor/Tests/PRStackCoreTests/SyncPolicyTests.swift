import Foundation
import XCTest
@testable import PRStackCore

/// IMPLEMENTATION_PLAN §4's interval table. Several of its conditions are true at once
/// most of the time, so what is worth pinning is not each row but the **order** they are
/// tested in — which is exactly what a laptop and a stopwatch cannot check.
final class SyncPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600) // 2025-12-29T12:00:00Z

    private func cadence(_ conditions: SyncConditions) -> PollCadence {
        SyncPolicy.cadence(for: conditions, now: now)
    }

    private func onBattery(_ fraction: Double?) -> PowerState {
        PowerState(isOnBattery: true, batteryFraction: fraction)
    }

    // MARK: - The table

    /// Each row on its own, top to bottom.
    func testEveryRowOfTheTable() {
        XCTAssertEqual(cadence(SyncConditions(isSystemAsleep: true)), .suspended)
        XCTAssertEqual(cadence(SyncConditions(isDisplayAsleep: true)), .suspended)
        XCTAssertEqual(cadence(SyncConditions(power: onBattery(0.15))), .lowPower)
        XCTAssertEqual(cadence(SyncConditions(isPanelOpen: true)), .panelOpen)
        XCTAssertEqual(cadence(SyncConditions(isAwaitingRelease: true)), .awaitingRelease)
        XCTAssertEqual(
            cadence(SyncConditions(lastActivityAt: now.addingTimeInterval(-60))),
            .recentlyActive
        )
        XCTAssertEqual(cadence(SyncConditions()), .idle)
    }

    /// The two power conditions outrank everything, including an open panel: a sleeping
    /// machine polls nothing, and a low battery is not worth a 30-second loop no matter
    /// what is on screen.
    func testPowerOutranksAnOpenPanel() {
        let busy = SyncConditions(
            isPanelOpen: true,
            isAwaitingRelease: true,
            lastActivityAt: now
        )

        var asleep = busy
        asleep.isSystemAsleep = true
        XCTAssertEqual(cadence(asleep), .suspended)

        // Display sleep alone, which `willSleepNotification` never reports — without its
        // own subscription this row would poll at 30 s against a dark screen.
        var dark = busy
        dark.isDisplayAsleep = true
        XCTAssertEqual(cadence(dark), .suspended)

        var flat = busy
        flat.power = onBattery(0.05)
        XCTAssertEqual(cadence(flat), .lowPower)
    }

    /// Below those, the fastest applicable interval wins by virtue of the ordering.
    func testFasterConditionsWinBelowThePowerRows() {
        let everything = SyncConditions(
            isPanelOpen: true,
            isAwaitingRelease: true,
            lastActivityAt: now
        )
        XCTAssertEqual(cadence(everything), .panelOpen)

        var closed = everything
        closed.isPanelOpen = false
        XCTAssertEqual(cadence(closed), .awaitingRelease)

        var nothingShipping = closed
        nothingShipping.isAwaitingRelease = false
        XCTAssertEqual(cadence(nothingShipping), .recentlyActive)
    }

    /// A charge reading is only low when the machine is actually running off it, and an
    /// absent reading is not a flat battery — a power source this build cannot parse must
    /// not park a plugged-in Mac at 15 minutes forever.
    func testLowBatteryNeedsBothHalves() {
        XCTAssertEqual(
            cadence(SyncConditions(power: PowerState(isOnBattery: false, batteryFraction: 0.05))),
            .idle
        )
        XCTAssertEqual(cadence(SyncConditions(power: onBattery(nil))), .idle)
        // The threshold is a floor to be below, not to reach.
        XCTAssertEqual(cadence(SyncConditions(power: onBattery(0.2))), .idle)
        XCTAssertEqual(cadence(SyncConditions(power: onBattery(0.199))), .lowPower)
    }

    func testActivityWindowIsFifteenMinutes() {
        let inside = SyncConditions(lastActivityAt: now.addingTimeInterval(-(15 * 60 - 1)))
        let outside = SyncConditions(lastActivityAt: now.addingTimeInterval(-15 * 60))
        XCTAssertEqual(cadence(inside), .recentlyActive)
        XCTAssertEqual(cadence(outside), .idle)
    }

    func testIntervalsAreThePlansNumbers() {
        let configuration = SyncConfiguration.standard
        XCTAssertNil(configuration.interval(for: .suspended))
        XCTAssertEqual(configuration.interval(for: .lowPower), 15 * 60)
        XCTAssertEqual(configuration.interval(for: .panelOpen), 30)
        XCTAssertEqual(configuration.interval(for: .awaitingRelease), 60)
        XCTAssertEqual(configuration.interval(for: .recentlyActive), 2 * 60)
        XCTAssertEqual(configuration.interval(for: .idle), 5 * 60)
    }

    // MARK: - Scheduling

    private func schedule(
        _ conditions: SyncConditions,
        backoff: Backoff = Backoff(),
        lastPollAt: Date?,
        at instant: Date? = nil
    ) -> SyncSchedule {
        SyncPolicy.schedule(
            conditions: conditions,
            backoff: backoff,
            lastPollAt: lastPollAt,
            now: instant ?? now
        )
    }

    /// The icon has to mean something before the first interval has elapsed.
    func testTheFirstPollOfALaunchIsDueImmediately() {
        let scheduled = schedule(SyncConditions(), lastPollAt: nil)
        XCTAssertEqual(scheduled.cadence, .idle)
        XCTAssertEqual(scheduled.delay(from: now), 0)
    }

    /// Measured from when the last poll *started*: a poll that took four seconds does not
    /// push the next one four seconds later.
    func testTheIntervalRunsFromTheLastPollsStart() {
        let scheduled = schedule(
            SyncConditions(isPanelOpen: true),
            lastPollAt: now.addingTimeInterval(-10)
        )
        XCTAssertEqual(scheduled.cadence, .panelOpen)
        XCTAssertEqual(scheduled.delay(from: now), 20)
    }

    func testSuspendedSchedulesNothingAtAll() {
        let scheduled = schedule(
            SyncConditions(isSystemAsleep: true),
            lastPollAt: now.addingTimeInterval(-3600)
        )
        XCTAssertNil(scheduled.interval)
        XCTAssertNil(scheduled.nextPollAt)
        XCTAssertNil(scheduled.delay(from: now))
    }

    /// Waking is not a special case in the scheduler, and deliberately so: after a night
    /// asleep the last poll is older than any interval, so the first schedule computed
    /// after the wake is already overdue and fires at once.
    func testWakingIsOverdueRatherThanSpecialCased() {
        let scheduled = schedule(SyncConditions(), lastPollAt: now.addingTimeInterval(-8 * 3600))
        XCTAssertEqual(scheduled.delay(from: now), 0)
    }

    /// Backoff moves the instant, never the cadence: a failing source does not get polled
    /// sooner because the panel opened, and a healthy interval is never shortened by it.
    func testBackoffOnlyEverPushesThePollLater() throws {
        var backoff = Backoff()
        backoff.recordFailure(at: now, jitter: 0.5) // 30 s, no spread

        // The interval alone would poll in five seconds.
        let held = schedule(
            SyncConditions(isPanelOpen: true),
            backoff: backoff,
            lastPollAt: now.addingTimeInterval(-25)
        )
        XCTAssertEqual(held.cadence, .panelOpen)
        XCTAssertEqual(held.interval, 30)
        XCTAssertTrue(held.isHeldByBackoff)
        XCTAssertEqual(try XCTUnwrap(held.delay(from: now)), 30, accuracy: 0.001)

        // The same hold once its instant has passed: the interval decides again, and
        // nothing claims to be waiting on a source.
        let later = now.addingTimeInterval(45)
        let free = schedule(
            SyncConditions(isPanelOpen: true),
            backoff: backoff,
            lastPollAt: now.addingTimeInterval(-25),
            at: later
        )
        XCTAssertFalse(free.isHeldByBackoff)
        XCTAssertEqual(free.delay(from: later), 0)
    }

    /// A backoff shorter than the interval it is competing with changes nothing — the
    /// slower of the two always wins.
    func testAShortHoldDoesNotShortenTheInterval() {
        var backoff = Backoff()
        backoff.recordFailure(at: now, jitter: 0.5) // 30 s

        let scheduled = schedule(SyncConditions(), backoff: backoff, lastPollAt: now)
        XCTAssertFalse(scheduled.isHeldByBackoff)
        XCTAssertEqual(scheduled.delay(from: now), 5 * 60)
    }
}

/// The per-source retry delay: what it waits, how it spreads, and what it refuses to
/// retry at all.
final class BackoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600)

    private func seconds(_ backoff: Backoff) throws -> TimeInterval {
        try XCTUnwrap(backoff.retryAt).timeIntervalSince(now)
    }

    func testDelayDoublesUpToTheCeiling() {
        let backoff = Backoff()
        XCTAssertEqual(backoff.delay(afterFailures: 0), 0)
        XCTAssertEqual(backoff.delay(afterFailures: 1), 30)
        XCTAssertEqual(backoff.delay(afterFailures: 2), 60)
        XCTAssertEqual(backoff.delay(afterFailures: 5), 480)
        XCTAssertEqual(backoff.delay(afterFailures: 6), 600)
        // `pow` overflows to infinity long before this; the ceiling still answers.
        XCTAssertEqual(backoff.delay(afterFailures: 4_000), 600)
    }

    func testConsecutiveFailuresEscalateAndSuccessResets() throws {
        var backoff = Backoff()
        backoff.recordFailure(at: now, jitter: 0.5)
        XCTAssertEqual(backoff.failureCount, 1)
        XCTAssertEqual(try seconds(backoff), 30, accuracy: 0.001)

        backoff.recordFailure(at: now, jitter: 0.5)
        XCTAssertEqual(backoff.failureCount, 2)
        XCTAssertEqual(try seconds(backoff), 60, accuracy: 0.001)

        backoff.clear()
        XCTAssertEqual(backoff.failureCount, 0)
        XCTAssertNil(backoff.retryAt)
        XCTAssertFalse(backoff.isHolding(at: now))

        // And the next failure starts from the first delay again, not from where it left off.
        backoff.recordFailure(at: now, jitter: 0.5)
        XCTAssertEqual(try seconds(backoff), 30, accuracy: 0.001)
    }

    /// Two machines that lost the same network at the same moment must not come back at
    /// the same instant, which is the whole point of jittering a fixed schedule.
    func testJitterSpreadsEitherSideOfTheDelay() throws {
        var low = Backoff()
        low.recordFailure(at: now, jitter: 0)
        var middle = Backoff()
        middle.recordFailure(at: now, jitter: 0.5)
        var high = Backoff()
        high.recordFailure(at: now, jitter: 1)

        XCTAssertEqual(try seconds(low), 24, accuracy: 0.001)
        XCTAssertEqual(try seconds(middle), 30, accuracy: 0.001)
        XCTAssertEqual(try seconds(high), 36, accuracy: 0.001)

        // A caller handing over a value from some other range should wait a jittered
        // delay, not a negative one.
        var wild = Backoff()
        wild.recordFailure(at: now, jitter: -4)
        XCTAssertEqual(try seconds(wild), 24, accuracy: 0.001)
    }

    func testHoldsUntilTheRetryInstantAndNoLonger() {
        var backoff = Backoff()
        backoff.recordFailure(at: now, jitter: 0.5)

        XCTAssertTrue(backoff.isHolding(at: now))
        XCTAssertTrue(backoff.isHolding(at: now.addingTimeInterval(29)))
        XCTAssertFalse(backoff.isHolding(at: now.addingTimeInterval(31)))
    }

    /// GitHub answers a secondary rate limit with `Retry-After` and a spent allowance with a
    /// reset instant. The table knows neither, so without this a poll told "not for another
    /// ten minutes" would come back in thirty seconds — which is how an app earns a longer
    /// block than the one it was given.
    func testTheServicesOwnRetryInstantWinsWhenItIsLater() throws {
        var backoff = Backoff()
        backoff.recordFailure(at: now, jitter: 0.5, notBefore: now.addingTimeInterval(600))
        XCTAssertEqual(try seconds(backoff), 600, accuracy: 0.001)
    }

    /// And only when it is later. A reset five seconds out does not shorten the 30 seconds the
    /// table asks for: one failure is one failure whatever the allowance says.
    func testTheTableWinsWhenTheServicesInstantIsSooner() throws {
        var backoff = Backoff()
        backoff.recordFailure(at: now, jitter: 0.5, notBefore: now.addingTimeInterval(5))
        XCTAssertEqual(try seconds(backoff), 30, accuracy: 0.001)
    }

    /// A `Retry-After` of a week — or a reset read from a header something mangled — must not
    /// park the app for a week. An app that has stopped polling looks exactly like an app that
    /// has stopped working.
    func testAnAbsurdRetryInstantIsClamped() throws {
        var backoff = Backoff()
        backoff.recordFailure(at: now, jitter: 0.5, notBefore: now.addingTimeInterval(7 * 24 * 3_600))
        XCTAssertEqual(try seconds(backoff), Backoff.maximumHonouredHold, accuracy: 0.001)
    }

    /// Only 5xx and network failures. No delay makes a rejected token work: the banner
    /// asks the user to fix it, and fixing it in Settings polls immediately.
    func testOnlyTransientFailuresBackOff() {
        XCTAssertTrue(Backoff.backsOff(.unreachable("the request timed out")))
        XCTAssertFalse(Backoff.backsOff(.unauthorized("bad credentials")))
        XCTAssertFalse(Backoff.backsOff(.unconfigured))
        XCTAssertFalse(Backoff.backsOff(.connected))
    }
}
