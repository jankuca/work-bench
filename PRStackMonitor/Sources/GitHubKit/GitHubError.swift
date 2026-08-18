import Foundation
import NetKit

public enum GitHubError: Error, Equatable, CustomStringConvertible {
    /// No token configured at all — the first-run state, not a failure to authenticate.
    case missingToken
    /// `401`, or a `403` GitHub attributes to bad credentials. Per IMPLEMENTATION_PLAN §4
    /// this marks *only* GitHub disconnected; Linear is unaffected.
    case unauthorized(String)
    /// The budget is spent on GitHub's side, not ours. `resetAt` is when it returns.
    case rateLimited(resetAt: Date?)
    case http(status: Int, message: String)
    case transport(String)
    /// A configured endpoint that credentials must not be sent to. Not a server failure —
    /// the request is refused before it is made.
    case insecureEndpoint(URL)
    /// A `200` whose `data` never arrived.
    case graphQL([GraphQLError])
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .missingToken:
            return "no GitHub token configured"
        case .unauthorized(let detail):
            return "GitHub rejected the token: \(detail)"
        case .rateLimited(let resetAt):
            let when = resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
            return "GitHub rate limit exhausted; resets at \(when)"
        case .http(let status, let message):
            return "GitHub returned HTTP \(status): \(message)"
        case .transport(let detail):
            return "could not reach GitHub: \(detail)"
        case .insecureEndpoint(let url):
            return "refusing to send a GitHub token to '\(url.absoluteString)': the endpoint must be https"
        case .graphQL(let errors):
            return "GitHub returned errors: " + errors.map(\.description).joined(separator: "; ")
        case .malformedResponse(let detail):
            return "could not read GitHub's response: \(detail)"
        }
    }

    /// Whether this is the condition that raises the reconnect banner and the dashed menu
    /// bar glyph, as opposed to a transient failure that backoff should retry.
    public var isAuthenticationFailure: Bool {
        switch self {
        case .missingToken, .unauthorized: return true
        default: return false
        }
    }

    /// Whether GitHub failed to *produce* an answer, as opposed to refusing to give one.
    ///
    /// These are the two shapes of "ask again, smaller". GitHub's GraphQL resolver answers
    /// `502` or `504` when a selection takes too long to compute — which is what a page of
    /// 50 pull requests, each with its reviews, its review requests and 20 check contexts,
    /// does on an account with hundreds of them — and a request over a poor connection
    /// stalls out into ``transport`` instead. Both describe *this request*, not the
    /// credential and not the allowance, so both are worth another attempt at a fraction of
    /// the size (``GitHubClient/Configuration/pageRetries``).
    ///
    /// ``rateLimited`` is deliberately not here even though it is every bit as transient: it
    /// is the one failure where asking again sooner is wrong at any size, and the scheduler
    /// already holds the whole poll off until the allowance returns.
    public var isServerSideFailure: Bool {
        switch self {
        case .http(let status, _):
            return status == 500 || status == 502 || status == 503 || status == 504
        case .transport:
            return true
        case .graphQL(let errors):
            // The same failure wearing a `200`. GitHub answers a resolver that ran out of
            // time with a success status, a null connection and the reason in `errors` —
            // which is *more* common on a heavy page than an actual 504, and reads as an
            // empty answer rather than as a failure unless somebody looks at the errors.
            return errors.contains { $0.isExecutionFailure }
        default:
            return false
        }
    }
}

extension GraphQLError {
    /// Whether GitHub is saying it could not *run* the query, rather than refusing part of
    /// what the query asked for.
    ///
    /// The distinction decides whether asking again can help. `FORBIDDEN` on a repository the
    /// token cannot see, `NOT_FOUND` for one that has been renamed — those are answers, and
    /// they are the same answer however many times they are asked for, at any page size. An
    /// execution failure is GitHub giving up on the work, and half the page is a different
    /// question.
    ///
    /// Classification is by absence of a `type`/`code` *and* the sentence GitHub sends,
    /// because that is all it sends: the timeout arrives as an unclassified error reading
    /// "Something went wrong while executing your query. This may be the result of a timeout".
    /// Matching on a message is unlovely and the alternative is worse — treating every
    /// unclassified error as retryable would retry the ones that never come good.
    public var isExecutionFailure: Bool {
        guard type == nil, code == nil else { return false }
        let text = message.lowercased()
        return text.contains("something went wrong while executing your query")
            || text.contains("timeout")
            || text.contains("timed out")
    }
}

extension GitHubError: LocalizedError {
    public var errorDescription: String? { description }
}
