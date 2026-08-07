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
/// `SyncEngine` owns this at M8; M3 sets it from a single fetch. Linear joins at M5 —
/// its health is a footer staleness condition, never a banner, because Linear being
/// unreachable costs the panel its project headings and nothing else (§5).
public struct PanelStatus: Equatable, Sendable {
    public var github: SourceHealth
    public var lastSyncedAt: Date?
    /// A poll in flight. The header's refresh control spins on it.
    public var isRefreshing: Bool

    public init(github: SourceHealth, lastSyncedAt: Date? = nil, isRefreshing: Bool = false) {
        self.github = github
        self.lastSyncedAt = lastSyncedAt
        self.isRefreshing = isRefreshing
    }

    public static let unconfigured = PanelStatus(github: .unconfigured)

    /// The status a fixture renders under: connected, synced 34 seconds ago — the footer
    /// design 2a shows.
    ///
    /// A fixture carries no sync history, and reading the wall clock for one would make
    /// two renderings of the same file differ. This lives here rather than in either
    /// caller because `prstack-dump --presentation` and the presentation goldens have to
    /// agree byte for byte, and two copies of the same constant is how that quietly stops
    /// being true.
    public static func fixture(now: Date) -> PanelStatus {
        PanelStatus(github: .connected, lastSyncedAt: now.addingTimeInterval(-34))
    }

    /// Data older than this reads as stale rather than current. Five minutes is two
    /// missed polls at M8's foreground interval, which is the point at which "synced 6m
    /// ago" stops being a detail and starts being a warning.
    public static let staleAfter: TimeInterval = 5 * 60
}

// MARK: - Pieces

public struct HeaderPresentation: Equatable, Sendable {
    public var title: String
    /// `10 in review · 3 shipping`. Empty when there is nothing to count.
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
    /// `synced 34s ago`, `stale · last synced 41m ago`, `never synced`.
    public var syncText: String
    /// Why the source is unhappy, when it is — the view shows it on hover.
    ///
    /// Kept off ``syncText`` deliberately. "could not reach GitHub: the request timed
    /// out" is the wrong length for a 11 pt footer and the wrong altitude for a glance,
    /// but it is the first thing wanted once the glance has raised a question, and the
    /// panel is the only place it exists.
    public var detail: String?
    /// Hidden when there is nothing unread, so the panel does not offer an action that
    /// would do nothing.
    public var showsMarkAllRead: Bool

    public init(syncTone: StatusTone, syncText: String, detail: String? = nil, showsMarkAllRead: Bool) {
        self.syncTone = syncTone
        self.syncText = syncText
        self.detail = detail
        self.showsMarkAllRead = showsMarkAllRead
    }
}

/// The connect prompt from design 1e.
public struct ConnectPrompt: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var githubActionTitle: String
    public var linearActionTitle: String

    public init(title: String, detail: String, githubActionTitle: String, linearActionTitle: String) {
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

    public static func make(model: PanelModel, status: PanelStatus, now: Date) -> PanelPresentation {
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
            footer: footer(model: model, status: status, now: now),
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
            return .connect(
                ConnectPrompt(
                    title: "Connect your accounts",
                    detail: "GitHub for pull requests and release tags, Linear to group them by project.",
                    githubActionTitle: "Connect GitHub",
                    linearActionTitle: "Connect Linear"
                )
            )
        }
        return .allClear(
            AllClearMessage(
                title: "Everything's clear",
                detail: "No open pull requests need you."
            )
        )
    }

    // MARK: Header

    /// `10 in review · 3 shipping`, dropping either half when it is zero — `0 shipping`
    /// is a count of nothing, and the panel below already shows its absence.
    private static func summary(for summary: PanelSummary) -> String {
        var parts: [String] = []
        if summary.openCount > 0 { parts.append("\(summary.openCount) in review") }
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

    private static func footer(model: PanelModel, status: PanelStatus, now: Date) -> FooterPresentation {
        let sync = syncState(status: status, now: now)
        return FooterPresentation(
            syncTone: sync.tone,
            syncText: sync.text,
            detail: status.github.message,
            // Offering `Mark all read` with nothing unread is offering an action that
            // does nothing.
            showsMarkAllRead: model.unreadCount > 0
        )
    }

    private static func syncState(status: PanelStatus, now: Date) -> (tone: StatusTone, text: String) {
        guard let synced = status.lastSyncedAt else {
            switch status.github {
            case .unconfigured: return (.neutral, "not connected")
            case .unauthorized: return (.danger, "disconnected")
            case .unreachable, .connected: return (.neutral, "never synced")
            }
        }

        let age = "last synced " + RelativeTime.past(since: synced, now: now)
        if status.github.needsReconnect {
            return (.danger, "disconnected · " + age)
        }
        // A failed poll does not by itself make what is on screen stale: a poll that
        // failed four seconds ago still leaves four-second-old rows. The clock decides,
        // and an unreachable source only means the clock will keep running.
        if !status.github.isConnected || now.timeIntervalSince(synced) >= PanelStatus.staleAfter {
            return (.inFlight, "stale · " + age)
        }
        return (.success, "synced " + RelativeTime.past(since: synced, now: now))
    }
}
