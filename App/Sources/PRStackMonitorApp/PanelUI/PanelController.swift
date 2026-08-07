import AppKit
import Combine
import SwiftUI
import GitHubKit
import PRStackCore

/// What the panel is bound to: one snapshot, the local state over it, and the health of
/// the source that produced it.
///
/// This is not the sync engine. There is no interval table, no power awareness and no
/// backoff here — those are M8, and this deliberately does the least that makes M3
/// demoable against real data: one poll when the panel opens, one more when the refresh
/// control is pressed. `SyncEngine` replaces `refresh()`'s body and nothing else in this
/// file has to move.
@MainActor
final class PanelController: ObservableObject {
    @Published private(set) var panel: PanelPresentation

    private var snapshot: RawSnapshot
    private var local: LocalState
    private var status: PanelStatus
    private var pollTask: Task<Void, Never>?
    /// Bumped per poll, so a late result can tell whether it is still the current one.
    private var pollGeneration = 0

    private let source: any PanelSource
    private let clock: () -> Date

    init(source: any PanelSource, clock: @escaping () -> Date = { Date() }) {
        self.source = source
        self.clock = clock
        snapshot = RawSnapshot(viewerLogin: "", pullRequests: [])
        local = .empty
        status = .unconfigured
        panel = PanelPresentation.make(model: .empty, status: .unconfigured, now: clock())
    }

    // MARK: - Lifecycle

    /// Called when the popover opens. The panel shows what it has immediately and the
    /// poll lands under it — the alternative is a blank panel for as long as GitHub takes,
    /// which is the one thing a menu bar app cannot afford.
    func panelDidOpen() {
        rebuild()
        refresh()
    }

    func panelDidClose() {
        // A poll whose result nobody will see is a poll worth cancelling; the transport
        // observes cancellation, so this actually stops the request.
        pollTask?.cancel()
        pollTask = nil
        if status.isRefreshing {
            status.isRefreshing = false
            rebuild()
        }
    }

    func refresh() {
        guard pollTask == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        status.isRefreshing = true
        rebuild()

        pollTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.source.load()
            self.apply(outcome, from: generation)
        }
    }

    private func apply(_ outcome: PollOutcome, from generation: Int) {
        // A poll cancelled by the panel closing still runs to completion, and can land
        // after the next open has started one. Without this guard its arrival would clear
        // the *live* task's handle, and the poll after that would run alongside it.
        guard generation == pollGeneration else { return }
        pollTask = nil
        status.isRefreshing = false

        switch outcome {
        case .cancelled:
            break
        case .fetched(let fetched):
            snapshot = fetched
            status.github = .connected
            status.lastSyncedAt = clock()
        case .failed(let health):
            // The rows stay. Losing the connection does not make what was fetched untrue,
            // only unverifiable — the banner and the footer say which (§5).
            status.github = health
        }
        rebuild()
    }

    // MARK: - Actions

    /// In memory only at M3. Persisting these, and reaching them from the keyboard, is
    /// M7 — which is also where `LocalState` gets a store to be written to.
    func markAllRead() {
        local.markAllRead(in: snapshot)
        rebuild()
    }

    func dismiss(_ id: PRID) {
        local.dismissed.insert(id)
        rebuild()
    }

    func clearDone() {
        let done = Derivation.derive(snapshot: snapshot, local: local, now: clock())
            .sections
            .first { $0.kind == .done }?
            .rows
            .map(\.id) ?? []
        local.dismissed.formUnion(done)
        rebuild()
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// M7 builds the settings window. Until then the panel says where the token comes
    /// from rather than silently doing nothing when the button is pressed.
    func openSettings() {
        let alert = NSAlert()
        alert.messageText = "Settings arrive with M7"
        alert.informativeText = """
        Until then PRStackMonitor reads its GitHub token from $PRSTACK_GITHUB_TOKEN, then \
        $GITHUB_TOKEN, then the login keychain under \(KeychainTokenStore.defaultService).
        """
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Derivation

    private func rebuild() {
        let now = clock()
        panel = PanelPresentation.make(
            model: Derivation.derive(snapshot: snapshot, local: local, now: now),
            status: status,
            now: now
        )
    }
}

/// What one poll produced.
enum PollOutcome: Sendable {
    case fetched(RawSnapshot)
    case failed(SourceHealth)
    /// The panel closed mid-poll. Distinct from a failure: nothing is known to be wrong,
    /// so neither the banner nor the footer should claim anything.
    case cancelled
}

/// Where a panel's rows come from. One implementation talks to GitHub; a preview passes
/// a fixture.
protocol PanelSource: Sendable {
    func load() async -> PollOutcome
}

/// One GraphQL poll, mapped to an outcome the panel can render.
struct GitHubPanelSource: PanelSource {
    var scope: RepoScope = .all

    func load() async -> PollOutcome {
        let client = GitHubClient(
            transport: URLSessionTransport.standard(),
            tokenProvider: FirstAvailableTokenProvider([
                EnvironmentTokenProvider(),
                KeychainTokenStore(account: .github)
            ])
        )

        do {
            return .fetched(try await client.fetchPullRequests(scope: scope).snapshot)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            // Cancelling the task cancels the URLSession task, which surfaces here rather
            // than as a `CancellationError`.
            return .cancelled
        } catch let error as GitHubError {
            switch error {
            case .missingToken:
                return .failed(.unconfigured)
            case _ where error.isAuthenticationFailure:
                return .failed(.unauthorized(error.description))
            default:
                return .failed(.unreachable(error.description))
            }
        } catch {
            return .failed(.unreachable(error.localizedDescription))
        }
    }
}

extension PanelModel {
    static let empty = PanelModel(
        sections: [],
        showsRepoNames: false,
        attentionCount: 0,
        unreadCount: 0,
        summary: PanelSummary(openCount: 0, shippingCount: 0)
    )
}
