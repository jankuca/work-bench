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

    public init(
        dismissed: Set<PRID> = [],
        snoozedUntil: [PRID: Date] = [:],
        readDigests: [PRID: ReadDigest] = [:],
        releaseBindings: [PRID: String] = [:]
    ) {
        self.dismissed = dismissed
        self.snoozedUntil = snoozedUntil
        self.readDigests = readDigests
        self.releaseBindings = releaseBindings
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
}

extension LocalState: Codable {
    private enum CodingKeys: String, CodingKey {
        case dismissed
        case snoozedUntil
        case readDigests
        case releaseBindings
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
        self.init(
            dismissed: Set(dismissed.compactMap(PRID.init(rawValue:))),
            snoozedUntil: LocalState.rekey(snoozed) { $0 },
            readDigests: LocalState.rekey(digests) { ReadDigest(value: $0) },
            releaseBindings: LocalState.rekey(bindings) { $0 }
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `dismissed` is sorted here, so it alone is stable. The three maps below encode
        // as JSON objects whose key order comes from `Dictionary` iteration, which varies
        // per process — the writing layer (M6) has to set
        // `outputFormatting.insert(.sortedKeys)` for the state file to be diffable.
        // Sorting cannot be done from inside `encode(to:)` without changing the on-disk
        // schema to key/value arrays, and the readable object form is the reason
        // `LocalState` has a hand-written `Codable` at all.
        try container.encode(dismissed.map(\.rawValue).sorted(), forKey: .dismissed)
        try container.encode(LocalState.stringKeyed(snoozedUntil) { $0 }, forKey: .snoozedUntil)
        try container.encode(LocalState.stringKeyed(readDigests) { $0.value }, forKey: .readDigests)
        try container.encode(LocalState.stringKeyed(releaseBindings) { $0 }, forKey: .releaseBindings)
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
