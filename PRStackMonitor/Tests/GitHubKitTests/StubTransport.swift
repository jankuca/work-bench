import Foundation
import XCTest
@testable import GitHubKit

/// The whole network, for the duration of a test.
///
/// Responses are consumed in order; every request is recorded so a test can assert what
/// went out as well as what came back. Running out of responses fails the test rather
/// than hanging, which is what turns "the client paginated one page too many" into a
/// readable failure.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum Step {
        case respond(HTTPResponse)
        case fail(any Error)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [HTTPRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    convenience init(responses: [HTTPResponse]) {
        self.init(responses.map(Step.respond))
    }

    /// The same response for every request. Used where a test is asserting the request,
    /// not the reply.
    static func always(_ response: HTTPResponse) -> StubTransport {
        StubTransport(Array(repeating: .respond(response), count: 64))
    }

    var remainingSteps: Int {
        lock.lock()
        defer { lock.unlock() }
        return steps.count
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        requests.append(request)
        guard !steps.isEmpty else {
            lock.unlock()
            throw Unexpected(request: request)
        }
        let step = steps.removeFirst()
        lock.unlock()

        switch step {
        case .respond(let response): return response
        case .fail(let error): throw error
        }
    }

    struct Unexpected: Error, CustomStringConvertible {
        var request: HTTPRequest
        var description: String {
            "the client made an unexpected \(request.method) to \(request.url)"
        }
    }

    /// The JSON body of the `index`-th request, as a dictionary.
    func requestBody(_ index: Int) throws -> [String: Any] {
        let body = try XCTUnwrap(requests[index].body, "request \(index) had no body")
        let object = try JSONSerialization.jsonObject(with: body)
        return try XCTUnwrap(object as? [String: Any], "request \(index) was not a JSON object")
    }

    /// The GraphQL `variables` of the `index`-th request.
    func requestVariables(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(requestBody(index)["variables"] as? [String: Any])
    }
}

extension HTTPResponse {
    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        var all = ["Content-Type": "application/json"]
        all.merge(headers) { _, new in new }
        return HTTPResponse(status: status, headers: all, body: Data(text.utf8))
    }
}
