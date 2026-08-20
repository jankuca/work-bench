import Foundation

// The whole panel, resolved: header, banner, body, footer.
//
// Same seam as ``RowPresentation``. What is here is what a test can pin — every string
// the panel shows and every decision about which of the three states (§5) it is in. What
// is not here is geometry, colour and the AppKit hosting.

// MARK: - Source health

/// How a data source is doing, as far as the panel is concerned.
///
/// The distinction that earns its keep is ``unauthorized`` versus ``unreachable``: only
/// the first raises the reconnect banner and — for GitHub — the dashed menu bar glyph,
/// and only the second is worth retrying with backoff (IMPLEMENTATION_PLAN §4).
public enum SourceHealth: Equatable, Sendable {
    /// Never connected. First run, or the token was removed.
    case unconfigured
    case connected
    /// Credentials rejected. The rows on screen are cached, and stay on screen — the
    /// banner comes off the top of the panel, not the data out of it.
    case unauthorized(String)
    /// Network, rate limit, anything transient. No banner; the footer goes stale.
    case unreachable(String)

    public var isConnected: Bool { self == .connected }

    /// Whether the last attempt found nothing to authenticate with.
    ///
    /// Only ever a statement about that attempt. "Is there a credential at all?" — the
    /// question the connect prompt asks — is ``PanelStatus/hasGitHubCredential``, because
    /// before the first poll there has been no attempt to read this from.
    public var isUnconfigured: Bool { self == .unconfigured }

    /// Whether this source's failure is the user's to fix.
    public var needsReconnect: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .unconfigured, .connected: return nil
        case .unauthorized(let message), .unreachable(let message): return message
        }
    }
}

/// Everything outside the snapshot that the panel chrome reads.
///
/// Assembled by whoever is polling: the health of each source, when the last poll
/// succeeded, and — since M8 — how often the next one is due, which is what the footer
/// measures staleness against.
public struct PanelStatus: Equatable, Sendable {
    public var github: SourceHealth
    /// Linear's health is a **footer condition, never a banner and never an icon state**.
    ///
    /// Losing Linear costs the panel its project headings for identifiers it has never
    /// cached, and nothing else: every row still renders, with its status, its checks and
    /// its reviewers, and cached headings stay put (IMPLEMENTATION_PLAN §2/§4). Raising
    /// the reconnect banner over that would be claiming the list is untrustworthy when
    /// only its section titles are.
    public var linear: SourceHealth
    public var lastSyncedAt: Date?
    /// A poll in flight. The header's refresh control spins on it.
    public var isRefreshing: Bool
    /// The interval the scheduler is currently polling at (``SyncSchedule/interval``), or
    /// nil while it is suspended or before one has been chosen.
    ///
    /// The footer reads it so that "stale" means *behind its own schedule* rather than a
    /// fixed age: five-minute-old data is current when the machine is on battery at 15
    /// minutes, and a laptop that woke from an overnight sleep is stale the moment it does,
    /// without waiting for a threshold to expire (IMPLEMENTATION_PLAN §4).
    public var pollInterval: TimeInterval?
    /// Whether a GitHub credential exists at all, whatever the last poll made of it.
    ///
    /// Health cannot answer this, and the connect prompt is the one place that has to ask.
    /// ``SourceHealth`` records how the last *attempt* went, and there are two states where
    /// no attempt has said anything about the credential: before the first poll, where the
    /// app starts every source at ``SourceHealth/unconfigured`` because nothing has been
    /// tried yet, and after a poll that failed for another reason. So this is supplied by
    /// whoever holds the credentials — for the app, the same chain a poll reads — and
    /// defaults to what health implies for callers that have nothing better.
    public var hasGitHubCredential: Bool
    /// Whether a Linear credential exists at all. See ``hasGitHubCredential``.
    ///
    /// Linear needs this more than GitHub does: a poll that fails at GitHub never gets far
    /// enough to ask Linear, so Linear's health stays ``SourceHealth/unconfigured`` for as
    /// long as GitHub is down, however long the key has been in the Keychain.
    public var hasLinearCredential: Bool

    public init(
        github: SourceHealth,
        linear: SourceHealth = .unconfigured,
        lastSyncedAt: Date? = nil,
        isRefreshing: Bool = false,
        pollInterval: TimeInterval? = nil,
        hasGitHubCredential: Bool? = nil,
        hasLinearCredential: Bool? = nil
    ) {
        self.github = github
        self.linear = linear
        self.lastSyncedAt = lastSyncedAt
        self.isRefreshing = isRefreshing
        self.pollInterval = pollInterval
        // Nil means "whatever health implies", which is right for everything that reports a
        // credential by reporting an attempt to use one: a rejected token is a token, and
        // `.unconfigured` came back from a poll that looked for one and found none.
        self.hasGitHubCredential = hasGitHubCredential ?? !github.isUnconfigured
        self.hasLinearCredential = hasLinearCredential ?? !linear.isUnconfigured
    }

    /// Records what a poll made of GitHub, keeping the credential flag in step.
    ///
    /// A poll that ran is the one thing that *does* answer both questions at once: it went
    /// looking for a credential, so whether it found one is settled — and settled by the
    /// same call, rather than by two assignments that can be made to disagree.
    public mutating func record(github health: SourceHealth) {
        github = health
        hasGitHubCredential = !health.isUnconfigured
    }

    /// Records what a poll made of Linear. See ``record(github:)``.
    public mutating func record(linear health: SourceHealth) {
        linear = health
        hasLinearCredential = !health.isUnconfigured
    }

    public static let unconfigured = PanelStatus(github: .unconfigured, linear: .unconfigured)

    /// The status a fixture renders under: connected, synced 34 seconds ago — the footer
    /// design 2a shows.
    ///
    /// A fixture carries no sync history, and reading the wall clock for one would make
    /// two renderings of the same file differ. This lives here rather than in either
    /// caller because `prstack-dump --presentation` and the presentation goldens have to
    /// agree byte for byte, and two copies of the same constant is how that quietly stops
    /// being true.
    public static func fixture(now: Date) -> PanelStatus {
        PanelStatus(github: .connected, linear: .connected, lastSyncedAt: now.addingTimeInterval(-34))
    }

    /// Data older than this reads as stale rather than current. Five minutes is two
    /// missed polls at M8's foreground interval, which is the point at which "synced 6m
    /// ago" stops being a detail and starts being a warning.
    public static let staleAfter: TimeInterval = 5 * 60

    /// How old the data may be before the footer calls it stale: one poll interval, but
    /// never less than ``staleAfter``.
    ///
    /// The floor is what keeps a 30-second panel-open interval from declaring 40-second-old
    /// rows stale — a single skipped tick is not a problem worth a warning. Above it the
    /// interval leads, so a cadence the user cannot see is not silently held to a
    /// five-minute promise it never made.
    public var staleThreshold: TimeInterval {
        max(PanelStatus.staleAfter, pollInterval ?? 0)
    }
}

// MARK: - Pieces

public struct HeaderPresentation: Equatable, Sendable {
    public var title: String
    /// `10 in review · 2 drafts · 3 shipping`. Empty when there is nothing to count.
    public var summary: String
    public var isRefreshing: Bool

    public init(title: String, summary: String, isRefreshing: Bool) {
        self.title = title
        self.summary = summary
        self.isRefreshing = isRefreshing
    }
}

/// The amber strip over cached rows.
public struct BannerPresentation: Equatable, Sendable {
    public var message: String
    public var actionTitle: String

    public init(message: String, actionTitle: String) {
        self.message = message
        self.actionTitle = actionTitle
    }
}

public struct SectionPresentation: Equatable, Sendable {
    public var kind: PanelSection.Kind
    public var heading: String
    public var count: Int
    /// Done is grey, projects are not. Colour means status, so a project heading never
    /// takes one (PRD §11) — this is a two-value tone, not a palette.
    public var isMuted: Bool
    /// `Clear all`, on Done only.
    public var clearAllTitle: String?
    public var rows: [RowPresentation]

    public init(
        kind: PanelSection.Kind,
        heading: String,
        count: Int,
        isMuted: Bool,
        clearAllTitle: String?,
        rows: [RowPresentation]
    ) {
        self.kind = kind
        self.heading = heading
        self.count = count
        self.isMuted = isMuted
        self.clearAllTitle = clearAllTitle
        self.rows = rows
    }
}

public struct FooterPresentation: Equatable, Sendable {
    public var syncTone: StatusTone
    /// `synced 34s ago`, `stale · last synced 41m ago`, `never synced`, `syncing…`.
    public var syncText: String
    /// A poll is in flight *right now*.
    ///
    /// Separate from ``syncText`` saying so, because the two answer different questions and
    /// the view needs both: the text is what the footer reads at a glance, and this is what
    /// lets it be drawn as activity rather than as another resting state.
    public var isSyncing: Bool
    /// Why the source is unhappy, when it is — the view shows it on hover.
    ///
    /// Kept off ``syncText`` deliberately. "could not reach GitHub: the request timed
    /// out" is the wrong length for a 11 pt footer and the wrong altitude for a glance,
    /// but it is the first thing wanted once the glance has raised a question, and the
    /// panel is the only place it exists.
    public var detail: String?
    /// The current GitHub failure, said out loud on a line of its own.
    ///
    /// ``detail`` is the same text on hover, and hover is not good enough on its own: a
    /// failing poll is exactly the moment the user is asking *why*, and a tooltip is
    /// something you have to already suspect in order to find. So a transient failure gets
    /// a line under the footer for as long as it lasts.
    ///
    /// GitHub only, and never when ``BannerPresentation`` is already up: an expired token
    /// is stated at the top of the panel next to the button that fixes it, and repeating it
    /// at the bottom would spend a second line on the one failure already handled. Linear
    /// keeps ``linearNote`` and the hover detail — its failures cost the panel its project
    /// headings and nothing else, which is not worth a line (IMPLEMENTATION_PLAN §4).
    public var errorMessage: String?
    /// `Linear stale`, `Linear disconnected`. Nil while Linear is healthy, and nil while
    /// no key is configured at all — a source the user has never connected is not stale.
    ///
    /// This is the whole of Linear's presence in the chrome, and deliberately so: an
    /// expired Linear key must not raise the reconnect banner or change the menu bar icon,
    /// because every row on screen is still true (IMPLEMENTATION_PLAN §4). What the user
    /// needs to know is that project headings may be behind, which is a footnote.
    public var linearNote: String?
    /// Hidden when there is nothing unread, so the panel does not offer an action that
    /// would do nothing.
    public var showsMarkAllRead: Bool
    /// The steps of the current-or-last sync, for the popover the sync label opens. Empty
    /// when no sync has ever run — the label is then only a label, with nothing to reveal.
    ///
    /// Kept off ``syncText`` on purpose: the footer's one line answers "how fresh is this?"
    /// at a glance, and the step breakdown — which search is paging, whether tags and Linear
    /// ran — is the detail behind that glance, wanted only when the label is clicked. It
    /// carries the *last* sync's steps between polls, so the breakdown is available at any
    /// time, not only while one happens to be in flight.
    public var progressSteps: [SyncStepPresentation]

    public init(
        syncTone: StatusTone,
        syncText: String,
        isSyncing: Bool = false,
        detail: String? = nil,
        errorMessage: String? = nil,
        linearNote: String? = nil,
        showsMarkAllRead: Bool,
        progressSteps: [SyncStepPresentation] = []
    ) {
        self.syncTone = syncTone
        self.syncText = syncText
        self.isSyncing = isSyncing
        self.detail = detail
        self.errorMessage = errorMessage
        self.linearNote = linearNote
        self.showsMarkAllRead = showsMarkAllRead
        self.progressSteps = progressSteps
    }
}

/// The connect prompt from design 1e.
public struct ConnectPrompt: Equatable, Sendable {
    public var title: String
    public var detail: String
    /// The GitHub button, and **nil when a GitHub credential is already stored**.
    ///
    /// The panel reaches this prompt whenever nothing has ever synced, which is not the
    /// same thing as nothing being connected: a token GitHub rejected, one it could not be
    /// asked about, and a Linear key no failing poll got as far as using all arrive here
    /// with a credential already in place. Offering to connect an account that is connected
    /// sends the user to fix something that is not broken — and where it *is* broken, the
    /// reconnect banner is already pointing at the fix.
    public var githubActionTitle: String?
    /// The Linear button, nil on the same terms as ``githubActionTitle``.
    public var linearActionTitle: String?

    public init(
        title: String,
        detail: String,
        githubActionTitle: String? = nil,
        linearActionTitle: String? = nil
    ) {
        self.title = title
        self.detail = detail
        self.githubActionTitle = githubActionTitle
        self.linearActionTitle = linearActionTitle
    }
}

public struct AllClearMessage: Equatable, Sendable {
    public var title: String
    public var detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

/// One line of the sync checklist the footer's label opens: a labelled step, its state, and
/// its running count.
///
/// A skipped step never becomes one of these — it is dropped from the list entirely, the
/// same way the connect prompt drops the button for an account that is already connected.
/// So the state here is only the three a visible step can be in.
public struct SyncStepPresentation: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Not started. Shown only for the two searches, which always run.
        case pending
        case active
        case done
    }

    public var stage: SyncStage
    public var title: String
    public var state: State
    /// `12 of 47`, `8 merges`, or nil while a step is only pending. The counterpart of the
    /// footer's `synced 34s ago`: what the step is doing, said in the fewest words that
    /// still carry a number.
    public var detail: String?

    public init(stage: SyncStage, title: String, state: State, detail: String? = nil) {
        self.stage = stage
        self.title = title
        self.state = state
        self.detail = detail
    }
}

// MARK: - Panel

public struct PanelPresentation: Equatable, Sendable {
    /// The three states §5 builds, as one value the view switches over. Making them
    /// mutually exclusive here is what stops the view rendering an empty list *and* a
    /// connect prompt, which is what "the list is empty" and "there is no account" would
    /// otherwise both look like.
    public enum Body: Equatable, Sendable {
        case sections([SectionPresentation])
        /// Connected, nothing to show. A stated message, not an empty list.
        case allClear(AllClearMessage)
        /// Never connected. No rows exist to be honest or stale about.
        case connect(ConnectPrompt)
    }

    public var header: HeaderPresentation
    public var banner: BannerPresentation?
    public var body: Body
    public var footer: FooterPresentation
    /// The red badge's count, which the menu bar icon reads at M4. Zero while GitHub is
    /// disconnected: every attention row on screen is cached, and a badge counting
    /// unverifiable failures asserts something the app cannot currently check (§5).
    public var attentionCount: Int

    public init(
        header: HeaderPresentation,
        banner: BannerPresentation?,
        body: Body,
        footer: FooterPresentation,
        attentionCount: Int
    ) {
        self.header = header
        self.banner = banner
        self.body = body
        self.footer = footer
        self.attentionCount = attentionCount
    }

    /// `syncProgress` feeds the sync popover the footer's label opens — the current sync's
    /// steps while one runs, the last sync's between them. It never touches the body: the
    /// content area's connect/all-clear/sections decision is exactly what it was, which is why
    /// every existing caller and golden is unaffected by passing nil.
    public static func make(
        model: PanelModel,
        status: PanelStatus,
        now: Date,
        syncProgress: SyncProgress? = nil
    ) -> PanelPresentation {
        let sections = model.sections.map { section in
            SectionPresentation(
                kind: section.kind,
                heading: heading(for: section.kind),
                count: section.rows.count,
                isMuted: section.kind == .done,
                clearAllTitle: section.kind == .done ? "Clear all" : nil,
                rows: section.rows.map {
                    RowPresentation.make(row: $0, showsRepoName: model.showsRepoNames, now: now)
                }
            )
        }

        return PanelPresentation(
            header: HeaderPresentation(
                title: "Pull requests",
                summary: summary(for: model.summary),
                isRefreshing: status.isRefreshing
            ),
            banner: banner(for: status.github),
            body: body(sections: sections, status: status),
            footer: footer(
                model: model,
                status: status,
                now: now,
                progressSteps: syncProgress.map { progressSteps(from: $0) } ?? []
            ),
            attentionCount: status.github.isConnected ? model.attentionCount : 0
        )
    }

    // MARK: Body

    private static func body(sections: [SectionPresentation], status: PanelStatus) -> Body {
        if !sections.isEmpty { return .sections(sections) }
        // "Everything's clear" is a claim about the user's pull requests, so the panel may
        // only make it once it has actually seen them. What licenses the claim is a
        // *completed sync*, not the health of the connection right now:
        //
        // - Synced, found nothing, and the poll since then failed → still true. The list
        //   was empty when it was last verified and the footer says how long ago.
        // - Never synced → not known to be true, whatever the reason. Saying it anyway is
        //   the stale-as-fresh reading PRD §4 forbids, and there is no cached list to be
        //   stale about.
        //
        // Reading the current health instead gets the first case wrong: one timed-out poll
        // would replace a legitimate all-clear with "Connect your accounts", offering to
        // fix an account that is already connected.
        guard status.github.isConnected || status.lastSyncedAt != nil else {
            return .connect(connectPrompt(for: status))
        }
        return .allClear(
            AllClearMessage(
                title: "Everything's clear",
                detail: "No open pull requests need you."
            )
        )
    }

    /// The empty panel that has never synced, offering only the accounts actually missing.
    ///
    /// Two different situations arrive here and they need different words. With no GitHub
    /// credential this is the first run design 1e draws, and the prompt is the whole point
    /// of the panel. With one already stored it is a sync that has not happened — the
    /// panel has nothing to show *yet*, and there is nothing for the user to connect. Both
    /// keep the same shape rather than becoming a fourth body state, because what changes
    /// between them is what there is to say and to offer, which is what this decides.
    private static func connectPrompt(for status: PanelStatus) -> ConnectPrompt {
        let needsGitHub = !status.hasGitHubCredential
        let needsLinear = !status.hasLinearCredential

        let title: String
        let detail: String
        switch (needsGitHub, needsLinear) {
        case (true, true):
            title = "Connect your accounts"
            detail = "GitHub for pull requests and release tags, Linear to group them by project."
        case (true, false):
            title = "Connect GitHub"
            detail = "GitHub for pull requests and release tags."
        case (false, _):
            // GitHub is connected and the panel still has nothing, so the missing piece is
            // the sync rather than the account. Its reason comes from the health: the
            // banner above says an expired token in its own words, and the footer carries
            // the transport failure verbatim, so this is the one-line version of whichever
            // of them is up.
            title = "Nothing synced yet"
            switch status.github {
            case .unauthorized: detail = "GitHub rejected the token it has, so nothing has arrived yet."
            case .unreachable: detail = "GitHub could not be reached, so nothing has arrived yet."
            case .unconfigured, .connected: detail = "The first sync has not landed yet."
            }
        }

        return ConnectPrompt(
            title: title,
            detail: detail,
            githubActionTitle: needsGitHub ? "Connect GitHub" : nil,
            linearActionTitle: needsLinear ? "Connect Linear" : nil
        )
    }

    // MARK: Syncing

    /// The sync checklist behind the footer's label — the current sync's steps while one runs,
    /// the last sync's between them.
    ///
    /// A step is shown once it is no longer merely pending — active or done — and always for
    /// the two searches, which run on every poll. A *skipped* step never appears: the tag and
    /// Linear steps only exist when there is work for them, and revealing one and then taking
    /// it away is the flicker this rule avoids. An empty result — the empty-scope poll that
    /// never searched — leaves the label with nothing to open, which is the same as never
    /// having synced.
    static func progressSteps(from progress: SyncProgress) -> [SyncStepPresentation] {
        SyncStage.allCases.compactMap { stage -> SyncStepPresentation? in
            let step = progress.step(stage)
            switch step.lifecycle {
            case .skipped:
                return nil
            case .pending:
                // Only the always-run steps are worth showing before they begin; a
                // conditional one that never began might be about to be skipped.
                guard stage.isAlwaysRun else { return nil }
                return SyncStepPresentation(stage: stage, title: title(for: stage), state: .pending)
            case .active:
                return SyncStepPresentation(
                    stage: stage,
                    title: title(for: stage),
                    state: .active,
                    detail: detail(for: stage, step: step)
                )
            case .done:
                return SyncStepPresentation(
                    stage: stage,
                    title: title(for: stage),
                    state: .done,
                    detail: detail(for: stage, step: step)
                )
            }
        }
    }

    private static func title(for stage: SyncStage) -> String {
        switch stage {
        case .openPullRequests: return "Finding open pull requests"
        case .mergedPullRequests: return "Finding merged pull requests"
        case .releaseTags: return "Checking release tags"
        case .linearProjects: return "Grouping by project"
        }
    }

    /// What the step says beside its title. The searches carry a real "of N" from GitHub's
    /// `issueCount`; the tag and Linear steps carry a plain count of the work in hand, with
    /// its own unit so a bare number never has to stand for two different things.
    private static func detail(for stage: SyncStage, step: SyncProgress.Step) -> String? {
        switch stage {
        case .openPullRequests, .mergedPullRequests:
            guard let found = step.found else { return nil }
            if let total = step.total { return "\(found) of \(total)" }
            return "\(found)"
        case .releaseTags:
            return step.found.map { "\($0) merge\($0 == 1 ? "" : "s")" }
        case .linearProjects:
            return step.found.map { "\($0) issue\($0 == 1 ? "" : "s")" }
        }
    }

    // MARK: Header

    /// `10 in review · 2 drafts · 3 shipping`, dropping any part that is zero — `0 shipping`
    /// is a count of nothing, and the panel below already shows its absence. The drafts part
    /// is therefore absent entirely unless the user has turned drafts on.
    private static func summary(for summary: PanelSummary) -> String {
        var parts: [String] = []
        if summary.openCount > 0 { parts.append("\(summary.openCount) in review") }
        if summary.draftCount > 0 {
            parts.append("\(summary.draftCount) draft\(summary.draftCount == 1 ? "" : "s")")
        }
        if summary.shippingCount > 0 { parts.append("\(summary.shippingCount) shipping") }
        return parts.joined(separator: " · ")
    }

    private static func heading(for kind: PanelSection.Kind) -> String {
        switch kind {
        case .project(_, let name): return name
        case .other: return "Other"
        case .done: return "Done"
        }
    }

    // MARK: Banner

    private static func banner(for health: SourceHealth) -> BannerPresentation? {
        guard health.needsReconnect else { return nil }
        return BannerPresentation(message: "GitHub token expired", actionTitle: "Reconnect")
    }

    // MARK: Footer

    private static func footer(
        model: PanelModel,
        status: PanelStatus,
        now: Date,
        progressSteps: [SyncStepPresentation]
    ) -> FooterPresentation {
        let sync = syncState(status: status, now: now)
        return FooterPresentation(
            syncTone: sync.tone,
            syncText: sync.text,
            isSyncing: status.isRefreshing,
            // Both sources' messages, so the hover detail explains whichever of them the
            // footer is complaining about. GitHub first: it is the one whose failure the
            // rows depend on.
            detail: [status.github.message, status.linear.message]
                .compactMap { $0 }
                .joined(separator: " · ")
                .nonEmpty,
            errorMessage: errorMessage(for: status.github),
            linearNote: linearNote(for: status.linear),
            // Offering `Mark all read` with nothing unread is offering an action that
            // does nothing.
            showsMarkAllRead: model.unreadCount > 0,
            progressSteps: progressSteps
        )
    }

    /// The failure the footer states rather than hides behind a tooltip.
    ///
    /// Only ``SourceHealth/unreachable``. The other three are each already said somewhere
    /// the user is looking: an expired token by the banner, no token at all by the connect
    /// prompt, and a healthy source by the absence of any of it.
    private static func errorMessage(for health: SourceHealth) -> String? {
        guard case .unreachable(let message) = health else { return nil }
        return message.nonEmpty
    }

    private static func linearNote(for health: SourceHealth) -> String? {
        switch health {
        // Not connected is not a failure. Linear is optional — the panel groups everything
        // under `Other` and says nothing about it, which is what the connect prompt is for.
        case .unconfigured, .connected: return nil
        case .unauthorized: return "Linear disconnected"
        case .unreachable: return "Linear stale"
        }
    }

    private static func syncState(status: PanelStatus, now: Date) -> (tone: StatusTone, text: String) {
        // A poll in flight outranks everything below, which are all statements about the
        // *last* one. "Is it actually running?" is the question a menu bar app is asked
        // most often and the one it is worst at answering — a dimmed refresh control says
        // it for as long as anyone happens to be looking at that corner, and says nothing
        // at all about the polls that happen on the interval. The footer is where the
        // panel already reports on syncing, so this is where it says that it is.
        if status.isRefreshing { return (.inFlight, "syncing…") }

        guard let synced = status.lastSyncedAt else {
            switch status.github {
            case .unconfigured: return (.neutral, "not connected")
            case .unauthorized: return (.danger, "disconnected")
            // Never synced *and* failing is a red dot, not a grey one. Grey would be
            // right if this were only "nothing has arrived yet", but a source that has
            // never once answered is not waiting, it is broken — and unlike the case
            // below there is no cached list underneath to be four seconds old. The
            // reason is on ``FooterPresentation/errorMessage`` beside it.
            case .unreachable: return (.danger, "never synced")
            case .connected: return (.neutral, "never synced")
            }
        }

        let age = "last synced " + RelativeTime.past(since: synced, now: now)
        if status.github.needsReconnect {
            return (.danger, "disconnected · " + age)
        }
        // A failed poll does not by itself make what is on screen stale: a poll that
        // failed four seconds ago still leaves four-second-old rows. The clock decides,
        // and an unreachable source only means the clock will keep running.
        if !status.github.isConnected || now.timeIntervalSince(synced) >= status.staleThreshold {
            return (.inFlight, "stale · " + age)
        }
        return (.success, "synced " + RelativeTime.past(since: synced, now: now))
    }
}

private extension String {
    /// Nil rather than `""`, so an absent detail is absent rather than an empty tooltip.
    var nonEmpty: String? { isEmpty ? nil : self }
}
