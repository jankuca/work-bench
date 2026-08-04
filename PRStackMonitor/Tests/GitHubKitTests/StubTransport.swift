import Foundation
import XCTest
@testable import GitHubKit

/// The whole network, for the duration of a test.
///
/// Responses are consumed in order; every request is recorded so a test can assert what
/// went out as well as what came back. Running out of responses fails the test rather
/// than hanging, which is what turns "the client paginated one page too many" into a
/// readable failure.
///
/// Unsynchronised on purpose. `GitHubClient` awaits each page before asking for the next
/// and XCTest runs one test method at a time, so there is exactly one consumer and a lock
/// would guard nothing — while `NSLock` across an `async` boundary is a hard error in the
/// Swift 6 language mode. If a future test ever drives this concurrently, make it an
/// `actor` rather than adding a lock back.
final class StubTransport: HTTPTransport {
    enum Step {
        case respond(HTTPResponse)
        case fail(any Error)
    }

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

    var remainingSteps: Int { steps.count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw Unexpected(request: request) }

        switch steps.removeFirst() {
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
