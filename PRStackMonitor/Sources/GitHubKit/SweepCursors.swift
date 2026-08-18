import Foundation

/// Where a poll's two searches stopped, so the next one can carry on from there rather than
/// walking the same pages again.
///
/// Every bound in ``GitHubClient`` — the page cap, the point budget, the rate limit floor,
/// and now a page GitHub would not answer — stops pagination and hands back a cursor. Until
/// this existed nothing carried that cursor anywhere: each poll started at page one, so an
/// account whose sweep takes eight pages re-fetched the first seven every time, and the poll
/// most likely to be cut short was the one that paid the most to get where it was cut.
///
/// Resuming is deliberately not free of caveats, and the two that matter are handled here.
/// A cursor is a position in **one** result set, so it is only valid for the search that
/// produced it (``fingerprint``); and a resumed sweep by definition never looks at the early
/// pages, so it cannot be allowed to run forever (``maximumResumes``) or to replace the
/// panel's rows wholesale — the caller merges a resumed sweep over what it already has
/// rather than treating it as the whole picture.
public struct SweepCursors: Equatable, Sendable {
    /// How many polls in a row may resume before one starts at page one again.
    ///
    /// A resumed sweep reads the *end* of the list, so a pull request that has since sorted
    /// onto page one is invisible to it. The priority refresh covers the rows already on
    /// screen while that is true, but nothing covers a row that is new, so the chain has to
    /// end: five polls is long enough to finish any sweep the page cap allows and short
    /// enough that a genuinely new pull request is never more than a few minutes late.
    public static let maximumResumes = 5

    /// Which searches these cursors belong to.
    ///
    /// The scope changing, the drafts preference flipping and the closed search's lower
    /// bound rolling onto a new day all make a *different* search, and resuming one search
    /// from another's position would silently skip everything the change brought in.
    public var fingerprint: String
    /// Where the open search stopped, or nil when it ran to completion.
    public var open: String?
    /// Where the closed search stopped, or nil when it ran to completion.
    public var closed: String?
    /// How many polls in a row have already resumed.
    public var resumes: Int

    public init(fingerprint: String, open: String? = nil, closed: String? = nil, resumes: Int = 0) {
        self.fingerprint = fingerprint
        self.open = open
        self.closed = closed
        self.resumes = resumes
    }

    /// Nothing to resume: the state of a first poll, of a completed sweep, and of a sweep
    /// whose searches no longer match the ones these cursors came from.
    public static let none = SweepCursors(fingerprint: "")

    /// Whether either search has somewhere to pick up from.
    public var isResumable: Bool { open != nil || closed != nil }

    /// These cursors if they still apply to `fingerprint` and the chain has not run too
    /// long, and ``none`` otherwise — which is a poll that starts at page one.
    public func usable(for fingerprint: String) -> SweepCursors {
        guard isResumable,
              self.fingerprint == fingerprint,
              resumes < SweepCursors.maximumResumes else { return .none }
        return self
    }

    /// What to hand the *next* poll after a sweep that resumed `previous` stopped here.
    ///
    /// Both searches complete answers ``none``, which is what resets the chain: a sweep that
    /// reached the end of both lists has no position worth keeping, and the poll after it
    /// starts at page one with everything on screen re-checked.
    static func next(
        fingerprint: String,
        open: String?,
        closed: String?,
        after previous: SweepCursors
    ) -> SweepCursors {
        guard open != nil || closed != nil else { return .none }
        return SweepCursors(
            fingerprint: fingerprint,
            open: open,
            closed: closed,
            resumes: previous.isResumable ? previous.resumes + 1 : 0
        )
    }
}
