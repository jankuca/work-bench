import Foundation
import XCTest
@testable import PRStackCore

/// The rules the row view reads but cannot check: the status phrase, the meta line's
/// composition and order, the release track, and the emphasis tiers.
final class RowPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600) // 2025-12-29T12:00:00Z

    private func present(
        _ pullRequest: PullRequest,
        local: LocalState = .empty,
        showsRepoName: Bool = false
    ) throws -> RowPresentation {
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: [pullRequest])
        let model = Derivation.derive(snapshot: snapshot, local: local, now: now)
        let row = try XCTUnwrap(model.row(pullRequest.id))
        return RowPresentation.make(row: row, showsRepoName: showsRepoName, now: now)
    }

    private func pullRequest(
        number: Int = 100,
        repo: String = "acme/web",
        title: String = "A title",
        updatedAgo: TimeInterval = 3 * 60 * 60
    ) -> PullRequest {
        PullRequest(
            repo: repo,
            number: number,
            title: title,
            headRef: "jk/branch-\(number)",
            baseRef: "main",
            updatedAt: now.addingTimeInterval(-updatedAgo)
        )
    }

    // MARK: - Meta line

    /// Identifier · repo · number · phrase · age, in that order (IMPLEMENTATION_PLAN §5).
    func testMetaLineOrder() throws {
        var pr = pullRequest()
        pr.reviewDecision = .approved
        pr.linearIssues = [IssueRef(identifier: "BIL-312", projectID: "p", projectName: "Billing")]

        let presented = try present(pr, showsRepoName: true)

        XCTAssertEqual(
            presented.meta.map(\.text),
            ["BIL-312", "acme/web", "#100", "approved", "3h"]
        )
    }

    /// The repo name only appears when the list spans more than one repository
    /// (PRD §12.3). It is the panel's most common token and the least informative one
    /// when everything shares it.
    func testRepositoryTokenOnlyWhenTheListSpansRepositories() throws {
        let presented = try present(pullRequest(), showsRepoName: false)
        XCTAssertFalse(presented.meta.contains { $0.text == "acme/web" })
    }

    /// No identifier, no placeholder — the line simply starts at the number. The `Other`
    /// heading already says the ticket is missing.
    func testNoIssueOmitsTheIdentifierEntirely() throws {
        var pr = pullRequest()
        pr.mergeable = .conflicting

        let presented = try present(pr)

        XCTAssertEqual(presented.meta.map(\.text), ["#100", "merge conflict", "3h"])
        XCTAssertNil(presented.issueURL)
        XCTAssertTrue(presented.issues.isEmpty)
    }

    func testAdditionalIssuesBecomeAnAffixAfterThePrimary() throws {
        var pr = pullRequest()
        pr.linearIssues = [
            IssueRef(identifier: "BIL-312", projectID: "p", projectName: "Billing"),
            IssueRef(identifier: "BIL-313", projectID: "p", projectName: "Billing"),
            IssueRef(identifier: "SRC-9", projectID: "q", projectName: "Search")
        ]

        let presented = try present(pr)

        XCTAssertEqual(presented.meta.first?.text, "BIL-312")
        XCTAssertEqual(presented.meta.dropFirst().first?.text, "+2")
        XCTAssertEqual(presented.issues.map(\.identifier), ["BIL-312", "BIL-313", "SRC-9"])
    }

    /// The primary is the first issue *with a project*, which need not be the first
    /// issue. It still leads the cycle order, and the others keep their own order.
    func testIssueCycleOrderLeadsWithThePrimary() throws {
        var pr = pullRequest()
        pr.linearIssues = [
            IssueRef(identifier: "ORP-1"),
            IssueRef(identifier: "BIL-312", projectID: "p", projectName: "Billing"),
            IssueRef(identifier: "ORP-2")
        ]

        let presented = try present(pr)

        XCTAssertEqual(presented.issues.map(\.identifier), ["BIL-312", "ORP-1", "ORP-2"])
        XCTAssertEqual(presented.meta.first?.text, "BIL-312")
    }

    func testSnoozedRowShowsItsRemainingTime() throws {
        var pr = pullRequest()
        pr.mergeable = .conflicting
        let local = LocalState(snoozedUntil: [pr.id: now.addingTimeInterval(2 * 60 * 60)])

        let presented = try present(pr, local: local)

        XCTAssertEqual(presented.meta.last?.text, "snoozed 2h")
        // Snooze silences the ask without hiding the status.
        XCTAssertFalse(presented.isTinted)
        XCTAssertEqual(presented.emphasis, .dim)
        XCTAssertEqual(presented.chipTone, .danger)
    }

    // MARK: - Status phrase

    func testEveryStatusHasExactlyOnePhrase() {
        let parent = PRID(repo: "acme/web", number: 12)
        for status in RowStatus.allCases(sampleParent: parent, sampleTag: "v1.4.0") {
            let row = PanelRow(
                pullRequest: pullRequest(),
                status: status,
                releaseStage: .unmerged,
                isAttention: false,
                isSuppressed: false,
                snoozedUntil: nil,
                isUnread: false,
                spine: .none,
                runBase: nil,
                stackRoot: nil
            )
            let phrase = RowPresentation.phrase(for: row)
            XCTAssertFalse(phrase.isEmpty, "\(status.token) has no phrase")
            XCTAssertFalse(phrase.contains("·"), "\(status.token)'s phrase is two phrases")
        }
    }

    func testFailingCheckPhraseAgreesWithTheCount() throws {
        var one = pullRequest(number: 101)
        one.checks = .failing(1)
        var many = pullRequest(number: 102)
        many.checks = .failing(4)
        // The short fixture form `"checks": "failing"` and a rollup GitHub summarised
        // without per-context detail both land here.
        var uncounted = pullRequest(number: 103)
        uncounted.checks = CheckRollup(state: .failing, failingCount: 0)

        XCTAssertTrue(try present(one).meta.map(\.text).contains("1 check failed"))
        XCTAssertTrue(try present(many).meta.map(\.text).contains("4 checks failed"))
        XCTAssertTrue(try present(uncounted).meta.map(\.text).contains("checks failed"))
    }

    func testBlockedPhraseNamesTheParent() throws {
        let base = PullRequest(
            repo: "acme/web",
            number: 10,
            title: "Base",
            headRef: "jk/one",
            baseRef: "main",
            updatedAt: now
        )
        let child = PullRequest(
            repo: "acme/web",
            number: 11,
            title: "Child",
            headRef: "jk/two",
            baseRef: "jk/one",
            updatedAt: now
        )
        let model = Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "viewer", pullRequests: [base, child]),
            local: .empty,
            now: now
        )
        let row = try XCTUnwrap(model.row(child.id))

        let presented = RowPresentation.make(row: row, showsRepoName: false, now: now)

        XCTAssertTrue(presented.meta.map(\.text).contains("waiting on #10"))
        XCTAssertEqual(presented.chipGlyph, .bar)
        XCTAssertEqual(presented.emphasis, .dim)
        XCTAssertEqual(presented.spine, SpineDraw(drawsUp: false, drawsDown: true))
    }

    // MARK: - Release track

    func testTrackFillsLeftToRightAsTheWorkProgresses() throws {
        var open = pullRequest(number: 201)
        open.checks = .passing
        XCTAssertEqual(try present(open).segments, [.passing, .empty, .empty])

        var merged = pullRequest(number: 202)
        merged.checks = .passing
        merged.state = .merged
        merged.mergedAt = now.addingTimeInterval(-3600)
        XCTAssertEqual(try present(merged).segments, [.passing, .passing, .empty])

        let released = try present(
            merged,
            local: LocalState(releaseBindings: [merged.id: "v1.4.0"])
        )
        XCTAssertEqual(released.segments, [.passing, .passing, .passing])
        XCTAssertTrue(released.meta.map(\.text).contains("released in v1.4.0"))
    }

    /// A pull request closed without merging never reached trunk, so nothing past the
    /// first segment may fill.
    func testClosedWithoutMergingLeavesTheTrackUnfilled() throws {
        var closed = pullRequest(number: 203)
        closed.checks = .passing
        closed.state = .closed

        let presented = try present(closed)

        XCTAssertEqual(presented.segments, [.passing, .empty, .empty])
        XCTAssertTrue(presented.isDismissible)
        XCTAssertEqual(presented.chipGlyph, .bar)
    }

    func testRunningChecksAreAmberNotFailing() throws {
        var pr = pullRequest(number: 204)
        pr.checks = .running

        XCTAssertEqual(try present(pr).segments.first, .running)
        XCTAssertEqual(SegmentState.running.tone, .inFlight)
        XCTAssertNil(SegmentState.empty.tone)
    }

    // MARK: - Emphasis and tint

    /// The tint is attention and nothing else. Unread is the gutter dot's job — the two
    /// are different questions and the panel answers them in different places (§5).
    func testTintTracksAttentionNotUnread() throws {
        var attention = pullRequest(number: 301)
        attention.mergeable = .conflicting
        let attentionRow = try present(attention)
        XCTAssertTrue(attentionRow.isTinted)
        XCTAssertTrue(attentionRow.isUnread)
        XCTAssertEqual(attentionRow.emphasis, .strong)

        var calm = pullRequest(number: 302)
        calm.reviewDecision = .approved
        // Never seen before, so unread — and still untinted.
        let calmRow = try present(calm)
        XCTAssertTrue(calmRow.isUnread)
        XCTAssertFalse(calmRow.isTinted)
        XCTAssertEqual(calmRow.emphasis, .normal)
    }

    func testDoneRowsDateFromTheirEndingInThePastForm() throws {
        var merged = pullRequest(number: 401, updatedAgo: 60)
        merged.state = .merged
        merged.mergedAt = now.addingTimeInterval(-22 * 60)

        // Merged but untagged is still in flight, so it keeps the bare form.
        XCTAssertTrue(try present(merged).meta.map(\.text).contains("1m"))

        let shipped = try present(merged, local: LocalState(releaseBindings: [merged.id: "v2"]))
        XCTAssertTrue(shipped.meta.map(\.text).contains("22m ago"))
    }

    // MARK: - Reviewers

    func testReviewersDeduplicateAndOverflow() throws {
        var pr = pullRequest(number: 501)
        pr.reviews = [
            ReviewerState(login: "jan-kuca", state: .approved),
            ReviewerState(login: "jan-kuca", state: .commented),
            ReviewerState(login: "tsmith", state: .changesRequested),
            ReviewerState(login: "pl", state: .commented),
            ReviewerState(login: "sofia.vega", state: .pending)
        ]

        let presented = try present(pr)

        XCTAssertEqual(presented.reviewers.map(\.initials), ["JK", "TS", "PL"])
        // First occurrence wins, so the approval survives the later comment.
        XCTAssertEqual(presented.reviewers.first?.tone, .success)
        XCTAssertEqual(presented.reviewers[1].tone, .danger)
        XCTAssertEqual(presented.reviewers[2].tone, .neutral)
        XCTAssertEqual(presented.overflowReviewers, 1)
    }

    func testInitialsFallBackToThePrefixWhenTheLoginHasOnePart() {
        XCTAssertEqual(ReviewerBadge.initials(for: "octocat"), "OC")
        XCTAssertEqual(ReviewerBadge.initials(for: "jan-kuca"), "JK")
        XCTAssertEqual(ReviewerBadge.initials(for: "sofia.vega"), "SV")
        XCTAssertEqual(ReviewerBadge.initials(for: "a"), "A")
        XCTAssertEqual(ReviewerBadge.initials(for: "---"), "?")
    }

    // MARK: - Spine

    func testSpineDirectionsMatchRunPosition() {
        XCTAssertEqual(SpineDraw(.none), .none)
        XCTAssertEqual(SpineDraw(.top), SpineDraw(drawsUp: false, drawsDown: true))
        XCTAssertEqual(SpineDraw(.middle), SpineDraw(drawsUp: true, drawsDown: true))
        XCTAssertEqual(SpineDraw(.base), SpineDraw(drawsUp: true, drawsDown: false))
        XCTAssertFalse(SpineDraw(.none).isVisible)
    }
}

final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600)

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    func testShortFormRoundsDown() {
        XCTAssertEqual(RelativeTime.short(since: ago(0), now: now), "now")
        XCTAssertEqual(RelativeTime.short(since: ago(59), now: now), "now")
        XCTAssertEqual(RelativeTime.short(since: ago(60), now: now), "1m")
        XCTAssertEqual(RelativeTime.short(since: ago(119), now: now), "1m")
        XCTAssertEqual(RelativeTime.short(since: ago(3 * 3600 + 59 * 60), now: now), "3h")
        XCTAssertEqual(RelativeTime.short(since: ago(2 * 86_400), now: now), "2d")
        XCTAssertEqual(RelativeTime.short(since: ago(21 * 86_400), now: now), "3w")
    }

    func testPastFormNamesYesterdayAndCountsEverythingElse() {
        XCTAssertEqual(RelativeTime.past(since: ago(34), now: now), "34s ago")
        XCTAssertEqual(RelativeTime.past(since: ago(22 * 60), now: now), "22m ago")
        XCTAssertEqual(RelativeTime.past(since: ago(23 * 3600), now: now), "23h ago")
        XCTAssertEqual(RelativeTime.past(since: ago(86_400), now: now), "yesterday")
        XCTAssertEqual(RelativeTime.past(since: ago(2 * 86_400 - 1), now: now), "yesterday")
        XCTAssertEqual(RelativeTime.past(since: ago(2 * 86_400), now: now), "2d ago")
        XCTAssertEqual(RelativeTime.past(since: ago(14 * 86_400), now: now), "2w ago")
    }

    /// Clock skew between GitHub and this machine is the usual cause of a future
    /// timestamp, and `-2m` would be reporting the skew rather than the pull request.
    func testFutureTimestampsReadAsTheFloor() {
        XCTAssertEqual(RelativeTime.short(since: now.addingTimeInterval(120), now: now), "now")
        XCTAssertEqual(RelativeTime.past(since: now.addingTimeInterval(120), now: now), "0s ago")
    }

    /// The one place that rounds *up*: a snooze with 90 seconds left reading `1m` would
    /// go on reading `1m` for a minute and a half.
    func testRemainingRoundsUp() {
        XCTAssertEqual(RelativeTime.remaining(until: now.addingTimeInterval(90), now: now), "2m")
        XCTAssertEqual(RelativeTime.remaining(until: now.addingTimeInterval(3600), now: now), "1h")
        XCTAssertEqual(RelativeTime.remaining(until: now.addingTimeInterval(3601), now: now), "2h")
        XCTAssertEqual(RelativeTime.remaining(until: now.addingTimeInterval(30), now: now), "<1m")
        XCTAssertEqual(RelativeTime.remaining(until: now.addingTimeInterval(-30), now: now), "<1m")
    }
}

/// Header, banner, footer and the three states from IMPLEMENTATION_PLAN §5.
final class PanelPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600)

    private func panel(
        _ name: String,
        github: SourceHealth = .connected,
        linear: SourceHealth = .connected,
        syncedAgo: TimeInterval? = 34,
        isRefreshing: Bool = false
    ) throws -> PanelPresentation {
        let fixture = try Fixtures.load(name)
        return PanelPresentation.make(
            model: fixture.derive(),
            status: PanelStatus(
                github: github,
                linear: linear,
                lastSyncedAt: syncedAgo.map { fixture.now.addingTimeInterval(-$0) },
                isRefreshing: isRefreshing
            ),
            now: fixture.now
        )
    }

    func testHeaderCountsOpenAndShipping() throws {
        let presented = try panel("panel-2a")
        XCTAssertEqual(presented.header.title, "Pull requests")
        XCTAssertEqual(presented.header.summary, "6 in review · 1 shipping")
    }

    /// `0 shipping` is a count of nothing, and the panel below already shows its absence.
    func testHeaderDropsAZeroHalf() {
        let model = PanelModel(
            sections: [],
            showsRepoNames: false,
            attentionCount: 0,
            unreadCount: 0,
            summary: PanelSummary(openCount: 4, shippingCount: 0)
        )
        let presented = PanelPresentation.make(model: model, status: .unconfigured, now: now)
        XCTAssertEqual(presented.header.summary, "4 in review")
    }

    func testSectionHeadingsAndClearAll() throws {
        let presented = try panel("panel-2a")
        guard case .sections(let sections) = presented.body else {
            return XCTFail("expected sections")
        }
        XCTAssertEqual(sections.map(\.heading), ["Payments", "Billing", "Other", "Done"])
        XCTAssertEqual(sections.map(\.clearAllTitle), [nil, nil, nil, "Clear all"])
        XCTAssertEqual(sections.map(\.isMuted), [false, false, false, true])
    }

    /// Connected with nothing to show is a stated message, not an empty list.
    func testAllClearIsStated() throws {
        let presented = try panel("empty-state")
        guard case .allClear(let message) = presented.body else {
            return XCTFail("expected the all-clear state")
        }
        XCTAssertEqual(message.title, "Everything's clear")
    }

    /// Nothing connected and nothing cached is the first run, not a clear day.
    func testNoSourceAndNoRowsIsTheConnectPrompt() throws {
        let presented = try panel("empty-state", github: .unconfigured, syncedAgo: nil)
        guard case .connect = presented.body else {
            return XCTFail("expected the connect prompt")
        }
    }

    /// What licenses "Everything's clear" is a completed sync, not the health of the
    /// connection right now.
    func testAllClearNeedsASyncToHaveHappenedNotAWorkingConnection() throws {
        // Never synced and no rows: the panel has not seen the list, whatever the reason.
        for health in [SourceHealth.unauthorized("bad credentials"), .unreachable("timed out")] {
            let presented = try panel("empty-state", github: health, syncedAgo: nil)
            guard case .connect = presented.body else {
                return XCTFail("\(health) with no sync should not claim everything is clear")
            }
        }

        // Synced, found nothing, and the poll since then failed: still true, and the
        // footer says how long ago. Offering "Connect GitHub" here would ask the user to
        // fix an account that is already connected.
        let expired = try panel("empty-state", github: .unauthorized("bad credentials"))
        guard case .allClear = expired.body else {
            return XCTFail("a verified-empty list stays clear under an expired token")
        }
        // The banner is what says the list can no longer be verified.
        XCTAssertEqual(expired.banner?.message, "GitHub token expired")

        let unreachable = try panel("empty-state", github: .unreachable("timed out"))
        guard case .allClear = unreachable.body else {
            return XCTFail("a verified-empty list stays clear under a failed poll")
        }
        XCTAssertNil(unreachable.banner)
    }

    /// The banner comes off the top of the panel; the rows stay. Losing the token does
    /// not make what was fetched untrue, only unverifiable.
    func testExpiredTokenKeepsCachedRowsUnderABanner() throws {
        let presented = try panel("panel-2a", github: .unauthorized("bad credentials"))

        guard case .sections(let sections) = presented.body else {
            return XCTFail("expected the cached rows to survive")
        }
        XCTAssertFalse(sections.isEmpty)
        XCTAssertEqual(presented.banner?.actionTitle, "Reconnect")
        // The badge does go: every attention row on screen is now unverifiable (§5).
        XCTAssertEqual(presented.attentionCount, 0)
        XCTAssertEqual(presented.footer.syncTone, .danger)
        XCTAssertEqual(presented.footer.syncText, "disconnected · last synced 34s ago")
    }

    func testFooterGoesStaleOnTheClockNotOnTheFailure() throws {
        let fresh = try panel("panel-2a", github: .unreachable("timed out"), syncedAgo: 4)
        XCTAssertEqual(fresh.footer.syncTone, .inFlight)
        XCTAssertEqual(fresh.footer.syncText, "stale · last synced 4s ago")

        let old = try panel("panel-2a", syncedAgo: PanelStatus.staleAfter + 60)
        XCTAssertEqual(old.footer.syncTone, .inFlight)
        XCTAssertEqual(old.footer.syncText, "stale · last synced 6m ago")

        let current = try panel("panel-2a", syncedAgo: 34)
        XCTAssertEqual(current.footer.syncTone, .success)
        XCTAssertEqual(current.footer.syncText, "synced 34s ago")
    }

    /// Stale means *behind its own schedule*, not older than a fixed age (M8). The
    /// five-minute floor is what keeps a skipped 30-second tick from raising a warning;
    /// above it the current interval leads, so a cadence the user cannot see is not held
    /// to a promise it never made.
    func testStalenessMeasuresAgainstTheCurrentInterval() {
        let model = PanelModel(
            sections: [],
            showsRepoNames: false,
            attentionCount: 0,
            unreadCount: 0,
            summary: PanelSummary(openCount: 1, shippingCount: 0)
        )
        func footer(interval: TimeInterval?, syncedAgo: TimeInterval) -> FooterPresentation {
            PanelPresentation.make(
                model: model,
                status: PanelStatus(
                    github: .connected,
                    linear: .connected,
                    lastSyncedAt: now.addingTimeInterval(-syncedAgo),
                    pollInterval: interval
                ),
                now: now
            ).footer
        }

        // Panel open at 30 s: three missed ticks are still inside the floor.
        XCTAssertEqual(footer(interval: 30, syncedAgo: 90).syncTone, .success)
        // On battery at 15 minutes: six-minute-old rows are exactly on schedule, and the
        // fixed threshold alone would have called them stale.
        XCTAssertEqual(footer(interval: 15 * 60, syncedAgo: 6 * 60).syncText, "synced 6m ago")
        XCTAssertEqual(
            footer(interval: 15 * 60, syncedAgo: 16 * 60).syncText,
            "stale · last synced 16m ago"
        )
        // Suspended — asleep — carries no interval, so the floor decides. A laptop that
        // woke from an overnight sleep reads stale immediately.
        XCTAssertEqual(footer(interval: nil, syncedAgo: 8 * 3600).syncTone, .inFlight)
    }

    /// Three strings nothing else reaches: the footer before any poll has succeeded.
    func testFooterBeforeTheFirstSync() throws {
        let unconfigured = try panel("empty-state", github: .unconfigured, syncedAgo: nil)
        XCTAssertEqual(unconfigured.footer.syncTone, .neutral)
        XCTAssertEqual(unconfigured.footer.syncText, "not connected")

        let expired = try panel("empty-state", github: .unauthorized("bad credentials"), syncedAgo: nil)
        XCTAssertEqual(expired.footer.syncTone, .danger)
        XCTAssertEqual(expired.footer.syncText, "disconnected")

        // Never synced *and* failing is red rather than grey. There is no cached list
        // underneath this one to be recently true, so "nothing has arrived yet" is not a
        // neutral fact about timing — it is the failure, and the message is beside it.
        let unreachable = try panel("empty-state", github: .unreachable("timed out"), syncedAgo: nil)
        XCTAssertEqual(unreachable.footer.syncTone, .danger)
        XCTAssertEqual(unreachable.footer.syncText, "never synced")
        XCTAssertEqual(unreachable.footer.errorMessage, "timed out")
    }

    /// "Is it actually running?" is the question the footer exists to answer, and until
    /// now it only ever reported on the poll before this one.
    func testFooterSaysWhenAPollIsInFlight() throws {
        let syncing = try panel("panel-2a", isRefreshing: true)
        XCTAssertTrue(syncing.footer.isSyncing)
        XCTAssertEqual(syncing.footer.syncTone, .inFlight)
        XCTAssertEqual(syncing.footer.syncText, "syncing…")

        // And outranks every resting state, each of which describes the *previous* poll.
        // A retry that is happening is the more current fact than the failure it retries.
        let retrying = try panel("panel-2a", github: .unreachable("timed out"), isRefreshing: true)
        XCTAssertEqual(retrying.footer.syncText, "syncing…")
        // The failure it is retrying still shows: it is the last thing known to be true,
        // and the poll under way has not yet disproved it.
        XCTAssertEqual(retrying.footer.errorMessage, "timed out")

        XCTAssertFalse(try panel("panel-2a").footer.isSyncing)
    }

    /// The report is read a line at a time, so a value that contains a newline would end
    /// its record early and be parsed as another. Failure messages are the one field that
    /// can carry one — a server's response body reaches this straight from the transport.
    func testTheReportEscapesLineBreaksInAValue() throws {
        let presented = try panel(
            "panel-2a",
            github: .unreachable("GitHub returned HTTP 502:\n<html>\r\n</html>")
        )
        let rendered = PanelPresentationReport.render(presented)
        let footers = rendered.split(separator: "\n").filter { $0.hasPrefix("footer ") }

        XCTAssertEqual(footers.count, 1, "the message must not break the footer into several records")
        XCTAssertTrue(
            footers[0].contains(#"error="GitHub returned HTTP 502:\n<html>\r\n</html>""#),
            "expected the breaks escaped in place, got \(footers[0])"
        )
    }

    /// A transient failure is stated, not hidden behind a hover. The two failures that are
    /// already said elsewhere — an expired token, no token at all — are not repeated.
    func testFooterStatesATransientFailure() throws {
        XCTAssertEqual(
            try panel("panel-2a", github: .unreachable("could not reach GitHub: the request timed out"))
                .footer.errorMessage,
            "could not reach GitHub: the request timed out"
        )
        XCTAssertNil(
            try panel("panel-2a", github: .unauthorized("bad credentials")).footer.errorMessage,
            "the reconnect banner already says this, next to the button that fixes it"
        )
        XCTAssertNil(try panel("panel-2a", github: .unconfigured).footer.errorMessage)
        XCTAssertNil(try panel("panel-2a").footer.errorMessage)
        // Linear's failures cost the panel its project headings and nothing else, so they
        // stay a footnote and the hover detail (§4).
        XCTAssertNil(
            try panel("panel-2a", linear: .unreachable("could not reach Linear")).footer.errorMessage
        )
    }

    /// The footer says how it is at a glance and why on hover. A connected source has no
    /// "why", so nothing is offered.
    func testFooterCarriesTheFailureDetail() throws {
        XCTAssertEqual(
            try panel("panel-2a", github: .unreachable("the request timed out")).footer.detail,
            "the request timed out"
        )
        XCTAssertEqual(
            try panel("panel-2a", github: .unauthorized("bad credentials")).footer.detail,
            "bad credentials"
        )
        XCTAssertNil(try panel("panel-2a").footer.detail)
    }

    func testMarkAllReadHidesWithNothingUnread() throws {
        let fixture = try Fixtures.load("panel-2a")
        var local = fixture.resolvedLocal()
        local.markAllRead(in: fixture.snapshot)

        let presented = PanelPresentation.make(
            model: Derivation.derive(snapshot: fixture.snapshot, local: local, now: fixture.now),
            status: PanelStatus(github: .connected, lastSyncedAt: fixture.now),
            now: fixture.now
        )

        XCTAssertFalse(presented.footer.showsMarkAllRead)
        XCTAssertTrue(try panel("panel-2a").footer.showsMarkAllRead)
    }

    func testAttentionCountSurvivesAReachableSource() throws {
        let presented = try panel("panel-2a")
        XCTAssertEqual(presented.attentionCount, 4)
        // Any GitHub failure drops it, not just an expired token: a badge counting four
        // cached failures asserts something the app cannot currently verify, and how the
        // connection broke does not change that (§5).
        XCTAssertEqual(try panel("panel-2a", github: .unreachable("timed out")).attentionCount, 0)
    }

    // MARK: - Linear (M5)

    /// Linear is a **footer condition and nothing more**. Losing it costs the panel its
    /// project headings for identifiers it has never cached; every row still renders, with
    /// its status, its checks and its reviewers. So: a note, never a banner, and never the
    /// badge (IMPLEMENTATION_PLAN §4/§5).
    func testLinearBeingUnreachableIsAFooterNoteAndNothingElse() throws {
        let presented = try panel("panel-2a", linear: .unreachable("could not reach Linear: timed out"))

        XCTAssertEqual(presented.footer.linearNote, "Linear stale")
        XCTAssertNil(presented.banner, "Linear must never raise the reconnect banner")
        XCTAssertEqual(presented.attentionCount, 4, "and must never touch the badge")
        // The sync tone still reports GitHub, which is healthy. The rows are current.
        XCTAssertEqual(presented.footer.syncTone, .success)
        XCTAssertEqual(presented.footer.syncText, "synced 34s ago")
        XCTAssertEqual(presented.footer.detail, "could not reach Linear: timed out")
    }

    func testAnExpiredLinearKeyReadsAsDisconnectedInTheFooter() throws {
        let presented = try panel("panel-2a", linear: .unauthorized("Linear rejected the API key"))
        XCTAssertEqual(presented.footer.linearNote, "Linear disconnected")
        XCTAssertNil(presented.banner)
    }

    /// A source the user has never connected is not stale. Linear is optional, and the
    /// panel says nothing about it until there is something to say.
    func testAHealthyOrUnconfiguredLinearAddsNoNote() throws {
        XCTAssertNil(try panel("panel-2a").footer.linearNote)
        XCTAssertNil(try panel("panel-2a", linear: .unconfigured).footer.linearNote)
    }

    /// Both sources' messages reach the hover detail, GitHub first — it is the one whose
    /// failure the rows depend on.
    func testTheFooterDetailCarriesBothSources() throws {
        let presented = try panel(
            "panel-2a",
            github: .unauthorized("bad credentials"),
            linear: .unreachable("timed out")
        )
        XCTAssertEqual(presented.footer.detail, "bad credentials · timed out")
    }
}
