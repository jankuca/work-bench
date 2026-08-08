import Foundation
import NetKit
import PRStackCore
import XCTest
@testable import LinearKit

final class LinearResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_000_000)

    private func pullRequest(
        number: Int = 4012,
        title: String = "Untitled",
        body: String? = nil,
        headRef: String = "jk/work"
    ) -> PullRequest {
        PullRequest(
            repo: "acme/billing",
            number: number,
            title: title,
            body: body,
            headRef: headRef,
            baseRef: "main",
            authorLogin: "jankuca",
            updatedAt: now.addingTimeInterval(-3_600)
        )
    }

    private func resolver(
        _ transport: StubTransport,
        cache: LinearProjectCache = .empty
    ) -> (LinearResolver, InMemoryLinearProjectCacheStore) {
        let store = InMemoryLinearProjectCacheStore(cache)
        let resolver = LinearResolver(
            client: LinearClient(transport: transport, tokenProvider: StaticTokenProvider("lin_api_test")),
            store: store
        )
        return (resolver, store)
    }

    private func issue(_ identifier: String, project: (id: String, name: String)?) -> IssueRef {
        IssueRef(
            identifier: identifier,
            projectID: project?.id,
            projectName: project?.name
        )
    }

    /// The section a resolved pull request lands in once derivation has run over it.
    ///
    /// Looked up by row rather than by position, because section order is by most recent
    /// activity and these fixtures deliberately share a timestamp — the assertion is about
    /// *which* project a row is filed under, not where that project sorts.
    private func section(of pullRequest: PullRequest, in model: PanelModel) -> PanelSection.Kind? {
        model.sections.first { section in
            section.rows.contains { $0.id == pullRequest.id }
        }?.kind
    }

    private func derive(_ pullRequests: [PullRequest]) -> PanelModel {
        Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "jankuca", pullRequests: pullRequests),
            local: .empty,
            now: now
        )
    }

    private func cache(_ pairs: [(String, IssueRef?)], age: TimeInterval = 0) -> LinearProjectCache {
        var cache = LinearProjectCache.empty
        for (identifier, reference) in pairs {
            if let reference {
                cache.record(reference, for: identifier, at: now.addingTimeInterval(-age))
            } else {
                cache.recordUnknown(identifier, at: now.addingTimeInterval(-age))
            }
        }
        return cache
    }

    // MARK: - Order

    /// `linear-resolve-order-cache-vs-fresh` (IMPLEMENTATION_PLAN §2).
    ///
    /// A pull request linking `BIL-312` and `SRC-97` must yield them in *that* order on the
    /// poll where both are cached and on the poll where one is freshly fetched. Building
    /// the row's list by appending cache hits and then response fields would flip them, and
    /// the row would migrate from Billing to Source with nothing having changed.
    func testIssueOrderComesFromThePullRequestNotFromWhatWasCached() async throws {
        let subject = pullRequest(title: "Fixes BIL-312 and SRC-97")
        let billing = issue("BIL-312", project: ("proj-billing", "Billing"))
        let source = issue("SRC-97", project: ("proj-source", "Source"))

        // Poll A: both cached. No request at all.
        let quiet = StubTransport(responses: [])
        let (cachedResolver, _) = self.resolver(quiet, cache: cache([("BIL-312", billing), ("SRC-97", source)]))
        let fromCache = await cachedResolver.resolve(pullRequests: [subject], now: now)
        XCTAssertEqual(quiet.requestCount, 0)

        // Poll B: the *second* identifier is cached and the first is fetched, which is the
        // arrangement that flips the order when the list is rebuilt from arrival order.
        let live = StubTransport(responses: [
            .json(
                """
                {"data": {"a0": {"identifier": "BIL-312",
                                 "project": {"id": "proj-billing", "name": "Billing"}}}}
                """
            )
        ])
        let (freshResolver, _) = self.resolver(live, cache: cache([("SRC-97", source)]))
        let fromMixed = await freshResolver.resolve(pullRequests: [subject], now: now)
        XCTAssertEqual(try live.requestedIdentifiers(0), ["BIL-312"], "only the uncached one is fetched")

        XCTAssertEqual(fromCache.pullRequests[0].linearIssues.map(\.identifier), ["BIL-312", "SRC-97"])
        XCTAssertEqual(fromMixed.pullRequests[0].linearIssues.map(\.identifier), ["BIL-312", "SRC-97"])
        XCTAssertEqual(fromMixed.pullRequests[0].primaryIssue?.identifier, "BIL-312")

        // The consequence, at the level the user sees it: the row is under Billing on both
        // polls. A list rebuilt from arrival order would put it under Source on one of
        // them, and the row would appear to migrate with nothing having changed.
        let billingSection = PanelSection.Kind.project(id: "proj-billing", name: "Billing")
        XCTAssertEqual(
            section(of: fromCache.pullRequests[0], in: derive(fromCache.pullRequests)),
            billingSection
        )
        XCTAssertEqual(
            section(of: fromMixed.pullRequests[0], in: derive(fromMixed.pullRequests)),
            billingSection
        )
    }

    /// `linear-cross-team-number-collision` (IMPLEMENTATION_PLAN §2), at panel level.
    ///
    /// `LinearClientTests` pins the query shape — that the unsafe `issues(filter:)`
    /// cross-product form never appears. This pins what that shape is *for*: two pull
    /// requests naming `BIL-312` and `SRC-97` file under Billing and Source respectively,
    /// and never under the `BIL-97` / `SRC-312` the cross-product would also have matched.
    func testTwoTeamsWithCollidingNumbersFileUnderTheirOwnProjects() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": {
                  "a0": {"identifier": "BIL-312", "project": {"id": "proj-billing", "name": "Billing"}},
                  "a1": {"identifier": "SRC-97", "project": {"id": "proj-source", "name": "Source"}}
                }}
                """
            )
        ])
        let (resolver, _) = self.resolver(transport)

        let resolution = await resolver.resolve(
            pullRequests: [
                pullRequest(number: 4012, headRef: "jk/bil-312"),
                pullRequest(number: 4013, headRef: "jk/src-97")
            ],
            now: now
        )

        XCTAssertEqual(try transport.requestedIdentifiers(0), ["BIL-312", "SRC-97"])

        let model = derive(resolution.pullRequests)
        XCTAssertEqual(
            section(of: resolution.pullRequests[0], in: model),
            PanelSection.Kind.project(id: "proj-billing", name: "Billing")
        )
        XCTAssertEqual(
            section(of: resolution.pullRequests[1], in: model),
            PanelSection.Kind.project(id: "proj-source", name: "Source")
        )
        XCTAssertEqual(model.sections.count, 2, "two projects, and no third from a phantom pairing")
    }

    /// One request per identifier, not per pull request: a ticket referenced by two pull
    /// requests is fetched once.
    func testAnIdentifierSharedByTwoPullRequestsIsFetchedOnce() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": {"a0": {"identifier": "BIL-312",
                                 "project": {"id": "proj-billing", "name": "Billing"}}}}
                """
            )
        ])
        let (resolver, _) = self.resolver(transport)
        let resolution = await resolver.resolve(
            pullRequests: [
                pullRequest(number: 4012, headRef: "jk/bil-312-a"),
                pullRequest(number: 4013, headRef: "jk/bil-312-b")
            ],
            now: now
        )

        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(try transport.requestedIdentifiers(0), ["BIL-312"])
        XCTAssertEqual(resolution.pullRequests.map { $0.primaryIssue?.projectName }, ["Billing", "Billing"])
    }

    // MARK: - Outage

    /// M5's third done-criterion: **a Linear outage keeps cached headings and marks the
    /// source stale.** Nothing reshuffles, nothing empties, and nothing is written — a
    /// failed poll has learned nothing, and recording that would be recording a guess.
    func testAnOutageKeepsCachedHeadingsAndMarksTheSourceStale() async throws {
        struct Offline: Error {}
        let transport = StubTransport([.fail(Offline())])
        let cached = cache(
            [("BIL-312", issue("BIL-312", project: ("proj-billing", "Billing")))],
            // Old enough to be re-asked, which is what sends the request that fails.
            age: LinearProjectCache.refreshInterval + 60
        )
        let (resolver, store) = self.resolver(transport, cache: cached)

        let resolution = await resolver.resolve(
            pullRequests: [pullRequest(title: "Fixes BIL-312 and SRC-97")],
            now: now
        )

        XCTAssertEqual(resolution.pullRequests[0].linearIssues.map(\.identifier), ["BIL-312"])
        XCTAssertEqual(resolution.pullRequests[0].primaryIssue?.projectName, "Billing")
        let health = try XCTUnwrap(resolution.health)
        guard case .unreachable = health else {
            return XCTFail("expected the source to be marked stale, got \(health)")
        }
        XCTAssertEqual(store.load().entries.count, 1, "a failed poll writes nothing")
    }

    /// An entry past its refresh interval is still an answer. The interval decides what
    /// gets re-asked, never what gets used — otherwise an outage would empty the panel's
    /// project sections a day after it started.
    func testStaleCacheEntriesAreStillUsedForHeadings() async throws {
        struct Offline: Error {}
        let transport = StubTransport([.fail(Offline())])
        let cached = cache(
            [("BIL-312", issue("BIL-312", project: ("proj-billing", "Billing")))],
            age: LinearProjectCache.refreshInterval * 30
        )
        let (resolver, _) = self.resolver(transport, cache: cached)

        let resolution = await resolver.resolve(pullRequests: [pullRequest(headRef: "jk/bil-312")], now: now)
        XCTAssertEqual(resolution.pullRequests[0].primaryIssue?.projectID, "proj-billing")
    }

    func testAnExpiredKeyMarksLinearDisconnectedAndNothingElse() async throws {
        let transport = StubTransport(responses: [
            .json(#"{"message": "Authentication required"}"#, status: 401)
        ])
        let (resolver, _) = self.resolver(transport)
        let resolution = await resolver.resolve(pullRequests: [pullRequest(headRef: "jk/bil-312")], now: now)

        XCTAssertEqual(resolution.health?.needsReconnect, true)
        XCTAssertTrue(resolution.pullRequests[0].linearIssues.isEmpty)
    }

    /// The panel closing mid-poll is not an outage. `nil` health means "keep what you had",
    /// so the footer does not sprout a stale marker in response to the user's own click.
    func testCancellationLeavesHealthUnchanged() async throws {
        let transport = StubTransport([.fail(CancellationError())])
        let (resolver, _) = self.resolver(transport)
        let resolution = await resolver.resolve(pullRequests: [pullRequest(headRef: "jk/bil-312")], now: now)
        XCTAssertNil(resolution.health)
    }

    // MARK: - Not configured

    /// Linear is optional; GitHub is not. With no key the panel groups everything under
    /// `Other` and nothing is stale, because nothing was ever connected.
    func testNoClientAttachesNothingAndReportsUnconfigured() async {
        let resolver = LinearResolver(client: nil)
        let resolution = await resolver.resolve(
            pullRequests: [pullRequest(title: "Fixes BIL-312")],
            now: now
        )
        XCTAssertTrue(resolution.pullRequests[0].linearIssues.isEmpty)
        XCTAssertEqual(resolution.health, SourceHealth.unconfigured)
    }

    // MARK: - Caching

    /// Negative answers are cached, and that is what keeps the scanner's false positives
    /// free. Without it, `UTF-8` in a title is re-queried on every poll forever.
    func testUnknownIdentifiersAreCachedAndNotReQueried() async throws {
        let first = StubTransport(responses: [
            .json(
                """
                {"data": {"a0": {"identifier": "BIL-312",
                                 "project": {"id": "proj-billing", "name": "Billing"}},
                          "a1": null}}
                """
            )
        ])
        let store = InMemoryLinearProjectCacheStore()
        let subject = pullRequest(title: "Fix UTF-8 handling", headRef: "jk/bil-312")

        let firstResolver = LinearResolver(
            client: LinearClient(transport: first, tokenProvider: StaticTokenProvider("lin_api_test")),
            store: store
        )
        _ = await firstResolver.resolve(pullRequests: [subject], now: now)
        XCTAssertEqual(first.requestCount, 1)
        XCTAssertEqual(try first.requestedIdentifiers(0), ["BIL-312", "UTF-8"])

        // Second poll, one minute later, same store: nothing left to ask.
        let second = StubTransport(responses: [])
        let secondResolver = LinearResolver(
            client: LinearClient(transport: second, tokenProvider: StaticTokenProvider("lin_api_test")),
            store: store
        )
        let resolution = await secondResolver.resolve(
            pullRequests: [subject],
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(second.requestCount, 0)
        XCTAssertEqual(resolution.cacheHits, 2)
        XCTAssertEqual(resolution.pullRequests[0].linearIssues.map(\.identifier), ["BIL-312"])
        XCTAssertNil(resolution.health, "a poll that sent no request verified no connection")
    }

    /// The same rule for a snapshot with no identifiers at all: no request, so nothing was
    /// learned, so the caller keeps the health it had.
    ///
    /// Reporting `.connected` here is the bug this pins. A quiet poll would clear a
    /// standing outage — the footer would go quiet while Linear was still down — and the
    /// *next* real loss would emit no `connectionLost`, because the previous status had
    /// already been reset to healthy.
    func testAPollWithNothingToResolveLeavesHealthUnchanged() async throws {
        let transport = StubTransport(responses: [])
        let (resolver, _) = self.resolver(transport)

        let resolution = await resolver.resolve(
            pullRequests: [pullRequest(title: "No ticket here", headRef: "jk/tidy")],
            now: now
        )

        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertNil(resolution.health)
        XCTAssertTrue(resolution.pullRequests[0].linearIssues.isEmpty)
    }

    /// The cache is pruned to what the current scan references, so it cannot grow across
    /// the life of the app — a retitled pull request leaves dead identifiers behind, and
    /// negatives like `UTF-8` accumulate from every pull request that ever mentioned one.
    func testASuccessfulPollPrunesIdentifiersNothingReferencesAnyMore() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": {"a0": {"identifier": "BIL-312",
                                 "project": {"id": "proj-billing", "name": "Billing"}}}}
                """
            )
        ])
        let stale = cache([
            ("OLD-1", issue("OLD-1", project: ("proj-old", "Old"))),
            ("UTF-8", nil)
        ], age: LinearProjectCache.refreshInterval * 10)
        let (resolver, store) = self.resolver(transport, cache: stale)

        _ = await resolver.resolve(pullRequests: [pullRequest(headRef: "jk/bil-312")], now: now)

        XCTAssertEqual(Set(store.load().entries.keys), ["BIL-312"])
    }

    /// The other half of that rule, and the reason the prune sits *after* the failure
    /// return: a poll that failed learned nothing, so it must not drop the entries the
    /// fallback headings come from.
    ///
    /// The outage test above cannot show this on its own — its cache holds one entry and
    /// that entry is also the one the scan references, so "wrote nothing" and "pruned to
    /// exactly what was referenced" are indistinguishable there. The dead identifier is
    /// what separates them.
    func testAFailedPollPrunesNothing() async throws {
        struct Offline: Error {}
        let transport = StubTransport([.fail(Offline())])
        let cached = cache([
            ("BIL-312", issue("BIL-312", project: ("proj-billing", "Billing"))),
            ("OLD-1", issue("OLD-1", project: ("proj-old", "Old")))
        ], age: LinearProjectCache.refreshInterval + 60)
        let (resolver, store) = self.resolver(transport, cache: cached)

        _ = await resolver.resolve(pullRequests: [pullRequest(headRef: "jk/bil-312")], now: now)

        XCTAssertEqual(Set(store.load().entries.keys), ["BIL-312", "OLD-1"])
    }

    func testEntriesAreReAskedOnceADay() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": {"a0": {"identifier": "BIL-312",
                                 "project": {"id": "proj-platform", "name": "Platform"}}}}
                """
            )
        ])
        let cached = cache(
            [("BIL-312", issue("BIL-312", project: ("proj-billing", "Billing")))],
            age: LinearProjectCache.refreshInterval + 1
        )
        let (resolver, store) = self.resolver(transport, cache: cached)

        let resolution = await resolver.resolve(pullRequests: [pullRequest(headRef: "jk/bil-312")], now: now)

        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(resolution.pullRequests[0].primaryIssue?.projectName, "Platform")
        XCTAssertEqual(store.load().issue(for: "BIL-312")?.projectName, "Platform")
    }

    // MARK: - Through to the panel

    /// End to end, because this is what M5 is judged on: real project headings, a `+N` on a
    /// multi-ticket pull request, and the row under its **primary** project rather than
    /// under both.
    func testResolvedPullRequestsGroupUnderTheirPrimaryProject() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": {
                  "a0": {"identifier": "BIL-320", "project": {"id": "proj-billing", "name": "Billing"}},
                  "a1": {"identifier": "PAY-90", "project": {"id": "proj-payments", "name": "Payments"}}
                }}
                """
            )
        ])
        let (resolver, _) = self.resolver(transport)

        let resolution = await resolver.resolve(
            pullRequests: [
                pullRequest(
                    number: 1200,
                    title: "Closes BIL-320, also touches PAY-90",
                    headRef: "jk/bil-320"
                )
            ],
            now: now
        )

        let model = Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "jankuca", pullRequests: resolution.pullRequests),
            local: .empty,
            now: now
        )

        XCTAssertEqual(model.sections.map(\.kind), [.project(id: "proj-billing", name: "Billing")])
        let row = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(row.primaryIssue?.identifier, "BIL-320")
        XCTAssertEqual(row.additionalIssueCount, 1, "the meta line reads BIL-320 +1")
    }

    /// A pull request whose only reference is in its body still lands in a project.
    /// `pr-body-only-identifier` (IMPLEMENTATION_PLAN §6) — the failure it guards is a body
    /// dropped between the DTO and the scan, which files the row under `Other` silently.
    func testABodyOnlyIdentifierStillGroupsTheRow() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": {"a0": {"identifier": "BIL-312",
                                 "project": {"id": "proj-billing", "name": "Billing"}}}}
                """
            )
        ])
        let (resolver, _) = self.resolver(transport)

        let resolution = await resolver.resolve(
            pullRequests: [
                pullRequest(
                    title: "Tidy the ledger export",
                    body: "Closes: https://linear.app/acme/issue/BIL-312/add-tax-rows",
                    headRef: "jk/tidy-ledger-export"
                )
            ],
            now: now
        )

        let model = Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "jankuca", pullRequests: resolution.pullRequests),
            local: .empty,
            now: now
        )
        XCTAssertEqual(model.sections.map(\.kind), [.project(id: "proj-billing", name: "Billing")])
    }

    /// Identifiers with nothing behind them are dropped rather than rendered. A meta line
    /// reading `UTF-8` would be worse than one reading nothing at all.
    func testUnknownIdentifiersNeverReachTheMetaLine() async throws {
        let transport = StubTransport(responses: [.json(#"{"data": {"a0": null}}"#)])
        let (resolver, _) = self.resolver(transport)

        let resolution = await resolver.resolve(
            pullRequests: [pullRequest(title: "Fix UTF-8 handling", headRef: "jk/tidy")],
            now: now
        )

        XCTAssertTrue(resolution.pullRequests[0].linearIssues.isEmpty)
        let model = Derivation.derive(
            snapshot: RawSnapshot(viewerLogin: "jankuca", pullRequests: resolution.pullRequests),
            local: .empty,
            now: now
        )
        XCTAssertEqual(model.sections.map(\.kind), [.other])
    }
}
