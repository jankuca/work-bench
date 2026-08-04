import Foundation

/// One error returned in a GraphQL response's `errors` array.
///
/// GitHub answers `200` with a partly-filled `data` and a populated `errors` for a
/// surprising number of conditions, so these have to survive as far as the caller rather
/// than being flattened into a generic failure.
public struct GraphQLError: Decodable, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// GitHub's own classification — `RATE_LIMITED`, `NOT_FOUND`, `FORBIDDEN`, …
    public var type: String?

    public init(message: String, type: String? = nil) {
        self.message = message
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case type
    }

    public var description: String {
        guard let type else { return message }
        return "\(type): \(message)"
    }
}

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
}

extension GitHubError: LocalizedError {
    public var errorDescription: String? { description }
}
