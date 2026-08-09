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
    /// lastCommentAt, releaseStage)` — IMPLEMENTATION_PLAN §2.
    public static func make(for pullRequest: PullRequest, releaseStage: ReleaseStage) -> ReadDigest {
        let lastComment = pullRequest.lastCommentAt.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "-"
        let parts = [
            "rd=" + (pullRequest.reviewDecision?.rawValue ?? "-"),
            "ck=" + pullRequest.checks.digestToken,
            "mg=" + pullRequest.mergeable.rawValue,
            "cc=\(pullRequest.commentCount)",
            "lc=" + lastComment,
            "rs=" + releaseStage.digestToken
        ]
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

    public init(
        dismissed: Set<PRID> = [],
        snoozedUntil: [PRID: Date] = [:],
        readDigests: [PRID: ReadDigest] = [:],
        releaseBindings: [PRID: String] = [:],
        unboundMerges: [PRID: UnboundMerge] = [:]
    ) {
        self.dismissed = dismissed
        self.snoozedUntil = snoozedUntil
        self.readDigests = readDigests
        self.releaseBindings = releaseBindings
        self.unboundMerges = unboundMerges
    }

    public static let empty = LocalState()

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
        for id in ids {
            guard let pullRequest = byID[id] else { continue }
            // Read `self` fully before mutating it, rather than nesting the lookup inside
            // the subscript assignment.
            let stage = Derivation.releaseStage(for: pullRequest, local: self)
            let digest = ReadDigest.make(for: pullRequest, releaseStage: stage)
            readDigests[id] = digest
        }
    }

    /// `Mark all read` — every pull request in the snapshot.
    public mutating func markAllRead(in snapshot: RawSnapshot) {
        markRead(snapshot.pullRequests.map(\.id), in: snapshot)
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

    /// Binds a pull request to the release it shipped in. Permanent, and it retires the
    /// unbound record — including its compared-tag set, which has nothing left to bound.
    public mutating func bind(_ id: PRID, toRelease tag: String) {
        releaseBindings[id] = tag
        unboundMerges[id] = nil
    }

    /// Records that `tag` was tested against this pull request's merge commit and did not
    /// contain it. Ignored for a pull request with no unbound record — a bound one has
    /// nothing left to compare.
    public mutating func recordComparison(_ id: PRID, against tag: String) {
        unboundMerges[id]?.comparedTags.insert(tag)
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
        self.init(
            dismissed: Set(dismissed.compactMap(PRID.init(rawValue:))),
            snoozedUntil: LocalState.rekey(snoozed) { $0 },
            readDigests: LocalState.rekey(digests) { ReadDigest(value: $0) },
            releaseBindings: LocalState.rekey(bindings) { $0 },
            unboundMerges: LocalState.rekey(merges) { $0 }
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
