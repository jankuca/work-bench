import Foundation
import XCTest
@testable import PRStackCore

/// Merge-commit capture: what the panel remembers about a merged pull request while it
/// waits for a release tag, and what that remembering costs if it is wrong.
final class UnboundMergeTests: XCTestCase {
    private let mergedAt = Date(timeIntervalSince1970: 1_767_900_000)

    private func merged(
        _ number: Int,
        repo: String = "acme/billing",
        commit: String? = "9f1c2ab",
        mergedAt: Date? = nil
    ) -> PullRequest {
        PullRequest(
            repo: repo,
            number: number,
            title: "Merged \(number)",
            headRef: "avery/branch-\(number)",
            baseRef: "main",
            state: .merged,
            mergeCommit: commit,
            updatedAt: mergedAt ?? self.mergedAt,
            mergedAt: mergedAt ?? self.mergedAt
        )
    }

    func testOnlyMergedPullRequestsWithACommitAreRecorded() {
        var state = LocalState.empty
        let open = PullRequest(
            repo: "acme/billing",
            number: 1,
            title: "Open",
            headRef: "avery/open",
            baseRef: "main",
            updatedAt: mergedAt
        )
        state.recordMerges(from: [open, merged(2), merged(3, commit: nil)])

        XCTAssertEqual(Set(state.unboundMerges.keys), [PRID(repo: "acme/billing", number: 2)])
    }

    /// A merge with no commit to compare against would be a permanent no-op entry — and a
    /// live one, because it would drag the closed search's lower bound backwards forever.
    func testAMergeWithNoCommitDoesNotMoveTheQueryBound() {
        var state = LocalState.empty
        state.recordMerges(from: [merged(3, commit: nil, mergedAt: Date(timeIntervalSince1970: 1))])
        XCTAssertNil(state.oldestUnboundMergeAt)
    }

    func testAlreadyBoundAndDismissedPullRequestsAreSkipped() {
        let bound = PRID(repo: "acme/billing", number: 2)
        let gone = PRID(repo: "acme/billing", number: 3)
        var state = LocalState(dismissed: [gone], releaseBindings: [bound: "v1.4.0"])

        state.recordMerges(from: [merged(2), merged(3), merged(4)])

        XCTAssertEqual(Set(state.unboundMerges.keys), [PRID(repo: "acme/billing", number: 4)])
    }

    /// Polling is continuous, so this runs over the same pull request dozens of times an
    /// hour. Re-recording it must not throw away the tags already tested against it —
    /// that set is the only thing keeping the comparison count near zero in steady state.
    func testRecordingAgainKeepsTheComparedTags() {
        let id = PRID(repo: "acme/billing", number: 2)
        var state = LocalState.empty
        state.recordMerges(from: [merged(2)])
        state.recordComparison(id, against: "v1.4.0")

        state.recordMerges(from: [merged(2)])

        XCTAssertEqual(state.unboundMerges[id]?.comparedTags, ["v1.4.0"])
    }

    /// If the merge commit changes, those negatives were about a commit that is no longer
    /// this pull request's, and keeping them would suppress the comparison that binds it.
    func testANewMergeCommitDropsTheOldNegatives() {
        let id = PRID(repo: "acme/billing", number: 2)
        var state = LocalState.empty
        state.recordMerges(from: [merged(2)])
        state.recordComparison(id, against: "v1.4.0")

        state.recordMerges(from: [merged(2, commit: "deadbee")])

        XCTAssertEqual(state.unboundMerges[id]?.mergeCommit, "deadbee")
        XCTAssertEqual(state.unboundMerges[id]?.comparedTags, [])
    }

    func testBindingRetiresTheUnboundRecord() {
        let id = PRID(repo: "acme/billing", number: 2)
        var state = LocalState.empty
        state.recordMerges(from: [merged(2)])

        state.bind(id, toRelease: "v1.4.0")

        XCTAssertEqual(state.releaseBindings[id], "v1.4.0")
        XCTAssertNil(state.unboundMerges[id])
        // And a late negative for a bound pull request lands nowhere.
        state.recordComparison(id, against: "v1.5.0")
        XCTAssertNil(state.unboundMerges[id])
    }

    /// The lower bound of the closed search. It is the *oldest* waiting merge, because that
    /// is the one that would otherwise age out of the query and strand.
    func testTheOldestWaitingMergeIsTheQueryBound() {
        var state = LocalState.empty
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        state.recordMerges(from: [merged(2), merged(3, mergedAt: old), merged(4)])
        XCTAssertEqual(state.oldestUnboundMergeAt, old)
    }
}
