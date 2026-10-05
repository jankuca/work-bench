import Foundation

// MARK: - Snooze

/// What a snoozed pull request is waiting for, as persisted in `state.json`.
///
/// A snooze used to be a wake time and nothing else, which made it a timer: the row came
/// back whether or not anything it was waiting on had happened. Most of the time what a
/// pull request is actually waiting on is another one — the base of its stack merging, or
/// shipping — or the next release being cut, so the condition is stored as that, and the
/// row wakes when it is met rather than when a guess about it runs out.
///
/// Two of the conditions can be answered from the snapshot at any time and are evaluated
/// in derivation (``Derivation/isSnoozed(_:releaseStage:context:)``). One cannot:
/// ``nextRelease(repository:baseline:)`` needs the repository's tags, which only a poll
/// reads, so it is woken by ``LocalState/observeReleases(_:)`` removing it.
public enum Snooze: Hashable, Sendable {
    /// Wakes at a wall-clock time — `1 day`, `1 week`, `Until Monday`.
    case until(Date)
    /// Wakes the moment anything about the pull request changes: what its read digest
    /// covers (reviews, checks, conflicts, comments, release) and anything else GitHub
    /// counts as an update, such as a push. The baseline is the pull request as it stood
    /// when it was snoozed.
    case anyChange(digest: ReadDigest, updatedAt: Date)
    /// Wakes when another pull request merges — or closes, since a pull request that was
    /// closed is never going to merge and the snooze would otherwise never end.
    case merged(PRID)
    /// Wakes when another pull request ships, or finishes without shipping.
    case released(PRID)
    /// Wakes when the repository cuts a release after the snooze started.
    ///
    /// `baseline` is the newest release the repository had when the snooze started
    /// watching it. It is nil until the first poll that reads the repository's tags fills
    /// it in: the tags are not in the snapshot, so at the moment of snoozing there is
    /// usually nothing to compare against yet.
    case nextRelease(repository: String, baseline: ReleaseMark?)
}

extension Snooze: Codable {
    private enum Kind: String, Codable {
        case until
        case anyChange
        case merged
        case released
        case nextRelease
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case until
        case digest
        case updatedAt
        case pullRequest
        case repository
        case baseline
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .until:
            self = .until(try container.decode(Date.self, forKey: .until))
        case .anyChange:
            self = .anyChange(
                digest: ReadDigest(value: try container.decode(String.self, forKey: .digest)),
                updatedAt: try container.decode(Date.self, forKey: .updatedAt)
            )
        case .merged, .released:
            let raw = try container.decode(String.self, forKey: .pullRequest)
            guard let id = PRID(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .pullRequest,
                    in: container,
                    debugDescription: "Expected 'owner/name#number', got '\(raw)'"
                )
            }
            self = kind == .merged ? .merged(id) : .released(id)
        case .nextRelease:
            self = .nextRelease(
                repository: try container.decode(String.self, forKey: .repository),
                baseline: try container.decodeIfPresent(ReleaseMark.self, forKey: .baseline)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .until(let date):
            try container.encode(Kind.until, forKey: .kind)
            try container.encode(date, forKey: .until)
        case .anyChange(let digest, let updatedAt):
            try container.encode(Kind.anyChange, forKey: .kind)
            try container.encode(digest.value, forKey: .digest)
            try container.encode(updatedAt, forKey: .updatedAt)
        case .merged(let id):
            try container.encode(Kind.merged, forKey: .kind)
            try container.encode(id.rawValue, forKey: .pullRequest)
        case .released(let id):
            try container.encode(Kind.released, forKey: .kind)
            try container.encode(id.rawValue, forKey: .pullRequest)
        case .nextRelease(let repository, let baseline):
            try container.encode(Kind.nextRelease, forKey: .kind)
            try container.encode(repository, forKey: .repository)
            try container.encodeIfPresent(baseline, forKey: .baseline)
        }
    }
}

// MARK: - Release mark

/// The newest release tag a repository had, as one poll saw it.
///
/// Two facts rather than one, because neither is enough on its own. The newest tag's
/// timestamp misses a release tagged on an older commit — a lightweight tag carries its
/// commit's date, not the date it was cut — and the count misses a release cut in the same
/// poll an old tag was deleted. Either moving is a new release.
public struct ReleaseMark: Hashable, Sendable, Codable {
    /// The newest matching tag, nil when the repository has none yet.
    public var tag: String?
    public var taggedAt: Date?
    /// How many matching tags the repository has.
    public var count: Int

    public init(tag: String?, taggedAt: Date?, count: Int) {
        self.tag = tag
        self.taggedAt = taggedAt
        self.count = max(0, count)
    }

    /// Whether this mark shows a release cut since `baseline`.
    public func isLater(than baseline: ReleaseMark) -> Bool {
        if count > baseline.count { return true }
        guard let tag, tag != baseline.tag, let taggedAt else { return false }
        guard let previous = baseline.taggedAt else { return true }
        return taggedAt > previous
    }
}

// MARK: - Local state

extension LocalState {
    /// Snoozes a pull request until `snooze` is met. Replaces any snooze it already had.
    public mutating func snooze(_ id: PRID, _ snooze: Snooze) {
        snoozes[id] = snooze
    }

    /// Snoozes a pull request until `deadline`.
    ///
    /// A deadline already in the past is stored rather than rejected, and derivation reads
    /// it as awake: the two are the same outcome, and refusing it here would mean the one
    /// caller that computes a deadline from a stale `now` fails silently instead.
    public mutating func snooze(_ id: PRID, until deadline: Date) {
        snoozes[id] = .until(deadline)
    }

    /// Snoozes a pull request with one of the menu's choices, resolved against the snapshot
    /// it was chosen from.
    ///
    /// The resolution happens here rather than in the menu because two of the choices need
    /// more than the clock: `Until any change` records the pull request as it stands, and
    /// `Until the next release` picks up a baseline another snooze in the same repository
    /// has already recorded. A pull request the snapshot does not hold is left alone — there
    /// is no row on screen it could have been chosen from.
    public mutating func snooze(
        _ id: PRID,
        _ option: SnoozeOption,
        in snapshot: RawSnapshot,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard let pullRequest = snapshot.pullRequests.first(where: { $0.id == id }) else { return }
        switch option {
        case .oneDay, .oneWeek, .untilMonday:
            guard let deadline = option.wakeTime(from: now, calendar: calendar) else { return }
            snoozes[id] = .until(deadline)
        case .anyChange:
            let stage = Derivation.releaseStage(
                for: pullRequest,
                in: MergeChain.headIndex(snapshot.pullRequests),
                local: self
            )
            snoozes[id] = .anyChange(
                digest: ReadDigest.make(for: pullRequest, releaseStage: stage),
                updatedAt: pullRequest.updatedAt
            )
        case .nextRelease:
            snoozes[id] = .nextRelease(
                repository: pullRequest.repo,
                baseline: releaseBaseline(for: pullRequest.repo)
            )
        case .merged(let target):
            guard target != id else { return }
            snoozes[id] = .merged(target)
        case .released(let target):
            guard target != id else { return }
            snoozes[id] = .released(target)
        }
    }

    /// Wakes a snoozed pull request now. Idempotent — waking a row that is not asleep is
    /// what the menu does when the condition was met while it was open.
    public mutating func wake(_ id: PRID) {
        snoozes[id] = nil
    }

    /// The repositories a poll has to read the newest release of: every one a
    /// `next release` snooze is waiting on.
    public var releaseWatchRepositories: Set<String> {
        Set(snoozes.values.compactMap { snooze in
            guard case .nextRelease(let repository, _) = snooze else { return nil }
            return repository
        })
    }

    /// Folds in the newest release of each repository a poll read, keyed by `owner/name`.
    ///
    /// A snooze with no baseline takes this one as its baseline: the release it waits for
    /// is the one after whatever the repository had when it started watching. A snooze
    /// with a baseline wakes if this mark is later. A repository missing from `marks` —
    /// its tags could not be read this poll — leaves its snoozes exactly as they were.
    public mutating func observeReleases(_ marks: [String: ReleaseMark]) {
        guard !marks.isEmpty else { return }
        for (id, snooze) in snoozes {
            guard case .nextRelease(let repository, let baseline) = snooze,
                  let mark = marks[repository]
            else { continue }
            guard let baseline else {
                snoozes[id] = .nextRelease(repository: repository, baseline: mark)
                continue
            }
            if mark.isLater(than: baseline) { snoozes[id] = nil }
        }
    }

    /// Drops time snoozes whose deadline has already passed.
    ///
    /// Cosmetic for derivation, which compares against `now` either way, but not for the
    /// file: a snooze set once per pull request per week would otherwise accumulate an
    /// entry per pull request the user has ever silenced, forever.
    public mutating func pruneSnoozes(before now: Date) {
        snoozes = snoozes.filter { _, snooze in
            guard case .until(let deadline) = snooze else { return true }
            return deadline > now
        }
    }

    /// Drops every snooze whose condition has been met, as of `snapshot`.
    ///
    /// Called once per completed poll. This is what makes waking permanent: `Until any
    /// change` compares against the pull request as it was snoozed, and a change that is
    /// later undone — checks going red and then green again — must not put the row back
    /// to sleep. It also keeps the file from accumulating snoozes nothing will ever read.
    ///
    /// `isComplete` says the snapshot is the whole list rather than part of it. Only then
    /// does a snoozed pull request missing from it mean it has gone — closed or merged out
    /// of the search's window, or out of the repositories in scope — and its snooze is
    /// dropped with it. A partial snapshot proves nothing about the rows it does not hold.
    ///
    /// Safe against the wake-up event, which is diffed from `(status, isSuppressed)` in
    /// the previous *model*: removing an entry derivation already reads as awake changes
    /// nothing it sees.
    public mutating func resolveSnoozes(in snapshot: RawSnapshot, now: Date, isComplete: Bool) {
        guard !snoozes.isEmpty else { return }
        let context = Derivation.SnoozeContext(snapshot: snapshot, local: self, now: now)
        for (id, snooze) in snoozes {
            guard let pullRequest = context.byID[id] else {
                if case .until(let deadline) = snooze, deadline <= now {
                    snoozes[id] = nil
                } else if isComplete {
                    snoozes[id] = nil
                }
                continue
            }
            let stage = Derivation.releaseStage(for: pullRequest, in: context.branches, local: self)
            // A row that has finished cannot be snoozed — Done offers dismissal instead —
            // so a snooze that outlived its row finishing has nothing left to do.
            let isFinished = RowStatusResolver.resolve(pullRequest: pullRequest, releaseStage: stage, parent: nil)
                .belongsInDone
            if isFinished || !Derivation.isSnoozed(pullRequest, releaseStage: stage, context: context) {
                snoozes[id] = nil
            }
        }
    }

    /// Snoozes every stacked pull request until the parent it is waiting on merges.
    ///
    /// A layer on top of an open parent can't merge before the parent does, so whatever it
    /// says in the meantime — a review, a red check, a conflict from the parent moving — is
    /// rarely something to act on yet. Each one is snoozed `.merged(parent)`, which shows
    /// up on the row as `until #N is merged` and wakes on its own when it is.
    ///
    /// Once per parent, not once per poll: ``autoSnoozed`` records the parent each row was
    /// snoozed against, so waking it by hand sticks. A row that already has a snooze of
    /// its own keeps it, and is recorded too, so it is not snoozed again the moment the
    /// user's own snooze ends. A row that moves onto a *different* open parent is snoozed
    /// against it — again if it was woken, or moved over if it was still asleep on the old
    /// one. From a poll that saw the whole list, a parent missing from it is no longer
    /// open, and the snooze waiting on it ends.
    ///
    /// Called once per completed poll, after ``resolveSnoozes(in:now:isComplete:)``. The
    /// record of a row that is no longer open is dropped, and so, from a poll that saw the
    /// whole list, is the record of a row that has gone. A row whose parent is missing from
    /// a partial snapshot keeps its record: missing is not merged.
    public mutating func autoSnoozeStackedPullRequests(in snapshot: RawSnapshot, isComplete: Bool) {
        let byID = Dictionary(
            snapshot.pullRequests.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        autoSnoozed = autoSnoozed.filter { id, _ in
            guard let pullRequest = byID[id] else { return !isComplete }
            return pullRequest.state == .open
        }

        // A whole list holds every open pull request, so a parent missing from one is not
        // open any more — it closed or merged while nothing was polling, and fell out of
        // the closed search before a poll could see it. The snooze it caused would otherwise
        // wait on it forever.
        if isComplete {
            for (id, parent) in autoSnoozed where byID[parent] == nil && snoozes[id] == Snooze.merged(parent) {
                snoozes[id] = nil
            }
        }

        let parents = Derivation.stackLayout(snapshot: snapshot, local: self).blockingParentOf
        for (id, parent) in parents {
            guard byID[id]?.state == .open else { continue }
            let previous = autoSnoozed[id]
            guard previous != parent else { continue }
            autoSnoozed[id] = parent
            // A row still asleep on the parent it was moved off is waiting on the wrong
            // pull request now; the snooze follows it to the new one.
            let isOwnSnooze = previous.map { snoozes[id] == Snooze.merged($0) } ?? false
            if snoozes[id] == nil || isOwnSnooze {
                snoozes[id] = .merged(parent)
            }
        }
    }

    /// A baseline another snooze in the same repository has already recorded, so a second
    /// `next release` snooze does not have to wait for a poll to start counting.
    private func releaseBaseline(for repository: String) -> ReleaseMark? {
        for snooze in snoozes.values {
            if case .nextRelease(repository, let baseline?) = snooze { return baseline }
        }
        return nil
    }
}

// MARK: - Evaluation

extension Derivation {
    /// What evaluating a snooze reads besides the snoozed pull request itself.
    ///
    /// Built from the *whole* snapshot rather than the visible rows: a snooze can wait on a
    /// pull request the user has since dismissed, and dismissing it does not change whether
    /// it merged.
    struct SnoozeContext {
        let byID: [PRID: PullRequest]
        let branches: [BranchKey: [PullRequest]]
        let local: LocalState
        let now: Date

        init(snapshot: RawSnapshot, local: LocalState, now: Date) {
            byID = Dictionary(
                snapshot.pullRequests.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            branches = MergeChain.headIndex(snapshot.pullRequests)
            self.local = local
            self.now = now
        }
    }

    /// The stack layout derivation draws for `snapshot`, built the same way: dismissed rows
    /// left out, every merge staged against the whole snapshot.
    static func stackLayout(snapshot: RawSnapshot, local: LocalState) -> StackLayout {
        let visible = snapshot.pullRequests.filter { !local.dismissed.contains($0.id) }
        let branches = MergeChain.headIndex(snapshot.pullRequests)
        let stages = Dictionary(
            visible.map { ($0.id, releaseStage(for: $0, in: branches, local: local)) },
            uniquingKeysWith: { first, _ in first }
        )
        return StackLayout.build(
            pullRequests: visible,
            viewerLogin: snapshot.viewerLogin,
            releaseStages: stages
        )
    }

    /// Whether `pullRequest` is snoozed right now. `releaseStage` is its own, already
    /// derived, which `Until any change` needs to rebuild the digest it compares.
    ///
    /// A target the snapshot does not hold keeps the row asleep unless its release was
    /// already recorded. Missing is not the same as merged — the first poll after a launch
    /// has not fetched everything yet — and ``LocalState/resolveSnoozes(in:now:isComplete:)``
    /// is what settles a target that is gone for good.
    static func isSnoozed(_ pullRequest: PullRequest, releaseStage: ReleaseStage, context: SnoozeContext) -> Bool {
        guard let snooze = context.local.snoozes[pullRequest.id] else { return false }
        switch snooze {
        case .until(let deadline):
            return context.now < deadline
        case .anyChange(let digest, let updatedAt):
            return ReadDigest.make(for: pullRequest, releaseStage: releaseStage) == digest
                && pullRequest.updatedAt <= updatedAt
        case .merged(let target):
            if context.local.releaseBindings[target] != nil { return false }
            guard let parent = context.byID[target] else { return true }
            return parent.state == .open
        case .released(let target):
            if context.local.releaseBindings[target] != nil { return false }
            guard let parent = context.byID[target] else { return true }
            let stage = Derivation.releaseStage(for: parent, in: context.branches, local: context.local)
            return !RowStatusResolver.resolve(pullRequest: parent, releaseStage: stage, parent: nil).belongsInDone
        case .nextRelease:
            return true
        }
    }
}
