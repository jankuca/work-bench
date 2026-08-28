import Foundation

/// A branch, qualified by the repository it lives in.
///
/// Never the branch alone. Names like `main`, `develop` and `release` recur across
/// repositories, so an index keyed on the ref would join unrelated pull requests into a
/// phantom chain — the same reason ``PRID`` carries its repository.
public struct BranchKey: Hashable, Sendable {
    public let repo: String
    public let ref: String

    public init(repo: String, ref: String) {
        self.repo = repo
        self.ref = ref
    }
}

/// What became of the branch a pull request merged into, when no pull request in the
/// snapshot claims it.
///
/// This is the answer to the one question the panel cannot answer locally: *you merged
/// into somebody else's branch — what happened to their pull request?* The searches carry
/// `is:pr author:@me`, so their pull request is never fetched, and ``StackLayout`` only
/// indexes the viewer's own — no local walk can reach it. `GitHubKit`'s
/// `BaseBranchResolver` asks GitHub directly and hands back one of these.
public enum MergeAnchorOutcome: Equatable, Sendable {
    /// The branch belongs to a pull request that is still open. Nothing has shipped and
    /// nothing has been abandoned; the answer is re-asked on a backoff.
    case pending(PRID)
    /// The chain reached trunk. `commit` is what it put on the default branch, through
    /// however many levels, and is what a release tag has to contain — the pull request's
    /// *own* merge commit is on a branch that a squash may have rewritten away.
    case landed(root: PRID, commit: String, mergedAt: Date)
    /// The chain ends in a pull request closed without merging. The work never reached
    /// trunk and never will.
    case abandoned(PRID)
    /// No pull request owns the branch — a long-lived integration branch merged into by
    /// hand. There is nothing to follow, so the row is shown as merged into that branch
    /// and stops asking.
    case untracked(branch: String)

    /// Whether this outcome ends release tracking outright.
    ///
    /// Only ``abandoned`` does. ``untracked`` still compares opportunistically — an
    /// integration branch merged into trunk with a merge commit does carry the work there,
    /// and that binding is worth catching — but it is capped, unlike a trunk merge's.
    public var stopsComparisons: Bool {
        if case .abandoned = self { return true }
        return false
    }

    /// Whether asking GitHub again could change this answer.
    ///
    /// Only ``pending`` can move. A merged or closed pull request is immutable, and a
    /// branch that no pull request owns is not going to acquire one in a way this would
    /// notice — if the user opens one later it is their own, and the local walk finds it
    /// in the snapshot without a request.
    public var isSettled: Bool {
        if case .pending = self { return false }
        return true
    }
}

/// One resolved answer about a pull request's base branch, and when it was resolved.
public struct MergeAnchor: Equatable, Sendable {
    public var outcome: MergeAnchorOutcome
    /// When the resolver last answered. Unsettled outcomes are re-asked once this is older
    /// than ``MergeChain/anchorBackoff``; settled ones never are.
    public var checkedAt: Date

    public init(outcome: MergeAnchorOutcome, checkedAt: Date) {
        self.outcome = outcome
        self.checkedAt = checkedAt
    }
}

/// Following a merge that did not land on trunk to whatever did.
///
/// The whole of this is built on one observation: **the merge method never enters into
/// it.** A squash rewrites the commits on the branch it lands on, so a nested pull
/// request's own merge commit may never appear in trunk's history and no tag will ever
/// contain it — which is why those rows sit at `merged · awaiting release` for good today.
/// Asking instead *"whose branch did this merge into, and what happened to that pull
/// request"* sidesteps the question entirely: only the root of the chain, which targets
/// trunk, ever needs a commit that a tag can contain, and its merge commit is on trunk by
/// definition. Multi-level chains and squash merges both fall out of that for free.
public enum MergeChain {
    /// How far up a chain to walk before giving up. Deep stacks exist; eight-deep ones
    /// that also cross an author boundary do not, and the cap is what keeps a malformed
    /// answer from becoming an unbounded walk.
    public static let maximumDepth = 8

    /// How long a `pending` answer stands before the resolver asks again.
    ///
    /// Not the poll interval. Their pull request merging is not time-sensitive — the row
    /// already reads `merged into #456`, which is the useful part — and asking every 60 s
    /// would spend a request per poll per chain, forever, on a question whose answer
    /// changes once.
    public static let anchorBackoff: TimeInterval = 10 * 60

    /// How many base branches one poll will resolve. Bounded for the same reason every
    /// other pass here is: a merge that has waited days can wait one more poll.
    public static let anchorLookupLimit = 10

    /// How many tags an ``MergeAnchorOutcome/untracked`` merge is compared against before
    /// it stops.
    ///
    /// A trunk merge compares against every new tag forever, because it *will* bind. This
    /// one probably will not — nothing says the branch it landed on ever reaches trunk
    /// intact — so it gets a fixed allowance rather than an open one, and then rests.
    public static let untrackedComparisonCap = 25

    // MARK: - Index

    /// The snapshot's pull requests by the branch each one *produces*.
    ///
    /// A list per branch rather than one winner, because picking the winner is a question
    /// about a particular child: a branch reused months apart has two pull requests, and
    /// which of them a given merge went into is decided by ``claims(_:child:)``, not by
    /// number order.
    public static func headIndex<PullRequests: Sequence>(
        _ pullRequests: PullRequests
    ) -> [BranchKey: [PullRequest]] where PullRequests.Element == PullRequest {
        var index: [BranchKey: [PullRequest]] = [:]
        for pullRequest in pullRequests where !pullRequest.headRef.isEmpty {
            index[BranchKey(repo: pullRequest.repo, ref: pullRequest.headRef), default: []]
                .append(pullRequest)
        }
        // Sorted so two runs over the same snapshot resolve the same parent. Dictionary
        // iteration order is per-process, and the ambiguity check below counts candidates.
        // Within one key the repository is fixed, so the number alone is a total order.
        return index.mapValues { $0.sorted { $0.number < $1.number } }
    }

    // MARK: - Predicates

    /// A merged pull request that landed somewhere other than its repository's trunk.
    ///
    /// An unknown default branch reads as trunk, which is what keeps this from changing
    /// the behaviour of a snapshot decoded from a state file written before the field
    /// existed: those rows track exactly as they did.
    public static func isNested(_ pullRequest: PullRequest) -> Bool {
        guard pullRequest.state == .merged, !pullRequest.baseRef.isEmpty else { return false }
        return !pullRequest.mergedIntoDefaultBranch
    }

    /// Whether `parent` can be the pull request `child` merged into.
    ///
    /// The lifetime guard, and it is the whole defence against a reused branch name. A
    /// branch called `integration` cut, merged, deleted and cut again a month later has two
    /// pull requests with the same head ref; joining the child to the wrong one would bind
    /// it to the wrong release, permanently. A merge into a branch can only have happened
    /// while that branch's pull request was open, so the child's merge has to fall inside
    /// the parent's lifetime.
    public static func claims(_ parent: PullRequest, child: PullRequest) -> Bool {
        guard parent.id != child.id, let mergedAt = child.mergedAt else { return false }
        guard parent.createdAt <= mergedAt else { return false }
        guard let parentMergedAt = parent.mergedAt else { return true }
        return mergedAt <= parentMergedAt
    }

    /// The pull request in the snapshot whose head branch `pullRequest` merged into.
    ///
    /// Nil when nothing claims the branch **and** when more than one thing does. Ambiguity
    /// resolves to nil rather than to a guess: the binding this feeds is permanent, and a
    /// row left saying `awaiting release` for another poll is recoverable in a way a row
    /// bound to the wrong release is not.
    public static func parent(
        of pullRequest: PullRequest,
        in index: [BranchKey: [PullRequest]]
    ) -> PullRequest? {
        let key = BranchKey(repo: pullRequest.repo, ref: pullRequest.baseRef)
        let candidates = (index[key] ?? []).filter { claims($0, child: pullRequest) }
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    // MARK: - Resolution

    /// The release stage of a merged pull request that did not target trunk.
    ///
    /// Walks the snapshot as far as it goes, and falls back to whatever the resolver
    /// learned about the branch when it runs out. The walk is what makes an all-your-own
    /// stack cost nothing: the parent is in the snapshot by construction, because the
    /// closed search's lower bound is the oldest merge still waiting for a tag and the
    /// parent merged *after* the child it is holding up.
    public static func nestedStage(
        for pullRequest: PullRequest,
        in index: [BranchKey: [PullRequest]],
        local: LocalState
    ) -> ReleaseStage {
        var seen: Set<PRID> = [pullRequest.id]
        var current = pullRequest
        var depth = 0

        while depth < maximumDepth {
            depth += 1
            guard let parent = parent(of: current, in: index) else { break }
            // A cycle is not a real GitHub state, but nothing here guarantees the snapshot
            // is not one: `StackLayout` breaks cycles for its own index and this walk reads
            // the raw branches.
            guard seen.insert(parent.id).inserted else { break }

            // The parent shipped, so its whole stack shipped with it — squash or not, the
            // content is in that release. This is the fast path: no request, and it lands
            // on the same poll the parent binds.
            if let tag = local.releaseBindings[parent.id] { return .released(tag: tag) }

            switch parent.state {
            case .closed:
                return .mergedIntoAbandonedPullRequest(parent.id)
            case .open:
                return .mergedIntoPullRequest(parent.id)
            case .merged:
                // Merged to trunk: the chain ends here, and the parent is waiting for a tag
                // exactly as this row is. Merged to another branch: keep walking.
                if parent.mergedIntoDefaultBranch { return .mergedIntoPullRequest(parent.id) }
                current = parent
            }
        }

        return anchoredStage(for: pullRequest, local: local)
    }

    /// The stage implied by a resolved anchor, for a chain the snapshot could not follow.
    ///
    /// With no anchor yet the row reads as an ordinary merge awaiting a tag. That is the
    /// honest answer for the poll or two before the resolver lands — the alternative,
    /// guessing at a terminal state, would move a row to Done and then have to take it
    /// back.
    public static func anchoredStage(for pullRequest: PullRequest, local: LocalState) -> ReleaseStage {
        guard let anchor = local.mergeAnchors[pullRequest.id] else { return .mergedAwaitingTag }
        switch anchor.outcome {
        case .pending(let parent):
            return .mergedIntoPullRequest(parent)
        // The work is on trunk and the only thing left is a tag containing it, which is
        // what an ordinary merge is waiting for too. The tracker is already comparing
        // against the anchor's commit rather than this row's own.
        case .landed:
            return .mergedAwaitingTag
        case .abandoned(let parent):
            return .mergedIntoAbandonedPullRequest(parent)
        case .untracked(let branch):
            return .mergedIntoBranch(branch)
        }
    }

    // MARK: - What needs asking

    /// The pull requests whose base branch the snapshot cannot account for, in the order a
    /// poll should spend its lookups on them.
    ///
    /// Oldest merge first — it has waited longest — with the id as a deterministic
    /// tie-break, so two polls over the same state ask about the same pull requests.
    public static func unresolved<PullRequests: Sequence>(
        among pullRequests: PullRequests,
        local: LocalState,
        now: Date,
        backoff: TimeInterval = MergeChain.anchorBackoff,
        limit: Int = MergeChain.anchorLookupLimit
    ) -> [PullRequest] where PullRequests.Element == PullRequest {
        let all = Array(pullRequests)
        let index = headIndex(all)

        return all
            .filter { pullRequest in
                guard isNested(pullRequest), pullRequest.mergedAt != nil else { return false }
                guard !local.dismissed.contains(pullRequest.id) else { return false }
                // Already bound: the answer cannot change anything.
                guard local.releaseBindings[pullRequest.id] == nil else { return false }
                // The snapshot answers this one for free.
                guard parent(of: pullRequest, in: index) == nil else { return false }

                guard let anchor = local.mergeAnchors[pullRequest.id] else { return true }
                guard !anchor.outcome.isSettled else { return false }
                return now.timeIntervalSince(anchor.checkedAt) >= backoff
            }
            .sorted { left, right in
                let leftMerged = left.mergedAt ?? .distantPast
                let rightMerged = right.mergedAt ?? .distantPast
                if leftMerged != rightMerged { return leftMerged < rightMerged }
                return PRID.panelOrder(left.id, right.id)
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}

// MARK: - Persistence

extension MergeAnchorOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case pullRequest
        case commit
        case mergedAt
        case branch
    }

    /// The discriminator written to disk. Spelled out rather than derived, because the
    /// state file outlives any one build and a renamed case must not silently change what
    /// an existing file decodes to.
    private enum Kind: String, Codable {
        case pending
        case landed
        case abandoned
        case untracked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pending:
            self = .pending(try container.decode(PRID.self, forKey: .pullRequest))
        case .landed:
            self = .landed(
                root: try container.decode(PRID.self, forKey: .pullRequest),
                commit: try container.decode(String.self, forKey: .commit),
                mergedAt: try container.decode(Date.self, forKey: .mergedAt)
            )
        case .abandoned:
            self = .abandoned(try container.decode(PRID.self, forKey: .pullRequest))
        case .untracked:
            self = .untracked(branch: try container.decode(String.self, forKey: .branch))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending(let id):
            try container.encode(Kind.pending, forKey: .kind)
            try container.encode(id, forKey: .pullRequest)
        case .landed(let root, let commit, let mergedAt):
            try container.encode(Kind.landed, forKey: .kind)
            try container.encode(root, forKey: .pullRequest)
            try container.encode(commit, forKey: .commit)
            try container.encode(mergedAt, forKey: .mergedAt)
        case .abandoned(let id):
            try container.encode(Kind.abandoned, forKey: .kind)
            try container.encode(id, forKey: .pullRequest)
        case .untracked(let branch):
            try container.encode(Kind.untracked, forKey: .kind)
            try container.encode(branch, forKey: .branch)
        }
    }
}

extension MergeAnchor: Codable {
    private enum CodingKeys: String, CodingKey {
        case outcome
        case checkedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            outcome: try container.decode(MergeAnchorOutcome.self, forKey: .outcome),
            // Absent in a file written by a build whose resolver did not record it. Read as
            // the epoch, which makes the anchor immediately re-askable — the safe direction,
            // since the alternative pins an unsettled answer forever.
            checkedAt: try container.decodeIfPresent(Date.self, forKey: .checkedAt) ?? Date(timeIntervalSince1970: 0)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(checkedAt, forKey: .checkedAt)
    }
}

// MARK: - What is worth comparing

extension MergeChain {
    /// The unbound merges a release tracker should actually spend comparisons on.
    ///
    /// Three of them are not worth a request, and today every one of them gets one on every
    /// poll for as long as it exists:
    ///
    /// - **Waiting on another pull request.** Nothing has reached trunk yet, or the thing
    ///   that did is itself waiting for a tag. Either way the row binds by inheriting its
    ///   parent's release the moment that happens, so testing its own commit is work whose
    ///   answer is already spoken for.
    /// - **Merged into an abandoned chain.** No tag will ever contain it.
    /// - **Merged onto a branch nobody owns**, past its allowance. It is still tested, for a
    ///   while — an integration branch merged to trunk with a merge commit does carry the
    ///   work there — but not forever, because nothing says it ever will.
    ///
    /// Anything this cannot account for is kept. A merge whose pull request is not in the
    /// snapshot, or whose chain has not been resolved yet, is compared exactly as it was
    /// before any of this existed: the point is to stop spending on questions already
    /// answered, never to withhold a comparison that might bind.
    public static func comparable<PullRequests: Sequence>(
        _ unbound: [PRID: UnboundMerge],
        among pullRequests: PullRequests,
        local: LocalState
    ) -> [PRID: UnboundMerge] where PullRequests.Element == PullRequest {
        let all = Array(pullRequests)
        let index = headIndex(all)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return unbound.filter { entry in
            guard let pullRequest = byID[entry.key] else { return true }
            switch Derivation.releaseStage(for: pullRequest, in: index, local: local) {
            case .mergedIntoPullRequest, .mergedIntoAbandonedPullRequest:
                return false
            case .mergedIntoBranch:
                return entry.value.comparedTags.count < untrackedComparisonCap
            // Bound, or inheriting a parent's binding that is about to be written down.
            // Either way there is nothing left to find.
            case .released:
                return false
            default:
                return true
            }
        }
    }
}
