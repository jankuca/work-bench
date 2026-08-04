import Foundation
import GitHubKit
import PRStackCore

/// The live half of the dump: one poll against GitHub, mapped to the same input the
/// fixture path produces.
enum GitHubSource {
    static func load(options: DumpOptions, now: Date) async throws -> DumpInput {
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
        return DumpInput(now: now, snapshot: fetch.snapshot)
    }

    /// `--token`, then the environment, then the login keychain. The keychain is last
    /// because an explicit flag or an exported variable is always the more deliberate
    /// intent, and it is absent entirely off macOS.
    private static func tokenProvider(options: DumpOptions) -> any TokenProvider {
        var providers: [any TokenProvider] = []
        if let token = options.token {
            providers.append(StaticTokenProvider(token))
        }
        providers.append(EnvironmentTokenProvider())
        #if canImport(Security)
        providers.append(KeychainTokenStore(account: .github))
        #endif
        return FirstAvailableTokenProvider(providers)
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
        write(lines.joined(separator: "\n") + "\n")
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

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
