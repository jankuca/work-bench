import Foundation

/// Which tags count as releases, per repository.
///
/// A **repository-keyed map**, not one global pattern: a user whose repositories tag as
/// `v1.2.3` and `release-2026-01-04` cannot be served by a single glob, and getting it
/// wrong does not fail loudly — it just leaves every merge in one repository sitting at
/// `merged · awaiting release` forever (IMPLEMENTATION_PLAN §3).
///
/// M6 reads this map and M7 added the editor for it; a repository with no entry still takes
/// the `v*` default, which is most of them.
public struct TagPatterns: Equatable, Sendable {
    /// The default for any repository without an entry.
    public static let defaultPattern = "v*"

    /// Keyed by `nameWithOwner`. Lookup is case-insensitive, because GitHub treats
    /// `Acme/Billing` and `acme/billing` as the same repository and the user may well type
    /// one and see the other in search results.
    public private(set) var byRepository: [String: String]

    public init(_ byRepository: [String: String] = [:]) {
        self.byRepository = [:]
        for (repository, pattern) in byRepository {
            let key = TagPatterns.key(repository)
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty pattern matches nothing at all, which would silently switch release
            // tracking off for that repository. Treat it as "no entry".
            guard !key.isEmpty, !trimmed.isEmpty else { continue }
            self.byRepository[key] = trimmed
        }
    }

    public static let standard = TagPatterns()

    public func pattern(for repository: String) -> String {
        byRepository[TagPatterns.key(repository)] ?? TagPatterns.defaultPattern
    }

    public func glob(for repository: String) -> Glob {
        Glob(pattern(for: repository))
    }

    public mutating func set(_ pattern: String?, for repository: String) {
        let key = TagPatterns.key(repository)
        // The same rejection the initialiser makes. Without it, a blank repository stores
        // its pattern under `""`, and `pattern(for: "")` answers with it instead of the
        // default — a setter and an initialiser disagreeing about their own key space.
        guard !key.isEmpty else { return }
        guard let pattern, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            byRepository[key] = nil
            return
        }
        byRepository[key] = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func key(_ repository: String) -> String {
        repository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
