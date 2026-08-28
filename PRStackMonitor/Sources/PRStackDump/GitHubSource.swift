import Foundation
import GitHubKit
import NetKit
import PRStackCore

/// The GitHub half of a live dump: one paginated search, mapped to domain values.
///
/// Linear resolution runs after it and separately (``LinearSource``), which is the plan's
/// sequential fetch — there are no identifiers to resolve until GitHub has answered.
enum GitHubSource {
    static func fetch(options: DumpOptions) async throws -> PullRequestFetch {
        let client = GitHubClient(
            transport: URLSessionTransport.standard(),
            tokenProvider: tokenProvider(options: options),
            configuration: GitHubClient.Configuration(
                pageSize: options.pageSize,
                pageCap: options.pageCap,
                pointBudget: options.pointBudget
            )
        )

        let fetch: PullRequestFetch
        do {
            fetch = try await client.fetchPullRequests(
                scope: options.scope,
                includesDrafts: options.includesDrafts,
                extraQualifiers: options.qualifiers
            )
        } catch let error as GitHubError {
            throw DumpFailure(describe(error))
        }

        report(fetch)
        return fetch
    }

    /// The full M6 poll: the open search, the closed search bounded by the oldest merge
    /// still waiting for a tag, and then the tag/`compare` pass that binds them.
    ///
    /// Runs only under `--releases`, because it costs a second search and up to
    /// `--comparisons` REST calls per run — and because the one-search path above is what
    /// M2's done-criteria is written against.
    static func poll(options: DumpOptions, local: LocalState, now: Date) async throws -> GitHubPollResult {
        let credentials = tokenProvider(options: options)
        let transport = URLSessionTransport.standard()
        let pipeline = GitHubPoll(
            client: GitHubClient(
                transport: transport,
                tokenProvider: credentials,
                configuration: GitHubClient.Configuration(
                    pageSize: options.pageSize,
                    pageCap: options.pageCap,
                    pointBudget: options.pointBudget
                )
            ),
            tracker: TagContainmentTracker(
                transport: transport,
                tokenProvider: credentials,
                configuration: TagContainmentTracker.Configuration(
                    tagPatterns: TagPatterns(options.tagPatterns),
                    comparisonBudget: options.comparisonBudget
                )
            ),
            recovery: MergeCommitRecovery(transport: transport, tokenProvider: credentials),
            // The diagnostic surface for merges that did not target trunk: without this the
            // dump reports them as awaiting a release and never says what they are actually
            // waiting on.
            baseBranches: BaseBranchResolver(transport: transport, tokenProvider: credentials)
        )

        let result: GitHubPollResult
        do {
            result = try await pipeline.run(
                scope: options.scope,
                includesDrafts: options.includesDrafts,
                local: local,
                now: now
            )
        } catch let error as GitHubError {
            throw DumpFailure(describe(error))
        }

        report(result.open, label: "open")
        report(result.closed, label: "closed")
        reportRecovery(result.recovery)
        reportBaseBranches(result.baseBranches)
        reportReleases(result.release)
        return result
    }

    /// `--token`, then the environment, then the login keychain — the shared chain, so the
    /// order and the `canImport(Security)` fence live in one place (``CredentialChain``).
    private static func tokenProvider(options: DumpOptions) -> any TokenProvider {
        CredentialChain.standard(
            explicit: options.token,
            environment: .github(),
            keychain: .github,
            service: "GitHub"
        )
    }

    /// Diagnostics go to stderr so `prstack-dump --github > panel.txt` still captures only
    /// the panel.
    private static func report(_ fetch: PullRequestFetch, label: String? = nil) {
        let kind = label.map { $0 + " " } ?? ""
        var lines = [
            "fetched \(fetch.pullRequests.count) \(kind)pull requests"
                + " as \(fetch.viewerLogin.isEmpty ? "(unknown viewer)" : fetch.viewerLogin)"
                + " in \(fetch.pagesFetched) page(s)"
                + ", \(fetch.pointsSpent) GraphQL point(s)"
                + ", stopped: \(fetch.stopReason.rawValue)"
        ]
        if let rateLimit = fetch.rateLimit {
            lines.append("rate limit: \(rateLimit.remaining) of \(rateLimit.limit) points left")
        }
        if let cursor = fetch.nextCursor {
            lines.append("more results remain; resume after cursor \(cursor)")
        }
        lines.append(contentsOf: fetch.warnings.map { "warning: " + $0.description })
        Diagnostics.write(lines.joined(separator: "\n"))
    }

    /// The trunk lookups for merges GitHub reported no commit for.
    ///
    /// Warnings go out even when nothing was recovered: a repository that could not be read
    /// is *why* a row is still sitting at `merged · awaiting release`, and silence there
    /// looks identical to "there was nothing to recover".
    private static func reportRecovery(_ result: MergeCommitRecoveryResult) {
        var lines: [String] = []
        if !result.commits.isEmpty {
            lines.append(
                "recovered \(result.commits.count) merge commit(s) from trunk"
                    + " for pull requests GitHub reported none for"
            )
        }
        lines.append(contentsOf: result.warnings.map { "warning: " + $0.description })
        guard !lines.isEmpty else { return }
        Diagnostics.write(lines.joined(separator: "\n"))
    }

    /// Where merges that landed on another pull request's branch were followed to.
    ///
    /// This is the line that answers "why is #4012 still shipping" for a stacked pull
    /// request, which before this pass existed had no answer at all: the row said
    /// `awaiting release` whether it was waiting on a tag, on a colleague's pull request,
    /// or on nothing that would ever come.
    private static func reportBaseBranches(_ result: BaseBranchResolution) {
        guard !result.isEmpty else { return }
        var lines = [
            "base branches: \(result.anchors.count) merge(s) followed"
                + ", \(result.pointsSpent) GraphQL point(s)"
        ]
        for id in result.anchors.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let anchor = result.anchors[id] else { continue }
            lines.append("  \(id.rawValue) \(describe(anchor.outcome))")
        }
        lines.append(contentsOf: result.warnings.map { "warning: " + $0.description })
        Diagnostics.write(lines.joined(separator: "\n"))
    }

    private static func describe(_ outcome: MergeAnchorOutcome) -> String {
        switch outcome {
        case .pending(let parent):
            return "merged into \(parent.rawValue), still open"
        case .landed(let root, let commit, _):
            return "reached trunk via \(root.rawValue) as \(commit)"
        case .abandoned(let parent):
            return "merged into \(parent.rawValue), closed without merging"
        case .untracked(let branch):
            return "merged into '\(branch)', which no pull request owns"
        case .unresolved(let branch):
            return "merged into '\(branch)', which could not be followed this time"
        }
    }

    /// What the release pass actually did. Bindings are the interesting line — everything
    /// else is there so a run that bound nothing still says why.
    private static func reportReleases(_ result: ReleaseTrackerResult) {
        var lines = [
            "release tracking: \(result.bindings.count) newly shipped"
                + ", \(result.comparisonsMade) comparison(s)"
                + ", \(result.pointsSpent) GraphQL point(s) on tags"
        ]
        for (id, tag) in result.bindings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("  \(id.rawValue) shipped in \(tag)")
        }
        if let limit = result.restRateLimit {
            lines.append("REST limit: \(limit.remaining) of \(limit.limit) request(s) left")
        }
        lines.append(contentsOf: result.warnings.map { "warning: " + $0.description })
        Diagnostics.write(lines.joined(separator: "\n"))
    }

    private static func describe(_ error: GitHubError) -> String {
        switch error {
        case .missingToken:
            return """
            no GitHub token found.

            Pass --token, export PRSTACK_GITHUB_TOKEN, or store one in the login keychain.
            A classic personal access token with the `repo` scope — or `public_repo` if every
            repository in scope is public (IMPLEMENTATION_PLAN §3).

            A fine-grained token authenticates and answers the search, then fails
            `statusCheckRollup` on every pull request with FORBIDDEN, so CI status comes back
            empty. GitHub Support's answer is that Checks cannot be granted to a fine-grained
            token at all — the capability existed, hit edge cases, and was withdrawn — which
            leaves a GitHub App as the only alternative to a classic token.
            """
        default:
            return error.description
        }
    }
}

/// Diagnostics go to stderr so `prstack-dump --github > panel.txt` still captures only the
/// panel.
enum Diagnostics {
    static func write(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
