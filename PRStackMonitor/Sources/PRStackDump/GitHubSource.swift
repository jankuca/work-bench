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
                extraQualifiers: options.qualifiers
            )
        } catch let error as GitHubError {
            throw DumpFailure(describe(error))
        }

        report(fetch)
        return fetch
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
    private static func report(_ fetch: PullRequestFetch) {
        var lines = [
            "fetched \(fetch.pullRequests.count) pull requests"
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

    private static func describe(_ error: GitHubError) -> String {
        switch error {
        case .missingToken:
            return """
            no GitHub token found.

            Pass --token, export PRSTACK_GITHUB_TOKEN, or store one in the login keychain.
            A fine-grained personal access token with read-only Contents, Pull requests and
            Metadata is all this needs (IMPLEMENTATION_PLAN §3).
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
