import Foundation
import XCTest
@testable import PRStackCore

final class RowStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_960_000)
    private let parent = PRID(repo: "acme/billing", number: 1)

    private func pullRequest(
        number: Int = 10,
        state: GitHubState = .open,
        reviewDecision: ReviewDecision? = nil,
        checks: CheckRollup = .noChecks,
        mergeable: Mergeable = .unknown
    ) -> PullRequest {
        PullRequest(
            repo: "acme/billing",
            number: number,
            title: "Title",
            headRef: "jk/head",
            baseRef: "main",
            state: state,
            authorLogin: "jankuca",
            reviewDecision: reviewDecision,
            checks: checks,
            mergeable: mergeable,
            updatedAt: now
        )
    }

    // MARK: - Precedence

    func testTerminalStatesOutrankEveryLiveSignal() {
        let closed = pullRequest(
            state: .closed,
            reviewDecision: .changesRequested,
            checks: .failing(3),
            mergeable: .conflicting
        )
        XCTAssertEqual(
            RowStatusResolver.resolve(pullRequest: closed, releaseStage: .unmerged, parent: parent),
            .closed
        )
    }

    func testMergedResolvesToShippedOnlyWhenBound() {
        let merged = pullRequest(state: .merged, mergeable: .conflicting)
        XCTAssertEqual(
            RowStatusResolver.resolve(pullRequest: merged, releaseStage: .mergedAwaitingTag, parent: nil),
            .merged
        )
        XCTAssertEqual(
            RowStatusResolver.resolve(pullRequest: merged, releaseStage: .released(tag: "v2.0.0"), parent: nil),
            .shipped(tag: "v2.0.0")
        )
    }

    func testConflictOutranksChangesRequestedAndChecks() {
        let conflicted = pullRequest(
            reviewDecision: .changesRequested,
            checks: .failing(1),
            mergeable: .conflicting
        )
        XCTAssertEqual(
            RowStatusResolver.resolve(pullRequest: conflicted, releaseStage: .unmerged, parent: nil),
            .conflicted
        )
    }

    func testChangesRequestedOutranksFailingChecks() {
        let pr = pullRequest(reviewDecision: .changesRequested, checks: .failing(2), mergeable: .mergeable)
        XCTAssertEqual(RowStatusResolver.resolve(pullRequest: pr, releaseStage: .unmerged, parent: nil), .changesRequested)
    }

    func testAttentionStatusesOutrankBlocked() {
        let pr = pullRequest(checks: .failing(1), mergeable: .mergeable)
        XCTAssertEqual(
            RowStatusResolver.resolve(pullRequest: pr, releaseStage: .unmerged, parent: parent),
            .checksFailing
        )
    }

    func testBlockedOutranksApproval() {
        let pr = pullRequest(reviewDecision: .approved, checks: .passing, mergeable: .mergeable)
        XCTAssertEqual(
            RowStatusResolver.resolve(pullRequest: pr, releaseStage: .unmerged, parent: parent),
            .blocked(on: parent)
        )
    }

    func testReadyToMergeNeedsApprovalGreenChecksAndAMergeableBranch() {
        let ready = pullRequest(reviewDecision: .approved, checks: .passing, mergeable: .mergeable)
        XCTAssertEqual(RowStatusResolver.resolve(pullRequest: ready, releaseStage: .unmerged, parent: nil), .readyToMerge)

        let checksStillRunning = pullRequest(reviewDecision: .approved, checks: .running, mergeable: .mergeable)
        XCTAssertEqual(
            RowStatusResolver.resolve(pullRequest: checksStillRunning, releaseStage: .unmerged, parent: nil),
            .approved
        )

        let mergeabilityUnknown = pullRequest(reviewDecision: .approved, checks: .passing, mergeable: .unknown)
        XCTAssertEqual(
            RowStatusResolver.resolve(pullRequest: mergeabilityUnknown, releaseStage: .unmerged, parent: nil),
            .approved
        )
    }

    func testDefaultIsInReview() {
        XCTAssertEqual(RowStatusResolver.resolve(pullRequest: pullRequest(), releaseStage: .unmerged, parent: nil), .inReview)
    }

    // MARK: - Invariants

    /// PRD §5.2's invariant, in the half that lives in core: attention is exactly
    /// conflicted, changesRequested and checksFailing — nothing else, and in particular
    /// not `blocked`, which is the layer below's problem. The other half (attention ⇒
    /// tinted ⇒ non-green icon) is pinned in PanelUI at M3.
    func testAttentionSetIsExactlyTheThreeDangerStatuses() {
        let attention = RowStatus
            .allCases(sampleParent: parent, sampleTag: "v1.0.0")
            .filter(\.isAttentionCandidate)
        XCTAssertEqual(Set(attention), Set<RowStatus>([.conflicted, .changesRequested, .checksFailing]))
    }

    /// Done holds the statuses nothing further will be learned about. `mergedUntracked`
    /// joins the two obvious ones: it merged onto a branch whose releases cannot be
    /// followed, so there is no signal still coming and leaving it in the live list would
    /// recreate the row that says `awaiting release` forever.
    func testOnlyTerminalStatusesBelongInDone() {
        let done = RowStatus
            .allCases(sampleParent: parent, sampleTag: "v1.0.0")
            .filter(\.belongsInDone)
        XCTAssertEqual(
            Set(done),
            Set<RowStatus>([.closed, .shipped(tag: "v1.0.0"), .mergedUntracked])
        )
    }

    /// `merged` specifically does *not*: it is still in flight, waiting for a release tag,
    /// and it is what the header's "N shipping" counts.
    func testAMergeAwaitingATagIsNotDone() {
        XCTAssertFalse(RowStatus.merged.belongsInDone)
    }

    func testNoStatusIsBothAttentionAndDone() {
        for status in RowStatus.allCases(sampleParent: parent, sampleTag: "v1.0.0") {
            XCTAssertFalse(
                status.isAttentionCandidate && status.belongsInDone,
                "\(status.token) is both an attention status and a Done status"
            )
        }
    }

    func testStatusTokensAreUnique() {
        let tokens = RowStatus.allCases(sampleParent: parent, sampleTag: "v1.0.0").map(\.token)
        XCTAssertEqual(Set(tokens).count, tokens.count)
    }
}
