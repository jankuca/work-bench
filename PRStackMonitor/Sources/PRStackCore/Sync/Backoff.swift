import Foundation

/// One source's retry delay after a transient failure, held per integration and never
/// globally (IMPLEMENTATION_PLAN §4).
///
/// Pure: the delay is a function of the failure count, and both the clock and the jitter
/// are passed in. Randomness is the caller's — `SyncEngine` hands it
/// `Double.random(in: 0...1)` — so a test can pin the exact instant a fifth failure
/// retries at, which is the only way the ceiling and the spread can be asserted at all.
public struct Backoff: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        /// What the first failure waits. Long enough not to hammer a service that just
        /// 500'd, short enough that a one-off blip costs at most one skipped interval.
        public var first: TimeInterval
        public var multiplier: Double
        /// The longest a source is ever left alone. Ten minutes is two idle intervals: past
        /// that, the panel is not "briefly behind", it is not syncing, and the footer's
        /// staleness is doing the reporting either way.
        public var ceiling: TimeInterval
        /// How far either side of the delay the jitter reaches, as a fraction of it. Two
        /// machines that lost the same network at the same moment come back at different
        /// times, which is the entire point of jittering a fixed schedule.
        public var jitterFraction: Double

        public init(
            first: TimeInterval = 30,
            multiplier: Double = 2,
            ceiling: TimeInterval = 10 * 60,
            jitterFraction: Double = 0.2
        ) {
            self.first = first
            self.multiplier = multiplier
            self.ceiling = ceiling
            self.jitterFraction = jitterFraction
        }

        public static let standard = Configuration()
    }

    public var configuration: Configuration
    /// Consecutive transient failures. Reset by any success.
    public private(set) var failureCount: Int
    /// The instant this source may be tried again, or nil when it is not backing off.
    public private(set) var retryAt: Date?

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
        failureCount = 0
        retryAt = nil
    }

    /// Whether this health is the kind that backs off.
    ///
    /// Only ``SourceHealth/unreachable`` — 5xx, timeouts, a rate limit. An expired
    /// credential is not retried into submission: no delay makes a rejected token work, the
    /// banner already asks the user to fix it, and fixing it in Settings polls immediately.
    /// So an unauthorized source keeps the interval table's cadence and nothing more.
    public static func backsOff(_ health: SourceHealth) -> Bool {
        if case .unreachable = health { return true }
        return false
    }

    /// The un-jittered delay a given consecutive-failure count waits: `first` doubling to
    /// `ceiling`. Failure 0 — no failure — waits nothing.
    public func delay(afterFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        let growth = pow(configuration.multiplier, Double(count - 1))
        // `pow` overflows to infinity long before this matters, and `min` handles that
        // correctly — the ceiling is the answer either way.
        return min(configuration.ceiling, configuration.first * growth)
    }

    /// Records a failure and arms the next retry. `jitter` is `0...1`, and values outside
    /// it are clamped rather than trusted — a caller that hands over a raw random `Double`
    /// from some other range should wait a jittered delay, not a negative one.
    public mutating func recordFailure(at now: Date, jitter: Double) {
        failureCount += 1
        let delay = delay(afterFailures: failureCount)
        let spread = (min(max(jitter, 0), 1) * 2 - 1) * configuration.jitterFraction
        retryAt = now.addingTimeInterval(max(0, delay * (1 + spread)))
    }

    /// Success, a manual reconnect, or a credential change: this source is no longer
    /// waiting, and its next failure starts again at ``Configuration/first``.
    public mutating func clear() {
        failureCount = 0
        retryAt = nil
    }

    /// Whether the next attempt is still in the future.
    public func isHolding(at now: Date) -> Bool {
        guard let retryAt else { return false }
        return now < retryAt
    }
}
