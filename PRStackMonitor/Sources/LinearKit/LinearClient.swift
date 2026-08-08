import Foundation
import NetKit
import PRStackCore

/// What one round of resolution learned about a set of identifiers.
public struct IssueBatchResult: Equatable, Sendable {
    /// Identifiers Linear answered for.
    public var found: [String: IssueRef]
    /// Identifiers Linear was asked about and does not have. Worth remembering: the scan
    /// cannot tell `UTF-8` from a team key, and without a negative answer on record the
    /// same junk identifier is re-queried on every poll, forever.
    public var unknown: Set<String>
    /// Identifiers no *usable* answer was obtained for: the batch was abandoned, or Linear
    /// failed the field for a reason other than the issue not existing — a permission
    /// error, a resolver fault. **Not** cached either way, so they are asked again next
    /// poll. Caching one as `unknown` would strip a real ticket's project heading for a day
    /// over a transient fault.
    public var unresolved: Set<String>
    public var errors: [GraphQLError]

    public init(
        found: [String: IssueRef] = [:],
        unknown: Set<String> = [],
        unresolved: Set<String> = [],
        errors: [GraphQLError] = []
    ) {
        self.found = found
        self.unknown = unknown
        self.unresolved = unresolved
        self.errors = errors
    }
}

/// The Linear half of one poll: batched `issue(id:)` lookups.
///
/// Deliberately smaller than ``GitHubKit``'s client. Linear is not metered in points, is
/// not paginated here (a batch is a fixed set of aliases, not a connection), and its
/// answers are cached indefinitely — so the whole surface is "resolve these identifiers,
/// and say which ones you could not".
public struct LinearClient {
    public struct Configuration: Equatable, Sendable {
        /// How many aliases go in one request.
        ///
        /// Aliases are cheap — the plan's own example batches them freely — but a query is
        /// a string that has to be built, sent and parsed, and an unbounded batch would
        /// send a megabyte of query text on the first poll of a busy account. Forty is
        /// comfortably more than a poll's worth of newly-seen identifiers in steady state.
        public static let defaultBatchSize = 40

        public var batchSize: Int
        public var endpoint: URL

        public init(batchSize: Int = Configuration.defaultBatchSize, endpoint: URL = LinearAPI.endpoint) {
            self.batchSize = max(1, batchSize)
            self.endpoint = endpoint
        }
    }

    private let transport: any HTTPTransport
    private let tokenProvider: any TokenProvider
    private let configuration: Configuration

    public init(
        transport: any HTTPTransport,
        tokenProvider: any TokenProvider,
        configuration: Configuration = Configuration()
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.configuration = configuration
    }

    /// Resolves `identifiers` to issues, in batches.
    ///
    /// Throws only for failures that are about the connection rather than about one
    /// identifier — a missing key, a rejected key, an unreachable host. Everything an
    /// individual identifier can do wrong comes back in the result, because one unknown
    /// ticket must not cost the poll its other thirty-nine answers.
    public func resolve(identifiers: [String]) async throws -> IssueBatchResult {
        var combined = IssueBatchResult()
        for chunk in chunks(identifiers) {
            let outcome = try await resolveBatch(chunk)
            combined.found.merge(outcome.found) { first, _ in first }
            combined.unknown.formUnion(outcome.unknown)
            combined.unresolved.formUnion(outcome.unresolved)
            combined.errors.append(contentsOf: outcome.errors)
        }
        return combined
    }

    /// One request, plus at most one retry.
    ///
    /// The retry exists because of a schema detail with an outsized blast radius: Linear
    /// declares `issue(id:)` as non-null, so an identifier it does not have does not come
    /// back as a null field — the error propagates to the nearest nullable parent, which is
    /// `data` itself, and the whole batch comes back empty. One `UTF-8` scanned out of a
    /// pull request title would otherwise cost every other row in the poll its project
    /// heading.
    ///
    /// What makes it recoverable is `errors[].path`: it names the aliases that failed. So a
    /// wholly-nulled response is not abandoned — the named aliases are set aside, classified
    /// by what the error says went wrong, and the rest are asked for again. Exactly once: a
    /// second failure means the response is not telling us which field is at fault, and
    /// retrying a shrinking batch until it empties would turn one bad poll into forty
    /// requests.
    private func resolveBatch(_ identifiers: [String]) async throws -> IssueBatchResult {
        var result = IssueBatchResult()
        var pending = identifiers
        var attempt = 0

        while !pending.isEmpty {
            let batch = IssueBatchQuery.build(identifiers: pending)
            let response = try await perform(batch)

            var answered: Set<String> = []
            for (alias, issue) in response.payload?.issues ?? [:] {
                guard let identifier = batch.identifiers[alias] else { continue }
                answered.insert(identifier)
                if let issue, let reference = makeReference(from: issue, requested: identifier) {
                    result.found[identifier] = reference
                } else {
                    result.unknown.insert(identifier)
                }
            }

            // Aliases the errors blame, split by *why*. `path` says which field failed; it
            // says nothing about the cause, and the difference decides whether the answer
            // is cacheable. "No such issue" is a fact that will hold tomorrow. A permission
            // failure or a resolver error is not: caching one as `unknown` would strip a
            // real ticket's project heading for a day over a transient fault.
            //
            // A field that both errored and came back is trusted as answered — Linear
            // attaches warnings to results that did arrive.
            var notFound: Set<String> = []
            var failed: Set<String> = []
            for error in response.errors {
                guard let alias = error.path?.first,
                      let identifier = batch.identifiers[alias],
                      !answered.contains(identifier) else { continue }
                if isNotFound(error) {
                    notFound.insert(identifier)
                } else {
                    failed.insert(identifier)
                }
            }
            result.unknown.formUnion(notFound)
            result.unresolved.formUnion(failed)
            result.errors.append(contentsOf: response.errors)

            // Both kinds are settled for *this* poll: neither would answer differently on
            // an immediate retry. The unresolved ones are asked again next poll, because
            // nothing was cached about them.
            let settled = answered.union(notFound).union(failed)
            pending = pending.filter { !settled.contains($0) }

            attempt += 1
            if pending.isEmpty { break }
            if attempt > 1 || settled.isEmpty {
                // Either the retry has been spent, or the response settled nothing and a
                // retry would send the identical request. Leave the rest unresolved: no
                // answer is a worse thing to cache than a wrong one.
                result.unresolved.formUnion(pending)
                break
            }
        }

        return result
    }

    private func makeReference(from issue: IssueDTO, requested: String) -> IssueRef? {
        // Linear's own spelling wins when it sends one — it is canonical, and the scan's
        // upper-casing of a lower-case branch segment is a guess until it is confirmed.
        // The *key* stays the requested identifier throughout, because that is what the
        // cache and the pull request's ordered list are keyed by.
        let identifier = issue.identifier.flatMap { $0.isEmpty ? nil : $0 } ?? requested
        return IssueRef(
            identifier: identifier,
            url: issue.url.flatMap(URL.init(string:)),
            projectID: issue.project?.id,
            projectName: issue.project?.name
        )
    }

    private struct BatchResponse {
        var payload: IssueBatchPayload?
        var errors: [GraphQLError]
    }

    private func perform(_ batch: IssueBatchQuery.Batch) async throws -> BatchResponse {
        let key = try LinearAPI.key(from: tokenProvider)
        let headers = try LinearAPI.headers(key: key, for: configuration.endpoint)
        let body = try GraphQLRequestBody(query: batch.text, variables: batch.variables).encoded()

        let response = try await LinearAPI.send(
            HTTPRequest(method: "POST", url: configuration.endpoint, headers: headers, body: body),
            over: transport
        )
        guard response.isSuccess else { throw LinearAPI.error(for: response) }

        let decoder = JSONDecoder()
        // Errors first and independently of `data` — the shape this client most has to
        // survive is exactly the one where `data` is null and the reason is in `errors`.
        let errors = GraphQLErrorsOnly.read(response.body, decoder: decoder)

        // An authentication failure arrives as a 200 with an `errors` array on some Linear
        // deployments and as a 401 on others. Both have to raise the reconnect banner
        // rather than being counted as forty unknown identifiers, which is what treating
        // this as an ordinary partial failure would do.
        if let authentication = errors.first(where: { isAuthentication($0) }) {
            throw LinearError.unauthorized(authentication.description)
        }

        let envelope: GraphQLEnvelope<IssueBatchPayload>
        do {
            envelope = try decoder.decode(GraphQLEnvelope<IssueBatchPayload>.self, from: response.body)
        } catch {
            throw errors.isEmpty
                ? LinearError.malformedResponse(String(describing: error))
                : LinearError.graphQL(errors)
        }
        if envelope.data == nil && errors.isEmpty {
            throw LinearError.malformedResponse("response carried neither data nor errors")
        }
        return BatchResponse(payload: envelope.data, errors: errors)
    }

    /// Whether this error means "there is no such issue" as opposed to "I could not answer".
    ///
    /// Linear reports the first as an `ENTITY_NOT_FOUND` extension code, a `not_found`
    /// type, or an "Entity not found" message, depending on which of those the response
    /// carries. All three are matched, and **nothing else is**: the default is the
    /// conservative one. An unrecognised failure becomes `unresolved` and is asked again
    /// next poll, which costs a request; misreading it as `unknown` would cache a wrong
    /// answer and cost a row its project heading until the entry expired.
    private func isNotFound(_ error: GraphQLError) -> Bool {
        if let code = error.code?.uppercased(), code.contains("NOT_FOUND") { return true }
        if let type = error.type?.uppercased(), type.contains("NOT_FOUND") { return true }
        return error.message.range(of: "entity not found", options: .caseInsensitive) != nil
    }

    private func isAuthentication(_ error: GraphQLError) -> Bool {
        if let type = error.type?.uppercased(),
           type.contains("AUTHENTICATION") || type == "FORBIDDEN" {
            return true
        }
        return error.message.range(of: "authentication", options: .caseInsensitive) != nil
    }

    private func chunks(_ identifiers: [String]) -> [[String]] {
        stride(from: 0, to: identifiers.count, by: configuration.batchSize).map { start in
            Array(identifiers[start..<min(start + configuration.batchSize, identifiers.count)])
        }
    }
}
