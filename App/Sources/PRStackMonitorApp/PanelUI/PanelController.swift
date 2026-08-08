import AppKit
import Combine
import SwiftUI
import GitHubKit
import LinearKit
import NetKit
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

    /// The model from the last derivation, held in memory and **never persisted**, so a
    /// relaunch replays no history (IMPLEMENTATION_PLAN §1). `SyncEngine` takes this over
    /// at M8.
    private var previous: PanelModel?
    /// The status the previous derivation ran under, for the connection transitions that
    /// cannot come out of a snapshot.
    private var previousStatus: PanelStatus?
    /// The read digests as they stood *before* this open, while the panel is open.
    ///
    /// Opening rewrites the digests — that is what clears unread — but the rows on screen
    /// have to keep the dots that made the user open it. So the authoritative `local` is
    /// rewritten immediately and the panel derives against this copy until it closes.
    /// Reading unread off the rewritten digests instead would blank every dot in the frame
    /// the panel appears in, which is the one frame they exist for.
    private var digestsWhileOpen: [PRID: ReadDigest]?

    private let source: any PanelSource
    private let clock: () -> Date
    private let events: EventBus

    init(source: any PanelSource, events: EventBus, clock: @escaping () -> Date = { Date() }) {
        self.source = source
        self.events = events
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
        // Unread is "changed since the panel was last open", so opening is what rewrites
        // the digests — including the rows the poll below is about to refresh, which get
        // rewritten again when it lands. The icon drops out of `unread` from here; it
        // never drops out of action-needed, which only the pull requests can clear.
        digestsWhileOpen = local.readDigests
        local.markAllRead(in: snapshot)
        rebuild()
        refresh()
    }

    func panelDidClose() {
        // A poll whose result nobody will see is a poll worth cancelling; the transport
        // observes cancellation, so this actually stops the request.
        pollTask?.cancel()
        pollTask = nil
        digestsWhileOpen = nil
        status.isRefreshing = false
        rebuild()
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
        case .fetched(let fetched, let linear):
            snapshot = fetched
            status.github = .connected
            status.lastSyncedAt = clock()
            // Nil means the Linear half learned nothing this poll, so the footer keeps
            // whatever it was already saying rather than being reset to healthy.
            if let linear { status.linear = linear }
            // A poll that lands while the panel is open has been seen, so it is read.
            // `digestsWhileOpen` stays frozen at the open, so the dots for it still appear
            // on screen — what this clears is the menu bar, which would otherwise light up
            // for activity the user is looking straight at.
            if digestsWhileOpen != nil {
                local.markAllRead(in: snapshot)
            }
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
        // Unlike opening, this one is asked for explicitly, so the dots go now rather than
        // at the next open — an action that visibly does nothing has been pressed twice.
        // Only while the panel is open: with it closed there is nothing frozen to update,
        // and writing one here would freeze the digests outside an open.
        if digestsWhileOpen != nil { digestsWhileOpen = local.readDigests }
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

        The Linear API key comes from $PRSTACK_LINEAR_KEY, then $LINEAR_API_KEY, then the \
        same keychain. Without one, every row is grouped under Other.
        """
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Derivation

    private func rebuild() {
        let now = clock()

        // While the panel is open the rows are compared against the digests as they stood
        // at the open, not against the ones that open rewrote.
        var deriving = local
        if let digestsWhileOpen { deriving.readDigests = digestsWhileOpen }

        let derived = Derivation.derive(snapshot: snapshot, local: deriving, previous: previous, now: now)
        // Connection transitions are diffed here rather than in derivation: a poll that
        // failed produces no snapshot to diff, and the model is unchanged precisely
        // because it failed.
        let connection = DomainEvent.connectionEvents(from: previousStatus, to: status)
        previous = derived.model
        previousStatus = status

        panel = PanelPresentation.make(model: derived.model, status: status, now: now)
        events.publish(
            connection + derived.events,
            context: EventContext(
                model: derived.model,
                status: status,
                icon: IconState.resolve(
                    github: status.github,
                    attentionCount: derived.model.attentionCount,
                    unreadCount: liveUnreadCount(in: derived.model)
                )
            )
        )
    }

    /// Unread as the *menu bar* reads it: against the authoritative digests rather than
    /// the frozen copy an open panel renders from.
    ///
    /// With the panel closed the two are the same value. With it open this is zero until
    /// something new actually lands, which is what "opening the panel clears unread"
    /// means for the icon while the dots stay on screen underneath it.
    private func liveUnreadCount(in model: PanelModel) -> Int {
        model.rows.filter { row in
            local.readDigests[row.id] != ReadDigest.make(
                for: row.pullRequest,
                releaseStage: row.releaseStage
            )
        }.count
    }
}

/// What one poll produced.
enum PollOutcome: Sendable {
    /// The snapshot, plus what the poll learned about Linear. Linear health is nil when
    /// the poll learned nothing about it — the request was cancelled, or there was nothing
    /// to resolve.
    case fetched(RawSnapshot, linear: SourceHealth?)
    /// GitHub failed. Linear is not reported here: this poll never got far enough to ask
    /// it, and marking it stale for GitHub's failure would blame the wrong source.
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
///
/// Two requests, in that order: GitHub for the pull requests, then Linear for the issues
/// the identifiers in them name. Sequential rather than parallel because on a cold start
/// there are no identifiers to resolve until GitHub has answered (IMPLEMENTATION_PLAN §1).
struct GitHubPanelSource: PanelSource {
    var scope: RepoScope = .all

    func load() async -> PollOutcome {
        let client = GitHubClient(
            transport: URLSessionTransport.standard(),
            tokenProvider: FirstAvailableTokenProvider([
                EnvironmentTokenProvider.github(),
                KeychainTokenStore(account: .github)
            ], service: "GitHub")
        )

        do {
            let fetch = try await client.fetchPullRequests(scope: scope)
            // Linear never fails the poll. It cannot: every row is already complete without
            // it, and losing it costs only the project headings for identifiers that have
            // never been cached (IMPLEMENTATION_PLAN §4).
            let resolution = await LinearPanelSource.resolve(fetch.pullRequests)
            return .fetched(
                RawSnapshot(viewerLogin: fetch.viewerLogin, pullRequests: resolution.pullRequests),
                linear: resolution.health
            )
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

/// The Linear half of a poll, and where its cache lives.
enum LinearPanelSource {
    static func resolve(_ pullRequests: [PullRequest]) async -> LinearResolution {
        let resolver = LinearResolver(
            client: LinearClient(
                transport: URLSessionTransport.standard(),
                tokenProvider: FirstAvailableTokenProvider([
                    EnvironmentTokenProvider.linear(),
                    KeychainTokenStore(account: .linear)
                ], service: "Linear")
            ),
            store: FileLinearProjectCacheStore(url: cacheURL)
        )
        return await resolver.resolve(pullRequests: pullRequests, now: Date())
    }

    /// `~/Library/Application Support/PRStackMonitor/linear-cache.json`.
    ///
    /// Its own file for now. IMPLEMENTATION_PLAN §3 puts the Linear project cache inside
    /// `state.json`, and M7 — which is where the rest of `LocalState` gains a store — is
    /// where it moves. Writing it there today would mean inventing the state file's
    /// reader, writer and schema version a milestone early, for the one field that already
    /// knows how to look after itself.
    private static var cacheURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("PRStackMonitor", isDirectory: true)
            .appendingPathComponent("linear-cache.json")
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
