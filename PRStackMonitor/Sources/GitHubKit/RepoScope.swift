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
    /// than sent. ``SearchQuery/build(scope:includesDrafts:extraQualifiers:)`` reports what
    /// it dropped.
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

    /// GitHub owner and repository names are ASCII letters, digits, `.`, `_` and `-`, and
    /// nothing else.
    ///
    /// An allowlist rather than a denylist, because the point of this check is to keep a
    /// name off the wire that GitHub's search would reject — and a denylist only catches
    /// the characters somebody thought of. `acme/bil(ling)`, `acme/a,b` and `acme/#1` are
    /// all names GitHub cannot have, and any of them would fail the whole query and take
    /// every other repository's pull requests with it.
    private static let allowedInName = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    /// `owner/name`, both halves non-empty and spelled with characters GitHub allows.
    public static func isWellFormed(_ repository: String) -> Bool {
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty
                && component.unicodeScalars.allSatisfy { RepoScope.allowedInName.contains($0) }
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

    /// The base qualifiers, from IMPLEMENTATION_PLAN §3.
    public static let baseQualifiers = "is:pr author:@me"

    /// Appended unless the caller asks for drafts.
    ///
    /// Drafts are dropped at the source rather than filtered after the fact, so with the
    /// preference off they cost no points and no page of the search — which is the whole
    /// reason the exclusion is a qualifier and not a `filter` over the results.
    public static let withoutDrafts = "-is:draft"

    /// Builds the query for a scope, or `nil` when the scope selects nothing.
    ///
    /// `includesDrafts` is the Settings preference (`Show draft pull requests`), off by
    /// default: PRD §2 defines the panel as the pull requests that have entered review, and
    /// a user who wants their work in progress in there has to say so.
    ///
    /// `nil` is the important case. An empty selection must **not** fall back to the base
    /// qualifiers: that string is exactly the `all` query, so "the user has unchecked
    /// every repository" would silently widen to "every repository the user has ever
    /// opened a pull request in". The client answers an empty selection with an empty
    /// result and no request at all.
    public static func build(
        scope: RepoScope,
        includesDrafts: Bool = false,
        extraQualifiers: [String] = []
    ) -> SearchQuery? {
        var qualifiers = [baseQualifiers]
        if !includesDrafts { qualifiers.append(withoutDrafts) }
        var dropped: [String] = []

        if case .selected(let requested) = scope {
            let normalized = scope.normalizedRepositories
            guard !normalized.isEmpty else { return nil }
            qualifiers.append(contentsOf: normalized.map { "repo:\($0)" })

            let kept = Set(normalized.map { $0.lowercased() })
            dropped = requested.filter { entry in
                let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                // A blank entry is not a repository the user asked for and lost — it is an
                // empty row in a settings list. Reporting it as `ignored '  '` would also
                // disagree with the empty-scope path, which filters blanks out.
                return !trimmed.isEmpty && !kept.contains(trimmed.lowercased())
            }
        }

        qualifiers.append(contentsOf: extraQualifiers)
        return SearchQuery(text: qualifiers.joined(separator: " "), droppedRepositories: dropped)
    }
}
