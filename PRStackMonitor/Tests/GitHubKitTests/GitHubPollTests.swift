import Foundation
import NetKit
import PRStackCore
import XCTest
@testable import GitHubKit

final class MergedPullRequestSearchTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-01-20T12:00:00Z")!

    private func merge(_ number: Int, mergedAt: Date) -> [PRID: UnboundMerge] {
        [
            PRID(repo: "acme/billing", number: number):
                UnboundMerge(mergeCommit: "c\(number)", mergedAt: mergedAt)
        ]
    }

    /// Nothing waiting: the cold-start window, and no further back.
    func testTheColdStartWindowIsFourteenDays() {
        let bound = MergedPullRequestSearch.lowerBound(unbound: [:], now: now)
        XCTAssertEqual(bound, now.addingTimeInterval(-MergedPullRequestSearch.coldStartWindow))
        XCTAssertEqual(
            MergedPullRequestSearch.qualifiers(unbound: [:], now: now),
            ["is:closed", "closed:>=2026-01-06"]
        )
    }

    /// The whole reason the bound is dynamic: a merge from six weeks ago must stay inside
    /// the query, or its commit is lost and the row strands at `merged · awaiting release`.
    func testAnOldWaitingMergeWidensTheWindow() {
        let old = ISO8601DateFormatter().date(from: "2025-12-01T09:30:00Z")!
        XCTAssertEqual(
            MergedPullRequestSearch.qualifiers(unbound: merge(4012, mergedAt: old), now: now),
            ["is:closed", "closed:>=2025-12-01"]
        )
    }

    /// And a recent one never narrows it: yesterday's merges have to stay in scope even
    /// when the only thing waiting is from this morning.
    func testARecentWaitingMergeDoesNotNarrowTheWindow() {
        let today = now.addingTimeInterval(-3_600)
        XCTAssertEqual(
            MergedPullRequestSearch.lowerBound(unbound: merge(4012, mergedAt: today), now: now),
            now.addingTimeInterval(-MergedPullRequestSearch.coldStartWindow)
        )
    }
}

/// Records what it was asked and answers with a fixed result, so the poll's *sequencing*
/// can be asserted: the tracker has to see the merges the searches just found.
private final class RecordingTracker: ReleaseTracker {
    var result: ReleaseTrackerResult = .empty
    private(set) var received: [PRID: UnboundMerge] = [:]
    private(set) var calls = 0

    func poll(unbound: [PRID: UnboundMerge], now: Date) async throws -> ReleaseTrackerResult {
        calls += 1
        received = unbound
        return result
    }
}

final class GitHubPollTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-01-20T12:00:00Z")!
    private let endpoint = URL(string: "https://api.github.test/graphql")!

    private func client(_ transport: StubTransport) -> GitHubClient {
        GitHubClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: GitHubClient.Configuration(endpoint: endpoint)
        )
    }

    private func searchQuery(_ transport: StubTransport, _ index: Int) throws -> String {
        try XCTUnwrap(transport.requestVariables(index)["query"] as? String)
    }

    /// Two searches, in this order. The open one is bounded to open pull requests, which
    /// the plan's single unbounded query is not — without that, every poll would re-fetch
    /// every pull request the user has ever authored and the closed query's careful lower
    /// bound would save nothing.
    func testThePollRunsAnOpenSearchAndThenABoundedClosedOne() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [10, 11], hasNextPage: false, endCursor: nil)),
            .json(
                SearchPage.json(
                    numbers: [9],
                    hasNextPage: false,
                    endCursor: nil,
                    state: "MERGED",
                    mergedAt: "2026-01-18T10:00:00Z",
                    mergeCommit: "sha"
                )
            )
        ])

        let result = try await GitHubPoll(client: client(transport))
            .run(scope: .all, local: .empty, now: now)

        XCTAssertTrue(try searchQuery(transport, 0).contains("is:open"))
        XCTAssertTrue(try searchQuery(transport, 1).contains("is:closed"))
        XCTAssertTrue(try searchQuery(transport, 1).contains("closed:>=2026-01-06"))
        XCTAssertEqual(result.pullRequests.map(\.number), [10, 11, 9])
        XCTAssertEqual(result.viewerLogin, "avery")
        XCTAssertTrue(result.isComplete)
    }

    /// The tracker's work list is the persisted merges *plus* the ones this poll just
    /// found, so a pull request that merged seconds ago is testable against a tag cut
    /// seconds before that, on the poll it first appears.
    func testTheTrackerSeesTheMergesThisPollFound() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil)),
            .json(
                SearchPage.json(
                    numbers: [9],
                    hasNextPage: false,
                    endCursor: nil,
                    state: "MERGED",
                    mergedAt: "2026-01-18T10:00:00Z",
                    mergeCommit: "sha"
                )
            )
        ])
        let tracker = RecordingTracker()
        let id = PRID(repo: "acme/billing", number: 9)
        tracker.result = ReleaseTrackerResult(bindings: [id: "v1.4.0"])

        let result = try await GitHubPoll(client: client(transport), tracker: tracker)
            .run(scope: .all, local: .empty, now: now)

        XCTAssertEqual(tracker.calls, 1)
        XCTAssertEqual(tracker.received[id]?.mergeCommit, "sha-9")
        XCTAssertEqual(result.release.bindings, [id: "v1.4.0"])

        // The caller is the only writer: nothing is stored until it applies the result.
        var local = LocalState.empty
        result.apply(to: &local)
        XCTAssertEqual(local.releaseBindings[id], "v1.4.0")
        XCTAssertNil(local.unboundMerges[id], "a bound pull request keeps no unbound record")
    }

    /// A pull request that merges between the two requests appears in both. Derivation
    /// would draw it twice.
    func testAPullRequestInBothSearchesIsCountedOnce() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [9], hasNextPage: false, endCursor: nil)),
            .json(
                SearchPage.json(
                    numbers: [9],
                    hasNextPage: false,
                    endCursor: nil,
                    state: "MERGED",
                    mergedAt: "2026-01-20T11:59:00Z",
                    mergeCommit: "sha"
                )
            )
        ])

        let result = try await GitHubPoll(client: client(transport))
            .run(scope: .all, local: .empty, now: now)

        XCTAssertEqual(result.pullRequests.count, 1)
        // The open sighting wins, which is the one the search index agreed with first.
        XCTAssertEqual(result.pullRequests[0].state, .open)
    }

    /// Below 10% of the allowance the comparison budget drops to zero. A merge that has
    /// waited weeks can wait for the reset; spending what is left on it would cost the open
    /// list its next poll.
    func testALowAllowanceDefersReleaseTrackingEntirely() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [10], hasNextPage: false, endCursor: nil)),
            .json(
                SearchPage.json(
                    numbers: [9],
                    hasNextPage: false,
                    endCursor: nil,
                    remaining: 400,
                    state: "MERGED",
                    mergedAt: "2026-01-18T10:00:00Z",
                    mergeCommit: "sha"
                )
            )
        ])
        let tracker = RecordingTracker()

        let result = try await GitHubPoll(client: client(transport), tracker: tracker)
            .run(scope: .all, local: .empty, now: now)

        XCTAssertEqual(tracker.calls, 0)
        XCTAssertEqual(result.release.warnings.count, 1)
        XCTAssertEqual(
            result.release.warnings.first?.description.contains("deferred release tracking"),
            true
        )
    }

    /// Without a tracker the poll is still a poll — that is what a build with no
    /// `Contents: read` scope, and the dump tool without `--releases`, do.
    func testNoTrackerMeansNoReleaseWork() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [10], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])

        let result = try await GitHubPoll(client: client(transport))
            .run(scope: .all, local: .empty, now: now)
        XCTAssertEqual(result.release, .empty)
    }
}
