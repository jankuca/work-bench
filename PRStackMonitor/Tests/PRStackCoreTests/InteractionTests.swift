import Foundation
import XCTest
@testable import PRStackCore

/// M7's decisions that are not about AppKit: which actions a row offers, which key means
/// which one, where the `L` key goes next, and what a snooze duration resolves to.
///
/// The panel builds on a Mac and none of this does, which is the whole reason it is here
/// (IMPLEMENTATION_PLAN §1).
final class RowActionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600) // 2025-12-29T12:00:00Z

    private func present(
        _ pullRequest: PullRequest,
        local: LocalState = .empty
    ) throws -> RowPresentation {
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: [pullRequest])
        let model = Derivation.derive(snapshot: snapshot, local: local, now: now)
        let row = try XCTUnwrap(model.row(pullRequest.id))
        return RowPresentation.make(row: row, showsRepoName: false, now: now)
    }

    private func pullRequest(number: Int = 100, state: GitHubState = .open) -> PullRequest {
        var pr = PullRequest(
            repo: "acme/web",
            number: number,
            title: "A title",
            headRef: "jk/branch-\(number)",
            baseRef: "main",
            updatedAt: now.addingTimeInterval(-3600)
        )
        pr.state = state
        return pr
    }

    // MARK: - Keys

    /// The table from IMPLEMENTATION_PLAN §5, as a table.
    func testKeyBindings() {
        XCTAssertEqual(RowAction.forKey("r"), .markRead)
        XCTAssertEqual(RowAction.forKey("x"), .dismiss)
        XCTAssertEqual(RowAction.forKey("s"), .snooze)
        XCTAssertEqual(RowAction.forKey("l"), .openIssue)
        XCTAssertEqual(RowAction.forKey("\r"), .open)
    }

    /// Shift is not a different key. Caps lock on is the same press.
    func testKeysAreCaseInsensitive() {
        XCTAssertEqual(RowAction.forKey("R"), .markRead)
        XCTAssertEqual(RowAction.forKey("X"), .dismiss)
        XCTAssertEqual(RowAction.forKey("S"), .snooze)
        XCTAssertEqual(RowAction.forKey("L"), .openIssue)
    }

    /// An unbound key means nothing here, so the event goes on to whoever else wants it
    /// rather than being swallowed by the row under the pointer.
    func testUnboundKeysResolveToNothing() {
        for character in ["q", "1", " ", "\u{1B}"] {
            XCTAssertNil(RowAction.forKey(Character(character)), "\(character) should not be bound")
        }
    }

    /// Every case has a key, and no two share one — otherwise `forKey` would resolve by
    /// declaration order and one action would be unreachable.
    func testEveryActionHasADistinctKey() {
        let keys = RowAction.allCases.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    // MARK: - Availability

    /// An open row with nothing linked: open and snooze, and mark-read because a row the
    /// panel has never recorded a digest for is unread.
    func testOpenRowOffersOpenSnoozeAndMarkRead() throws {
        let row = try present(pullRequest())
        XCTAssertEqual(row.availableActions, [.open, .markRead, .snooze])
    }

    /// Dismissal is a Done-row action, and snooze is not: a finished pull request has no
    /// attention state left to silence.
    func testDoneRowOffersDismissalAndNotSnooze() throws {
        let row = try present(pullRequest(number: 101, state: .closed))

        XCTAssertTrue(row.isDismissible)
        XCTAssertTrue(row.supports(.dismiss))
        XCTAssertFalse(row.supports(.snooze))
    }

    /// `Mark read` on a row that is already read is a control the user cannot tell they
    /// pressed, so it is absent rather than disabled.
    func testMarkReadDisappearsOnceTheRowIsRead() throws {
        let pr = pullRequest()
        var local = LocalState.empty
        local.markRead([pr.id], in: RawSnapshot(viewerLogin: "viewer", pullRequests: [pr]))

        let row = try present(pr, local: local)

        XCTAssertFalse(row.isUnread)
        XCTAssertFalse(row.supports(.markRead))
    }

    /// `L` on a pull request with no ticket is a no-op, so the action is not offered and
    /// the key falls through.
    func testIssueActionRequiresALinkedIssue() throws {
        var pr = pullRequest()
        XCTAssertFalse(try present(pr).supports(.openIssue))

        pr.linearIssues = [IssueRef(identifier: "BIL-1", projectID: "p", projectName: "Billing")]
        XCTAssertTrue(try present(pr).supports(.openIssue))
    }

    /// The row menu says `Wake now` instead of `Snooze` once the row is asleep, which it
    /// reads off the row rather than off the meta line's display token.
    func testSnoozedRowReportsItself() throws {
        let pr = pullRequest()
        var local = LocalState.empty
        local.snooze(pr.id, until: now.addingTimeInterval(3600))

        let row = try present(pr, local: local)

        XCTAssertTrue(row.isSnoozed)
        XCTAssertTrue(row.supports(.snooze))
    }

    /// An expired deadline is awake, not snoozed — the row resumes with no further input
    /// and no user action (IMPLEMENTATION_PLAN §1).
    func testExpiredSnoozeIsNotSnoozed() throws {
        let pr = pullRequest()
        var local = LocalState.empty
        local.snooze(pr.id, until: now.addingTimeInterval(-1))

        XCTAssertFalse(try present(pr, local: local).isSnoozed)
    }
}

/// The `(row, index)` pair behind repeated `L` presses.
final class IssueCycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600)

    private func row(number: Int, identifiers: [String]) throws -> RowPresentation {
        var pr = PullRequest(
            repo: "acme/web",
            number: number,
            title: "A title",
            headRef: "jk/branch-\(number)",
            baseRef: "main",
            updatedAt: now.addingTimeInterval(-3600)
        )
        pr.linearIssues = identifiers.map {
            IssueRef(identifier: $0, projectID: "proj", projectName: "Billing")
        }
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: [pr])
        let model = Derivation.derive(snapshot: snapshot, local: .empty, now: now)
        let derived = try XCTUnwrap(model.row(pr.id))
        return RowPresentation.make(row: derived, showsRepoName: false, now: now)
    }

    /// Primary first, then the rest, then back to the primary — a two-ticket row
    /// alternates rather than going quiet after the second press.
    func testCyclingWrapsBackToThePrimary() throws {
        let row = try row(number: 100, identifiers: ["BIL-1", "BIL-2", "BIL-3"])
        var cycle = IssueCycle()

        let opened = (0..<4).compactMap { _ in cycle.next(for: row)?.identifier }

        XCTAssertEqual(opened, ["BIL-1", "BIL-2", "BIL-3", "BIL-1"])
    }

    /// The failure the pair exists to prevent: hover a three-ticket row, press twice,
    /// hover another row, and the next press must open *that* row's primary.
    func testHoveringAnotherRowStartsAtItsOwnPrimary() throws {
        let first = try row(number: 100, identifiers: ["BIL-1", "BIL-2", "BIL-3"])
        let second = try row(number: 101, identifiers: ["SRC-9"])
        var cycle = IssueCycle()

        _ = cycle.next(for: first)
        _ = cycle.next(for: first)

        XCTAssertEqual(cycle.next(for: second)?.identifier, "SRC-9")
        // And coming back is a fresh cycle too, not a resumed one.
        XCTAssertEqual(cycle.next(for: first)?.identifier, "BIL-1")
    }

    /// What the popover closing does. A reopened panel never continues a cycle whose
    /// position the user cannot see.
    func testResetReturnsToThePrimary() throws {
        let row = try row(number: 100, identifiers: ["BIL-1", "BIL-2"])
        var cycle = IssueCycle()

        _ = cycle.next(for: row)
        cycle.reset()

        XCTAssertEqual(cycle.next(for: row)?.identifier, "BIL-1")
    }

    /// A row with no ticket answers nothing, and does not leave a position behind for the
    /// next row to inherit.
    func testARowWithNoIssuesAnswersNothing() throws {
        let linked = try row(number: 100, identifiers: ["BIL-1", "BIL-2"])
        let bare = try row(number: 101, identifiers: [])
        var cycle = IssueCycle()

        _ = cycle.next(for: linked)
        XCTAssertNil(cycle.next(for: bare))
        XCTAssertEqual(cycle.next(for: linked)?.identifier, "BIL-1")
    }
}

/// What the duration menu resolves to. A fixed calendar, because a wake time is a
/// wall-clock time and the point of the test is that it lands on the right one.
final class SnoozeDurationTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague") ?? .init(secondsFromGMT: 0)!
        return calendar
    }()

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: iso), "unparseable date \(iso)")
    }

    private func components(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
    }

    func testHourlyDurationsAreElapsedTime() throws {
        let now = try date("2026-08-06T14:32:00Z")
        XCTAssertEqual(SnoozeDuration.oneHour.wakeTime(from: now, calendar: calendar), now.addingTimeInterval(3600))
        XCTAssertEqual(SnoozeDuration.fourHours.wakeTime(from: now, calendar: calendar), now.addingTimeInterval(14400))
    }

    /// Tomorrow morning, in the user's own time zone — 2026-08-06T22:32Z is already the
    /// 7th in Prague, so "tomorrow" is the 8th there and not the 7th.
    func testTomorrowIsTheNextLocalMorning() throws {
        let now = try date("2026-08-06T22:32:00Z")
        let wake = SnoozeDuration.tomorrow.wakeTime(from: now, calendar: calendar)
        let parts = components(wake)

        XCTAssertEqual(parts.day, 8)
        XCTAssertEqual(parts.month, 8)
        XCTAssertEqual(parts.hour, SnoozeDuration.morningHour)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertGreaterThan(wake, now)
    }

    /// Thursday's "Until Monday" is four days out.
    func testUntilMondayFromMidweek() throws {
        let now = try date("2026-08-06T14:32:00Z") // a Thursday
        let wake = SnoozeDuration.nextWeek.wakeTime(from: now, calendar: calendar)
        let parts = components(wake)

        XCTAssertEqual(parts.weekday, 2)
        XCTAssertEqual(parts.day, 10)
        XCTAssertEqual(parts.hour, SnoozeDuration.morningHour)
    }

    /// The case the "counting from tomorrow" rule exists for: pressed on a Monday, it
    /// means the *next* Monday, not a snooze that expires the same morning.
    func testUntilMondayOnAMondayIsTheFollowingWeek() throws {
        let now = try date("2026-08-10T06:00:00Z") // a Monday, 08:00 local — before the wake hour
        let wake = SnoozeDuration.nextWeek.wakeTime(from: now, calendar: calendar)
        let parts = components(wake)

        XCTAssertEqual(parts.weekday, 2)
        XCTAssertEqual(parts.day, 17)
        XCTAssertGreaterThan(wake.timeIntervalSince(now), 6 * 24 * 3600)
    }

    /// Whatever the calendar does, a snooze always lands in the future — a deadline in the
    /// past is a control that visibly does nothing.
    func testEveryDurationIsInTheFuture() throws {
        let now = try date("2026-08-06T14:32:00Z")
        for duration in SnoozeDuration.allCases {
            XCTAssertGreaterThan(duration.wakeTime(from: now, calendar: calendar), now, "\(duration)")
        }
    }
}

/// The `LocalState` half: what the menu writes, and what survives a relaunch.
final class LocalStateActionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600)
    private let id = PRID(repo: "acme/web", number: 100)

    func testSnoozeAndWakeAreASingleKey() {
        var local = LocalState.empty
        local.snooze(id, until: now.addingTimeInterval(3600))
        XCTAssertEqual(local.snoozedUntil[id], now.addingTimeInterval(3600))

        local.wake(id)
        XCTAssertNil(local.snoozedUntil[id])
        // Waking a row that is not asleep is what the menu does when the deadline passed
        // while the panel was open.
        local.wake(id)
        XCTAssertNil(local.snoozedUntil[id])
    }

    /// A dismissed row never renders again, so its wake time has nothing left to wake.
    func testDismissalClearsTheSnooze() {
        var local = LocalState.empty
        local.snooze(id, until: now.addingTimeInterval(3600))
        local.dismiss(id)

        XCTAssertTrue(local.dismissed.contains(id))
        XCTAssertNil(local.snoozedUntil[id])
    }

    /// Expired deadlines leave the file; live ones stay. Without this the state file grows
    /// an entry per pull request the user has ever silenced.
    func testPruningDropsOnlyExpiredDeadlines() {
        let expired = PRID(repo: "acme/web", number: 1)
        let live = PRID(repo: "acme/web", number: 2)
        let exact = PRID(repo: "acme/web", number: 3)

        var local = LocalState.empty
        local.snooze(expired, until: now.addingTimeInterval(-1))
        local.snooze(live, until: now.addingTimeInterval(60))
        // Derivation suppresses while `now < deadline`, so a deadline exactly at `now` is
        // already awake and pruning it agrees with that.
        local.snooze(exact, until: now)

        local.pruneSnoozes(before: now)

        XCTAssertEqual(Set(local.snoozedUntil.keys), [live])
    }

    /// M7's other half, end to end: "a dismissal and a snooze set before a relaunch are
    /// still in force after it."
    ///
    /// Through the real store and a second one over the same path — a relaunch — and then
    /// through derivation, because surviving the file is only half of being in force.
    func testDismissalAndSnoozeSurviveARelaunch() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prstack-m7-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")

        let snoozed = PullRequest(
            repo: "acme/web",
            number: 100,
            title: "Snoozed",
            headRef: "jk/n100",
            baseRef: "main",
            checks: .failing(2),
            updatedAt: now.addingTimeInterval(-3600)
        )
        let dismissed = PullRequest(
            repo: "acme/web",
            number: 101,
            title: "Dismissed",
            headRef: "jk/n101",
            baseRef: "main",
            state: .closed,
            updatedAt: now.addingTimeInterval(-7200)
        )
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: [snoozed, dismissed])

        var local = LocalState.empty
        local.snooze(snoozed.id, until: now.addingTimeInterval(3600))
        local.dismiss(dismissed.id)
        try FileStateStore(url: url).save(local)

        // The relaunch: a new store over the same file, and nothing carried in memory.
        let reloaded = FileStateStore(url: url).load()
        XCTAssertNil(reloaded.failure)

        let model = Derivation.derive(snapshot: snapshot, local: reloaded.state, now: now)
        let row = try XCTUnwrap(model.row(snoozed.id))

        XCTAssertNil(model.row(dismissed.id), "a dismissed pull request never renders again")
        XCTAssertTrue(row.isSuppressed)
        XCTAssertFalse(row.isAttention, "failing checks, but asleep — no tint and no badge")
        XCTAssertEqual(model.attentionCount, 0)
    }

    /// Pruning is not allowed to disturb anything else in the file.
    func testPruningLeavesTheRestOfTheStateAlone() {
        var local = LocalState.empty
        local.dismiss(PRID(repo: "acme/web", number: 9))
        local.bind(PRID(repo: "acme/web", number: 8), toRelease: "v1.2.0")
        local.snooze(id, until: now.addingTimeInterval(-1))

        var pruned = local
        pruned.pruneSnoozes(before: now)

        XCTAssertEqual(pruned.dismissed, local.dismissed)
        XCTAssertEqual(pruned.releaseBindings, local.releaseBindings)
        XCTAssertTrue(pruned.snoozedUntil.isEmpty)
    }
}
