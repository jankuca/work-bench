import SwiftUI
import PRStackCore

/// The Settings window: accounts, repositories, notifications.
///
/// Three tabs because they answer three different questions — what am I connected to, what
/// am I watching, what do I want to hear about — and because the repository tab is a list
/// that wants the room.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            AccountsSettingsView(model: model)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            RepositoriesSettingsView(model: model)
                .tabItem { Label("Repositories", systemImage: "folder") }
            EventSettingsView(model: model)
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 520, height: 400)
        // The Keychain, the environment and the repository list can all change while the
        // window is open — a token revoked in Keychain Access, a variable exported into a
        // relaunch, a poll landing behind the window — and this is the one place that would
        // otherwise go on claiming the old answer.
        .onAppear { model.reload() }
    }
}

/// Tokens. Both are pasted personal access tokens; neither involves an OAuth callback or
/// Apple (IMPLEMENTATION_PLAN §3).
struct AccountsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("GitHub") {
                CredentialField(
                    prompt: "Classic personal access token",
                    help: "Scope: repo (or public_repo). CI status needs a classic token — "
                        + "fine-grained tokens cannot read Checks.",
                    value: $model.githubToken,
                    source: model.githubSource,
                    isStored: model.githubHasStoredToken,
                    onSave: model.saveGitHubToken,
                    onRemove: model.removeGitHubToken
                )
                // Which token is in use is otherwise unanswerable from this window: the
                // field is write-only, so `Stored in the login keychain` reads the same
                // before and after a token is replaced. This is GitHub's own answer, from
                // the last poll the stored token made.
                if let account = model.githubAccount {
                    Text("Signed in as @\(account). Repository settings below are kept per account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Linear") {
                CredentialField(
                    prompt: "Personal API key",
                    help: "Optional. Without it every row groups under Other.",
                    value: $model.linearKey,
                    source: model.linearSource,
                    isStored: model.linearHasStoredToken,
                    onSave: model.saveLinearKey,
                    onRemove: model.removeLinearKey
                )
            }

            if let message = model.credentialMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

/// One credential: a write-only field, where it is currently coming from, and the two
/// things that can be done to it.
struct CredentialField: View {
    var prompt: String
    var help: String
    @Binding var value: String
    var source: SettingsModel.CredentialSource
    /// Whether the Keychain holds one, separately from whether it is the one in use.
    var isStored: Bool
    var onSave: () -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SecureField(prompt, text: $value)
                    .textFieldStyle(.roundedBorder)
                Button("Save", action: onSave)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // Offered whenever something is stored, not only when the store is what
                // the app is reading. An exported variable outranks the Keychain, and
                // hiding this behind that would leave a token the user cannot delete.
                if isStored {
                    Button("Remove", action: onRemove)
                }
            }
            Text(help)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        switch source {
        case .absent:
            return "Not configured."
        case .keychain:
            return "Stored in the login keychain."
        case .environment(let name):
            // Worth stating plainly: the chain tries the environment before the Keychain,
            // so a stored token is sitting there unused until the variable goes away. Said
            // only when there actually is one, or it reads as a warning about nothing.
            guard isStored else { return "Using $\(name) from the environment." }
            return "Using $\(name) from the environment; the saved token is ignored while it is set."
        }
    }
}

/// Repository scope and the per-repository release-tag glob, in one list because they are
/// two columns of the same question.
struct RepositoriesSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Watch", selection: scope) {
                    Text("All repositories I open pull requests in").tag(true)
                    Text("Only the ones I select").tag(false)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Both modes cost one search request per poll — selecting fewer repositories "
                     + "does not make the app faster, only quieter.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section(model.repositoriesHeading) {
                if model.repositories.isEmpty {
                    Text("Nothing seen yet. Repositories appear here as polls return pull requests from them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.repositories) { repository in
                        RepositoryRow(model: model, repository: repository)
                    }
                }

                // An empty selection is answered with no request at all rather than
                // silently widening to everything, so the panel goes empty and stays that
                // way. Better said here than discovered.
                if model.isWatchingNothing {
                    Label(
                        "Nothing is selected, so no pull requests are fetched.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                // The list only ever grows, so this is the one way back. Offered whenever
                // there is something to clear, not only after a token change: an archived
                // repository is the same problem arriving slowly.
                if !model.repositories.isEmpty {
                    HStack {
                        Text("Repositories are remembered as polls find them, and never drop out on "
                             + "their own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Reset list", action: model.resetRepositories)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The picker is a two-value radio group over the model's `Bool`, which keeps the
    /// pre-checking rule (§3) in the model rather than in the binding.
    private var scope: Binding<Bool> {
        Binding(get: { model.isAllRepositories }, set: { model.setAllRepositories($0) })
    }
}

struct RepositoryRow: View {
    @ObservedObject var model: SettingsModel
    var repository: SettingsModel.RepositorySetting

    var body: some View {
        HStack(spacing: 10) {
            Toggle(repository.name, isOn: selected)
                // The checkbox is meaningless in All mode, but the row stays visible: the
                // tag pattern beside it is not, and hiding the list would make it
                // unreachable for anyone who watches everything.
                .disabled(model.isAllRepositories)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            TextField(model.defaultTagPattern, text: pattern)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .help("Which tags count as releases in this repository. Blank uses \(model.defaultTagPattern).")
        }
    }

    private var selected: Binding<Bool> {
        Binding(
            get: { repository.isSelected },
            set: { model.setSelected($0, for: repository.name) }
        )
    }

    private var pattern: Binding<String> {
        Binding(
            get: { repository.tagPattern },
            set: { model.setTagPattern($0, for: repository.name) }
        )
    }
}

/// The per-event toggles. Honest about what they do today, which is filter a bus with one
/// sink on it.
struct EventSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(DomainEventKind.allCases, id: \.self) { kind in
                    Toggle(kind.settingsTitle, isOn: binding(for: kind))
                }
            } header: {
                Text("Tell me when")
            } footer: {
                Text("PRStackMonitor does not post system notifications yet — without a paid "
                     + "Apple Developer account they are unreliable for a self-signed app. These "
                     + "switches gate the events the menu bar icon is driven by, and they are what "
                     + "a notification will read when there is one.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for kind: DomainEventKind) -> Binding<Bool> {
        Binding(
            get: { model.enabledEvents[kind] ?? true },
            set: { model.setEvent(kind, enabled: $0) }
        )
    }
}
