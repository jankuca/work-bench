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

    /// One preference, both halves. A poll whose open search covered drafts and whose
    /// closed search did not would put a draft in the panel and then lose it the moment it
    /// was closed, which reads as the row being dismissed.
    func testTheDraftPreferenceReachesBothSearches() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])

        _ = try await GitHubPoll(client: client(transport))
            .run(scope: .all, includesDrafts: true, local: .empty, now: now)

        XCTAssertFalse(try searchQuery(transport, 0).contains("-is:draft"))
        XCTAssertFalse(try searchQuery(transport, 1).contains("-is:draft"))
    }

    /// And the default is still the narrow query, in both halves.
    func testDraftsAreExcludedFromBothSearchesByDefault() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])

        _ = try await GitHubPoll(client: client(transport)).run(scope: .all, local: .empty, now: now)

        XCTAssertTrue(try searchQuery(transport, 0).contains("-is:draft"))
        XCTAssertTrue(try searchQuery(transport, 1).contains("-is:draft"))
    }

    /// The persisted merges are what widen the closed search. Every other poll test starts
    /// from `.empty`, so without this one, dropping `local.unboundMerges` from the call
    /// would leave the suite green while a six-week-old merge quietly left the query.
    func testAWaitingMergeWidensTheClosedSearch() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])
        let local = LocalState(unboundMerges: [
            PRID(repo: "acme/billing", number: 4012): UnboundMerge(
                mergeCommit: "9f1c2ab",
                mergedAt: ISO8601DateFormatter().date(from: "2025-12-01T09:30:00Z")!
            )
        ])

        _ = try await GitHubPoll(client: client(transport)).run(scope: .all, local: local, now: now)

        XCTAssertTrue(try searchQuery(transport, 1).contains("closed:>=2025-12-01"))
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

    // MARK: - Resuming a sweep that was cut short

    /// A sweep that stopped short hands back where it stopped, and the poll after it starts
    /// there. Every bound in the client has always returned a cursor for this; until now
    /// nothing carried it anywhere, so an account whose sweep takes eight pages re-fetched the
    /// first seven on every poll — and the poll most likely to be cut off was the one that had
    /// paid the most to get where it was cut.
    func testASweepThatStoppedShortComesBackWithItsCursors() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [10], hasNextPage: true, endCursor: "open-2")),
            .json(SearchPage.json(numbers: [9], hasNextPage: false, endCursor: nil))
        ])

        let result = try await GitHubPoll(client: clientWithPageCap(transport, pageCap: 1))
            .run(scope: .all, local: .empty, now: now)

        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.isResumed, "this poll started at page one")
        XCTAssertEqual(result.cursors.open, "open-2")
        XCTAssertNil(result.cursors.closed, "the closed search reached the end of its own list")
        XCTAssertEqual(result.cursors.resumes, 0)
    }

    func testAPollResumesTheSearchThatStoppedAndSaysThatItDid() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [8], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])
        let carried = SweepCursors(
            fingerprint: GitHubPoll.fingerprint(
                scope: .all,
                includesDrafts: false,
                local: .empty,
                now: now
            ),
            open: "open-2"
        )

        let result = try await GitHubPoll(client: client(transport))
            .run(scope: .all, local: .empty, resuming: carried, now: now)

        XCTAssertEqual(try transport.requestVariables(0)["cursor"] as? String, "open-2")
        XCTAssertNil(try transport.requestVariables(1)["cursor"] as? String)
        XCTAssertTrue(result.isResumed, "the caller merges a resumed sweep rather than replacing")
        // Both searches reached the end, so there is nothing left to carry and the next poll
        // starts at page one with every row re-read.
        XCTAssertEqual(result.cursors, .none)
    }

    /// A cursor is a position in *one* result set. The closed search's lower bound moving onto
    /// a new day is a different search, and resuming it from yesterday's position would skip
    /// whatever the change brought in.
    func testCursorsFromADifferentSearchAreDiscarded() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [8], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])
        let stale = SweepCursors(fingerprint: "some other search", open: "open-2")

        let result = try await GitHubPoll(client: client(transport))
            .run(scope: .all, local: .empty, resuming: stale, now: now)

        XCTAssertNil(try transport.requestVariables(0)["cursor"] as? String)
        XCTAssertFalse(result.isResumed)
    }

    /// The middle of the chain: a sweep that resumed and stopped short again advances the
    /// count. Without this the cap above is unreachable in the suite, and a chain that never
    /// ended — or ended one poll early — would leave it green.
    func testAResumedSweepThatStopsShortAgainAdvancesTheChain() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [8], hasNextPage: true, endCursor: "open-3")),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])
        let carried = SweepCursors(
            fingerprint: GitHubPoll.fingerprint(
                scope: .all,
                includesDrafts: false,
                local: .empty,
                now: now
            ),
            open: "open-2",
            resumes: 1
        )

        let result = try await GitHubPoll(client: clientWithPageCap(transport, pageCap: 1))
            .run(scope: .all, local: .empty, resuming: carried, now: now)

        XCTAssertEqual(try transport.requestVariables(0)["cursor"] as? String, "open-2")
        XCTAssertTrue(result.isResumed)
        XCTAssertEqual(result.cursors.open, "open-3")
        XCTAssertEqual(result.cursors.resumes, 2)
    }

    /// A resumed sweep reads the end of the list, so nothing in it can see a pull request that
    /// has since sorted onto page one. The chain has to end for that reason alone.
    func testTheResumeChainStopsAtItsCap() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [8], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])
        let exhausted = SweepCursors(
            fingerprint: GitHubPoll.fingerprint(
                scope: .all,
                includesDrafts: false,
                local: .empty,
                now: now
            ),
            open: "open-9",
            resumes: SweepCursors.maximumResumes
        )

        let result = try await GitHubPoll(client: client(transport))
            .run(scope: .all, local: .empty, resuming: exhausted, now: now)

        XCTAssertNil(try transport.requestVariables(0)["cursor"] as? String)
        XCTAssertFalse(result.isResumed)
    }

    // MARK: - One budget for the whole poll

    /// The two searches and the refresh ahead of them share one allowance. Each of them used
    /// to be handed the full budget — the refresh was not counted at all — so a poll could
    /// spend three times what IMPLEMENTATION_PLAN §3's budget says before any bound noticed.
    func testTheSearchesAndTheRefreshShareOnePointBudget() async throws {
        let transport = StubTransport.always(
            .json(SearchPage.json(numbers: [10], hasNextPage: true, endCursor: "c", cost: 30))
        )
        let refreshed = KnownPullRequestFetch(pullRequests: [], pointsSpent: 50)

        let result = try await GitHubPoll(client: clientWithBudget(transport, pointBudget: 100))
            .run(scope: .all, local: .empty, refreshed: refreshed, now: now)

        // 50 spent before the sweep started, so the open search stops after two pages rather
        // than paging to the cap, and the closed search gets one page and no more.
        XCTAssertEqual(result.open.pagesFetched, 2)
        XCTAssertEqual(result.open.stopReason, .pointBudget)
        XCTAssertEqual(result.closed.pagesFetched, 1)
        XCTAssertEqual(result.closed.stopReason, .pointBudget)
        XCTAssertEqual(result.pointsSpent, 140, "50 from the refresh, 90 across three pages")
    }

    private func clientWithPageCap(_ transport: StubTransport, pageCap: Int) -> GitHubClient {
        GitHubClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: GitHubClient.Configuration(pageCap: pageCap, endpoint: endpoint)
        )
    }

    private func clientWithBudget(_ transport: StubTransport, pointBudget: Int) -> GitHubClient {
        GitHubClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: GitHubClient.Configuration(
                pointBudget: pointBudget,
                endpoint: endpoint
            )
        )
    }
}
