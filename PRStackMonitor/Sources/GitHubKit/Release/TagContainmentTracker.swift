import Foundation
import NetKit
import PRStackCore

/// v1's release tracker: **shipped means the merge commit is contained in a tag matching
/// the repository's pattern** (IMPLEMENTATION_PLAN §3).
///
/// Per repository with an unbound merge: read the matching tags, order them by their own
/// timestamps, then test containment **oldest candidate first**, so the release a pull
/// request binds to is the *earliest* one that contains it rather than an arbitrary one.
/// The first hit wins and the binding is permanent, which is why every ordering decision
/// here is made locally and deterministically rather than taken from the API.
///
/// Two bounds keep this from growing without limit, and they work together: each unbound
/// merge persists the tags it has already been compared against, so a negative is as
/// durable as a positive; and a per-poll comparison budget defers the rest to the next
/// poll. Steady state after the first poll following a release cut is near zero
/// comparisons, because only genuinely new tags are untested.
public struct TagContainmentTracker: ReleaseTracker {
    public struct Configuration: Equatable, Sendable {
        /// Which tags count as releases, per repository. `v*` for anything unlisted.
        public var tagPatterns: TagPatterns
        /// `compare` calls one poll may spend, oldest candidates first. Exceeding it defers
        /// the remainder — a pull request shipping is not urgent enough to spend a rate
        /// limit on, and the persisted negatives mean the work already done is never
        /// repeated.
        public var comparisonBudget: Int
        public var tagRefs: TagRefsClient.Configuration
        public var restBaseURL: URL

        public init(
            tagPatterns: TagPatterns = .standard,
            comparisonBudget: Int = 20,
            tagRefs: TagRefsClient.Configuration = TagRefsClient.Configuration(),
            restBaseURL: URL = GitHubAPI.restBaseURL
        ) {
            self.tagPatterns = tagPatterns
            self.comparisonBudget = max(0, comparisonBudget)
            self.tagRefs = tagRefs
            self.restBaseURL = restBaseURL
        }
    }

    private let tags: TagRefsClient
    private let rest: RESTClient
    private let configuration: Configuration

    public init(
        transport: any HTTPTransport,
        tokenProvider: any TokenProvider,
        configuration: Configuration = Configuration(),
        etagStore: any ETagStore = InMemoryETagStore()
    ) {
        self.tags = TagRefsClient(
            transport: transport,
            tokenProvider: tokenProvider,
            configuration: configuration.tagRefs
        )
        self.rest = RESTClient(
            transport: transport,
            tokenProvider: tokenProvider,
            baseURL: configuration.restBaseURL,
            etagStore: etagStore
        )
        self.configuration = configuration
    }

    public func poll(unbound: [PRID: UnboundMerge], now: Date) async throws -> ReleaseTrackerResult {
        var result = ReleaseTrackerResult()
        guard !unbound.isEmpty, configuration.comparisonBudget > 0 else { return result }

        var remainingComparisons = configuration.comparisonBudget
        /// Set when a comparison comes back with less than 10% of the REST allowance left.
        /// From then on the budget is zero for the rest of this poll, and the negatives
        /// already collected are kept — so the deferred work resumes rather than restarting.
        var restFloorReached = false

        // Sorted, so two polls over the same state spend the budget on the same repositories
        // in the same order. `Dictionary` iteration order is not stable across processes,
        // and "which repository got the budget" would otherwise vary between launches.
        let byRepository = Dictionary(grouping: unbound.keys, by: \.repo)

        repositories: for repository in byRepository.keys.sorted() {
            let merges = (byRepository[repository] ?? [])
                .compactMap { id in unbound[id].map { (id: id, merge: $0) } }
                // Oldest merge first: it has been waiting longest, and its candidate list is
                // the one most likely to contain the answer.
                .sorted { left, right in
                    if left.merge.mergedAt != right.merge.mergedAt {
                        return left.merge.mergedAt < right.merge.mergedAt
                    }
                    return PRID.panelOrder(left.id, right.id)
                }
            guard !merges.isEmpty else { continue }

            let fetch: TagFetch
            do {
                fetch = try await tags.fetchCandidates(
                    repository: repository,
                    glob: configuration.tagPatterns.glob(for: repository)
                )
            } catch let error as GitHubError {
                // An expired token or a spent allowance is not this repository's problem —
                // it ends the poll. Anything else is: a repository that has been renamed or
                // whose access was revoked must not stop the others from binding.
                if error.endsThePoll { throw error }
                result.warnings.append(
                    .releaseTrackingFailed(repository: repository, reason: error.description)
                )
                continue repositories
            }

            result.pointsSpent += fetch.pointsSpent
            result.rateLimit = fetch.rateLimit ?? result.rateLimit
            result.warnings.append(contentsOf: fetch.warnings)
            guard !fetch.candidates.isEmpty else { continue }

            for (id, merge) in merges {
                if restFloorReached { break repositories }
                // Only tags as new as the merge can contain it, and only tags never tested
                // against *this* commit are worth a request. `fetch.candidates` is already
                // oldest-first, so the first hit is the earliest release.
                //
                // The bound is inclusive, and that is load-bearing rather than tidy. A
                // lightweight tag carries its target commit's date, so a tag cut directly on
                // the merge commit — the ordinary "tag the release" workflow — reports
                // exactly `mergedAt`. A strict `>` would drop it from the candidate list on
                // every poll, and it would never enter `comparedTags` to be reconsidered, so
                // the row would sit at `merged · awaiting release` for good. One redundant
                // comparison against a same-instant tag costs a request; missing it costs
                // the binding.
                let untested = fetch.candidates.filter { candidate in
                    candidate.taggedAt >= merge.mergedAt && !merge.comparedTags.contains(candidate.name)
                }
                guard !untested.isEmpty else { continue }

                var negatives: Set<String> = []
                candidates: for candidate in untested {
                    guard !restFloorReached else {
                        if !negatives.isEmpty { result.comparisons[id] = negatives }
                        break repositories
                    }
                    guard remainingComparisons > 0 else {
                        result.warnings.append(
                            .comparisonBudgetExhausted(
                                spent: result.comparisonsMade,
                                limit: configuration.comparisonBudget
                            )
                        )
                        if !negatives.isEmpty { result.comparisons[id] = negatives }
                        break repositories
                    }

                    remainingComparisons -= 1
                    result.comparisonsMade += 1

                    let comparison: ComparisonResult
                    do {
                        comparison = try await rest.compare(
                            repository: repository,
                            tag: candidate.name,
                            containsCommit: merge.mergeCommit
                        )
                    } catch let error as GitHubError {
                        if error.endsThePoll { throw error }
                        // A tag deleted between the ref query and this call, or a commit
                        // that no longer exists. Report it and leave the whole repository
                        // for the next poll: the merges under it share the candidate list
                        // that just failed, so trying the next one spends the budget on a
                        // repository that is answering with errors.
                        result.warnings.append(
                            .releaseTrackingFailed(repository: repository, reason: error.description)
                        )
                        if !negatives.isEmpty { result.comparisons[id] = negatives }
                        continue repositories
                    }

                    result.restRateLimit = comparison.rateLimit ?? result.restRateLimit
                    // Backing off on the *measured* remaining allowance, before exhaustion,
                    // is what keeps the app from being hard-blocked mid-poll for the rest of
                    // the hour (IMPLEMENTATION_PLAN §3). Noted here and acted on at the top
                    // of the loop, so this comparison's own answer is still banked.
                    if let rest = comparison.rateLimit, rest.isBelowFloor, !restFloorReached {
                        restFloorReached = true
                        result.warnings.append(
                            .rateLimitFloorReached(
                                remaining: rest.remaining,
                                limit: rest.limit,
                                resetAt: rest.resetAt
                            )
                        )
                    }

                    if comparison.containment.contains {
                        result.bindings[id] = candidate.name
                        break candidates
                    }
                    // A `304` reaches here too, and recording it as a negative is right: a
                    // positive would have bound the pull request and stopped the pair ever
                    // being compared again, so an unchanged answer can only be a repeat of
                    // a negative.
                    negatives.insert(candidate.name)
                }

                if !negatives.isEmpty { result.comparisons[id] = negatives }
            }
        }

        return result
    }
}

extension GitHubError {
    /// Whether this failure is about the connection rather than about one repository.
    ///
    /// Only these two stop the whole poll. Everything else — a 404 for a renamed
    /// repository, a deleted tag, a malformed answer — is scoped to the repository it came
    /// from, and the other repositories' merges are still perfectly bindable.
    var endsThePoll: Bool {
        if isAuthenticationFailure { return true }
        if case .rateLimited = self { return true }
        return false
    }
}
