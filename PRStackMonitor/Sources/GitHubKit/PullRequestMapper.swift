import Foundation
import PRStackCore

/// Turns one search node into a domain ``PullRequest``.
///
/// Everything GitHub-shaped stops here. Above this type the app only ever sees
/// `PRStackCore` values, which is what lets derivation be tested without a network layer
/// and what would let a second forge be added without touching the domain.
enum PullRequestMapper {
    /// A node either becomes a pull request or is skipped with a reason for the warning
    /// list. The cases that reach ``skipped(_:)`` in practice are a non-`PullRequest` node
    /// in the ISSUE search union, and a repository the token can see the search result for
    /// but not the details of.
    enum Outcome: Equatable {
        case mapped(PullRequest)
        case skipped(String)
    }

    static func map(_ node: PullRequestNodeDTO) -> Outcome {
        guard node.isPullRequest else {
            return .skipped("skipped a \(node.typeName ?? "node") — the search returns issues too")
        }
        guard let number = node.number else {
            return .skipped("skipped a pull request with no number")
        }
        guard let repo = node.repository?.nameWithOwner, !repo.isEmpty else {
            return .skipped("skipped #\(number): no repository name")
        }
        // The exact predicate `LocalState` runs every persisted key through. Validating
        // here, at the one place untrusted input becomes an id, keeps a malformed repo
        // name from reaching `PRID`'s assert — and from being written into a state file
        // that would then drop the entry on the next launch.
        guard PRID(rawValue: "\(repo)#\(number)") != nil else {
            return .skipped("skipped '\(repo)#\(number)': not a usable pull request id")
        }
        guard let updatedAt = node.updatedAt else {
            return .skipped("skipped \(repo)#\(number): no updatedAt")
        }

        return .mapped(
            PullRequest(
                repo: repo,
                number: number,
                title: node.title ?? "",
                body: node.body,
                url: node.url.flatMap(URL.init(string:)),
                headRef: node.headRefName ?? "",
                baseRef: node.baseRefName ?? "",
                isDraft: node.isDraft ?? false,
                state: state(node.state),
                authorLogin: node.author?.login ?? "",
                reviewDecision: reviewDecision(node.reviewDecision),
                reviews: reviewers(
                    from: node.reviews,
                    requests: node.reviewRequests,
                    author: node.author?.login
                ),
                checks: checks(from: node.commits),
                mergeable: mergeable(node.mergeable),
                mergeCommit: node.mergeCommit?.oid,
                createdAt: node.createdAt,
                updatedAt: updatedAt,
                mergedAt: node.mergedAt,
                commentCount: node.comments?.totalCount ?? 0,
                lastCommentAt: lastCommentAt(from: node.comments),
                // Linear resolution is M5's job and runs off the title, branch and body
                // this mapper has just carried through.
                linearIssues: []
            )
        )
    }

    // MARK: - Enumerations

    /// GitHub reports a merged pull request as `MERGED`, never as `CLOSED`, and the row
    /// status precedence depends on that distinction.
    static func state(_ raw: String?) -> GitHubState {
        switch raw?.uppercased() {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return .open
        }
    }

    static func mergeable(_ raw: String?) -> Mergeable {
        switch raw?.uppercased() {
        case "MERGEABLE": return .mergeable
        case "CONFLICTING": return .conflicting
        default: return .unknown
        }
    }

    static func reviewDecision(_ raw: String?) -> ReviewDecision? {
        switch raw?.uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .reviewRequired
        default: return nil
        }
    }

    static func reviewState(_ raw: String?) -> ReviewState? {
        switch raw?.uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "COMMENTED": return .commented
        case "DISMISSED": return .dismissed
        case "PENDING": return .pending
        default: return nil
        }
    }

    // MARK: - Reviewers

    /// One row per reviewer: everyone who has submitted a review, then everyone who has
    /// been asked for one and has not.
    ///
    /// Four rules, all of which match what GitHub itself shows and none of which falls out
    /// of "take the last node":
    ///
    /// - A `PENDING` review is an unsubmitted draft, visible to nobody but its author. It
    ///   is dropped, not rendered as a reviewer who has done nothing.
    /// - `COMMENTED` does not overwrite a standing `APPROVED` or `CHANGES_REQUESTED`. A
    ///   reviewer who approves and then leaves a remark is still an approver, and letting
    ///   the remark win would quietly turn a green avatar ring grey.
    /// - **The author is not one of their own reviewers.** Every review comment on GitHub
    ///   belongs to a `PullRequestReview`, so replying to a reviewer on your own pull
    ///   request submits a `COMMENTED` review by you. Kept, it puts the author's own
    ///   avatar in the row of people reviewing them — which, since the panel lists only
    ///   `author:@me` pull requests, is every reply you have ever left.
    /// - **An open review request is a reviewer.** `reviews` is submissions only, so a
    ///   pull request waiting on people who have not looked at it yet would otherwise show
    ///   an empty avatar row — the state the row is most needed for. Requests answer
    ///   ``ReviewState/requested``, which tones neutral: asked, no verdict.
    ///
    /// Submitted reviews are ordered by submission time with the login as a tie-break, and
    /// requests follow in name order, so the avatar row is stable across polls rather than
    /// following API order. Requests come last on purpose: the row renders only
    /// `avatarLimit` of them, and a reviewer who has actually answered outranks one who
    /// has been asked when something has to become `+2`. A re-requested reviewer who
    /// already has a review keeps the review — the verdict still stands and is the more
    /// informative of the two.
    ///
    /// Bounded by `reviews(last: 20)` and `reviewRequests(first: 10)` — the plan's query
    /// (§3). A reviewer whose only approval sits further back than the last twenty reviews
    /// is not represented here. That is accepted rather than overlooked: the selections
    /// multiply against 50 pull requests per page and are billed in points, and paginating
    /// reviews would cost a request per pull request, which the per-poll budget exists to
    /// prevent. The row's *status* does not depend on this — `reviewDecision` is a separate
    /// field and is always GitHub's current answer — so what lags on an unusually long
    /// review thread is one avatar's ring, not the panel's correctness.
    static func reviewers(
        from connection: ReviewConnectionDTO?,
        requests: ReviewRequestConnectionDTO? = nil,
        author: String? = nil
    ) -> [ReviewerState] {
        struct Entry {
            var login: String
            var avatarURL: URL?
            var state: ReviewState
            var submittedAt: Date?
            var isSticky: Bool
        }

        var entries: [String: Entry] = [:]

        for node in (connection?.nodes ?? []).compactMap({ $0 }) {
            guard let login = node.author?.login, !login.isEmpty else { continue }
            guard login != author else { continue }
            guard let state = reviewState(node.state), state != .pending else { continue }

            let sticky = state == .approved || state == .changesRequested || state == .dismissed
            if let existing = entries[login], existing.isSticky, !sticky { continue }

            let avatar: String? = node.author?.avatarUrl
            entries[login] = Entry(
                login: login,
                avatarURL: avatar.flatMap(URL.init(string:)),
                state: state,
                submittedAt: node.submittedAt,
                isSticky: sticky
            )
        }

        let submitted = entries.values
            .sorted { left, right in
                let leftDate = left.submittedAt ?? .distantPast
                let rightDate = right.submittedAt ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                return left.login < right.login
            }
            .map { ReviewerState(login: $0.login, avatarURL: $0.avatarURL, state: $0.state) }

        return submitted + requested(from: requests, excluding: Set(entries.keys), author: author)
    }

    /// The open review requests, minus anyone already answered for by a submitted review.
    private static func requested(
        from connection: ReviewRequestConnectionDTO?,
        excluding seen: Set<String>,
        author: String?
    ) -> [ReviewerState] {
        var names: Set<String> = []
        var result: [ReviewerState] = []

        for node in (connection?.nodes ?? []).compactMap({ $0 }) {
            // A `Bot` or a `Mannequin` reaches here with neither `login` nor `slug`
            // selected. There is nothing to draw an avatar from, so it is dropped rather
            // than rendered as a `?`.
            guard let reviewer = node.requestedReviewer, let name = reviewer.name else { continue }
            // `author` is a login, and a team's name is a slug. Comparing the two is a
            // category error: a team whose slug happens to match the author's login is a
            // different reviewer and stays.
            if !reviewer.isTeam, name == author { continue }
            // `seen` is login-keyed, so a team slug colliding with a submitted reviewer's
            // login is dropped here. That collision is resolved the same way one layer up
            // — `RowPresentation.badges(for:)` is keyed on `login` too — so distinguishing
            // the namespaces here alone would move the drop without changing the row.
            // Showing both needs the kind carried on `ReviewerState`, not a richer key.
            guard !seen.contains(name), names.insert(name).inserted else { continue }

            let avatar: String? = reviewer.avatarUrl
            result.append(
                ReviewerState(
                    login: name,
                    avatarURL: avatar.flatMap(URL.init(string:)),
                    state: .requested
                )
            )
        }

        return result.sorted { $0.login < $1.login }
    }

    // MARK: - Checks

    /// The rollup for the head commit, plus how many contexts are failing.
    ///
    /// The rollup `state` is authoritative for green/red/amber — the per-context nodes
    /// exist only to name a count for the status phrase (`2 checks failed`). `contexts` is
    /// capped at 20, so a rollup that reports failure while the page shows none still
    /// reports one failure rather than claiming a failing rollup with nothing failing.
    static func checks(from commits: CommitConnectionDTO?) -> CheckRollup {
        let rollup = (commits?.nodes ?? [])
            .compactMap { $0 }
            .last?
            .commit?
            .statusCheckRollup

        guard let rollup else { return .noChecks }

        switch rollup.state?.uppercased() {
        case "SUCCESS":
            return .passing
        case "FAILURE", "ERROR":
            return .failing(max(1, failingContextCount(rollup.contexts)))
        case "PENDING", "EXPECTED":
            return .running
        default:
            return .noChecks
        }
    }

    private static let failedConclusions: Set<String> = [
        "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "CANCELLED"
    ]
    private static let failedStatusStates: Set<String> = ["FAILURE", "ERROR"]

    private static func failingContextCount(_ contexts: CheckContextConnectionDTO?) -> Int {
        (contexts?.nodes ?? []).compactMap { $0 }.reduce(into: 0) { count, context in
            if let conclusion = context.conclusion?.uppercased(),
               failedConclusions.contains(conclusion) {
                count += 1
            } else if let state = context.state?.uppercased(),
                      failedStatusStates.contains(state) {
                count += 1
            }
        }
    }

    // MARK: - Comments

    /// `comments(last: 1)` yields both the total and the newest timestamp, which is the
    /// pair the unread digest reads.
    static func lastCommentAt(from connection: CommentConnectionDTO?) -> Date? {
        (connection?.nodes ?? []).compactMap { $0?.createdAt }.max()
    }
}
