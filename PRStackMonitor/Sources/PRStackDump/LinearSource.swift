import Foundation
import LinearKit
import NetKit
import PRStackCore

/// The Linear half of a live dump: scan the fetched pull requests for identifiers, resolve
/// them, and hand back the same pull requests with their issues attached.
///
/// This is what M5 is demoable against — `prstack-dump --github` prints real project
/// headings, a `+N` on a multi-ticket pull request, and (with `--linear-token bad`) a
/// panel whose rows keep their cached headings while the footer reads `Linear stale`.
enum LinearSource {
    static func resolve(
        _ pullRequests: [PullRequest],
        options: DumpOptions,
        now: Date
    ) async -> (pullRequests: [PullRequest], health: SourceHealth?) {
        guard options.resolvesLinear else {
            Diagnostics.write("linear: skipped (--no-linear)")
            return (pullRequests, .unconfigured)
        }

        let resolver = LinearResolver(
            client: LinearClient(
                transport: URLSessionTransport.standard(),
                tokenProvider: tokenProvider(options: options)
            ),
            store: store(options: options)
        )
        let resolution = await resolver.resolve(pullRequests: pullRequests, now: now)
        report(resolution)
        return (resolution.pullRequests, resolution.health)
    }

    /// `--linear-token`, then the environment, then the login keychain — the same order,
    /// and for the same reasons, as the GitHub credential.
    private static func tokenProvider(options: DumpOptions) -> any TokenProvider {
        var providers: [any TokenProvider] = []
        if let token = options.linearToken {
            providers.append(StaticTokenProvider(token, service: "Linear"))
        }
        providers.append(EnvironmentTokenProvider.linear())
        #if canImport(Security)
        providers.append(KeychainTokenStore(account: .linear))
        #endif
        return FirstAvailableTokenProvider(providers, service: "Linear")
    }

    /// A file store only when one is asked for. The dump is a one-shot tool, so an
    /// in-memory cache is the honest default — it resolves everything it sees, every run,
    /// which is what makes the request diagnostics below mean anything. `--linear-cache`
    /// is how the caching behaviour itself gets exercised, by running the tool twice.
    private static func store(options: DumpOptions) -> any LinearProjectCacheStore {
        guard let path = options.linearCachePath else { return InMemoryLinearProjectCacheStore() }
        return FileLinearProjectCacheStore(url: URL(fileURLWithPath: path))
    }

    private static func report(_ resolution: LinearResolution) {
        let issues = resolution.pullRequests.reduce(0) { $0 + $1.linearIssues.count }
        var lines = [
            "linear: \(issues) issue(s) attached"
                + ", \(resolution.cacheHits) from cache"
                + ", \(resolution.fetchedCount) fetched"
                + ", health: \(describe(resolution.health))"
        ]
        lines.append(contentsOf: resolution.warnings.map { "warning: " + $0.description })
        Diagnostics.write(lines.joined(separator: "\n"))
    }

    private static func describe(_ health: SourceHealth?) -> String {
        guard let health else { return "unchanged (cancelled)" }
        switch health {
        case .connected: return "connected"
        case .unconfigured: return "not configured — every row falls to Other"
        case .unauthorized(let message): return "disconnected: \(message)"
        case .unreachable(let message): return "stale: \(message)"
        }
    }
}
