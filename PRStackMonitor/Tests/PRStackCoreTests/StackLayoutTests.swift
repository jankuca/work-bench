import Foundation
import XCTest
@testable import PRStackCore

final class StackLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_960_000)

    private func pullRequest(
        repo: String = "acme/billing",
        _ number: Int,
        head: String,
        base: String,
        state: GitHubState = .open,
        author: String = "jankuca"
    ) -> PullRequest {
        PullRequest(
            repo: repo,
            number: number,
            title: "#\(number)",
            headRef: head,
            baseRef: base,
            state: state,
            authorLogin: author,
            updatedAt: now
        )
    }

    private func id(_ number: Int, repo: String = "acme/billing") -> PRID {
        PRID(repo: repo, number: number)
    }

    func testLinearChainRendersTopMostFirst() {
        let layout = StackLayout.build(
            pullRequests: [
                pullRequest(1, head: "a", base: "main"),
                pullRequest(2, head: "b", base: "a"),
                pullRequest(3, head: "c", base: "b")
            ],
            viewerLogin: "jankuca"
        )

        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.groups.first?.root, id(1))
        XCTAssertEqual(layout.groups.first?.runs.map(\.members), [[id(3), id(2), id(1)]])
        XCTAssertEqual(layout.placement(for: id(3)).spine, .top)
        XCTAssertEqual(layout.placement(for: id(2)).spine, .middle)
        XCTAssertEqual(layout.placement(for: id(1)).spine, .base)
        XCTAssertEqual(layout.placement(for: id(2)).runBase, id(1))
    }

    func testForkGivesTheSpineToTheLongestChain() {
        let layout = StackLayout.build(
            pullRequests: [
                pullRequest(1, head: "base", base: "main"),
                // The sibling has the higher number but the shorter chain.
                pullRequest(9, head: "x", base: "base"),
                pullRequest(2, head: "y", base: "base"),
                pullRequest(3, head: "z", base: "y")
            ],
            viewerLogin: "jankuca"
        )

        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(layout.groups.first?.runs.map(\.members), [[id(3), id(2), id(1)], [id(9)]])
        // The sibling run is a run of one, so it draws no spine, but it stays in the group
        // so it renders directly beneath.
        XCTAssertEqual(layout.placement(for: id(9)).spine, .none)
        XCTAssertNil(layout.placement(for: id(9)).runBase)
        XCTAssertEqual(layout.placement(for: id(9)).groupRoot, id(1))
    }

    /// When two branches off the same base are the same depth, chain length can't decide
    /// which keeps the spine, so the higher pull request number does. Without a test the
    /// tie-break direction is free to flip and only a golden would notice.
    func testEqualLengthChainsGiveTheSpineToTheHigherNumber() {
        let layout = StackLayout.build(
            pullRequests: [
                pullRequest(1, head: "base", base: "main"),
                pullRequest(2, head: "x", base: "base"),
                pullRequest(3, head: "x2", base: "x"),
                pullRequest(4, head: "y", base: "base"),
                pullRequest(5, head: "y2", base: "y")
            ],
            viewerLogin: "jankuca"
        )

        XCTAssertEqual(layout.groups.count, 1)
        XCTAssertEqual(
            layout.groups.first?.runs.map(\.members),
            [[id(5), id(4), id(1)], [id(3), id(2)]],
            "Both branches are two deep, so #4's branch should keep the spine on number alone"
        )
        // The losing branch is long enough to be a run in its own right, so it draws its
        // own spine rather than collapsing to loose rows.
        XCTAssertEqual(layout.placement(for: id(3)).spine, .top)
        XCTAssertEqual(layout.placement(for: id(2)).spine, .base)
        XCTAssertEqual(layout.placement(for: id(2)).runBase, id(2))
        XCTAssertEqual(layout.placement(for: id(2)).groupRoot, id(1))
    }

    /// A pull request that is not itself in a cycle but whose parent chain leads into one
    /// is made loose too. It has no trunk-anchored ancestry, so there is no honest spine
    /// to draw for it, and leaving it stacked on a cycle member would render it as
    /// `blocked` on a pull request the layout has already given up on.
    func testACycleAlsoLoosensPullRequestsThatLeadIntoIt() {
        let layout = StackLayout.build(
            pullRequests: [
                pullRequest(1, head: "p", base: "q"),
                pullRequest(2, head: "q", base: "p"),
                // Outside the cycle, but based on #1's head branch.
                pullRequest(3, head: "c", base: "p")
            ],
            viewerLogin: "jankuca"
        )

        XCTAssertTrue(layout.groups.isEmpty)
        XCTAssertTrue(layout.parentOf.isEmpty)
        XCTAssertNil(layout.parentOf[id(3)], "A child of a cycle member must not resolve to blocked")
        for number in 1...3 {
            XCTAssertEqual(layout.placement(for: id(number)).spine, .none)
            XCTAssertNil(layout.placement(for: id(number)).groupRoot)
        }
    }

    func testCycleLeavesEveryMemberLoose() {
        let layout = StackLayout.build(
            pullRequests: [
                pullRequest(1, head: "p", base: "q"),
                pullRequest(2, head: "q", base: "p")
            ],
            viewerLogin: "jankuca"
        )

        XCTAssertTrue(layout.groups.isEmpty)
        XCTAssertTrue(layout.parentOf.isEmpty, "A cycle member must not keep a parent, or it would render as blocked")
        XCTAssertEqual(layout.placement(for: id(1)).spine, .none)
        XCTAssertEqual(layout.placement(for: id(2)).spine, .none)
    }

    func testBranchNamesDoNotJoinAcrossRepositories() {
        let layout = StackLayout.build(
            pullRequests: [
                pullRequest(repo: "acme/billing", 1, head: "release", base: "main"),
                pullRequest(repo: "acme/web", 2, head: "feature", base: "release")
            ],
            viewerLogin: "jankuca"
        )

        XCTAssertTrue(layout.groups.isEmpty)
        XCTAssertNil(layout.parentOf[id(2, repo: "acme/web")])
    }

    func testParentAuthoredBySomebodyElseIsNotAParent() {
        let layout = StackLayout.build(
            pullRequests: [
                pullRequest(1, head: "shared", base: "main", author: "otherdev"),
                pullRequest(2, head: "mine", base: "shared")
            ],
            viewerLogin: "jankuca"
        )

        XCTAssertTrue(layout.groups.isEmpty)
        XCTAssertNil(layout.parentOf[id(2)])
    }

    func testMergedParentDropsOutOfTheIndex() {
        let layout = StackLayout.build(
            pullRequests: [
                pullRequest(1, head: "a", base: "main", state: .merged),
                pullRequest(2, head: "b", base: "a")
            ],
            viewerLogin: "jankuca"
        )

        XCTAssertTrue(layout.groups.isEmpty)
        XCTAssertNil(layout.parentOf[id(2)])
    }

    func testAPullRequestIsNeverItsOwnParent() {
        let layout = StackLayout.build(
            pullRequests: [pullRequest(1, head: "same", base: "same")],
            viewerLogin: "jankuca"
        )

        XCTAssertNil(layout.parentOf[id(1)])
        XCTAssertTrue(layout.groups.isEmpty)
    }
}
