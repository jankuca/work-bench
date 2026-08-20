import Foundation

/// The steps a poll moves through, in the order the pipeline runs them.
///
/// These are the *observable* units of a sync — the two searches, the tag comparisons and
/// the Linear resolution — not every request inside them. The panel only shows this during
/// the first sync of a launch, when there are no rows to draw yet and the empty content
/// area would otherwise say nothing more than "not synced". A steady-state poll finishes in
/// a few hundred milliseconds under an already-populated panel, so it has no use for a
/// stepper and never builds one.
///
/// `CaseIterable`'s order **is** the display order, so the two always-present searches lead
/// and the two conditional steps follow.
public enum SyncStage: String, Equatable, Sendable, CaseIterable, Hashable {
    /// The open list — the rows the panel is mostly about.
    case openPullRequests
    /// The closed/merged search behind it, bounded by the merges still waiting for a tag.
    case mergedPullRequests
    /// Comparing tags to the merges that await a release. Skipped when nothing is waiting.
    case releaseTags
    /// Resolving the Linear identifiers the pull requests name into project headings.
    /// Skipped when Linear is not configured, backing off, or there is nothing to resolve.
    case linearProjects

    /// Whether the step always runs, and so should be shown as *pending* before it begins.
    ///
    /// The two searches always run; the tag and Linear steps only run when there is work
    /// for them, and are revealed only once they actually begin — showing a step that then
    /// gets skipped is the flicker this avoids.
    public var isAlwaysRun: Bool {
        switch self {
        case .openPullRequests, .mergedPullRequests: return true
        case .releaseTags, .linearProjects: return false
        }
    }
}

/// One thing that happened to a step, emitted from wherever the work runs.
///
/// A value rather than a mutation so it can cross an actor boundary (the poll runs off the
/// main actor, the panel updates on it) and be folded into ``SyncProgress`` by a pure
/// reducer that a test can pin.
public enum SyncProgressEvent: Equatable, Sendable {
    /// The step started. `found`/`total` stay whatever they were, which is nothing yet.
    case began(SyncStage)
    /// Progress within a step: how many items are in hand, and the total when it is known.
    /// GitHub's search reports its `issueCount`, so the two searches carry a real "of N";
    /// the rest carry a running count with no denominator.
    case advanced(SyncStage, found: Int, total: Int?)
    case finished(SyncStage)
    /// The step had no work to do, so it never appears in the list.
    case skipped(SyncStage)

    public var stage: SyncStage {
        switch self {
        case .began(let stage), .finished(let stage), .skipped(let stage):
            return stage
        case .advanced(let stage, _, _):
            return stage
        }
    }
}

/// A `@Sendable` sink for ``SyncProgressEvent``s, threaded through the poll as an optional.
///
/// Optional at every call site: `nil` is the steady-state poll, which reports nothing
/// because nobody is watching a stepper. Passing one is what the first sync does.
public typealias SyncProgressReporter = @Sendable (SyncProgressEvent) -> Void

/// The state of every step of one sync, folded from the events as they arrive.
public struct SyncProgress: Equatable, Sendable {
    public enum Lifecycle: Equatable, Sendable {
        case pending
        case active
        case done
        case skipped
    }

    /// Where one step stands, and how far into it the work is.
    public struct Step: Equatable, Sendable {
        public var lifecycle: Lifecycle
        /// Items in hand. Nil until the step reports its first count.
        public var found: Int?
        /// The denominator, when the step knows one. Only the two searches do.
        public var total: Int?

        public init(lifecycle: Lifecycle = .pending, found: Int? = nil, total: Int? = nil) {
            self.lifecycle = lifecycle
            self.found = found
            self.total = total
        }
    }

    /// Keyed by stage; iterate ``SyncStage/allCases`` for display order. A stage absent from
    /// the map is ``Lifecycle/pending`` — the state it holds before any event names it.
    public private(set) var steps: [SyncStage: Step]

    public init(steps: [SyncStage: Step] = [:]) {
        self.steps = steps
    }

    /// Every step pending — the state the first frame of a sync renders from.
    public static let initial = SyncProgress()

    /// The step's state, defaulting to pending for a stage nothing has reported yet.
    public func step(_ stage: SyncStage) -> Step {
        steps[stage] ?? Step()
    }

    /// Folds one event in. Deliberately total: an `advanced` on a step nothing began yet
    /// still moves it to `active`, so a reporter that skips `began` and jumps straight to a
    /// count is not lost.
    public mutating func apply(_ event: SyncProgressEvent) {
        var step = self.step(event.stage)
        switch event {
        case .began:
            // Never walk a finished step back to active — events can arrive out of order
            // across the actor hop, and a stray `began` after a `finished` must not un-tick it.
            if step.lifecycle != .done { step.lifecycle = .active }
        case .advanced(_, let found, let total):
            if step.lifecycle != .done { step.lifecycle = .active }
            step.found = found
            // A page that does not report the count must not erase one an earlier page did.
            if let total { step.total = total }
        case .finished:
            step.lifecycle = .done
        case .skipped:
            // Only a step that never really ran is skipped; one that already finished keeps
            // its tick.
            if step.lifecycle != .done { step.lifecycle = .skipped }
        }
        steps[event.stage] = step
    }

    /// The same fold, as a value — for a caller that holds the progress by value and wants
    /// the next one back rather than mutating in place.
    public func applying(_ event: SyncProgressEvent) -> SyncProgress {
        var copy = self
        copy.apply(event)
        return copy
    }
}
