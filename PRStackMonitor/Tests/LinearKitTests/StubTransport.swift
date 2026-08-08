import Foundation
import NetKit
import XCTest

/// The whole network, for the duration of a test.
///
/// A near-twin of `GitHubKitTests`' stub, kept separate rather than shared. SwiftPM would
/// need a third library target to share it, and the two diverge where it matters — this
/// one reads GraphQL aliases back out of a request body, which is the thing every test
/// here asserts about.
///
/// Unsynchronised on purpose: `LinearClient` awaits each batch before building the next
/// and XCTest runs one test method at a time, so there is exactly one consumer and a lock
/// would guard nothing.
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

    static func always(_ response: HTTPResponse) -> StubTransport {
        StubTransport(Array(repeating: .respond(response), count: 16))
    }

    var remainingSteps: Int { steps.count }
    var requestCount: Int { requests.count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else {
            // A hang would be the alternative, and "the client sent one request more than
            // the test planned for" deserves to read as a failure rather than a timeout.
            throw StubFailure.exhausted(after: requests.count)
        }
        switch steps.removeFirst() {
        case .respond(let response): return response
        case .fail(let error): throw error
        }
    }

    enum StubFailure: Error, CustomStringConvertible {
        case exhausted(after: Int)

        var description: String {
            switch self {
            case .exhausted(let count):
                return "the stub ran out of responses on request \(count)"
            }
        }
    }

    // MARK: - Reading requests back

    func body(_ index: Int) throws -> [String: Any] {
        let request = try XCTUnwrap(requests.indices.contains(index) ? requests[index] : nil)
        let data = try XCTUnwrap(request.body)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func query(_ index: Int) throws -> String {
        try XCTUnwrap(try body(index)["query"] as? String)
    }

    func variables(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(try body(index)["variables"] as? [String: Any])
    }

    /// The identifiers a request asked for, in alias order — `a0`, `a1`, …
    func requestedIdentifiers(_ index: Int) throws -> [String] {
        let variables = try variables(index)
        return (0..<variables.count).compactMap { variables["a\($0)"] as? String }
    }
}

extension HTTPResponse {
    static func json(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }
}
