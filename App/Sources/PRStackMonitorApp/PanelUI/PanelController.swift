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
/// It is not the scheduler either. ``SyncEngine`` decides *when* a poll happens — the
/// interval table, sleep, battery, backoff — and calls in; everything about *what* a poll
/// does, and every write to `LocalState`, stays here, so there is still exactly one writer
/// of `state.json` and one place the network is touched.
@MainActor
final class PanelController: ObservableObject {
    @Published private(set) var panel: PanelPresentation

    /// The row under the pointer, and the target of every keyboard action (§5).
    ///
    /// Held here rather than as `@State` in the view because the key monitor is an AppKit
    /// object outside the view tree: it has to be able to ask what the pointer is on
    /// without owning the answer.
    @Published var hovered: PRID?

    /// What the `Settings` buttons and the reconnect banner call.
    ///
    /// A closure rather than a reference to the window controller, so the panel keeps
    /// knowing nothing about windows — and so a preview can pass an empty one.
    var onOpenSettings: () -> Void = {}

    private var snapshot: RawSnapshot
    private var local: LocalState
    private var status: PanelStatus
    private var pollTask: Task<Void, Never>?
    /// Bumped per poll, so a late result can tell whether it is still the current one.
    private var pollGeneration = 0

    /// The model from the last derivation, held in memory and **never persisted**, so a
    /// relaunch replays no history (IMPLEMENTATION_PLAN §1).
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
    /// The single writer of `state.json`. Everything that mutates `local` goes through
    /// ``persist()`` immediately afterwards, so a crash costs at most the change in flight
    /// (IMPLEMENTATION_PLAN §3).
    private let store: any StateStore
    /// When to poll. Held here because everything that changes the answer — the panel
    /// opening, a merge waiting for a tag, a source failing — is observed here.
    private let engine: SyncEngine

    init(
        source: any PanelSource,
        events: EventBus,
        store: any StateStore = FileStateStore(url: FileStateStore.defaultURL()),
        engine: SyncEngine = SyncEngine(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.source = source
        self.events = events
        self.store = store
        self.engine = engine
        self.clock = clock
        snapshot = RawSnapshot(viewerLogin: "", pullRequests: [])
        status = .unconfigured

        // Dismissals, snoozes, read digests, release bindings and the merges still waiting
        // for a tag, as the last launch left them. A file that could not be read has already
        // been moved aside by the store, so this is empty rather than half-read.
        let loaded = store.load()
        local = loaded.state
        if let failure = loaded.failure {
            let moved = loaded.quarantinedTo.map { " It was moved to \($0.lastPathComponent)." } ?? ""
            NSLog("PRStackMonitor: starting from empty local state — %@.%@", failure, moved)
        }

        panel = PanelPresentation.make(model: .empty, status: .unconfigured, now: clock())

        // The engine says when; this says what. Every poll in the app's life comes through
        // here, including the first one and the manual ones, so there is one path to reason
        // about rather than a scheduled path and a hand-rolled one beside it.
        engine.onPoll = { [weak self] in self?.poll() }
        // The merges the last launch left waiting decide the interval before the first poll
        // has landed: a release tag cut while the app was closed is found at 60 s, not 5 min.
        engine.setAwaitingRelease(!local.unboundMerges.isEmpty)
    }

    // MARK: - Lifecycle

    /// Starts the scheduler, which polls once immediately: the menu bar icon has to mean
    /// something before the panel has ever been opened.
    func start() {
        engine.start()
    }

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
        persist()
        // Row 3 of the interval table. Set before the poll below, so the 30-second cadence
        // is what the poll it starts is measured from.
        engine.setPanelOpen(true)
        rebuild()
        refresh()
    }

    func panelDidClose() {
        // A poll whose result nobody will see is a poll worth cancelling; the transport
        // observes cancellation, so this actually stops the request.
        pollTask?.cancel()
        pollTask = nil
        digestsWhileOpen = nil
        // The pointer is not over anything once there is nothing to be over. Left set, the
        // next open would begin with a keyboard target the user cannot see.
        hovered = nil
        status.isRefreshing = false
        engine.setPanelOpen(false)
        rebuild()
    }

    /// The refresh control, and the poll an open panel starts with.
    ///
    /// Through the engine rather than straight into ``poll()``, because a manual refresh
    /// restarts the current interval's timer from zero — pressing it at second 29 must not
    /// be followed by a scheduled poll one second later.
    func refresh() {
        engine.refreshNow()
    }

    private func poll() {
        guard pollTask == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        status.isRefreshing = true
        rebuild()

        // The state the poll reads — its unbound merges bound the closed search and give the
        // release tracker its work list. A value copy: the poll never writes local state,
        // it hands back what it found and this actor merges it (IMPLEMENTATION_PLAN §3).
        let plan = PollPlan(
            local: local,
            now: clock(),
            // A backing-off Linear still resolves from cache; what it skips is the request.
            resolvesLinear: engine.resolvesLinear
        )
        pollTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.source.load(plan)
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
        case .fetched(let product):
            snapshot = product.snapshot
            status.github = .connected
            status.lastSyncedAt = clock()
            // Nil means the Linear half learned nothing this poll, so the footer keeps
            // whatever it was already saying rather than being reset to healthy.
            if let linear = product.linear { status.linear = linear }
            // The merge commits this poll saw, then the releases they were found in. Both
            // are written here and nowhere else — the tracker hands its bindings back
            // rather than writing the file from its own task.
            local.recordMerges(from: snapshot.pullRequests)
            local.apply(product.release)
            // Deadlines that have passed are already awake as far as derivation is
            // concerned; dropping them here is what stops the file accumulating an entry
            // per pull request the user has ever silenced.
            local.pruneSnoozes(before: clock())
            // What Settings offers as the repository checklist. Recorded from the poll
            // rather than asked for separately — these are exactly the repositories the
            // user authors pull requests in (IMPLEMENTATION_PLAN §3).
            AppDefaults.noteRepositories(snapshot.pullRequests.map(\.repo))
            // A poll that lands while the panel is open has been seen, so it is read.
            // `digestsWhileOpen` stays frozen at the open, so the dots for it still appear
            // on screen — what this clears is the menu bar, which would otherwise light up
            // for activity the user is looking straight at.
            if digestsWhileOpen != nil {
                local.markAllRead(in: snapshot)
            }
            persist()
            for warning in product.warnings {
                NSLog("PRStackMonitor: %@", warning.description)
            }
            // What the next interval is decided from. Each source's health separately, so a
            // Linear outage backs Linear off and leaves GitHub's cadence alone; then the
            // two table rows that come out of the data.
            engine.record(.connected, for: .github)
            if let linear = product.linear { engine.record(linear, for: .linear) }
            engine.setAwaitingRelease(!local.unboundMerges.isEmpty)
            // "Recently active" reads the pull requests' own timestamps rather than a note
            // this app takes when it happens to notice something. That way it survives a
            // relaunch, and a stack somebody else is pushing to counts as activity even on
            // the poll that first sees it.
            engine.noteActivity(at: snapshot.pullRequests.map(\.updatedAt).max())
        case .failed(let health):
            // The rows stay. Losing the connection does not make what was fetched untrue,
            // only unverifiable — the banner and the footer say which (§5).
            status.github = health
            engine.record(health, for: .github)
        }
        rebuild()
    }

    // MARK: - Actions

    /// Every one of these survives a relaunch: each writes `state.json` through
    /// ``persist()`` immediately, so a crash costs at most the change in flight.
    ///
    /// Each is reachable three ways — pointer, key, and VoiceOver rotor — and all three
    /// land here rather than each growing its own copy of the rule.
    func markAllRead() {
        local.markAllRead(in: snapshot)
        persist()
        // Unlike opening, this one is asked for explicitly, so the dots go now rather than
        // at the next open — an action that visibly does nothing has been pressed twice.
        // Only while the panel is open: with it closed there is nothing frozen to update,
        // and writing one here would freeze the digests outside an open.
        if digestsWhileOpen != nil { digestsWhileOpen = local.readDigests }
        rebuild()
    }

    /// One row, on demand — the `R` key and the row menu.
    ///
    /// Unlike ``markAllRead()`` this is about a row the user is looking at, so it also
    /// rewrites the frozen copy the open panel derives from: leaving the dot on a row the
    /// user just marked read is the same failure as an action that visibly does nothing.
    func markRead(_ id: PRID) {
        local.markRead(CollectionOfOne(id), in: snapshot)
        persist()
        if digestsWhileOpen != nil { digestsWhileOpen = local.readDigests }
        rebuild()
    }

    func dismiss(_ id: PRID) {
        // Tombstone plus release cleanup, in `LocalState` so the two cannot drift apart
        // here and in `clearDone`.
        local.dismiss(id)
        persist()
        rebuild()
    }

    /// Suppresses a row's attention state until the duration's wake time.
    ///
    /// The deadline is resolved here, from the injected clock, rather than in the menu —
    /// so "until Monday" means the same thing whichever of the three paths asked for it.
    func snooze(_ id: PRID, for duration: SnoozeDuration) {
        local.snooze(id, until: duration.wakeTime(from: clock()))
        persist()
        rebuild()
    }

    /// Ends a snooze early. The row resumes full derivation on the next rebuild, which is
    /// this one.
    func wake(_ id: PRID) {
        local.wake(id)
        persist()
        rebuild()
    }

    func clearDone() {
        let done = Derivation.derive(snapshot: snapshot, local: local, now: clock())
            .sections
            .first { $0.kind == .done }?
            .rows
            .map(\.id) ?? []
        local.dismiss(done)
        persist()
        rebuild()
    }

    /// Writes `state.json`. Called after every mutation of `local`, and from nowhere else.
    ///
    /// A failed write is logged rather than surfaced: the panel is still correct for this
    /// session, and there is nothing the user can do about a full disk from inside a popover.
    /// The one failure that matters — a file that could not be read *and* could not be moved
    /// aside — is refused by the store itself, so this never overwrites state it could not
    /// read.
    private func persist() {
        do {
            try store.save(local)
        } catch {
            NSLog("PRStackMonitor: could not save local state — %@", String(describing: error))
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Clicking a row opens the pull request **and marks it read** (PRD §8).
    ///
    /// The two belong together: the dot means "changed since you last looked", and having
    /// just looked is exactly what a click is. Opening the URL without this leaves a dot on
    /// the one row the user can be certain has been seen.
    func open(row: RowPresentation) {
        open(row.url)
        markRead(row.id)
    }

    /// The row as the panel currently presents it, for the callers that hold only an id —
    /// the key monitor, and the menu it pops up.
    func row(_ id: PRID) -> RowPresentation? {
        guard case .sections(let sections) = panel.body else { return nil }
        for section in sections {
            if let row = section.rows.first(where: { $0.id == id }) { return row }
        }
        return nil
    }

    /// The row under the pointer, when there is one and it is still on screen.
    var hoveredRow: RowPresentation? {
        hovered.flatMap(row)
    }

    func openSettings() {
        onOpenSettings()
    }

    /// Called when Settings closes, and when a credential changes under it.
    ///
    /// Nothing to invalidate: the scope and the patterns are read from `UserDefaults` at the
    /// top of every poll. What there is, is a poll to bring forward — and one to abandon.
    /// A poll already in flight was started under the configuration the user has just
    /// replaced, and ``poll()`` would decline to start another while it ran, leaving the
    /// panel on the old scope's results until the next open. Cancelling is safe: the
    /// generation guard in ``apply(_:from:)`` drops the late arrival.
    ///
    /// This is the reconnect path, so it clears both sources' backoff: either credential
    /// may have been the one replaced, and a token pasted in Settings must be tried now
    /// rather than after however long the last failure had earned.
    func settingsDidChange() {
        pollTask?.cancel()
        pollTask = nil
        engine.reconnect()
    }

    // MARK: - Derivation

    private func rebuild() {
        let now = clock()

        // While the panel is open the rows are compared against the digests as they stood
        // at the open, not against the ones that open rewrote.
        var deriving = local
        if let digestsWhileOpen { deriving.readDigests = digestsWhileOpen }

        // What the footer measures staleness against: data older than one interval is
        // behind its own schedule, whatever that schedule currently is (§4).
        status.pollInterval = engine.schedule.interval

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
    case fetched(PollProduct)
    /// GitHub failed. Linear is not reported here: this poll never got far enough to ask
    /// it, and marking it stale for GitHub's failure would blame the wrong source.
    case failed(SourceHealth)
    /// The panel closed mid-poll. Distinct from a failure: nothing is known to be wrong,
    /// so neither the banner nor the footer should claim anything.
    case cancelled
}

/// A successful poll: the rows, what it learned about Linear, and what it learned about
/// releases.
struct PollProduct: Sendable {
    var snapshot: RawSnapshot
    /// Nil when the poll learned nothing about Linear: no request was sent — nothing to
    /// resolve, or every identifier already cached — or the one that was sent was
    /// cancelled. The footer then keeps whatever it was already saying, rather than being
    /// reset to healthy by a poll that never checked.
    var linear: SourceHealth?
    /// Bindings and durable negatives, for the main actor to merge into `LocalState`.
    var release: ReleaseTrackerResult = .empty
    var warnings: [FetchWarning] = []
}

/// One poll's instructions.
///
/// `local` is here because two things depend on it: the closed search's lower bound, and
/// the release tracker's work list. It comes back untouched — the source returns findings,
/// the panel controller is the only writer.
struct PollPlan: Sendable {
    var local: LocalState
    var now: Date
    /// False while Linear is backing off. The poll runs either way and the rows still get
    /// their cached project headings; what is deferred is the request, not the resolution
    /// (IMPLEMENTATION_PLAN §4).
    var resolvesLinear: Bool = true
}

/// Where a panel's rows come from. One implementation talks to GitHub; a preview passes
/// a fixture.
protocol PanelSource: Sendable {
    func load(_ plan: PollPlan) async -> PollOutcome
}

/// One GraphQL poll, mapped to an outcome the panel can render.
///
/// Two requests, in that order: GitHub for the pull requests, then Linear for the issues
/// the identifiers in them name. Sequential rather than parallel because on a cold start
/// there are no identifiers to resolve until GitHub has answered (IMPLEMENTATION_PLAN §1).
struct GitHubPanelSource: PanelSource {
    /// Read per poll rather than held, like the tag patterns below: Settings writes
    /// `UserDefaults` and the next poll picks the change up, so there is no second copy to
    /// keep in step and no invalidation to get wrong.
    var scope: RepoScope { AppDefaults.repoScope() }

    /// One transport for the life of the source, shared by both requests.
    ///
    /// Not per poll. Each `URLSession` brings its own connection pool that outlives the
    /// object, so building one per poll — at 30 s with the panel open, 120 an hour — leaks
    /// pools rather than reusing connections. Apple's guidance is explicit about reusing a
    /// session, and the panel controller holds this source for its whole life.
    let transport = URLSessionTransport.standard()

    /// The validators for the release tracker's `compare` calls, for the same reason and
    /// with the same lifetime as the transport. Losing them on relaunch costs one
    /// uncached request per pair, which the persisted negatives keep to a handful.
    let etags: any ETagStore = InMemoryETagStore()

    func load(_ plan: PollPlan) async -> PollOutcome {
        let credentials = CredentialChain.standard(
            environment: .github(),
            keychain: .github,
            service: "GitHub"
        )
        let poll = GitHubPoll(
            client: GitHubClient(transport: transport, tokenProvider: credentials),
            tracker: TagContainmentTracker(
                transport: transport,
                tokenProvider: credentials,
                configuration: TagContainmentTracker.Configuration(
                    // The map Settings edits. A repository without an entry takes the `v*`
                    // default, which is most of them.
                    tagPatterns: AppDefaults.tagPatterns()
                ),
                // Held for the life of the source, like the transport: a repeated
                // comparison then costs a 304 instead of a request against the REST
                // allowance.
                etagStore: etags
            ),
            // Costs nothing unless a merged pull request arrives without a merge commit,
            // which is rare and otherwise permanent.
            recovery: MergeCommitRecovery(transport: transport, tokenProvider: credentials)
        )

        do {
            let fetched = try await poll.run(scope: scope, local: plan.local, now: plan.now)
            // Linear never fails the poll. It cannot: every row is already complete without
            // it, and losing it costs only the project headings for identifiers that have
            // never been cached (IMPLEMENTATION_PLAN §4).
            let resolution = await LinearPanelSource.resolve(
                fetched.pullRequests,
                over: transport,
                mode: plan.resolvesLinear ? .fetch : .cacheOnly
            )
            return .fetched(
                PollProduct(
                    snapshot: RawSnapshot(
                        viewerLogin: fetched.viewerLogin,
                        pullRequests: resolution.pullRequests
                    ),
                    linear: resolution.health,
                    release: fetched.release,
                    warnings: fetched.warnings
                )
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
    /// Shares the caller's transport — see ``GitHubPanelSource/transport``. The two
    /// integrations talk to different hosts, so they do not contend for a connection, and
    /// one session for the app is what the pooling is for.
    static func resolve(
        _ pullRequests: [PullRequest],
        over transport: any HTTPTransport,
        mode: LinearResolutionMode
    ) async -> LinearResolution {
        let resolver = LinearResolver(
            client: LinearClient(
                transport: transport,
                tokenProvider: CredentialChain.standard(
                    environment: .linear(),
                    keychain: .linear,
                    service: "Linear"
                )
            ),
            store: FileLinearProjectCacheStore(url: cacheURL)
        )
        return await resolver.resolve(pullRequests: pullRequests, now: Date(), mode: mode)
    }

    /// `~/Library/Application Support/PRStackMonitor/linear-cache.json`.
    ///
    /// Its own file, and staying that way. IMPLEMENTATION_PLAN §3 lists the Linear project
    /// cache among `state.json`'s contents, but the two have different writers: `LocalState`
    /// is a single value owned by the main actor and written whole, while the cache is
    /// written from the resolver's own task on a background poll. Folding it in would either
    /// make the resolver a second writer of the state file — the exact hazard §3's
    /// single-writer rule exists to prevent — or route every cache hit through the main actor
    /// to be merged. Nothing derivation reads lives in it, so keeping it beside the state
    /// file costs one extra path and no correctness.
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
