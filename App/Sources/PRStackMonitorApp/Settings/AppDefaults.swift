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
    static let showsDraftsKey = "showsDrafts"
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

    // MARK: - Drafts

    /// Whether the poll's searches include draft pull requests.
    ///
    /// Off unless the user has said otherwise, which is the PRD's definition of the panel
    /// (§2) — the pull requests that have entered review. Deliberately **not**
    /// account-scoped: it says what the user wants to look at, and that does not change when
    /// the token does, unlike a repository list which means nothing under another account.
    ///
    /// `bool(forKey:)` answers `false` for a value of the wrong type, which is the right
    /// failure here: a preference nobody can read falls back to the default rather than
    /// widening every search.
    static func showsDrafts(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: showsDraftsKey)
    }

    static func setShowsDrafts(_ showsDrafts: Bool, _ defaults: UserDefaults = .standard) {
        // Removed rather than stored as `false`, so "off" reads the same as a fresh install
        // and `defaults read` does not suggest a preference nobody set.
        if showsDrafts {
            defaults.set(true, forKey: showsDraftsKey)
        } else {
            defaults.removeObject(forKey: showsDraftsKey)
        }
    }

    // MARK: - Repository scope

    /// Which repositories the poll covers. `all` unless the user has said otherwise, and
    /// `all` again if the stored mode is a spelling this build does not know.
    static func repoScope(_ defaults: UserDefaults = .standard) -> RepoScope {
        let raw = defaults.string(forKey: key(repoScopeModeKey, defaults)) ?? ScopeMode.all.rawValue
        guard ScopeMode(rawValue: raw) == .selected else { return .all }
        return .selected(selectedRepositories(defaults))
    }

    static func setRepoScope(_ scope: RepoScope, _ defaults: UserDefaults = .standard) {
        defaults.set(
            scope.isAll ? ScopeMode.all.rawValue : ScopeMode.selected.rawValue,
            forKey: key(repoScopeModeKey, defaults)
        )
        // The selection is written even in `all` mode. Switching to All and back must not
        // silently blank the checklist, and the empty selection is exactly the case the
        // search client answers with no request at all.
        if case .selected(let repositories) = scope {
            defaults.set(repositories, forKey: key(selectedRepositoriesKey, defaults))
        }
    }

    static func selectedRepositories(_ defaults: UserDefaults = .standard) -> [String] {
        strings(forKey: key(selectedRepositoriesKey, defaults), defaults)
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
        strings(forKey: key(seenRepositoriesKey, defaults), defaults)
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
        if merged != stored { defaults.set(merged, forKey: key(seenRepositoriesKey, defaults)) }
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
        defaults.removeObject(forKey: key(seenRepositoriesKey, defaults))
        defaults.removeObject(forKey: key(selectedRepositoriesKey, defaults))
        setRepoScope(.all, defaults)
    }

    // MARK: - The signed-in account

    /// What ``noteViewer(_:_:)`` found.
    enum AccountChange: Equatable {
        /// The same account as the last poll, or a poll that could not say who it was for.
        case unchanged
        /// The first poll ever to name an account. Whatever is stored was configured under
        /// it — there has only been one — so it is handed over rather than left behind.
        case adopted(String)
        case switched(from: String, to: String)
    }

    /// The account the stored repository preferences currently belong to.
    static func viewerLogin(_ defaults: UserDefaults = .standard) -> String? {
        let stored = defaults.string(forKey: viewerLoginKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? nil : stored
    }

    /// Where an account's copy of `base` lives.
    ///
    /// Every account-scoped read and write in this file goes through here, which is what
    /// makes switching accounts **one write**: nothing is moved between keys, so there is no
    /// window in which the stored login says one account and some of the preferences still
    /// belong to another. A process that stops mid-switch has either written the login or
    /// not, and both are consistent.
    ///
    /// With no account identified yet — a fresh install, or any launch before the first poll
    /// answers — this is the bare key. That is also where every build before account scoping
    /// wrote, which is what lets ``noteViewer(_:_:)`` adopt those settings by copying from
    /// one known place rather than carrying a migration table.
    private static func key(_ base: String, for login: String?) -> String {
        guard let login, !login.isEmpty else { return base }
        return "\(base)@\(login.lowercased())"
    }

    /// Lower-cased in ``key(_:for:)``, because GitHub logins are case-insensitive and
    /// `Jankuca` coming back must find what `jankuca` left.
    private static func key(_ base: String, _ defaults: UserDefaults) -> String {
        key(base, for: viewerLogin(defaults))
    }

    /// Records who the poll answered for, which is what every account-scoped preference is
    /// keyed by.
    ///
    /// Replacing the token in Settings is not a small edit — it repoints the app at a
    /// different person's pull requests — and the repository list is the part that cannot
    /// survive the change: it is the previous account's, and it is what the `selected` scope
    /// filters against. Left alone, the panel is empty and the checklist offers repositories
    /// the new token cannot see, with nothing anywhere saying why.
    ///
    /// Nothing is discarded on the way. The previous account's preferences stay under their
    /// own keys and are found again if that token comes back — switching between a work
    /// token and a personal one is the reason anyone has two, and a selection thrown away
    /// the first time is a selection nobody makes twice. An account seen for the first time
    /// has nothing stored, so it starts where a fresh install does: All repositories, an
    /// empty list, and the next poll fills it in.
    ///
    /// The viewer login is GitHub's own answer to `viewer { login }` on the poll the token
    /// just made — not the token, which is never stored anywhere but the Keychain.
    @discardableResult
    static func noteViewer(_ login: String, _ defaults: UserDefaults = .standard) -> AccountChange {
        let incoming = login.trimmingCharacters(in: .whitespacesAndNewlines)
        // A poll that produced no login answers nothing about whose it was, so it is not
        // evidence of a switch. Both searches would have to come back empty for this.
        guard !incoming.isEmpty else { return .unchanged }

        let stored = viewerLogin(defaults)
        guard stored?.lowercased() != incoming.lowercased() else { return .unchanged }

        guard let previous = stored else {
            adopt(incoming, defaults)
            return .adopted(incoming)
        }

        // One write, and every keyed read above follows it.
        defaults.set(incoming, forKey: viewerLoginKey)
        return .switched(from: previous, to: incoming)
    }

    /// Hands the settings stored before anyone knew whose they were to the first account
    /// that identifies itself.
    ///
    /// The one place account scoping copies anything, and the copy is safe to interrupt:
    /// the login is written **last**, so a process that stops partway leaves it unset and
    /// the bare keys untouched — the next poll runs the whole thing again from the same
    /// starting point. Skipping keys the account already has is what makes the repeat
    /// harmless rather than a second overwrite.
    ///
    /// The bare keys are left behind rather than deleted. They are unreachable once a login
    /// is stored, and leaving them is what keeps this idempotent.
    private static func adopt(_ login: String, _ defaults: UserDefaults) {
        for base in accountScopedKeys {
            let destination = key(base, for: login)
            guard defaults.object(forKey: destination) == nil,
                  let inherited = defaults.object(forKey: base) else { continue }
            defaults.set(inherited, forKey: destination)
        }
        defaults.set(login, forKey: viewerLoginKey)
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
