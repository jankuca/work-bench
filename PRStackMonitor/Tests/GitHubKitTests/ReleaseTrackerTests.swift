import Foundation
import NetKit
import PRStackCore
import XCTest
@testable import GitHubKit

/// A transport that routes rather than replays.
///
/// The ordered ``StubTransport`` is right where the sequence *is* the thing under test. The
/// tracker interleaves one GraphQL page with a variable number of `compare` calls, so
/// keying the answers by what was asked keeps a test's intent — "this tag contains that
/// commit" — legible, and lets the assertions be about which comparisons happened at all.
final class ReleaseStubTransport: HTTPTransport {
    /// GraphQL answers, consumed in order.
    var tagPages: [HTTPResponse] = []
    /// `"<tag>...<sha>"` → the `status` GitHub answers with. Anything unlisted is `ahead`,
    /// which is a tag that does not contain the commit.
    var comparisons: [String: String] = [:]
    /// `"<tag>...<sha>"` → a failure response instead of a comparison.
    var comparisonFailures: [String: HTTPResponse] = [:]
    /// Headers on every successful comparison, for the rate-limit accounting.
    var comparisonHeaders: [String: String] = [:]

    private(set) var tagQueries: [HTTPRequest] = []
    /// Every `<tag>...<sha>` asked for, in order.
    private(set) var compared: [String] = []
    /// The comparison requests themselves, so a conditional header can be asserted.
    private(set) var comparisonRequests: [HTTPRequest] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.method == "POST" {
            tagQueries.append(request)
            guard !tagPages.isEmpty else { throw StubTransport.Unexpected(request: request) }
            return tagPages.removeFirst()
        }

        let basehead = request.url.lastPathComponent
        compared.append(basehead)
        comparisonRequests.append(request)
        if let failure = comparisonFailures[basehead] { return failure }
        let status = comparisons[basehead] ?? "ahead"
        return .json(#"{"status":"\#(status)"}"#, headers: comparisonHeaders)
    }
}

final class ReleaseTrackerTests: XCTestCase {
    private let repository = "acme/billing"
    private let commit = "9f1c2ab"
    private lazy var pullRequest = PRID(repo: repository, number: 4012)
    private let mergedAt = ReleaseTrackerTests.date(4)
    private let now = ReleaseTrackerTests.date(10)

    private static func date(_ day: Int) -> Date {
        ISO8601DateFormatter().date(from: String(format: "2026-01-%02dT12:00:00Z", day))!
    }

    private static func day(_ number: Int) -> String {
        String(format: "2026-01-%02dT12:00:00Z", number)
    }

    private func tracker(
        _ transport: ReleaseStubTransport,
        patterns: TagPatterns = .standard,
        comparisonBudget: Int = 20,
        etags: any ETagStore = InMemoryETagStore()
    ) -> TagContainmentTracker {
        TagContainmentTracker(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: TagContainmentTracker.Configuration(
                tagPatterns: patterns,
                comparisonBudget: comparisonBudget,
                tagRefs: TagRefsClient.Configuration(
                    endpoint: URL(string: "https://api.github.test/graphql")!
                ),
                restBaseURL: URL(string: "https://api.github.test")!
            ),
            etagStore: etags
        )
    }

    private func unbound(
        comparedTags: Set<String> = [],
        mergedAt: Date? = nil
    ) -> [PRID: UnboundMerge] {
        [
            pullRequest: UnboundMerge(
                mergeCommit: commit,
                mergedAt: mergedAt ?? self.mergedAt,
                comparedTags: comparedTags
            )
        ]
    }

    /// Oldest candidate first, and the first hit wins — which is what makes the binding the
    /// *earliest* release containing the merge rather than an arbitrary one.
    func testBindsTheEarliestContainingTagAndStopsThere() async throws {
        let transport = ReleaseStubTransport()
        transport.tagPages = [
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("v1.0.0", commit: "c1", date: ReleaseTrackerTests.day(5)),
                TagPage.Tag.lightweight("v1.1.0", commit: "c2", date: ReleaseTrackerTests.day(6)),
                TagPage.Tag.lightweight("v1.2.0", commit: "c3", date: ReleaseTrackerTests.day(7))
            ]))
        ]
        transport.comparisons = ["v1.1.0...\(commit)": "behind", "v1.2.0...\(commit)": "identical"]

        let result = try await tracker(transport).poll(unbound: unbound(), now: now)

        XCTAssertEqual(result.bindings, [pullRequest: "v1.1.0"])
        XCTAssertEqual(transport.compared, ["v1.0.0...\(commit)", "v1.1.0...\(commit)"])
        XCTAssertEqual(result.comparisons[pullRequest], ["v1.0.0"])
        XCTAssertEqual(result.comparisonsMade, 2)
    }

    /// A lightweight tag carries its target commit's date, so a tag cut directly on the
    /// merge commit reports exactly `mergedAt`. A strict `>` would drop it every poll and
    /// never record it as compared — the row would strand at `merged · awaiting release`,
    /// which is the failure this milestone exists to prevent.
    func testATagCutOnTheMergeCommitIsStillACandidate() async throws {
        let transport = ReleaseStubTransport()
        transport.tagPages = [
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("v1.4.0", commit: commit, date: ReleaseTrackerTests.day(4))
            ]))
        ]
        transport.comparisons = ["v1.4.0...\(commit)": "identical"]

        let result = try await tracker(transport).poll(unbound: unbound(), now: now)

        XCTAssertEqual(result.bindings, [pullRequest: "v1.4.0"])
    }

    /// A tag cut before the merge cannot contain it, so it is never worth a request.
    func testTagsOlderThanTheMergeAreNeverCompared() async throws {
        let transport = ReleaseStubTransport()
        transport.tagPages = [
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("v0.9.0", commit: "c0", date: ReleaseTrackerTests.day(1)),
                TagPage.Tag.lightweight("v1.0.0", commit: "c1", date: ReleaseTrackerTests.day(5))
            ]))
        ]
        transport.comparisons = ["v1.0.0...\(commit)": "behind"]

        let result = try await tracker(transport).poll(unbound: unbound(), now: now)

        XCTAssertEqual(transport.compared, ["v1.0.0...\(commit)"])
        XCTAssertEqual(result.bindings, [pullRequest: "v1.0.0"])
    }

    /// `release-compare-not-repeated-across-polls`. Without durable negatives, an unbound
    /// merge re-tests every candidate on every poll — 10 stranded merges against 25 tags is
    /// 250 requests a minute, forever.
    func testANegativeIsNeverRetestedOnALaterPoll() async throws {
        let tags = (1...5).map { index in
            TagPage.Tag.lightweight("v1.0.\(index)", commit: "c\(index)", date: ReleaseTrackerTests.day(5))
        }

        var state = LocalState(unboundMerges: unbound())

        let first = ReleaseStubTransport()
        first.tagPages = [.json(TagPage.json(tags: tags))]
        let firstResult = try await tracker(first).poll(unbound: state.unboundMerges, now: now)
        state.apply(firstResult)

        XCTAssertEqual(first.compared.count, 5)
        XCTAssertTrue(firstResult.bindings.isEmpty)
        XCTAssertEqual(state.unboundMerges[pullRequest]?.comparedTags.count, 5)

        // The next poll, same tags: nothing left to ask.
        let second = ReleaseStubTransport()
        second.tagPages = [.json(TagPage.json(tags: tags))]
        let secondResult = try await tracker(second).poll(unbound: state.unboundMerges, now: now)
        state.apply(secondResult)

        XCTAssertEqual(second.compared, [], "a negative must be as durable as a positive")
        XCTAssertEqual(secondResult.comparisonsMade, 0)

        // A genuinely new tag is the only thing that costs a request.
        let third = ReleaseStubTransport()
        third.tagPages = [
            .json(TagPage.json(tags: tags + [
                TagPage.Tag.lightweight("v1.1.0", commit: "new", date: ReleaseTrackerTests.day(8))
            ]))
        ]
        third.comparisons = ["v1.1.0...\(commit)": "behind"]
        let thirdResult = try await tracker(third).poll(unbound: state.unboundMerges, now: now)
        state.apply(thirdResult)

        XCTAssertEqual(third.compared, ["v1.1.0...\(commit)"])
        XCTAssertEqual(state.releaseBindings[pullRequest], "v1.1.0")
        XCTAssertNil(state.unboundMerges[pullRequest], "binding retires the unbound record")
    }

    /// The hard per-poll cap. What is already done is kept — the negatives are returned —
    /// so the deferred work resumes rather than restarting.
    func testTheComparisonBudgetDefersTheRestOfTheWork() async throws {
        let tags = (1...10).map { index in
            TagPage.Tag.lightweight(
                "v1.0.\(index)",
                commit: "c\(index)",
                date: ReleaseTrackerTests.day(5)
            )
        }
        let transport = ReleaseStubTransport()
        transport.tagPages = [.json(TagPage.json(tags: tags))]

        let result = try await tracker(transport, comparisonBudget: 3)
            .poll(unbound: unbound(), now: now)

        XCTAssertEqual(transport.compared.count, 3)
        XCTAssertEqual(result.comparisonsMade, 3)
        XCTAssertEqual(result.comparisons[pullRequest]?.count, 3)
        XCTAssertEqual(
            result.warnings,
            [.comparisonBudgetExhausted(spent: 3, limit: 3)]
        )
    }

    /// Below 10% of the REST allowance the budget drops to zero for the rest of the poll.
    /// Backing off on the measured remaining count, before exhaustion, is what stops the app
    /// being hard-blocked mid-poll and showing a disconnected icon for the rest of the hour.
    func testTheRESTFloorStopsFurtherComparisons() async throws {
        let tags = (1...5).map { index in
            TagPage.Tag.lightweight("v1.0.\(index)", commit: "c\(index)", date: ReleaseTrackerTests.day(5))
        }
        let transport = ReleaseStubTransport()
        transport.tagPages = [.json(TagPage.json(tags: tags))]
        transport.comparisonHeaders = [
            "x-ratelimit-limit": "5000",
            "x-ratelimit-remaining": "400",
            "x-ratelimit-reset": "1800000000"
        ]

        let result = try await tracker(transport).poll(unbound: unbound(), now: now)

        XCTAssertEqual(transport.compared.count, 1, "the first answer already reported the floor")
        // The one answer it did get is still banked, so the deferred work resumes rather
        // than restarting.
        XCTAssertEqual(result.comparisons[pullRequest], ["v1.0.1"])
        XCTAssertEqual(
            result.warnings,
            [
                .rateLimitFloorReached(
                    remaining: 400,
                    limit: 5_000,
                    resetAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            ]
        )
    }

    /// A 404 — a tag deleted between the ref query and the comparison — is one repository's
    /// problem and not a negative. Recording it as one would suppress the comparison that
    /// binds the pull request if the tag comes back.
    func testAFailedComparisonIsAWarningAndNotADurableNegative() async throws {
        let transport = ReleaseStubTransport()
        transport.tagPages = [
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("v1.0.0", commit: "c1", date: ReleaseTrackerTests.day(5))
            ]))
        ]
        transport.comparisonFailures = [
            "v1.0.0...\(commit)": .json(#"{"message":"Not Found"}"#, status: 404)
        ]

        let result = try await tracker(transport).poll(unbound: unbound(), now: now)

        XCTAssertTrue(result.bindings.isEmpty)
        XCTAssertNil(result.comparisons[pullRequest])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(
            result.warnings.first?.description.contains("could not check acme/billing's releases"),
            true
        )
    }

    /// An expired token is not one repository's problem. It ends the poll, so the panel
    /// raises the reconnect banner rather than reporting a release failure per repository.
    func testAnExpiredTokenEndsThePoll() async throws {
        let transport = ReleaseStubTransport()
        transport.tagPages = [.json(#"{"message":"Bad credentials"}"#, status: 401)]

        do {
            _ = try await tracker(transport).poll(unbound: unbound(), now: now)
            XCTFail("expected the poll to fail")
        } catch {
            XCTAssertEqual((error as? GitHubError)?.isAuthenticationFailure, true)
        }
    }

    /// One repository being unreachable must not stop another's merges from binding.
    func testOneUnreachableRepositoryDoesNotStopTheOthers() async throws {
        let other = PRID(repo: "acme/web", number: 77)
        let transport = ReleaseStubTransport()
        // Repositories are visited in sorted order: acme/billing, then acme/web.
        transport.tagPages = [
            .json(#"{"message":"Not Found"}"#, status: 404),
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("v2.0.0", commit: "c9", date: ReleaseTrackerTests.day(6))
            ]))
        ]
        transport.comparisons = ["v2.0.0...webcommit": "behind"]

        var merges = unbound()
        merges[other] = UnboundMerge(mergeCommit: "webcommit", mergedAt: mergedAt)

        let result = try await tracker(transport).poll(unbound: merges, now: now)

        XCTAssertEqual(result.bindings, [other: "v2.0.0"])
        XCTAssertEqual(result.warnings.count, 1)
    }

    /// Each repository is read with its own pattern; anything unlisted takes `v*`.
    func testEachRepositoryUsesItsOwnPattern() async throws {
        let other = PRID(repo: "acme/web", number: 77)
        let transport = ReleaseStubTransport()
        transport.tagPages = [
            .json(TagPage.json(tags: [])),
            .json(TagPage.json(tags: []))
        ]

        var merges = unbound()
        merges[other] = UnboundMerge(mergeCommit: "webcommit", mergedAt: mergedAt)

        _ = try await tracker(transport, patterns: TagPatterns(["acme/billing": "release-*"]))
            .poll(unbound: merges, now: now)

        let first = try XCTUnwrap(variables(of: transport.tagQueries[0]))
        let second = try XCTUnwrap(variables(of: transport.tagQueries[1]))
        XCTAssertEqual(first["name"] as? String, "billing")
        XCTAssertEqual(first["prefilter"] as? String, "release-")
        XCTAssertEqual(second["name"] as? String, "web")
        XCTAssertEqual(second["prefilter"] as? String, "v")
    }

    /// A repeated pair costs a 304 rather than a request, and an unchanged answer can only
    /// be a repeat of a negative — a positive would have bound the pull request and stopped
    /// the pair ever being compared again.
    func testAnUnchangedComparisonIsRecordedAsANegative() async throws {
        let etags = InMemoryETagStore()
        etags.setETag(
            "W/\"cached\"",
            for: "https://api.github.test/repos/acme/billing/compare/v1.0.0...\(commit)"
        )
        let transport = ReleaseStubTransport()
        transport.tagPages = [
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("v1.0.0", commit: "c1", date: ReleaseTrackerTests.day(5))
            ]))
        ]
        transport.comparisonFailures = ["v1.0.0...\(commit)": HTTPResponse(status: 304)]

        let result = try await tracker(transport, etags: etags).poll(unbound: unbound(), now: now)

        XCTAssertEqual(transport.comparisonRequests.first?.header("If-None-Match"), "W/\"cached\"")
        XCTAssertTrue(result.bindings.isEmpty)
        XCTAssertEqual(result.comparisons[pullRequest], ["v1.0.0"])
    }

    /// A repository answering with errors is left for the next poll whole. Its merges share
    /// the candidate list that just failed, so trying the next one only spends more budget
    /// on the same failure.
    func testAComparisonFailureStopsThatRepositoryForThePoll() async throws {
        let second = PRID(repo: repository, number: 4013)
        let transport = ReleaseStubTransport()
        transport.tagPages = [
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("v1.0.0", commit: "c1", date: ReleaseTrackerTests.day(5))
            ]))
        ]
        transport.comparisonFailures = [
            "v1.0.0...\(commit)": .json(#"{"message":"Not Found"}"#, status: 404)
        ]

        var merges = unbound()
        // Merged a minute later, so the failing one is reached first — merges are taken
        // oldest first.
        merges[second] = UnboundMerge(mergeCommit: "another", mergedAt: mergedAt.addingTimeInterval(60))

        let result = try await tracker(transport).poll(unbound: merges, now: now)

        XCTAssertEqual(transport.compared, ["v1.0.0...\(commit)"])
        XCTAssertEqual(result.comparisonsMade, 1)
        XCTAssertTrue(result.comparisons.isEmpty, "a failure is not a durable negative")
    }

    /// M6's headline behaviour, end to end: a merge from six weeks ago, a tag cut today,
    /// and the row moves to Done as shipped. The merge only survives that long because the
    /// unbound record does — which is why the store belongs to this milestone.
    func testAMergeFromSixWeeksAgoStillShipsWhenTheTagFinallyAppears() async throws {
        let mergedLongAgo = ISO8601DateFormatter().date(from: "2025-11-28T09:00:00Z")!
        let pullRequest = PullRequest(
            repo: repository,
            number: 4012,
            title: "Invoice renderer",
            headRef: "avery/invoice",
            baseRef: "main",
            state: .merged,
            mergeCommit: commit,
            updatedAt: mergedLongAgo,
            mergedAt: mergedLongAgo
        )

        var state = LocalState.empty
        state.recordMerges(from: [pullRequest])
        XCTAssertEqual(state.oldestUnboundMergeAt, mergedLongAgo, "the merged query's lower bound")

        let transport = ReleaseStubTransport()
        transport.tagPages = [
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("v3.0.0", commit: "head", date: ReleaseTrackerTests.day(9))
            ]))
        ]
        transport.comparisons = ["v3.0.0...\(commit)": "behind"]

        state.apply(try await tracker(transport).poll(unbound: state.unboundMerges, now: now))

        let panel = Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "avery", pullRequests: [pullRequest]),
            local: state,
            now: now
        )
        let row = try XCTUnwrap(panel.sections.first { $0.kind == .done }?.rows.first)
        XCTAssertEqual(row.status, .shipped(tag: "v3.0.0"))
        XCTAssertEqual(row.releaseStage, .released(tag: "v3.0.0"))
    }

    func testNothingWaitingMeansNoRequests() async throws {
        let transport = ReleaseStubTransport()
        let result = try await tracker(transport).poll(unbound: [:], now: now)

        XCTAssertEqual(result, .empty)
        XCTAssertTrue(transport.tagQueries.isEmpty)
        XCTAssertTrue(transport.compared.isEmpty)
    }

    private func variables(of request: HTTPRequest) -> [String: Any]? {
        guard let body = request.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return object["variables"] as? [String: Any]
    }
}
