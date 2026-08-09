import Foundation
import GitHubKit
import LinearKit
import NetKit
import PRStackCore

/// Everything the Settings window edits, and the only place it is written.
///
/// Three stores sit behind it and the split is deliberate: credentials go to the Keychain,
/// preferences to `UserDefaults`, and nothing here touches `state.json` — the panel's own
/// state has one writer and it is not this window (IMPLEMENTATION_PLAN §3).
///
/// Every edit is applied immediately rather than on an OK button. A settings window with no
/// document behind it has nothing to cancel back to, and a repository checkbox that only
/// took effect on close would leave the panel disagreeing with the checklist in front of it.
@MainActor
final class SettingsModel: ObservableObject {
    /// One repository in the checklist, with its release-tag glob.
    struct RepositorySetting: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var isSelected: Bool
        /// Empty means "no override" — the row shows `v*` greyed out and the tracker uses it.
        var tagPattern: String
    }

    /// Where a credential is actually coming from, which is not always where it was put.
    enum CredentialSource: Equatable {
        /// Nothing stored and nothing exported. `absent` rather than `none`, which reads as
        /// `Optional.none` at every call site that has an optional in scope.
        case absent
        case keychain
        /// The environment wins over the Keychain (``CredentialChain``), so a stored token
        /// can be sitting there unused. Saying which variable is what makes that debuggable.
        case environment(String)
    }

    /// Called after any change a poll would read differently.
    var onChange: () -> Void = {}

    @Published var isAllRepositories: Bool
    @Published private(set) var repositories: [RepositorySetting]

    /// The two token fields. Write-only: a stored credential is never read back into the
    /// window — there is no reason to put a live token on screen, and an empty field with
    /// `Stored in the login keychain` beside it says everything the user needs.
    @Published var githubToken: String = ""
    @Published var linearKey: String = ""
    @Published private(set) var githubSource: CredentialSource = .absent
    @Published private(set) var linearSource: CredentialSource = .absent
    /// The outcome of the last credential action, or the reason it failed. The Keychain is
    /// the one thing here that can refuse.
    @Published private(set) var credentialMessage: String?

    /// Per-event-type delivery, as ``EventPreferences`` holds it.
    @Published private(set) var enabledEvents: [DomainEventKind: Bool]

    private let defaults: UserDefaults
    private let events: EventBus
    private let environment: [String: String]

    init(
        events: EventBus,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.events = events
        self.defaults = defaults
        self.environment = environment

        let scope = AppDefaults.repoScope(defaults)
        isAllRepositories = scope.isAll

        let selected = Set(AppDefaults.selectedRepositories(defaults).map { $0.lowercased() })
        let patterns = AppDefaults.tagPatterns(defaults)
        // The union of what the polls have seen and what is currently selected. A repository
        // that has stopped producing pull requests must not vanish out of the list it is
        // still checked in, or unchecking it would become impossible.
        let known = AppDefaults.noteRepositories(AppDefaults.selectedRepositories(defaults), defaults)
        repositories = known.map { name in
            RepositorySetting(
                name: name,
                isSelected: selected.contains(name.lowercased()),
                // The stored value only, never the `v*` fallback: an empty field is what
                // makes "no override" visible, and writing the default back would turn every
                // repository the user has ever seen into an explicit entry.
                tagPattern: patterns.byRepository[name.lowercased()] ?? ""
            )
        }

        enabledEvents = Dictionary(
            uniqueKeysWithValues: DomainEventKind.allCases.map { ($0, events.preferences.allows($0)) }
        )

        refreshCredentialSources()
    }

    // MARK: - Repository scope

    /// Switching between All and Selected.
    ///
    /// Turning Selected on with nothing checked pre-checks everything visible, per
    /// IMPLEMENTATION_PLAN §3 — the mode switch must never blank the panel, and an empty
    /// selection is answered by the client with no request at all.
    func setAllRepositories(_ isAll: Bool) {
        isAllRepositories = isAll
        if !isAll, !repositories.contains(where: \.isSelected) {
            repositories = repositories.map {
                var setting = $0
                setting.isSelected = true
                return setting
            }
        }
        writeScope()
    }

    func setSelected(_ isSelected: Bool, for name: String) {
        guard let index = repositories.firstIndex(where: { $0.name == name }) else { return }
        repositories[index].isSelected = isSelected
        writeScope()
    }

    /// The per-repository release-tag glob. Blank clears the override back to `v*`.
    func setTagPattern(_ pattern: String, for name: String) {
        guard let index = repositories.firstIndex(where: { $0.name == name }) else { return }
        repositories[index].tagPattern = pattern

        var patterns = AppDefaults.tagPatterns(defaults)
        // `TagPatterns.set` already treats blank as "no entry", so this is one path and not
        // a branch on emptiness here.
        patterns.set(pattern, for: name)
        AppDefaults.setTagPatterns(patterns, defaults)
        onChange()
    }

    /// The pattern actually in force for a repository, for the field's placeholder.
    var defaultTagPattern: String { TagPatterns.defaultPattern }

    /// Selected mode with nothing selected — a state the user can reach, and one that stops
    /// every poll. The client answers an empty selection with no request rather than
    /// widening back to everything, so this has to be said out loud.
    var isWatchingNothing: Bool {
        !isAllRepositories && !repositories.contains(where: \.isSelected)
    }

    private func writeScope() {
        let selected = repositories.filter(\.isSelected).map(\.name)
        AppDefaults.setRepoScope(isAllRepositories ? .all : .selected(selected), defaults)
        onChange()
    }

    // MARK: - Credentials

    func saveGitHubToken() {
        // The field is cleared only on success. A Keychain that refused the write is the one
        // moment the pasted token is worth keeping on screen — it is the only copy the user
        // still has without going back to GitHub for another one.
        if save(githubToken, to: KeychainTokenStore(account: .github), named: "GitHub token") {
            githubToken = ""
        }
    }

    func removeGitHubToken() {
        remove(KeychainTokenStore(account: .github), named: "GitHub token")
    }

    func saveLinearKey() {
        if save(linearKey, to: KeychainTokenStore(account: .linear), named: "Linear API key") {
            linearKey = ""
        }
    }

    func removeLinearKey() {
        remove(KeychainTokenStore(account: .linear), named: "Linear API key")
    }

    /// True when the credential reached the Keychain.
    @discardableResult
    private func save(_ value: String, to store: KeychainTokenStore, named name: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            credentialMessage = "Paste a \(name) first."
            return false
        }
        var saved = false
        do {
            try store.save(trimmed)
            credentialMessage = "\(name) saved."
            saved = true
        } catch {
            credentialMessage = "Could not save the \(name): \(String(describing: error))"
        }
        finishCredentialChange()
        return saved
    }

    private func remove(_ store: KeychainTokenStore, named name: String) {
        do {
            try store.remove()
            credentialMessage = "\(name) removed."
        } catch {
            credentialMessage = "Could not remove the \(name): \(String(describing: error))"
        }
        finishCredentialChange()
    }

    /// A credential change is the one edit worth polling on immediately: it is how the
    /// reconnect banner comes down.
    private func finishCredentialChange() {
        refreshCredentialSources()
        onChange()
    }

    func refreshCredentialSources() {
        githubSource = source(names: EnvironmentTokenProvider.github(environment: environment).names,
                              store: KeychainTokenStore(account: .github))
        linearSource = source(names: EnvironmentTokenProvider.linear(environment: environment).names,
                              store: KeychainTokenStore(account: .linear))
    }

    private func source(names: [String], store: KeychainTokenStore) -> CredentialSource {
        for name in names {
            let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return .environment(name) }
        }
        return store.hasToken ? .keychain : .absent
    }

    // MARK: - Events

    /// Which transitions reach the sinks.
    ///
    /// v1 has one sink and it ignores them (IMPLEMENTATION_PLAN §1), so today this changes
    /// nothing a user can see. It is here because the bus already filters on it and a
    /// `UserNotificationSink` is meant to be a drop-in — a toggle set retrofitted alongside
    /// a new sink is a toggle set with no stored history.
    func setEvent(_ kind: DomainEventKind, enabled: Bool) {
        enabledEvents[kind] = enabled
        var preferences = events.preferences
        preferences.setEnabled(enabled, for: kind)
        // The live bus and the stored copy, in that order: the bus is what the next poll
        // filters through, and `save` writes every toggle so a value flipped back on
        // overwrites the stored exception rather than leaving it behind.
        events.preferences = preferences
        preferences.save(to: defaults)
    }
}
