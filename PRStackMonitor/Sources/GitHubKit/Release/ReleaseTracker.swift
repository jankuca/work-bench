import Foundation
import PRStackCore

/// What one poll learned about releases.
///
/// A **value**, handed back to whoever owns `LocalState`, rather than a write. `LocalState`
/// is a single value owned by the main actor and written whole, so the tracker returning
/// its findings — instead of writing the state file from its own task — is what keeps the
/// single-writer rule true. Two writers holding partial copies is how a dismissal
/// disappears behind a binding (IMPLEMENTATION_PLAN §3).
public struct ReleaseTrackerResult: Equatable, Sendable {
    /// Pull requests that shipped, and the tag they shipped in. Permanent once applied.
    public var bindings: [PRID: String]
    /// Tags tested against a pull request's merge commit and found **not** to contain it.
    /// Persisting these is what stops the same pair being compared on every poll forever.
    public var comparisons: [PRID: Set<String>]
    /// The newest release of each repository a `next release` snooze is watching, keyed by
    /// `owner/name`. A repository whose tags could not be read completely is left out, so
    /// its snoozes neither take a baseline nor wake on a partial list.
    public var latestReleases: [String: ReleaseMark]
    /// How many `compare` requests this poll actually spent.
    public var comparisonsMade: Int
    /// GraphQL points spent reading tags.
    public var pointsSpent: Int
    public var rateLimit: RateLimit?
    public var restRateLimit: RESTRateLimit?
    public var warnings: [FetchWarning]

    public init(
        bindings: [PRID: String] = [:],
        comparisons: [PRID: Set<String>] = [:],
        latestReleases: [String: ReleaseMark] = [:],
        comparisonsMade: Int = 0,
        pointsSpent: Int = 0,
        rateLimit: RateLimit? = nil,
        restRateLimit: RESTRateLimit? = nil,
        warnings: [FetchWarning] = []
    ) {
        self.bindings = bindings
        self.comparisons = comparisons
        self.latestReleases = latestReleases
        self.comparisonsMade = comparisonsMade
        self.pointsSpent = pointsSpent
        self.rateLimit = rateLimit
        self.restRateLimit = restRateLimit
        self.warnings = warnings
    }

    public static let empty = ReleaseTrackerResult()

    public var isEmpty: Bool {
        bindings.isEmpty && comparisons.isEmpty && latestReleases.isEmpty && warnings.isEmpty
    }
}

/// How the app finds out that a merged pull request has shipped.
///
/// v1's implementation is ``TagContainmentTracker``: shipped means the merge commit is
/// contained in a tag matching the repository's pattern, and nothing else — no Deployments
/// API, no workflow runs, no deploy outcome. The protocol is the seam a
/// `DeploymentAPITracker` would slot into later. What that would still touch, honestly:
/// `RowStatus` gains a `deployFailed` case in the attention set, and the icon regains its
/// amber in-flight state. The data path and the segment rendering are ready; the attention
/// rules are not (IMPLEMENTATION_PLAN §3).
public protocol ReleaseTracker {
    /// Tests every unbound merge against the releases its repository has cut since.
    ///
    /// Throws only for failures that end the poll — an expired token, an exhausted
    /// allowance, cancellation. Anything narrower (one unreachable repository, one
    /// comparison that 404s) comes back as a warning, because the other repositories'
    /// merges are still perfectly bindable.
    func poll(unbound: [PRID: UnboundMerge], now: Date) async throws -> ReleaseTrackerResult

    /// The newest release each of `repositories` has, for the `next release` snoozes.
    ///
    /// Answers in ``ReleaseTrackerResult/latestReleases`` and spends nothing on
    /// comparisons. Throws on the same terms as ``poll(unbound:now:)``.
    func latestReleases(in repositories: Set<String>) async throws -> ReleaseTrackerResult
}

extension ReleaseTracker {
    /// A tracker that cannot list releases answers with nothing, which leaves every
    /// `next release` snooze asleep until the user wakes it.
    public func latestReleases(in repositories: Set<String>) async throws -> ReleaseTrackerResult {
        .empty
    }
}

extension ReleaseTrackerResult {
    /// Folds a second answer from the same tracker into this one — the release watch's,
    /// into the comparisons' — so the poll reports one release result.
    public mutating func merge(_ other: ReleaseTrackerResult) {
        bindings.merge(other.bindings) { first, _ in first }
        comparisons.merge(other.comparisons) { $0.union($1) }
        latestReleases.merge(other.latestReleases) { _, last in last }
        comparisonsMade += other.comparisonsMade
        pointsSpent += other.pointsSpent
        rateLimit = other.rateLimit ?? rateLimit
        restRateLimit = other.restRateLimit ?? restRateLimit
        warnings += other.warnings
    }
}

extension LocalState {
    /// Merges a tracker's findings in. The one place release bindings enter local state.
    ///
    /// Bindings first, then negatives: binding retires a pull request's unbound record, and
    /// ``recordComparison(_:against:)`` is a no-op once it is gone — so a tag that came back
    /// negative for a pull request that bound to a *different* tag in the same poll leaves
    /// nothing behind.
    public mutating func apply(_ result: ReleaseTrackerResult) {
        for (id, tag) in result.bindings {
            bind(id, toRelease: tag)
        }
        for (id, tags) in result.comparisons {
            for tag in tags { recordComparison(id, against: tag) }
        }
        observeReleases(result.latestReleases)
    }
}
