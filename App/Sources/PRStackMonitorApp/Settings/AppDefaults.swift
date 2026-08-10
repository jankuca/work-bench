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
    static let viewerLoginKey = "githubViewerLogin"

    /// The preferences that belong to a GitHub **account** rather than to the machine.
    ///
    /// Every one of them names repositories, and a repository list means nothing across
    /// accounts: the second token's owner has not opened a pull request in any of the first
    /// one's repositories, so a `selected` scope carried over from them matches nothing and
    /// the panel goes quietly empty. The tag patterns are deliberately not here — those are
    /// keyed by repository, and a repository is the same repository whoever is looking.
    private static let accountScopedKeys = [
        repoScopeModeKey,
        selectedRepositoriesKey,
        seenRepositoriesKey
    ]

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
    ///
    /// What is already stored goes through the same filter as what arrives. A hand-written
    /// `defaults write` can put `["acme/web", "ACME/web", " "]` under this key, and a merge
    /// that trusted the stored half would carry all three into the checklist while claiming
    /// to have de-duplicated them.
    @discardableResult
    static func noteRepositories<Names: Sequence>(
        _ names: Names,
        _ defaults: UserDefaults = .standard
    ) -> [String] where Names.Element == String {
        let stored = seenRepositories(defaults)
        var seen: Set<String> = []
        var merged: [String] = []
        for name in stored + Array(names) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard RepoScope.isWellFormed(trimmed), seen.insert(trimmed.lowercased()).inserted else { continue }
            merged.append(trimmed)
        }
        merged.sort { $0.lowercased() < $1.lowercased() }
        if merged != stored { defaults.set(merged, forKey: seenRepositoriesKey) }
        return merged
    }

    /// Empties the checklist and the selection under it, and widens the scope back to All.
    ///
    /// The list only ever grows — a repository that has stopped producing pull requests
    /// stays, deliberately, so that unchecking it does not become impossible — which means
    /// there has to be one way to start it over. Two situations need it and neither
    /// self-corrects: entries left behind by a token that was replaced before this build
    /// tracked which account a list belonged to, and repositories that have simply been
    /// archived. Widening to All is part of the reset rather than a side effect: clearing a
    /// selection while `selected` is in force is the one state that stops every poll.
    static func resetRepositories(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: seenRepositoriesKey)
        defaults.removeObject(forKey: selectedRepositoriesKey)
        setRepoScope(.all, defaults)
    }

    // MARK: - The signed-in account

    /// What ``noteViewer(_:_:)`` found.
    enum AccountChange: Equatable {
        /// The same account as the last poll, or a poll that could not say who it was for.
        case unchanged
        /// The first poll ever to name an account. Whatever is stored was configured under
        /// it — there has only been one — so it is adopted rather than parked.
        case adopted(String)
        case switched(from: String, to: String)
    }

    /// The account the stored repository preferences currently belong to.
    static func viewerLogin(_ defaults: UserDefaults = .standard) -> String? {
        let stored = defaults.string(forKey: viewerLoginKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? nil : stored
    }

    /// Records who the poll answered for, and moves the account-scoped preferences with it.
    ///
    /// Replacing the token in Settings is not a small edit — it repoints the app at a
    /// different person's pull requests — and the repository list is the part that cannot
    /// survive the change: it is the previous account's, and it is what the `selected` scope
    /// filters against. Left alone, the panel is empty and the checklist offers repositories
    /// the new token cannot see, with nothing anywhere saying why.
    ///
    /// Parked rather than deleted, and restored on the way back. Switching between a work
    /// token and a personal one is the reason anyone has two, and a selection that was
    /// discarded the first time is a selection nobody makes twice. An account seen for the
    /// first time has nothing parked, so it starts where a fresh install does: All
    /// repositories, an empty list, and the next poll fills it in.
    ///
    /// The viewer login is GitHub's own answer to `viewer { login }` on the poll the token
    /// just made — not the token, which is never stored anywhere but the Keychain.
    @discardableResult
    static func noteViewer(_ login: String, _ defaults: UserDefaults = .standard) -> AccountChange {
        let incoming = login.trimmingCharacters(in: .whitespacesAndNewlines)
        // A poll that produced no login answers nothing about whose it was, so it is not
        // evidence of a switch. Both searches would have to come back empty for this.
        guard !incoming.isEmpty else { return .unchanged }

        let previous = viewerLogin(defaults)
        guard previous?.lowercased() != incoming.lowercased() else { return .unchanged }
        defaults.set(incoming, forKey: viewerLoginKey)

        guard let previous else { return .adopted(incoming) }
        for key in accountScopedKeys {
            move(key, to: parked(key, for: previous), defaults)
            move(parked(key, for: incoming), to: key, defaults)
        }
        return .switched(from: previous, to: incoming)
    }

    /// Where an account's preferences wait while another account is signed in. Lower-cased,
    /// because GitHub logins are case-insensitive and `Jankuca` coming back must find what
    /// `jankuca` parked.
    private static func parked(_ key: String, for login: String) -> String {
        "\(key)@\(login.lowercased())"
    }

    /// Moves a stored value, leaving nothing behind at either end.
    ///
    /// Absent has to stay absent: an account with nothing parked must arrive at this
    /// build's defaults, and copying rather than moving would leave it looking at the
    /// account it replaced.
    private static func move(_ source: String, to destination: String, _ defaults: UserDefaults) {
        if let value = defaults.object(forKey: source) {
            defaults.set(value, forKey: destination)
        } else {
            defaults.removeObject(forKey: destination)
        }
        defaults.removeObject(forKey: source)
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
