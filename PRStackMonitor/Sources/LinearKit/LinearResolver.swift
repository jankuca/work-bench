import Foundation
import NetKit
import PRStackCore

/// Something worth showing the user that is not an error.
public enum LinearWarning: Equatable, Sendable, CustomStringConvertible {
    /// Linear was asked and does not have these. Almost always the scanner's false
    /// positives (`UTF-8`, `SHA-256`) rather than a problem, which is why this is a
    /// warning in a diagnostic dump and not something the panel shows.
    case unknownIdentifiers([String])
    /// A poll that could not resolve these — the request failed part way. They keep
    /// whatever the cache had, and are asked again next poll.
    case unresolvedIdentifiers([String])
    case graphQL(GraphQLError)

    public var description: String {
        switch self {
        case .unknownIdentifiers(let identifiers):
            return "Linear has no issue for \(identifiers.sorted().joined(separator: ", "))"
        case .unresolvedIdentifiers(let identifiers):
            return "could not resolve \(identifiers.sorted().joined(separator: ", ")) this poll"
        case .graphQL(let error):
            return "Linear reported: \(error.description)"
        }
    }
}

/// One poll's Linear work: pull requests with their issues attached, and how it went.
public struct LinearResolution: Equatable, Sendable {
    public var pullRequests: [PullRequest]
    /// The health the footer reads. Linear is never a menu bar icon state — the panel's
    /// contents do not depend on it (IMPLEMENTATION_PLAN §4/§5).
    ///
    /// `nil` means this poll learned nothing about Linear and the caller should keep the
    /// health it already had. The one thing that produces it is cancellation: the panel
    /// closing mid-poll is not an outage, and recording it as one would put a stale marker
    /// on the footer in response to the user's own click.
    public var health: SourceHealth?
    /// How many identifiers were answered from cache rather than fetched. Diagnostic only.
    public var cacheHits: Int
    public var fetchedCount: Int
    public var warnings: [LinearWarning]

    public init(
        pullRequests: [PullRequest],
        health: SourceHealth?,
        cacheHits: Int = 0,
        fetchedCount: Int = 0,
        warnings: [LinearWarning] = []
    ) {
        self.pullRequests = pullRequests
        self.health = health
        self.cacheHits = cacheHits
        self.fetchedCount = fetchedCount
        self.warnings = warnings
    }
}

/// Scans, resolves, caches, and hands back pull requests with `linearIssues` filled.
///
/// This is the whole of M5's data path in one type. `SyncEngine` calls it with the pull
/// requests `GitHubKit` produced, and `PRStackCore` takes it from there — the plan's
/// sequential fetch (§1): there are no identifiers to resolve until GitHub has answered.
public struct LinearResolver {
    private let client: LinearClient?
    private let store: any LinearProjectCacheStore

    /// `client: nil` is the not-configured path: no key, no requests, and every row falls
    /// to `Other`. It is a valid way to run the app — Linear is optional, GitHub is not.
    public init(client: LinearClient?, store: any LinearProjectCacheStore = InMemoryLinearProjectCacheStore()) {
        self.client = client
        self.store = store
    }

    public func resolve(pullRequests: [PullRequest], now: Date) async -> LinearResolution {
        // Scanned once per pull request and kept, because this order *is* the contract:
        // the primary issue is the first of these with a project, and rebuilding the row's
        // list by walking this list — rather than by appending cache hits and then response
        // fields — is what keeps a row in the same section from one poll to the next.
        let scanned = pullRequests.map { IssueIdentifierScanner.identifiers(in: $0) }

        var wanted = OrderedIdentifiers()
        for identifiers in scanned { wanted.append(identifiers) }
        let identifiers = wanted.values

        guard let client, !identifiers.isEmpty else {
            // With no key configured there is nothing to attach and nothing to be stale
            // about; with no identifiers there is nothing to ask. Either way the cache is
            // left exactly as it was.
            //
            // "Nothing to ask" is reported as `nil`, not as `.connected`. A poll that sent
            // no request verified no connection, and claiming one would silently clear a
            // standing outage: the footer would go quiet while Linear was still down, and
            // the *next* real loss would emit no `connectionLost` event because the
            // previous status had already been reset to healthy.
            let cache = client == nil ? LinearProjectCache.empty : store.load()
            return LinearResolution(
                pullRequests: attach(scanned: scanned, to: pullRequests, using: cache),
                health: client == nil ? .unconfigured : nil
            )
        }

        var cache = store.load()
        let toFetch = cache.staleOrMissing(among: identifiers, now: now)
        let cacheHits = identifiers.count - toFetch.count

        guard !toFetch.isEmpty else {
            // Every identifier was fresh in cache. Same rule as above: no request, so
            // nothing was learned about the connection.
            return LinearResolution(
                pullRequests: attach(scanned: scanned, to: pullRequests, using: cache),
                health: nil,
                cacheHits: cacheHits
            )
        }

        var warnings: [LinearWarning] = []
        let batch: IssueBatchResult
        do {
            batch = try await client.resolve(identifiers: toFetch)
        } catch {
            // The rows keep their cached headings and the source is marked stale. Nothing
            // is reshuffled and nothing is written: a failed poll has learned nothing, and
            // recording that would be recording a guess.
            return LinearResolution(
                pullRequests: attach(scanned: scanned, to: pullRequests, using: cache),
                health: Cancellation.matches(error) ? nil : health(for: error),
                cacheHits: cacheHits
            )
        }

        for (identifier, issue) in batch.found { cache.record(issue, for: identifier, at: now) }
        for identifier in batch.unknown { cache.recordUnknown(identifier, at: now) }
        // Prune to what this scan actually references, so the file cannot grow across the
        // life of the app — a pull request retitled twice leaves two dead identifiers
        // behind, and negatives like `UTF-8` accumulate from every PR that ever mentioned
        // one. Only on a poll that reached this far: a failed or cancelled poll returned
        // above, so an outage never prunes the cache it is meant to be falling back on.
        // The cost of pruning something still wanted is one lookup on a later poll.
        cache.retainOnly(identifiers)
        store.save(cache)

        if !batch.unknown.isEmpty { warnings.append(.unknownIdentifiers(Array(batch.unknown))) }
        if !batch.unresolved.isEmpty { warnings.append(.unresolvedIdentifiers(Array(batch.unresolved))) }
        warnings.append(contentsOf: batch.errors.map(LinearWarning.graphQL))

        return LinearResolution(
            pullRequests: attach(scanned: scanned, to: pullRequests, using: cache),
            // A batch that came back at all is a healthy connection. Individual identifiers
            // it could not settle are the scanner's problem, not the source's, and marking
            // Linear stale for a `UTF-8` in somebody's title would leave the footer warning
            // about a service that is answering perfectly well.
            health: .connected,
            cacheHits: cacheHits,
            fetchedCount: toFetch.count,
            warnings: warnings
        )
    }

    /// Rebuilds each pull request's ordered issue list by walking its **own** identifier
    /// order and looking each one up.
    ///
    /// Never by appending cache hits and then freshly-fetched ones. That is the bug
    /// `linear-resolve-order-cache-vs-fresh` exists to catch: a pull request linking
    /// `BIL-312` and `SRC-97` would yield `[BIL-312, SRC-97]` on the poll where both are
    /// cached and `[SRC-97, BIL-312]` on the poll where one is freshly fetched, and the row
    /// would migrate from Billing to Source and back with nothing having changed.
    private func attach(
        scanned: [[String]],
        to pullRequests: [PullRequest],
        using cache: LinearProjectCache
    ) -> [PullRequest] {
        zip(pullRequests, scanned).map { pair -> PullRequest in
            var resolved = pair.0
            // Identifiers with no issue behind them — Linear's "no such thing", or one this
            // poll never got an answer for — are dropped rather than rendered. A meta line
            // reading `UTF-8` would be worse than one reading nothing at all.
            resolved.linearIssues = pair.1.compactMap { cache.issue(for: $0) }
            return resolved
        }
    }

    private func health(for error: any Error) -> SourceHealth {
        guard let error = error as? LinearError else {
            return .unreachable(error.localizedDescription)
        }
        switch error {
        case .missingKey:
            return .unconfigured
        case _ where error.isAuthenticationFailure:
            return .unauthorized(error.description)
        default:
            return .unreachable(error.description)
        }
    }
}
