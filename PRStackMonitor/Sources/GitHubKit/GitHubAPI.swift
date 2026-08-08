import Foundation
import NetKit

/// Endpoints and the header set both clients share.
public enum GitHubAPI {
    public static let graphQLEndpoint = URL(string: "https://api.github.com/graphql")!
    public static let restBaseURL = URL(string: "https://api.github.com")!

    /// Where the dump tool and CI look for a token, in order.
    public static let tokenEnvironmentNames = ["PRSTACK_GITHUB_TOKEN", "GITHUB_TOKEN"]

    /// GitHub rejects requests without one, so it is not optional decoration.
    public static let userAgent = "PRStackMonitor/1.0 (+https://github.com/jankuca/work-bench)"

    /// Pins the REST media type. GraphQL ignores it and takes `application/json`.
    public static let restAccept = "application/vnd.github+json"
    public static let apiVersion = "2022-11-28"

    /// The headers for a credentialed request to `url`.
    ///
    /// Throws rather than returns for one reason: the endpoint is configurable
    /// (``GitHubClient/Configuration/endpoint``, ``RESTClient``'s `baseURL`), and a token
    /// put on the wire in cleartext is disclosed the moment it is sent — there is no
    /// recovering from it afterwards. Checking here, at the one place credentials are
    /// attached, covers every caller rather than every call site.
    static func headers(token: String, accept: String, for url: URL) throws -> [String: String] {
        guard url.scheme?.lowercased() == "https" else {
            throw GitHubError.insecureEndpoint(url)
        }
        return [
            "Authorization": "Bearer \(token)",
            "Accept": accept,
            "User-Agent": userAgent,
            "X-GitHub-Api-Version": apiVersion
        ]
    }

    /// Turns a non-success response into the error the sync layer switches on.
    ///
    /// The distinction that matters is authentication versus everything else: only the
    /// first raises the reconnect banner and the dashed glyph, and only the rest are worth
    /// retrying with backoff (IMPLEMENTATION_PLAN §4). `now` is injected so the
    /// `Retry-After` arithmetic is testable.
    static func error(for response: HTTPResponse, now: Date = Date()) -> GitHubError {
        let message = summarise(response.body)
        switch response.status {
        case 401:
            return .unauthorized(message)
        case 403, 429:
            // A 403 is GitHub's answer to a bad token, to a spent hourly allowance, *and*
            // to a secondary rate limit. Only the first is an authentication failure, and
            // getting that wrong is expensive: it raises the reconnect banner and the
            // dashed glyph for what is a few seconds of throttling.
            //
            // The primary limit is the one that reports itself in the remaining count.
            if let remaining = response.header("x-ratelimit-remaining").flatMap(Int.init), remaining <= 0 {
                let reset = response.header("x-ratelimit-reset")
                    .flatMap(Double.init)
                    .map { Date(timeIntervalSince1970: $0) }
                return .rateLimited(resetAt: reset)
            }
            // A secondary limit leaves the hourly allowance intact and announces itself
            // with `Retry-After` and/or the documented phrase in the body.
            //
            // The header's *presence* is the signal, not its parseability. `Retry-After` is
            // delta-seconds or an HTTP-date (RFC 9110 §10.2.3), and reading it as a Double
            // only recognises the first — so a date-form header would fall through to
            // `.unauthorized` and raise the reconnect banner for a throttle. The delta,
            // when there is one, only refines the answer into a resume time.
            if let retryAfter = response.header("retry-after") {
                let delta = Double(retryAfter.trimmingCharacters(in: .whitespaces))
                return .rateLimited(resetAt: delta.map { now.addingTimeInterval($0) })
            }
            if response.status == 429
                || message.range(of: "secondary rate limit", options: .caseInsensitive) != nil {
                return .rateLimited(resetAt: nil)
            }
            return .unauthorized(message)
        default:
            return .http(status: response.status, message: message)
        }
    }

    /// Reads a credential, translating "nothing configured" into the error the panel
    /// shows the connect prompt for. Every credentialed call goes through here.
    static func token(from provider: any TokenProvider) throws -> String {
        do {
            return try provider.token()
        } catch is MissingCredential {
            throw GitHubError.missingToken
        }
    }

    /// Sends `request`, translating a transport failure into a ``GitHubError`` so callers
    /// of this package only ever have one error family to switch over.
    ///
    /// Cancellation is rethrown untouched: a poll cancelled by the panel closing is not a
    /// connection failure, and the caller distinguishes the two (`PollOutcome.cancelled`).
    static func send(_ request: HTTPRequest, over transport: any HTTPTransport) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as GitHubError {
            throw error
        } catch where Cancellation.matches(error) {
            throw error
        } catch {
            throw GitHubError.transport(String(describing: error))
        }
    }

    /// GitHub's error bodies are JSON with a `message`; anything else is echoed back
    /// truncated so a stray HTML error page cannot flood a log line.
    private static func summarise(_ body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }
        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return "no response body" }
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}

extension EnvironmentTokenProvider {
    /// `$PRSTACK_GITHUB_TOKEN`, then `$GITHUB_TOKEN`.
    public static func github(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EnvironmentTokenProvider {
        EnvironmentTokenProvider(
            names: GitHubAPI.tokenEnvironmentNames,
            service: "GitHub",
            environment: environment
        )
    }
}

/// Conditional GETs against the REST API.
///
/// Nothing in M2 calls this — the pull request ingestion is entirely GraphQL. It lands
/// here because the milestone puts ETag handling in M2 and because M6's release tracking
/// is built on exactly one REST call, `compare/{tag}...{sha}`, repeated across polls for
/// the same pairs. Having the conditional path already tested is what keeps that
/// milestone's request budget honest.
public struct RESTClient {
    private let transport: any HTTPTransport
    private let tokenProvider: any TokenProvider
    private let baseURL: URL
    private let etags: any ETagStore

    public init(
        transport: any HTTPTransport,
        tokenProvider: any TokenProvider,
        baseURL: URL = GitHubAPI.restBaseURL,
        etagStore: any ETagStore = InMemoryETagStore()
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.baseURL = baseURL
        self.etags = etagStore
    }

    /// `GET path`, sending `If-None-Match` when this path has been fetched before.
    public func get(path: String, queryItems: [URLQueryItem] = []) async throws -> RESTResult {
        let token = try GitHubAPI.token(from: tokenProvider)
        let url = try makeURL(path: path, queryItems: queryItems)
        let key = url.absoluteString

        var headers = try GitHubAPI.headers(token: token, accept: GitHubAPI.restAccept, for: url)
        if let etag = etags.etag(for: key) {
            headers["If-None-Match"] = etag
        }

        let response = try await GitHubAPI.send(
            HTTPRequest(method: "GET", url: url, headers: headers),
            over: transport
        )
        let limit = RESTRateLimit.from(response)

        if response.isNotModified {
            return RESTResult(payload: .unchanged, rateLimit: limit)
        }
        guard response.isSuccess else {
            // Drop the stored validator: a 401 or a 404 means the cached body is no longer
            // something we can claim is current, and keeping the ETag would make the next
            // successful request answer 304 against a body we never received.
            etags.setETag(nil, for: key)
            throw GitHubAPI.error(for: response)
        }

        etags.setETag(response.header("etag"), for: key)
        return RESTResult(payload: .changed(response.body), rateLimit: limit)
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(trimmed),
            resolvingAgainstBaseURL: false
        ) else {
            throw GitHubError.malformedResponse("cannot build a URL for '\(path)'")
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else {
            throw GitHubError.malformedResponse("cannot build a URL for '\(path)'")
        }
        return url
    }
}
