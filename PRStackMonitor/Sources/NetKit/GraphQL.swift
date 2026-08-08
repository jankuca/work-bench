import Foundation

// The parts of GraphQL that are the same wherever it is spoken: the variable value space,
// the error shape, and the `{ data, errors }` envelope. Both `GitHubKit` and `LinearKit`
// POST a query string and decode that envelope; what they do *not* share is the policy
// around it — GitHub meters points and answers `200` with a `RATE_LIMITED` error, Linear
// nulls individual aliases for issues that do not exist. So the scaffolding is here and
// each client keeps its own error handling.

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

/// One error returned in a GraphQL response's `errors` array.
///
/// Servers answer `200` with a partly-filled `data` and a populated `errors` for a
/// surprising number of conditions, so these have to survive as far as the caller rather
/// than being flattened into a generic failure.
public struct GraphQLError: Decodable, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// The server's own classification — GitHub's `RATE_LIMITED`, `NOT_FOUND`,
    /// `FORBIDDEN`; Linear's `AUTHENTICATION_ERROR`. Absent from plenty of responses.
    public var type: String?
    /// Which field failed, as response-key components from the root: `["a3"]`,
    /// `["search", "nodes", "2"]`.
    ///
    /// This is the only thing that makes a batched query recoverable. When one aliased
    /// field of forty fails, the path is what says *which* — so the batch can be retried
    /// without it instead of being abandoned whole. List indices arrive as numbers and are
    /// flattened to their decimal spelling, because nothing here needs to tell an index
    /// from a field named `0`.
    public var path: [String]?

    public init(message: String, type: String? = nil, path: [String]? = nil) {
        self.message = message
        self.type = type
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case type
        case path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type)
        path = try container.decodeIfPresent([PathComponent].self, forKey: .path)?.map(\.text)
    }

    /// A path component is a field name or a list index, so the array is heterogeneous.
    private struct PathComponent: Decodable {
        var text: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let name = try? container.decode(String.self) {
                text = name
            } else if let index = try? container.decode(Int.self) {
                text = String(index)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "a GraphQL error path component is neither a name nor an index"
                )
            }
        }
    }

    public var description: String {
        guard let type else { return message }
        return "\(type): \(message)"
    }
}

/// A successful GraphQL response.
///
/// `errors` is carried alongside `data` rather than thrown, because both APIs routinely
/// answer `200` with both: one inaccessible repository in a search does not invalidate the
/// other forty results, and one unknown Linear identifier does not invalidate the batch it
/// was asked in. The caller decides — the fetch turns them into warnings the footer can
/// show, and only a wholly absent `data` is an error.
public struct GraphQLResult<Value>: Equatable where Value: Equatable {
    public var data: Value
    public var errors: [GraphQLError]

    public init(data: Value, errors: [GraphQLError] = []) {
        self.data = data
        self.errors = errors
    }
}

/// The POST body: a query string and its variables.
public struct GraphQLRequestBody: Encodable {
    public var query: String
    public var variables: [String: GraphQLValue]

    public init(query: String, variables: [String: GraphQLValue] = [:]) {
        self.query = query
        self.variables = variables
    }

    /// JSON, ready to hand to ``HTTPRequest``.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// `{ "data": …, "errors": [ … ] }`.
public struct GraphQLEnvelope<Value: Decodable>: Decodable {
    public var data: Value?
    public var errors: [GraphQLError]?
}

/// The `errors` array alone, decodable from any response regardless of what `data` holds.
///
/// Reading errors *before* and independently of `data` is load-bearing. When a resolver
/// fails, the server answers `200` with a `data` shaped unlike the query's own result type
/// and the reason in `errors`. Decoding the envelope first would turn that into a
/// malformed-response error and discard the reason — including a `RATE_LIMITED` the
/// scheduler has to see.
public struct GraphQLErrorsOnly: Decodable {
    public var errors: [GraphQLError]?

    public static func read(_ body: Data, decoder: JSONDecoder = JSONDecoder()) -> [GraphQLError] {
        (try? decoder.decode(GraphQLErrorsOnly.self, from: body))?.errors ?? []
    }
}
