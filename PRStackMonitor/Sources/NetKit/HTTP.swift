import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One outbound request, expressed in types this package owns.
///
/// `URLRequest` would do the job on Apple platforms, but it lives in `FoundationNetworking`
/// on Linux and drags the whole networking module into every test that only wants to
/// assert what was sent. A plain struct keeps the seam — and the tests — portable.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    /// Header names are matched case-insensitively by ``header(_:)``; the casing here is
    /// what goes on the wire.
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        HTTPRequest.value(for: name, in: headers)
    }

    public mutating func setHeader(_ name: String, _ value: String?) {
        headers = headers.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
        if let value { headers[name] = value }
    }

    static func value(for name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// HTTP header names are case-insensitive, and the two `URLSession` implementations
    /// disagree about the casing they hand back, so every read goes through here.
    public func header(_ name: String) -> String? {
        HTTPRequest.value(for: name, in: headers)
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var isNotModified: Bool { status == 304 }
}

/// The one seam between this package and the network.
///
/// IMPLEMENTATION_PLAN §6 calls for a `URLProtocol` stub. That works on Apple platforms
/// but `URLProtocol` registration is not dependable in swift-corelibs-foundation, and
/// these modules exist precisely so CI can exercise them in a Linux container. A protocol
/// the tests implement directly gives the same guarantee — no test touches the network —
/// without betting the suite on a platform difference.
public protocol HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// A failure below the level any one API knows about.
///
/// Each service kit wraps these into its own error type, so nothing above `GitHubKit` or
/// `LinearKit` has to switch over two error families to find out that the network is down.
public enum TransportError: Error, Equatable, CustomStringConvertible {
    case noResponse
    case notHTTP(String)

    public var description: String {
        switch self {
        case .noResponse: return "the request completed with no response and no error"
        case .notHTTP(let kind): return "expected an HTTP response, got \(kind)"
        }
    }
}

extension TransportError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Whether an error is this task being cancelled rather than something going wrong.
///
/// Cancellation reaches a caller in two shapes: `CancellationError` when the suspension
/// point itself was cancelled, and `URLError.cancelled` when the in-flight `URLSession`
/// task was. Both have to survive the wrapping each service kit does — a poll cancelled by
/// the panel closing is not a connection failure, and reporting it as one would raise a
/// footer warning for the user's own click.
public enum Cancellation {
    public static func matches(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

/// Holds the in-flight data task so the cancellation handler can reach it.
///
/// `onCancel` runs in a different isolation domain from the closure that creates the task,
/// and it can run *before* it — hence the flag as well as the reference, so a cancellation
/// that arrives first is not lost. The lock never spans a suspension point, which is what
/// keeps it legal in an async context.
private final class DataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false

    func store(_ task: URLSessionDataTask) {
        lock.lock()
        let cancelled = isCancelled
        if !cancelled { self.task = task }
        lock.unlock()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// The production transport.
///
/// `@unchecked Sendable` because `URLSession` is documented as safe to use from multiple
/// threads and this holds nothing else. That matters for more than tidiness: Apple's own
/// guidance is to **reuse** a session rather than create one per request, since each new
/// session brings its own connection pool that outlives it. Being `Sendable` is what lets
/// a caller hold one transport for the life of the app instead of building one per poll.
public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Configured rather than `.shared`: GitHub's own guidance is one connection at a
    /// time per token, and a poll that outlives its interval is worse than a poll that
    /// fails.
    public static func standard(timeout: TimeInterval = 30) -> URLSessionTransport {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpMaximumConnectionsPerHost = 2
        // The app does its own conditional requests with stored ETags (see ``ETagStore``),
        // so the URL cache would only duplicate that bookkeeping less precisely.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        // Hand-rolled rather than `session.data(for:)`: the async overload is not uniformly
        // available across the Foundation implementations this package builds against, and
        // the continuation is the same handful of lines.
        //
        // The cancellation handler is not optional decoration. A bare continuation does not
        // observe `Task` cancellation, so a poll cancelled on sleep (M8) would leave its
        // request in flight and only resume when the 30-second timeout expired.
        let inFlight = DataTaskBox()
        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Data, URLResponse), any Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: TransportError.noResponse)
                    }
                }
                inFlight.store(task)
                task.resume()
            }
        } onCancel: {
            inFlight.cancel()
        }

        guard let http = response as? HTTPURLResponse else {
            throw TransportError.notHTTP(String(describing: type(of: response)))
        }

        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name] = String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
