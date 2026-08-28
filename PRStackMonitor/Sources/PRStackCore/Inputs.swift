import Foundation

/// Everything the network layers produced for one poll, already mapped into domain types.
///
/// `PRStackCore` never fetches this; `SyncEngine` assembles it from `GitHubKit` and
/// `LinearKit` and hands it to ``Derivation/derive(snapshot:local:now:)``.
public struct RawSnapshot: Equatable, Sendable {
    /// The authenticated user. Only this user's pull requests may act as stack parents.
    public var viewerLogin: String
    public var pullRequests: [PullRequest]

    public init(viewerLogin: String, pullRequests: [PullRequest]) {
        self.viewerLogin = viewerLogin
        // Fixtures and call sites routinely omit the author because the GitHub search is
        // scoped to `author:@me`; an absent author means "the viewer".
        self.pullRequests = pullRequests.map { pullRequest in
            guard pullRequest.authorLogin.isEmpty else { return pullRequest }
            var normalized = pullRequest
            normalized.authorLogin = viewerLogin
            return normalized
        }
    }
}

extension RawSnapshot {
    /// This snapshot with `refreshed` in place of the rows it names, and everything else
    /// left exactly as it was.
    ///
    /// What a priority refresh lands with. It answers for the rows it was asked about and
    /// for nothing else, so it cannot *replace* a snapshot — doing that would empty the
    /// panel of every row the refresh did not cover, which on a large account is most of
    /// them. Rows it names are updated in place, keeping their position; rows it does not
    /// are untouched; rows the snapshot has never seen — every row, on the first poll after
    /// a launch — are appended in the order given.
    ///
    /// `viewerLogin` is the login the refresh answered as, and is used only when this
    /// snapshot does not have one yet. That is the launch case again: the panel starts with
    /// no viewer, and derivation needs one before it can tell the user's own pull requests
    /// from anybody else's.
    public func replacing(
        _ refreshed: [PullRequest],
        viewerLogin: String? = nil
    ) -> RawSnapshot {
        var login = self.viewerLogin
        if login.isEmpty, let viewerLogin { login = viewerLogin }
        guard !refreshed.isEmpty else {
            return RawSnapshot(viewerLogin: login, pullRequests: pullRequests)
        }

        var byID = Dictionary(refreshed.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var merged: [PullRequest] = []
        merged.reserveCapacity(pullRequests.count + refreshed.count)

        for existing in pullRequests {
            merged.append(byID.removeValue(forKey: existing.id) ?? existing)
        }
        // Whatever is left over was not in the snapshot at all. Appended in the order it
        // was given rather than in the order a dictionary iterates, so two runs of the same
        // poll produce the same snapshot — and appended as the *map* holds it, which is the
        // last copy of a repeated id. The loop above hands back that same copy, and two
        // paths disagreeing about which version of a duplicated row wins is a difference
        // that would only ever show up as one stale row, once, unreproducibly.
        for pullRequest in refreshed {
            guard let latest = byID.removeValue(forKey: pullRequest.id) else { continue }
            merged.append(latest)
        }

        return RawSnapshot(viewerLogin: login, pullRequests: merged)
    }
}

extension RawSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case viewerLogin
        case pullRequests
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            viewerLogin: try container.decode(String.self, forKey: .viewerLogin),
            pullRequests: try container.decodeIfPresent([PullRequest].self, forKey: .pullRequests) ?? []
        )
    }
}

/// A digest of the fields whose change makes a row unread.
///
/// The value is a canonical string, not a hash: Swift's `hashValue` is seeded per
/// process, so a hash-based digest would differ on every launch and mark the whole
/// panel unread on relaunch.
public struct ReadDigest: Hashable, Sendable, Codable {
    public let value: String

    public init(value: String) {
        self.value = value
    }

    /// The digest of `(reviewDecision, checkRollup, mergeable, commentCount,
    /// lastCommentAt, releaseStage)`, plus draft state — IMPLEMENTATION_PLAN §2.
    ///
    /// The draft marker is **only present while the pull request is a draft**, rather than
    /// being a seventh `dr=` part that is always there. Two things fall out of that, and
    /// both are the point:
    ///
    /// - With drafts off, every digest is byte for byte what it was before drafts existed,
    ///   so upgrading does not invalidate the persisted digests and mark the whole panel
    ///   unread for people who never asked for this.
    /// - Marking a draft ready for review changes the digest with nothing else about the
    ///   pull request having moved, which is what puts the unread dot on it. That
    ///   transition is one the panel is *for* — with drafts off it shows up as the row
    ///   appearing, and with drafts on the row is already there, so it needs to be said
    ///   some other way.
    public static func make(for pullRequest: PullRequest, releaseStage: ReleaseStage) -> ReadDigest {
        let lastComment = pullRequest.lastCommentAt.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "-"
        var parts = [
            "rd=" + (pullRequest.reviewDecision?.rawValue ?? "-"),
            "ck=" + pullRequest.checks.digestToken,
            "mg=" + pullRequest.mergeable.rawValue,
            "cc=\(pullRequest.commentCount)",
            "lc=" + lastComment,
            "rs=" + releaseStage.digestToken
        ]
        if pullRequest.isDraft { parts.append("dr=1") }
        return ReadDigest(value: parts.joined(separator: ";"))
    }
}

/// A merged pull request that has not been matched to a release tag yet.
///
/// Persisted indefinitely, which is the whole point: a release cut six weeks after the
/// merge still binds and still flips the row to shipped. It is also what gives the
/// merged-pull-request query its lower bound — without the record, the merge ages out of
/// the query, its commit is lost, and the row strands at `merged · awaiting release`
/// forever (IMPLEMENTATION_PLAN §3, §7).
public struct UnboundMerge: Equatable, Sendable {
    /// The commit a tag has to contain for this pull request to count as shipped.
    public var mergeCommit: String
    public var mergedAt: Date
    /// Tags already tested against ``mergeCommit`` and found not to contain it.
    ///
    /// A negative has to be as durable as a positive. Without this set an unbound merge
    /// re-tests every candidate tag on every poll — N unbound pull requests × K candidate
    /// tags *per poll*, forever. The set is bounded by the tags cut since the merge and is
    /// discarded the moment the pull request binds.
    public var comparedTags: Set<String>

    public init(mergeCommit: String, mergedAt: Date, comparedTags: Set<String> = []) {
        self.mergeCommit = mergeCommit
        self.mergedAt = mergedAt
        self.comparedTags = comparedTags
    }
}

extension UnboundMerge: Codable {
    private enum CodingKeys: String, CodingKey {
        case mergeCommit
        case mergedAt
        case comparedTags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mergeCommit: try container.decode(String.self, forKey: .mergeCommit),
            mergedAt: try container.decode(Date.self, forKey: .mergedAt),
            comparedTags: Set(try container.decodeIfPresent([String].self, forKey: .comparedTags) ?? [])
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mergeCommit, forKey: .mergeCommit)
        try container.encode(mergedAt, forKey: .mergedAt)
        // Sorted, because a `Set` iterates in a per-process order and this file is meant to
        // be diffable between two writes of the same state.
        try container.encode(comparedTags.sorted(), forKey: .comparedTags)
    }
}

/// Everything persisted between launches that derivation reads.
///
/// Note what is *not* here: the previous ``PanelModel``. That is held in memory by
/// `SyncEngine` and never written to disk, so a relaunch replays no history.
public struct LocalState: Equatable, Sendable {
    /// Permanent tombstones. A dismissed pull request is suppressed forever, even if a
    /// later event touches it (PRD §5.3).
    public var dismissed: Set<PRID>
    /// Wake times. A row is suppressed while `now < deadline`.
    public var snoozedUntil: [PRID: Date]
    /// The digest recorded the last time the panel was open, or `Mark all read` was used.
    public var readDigests: [PRID: ReadDigest]
    /// Permanent pull request → release tag bindings, written by the release tracker at M6.
    public var releaseBindings: [PRID: String]
    /// Merged pull requests still waiting for a tag, keyed the same way as everything else.
    public var unboundMerges: [PRID: UnboundMerge]
    /// What became of the branch a nested merge landed on, for the chains the snapshot
    /// cannot follow on its own — see ``MergeAnchor``.
    ///
    /// Persisted for the same reason the bindings are. A settled answer is a fact about a
    /// pull request that has already merged, so re-asking GitHub for it on every launch
    /// would spend a request to learn something that cannot have changed.
    public var mergeAnchors: [PRID: MergeAnchor]
    /// The rows the panel last drew, in the order the next poll should refresh them.
    ///
    /// The one entry here that is not the user's own doing, and the only one that is a
    /// *cache* rather than a decision: nothing derivation reads depends on it, and losing
    /// the whole list costs one slow poll and nothing else.
    ///
    /// It is persisted for the launch case. A poll that knows which rows were on screen can
    /// ask for those directly, in one request, before it starts paging through everything
    /// in scope — and the launch after a quit is precisely when the panel is empty and the
    /// sweep is longest. Held only in memory it would help every poll except the first,
    /// which is the one that needs it most.
    public var displayed: [PRID]

    public init(
        dismissed: Set<PRID> = [],
        snoozedUntil: [PRID: Date] = [:],
        readDigests: [PRID: ReadDigest] = [:],
        releaseBindings: [PRID: String] = [:],
        unboundMerges: [PRID: UnboundMerge] = [:],
        mergeAnchors: [PRID: MergeAnchor] = [:],
        displayed: [PRID] = []
    ) {
        self.dismissed = dismissed
        self.snoozedUntil = snoozedUntil
        self.readDigests = readDigests
        self.releaseBindings = releaseBindings
        self.unboundMerges = unboundMerges
        self.mergeAnchors = mergeAnchors
        self.displayed = displayed
    }

    public static let empty = LocalState()

    /// How many ids ``recordDisplayed(from:limit:)`` keeps.
    ///
    /// The refresh that reads them asks for all of them in a single request, so the cap is
    /// what fits in one: fifty, which is also the search's page size. `GitHubKit` owns that
    /// number for its own query and this module cannot name it — `PRStackCore` sits
    /// underneath it and stays there — so the two are written down twice and agree by
    /// intent. A panel with more than fifty rows is one nobody is reading past anyway.
    public static let displayedLimit = 50

    /// Records the rows the panel is showing, in refresh priority order.
    ///
    /// The order is the answer to "if only some of these can be refreshed, which ones":
    /// open pull requests before terminal ones, because a merged row's status cannot change
    /// again while a review can arrive on an open one any second; then most recently
    /// updated first, because that is where activity is; then the panel's own ordering as a
    /// tie-break, so the list is a function of the snapshot rather than of the order GitHub
    /// happened to answer in — a list that reshuffled itself between polls would rewrite the
    /// state file on every one of them.
    ///
    /// Dismissed pull requests are left out. They never render again, so refreshing one
    /// would spend part of a single request's budget on a row nobody will see.
    public mutating func recordDisplayed<PullRequests: Sequence>(
        from pullRequests: PullRequests,
        limit: Int = LocalState.displayedLimit
    ) where PullRequests.Element == PullRequest {
        displayed = pullRequests
            .filter { !dismissed.contains($0.id) }
            .sorted { left, right in
                if (left.state == .open) != (right.state == .open) { return left.state == .open }
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                return PRID.panelOrder(left.id, right.id)
            }
            .prefix(max(0, limit))
            .map(\.id)
    }

    /// Records read digests for `ids` as those pull requests stand in `snapshot`.
    ///
    /// This is what opening the panel does, and what `Mark all read` does on demand
    /// (IMPLEMENTATION_PLAN §2). Ids absent from the snapshot are ignored.
    public mutating func markRead<Ids: Sequence>(_ ids: Ids, in snapshot: RawSnapshot)
    where Ids.Element == PRID {
        let byID = Dictionary(
            snapshot.pullRequests.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let index = MergeChain.headIndex(snapshot.pullRequests)
        for id in ids {
            guard let pullRequest = byID[id] else { continue }
            // Read `self` fully before mutating it, rather than nesting the lookup inside
            // the subscript assignment.
            let stage = Derivation.releaseStage(for: pullRequest, in: index, local: self)
            let digest = ReadDigest.make(for: pullRequest, releaseStage: stage)
            readDigests[id] = digest
        }
    }

    /// `Mark all read` — every pull request in the snapshot.
    public mutating func markAllRead(in snapshot: RawSnapshot) {
        markRead(snapshot.pullRequests.map(\.id), in: snapshot)
    }

    // MARK: - Snooze

    /// Suppresses a pull request's attention state until `deadline`.
    ///
    /// A deadline already in the past is stored rather than rejected, and derivation reads
    /// it as awake: the two are the same outcome, and refusing it here would mean the one
    /// caller that computes a deadline from a stale `now` fails silently instead.
    public mutating func snooze(_ id: PRID, until deadline: Date) {
        snoozedUntil[id] = deadline
    }

    /// Wakes a snoozed pull request now. Idempotent — waking a row that is not asleep is
    /// what the menu does when the deadline passed while it was open.
    public mutating func wake(_ id: PRID) {
        snoozedUntil[id] = nil
    }

    /// Drops deadlines that have already passed.
    ///
    /// Cosmetic for derivation, which compares against `now` either way, but not for the
    /// file: a snooze set once per pull request per week would otherwise accumulate an
    /// entry per pull request the user has ever silenced, forever. Called once per poll,
    /// so an expired deadline survives at most one interval.
    ///
    /// Safe against the wake-up event, which is diffed from `(status, isSuppressed)` in
    /// the previous *model* — removing an entry derivation already reads as expired
    /// changes nothing it sees.
    public mutating func pruneSnoozes(before now: Date) {
        snoozedUntil = snoozedUntil.filter { $0.value > now }
    }

    // MARK: - Release tracking

    /// Notes the merge commit of every merged pull request that is still waiting for a tag.
    ///
    /// Idempotent, and called on every poll: a pull request already bound to a release is
    /// skipped, and one already recorded keeps the tags it has been compared against —
    /// unless its merge commit has changed underneath us, in which case those negatives
    /// were about a commit that is no longer this pull request's and are dropped.
    ///
    /// A pull request with no merge commit is not recorded at all. There is nothing to
    /// compare a tag against, so an entry for it would be a permanent no-op that still
    /// dragged the merged query's lower bound backwards.
    public mutating func recordMerges<PullRequests: Sequence>(from pullRequests: PullRequests)
    where PullRequests.Element == PullRequest {
        for pullRequest in pullRequests {
            guard pullRequest.state == .merged,
                  releaseBindings[pullRequest.id] == nil,
                  // A dismissed row is suppressed forever, so binding it to a tag would
                  // spend comparisons on something that can never appear again.
                  !dismissed.contains(pullRequest.id),
                  // The chain this merge sits in has finished without a release — it was
                  // abandoned, or it landed somewhere untrackable and spent its allowance.
                  // Re-recording it here is what would otherwise undo that on the next poll.
                  !hasFinishedReleaseTracking(pullRequest.id),
                  let commit = pullRequest.mergeCommit,
                  !commit.isEmpty,
                  let mergedAt = pullRequest.mergedAt
            else { continue }

            if let existing = unboundMerges[pullRequest.id], existing.mergeCommit == commit {
                unboundMerges[pullRequest.id]?.mergedAt = mergedAt
                continue
            }
            unboundMerges[pullRequest.id] = UnboundMerge(mergeCommit: commit, mergedAt: mergedAt)
        }
    }

    /// Dismisses a pull request: a permanent tombstone, and the end of any release work
    /// still queued for it.
    ///
    /// The two halves belong together. A dismissed row never renders again, so an unbound
    /// record left behind would go on drawing the merged query's lower bound backwards and
    /// spending comparisons on a row nobody will see — and ``recordMerges(from:)`` would
    /// not put it back, because it skips dismissed pull requests.
    public mutating func dismiss<Ids: Sequence>(_ ids: Ids) where Ids.Element == PRID {
        // Collected before anything is written, because `Ids` is a `Sequence` and a
        // sequence may only be walked once — the list is needed twice below.
        let removed = Set(ids)
        for id in removed {
            dismissed.insert(id)
            unboundMerges[id] = nil
            // Nothing will ever ask about this row's chain again, and the answer is only
            // ever read to draw it.
            mergeAnchors[id] = nil
            // A dismissed row never renders again, so its wake time has nothing left to
            // wake. Left behind it would sit in the file forever, since nothing else ever
            // looks the id up again.
            snoozedUntil[id] = nil
        }
        // The next poll rewrites this list from its own snapshot and leaves dismissals out
        // anyway, so this only closes the window between the two — but a refresh that spent
        // part of its one request on a row the user has just dismissed would be spending it
        // on nothing.
        displayed.removeAll { removed.contains($0) }
    }

    public mutating func dismiss(_ id: PRID) {
        dismiss(CollectionOfOne(id))
    }

    /// Records what became of the branch a nested merge landed on, and acts on it.
    ///
    /// The two halves belong together, the same way dismissal and its cleanup do. An
    /// anchor is not a note: `landed` is the only thing that makes the pull request
    /// comparable at all, and `abandoned` is the only thing that makes it stop.
    public mutating func recordAnchor(_ anchor: MergeAnchor, for id: PRID) {
        guard !dismissed.contains(id), releaseBindings[id] == nil else { return }
        // A settled answer is a fact about a pull request that has already merged, so
        // nothing later can improve on it — and an unsettled one replacing it would be a
        // strict loss: `landed` carries the trunk commit the whole binding depends on, and
        // overwriting that with "could not answer this time" would strand the row for good.
        // ``MergeChain/unresolved(among:local:now:backoff:limit:)`` does not re-ask a
        // settled chain, so this only closes the door on a caller that does.
        if let existing = mergeAnchors[id]?.outcome, existing.isSettled, !anchor.outcome.isSettled {
            return
        }
        mergeAnchors[id] = anchor

        switch anchor.outcome {
        case .landed(_, let commit, let mergedAt):
            retarget(id, toTrunkCommit: commit, mergedAt: mergedAt)
        case .abandoned:
            // Nothing left to compare, and the record is what drags the closed search's
            // lower bound backwards and holds the app at the awaiting-release cadence.
            unboundMerges[id] = nil
        case .pending, .untracked, .unresolved:
            break
        }
    }

    /// Points a nested merge's release tracking at the commit its chain actually put on
    /// trunk, rather than at its own merge commit.
    ///
    /// This is the whole of what makes a squashed chain bindable. The pull request's own
    /// merge commit is on a branch that the squash rewrote away, so no tag will ever
    /// contain it; the commit the chain's root put on trunk is on trunk by definition, and
    /// the earliest tag containing it is the release this pull request shipped in.
    ///
    /// The compared-tag set is dropped when the commit changes, and that is load-bearing
    /// rather than tidy: those negatives were recorded against a commit no tag was ever
    /// going to contain, and carrying them over would silently skip the very tag that
    /// contains the new one.
    public mutating func retarget(_ id: PRID, toTrunkCommit commit: String, mergedAt: Date) {
        guard releaseBindings[id] == nil, !dismissed.contains(id), !commit.isEmpty else { return }
        if let existing = unboundMerges[id], existing.mergeCommit == commit {
            unboundMerges[id]?.mergedAt = mergedAt
            return
        }
        unboundMerges[id] = UnboundMerge(mergeCommit: commit, mergedAt: mergedAt)
    }

    /// Binds a pull request to the release it shipped in. Permanent, and it retires the
    /// unbound record — including its compared-tag set, which has nothing left to bound.
    public mutating func bind(_ id: PRID, toRelease tag: String) {
        releaseBindings[id] = tag
        unboundMerges[id] = nil
        // The anchor answered "where did this land"; the binding answers "and which release
        // contains it", which is strictly more. Nothing reads the anchor again — derivation
        // short-circuits on the binding before it ever gets there.
        mergeAnchors[id] = nil
    }

    /// Writes down the releases that nested merges inherited from the pull requests they
    /// merged into.
    ///
    /// Derivation works this out on its own from the snapshot, so it would be tempting to
    /// leave it derived. It cannot be. The proof lives in the snapshot — the parent row —
    /// and the snapshot is bounded by the closed search's lower bound, which *shrinks* as
    /// merges bind. So the parent eventually stops being fetched, and a purely derived
    /// answer would flip the child back to `awaiting release` months after it shipped, with
    /// nothing left to work it out from a second time.
    ///
    /// Writing it down also ends the row's cost: ``bind(_:toRelease:)`` retires the unbound
    /// record, which is what was dragging the closed search's lower bound backwards and
    /// holding the app at the awaiting-release cadence.
    ///
    /// One pass is enough for a chain of any depth. The walk goes all the way to the root
    /// before it answers, so a leaf three levels down reads the root's binding directly
    /// rather than waiting for the level above it to be written first.
    public mutating func bindInheritedReleases<PullRequests: Sequence>(
        from pullRequests: PullRequests
    ) where PullRequests.Element == PullRequest {
        let all = Array(pullRequests)
        let index = MergeChain.headIndex(all)

        // Collected before anything is written: `nestedStage` reads `releaseBindings`, and
        // binding as we go would let one row's answer depend on where another happened to
        // sit in the iteration order.
        var inherited: [PRID: String] = [:]
        for pullRequest in all {
            guard pullRequest.state == .merged,
                  releaseBindings[pullRequest.id] == nil,
                  !dismissed.contains(pullRequest.id),
                  MergeChain.isNested(pullRequest)
            else { continue }
            guard case .released(let tag) = MergeChain.nestedStage(
                for: pullRequest,
                in: index,
                local: self
            ) else { continue }
            inherited[pullRequest.id] = tag
        }

        for id in inherited.keys.sorted(by: PRID.panelOrder) {
            guard let tag = inherited[id] else { continue }
            bind(id, toRelease: tag)
        }
    }

    /// Records that `tag` was tested against this pull request's merge commit and did not
    /// contain it. Ignored for a pull request with no unbound record — a bound one has
    /// nothing left to compare.
    public mutating func recordComparison(_ id: PRID, against tag: String) {
        unboundMerges[id]?.comparedTags.insert(tag)
        retireIfAllowanceSpent(id)
    }

    /// Drops the unbound record of an untracked merge once it has spent its allowance.
    ///
    /// ``MergeChain/comparable(_:among:local:)`` already stops *selecting* such a record,
    /// but stopping there leaves it in the file forever — and the record itself has two
    /// live effects that have nothing to do with comparisons: it is what
    /// ``oldestUnboundMergeAt`` reads to hold the closed search's lower bound open, and
    /// what the app reads to decide it is still awaiting a release and should keep polling
    /// at the shorter interval. A row that has stopped asking must stop costing, or this
    /// is the same permanent drag it was written to remove.
    private mutating func retireIfAllowanceSpent(_ id: PRID) {
        guard case .untracked = mergeAnchors[id]?.outcome,
              let merge = unboundMerges[id],
              merge.comparedTags.count >= MergeChain.untrackedComparisonCap
        else { return }
        unboundMerges[id] = nil
    }

    /// Whether release tracking for this pull request has finished for good.
    ///
    /// Two ways to be done without ever binding: the chain was abandoned, or it landed on a
    /// branch nobody owns and has spent its allowance of tags. The second is read from the
    /// *absence* of the record rather than from a flag, because retiring it is what being
    /// done means here — and without this, ``recordMerges(from:)`` would put it straight
    /// back on the next poll.
    func hasFinishedReleaseTracking(_ id: PRID) -> Bool {
        guard let outcome = mergeAnchors[id]?.outcome else { return false }
        if outcome.stopsComparisons { return true }
        if case .untracked = outcome, unboundMerges[id] == nil { return true }
        return false
    }

    /// The oldest merge still waiting for a tag, which is the merged query's lower bound.
    /// `nil` when nothing is waiting, and the caller falls back to its cold-start window.
    public var oldestUnboundMergeAt: Date? {
        unboundMerges.values.map(\.mergedAt).min()
    }
}

extension LocalState: Codable {
    private enum CodingKeys: String, CodingKey {
        case dismissed
        case snoozedUntil
        case readDigests
        case releaseBindings
        case unboundMerges
        case mergeAnchors
        case displayed
    }

    public init(from decoder: any Decoder) throws {
        // Unparseable ids are dropped, not thrown on. This is a cache of the user's own
        // dismissals and snoozes, not authoritative data: discarding one stale entry is a
        // fair price, while failing the decode would throw away every dismissal and snooze
        // they have ever set because of a single bad key. That also bounds the damage from
        // any id built through an unvalidated path — a hand-edited file, or a future caller
        // of a public initialiser — to the entry itself.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dismissed = try container.decodeIfPresent([String].self, forKey: .dismissed) ?? []
        let snoozed = try container.decodeIfPresent([String: Date].self, forKey: .snoozedUntil) ?? [:]
        let digests = try container.decodeIfPresent([String: String].self, forKey: .readDigests) ?? [:]
        let bindings = try container.decodeIfPresent([String: String].self, forKey: .releaseBindings) ?? [:]
        let merges = try container.decodeIfPresent([String: UnboundMerge].self, forKey: .unboundMerges) ?? [:]
        // Absent from every file written before nested merges were followed. An empty map
        // is exactly right for one: nothing has been resolved, so every nested merge is
        // asked about once and then settles.
        let anchors = try container.decodeIfPresent([String: MergeAnchor].self, forKey: .mergeAnchors) ?? [:]
        // Absent from every file written before the priority refresh existed, and from a
        // file written by a launch that never completed a poll. Both mean the same thing:
        // the first poll of this launch has nothing to refresh ahead of its search and is
        // the plain sweep it always was.
        let displayed = try container.decodeIfPresent([String].self, forKey: .displayed) ?? []
        self.init(
            dismissed: Set(dismissed.compactMap(PRID.init(rawValue:))),
            snoozedUntil: LocalState.rekey(snoozed) { $0 },
            readDigests: LocalState.rekey(digests) { ReadDigest(value: $0) },
            releaseBindings: LocalState.rekey(bindings) { $0 },
            unboundMerges: LocalState.rekey(merges) { $0 },
            mergeAnchors: LocalState.rekey(anchors) { $0 },
            displayed: displayed.compactMap(PRID.init(rawValue:))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `dismissed` is sorted here, so it alone is stable. The maps below encode as JSON
        // objects whose key order comes from `Dictionary` iteration, which varies per
        // process — ``FileStateStore`` sets `.sortedKeys` for exactly this reason, and the
        // state file is only diffable because it does.
        // Sorting cannot be done from inside `encode(to:)` without changing the on-disk
        // schema to key/value arrays, and the readable object form is the reason
        // `LocalState` has a hand-written `Codable` at all.
        try container.encode(dismissed.map(\.rawValue).sorted(), forKey: .dismissed)
        try container.encode(LocalState.stringKeyed(snoozedUntil) { $0 }, forKey: .snoozedUntil)
        try container.encode(LocalState.stringKeyed(readDigests) { $0.value }, forKey: .readDigests)
        try container.encode(LocalState.stringKeyed(releaseBindings) { $0 }, forKey: .releaseBindings)
        try container.encode(LocalState.stringKeyed(unboundMerges) { $0 }, forKey: .unboundMerges)
        try container.encode(LocalState.stringKeyed(mergeAnchors) { $0 }, forKey: .mergeAnchors)
        // Not sorted, unlike `dismissed`: this list *is* an order — the order the next poll
        // refreshes in — and sorting it would throw away the only thing it says.
        try container.encode(displayed.map(\.rawValue), forKey: .displayed)
    }

    private static func rekey<Input, Output>(
        _ source: [String: Input],
        _ transform: (Input) -> Output
    ) -> [PRID: Output] {
        var result: [PRID: Output] = [:]
        for (raw, value) in source {
            guard let id = PRID(rawValue: raw) else { continue }
            result[id] = transform(value)
        }
        return result
    }

    private static func stringKeyed<Input, Output>(
        _ source: [PRID: Input],
        _ transform: (Input) -> Output
    ) -> [String: Output] {
        var result: [String: Output] = [:]
        for (id, value) in source {
            result[id.rawValue] = transform(value)
        }
        return result
    }
}
