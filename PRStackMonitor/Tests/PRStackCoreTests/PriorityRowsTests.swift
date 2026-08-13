import Foundation
import XCTest
@testable import PRStackCore

/// What the panel remembers so the next poll can refresh what it is showing before it
/// starts paging through everything in scope.
///
/// The list is a cache, not a decision — nothing derivation reads depends on it — so what
/// these pin is the *order*, which is the only thing it says: if a single request can only
/// carry so many rows, these are the ones worth carrying.
final class PriorityRowsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-01-20T12:00:00Z")!

    private func pullRequest(
        _ number: Int,
        repo: String = "acme/billing",
        state: GitHubState = .open,
        updatedMinutesAgo minutes: Double
    ) -> PullRequest {
        PullRequest(
            repo: repo,
            number: number,
            title: "Pull request \(number)",
            headRef: "avery/branch-\(number)",
            baseRef: "main",
            state: state,
            updatedAt: now.addingTimeInterval(-minutes * 60)
        )
    }

    /// A merged row's status cannot change again; an open one's can, at any moment. So an
    /// open pull request outranks a merge that happened more recently.
    func testOpenPullRequestsAreRefreshedBeforeTerminalOnes() {
        var local = LocalState.empty
        local.recordDisplayed(from: [
            pullRequest(9, state: .merged, updatedMinutesAgo: 1),
            pullRequest(10, updatedMinutesAgo: 90)
        ])

        XCTAssertEqual(
            local.displayed,
            [PRID(repo: "acme/billing", number: 10), PRID(repo: "acme/billing", number: 9)]
        )
    }

    /// Within a state, activity decides: the row something happened to five minutes ago is
    /// the row something is most likely to happen to next.
    func testTheMostRecentlyUpdatedComesFirst() {
        var local = LocalState.empty
        local.recordDisplayed(from: [
            pullRequest(10, updatedMinutesAgo: 90),
            pullRequest(12, updatedMinutesAgo: 5),
            pullRequest(11, updatedMinutesAgo: 40)
        ])

        XCTAssertEqual(local.displayed.map(\.number), [12, 11, 10])
    }

    /// Two rows updated in the same second must not swap places between polls: the list is
    /// written to disk on every one of them, and a list that reshuffles itself rewrites the
    /// state file for nothing.
    func testTiesFallBackToThePanelsOwnOrdering() {
        var local = LocalState.empty
        let rows = [
            pullRequest(10, repo: "acme/web", updatedMinutesAgo: 5),
            pullRequest(11, updatedMinutesAgo: 5)
        ]
        local.recordDisplayed(from: rows)
        var reversed = LocalState.empty
        reversed.recordDisplayed(from: rows.reversed())

        XCTAssertEqual(local.displayed.map(\.number), [11, 10])
        XCTAssertEqual(local.displayed, reversed.displayed)
    }

    /// A dismissed row never renders again. Refreshing one would spend part of a single
    /// request's budget on something nobody will see.
    func testDismissedRowsAreNotWorthRefreshing() {
        var local = LocalState.empty
        local.dismiss(PRID(repo: "acme/billing", number: 11))
        local.recordDisplayed(from: [
            pullRequest(11, updatedMinutesAgo: 1),
            pullRequest(10, updatedMinutesAgo: 5)
        ])

        XCTAssertEqual(local.displayed.map(\.number), [10])
    }

    /// And dismissing one already on the list drops it there and then, rather than at the
    /// next poll.
    func testDismissingARowDropsItFromTheList() {
        var local = LocalState.empty
        local.recordDisplayed(from: [
            pullRequest(11, updatedMinutesAgo: 1),
            pullRequest(10, updatedMinutesAgo: 5)
        ])
        local.dismiss(PRID(repo: "acme/billing", number: 11))

        XCTAssertEqual(local.displayed.map(\.number), [10])
    }

    /// One request carries so many rows and no more, so the list is cut at the same number
    /// — and cut from the *end*, which is what makes the order above worth having.
    func testTheListIsCappedAtTheLimit() {
        var local = LocalState.empty
        local.recordDisplayed(
            // Pull request 1 was updated a minute ago, 10 was updated ten minutes ago.
            from: (1...10).map { pullRequest($0, updatedMinutesAgo: Double($0)) },
            limit: 3
        )

        XCTAssertEqual(local.displayed.map(\.number), [1, 2, 3])
    }

    /// The launch case is the whole reason this is persisted: the panel starts empty, and
    /// the first poll of a new process is the one with the most to page through.
    func testTheOrderSurvivesTheStateFile() throws {
        var local = LocalState.empty
        local.recordDisplayed(from: [
            pullRequest(10, updatedMinutesAgo: 90),
            pullRequest(12, updatedMinutesAgo: 5),
            pullRequest(11, updatedMinutesAgo: 40)
        ])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LocalState.self, from: encoder.encode(local))

        XCTAssertEqual(decoded.displayed, local.displayed)
        XCTAssertEqual(decoded, local)
    }

    /// A file written before any of this existed decodes to "nothing known", which is the
    /// same poll it has always had.
    func testAFileWithoutTheListDecodesToAnEmptyOne() throws {
        let json = #"{"dismissed": ["acme/billing#4012"]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let state = try decoder.decode(LocalState.self, from: Data(json.utf8))
        XCTAssertEqual(state.displayed, [])
    }

    // MARK: - Merging a refresh into a snapshot

    /// A refresh answers for the rows it asked about and for nothing else, so it updates
    /// them in place and leaves everything around them alone.
    func testARefreshReplacesTheRowsItNamesAndKeepsTheRest() {
        let snapshot = RawSnapshot(
            viewerLogin: "avery",
            pullRequests: [
                pullRequest(10, updatedMinutesAgo: 90),
                pullRequest(11, updatedMinutesAgo: 90)
            ]
        )

        let merged = snapshot.replacing([pullRequest(11, updatedMinutesAgo: 1)])

        XCTAssertEqual(merged.pullRequests.map(\.number), [10, 11])
        XCTAssertEqual(merged.pullRequests[1].updatedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(merged.pullRequests[0].updatedAt, now.addingTimeInterval(-90 * 60))
    }

    /// On the first poll after a launch the snapshot is empty and every refreshed row is
    /// new to it. They arrive in the order they were asked for.
    func testRowsTheSnapshotHasNeverSeenAreAppendedInOrder() {
        let merged = RawSnapshot(viewerLogin: "", pullRequests: []).replacing(
            [
                pullRequest(12, updatedMinutesAgo: 5),
                pullRequest(10, updatedMinutesAgo: 90)
            ],
            viewerLogin: "avery"
        )

        XCTAssertEqual(merged.pullRequests.map(\.number), [12, 10])
        XCTAssertEqual(merged.viewerLogin, "avery")
        // The author defaults to the viewer, which is what makes these the user's own pull
        // requests as far as stack derivation is concerned.
        XCTAssertEqual(merged.pullRequests.map(\.authorLogin), ["avery", "avery"])
    }

    /// The viewer a refresh answered as is only adopted when the panel does not have one.
    /// Which account the app is on is a whole poll's conclusion, not half a one's.
    func testAKnownViewerIsNotReplacedByTheRefreshes() {
        let snapshot = RawSnapshot(
            viewerLogin: "avery",
            pullRequests: [pullRequest(10, updatedMinutesAgo: 90)]
        )

        let merged = snapshot.replacing(
            [pullRequest(10, updatedMinutesAgo: 1)],
            viewerLogin: "someone-else"
        )

        XCTAssertEqual(merged.viewerLogin, "avery")
    }
}
