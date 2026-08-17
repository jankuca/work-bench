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
        default:
            return false
        }
    }
}

extension GitHubError: LocalizedError {
    public var errorDescription: String? { description }
}
