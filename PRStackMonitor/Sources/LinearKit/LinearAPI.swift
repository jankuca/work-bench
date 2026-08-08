import Foundation
import NetKit

/// Endpoint, headers and the credential path for Linear's GraphQL API.
public enum LinearAPI {
    public static let endpoint = URL(string: "https://api.linear.app/graphql")!

    /// Linear rejects requests without one, same as GitHub.
    public static let userAgent = "PRStackMonitor/1.0 (+https://github.com/jankuca/work-bench)"

    /// Where the dump tool and CI look for a key, in order.
    public static let keyEnvironmentNames = ["PRSTACK_LINEAR_KEY", "LINEAR_API_KEY"]

    /// The headers for a credentialed request to `url`.
    ///
    /// A **personal API key** goes in `Authorization` bare, with no `Bearer` prefix — that
    /// prefix is for OAuth access tokens, and sending it with a personal key is answered
    /// with an authentication error. Keys start with `lin_api_`; anything else is assumed
    /// to be an OAuth token and does get the prefix, so both credential types work through
    /// the same seam if Settings ever offers OAuth.
    ///
    /// Throws rather than returns for the same reason GitHub's does: the endpoint is
    /// configurable, and a key put on the wire in cleartext is disclosed the moment it is
    /// sent. Checking at the one place credentials are attached covers every caller.
    static func headers(key: String, for url: URL) throws -> [String: String] {
        guard url.scheme?.lowercased() == "https" else {
            throw LinearError.insecureEndpoint(url)
        }
        return [
            "Authorization": key.hasPrefix("lin_api_") ? key : "Bearer \(key)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": userAgent
        ]
    }

    /// Reads a credential, translating "nothing configured" into the state the panel shows
    /// the connect prompt for.
    static func key(from provider: any TokenProvider) throws -> String {
        do {
            return try provider.token()
        } catch is MissingCredential {
            throw LinearError.missingKey
        }
    }

    /// Sends `request`, translating a transport failure into a ``LinearError``.
    ///
    /// Cancellation is rethrown untouched — a poll cancelled by the panel closing is not a
    /// Linear outage, and marking the source stale for the user's own click would be a
    /// lie the footer then has to carry.
    static func send(_ request: HTTPRequest, over transport: any HTTPTransport) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as LinearError {
            throw error
        } catch where Cancellation.matches(error) {
            throw error
        } catch {
            throw LinearError.transport(String(describing: error))
        }
    }

    /// Turns a non-success response into the error the sync layer switches on.
    ///
    /// The distinction that matters is the same one GitHub's makes — authentication versus
    /// everything else — with one difference in what it costs: an expired Linear key never
    /// raises the dashed menu bar glyph, because the panel's contents do not depend on
    /// Linear (IMPLEMENTATION_PLAN §4). It shows a banner over rows that keep their cached
    /// project headings.
    static func error(for response: HTTPResponse, now: Date = Date()) -> LinearError {
        let message = summarise(response.body)
        switch response.status {
        case 401, 403:
            return .unauthorized(message)
        case 429:
            let retryAfter = response.header("retry-after")
                .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { now.addingTimeInterval($0) }
            return .rateLimited(resetAt: retryAfter)
        default:
            return .http(status: response.status, message: message)
        }
    }

    /// Linear's error bodies are JSON with either a top-level `message` or the GraphQL
    /// `errors` array; anything else is echoed back truncated so a stray HTML error page
    /// cannot flood a log line.
    private static func summarise(_ body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let errors = object["errors"] as? [[String: Any]] {
                let messages = errors.compactMap { $0["message"] as? String }
                if !messages.isEmpty { return messages.joined(separator: "; ") }
            }
        }
        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return "no response body" }
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}

extension EnvironmentTokenProvider {
    /// `$PRSTACK_LINEAR_KEY`, then `$LINEAR_API_KEY`.
    public static func linear(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EnvironmentTokenProvider {
        EnvironmentTokenProvider(
            names: LinearAPI.keyEnvironmentNames,
            service: "Linear",
            environment: environment
        )
    }
}
