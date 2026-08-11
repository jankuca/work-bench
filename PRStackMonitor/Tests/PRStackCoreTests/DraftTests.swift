import Foundation
import XCTest
@testable import PRStackCore

/// What a draft is once it is in the panel at all.
///
/// The fetch decides *whether* drafts are there — that is one search qualifier, pinned in
/// GitHubKit. Everything here is the half that has to hold whichever way the preference is
/// set: a draft is its own status, it never asks for attention, and it is never counted as
/// something that is in review.
final class DraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600) // 2025-12-29T12:00:00Z

    private func draft(
        number: Int = 100,
        checks: CheckRollup = .noChecks,
        mergeable: Mergeable = .unknown,
        reviewDecision: ReviewDecision? = nil,
        state: GitHubState = .open
    ) -> PullRequest {
        PullRequest(
            repo: "acme/web",
            number: number,
            title: "Work in progress",
            headRef: "jk/branch-\(number)",
            baseRef: "main",
            isDraft: true,
            state: state,
            authorLogin: "viewer",
            reviewDecision: reviewDecision,
            checks: checks,
            mergeable: mergeable,
            updatedAt: now.addingTimeInterval(-3 * 60 * 60)
        )
    }

    private func derive(_ pullRequests: [PullRequest]) -> PanelModel {
        Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "viewer", pullRequests: pullRequests),
            local: .empty,
            now: now
        )
    }

    // MARK: - Status

    func testADraftResolvesToDraftRatherThanInReview() throws {
        let row = try XCTUnwrap(derive([draft()]).row(PRID(repo: "acme/web", number: 100)))
        XCTAssertEqual(row.status, .draft)
    }

    /// The precedence that makes the preference safe to turn on: a draft's red checks and
    /// its conflict are not a verdict on anything that has been offered to anyone, so they
    /// do not resolve to the danger statuses and cannot tint a row or redden the icon.
    func testDraftOutranksEveryLiveSignal() {
        let noisy = draft(
            checks: .failing(3),
            mergeable: .conflicting,
            reviewDecision: .changesRequested
        )
        XCTAssertEqual(
            RowStatusResolver.resolve(pullRequest: noisy, releaseStage: .unmerged, parent: nil),
            .draft
        )
        XCTAssertEqual(
            RowStatusResolver.resolve(
                pullRequest: noisy,
                releaseStage: .unmerged,
                parent: PRID(repo: "acme/web", number: 99)
            ),
            .draft
        )
    }

    /// Terminal states are facts about a pull request and still come first. A draft that
    /// was abandoned is closed, belongs in Done, and is dismissible there like any other.
    func testAClosedDraftIsClosedAndNotDraft() {
        XCTAssertEqual(
            RowStatusResolver.resolve(
                pullRequest: draft(state: .closed),
                releaseStage: .unmerged,
                parent: nil
            ),
            .closed
        )
    }

    func testADraftNeverAsksForAttention() {
        let model = derive([draft(checks: .failing(2), mergeable: .conflicting)])
        XCTAssertEqual(model.attentionCount, 0)
        XCTAssertEqual(model.rows.map(\.isAttention), [false])
        XCTAssertFalse(RowStatus.draft.isAttentionCandidate)
        XCTAssertFalse(RowStatus.draft.belongsInDone)
    }

    // MARK: - Counts

    /// `10 in review` has to mean ten pull requests in review. A draft is open, so counting
    /// it would be defensible arithmetic and a false sentence.
    func testDraftsAreCountedSeparatelyFromTheInReviewTotal() {
        var reviewed = draft(number: 200)
        reviewed.isDraft = false

        let model = derive([draft(number: 100), draft(number: 101), reviewed])

        XCTAssertEqual(model.summary.openCount, 1)
        XCTAssertEqual(model.summary.draftCount, 2)
        XCTAssertEqual(model.summary.shippingCount, 0)
    }

    /// A closed draft is in neither count — it is a Done row.
    func testAClosedDraftCountsAsNeither() {
        let model = derive([draft(number: 100, state: .closed)])
        XCTAssertEqual(model.summary.openCount, 0)
        XCTAssertEqual(model.summary.draftCount, 0)
    }

    /// With the preference off there are no drafts to count, so the header reads exactly
    /// as it did before the setting existed.
    func testTheHeaderIsUnchangedWhenThereAreNoDrafts() {
        let model = PanelModel(
            sections: [],
            showsRepoNames: false,
            attentionCount: 0,
            unreadCount: 0,
            summary: PanelSummary(openCount: 4, draftCount: 0, shippingCount: 2)
        )
        let presented = PanelPresentation.make(model: model, status: .unconfigured, now: now)
        XCTAssertEqual(presented.header.summary, "4 in review · 2 shipping")
    }

    func testTheHeaderCountsDraftsBetweenReviewAndShipping() {
        let model = PanelModel(
            sections: [],
            showsRepoNames: false,
            attentionCount: 0,
            unreadCount: 0,
            summary: PanelSummary(openCount: 4, draftCount: 2, shippingCount: 1)
        )
        let presented = PanelPresentation.make(model: model, status: .unconfigured, now: now)
        XCTAssertEqual(presented.header.summary, "4 in review · 2 drafts · 1 shipping")
    }

    func testASingleDraftIsSingular() {
        let model = PanelModel(
            sections: [],
            showsRepoNames: false,
            attentionCount: 0,
            unreadCount: 0,
            summary: PanelSummary(openCount: 0, draftCount: 1, shippingCount: 0)
        )
        let presented = PanelPresentation.make(model: model, status: .unconfigured, now: now)
        XCTAssertEqual(presented.header.summary, "1 draft")
    }

    // MARK: - Unread

    /// Marking a draft ready for review is the transition the panel exists to notice. With
    /// drafts off it shows up as the row appearing for the first time; with drafts on the
    /// row is already there, so the read digest has to carry it or the change is silent.
    func testMarkingADraftReadyMakesTheRowUnread() throws {
        let wip = draft()
        let snapshot = RawSnapshot(viewerLogin: "viewer", pullRequests: [wip])
        var local = LocalState.empty
        local.markRead([wip.id], in: snapshot)

        // Read as it stands: no dot.
        let before = Derivation.derive(snapshot: snapshot, local: local, now: now)
        XCTAssertEqual(try XCTUnwrap(before.row(wip.id)).isUnread, false)

        var ready = wip
        ready.isDraft = false
        let after = Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "viewer", pullRequests: [ready]),
            local: local,
            now: now
        )
        XCTAssertEqual(try XCTUnwrap(after.row(ready.id)).isUnread, true)
    }

    /// And the digest of everything that is not a draft is unchanged, so upgrading to a
    /// build that knows about drafts does not mark a whole panel unread.
    func testTheDigestOfANonDraftIsUnchanged() {
        var ready = draft()
        ready.isDraft = false
        XCTAssertFalse(
            ReadDigest.make(for: ready, releaseStage: .unmerged).value.contains("dr=")
        )
    }

    // MARK: - The row

    func testTheRowReadsAsADraftAndNotAsSomethingToActOn() throws {
        let model = derive([draft(checks: .failing(2))])
        let row = try XCTUnwrap(model.row(PRID(repo: "acme/web", number: 100)))
        let presented = RowPresentation.make(row: row, showsRepoName: false, now: now)

        XCTAssertEqual(presented.meta.map(\.text), ["#100", "draft", "3h"])
        XCTAssertEqual(presented.chipTone, .neutral)
        // The bar is "nothing is happening here" — a draft waits on its author, not on a
        // reviewer, and shape has to carry that as well as colour does.
        XCTAssertEqual(presented.chipGlyph, .bar)
        XCTAssertEqual(presented.emphasis, .dim)
        XCTAssertFalse(presented.isTinted)
        XCTAssertFalse(presented.isDismissible)
    }

    /// The release track is CI, merge, tag — none of which a draft is exempt from. Its
    /// first segment still reports what the checks say, because that is a fact about the
    /// branch rather than a demand on the user.
    func testTheReleaseTrackStillReportsTheChecks() throws {
        let model = derive([draft(checks: .failing(2))])
        let row = try XCTUnwrap(model.row(PRID(repo: "acme/web", number: 100)))
        let presented = RowPresentation.make(row: row, showsRepoName: false, now: now)

        XCTAssertEqual(presented.segments, [.failing, .empty, .empty])
    }
}
