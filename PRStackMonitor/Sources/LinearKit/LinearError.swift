import Foundation
import NetKit

public enum LinearError: Error, Equatable, CustomStringConvertible {
    /// No API key configured at all — the first-run state, not a failure to authenticate.
    case missingKey
    /// `401`, or a `403`. Per IMPLEMENTATION_PLAN §4 this marks *only* Linear
    /// disconnected; every GitHub row keeps rendering.
    case unauthorized(String)
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
        case .missingKey:
            return "no Linear API key configured"
        case .unauthorized(let detail):
            return "Linear rejected the API key: \(detail)"
        case .rateLimited(let resetAt):
            let when = resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
            return "Linear rate limit exhausted; resets at \(when)"
        case .http(let status, let message):
            return "Linear returned HTTP \(status): \(message)"
        case .transport(let detail):
            return "could not reach Linear: \(detail)"
        case .insecureEndpoint(let url):
            return "refusing to send a Linear API key to '\(url.absoluteString)': the endpoint must be https"
        case .graphQL(let errors):
            return "Linear returned errors: " + errors.map(\.description).joined(separator: "; ")
        case .malformedResponse(let detail):
            return "could not read Linear's response: \(detail)"
        }
    }

    /// Whether this is the condition the user has to fix, as opposed to a transient
    /// failure that backoff should retry.
    public var isAuthenticationFailure: Bool {
        switch self {
        case .missingKey, .unauthorized: return true
        default: return false
        }
    }
}

extension LinearError: LocalizedError {
    public var errorDescription: String? { description }
}
