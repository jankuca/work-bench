import XCTest
@testable import PRStackCore

/// The conditions a snooze can wait for, how each one wakes, and what a sleeping row
/// stops contributing to the header and the menu bar.
final class SnoozeConditionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600) // 2025-12-29T12:00:00Z

    private func pullRequest(
        _ number: Int,
        repo: String = "acme/web",
        base: String = "main",
        state: GitHubState = .open,
        checks: CheckRollup = .passing,
        updatedAgo: TimeInterval = 3600
    ) -> PullRequest {
        PullRequest(
            repo: repo,
            number: number,
            title: "PR \(number)",
            headRef: "jk/\(number)",
            baseRef: base,
            state: state,
            checks: checks,
            mergeCommit: state == .merged ? "sha\(number)" : nil,
            updatedAt: now.addingTimeInterval(-updatedAgo),
            mergedAt: state == .merged ? now.addingTimeInterval(-updatedAgo) : nil
        )
    }

    private func id(_ number: Int, repo: String = "acme/web") -> PRID {
        PRID(repo: repo, number: number)
    }

    private func derive(_ pullRequests: [PullRequest], _ local: LocalState) -> PanelModel {
        Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "viewer", pullRequests: pullRequests),
            local: local,
            now: now
        )
    }

    private func isSuppressed(_ number: Int, _ pullRequests: [PullRequest], _ local: LocalState) throws -> Bool {
        try XCTUnwrap(derive(pullRequests, local).row(id(number))).isSuppressed
    }

    // MARK: - Another pull request merging

    func testMergedWaitsForTheTargetToMerge() throws {
        let local = LocalState(snoozes: [id(2): .merged(id(1))])
        let child = pullRequest(2, base: "jk/1", checks: .failing(1))

        XCTAssertTrue(try isSuppressed(2, [pullRequest(1), child], local))
        XCTAssertFalse(try isSuppressed(2, [pullRequest(1, state: .merged), child], local))
        // Closed without merging is never going to merge, so waiting on it is over too.
        XCTAssertFalse(try isSuppressed(2, [pullRequest(1, state: .closed), child], local))
    }

    /// A target the snapshot does not hold keeps the row asleep — missing is not merged —
    /// unless its release is already on record, which only a merge can have.
    func testMissingTargetStaysAsleepUnlessItIsKnownToHaveShipped() throws {
        var local = LocalState(snoozes: [id(2): .merged(id(1))])
        XCTAssertTrue(try isSuppressed(2, [pullRequest(2)], local))

        local.releaseBindings[id(1)] = "v1.0.0"
        XCTAssertFalse(try isSuppressed(2, [pullRequest(2)], local))
    }

    // MARK: - Stacked pull requests snoozing on their own

    private func autoSnooze(_ local: inout LocalState, _ pullRequests: [PullRequest], isComplete: Bool = true) {
        local.autoSnoozeStackedPullRequests(
            in: RawSnapshot(viewerLogin: "viewer", pullRequests: pullRequests),
            isComplete: isComplete
        )
    }

    /// Every layer sitting on an open parent waits for that parent; the base, which
    /// targets trunk, and a row on nothing at all are left alone.
    func testAutoSnoozeWaitsForEachLayersParent() throws {
        let stack = [pullRequest(1), pullRequest(2, base: "jk/1"), pullRequest(3, base: "jk/2"), pullRequest(4)]
        var local = LocalState()
        autoSnooze(&local, stack)

        XCTAssertEqual(local.snoozes, [id(2): .merged(id(1)), id(3): .merged(id(2))])
        XCTAssertFalse(try isSuppressed(1, stack, local))
        XCTAssertTrue(try isSuppressed(2, stack, local))
        XCTAssertTrue(try isSuppressed(3, stack, local))
        XCTAssertFalse(try isSuppressed(4, stack, local))
    }

    /// The snooze is the ordinary `merged` one, so the parent merging wakes the child and
    /// the next poll drops it — without snoozing it again against a parent that is gone.
    func testAutoSnoozeWakesWhenTheParentMerges() throws {
        var local = LocalState()
        autoSnooze(&local, [pullRequest(1), pullRequest(2, base: "jk/1")])

        let merged = [pullRequest(1, state: .merged), pullRequest(2, base: "jk/1")]
        XCTAssertFalse(try isSuppressed(2, merged, local))
        local.resolveSnoozes(
            in: RawSnapshot(viewerLogin: "viewer", pullRequests: merged),
            now: now,
            isComplete: true
        )
        autoSnooze(&local, merged)
        XCTAssertNil(local.snoozes[id(2)])
    }

    /// Waking a row by hand sticks: the next poll sees the same parent and leaves it be.
    func testAutoSnoozeHappensOncePerParent() {
        let stack = [pullRequest(1), pullRequest(2, base: "jk/1")]
        var local = LocalState()
        autoSnooze(&local, stack)
        local.wake(id(2))
        autoSnooze(&local, stack)

        XCTAssertNil(local.snoozes[id(2)])
        XCTAssertEqual(local.autoSnoozed, [id(2): id(1)])
    }

    /// A row moved onto a different open parent is waiting on something new.
    func testAutoSnoozeAgainWhenTheParentChanges() {
        var local = LocalState()
        autoSnooze(&local, [pullRequest(1), pullRequest(3), pullRequest(2, base: "jk/1")])
        local.wake(id(2))
        autoSnooze(&local, [pullRequest(1, state: .closed), pullRequest(3), pullRequest(2, base: "jk/3")])

        XCTAssertEqual(local.snoozes[id(2)], .merged(id(3)))
    }

    /// The user's own snooze is never replaced, and once it ends the row stays awake.
    func testAutoSnoozeKeepsTheUsersOwnSnooze() {
        let stack = [pullRequest(1), pullRequest(2, base: "jk/1")]
        let deadline = now.addingTimeInterval(86_400)
        var local = LocalState(snoozes: [id(2): .until(deadline)])
        autoSnooze(&local, stack)
        XCTAssertEqual(local.snoozes[id(2)], .until(deadline))

        local.pruneSnoozes(before: deadline.addingTimeInterval(1))
        autoSnooze(&local, stack)
        XCTAssertNil(local.snoozes[id(2)])
    }

    /// The record goes once the row is no longer open, or — from a poll that saw the whole
    /// list — once the row has gone. A partial poll proves nothing about what it missed.
    func testAutoSnoozeRecordIsPruned() {
        var local = LocalState(autoSnoozed: [id(2): id(1), id(3): id(1), id(4): id(1)])
        autoSnooze(&local, [pullRequest(2, state: .merged), pullRequest(3)], isComplete: false)
        XCTAssertEqual(local.autoSnoozed, [id(3): id(1), id(4): id(1)])

        autoSnooze(&local, [pullRequest(3)], isComplete: true)
        XCTAssertEqual(local.autoSnoozed, [id(3): id(1)])
    }

    // MARK: - Another pull request being released

    func testReleasedWaitsPastTheMergeForTheTag() throws {
        var local = LocalState(snoozes: [id(2): .released(id(1))])
        let child = pullRequest(2)

        XCTAssertTrue(try isSuppressed(2, [pullRequest(1), child], local))
        XCTAssertTrue(try isSuppressed(2, [pullRequest(1, state: .merged), child], local), "Merged is not released")

        local.releaseBindings[id(1)] = "v1.0.0"
        XCTAssertFalse(try isSuppressed(2, [pullRequest(1, state: .merged), child], local))
    }

    /// A target that closed without merging will never be released.
    func testReleasedWakesWhenTheTargetIsAbandoned() throws {
        let local = LocalState(snoozes: [id(2): .released(id(1))])
        XCTAssertFalse(try isSuppressed(2, [pullRequest(1, state: .closed), pullRequest(2)], local))
    }

    // MARK: - Any change

    func testAnyChangeWakesOnADigestChangeOrAnUpdate() throws {
        let original = pullRequest(1, checks: .running)
        var local = LocalState.empty
        local.snooze(original.id, .anyChange, in: RawSnapshot(viewerLogin: "viewer", pullRequests: [original]), now: now)
        XCTAssertTrue(try isSuppressed(1, [original], local))

        var checked = original
        checked.checks = .passing
        XCTAssertFalse(try isSuppressed(1, [checked], local), "A check finishing is a change")

        var pushed = original
        pushed.updatedAt = now
        XCTAssertFalse(try isSuppressed(1, [pushed], local), "A push is a change")
    }

    /// Once awake it stays awake, even if the change is undone before the next look.
    func testAnyChangeStaysAwakeOnceResolved() throws {
        let original = pullRequest(1, checks: .running)
        var local = LocalState.empty
        local.snooze(original.id, .anyChange, in: RawSnapshot(viewerLogin: "viewer", pullRequests: [original]), now: now)

        var changed = original
        changed.checks = .failing(1)
        local.resolveSnoozes(in: RawSnapshot(viewerLogin: "viewer", pullRequests: [changed]), now: now, isComplete: true)

        XCTAssertNil(local.snoozes[original.id])
        XCTAssertFalse(try isSuppressed(1, [original], local))
    }

    // MARK: - The next release

    func testNextReleaseTakesABaselineThenWakesOnALaterRelease() {
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: [pullRequest(1)])
        var local = LocalState.empty
        local.snooze(id(1), .nextRelease, in: snapshot, now: now)
        XCTAssertEqual(local.snoozes[id(1)], .nextRelease(repository: "acme/web", baseline: nil))
        XCTAssertEqual(local.releaseWatchRepositories, ["acme/web"])

        let v1 = ReleaseMark(tag: "v1.0.0", taggedAt: now, count: 3)
        local.observeReleases(["acme/web": v1])
        XCTAssertEqual(local.snoozes[id(1)], .nextRelease(repository: "acme/web", baseline: v1))

        // The same release again, and another repository's, change nothing.
        local.observeReleases(["acme/web": v1, "acme/api": ReleaseMark(tag: "v9", taggedAt: now, count: 9)])
        XCTAssertNotNil(local.snoozes[id(1)])

        local.observeReleases(["acme/web": ReleaseMark(tag: "v1.1.0", taggedAt: now.addingTimeInterval(60), count: 4)])
        XCTAssertNil(local.snoozes[id(1)])
        XCTAssertTrue(local.releaseWatchRepositories.isEmpty)
    }

    /// A second snooze in the same repository starts from the baseline the first one
    /// already has, rather than waiting a poll for its own.
    func testNextReleaseReusesAKnownBaseline() {
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: [pullRequest(1), pullRequest(2)])
        let v1 = ReleaseMark(tag: "v1.0.0", taggedAt: now, count: 3)
        var local = LocalState(snoozes: [id(1): .nextRelease(repository: "acme/web", baseline: v1)])

        local.snooze(id(2), .nextRelease, in: snapshot, now: now)

        XCTAssertEqual(local.snoozes[id(2)], .nextRelease(repository: "acme/web", baseline: v1))
    }

    /// Only a poll can wake it, so derivation always reads it as asleep.
    func testNextReleaseIsAsleepUntilObserved() throws {
        let local = LocalState(snoozes: [id(1): .nextRelease(repository: "acme/web", baseline: nil)])
        XCTAssertTrue(try isSuppressed(1, [pullRequest(1)], local))
    }

    func testReleaseMarkOrdering() {
        let base = ReleaseMark(tag: "v2", taggedAt: now, count: 5)
        XCTAssertFalse(base.isLater(than: base))
        // A tag on an older commit still adds one.
        XCTAssertTrue(ReleaseMark(tag: "v2", taggedAt: now, count: 6).isLater(than: base))
        XCTAssertTrue(ReleaseMark(tag: "v3", taggedAt: now.addingTimeInterval(1), count: 5).isLater(than: base))
        // The newest one deleted is not a release.
        XCTAssertFalse(ReleaseMark(tag: "v1", taggedAt: now.addingTimeInterval(-1), count: 4).isLater(than: base))
        // The first release a repository ever cuts.
        XCTAssertTrue(ReleaseMark(tag: "v1", taggedAt: now, count: 1).isLater(than: ReleaseMark(tag: nil, taggedAt: nil, count: 0)))
    }

    // MARK: - Resolving

    func testResolvingDropsMetConditionsAndKeepsTheRest() {
        var local = LocalState(snoozes: [
            id(1): .until(now.addingTimeInterval(-1)),
            id(2): .until(now.addingTimeInterval(60)),
            id(3): .merged(id(10)),
            id(4): .merged(id(11)),
            id(5): .nextRelease(repository: "acme/web", baseline: nil)
        ])
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: [
            pullRequest(1), pullRequest(2), pullRequest(3), pullRequest(4), pullRequest(5),
            pullRequest(10, state: .merged), pullRequest(11)
        ])

        local.resolveSnoozes(in: snapshot, now: now, isComplete: true)

        XCTAssertEqual(Set(local.snoozes.keys), [id(2), id(4), id(5)])
    }

    /// A snoozed row missing from the snapshot is only gone if the snapshot is the whole
    /// list. A partial one proves nothing about it.
    func testResolvingDropsAMissingRowOnlyFromACompleteSnapshot() {
        let snoozes: [PRID: Snooze] = [id(1): .merged(id(10))]
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: [pullRequest(10)])

        var partial = LocalState(snoozes: snoozes)
        partial.resolveSnoozes(in: snapshot, now: now, isComplete: false)
        XCTAssertEqual(partial.snoozes, snoozes)

        var complete = LocalState(snoozes: snoozes)
        complete.resolveSnoozes(in: snapshot, now: now, isComplete: true)
        XCTAssertTrue(complete.snoozes.isEmpty)
    }

    /// A row that has finished cannot be asleep, so its snooze is done with too.
    func testAFinishedRowIsNeverSuppressedAndLosesItsSnooze() throws {
        var local = LocalState(snoozes: [id(1): .until(now.addingTimeInterval(3600))])
        local.releaseBindings[id(1)] = "v1.0.0"
        let shipped = pullRequest(1, state: .merged)

        XCTAssertFalse(try isSuppressed(1, [shipped], local))
        local.resolveSnoozes(in: RawSnapshot(viewerLogin: "viewer", pullRequests: [shipped]), now: now, isComplete: true)
        XCTAssertTrue(local.snoozes.isEmpty)
    }

    func testSnoozingAgainstItselfIsIgnored() {
        var local = LocalState.empty
        local.snooze(id(1), .merged(id(1)), in: RawSnapshot(viewerLogin: "viewer", pullRequests: [pullRequest(1)]), now: now)
        XCTAssertTrue(local.snoozes.isEmpty)
    }

    // MARK: - Counts

    /// A snoozed row is counted as snoozed and nowhere else, and asks nothing of the icon.
    func testSnoozedRowsLeaveTheCountsAndTheIcon() {
        var failing = pullRequest(1, checks: .failing(1))
        failing.reviewDecision = .approved
        var ready = pullRequest(2)
        ready.reviewDecision = .approved
        ready.mergeable = .mergeable
        let merged = pullRequest(3, state: .merged)
        let local = LocalState(snoozes: [
            id(1): .until(now.addingTimeInterval(3600)),
            id(2): .until(now.addingTimeInterval(3600)),
            id(3): .until(now.addingTimeInterval(3600))
        ])

        let model = derive([failing, ready, merged, pullRequest(4)], local)

        XCTAssertEqual(model.summary, PanelSummary(openCount: 1, shippingCount: 0, snoozedCount: 3))
        XCTAssertEqual(model.attentionCount, 0)
        XCTAssertEqual(model.readyCount, 0)
        // All four are unread — none has a digest — but only the awake one lights the icon.
        XCTAssertEqual(model.unreadCount, 4)
        XCTAssertEqual(model.awakeUnreadCount, 1)
        XCTAssertEqual(IconState.resolve(model: model, status: PanelStatus(github: .connected)), .unread)

        let panel = PanelPresentation.make(model: model, status: PanelStatus(github: .connected), now: now)
        XCTAssertEqual(panel.header.summary, "1 in review · 3 snoozed")
    }

    // MARK: - Targets

    /// Stack members first, then the rest; the row itself and finished rows never; only
    /// open pull requests for `Until merged`.
    func testTargetsListTheStackFirst() throws {
        let base = pullRequest(10)
        let middle = pullRequest(11, base: "jk/10")
        let top = pullRequest(12, base: "jk/11")
        let loose = pullRequest(5)
        let shipping = pullRequest(6, state: .merged)
        let closed = pullRequest(7, state: .closed)

        let model = derive([base, middle, top, loose, shipping, closed], .empty)
        let panel = PanelPresentation.make(model: model, status: PanelStatus(github: .connected), now: now)
        guard case .sections(let sections) = panel.body else { return XCTFail("Expected rows") }
        let row = try XCTUnwrap(sections.flatMap(\.rows).first { $0.id == id(12) })

        XCTAssertEqual(row.releaseTargets.map(\.id), [id(11), id(10), id(6), id(5)])
        XCTAssertEqual(row.releaseTargets.map(\.isStackMember), [true, true, false, false])
        XCTAssertEqual(row.mergeTargets.map(\.id), [id(11), id(10), id(5)])
        XCTAssertEqual(row.mergeTargets.first?.menuTitle, "#11 PR 11")

        let done = try XCTUnwrap(sections.flatMap(\.rows).first { $0.id == id(7) })
        XCTAssertTrue(done.snoozeTargets.isEmpty, "A Done row offers no snooze at all")
    }

    // MARK: - Persistence

    func testEveryKindRoundTrips() throws {
        let snoozes: [PRID: Snooze] = [
            id(1): .until(Date(timeIntervalSince1970: 1_767_960_000)),
            id(2): .anyChange(digest: ReadDigest(value: "rd=-;ck=passing"), updatedAt: Date(timeIntervalSince1970: 1_767_000_000)),
            id(3): .merged(id(10)),
            id(4): .released(id(11, repo: "acme/api")),
            id(5): .nextRelease(repository: "acme/web", baseline: nil),
            id(6): .nextRelease(
                repository: "acme/web",
                baseline: ReleaseMark(tag: "v1", taggedAt: Date(timeIntervalSince1970: 1_767_000_000), count: 2)
            )
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(LocalState(snoozes: snoozes))
        XCTAssertEqual(try decoder.decode(LocalState.self, from: data).snoozes, snoozes)
    }

    func testAutoSnoozedRoundTripsAndIsOptional() throws {
        let data = try JSONEncoder().encode(LocalState(autoSnoozed: [id(2): id(1)]))
        XCTAssertEqual(try JSONDecoder().decode(LocalState.self, from: data).autoSnoozed, [id(2): id(1)])
        XCTAssertEqual(try JSONDecoder().decode(LocalState.self, from: Data("{}".utf8)).autoSnoozed, [:])
    }

    /// A file from before conditional snoozes still loads, as time snoozes; a kind this
    /// version does not know costs that one entry and nothing else.
    func testLegacyAndUnknownEntries() throws {
        let json = """
        {
          "snoozedUntil": {"acme/web#1": "2026-01-10T12:00:00Z", "acme/web#2": "2026-01-10T12:00:00Z"},
          "snoozes": {
            "acme/web#2": {"kind": "merged", "pullRequest": "acme/web#9"},
            "acme/web#3": {"kind": "whenTheStarsAlign"}
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(LocalState.self, from: Data(json.utf8))

        let deadline = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-10T12:00:00Z"))
        XCTAssertEqual(state.snoozes, [id(1): .until(deadline), id(2): .merged(id(9))])
    }
}
