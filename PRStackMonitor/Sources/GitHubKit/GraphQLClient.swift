import Foundation

/// A GraphQL variable value.
///
/// `[String: Any]` would encode with `JSONSerialization` just as well, but it makes the
/// variable set untypeable and unassertable in tests. This is the whole JSON value space
/// and nothing more.
public enum GraphQLValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case list([GraphQLValue])
    case object([String: GraphQLValue])
}

extension GraphQLValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .list(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}

/// A successful GraphQL response.
///
/// `errors` is carried alongside `data` rather than thrown, because GitHub routinely
/// answers `200` with both: one inaccessible repository in a search does not invalidate
/// the other forty results. The caller decides — the fetch turns them into warnings the
/// footer can show, and only a wholly absent `data` is an error.
public struct GraphQLResult<Value>: Equatable where Value: Equatable {
    public var data: Value
    public var errors: [GraphQLError]

    public init(data: Value, errors: [GraphQLError] = []) {
        self.data = data
        self.errors = errors
    }
}

public struct GraphQLClient {
    private let transport: any HTTPTransport
    private let tokenProvider: any TokenProvider
    private let endpoint: URL

    public init(
        transport: any HTTPTransport,
        tokenProvider: any TokenProvider,
        endpoint: URL = GitHubAPI.graphQLEndpoint
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.endpoint = endpoint
    }

    public func perform<Value: Decodable & Equatable>(
        query: String,
        variables: [String: GraphQLValue] = [:]
    ) async throws -> GraphQLResult<Value> {
        let token = try tokenProvider.token()

        var headers = try GitHubAPI.headers(token: token, accept: "application/json", for: endpoint)
        headers["Content-Type"] = "application/json"

        let body = try JSONEncoder().encode(RequestBody(query: query, variables: variables))
        let response = try await transport.send(
            HTTPRequest(method: "POST", url: endpoint, headers: headers, body: body)
        )

        guard response.isSuccess else { throw GitHubAPI.error(for: response) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Errors are read *before* and independently of `data`, and this ordering is
        // load-bearing. When a resolver fails, GitHub answers 200 with a `data` shaped
        // unlike the query's own result type and the reason in `errors`. Decoding the
        // envelope first would make that a `malformedResponse` and discard the reason —
        // including a RATE_LIMITED that the scheduler has to see.
        let errors = (try? decoder.decode(ErrorsOnly.self, from: response.body))?.errors ?? []

        // GitHub reports an exhausted allowance as a 200 carrying a RATE_LIMITED error, not
        // as a 403. Treating it as an ordinary GraphQL error would let the scheduler keep
        // polling straight into the wall.
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            // A reset time matters here: it is what the scheduler backs off *until*, and
            // without one the footer can only say "resets at unknown". The same response
            // usually still carries `data.rateLimit.resetAt`, and the headers carry
            // `x-ratelimit-reset` as a second chance.
            throw GitHubError.rateLimited(
                resetAt: GraphQLClient.reportedReset(in: response, decoder: decoder)
            )
        }

        let envelope: Envelope<Value>
        do {
            envelope = try decoder.decode(Envelope<Value>.self, from: response.body)
        } catch {
            throw errors.isEmpty
                ? GitHubError.malformedResponse(String(describing: error))
                : GitHubError.graphQL(errors)
        }
        guard let data = envelope.data else {
            throw errors.isEmpty
                ? GitHubError.malformedResponse("response carried neither data nor errors")
                : GitHubError.graphQL(errors)
        }
        return GraphQLResult(data: data, errors: errors)
    }

    /// The `errors` array alone, decodable from any response regardless of what `data`
    /// holds.
    private struct ErrorsOnly: Decodable {
        var errors: [GraphQLError]?
    }

    /// Reads only `data.rateLimit.resetAt`, so it decodes a response whose `data` is
    /// otherwise unusable — which is exactly the shape a rate-limited answer has.
    private struct RateLimitProbe: Decodable {
        struct Payload: Decodable {
            struct Limit: Decodable {
                var resetAt: Date?
            }
            var rateLimit: Limit?
        }
        var data: Payload?
    }

    private static func reportedReset(in response: HTTPResponse, decoder: JSONDecoder) -> Date? {
        if let probe = try? decoder.decode(RateLimitProbe.self, from: response.body),
           let resetAt = probe.data?.rateLimit?.resetAt {
            return resetAt
        }
        return RESTRateLimit.from(response)?.resetAt
    }

    private struct RequestBody: Encodable {
        var query: String
        var variables: [String: GraphQLValue]
    }

    private struct Envelope<Value: Decodable>: Decodable {
        var data: Value?
        var errors: [GraphQLError]?
    }
}
