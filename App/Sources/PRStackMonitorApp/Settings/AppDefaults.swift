import Foundation
import GitHubKit

/// The `UserDefaults` keys the app reads, in one place.
///
/// Everything here is a *preference*: the repository scope, the per-repository tag
/// patterns, the repositories the polls have seen. None of it is state the panel derives
/// from — that lives in `state.json` behind `StateStore`, and the split is deliberate.
/// `defaults delete com.jankuca.PRStackMonitor` should cost the user their settings and
/// nothing they did to a row.
///
/// Every reader here is forgiving in the same way, and for the same reason as
/// `LocalState.init(from:)`: `defaults write` can put any plist value under any of these
/// keys. A wrong type must cost the user that one preference, not the app's ability to
/// poll.
enum AppDefaults {
    static let tagPatternsKey = "tagPatterns"
    static let repoScopeModeKey = "repoScopeMode"
    static let selectedRepositoriesKey = "selectedRepositories"
    static let seenRepositoriesKey = "seenRepositories"

    /// The two spellings of ``RepoScope`` as they appear on disk. Not `RawRepresentable`
    /// on `RepoScope` itself: that type carries the selection with it, and the stored form
    /// keeps the list under its own key so unchecking every repository does not also
    /// forget which ones they were.
    private enum ScopeMode: String {
        case all
        case selected
    }

    // MARK: - Tag patterns

    /// The repository → glob map, with anything unreadable ignored rather than fatal.
    ///
    /// Entries that are not `String: String` are dropped, and every repository without a
    /// usable entry falls back to `v*`.
    static func tagPatterns(_ defaults: UserDefaults = .standard) -> TagPatterns {
        guard let stored = defaults.dictionary(forKey: tagPatternsKey) else { return .standard }
        var patterns: [String: String] = [:]
        for (repository, value) in stored {
            guard let pattern = value as? String else { continue }
            patterns[repository] = pattern
        }
        return TagPatterns(patterns)
    }

    /// Writes the map back. `TagPatterns` has already dropped blank keys and blank
    /// patterns, so what is stored is what the next read will produce.
    static func setTagPatterns(_ patterns: TagPatterns, _ defaults: UserDefaults = .standard) {
        if patterns.byRepository.isEmpty {
            // Removed rather than stored as an empty dictionary, so "no overrides" reads
            // the same as a fresh install.
            defaults.removeObject(forKey: tagPatternsKey)
        } else {
            defaults.set(patterns.byRepository, forKey: tagPatternsKey)
        }
    }

    // MARK: - Repository scope

    /// Which repositories the poll covers. `all` unless the user has said otherwise, and
    /// `all` again if the stored mode is a spelling this build does not know.
    static func repoScope(_ defaults: UserDefaults = .standard) -> RepoScope {
        let raw = defaults.string(forKey: repoScopeModeKey) ?? ScopeMode.all.rawValue
        guard ScopeMode(rawValue: raw) == .selected else { return .all }
        return .selected(selectedRepositories(defaults))
    }

    static func setRepoScope(_ scope: RepoScope, _ defaults: UserDefaults = .standard) {
        defaults.set(scope.isAll ? ScopeMode.all.rawValue : ScopeMode.selected.rawValue, forKey: repoScopeModeKey)
        // The selection is written even in `all` mode. Switching to All and back must not
        // silently blank the checklist, and the empty selection is exactly the case the
        // search client answers with no request at all.
        if case .selected(let repositories) = scope {
            defaults.set(repositories, forKey: selectedRepositoriesKey)
        }
    }

    static func selectedRepositories(_ defaults: UserDefaults = .standard) -> [String] {
        strings(forKey: selectedRepositoriesKey, defaults)
    }

    // MARK: - Repositories seen

    /// Every repository a poll has returned a pull request from, which is what Settings
    /// offers as the checklist (IMPLEMENTATION_PLAN §3).
    ///
    /// Persisted rather than read off the current snapshot, because the list has to be
    /// there before the first poll of a launch lands — and because `selected` scope
    /// narrows the snapshot, so reading only what is on screen would make the unchecked
    /// repositories disappear from the very list they are unchecked in.
    static func seenRepositories(_ defaults: UserDefaults = .standard) -> [String] {
        strings(forKey: seenRepositoriesKey, defaults)
    }

    /// Unions `names` into the stored list. Sorted, case-insensitively de-duplicated, and
    /// only written when it actually changed — this runs on every poll.
    @discardableResult
    static func noteRepositories<Names: Sequence>(
        _ names: Names,
        _ defaults: UserDefaults = .standard
    ) -> [String] where Names.Element == String {
        let existing = seenRepositories(defaults)
        var seen = Set(existing.map { $0.lowercased() })
        var merged = existing
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard RepoScope.isWellFormed(trimmed), seen.insert(trimmed.lowercased()).inserted else { continue }
            merged.append(trimmed)
        }
        merged.sort { $0.lowercased() < $1.lowercased() }
        if merged != existing { defaults.set(merged, forKey: seenRepositoriesKey) }
        return merged
    }

    // MARK: - Reading

    /// A `[String]` under `key`, with non-string elements dropped.
    ///
    /// `array(forKey:)` rather than `stringArray(forKey:)`: the latter answers nil for the
    /// *whole* array as soon as one element is not a string, which would turn one bad
    /// entry into a forgotten selection.
    private static func strings(forKey key: String, _ defaults: UserDefaults) -> [String] {
        guard let stored = defaults.array(forKey: key) else { return [] }
        return stored.compactMap { $0 as? String }
    }
}
