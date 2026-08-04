import Foundation
import PRStackCore
import XCTest
@testable import GitHubKit

final class PullRequestMapperTests: XCTestCase {
    private struct Envelope: Decodable {
        var data: SearchPayload
    }

    private func nodes() throws -> [PullRequestNodeDTO] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: try Fixtures.data("search-page-full.json"))
        return (envelope.data.search.nodes ?? []).compactMap { $0 }
    }

    private func mapped() throws -> [PullRequest] {
        try nodes().compactMap { node -> PullRequest? in
            if case .mapped(let pullRequest) = PullRequestMapper.map(node) { return pullRequest }
            return nil
        }
    }

    private func skipReasons() throws -> [String] {
        try nodes().compactMap { node -> String? in
            if case .skipped(let reason) = PullRequestMapper.map(node) { return reason }
            return nil
        }
    }

    // MARK: - Whole nodes

    func testMapsAnOpenPullRequestCompletely() throws {
        let pullRequest = try XCTUnwrap(mapped().first { $0.number == 4012 })

        XCTAssertEqual(pullRequest.repo, "acme/billing")
        XCTAssertEqual(pullRequest.id.rawValue, "acme/billing#4012")
        XCTAssertEqual(pullRequest.title, "Split invoice totals out of the ledger writer")
        XCTAssertEqual(pullRequest.url, URL(string: "https://github.com/acme/billing/pull/4012"))
        XCTAssertEqual(pullRequest.headRef, "avery/bil-312-invoice-totals")
        XCTAssertEqual(pullRequest.baseRef, "avery/bil-311-ledger-writer")
        XCTAssertEqual(pullRequest.authorLogin, "avery")
        XCTAssertEqual(pullRequest.state, .open)
        XCTAssertEqual(pullRequest.reviewDecision, .changesRequested)
        XCTAssertEqual(pullRequest.mergeable, .mergeable)
        XCTAssertNil(pullRequest.mergeCommit)
        XCTAssertNil(pullRequest.mergedAt)
        XCTAssertEqual(pullRequest.commentCount, 7)
        XCTAssertEqual(
            pullRequest.lastCommentAt,
            ISO8601DateFormatter().date(from: "2026-01-09T16:35:00Z")
        )
        // Linear resolution is M5's job; the mapper carries the fields it will scan.
        XCTAssertTrue(pullRequest.linearIssues.isEmpty)
    }

    /// The body is nullable on the wire and is the third source in the Linear identifier
    /// scan, so dropping it would silently file body-only references under `Other`.
    func testBodyIsCarriedThroughIncludingItsAbsence() throws {
        let all = try mapped()
        let withBody = try XCTUnwrap(all.first { $0.number == 4012 })
        XCTAssertEqual(
            withBody.body,
            "Closes BIL-312.\n\nAlso touches https://linear.app/acme/issue/BIL-313/rounding"
        )
        XCTAssertNil(try XCTUnwrap(all.first { $0.number == 4011 }).body)
    }

    /// GitHub reports a merged pull request as MERGED, never CLOSED, and the whole row
    /// status precedence depends on that.
    func testMergedPullRequestKeepsItsMergeCommitAndTime() throws {
        let pullRequest = try XCTUnwrap(try mapped().first { $0.number == 4011 })
        XCTAssertEqual(pullRequest.state, .merged)
        XCTAssertEqual(pullRequest.mergeCommit, "9f1c2ab7d4e5f60718293a4b5c6d7e8f90a1b2c3")
        XCTAssertEqual(
            pullRequest.mergedAt,
            ISO8601DateFormatter().date(from: "2026-01-09T09:58:00Z")
        )
        XCTAssertEqual(pullRequest.checks, .passing)
    }

    // MARK: - Nodes that cannot become pull requests

    /// `search(type: ISSUE)` returns a union, so a page routinely carries nodes that are
    /// not pull requests at all. A strict DTO would throw and lose the whole page.
    func testNonPullRequestNodesAreSkippedWithoutLosingThePage() throws {
        XCTAssertEqual(try mapped().count, 2)
        let reasons = try skipReasons()
        XCTAssertEqual(reasons.count, 2)
        XCTAssertTrue(reasons.contains { $0.contains("Issue") })
        XCTAssertTrue(reasons.contains { $0.contains("no repository name") })
    }

    func testUnusableIdentityIsSkippedRatherThanBuiltIntoAPRID() {
        let node = PullRequestNodeDTO(
            typeName: "PullRequest",
            number: 4012,
            updatedAt: Date(timeIntervalSince1970: 0),
            repository: RepositoryDTO(nameWithOwner: "acme")
        )
        guard case .skipped(let reason) = PullRequestMapper.map(node) else {
            return XCTFail("expected a repository without an owner to be skipped")
        }
        XCTAssertTrue(reason.contains("not a usable pull request id"))
    }

    // MARK: - Enumerations

    func testStateMappingTreatsAnythingUnknownAsOpen() {
        XCTAssertEqual(PullRequestMapper.state("OPEN"), .open)
        XCTAssertEqual(PullRequestMapper.state("MERGED"), .merged)
        XCTAssertEqual(PullRequestMapper.state("CLOSED"), .closed)
        XCTAssertEqual(PullRequestMapper.state(nil), .open)
    }

    func testMergeableAndReviewDecisionMapping() {
        XCTAssertEqual(PullRequestMapper.mergeable("CONFLICTING"), .conflicting)
        XCTAssertEqual(PullRequestMapper.mergeable("MERGEABLE"), .mergeable)
        XCTAssertEqual(PullRequestMapper.mergeable(nil), .unknown)
        XCTAssertEqual(PullRequestMapper.reviewDecision("CHANGES_REQUESTED"), .changesRequested)
        XCTAssertEqual(PullRequestMapper.reviewDecision("REVIEW_REQUIRED"), .reviewRequired)
        XCTAssertNil(PullRequestMapper.reviewDecision(nil))
    }

    // MARK: - Checks

    func testFailingRollupCountsOnlyTheFailingContexts() throws {
        let pullRequest = try XCTUnwrap(try mapped().first { $0.number == 4012 })
        // One SUCCESS, one FAILURE, one TIMED_OUT, one passing legacy StatusContext.
        XCTAssertEqual(pullRequest.checks, .failing(2))
    }

    /// `contexts` is capped at 20, so a rollup can report failure while the page shows
    /// none. Reporting zero failures on a failing rollup would contradict the row's own
    /// status.
    func testFailingRollupWithNoVisibleContextsStillReportsOne() {
        let rollup = PullRequestMapper.checks(
            from: CommitConnectionDTO(nodes: [
                CommitWrapperDTO(
                    commit: CommitDTO(
                        statusCheckRollup: StatusCheckRollupDTO(
                            state: "FAILURE",
                            contexts: CheckContextConnectionDTO(totalCount: 25, nodes: [])
                        )
                    )
                )
            ])
        )
        XCTAssertEqual(rollup, .failing(1))
    }

    func testRollupStates() {
        func rollup(_ state: String?) -> CheckRollup {
            PullRequestMapper.checks(
                from: CommitConnectionDTO(nodes: [
                    CommitWrapperDTO(
                        commit: CommitDTO(
                            statusCheckRollup: state.map {
                                StatusCheckRollupDTO(state: $0, contexts: nil)
                            }
                        )
                    )
                ])
            )
        }
        XCTAssertEqual(rollup("SUCCESS"), .passing)
        XCTAssertEqual(rollup("PENDING"), .running)
        XCTAssertEqual(rollup("EXPECTED"), .running)
        XCTAssertEqual(rollup("ERROR"), .failing(1))
        // No rollup at all is not the same as a rollup with nothing in it.
        XCTAssertEqual(rollup(nil), .noChecks)
        XCTAssertEqual(PullRequestMapper.checks(from: nil), .noChecks)
    }

    // MARK: - Reviewers

    /// A reviewer who approves and then leaves a remark is still an approver. Taking the
    /// last node would quietly turn their green ring grey.
    func testCommentDoesNotOverwriteAStandingApproval() throws {
        let pullRequest = try XCTUnwrap(try mapped().first { $0.number == 4012 })
        XCTAssertEqual(pullRequest.reviews.map(\.login), ["rowan", "kai"])
        XCTAssertEqual(pullRequest.reviews.map(\.state), [.approved, .changesRequested])
        XCTAssertEqual(
            pullRequest.reviews.first?.avatarURL,
            URL(string: "https://avatars.example/rowan")
        )
    }

    /// A pending review is an unsubmitted draft, visible to nobody but its author.
    func testPendingReviewsAreNotReviewers() throws {
        let pullRequest = try XCTUnwrap(try mapped().first { $0.number == 4012 })
        XCTAssertFalse(pullRequest.reviews.contains { $0.login == "sam" })
    }

    /// The avatar row has to be stable across polls, so its order comes from submission
    /// time and the login, never from the order the API happened to answer in.
    func testReviewerOrderIsDeterministic() {
        let connection = ReviewConnectionDTO(nodes: [
            ReviewDTO(
                author: ActorDTO(login: "zoe", avatarUrl: nil),
                state: "APPROVED",
                submittedAt: Date(timeIntervalSince1970: 100)
            ),
            ReviewDTO(
                author: ActorDTO(login: "adam", avatarUrl: nil),
                state: "APPROVED",
                submittedAt: Date(timeIntervalSince1970: 100)
            ),
            ReviewDTO(
                author: ActorDTO(login: "mia", avatarUrl: nil),
                state: "COMMENTED",
                submittedAt: Date(timeIntervalSince1970: 50)
            )
        ])
        XCTAssertEqual(
            PullRequestMapper.reviewers(from: connection).map(\.login),
            ["mia", "adam", "zoe"]
        )
    }

    func testReviewsWithoutAnAuthorAreIgnored() {
        let connection = ReviewConnectionDTO(nodes: [
            ReviewDTO(author: nil, state: "APPROVED", submittedAt: nil),
            ReviewDTO(author: ActorDTO(login: "", avatarUrl: nil), state: "APPROVED", submittedAt: nil)
        ])
        XCTAssertTrue(PullRequestMapper.reviewers(from: connection).isEmpty)
    }
}
