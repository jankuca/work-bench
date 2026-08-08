import Foundation
import NetKit

/// One batched `issue(id:)` query: one aliased field per identifier.
///
/// Linear's `issue(id:)` accepts the human-readable identifier directly, so resolution
/// keeps the **full identifier** as the key throughout and never splits it into a team key
/// and a number. That is what makes cross-team number collisions impossible to introduce:
/// `BIL-312` and `SRC-97` are two independent lookups that cannot combine into `BIL-97`.
///
/// IMPLEMENTATION_PLAN §2 spells out the form this must **not** take:
///
/// ```graphql
/// issues(filter: { team: { key: { in: ["BIL", "SRC"] } }, number: { in: [312, 97] } })
/// ```
///
/// Independent `in` lists match the cross-product, so that filter also matches `BIL-97`
/// and `SRC-312` and files the pull requests under the wrong projects. The batch here is
/// per *identifier*, not per pull request, so a ticket referenced by two pull requests is
/// fetched once and cached once.
enum IssueBatchQuery {
    struct Batch {
        var text: String
        var variables: [String: GraphQLValue]
        /// Alias → the identifier it was asked for, which is how the response is read back.
        var identifiers: [String: String]
    }

    /// `a0`, `a1`, … — GraphQL aliases have to match `[_A-Za-z][_0-9A-Za-z]*`, and
    /// `BIL-312` does not, so the identifier cannot be its own alias.
    static func alias(_ index: Int) -> String { "a\(index)" }

    static func build(identifiers: [String]) -> Batch {
        var fields: [String] = []
        var declarations: [String] = []
        var variables: [String: GraphQLValue] = [:]
        var byAlias: [String: String] = [:]

        for (index, identifier) in identifiers.enumerated() {
            let alias = alias(index)
            byAlias[alias] = identifier
            // The identifier travels as a variable rather than being interpolated into the
            // query text. It reaches here from a pull request title and a branch name —
            // strings a third party controls — and the scanner's shape check is a filter,
            // not a guarantee that belongs on the far side of a string interpolation.
            declarations.append("$\(alias): String!")
            variables[alias] = .string(identifier)
            fields.append("  \(alias): issue(id: $\(alias)) { identifier url project { id name } }")
        }

        let text = """
        query IssueBatch(\(declarations.joined(separator: ", "))) {
        \(fields.joined(separator: "\n"))
        }
        """
        return Batch(text: text, variables: variables, identifiers: byAlias)
    }
}

/// The wire shape of one aliased `issue` field.
struct IssueDTO: Decodable, Equatable {
    var identifier: String?
    var url: String?
    var project: ProjectDTO?
}

struct ProjectDTO: Decodable, Equatable {
    var id: String?
    var name: String?
}

/// The batch's `data`: alias → issue, with the aliases only known at runtime.
struct IssueBatchPayload: Decodable, Equatable {
    var issues: [String: IssueDTO?]

    private struct AliasKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(issues: [String: IssueDTO?]) {
        self.issues = issues
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AliasKey.self)
        var issues: [String: IssueDTO?] = [:]
        for key in container.allKeys {
            // An alias that decodes to null is an issue Linear does not have. Recorded as
            // a present-but-nil entry rather than dropped, because "asked and told no" and
            // "never asked" have to stay distinguishable: the first is worth caching so the
            // same junk identifier is not re-queried every poll, and the second is not.
            // `updateValue` rather than the subscript: the value type is already optional,
            // so `issues[key] = nil` would *remove* the entry — the exact opposite of
            // recording that Linear answered "no such issue".
            if try container.decodeNil(forKey: key) {
                issues.updateValue(nil, forKey: key.stringValue)
            } else {
                issues.updateValue(try container.decode(IssueDTO.self, forKey: key), forKey: key.stringValue)
            }
        }
        self.issues = issues
    }
}
