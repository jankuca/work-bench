import Foundation

/// Which repositories the poll covers (IMPLEMENTATION_PLAN §3).
///
/// Both modes are a *single* search request: multiple `repo:` qualifiers in one query are
/// OR'd by GitHub, so `selected` costs no more calls than `all`.
public enum RepoScope: Equatable, Sendable {
    /// Every repository the user authors pull requests in.
    case all
    /// A checked subset, as `owner/name`.
    case selected([String])

    public var isAll: Bool {
        if case .all = self { return true }
        return false
    }

    /// The selection, normalised: trimmed, malformed entries dropped, de-duplicated
    /// case-insensitively while keeping first-seen order and spelling.
    ///
    /// GitHub's search would reject the whole query for one malformed qualifier, taking
    /// every other repository's pull requests with it, so a bad entry is dropped rather
    /// than sent. ``SearchQuery/build(scope:)`` reports what it dropped.
    public var normalizedRepositories: [String] {
        guard case .selected(let repositories) = self else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for repository in repositories {
            let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
            guard RepoScope.isWellFormed(trimmed) else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// `owner/name`, with nothing in either half that would change the meaning of the
    /// qualifier it is spliced into.
    public static func isWellFormed(_ repository: String) -> Bool {
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`:*?~^\\"))
        return components.allSatisfy { component in
            !component.isEmpty && String(component).rangeOfCharacter(from: forbidden) == nil
        }
    }
}

/// The search query string, and what had to be discarded to build it.
public struct SearchQuery: Equatable, Sendable {
    /// The full qualifier string, ready to be sent as the `query` variable.
    public var text: String
    /// Repositories the caller asked for that could not be turned into a qualifier.
    public var droppedRepositories: [String]

    public init(text: String, droppedRepositories: [String] = []) {
        self.text = text
        self.droppedRepositories = droppedRepositories
    }

    /// The base qualifiers, from IMPLEMENTATION_PLAN §3. Drafts are excluded at the
    /// source rather than filtered afterwards, so they never cost points.
    public static let baseQualifiers = "is:pr author:@me -is:draft"

    /// Builds the query for a scope, or `nil` when the scope selects nothing.
    ///
    /// `nil` is the important case. An empty selection must **not** fall back to the base
    /// qualifiers: that string is exactly the `all` query, so "the user has unchecked
    /// every repository" would silently widen to "every repository the user has ever
    /// opened a pull request in". The client answers an empty selection with an empty
    /// result and no request at all.
    public static func build(scope: RepoScope, extraQualifiers: [String] = []) -> SearchQuery? {
        var qualifiers = [baseQualifiers]

        if case .selected(let requested) = scope {
            let normalized = scope.normalizedRepositories
            guard !normalized.isEmpty else { return nil }
            qualifiers.append(contentsOf: normalized.map { "repo:\($0)" })

            let kept = Set(normalized.map { $0.lowercased() })
            let dropped = requested.filter { requested in
                let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
                return !kept.contains(trimmed.lowercased())
            }
            qualifiers.append(contentsOf: extraQualifiers)
            return SearchQuery(
                text: qualifiers.joined(separator: " "),
                droppedRepositories: dropped
            )
        }

        qualifiers.append(contentsOf: extraQualifiers)
        return SearchQuery(text: qualifiers.joined(separator: " "))
    }
}
