import Foundation
import XCTest
@testable import PRStackCore

/// The exact `[DomainEvent]` emitted between two consecutive snapshots.
///
/// This is what a future notification sink depends on, so it is worth pinning before the
/// sink exists (IMPLEMENTATION_PLAN §6). The cases are built in code rather than as JSON
/// fixtures because every one of them is a *pair* of snapshots, and the fixture format is
/// deliberately one snapshot and one clock.
final class EventDiffTests: XCTestCase {
    // MARK: - Cold start

    /// The M4 done-criterion, in one test: a relaunch emits no events but preserves
    /// unread. The digests are persisted, so the dots come back; the previous model is
    /// not, so nothing is announced.
    func testRelaunchEmitsNoEventsButPreservesUnread() throws {
        let fixture = try Fixtures.load("unread-digests")
        let relaunched = Derivation.derive(
            snapshot: fixture.snapshot,
            local: fixture.resolvedLocal(),
            previous: nil,
            now: fixture.now
        )

        let expected = try Fixtures.derive("unread-digests")
        XCTAssertEqual(relaunched.events, [])
        XCTAssertGreaterThan(
            relaunched.model.unreadCount,
            0,
            "The unread fixture should still have unread rows after a relaunch"
        )
        XCTAssertEqual(relaunched.model, expected)
    }

    /// A pull request seen for the first time is not a transition, however it looks. On
    /// the first poll that is every pull request, which is the same rule as cold start
    /// applied per row.
    func testFirstSightOfAPullRequestEmitsNothing() {
        let failing = pullRequest(4001, checks: .failing(2))
        let before = model(with: [pullRequest(4002)])
        let after = model(with: [pullRequest(4002), failing])

        XCTAssertEqual(EventDiff.events(previous: before, current: after), [])
    }

    // MARK: - Attention transitions

    func testChecksFailingAndChangesRequestedEmitOnceEach() {
        let quiet = model(with: [pullRequest(4001), pullRequest(4002)])
        let noisy = model(
            with: [
                pullRequest(4001, checks: .failing(2)),
                pullRequest(4002, reviewDecision: .changesRequested)
            ]
        )

        // Rows order by number descending, so #4002 leads.
        XCTAssertEqual(
            EventDiff.events(previous: quiet, current: noisy),
            [.changesRequested(id(4002)), .checksFailed(id(4001))]
        )
        // The same state a second time is not a second transition.
        XCTAssertEqual(EventDiff.events(previous: noisy, current: noisy), [])
    }

    /// Approved, checks green and mergeable is `readyToMerge`, and that is the one
    /// transition worth calling "became mergeable".
    func testBecameMergeableEmitsWhenTheRowTurnsReadyToMerge() {
        let waiting = model(with: [pullRequest(4001, reviewDecision: .approved, checks: .running)])
        let ready = model(
            with: [
                pullRequest(4001, reviewDecision: .approved, checks: .passing, mergeable: .mergeable)
            ]
        )

        XCTAssertEqual(EventDiff.events(previous: waiting, current: ready), [.becameMergeable(id(4001))])
    }

    /// Nothing to act on is not an event. A row falling back to `inReview`, or picking up
    /// a `blocked` parent, says nothing the panel does not already show.
    func testRecoveringToAQuietStatusEmitsNothing() {
        let failing = model(with: [pullRequest(4001, checks: .failing(1))])
        let recovered = model(with: [pullRequest(4001, checks: .passing)])

        XCTAssertEqual(EventDiff.events(previous: failing, current: recovered), [])
    }

    // MARK: - Comments

    func testNewCommentsCarriesTheDeltaNotTheTotal() {
        let before = model(with: [pullRequest(4001, commentCount: 3)])
        let after = model(with: [pullRequest(4001, commentCount: 7)])

        XCTAssertEqual(EventDiff.events(previous: before, current: after), [.newComments(id(4001), count: 4)])
        // A comment deleted is not "minus one new comments".
        XCTAssertEqual(
            EventDiff.events(previous: after, current: model(with: [pullRequest(4001, commentCount: 6)])),
            []
        )
    }

    // MARK: - Snooze

    /// `snooze-status-changed-while-asleep`: the pull request went `checksFailing` during
    /// its snooze, so the raw status is unchanged at wake and only the effective state
    /// carries the transition. Exactly one event, at wake.
    func testStatusChangedWhileAsleepEmitsExactlyOnceAtWake() {
        let deadline = Date(timeIntervalSince1970: 1_000_000)
        let local = LocalState(snoozedUntil: [id(4001): deadline])
        let snapshotBefore = snapshot(with: [pullRequest(4001)])
        let snapshotAfter = snapshot(with: [pullRequest(4001, checks: .failing(1))])

        // Asleep, and the checks start failing underneath it.
        let asleepQuiet = Derivation.derive(
            snapshot: snapshotBefore,
            local: local,
            now: deadline.addingTimeInterval(-120)
        )
        let asleepFailing = Derivation.derive(
            snapshot: snapshotAfter,
            local: local,
            previous: asleepQuiet,
            now: deadline.addingTimeInterval(-60)
        )
        XCTAssertEqual(asleepFailing.events, [], "A snoozed row announced an attention transition")

        // The deadline passes with no further input and no user action.
        let awake = Derivation.derive(
            snapshot: snapshotAfter,
            local: local,
            previous: asleepFailing.model,
            now: deadline
        )
        XCTAssertEqual(awake.events, [.checksFailed(id(4001))])

        // And once only — the next poll has nothing left to announce.
        let settled = Derivation.derive(
            snapshot: snapshotAfter,
            local: local,
            previous: awake.model,
            now: deadline.addingTimeInterval(60)
        )
        XCTAssertEqual(settled.events, [])
    }

    /// `snooze-expiry-no-underlying-change`: nothing happened during the snooze, so
    /// waking announces nothing. The transition exists in the effective state either way;
    /// what stops it here is that the status it wakes into is not an attention status.
    func testSnoozeExpiryWithNoUnderlyingChangeEmitsNothing() {
        let deadline = Date(timeIntervalSince1970: 1_000_000)
        let local = LocalState(snoozedUntil: [id(4001): deadline])
        let unchanged = snapshot(with: [pullRequest(4001)])

        let asleep = Derivation.derive(snapshot: unchanged, local: local, now: deadline.addingTimeInterval(-60))
        let awake = Derivation.derive(snapshot: unchanged, local: local, previous: asleep, now: deadline)

        XCTAssertEqual(awake.events, [])
    }

    /// Snooze silences "this needs you", not "this finished".
    func testSnoozeDoesNotWithholdReachedProduction() {
        let deadline = Date(timeIntervalSince1970: 1_000_000)
        var local = LocalState(snoozedUntil: [id(4001): deadline])
        let merged = snapshot(with: [pullRequest(4001, state: .merged)])

        let awaiting = Derivation.derive(snapshot: merged, local: local, now: deadline.addingTimeInterval(-120))
        local.releaseBindings[id(4001)] = "v3.1.0"
        let released = Derivation.derive(
            snapshot: merged,
            local: local,
            previous: awaiting,
            now: deadline.addingTimeInterval(-60)
        )

        XCTAssertEqual(released.events, [.reachedProduction(id(4001))])
        XCTAssertTrue(
            released.model.row(id(4001))?.isSuppressed == true,
            "The row should still be snoozed — the point is that it shipped anyway"
        )

        // Waking later does not announce it a second time.
        let awake = Derivation.derive(snapshot: merged, local: local, previous: released.model, now: deadline)
        XCTAssertEqual(awake.events, [])
    }

    /// Comments that arrive while a row is asleep are not replayed at wake.
    func testCommentsDuringASnoozeAreNotAnnounced() {
        let deadline = Date(timeIntervalSince1970: 1_000_000)
        let local = LocalState(snoozedUntil: [id(4001): deadline])

        let quiet = Derivation.derive(
            snapshot: snapshot(with: [pullRequest(4001, commentCount: 1)]),
            local: local,
            now: deadline.addingTimeInterval(-120)
        )
        let noisy = Derivation.derive(
            snapshot: snapshot(with: [pullRequest(4001, commentCount: 9)]),
            local: local,
            previous: quiet,
            now: deadline.addingTimeInterval(-60)
        )

        XCTAssertEqual(noisy.events, [])
    }

    /// ``DomainEventKind/isWithheldBySnooze`` documents which events a snooze silences,
    /// and nothing in the diff reads it — the withholding falls out of comparing effective
    /// states. So it is pinned against the behaviour here, or it is a comment that
    /// compiles.
    func testWithheldKindsAreTheOnesTheDiffActuallyWithholds() {
        XCTAssertEqual(
            Set(DomainEventKind.allCases.filter(\.isWithheldBySnooze)),
            [.changesRequested, .checksFailed, .becameMergeable, .newComments]
        )

        let deadline = Date(timeIntervalSince1970: 1_000_000)
        let now = deadline.addingTimeInterval(-60)
        let snoozed = LocalState(snoozedUntil: [id(4001): deadline])
        let cases: [(kind: DomainEventKind, before: PullRequest, after: PullRequest)] = [
            (.changesRequested, pullRequest(4001), pullRequest(4001, reviewDecision: .changesRequested)),
            (.checksFailed, pullRequest(4001), pullRequest(4001, checks: .failing(1))),
            (
                .becameMergeable,
                pullRequest(4001, reviewDecision: .approved),
                pullRequest(4001, reviewDecision: .approved, checks: .passing, mergeable: .mergeable)
            ),
            (.newComments, pullRequest(4001, commentCount: 1), pullRequest(4001, commentCount: 2))
        ]

        for testCase in cases {
            XCTAssertEqual(
                events(from: testCase.before, to: testCase.after, local: .empty, now: now).map(\.kind),
                [testCase.kind],
                "An awake row did not produce \(testCase.kind.rawValue)"
            )
            XCTAssertEqual(
                events(from: testCase.before, to: testCase.after, local: snoozed, now: now),
                [],
                "A snoozed row announced \(testCase.kind.rawValue)"
            )
        }
    }

    // MARK: - Ordering and determinism

    /// Events come out in the panel's own row order, which is deterministic. API order
    /// would let two polls with the same underlying change produce different lists.
    func testEventOrderFollowsTheModelAndIsRepeatable() {
        let before = model(with: [pullRequest(4001), pullRequest(4002), pullRequest(4003)])
        let after = model(
            with: [
                pullRequest(4001, checks: .failing(1)),
                pullRequest(4002, reviewDecision: .changesRequested),
                pullRequest(4003, commentCount: 2)
            ]
        )
        let reversed = model(
            with: [
                pullRequest(4003, commentCount: 2),
                pullRequest(4002, reviewDecision: .changesRequested),
                pullRequest(4001, checks: .failing(1))
            ]
        )

        // Rows order by number descending, so #4003 leads however the snapshot arrived.
        let expected: [DomainEvent] = [
            .newComments(id(4003), count: 2),
            .changesRequested(id(4002)),
            .checksFailed(id(4001))
        ]
        XCTAssertEqual(EventDiff.events(previous: before, current: after), expected)
        XCTAssertEqual(EventDiff.events(previous: before, current: reversed), expected)
    }

    /// A row that leaves the model — dismissed, or closed and cleared — takes its
    /// transitions with it rather than emitting one on the way out.
    func testDisappearingRowsEmitNothing() {
        let before = model(with: [pullRequest(4001, checks: .failing(1)), pullRequest(4002)])
        let after = model(with: [pullRequest(4002)])

        XCTAssertEqual(EventDiff.events(previous: before, current: after), [])
    }

    // MARK: - Connection

    /// Connection loss is a transition, not a state: it fires when the source goes from
    /// connected to not, and not on every poll that stays down.
    func testConnectionLostFiresOncePerTransition() {
        let connected = PanelStatus(github: .connected, lastSyncedAt: Date(timeIntervalSince1970: 1))
        let lost = PanelStatus(github: .unauthorized("token expired"), lastSyncedAt: connected.lastSyncedAt)
        let stillLost = PanelStatus(github: .unreachable("timed out"), lastSyncedAt: connected.lastSyncedAt)

        XCTAssertEqual(DomainEvent.connectionEvents(from: connected, to: lost), [.connectionLost(.github)])
        XCTAssertEqual(DomainEvent.connectionEvents(from: lost, to: stillLost), [])
        XCTAssertEqual(DomainEvent.connectionEvents(from: lost, to: connected), [])
        // Never connected is not a loss, and a cold start announces nothing at all.
        XCTAssertEqual(DomainEvent.connectionEvents(from: PanelStatus.unconfigured, to: stillLost), [])
        XCTAssertEqual(DomainEvent.connectionEvents(from: nil, to: lost), [])
    }

    // MARK: - Event metadata

    /// Every event carries the row it is about, except the one that is not about a row.
    func testEventsIdentifyTheirSubject() {
        let events: [DomainEvent] = [
            .reachedProduction(id(1)),
            .changesRequested(id(2)),
            .checksFailed(id(3)),
            .becameMergeable(id(4)),
            .newComments(id(5), count: 2),
            .connectionLost(.github)
        ]

        XCTAssertEqual(events.map(\.kind), DomainEventKind.allCases)
        for event in events {
            XCTAssertEqual(event.pullRequest == nil, event.kind == .connectionLost, event.token)
            XCTAssertFalse(event.token.isEmpty)
        }
    }

    // MARK: - Builders

    private func id(_ number: Int) -> PRID {
        PRID(repo: "acme/billing", number: number)
    }

    private func pullRequest(
        _ number: Int,
        state: GitHubState = .open,
        reviewDecision: ReviewDecision? = nil,
        checks: CheckRollup = .noChecks,
        mergeable: Mergeable = .unknown,
        commentCount: Int = 0
    ) -> PullRequest {
        PullRequest(
            repo: "acme/billing",
            number: number,
            title: "Pull request \(number)",
            headRef: "jk/n\(number)",
            baseRef: "main",
            state: state,
            reviewDecision: reviewDecision,
            checks: checks,
            mergeable: mergeable,
            mergedAt: state == .merged ? Date(timeIntervalSince1970: 900_000) : nil,
            commentCount: commentCount
        )
    }

    /// Two consecutive polls over one pull request, and the events between them.
    private func events(
        from before: PullRequest,
        to after: PullRequest,
        local: LocalState,
        now: Date
    ) -> [DomainEvent] {
        let previous = Derivation.derive(snapshot: snapshot(with: [before]), local: local, now: now)
        return Derivation.derive(
            snapshot: snapshot(with: [after]),
            local: local,
            previous: previous,
            now: now
        ).events
    }

    private func snapshot(with pullRequests: [PullRequest]) -> RawSnapshot {
        RawSnapshot(viewerLogin: "jankuca", pullRequests: pullRequests)
    }

    private func model(with pullRequests: [PullRequest]) -> PanelModel {
        Derivation.derive(
            snapshot: snapshot(with: pullRequests),
            local: .empty,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
    }
}
