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
