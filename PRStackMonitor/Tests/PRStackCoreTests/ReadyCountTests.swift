import Foundation
import XCTest
@testable import PRStackCore

/// What the icon's green badge counts.
///
/// The badge is a number in a menu bar, so the only thing that makes it worth drawing is
/// that every pull request behind it can actually be merged right now. These are the four
/// ways that claim could quietly stop being true.
final class ReadyCountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_009_600) // 2025-12-29T12:00:00Z

    private func pullRequest(
        number: Int = 100,
        baseRef: String = "main",
        state: GitHubState = .open,
        reviewDecision: ReviewDecision? = .approved,
        checks: CheckRollup = .passing,
        mergeable: Mergeable = .mergeable
    ) -> PullRequest {
        PullRequest(
            repo: "acme/web",
            number: number,
            title: "Pull request \(number)",
            headRef: "jk/branch-\(number)",
            baseRef: baseRef,
            state: state,
            authorLogin: "viewer",
            reviewDecision: reviewDecision,
            checks: checks,
            mergeable: mergeable,
            updatedAt: now.addingTimeInterval(-3 * 60 * 60)
        )
    }

    private func derive(_ pullRequests: [PullRequest], local: LocalState = .empty) -> PanelModel {
        Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "viewer", pullRequests: pullRequests),
            local: local,
            now: now
        )
    }

    func testApprovedPassingAndMergeableIsCounted() {
        let model = derive([pullRequest(number: 100), pullRequest(number: 101)])
        XCTAssertEqual(model.rows.map(\.status), [.readyToMerge, .readyToMerge])
        XCTAssertEqual(model.readyCount, 2)
        XCTAssertEqual(model.attentionCount, 0)
    }

    /// `approved` is green in the panel and is not this. An approval with the checks still
    /// running is not something the user can act on, and a badge that counted it would be
    /// promising a merge button that is not there yet.
    func testApprovedWithoutPassingChecksIsNotCounted() {
        let model = derive([pullRequest(checks: .running)])
        XCTAssertEqual(model.rows.map(\.status), [.approved])
        XCTAssertEqual(model.readyCount, 0)
    }

    /// Snooze silences "go merge me" for the same reason it silences "this needs you":
    /// the user asked this row to stop asking.
    func testASnoozedReadyRowIsNotCounted() {
        var local = LocalState.empty
        local.snooze(PRID(repo: "acme/web", number: 100), until: now.addingTimeInterval(2 * 60 * 60))

        let model = derive([pullRequest(number: 100)], local: local)
        XCTAssertEqual(model.rows.map(\.status), [.readyToMerge], "Snooze suppresses, it does not restatus")
        XCTAssertEqual(model.readyCount, 0)

        // And it comes back on its own, with nothing to do but the deadline passing.
        var woken = LocalState.empty
        woken.snooze(PRID(repo: "acme/web", number: 100), until: now.addingTimeInterval(-1))
        XCTAssertEqual(derive([pullRequest(number: 100)], local: woken).readyCount, 1)
    }

    /// A stack member whose parent is still open resolves to `blocked`, not
    /// `readyToMerge` — merging it would take the parent's commits with it. The count
    /// inherits that: only the base of the run is offered.
    func testAStackedChildWaitingOnItsParentIsNotCounted() {
        let base = pullRequest(number: 100)
        let child = pullRequest(number: 101, baseRef: base.headRef)

        let model = derive([base, child])
        XCTAssertEqual(model.row(child.id)?.status, .blocked(on: base.id))
        XCTAssertEqual(model.readyCount, 1)
    }

    /// Merged and closed rows carry whatever review metadata they had at the end. A
    /// terminal status is resolved before any of it is read, so neither can land in the
    /// count.
    func testTerminalRowsAreNotCounted() {
        let model = derive([
            pullRequest(number: 100, state: .merged),
            pullRequest(number: 101, state: .closed)
        ])
        XCTAssertEqual(model.rows.map(\.status), [.merged, .closed])
        XCTAssertEqual(model.readyCount, 0)
    }

    /// The green and the red badge count disjoint sets, so the two numbers can never
    /// describe the same pull request twice.
    func testTheTwoCountsNeverOverlap() {
        let model = derive([
            pullRequest(number: 100),
            pullRequest(number: 101, reviewDecision: .changesRequested),
            pullRequest(number: 102, reviewDecision: nil, checks: .failing(2))
        ])
        XCTAssertEqual(model.readyCount, 1)
        XCTAssertEqual(model.attentionCount, 2)
        XCTAssertTrue(model.rows.allSatisfy { !($0.isReady && $0.isAttention) })
    }
}
