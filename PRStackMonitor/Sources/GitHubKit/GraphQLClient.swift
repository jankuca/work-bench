import Foundation
import NetKit

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
        let token = try GitHubAPI.token(from: tokenProvider)

        var headers = try GitHubAPI.headers(token: token, accept: "application/json", for: endpoint)
        headers["Content-Type"] = "application/json"

        let body = try GraphQLRequestBody(query: query, variables: variables).encoded()
        let response = try await GitHubAPI.send(
            HTTPRequest(method: "POST", url: endpoint, headers: headers, body: body),
            over: transport
        )

        guard response.isSuccess else { throw GitHubAPI.error(for: response) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Errors are read *before* and independently of `data` — see ``GraphQLErrorsOnly``
        // for why that ordering is load-bearing.
        let errors = GraphQLErrorsOnly.read(response.body, decoder: decoder)

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

        let envelope: GraphQLEnvelope<Value>
        do {
            envelope = try decoder.decode(GraphQLEnvelope<Value>.self, from: response.body)
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
}
