import Foundation

/// One row in the panel: a pull request plus every decision the view needs to draw it.
public struct PanelRow: Equatable, Sendable {
    public var pullRequest: PullRequest
    public var status: RowStatus
    public var releaseStage: ReleaseStage
    /// Status 5–7 **and** not snoozed. This is the value the tint, the title weight and
    /// the icon's red badge all read.
    public var isAttention: Bool
    /// Snoozed with a wake time still in the future.
    public var isSuppressed: Bool
    /// The wake time, when snoozed — the meta line shows it.
    public var snoozedUntil: Date?
    public var isUnread: Bool
    public var spine: SpinePosition
    public var runBase: PRID?
    public var stackRoot: PRID?

    public init(
        pullRequest: PullRequest,
        status: RowStatus,
        releaseStage: ReleaseStage,
        isAttention: Bool,
        isSuppressed: Bool,
        snoozedUntil: Date?,
        isUnread: Bool,
        spine: SpinePosition,
        runBase: PRID?,
        stackRoot: PRID?
    ) {
        self.pullRequest = pullRequest
        self.status = status
        self.releaseStage = releaseStage
        self.isAttention = isAttention
        self.isSuppressed = isSuppressed
        self.snoozedUntil = snoozedUntil
        self.isUnread = isUnread
        self.spine = spine
        self.runBase = runBase
        self.stackRoot = stackRoot
    }

    public var id: PRID { pullRequest.id }
    public var primaryIssue: IssueRef? { pullRequest.primaryIssue }
    public var additionalIssueCount: Int { pullRequest.additionalIssueCount }

    /// Ready to merge **and** not snoozed. This is what the icon's green badge counts.
    ///
    /// Computed rather than stored, unlike ``isAttention``: that one is read by the tint,
    /// the title weight and the row's emphasis, so it is part of what derivation decided
    /// about a row. This is only ever counted, and the count has one consumer.
    ///
    /// `approved` is deliberately excluded. It is green in the panel, but an approved pull
    /// request whose checks have not finished is not something the user can act on — and a
    /// green badge that means "some of these might be mergeable" is worth nothing in a menu
    /// bar. ``RowStatus/readyToMerge`` is the status that already means approved, passing
    /// and mergeable.
    ///
    /// Snooze suppresses it for the same reason it suppresses attention: the user asked
    /// this row to stop asking, and "go merge me" is asking.
    public var isReady: Bool {
        status == .readyToMerge && !isSuppressed
    }

    /// What M4 diffs against the previous model. See ``EffectiveState``.
    public var effectiveState: EffectiveState {
        EffectiveState(status: status, isSuppressed: isSuppressed)
    }
}

public struct PanelSection: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case project(id: String, name: String)
        /// No linked issue, or no linked issue with a project.
        case other
        /// Closed and shipped rows.
        case done
    }

    public var kind: Kind
    public var rows: [PanelRow]

    public init(kind: Kind, rows: [PanelRow]) {
        self.kind = kind
        self.rows = rows
    }
}

/// The header's counts. Core decides what is counted; the view decides the wording.
public struct PanelSummary: Equatable, Sendable {
    /// Open pull requests that are actually in review — "10 in review".
    ///
    /// Drafts are **not** in here. They are open, so counting them would be defensible
    /// arithmetic and a false sentence: the header says `in review`, and a draft is the
    /// one pull request that by definition has not entered it.
    public var openCount: Int
    /// Open drafts — "2 drafts". Always zero unless the user has turned drafts on.
    public var draftCount: Int
    /// Merged, waiting for a release tag — "3 shipping".
    public var shippingCount: Int

    public init(openCount: Int, draftCount: Int = 0, shippingCount: Int) {
        self.openCount = openCount
        self.draftCount = draftCount
        self.shippingCount = shippingCount
    }
}

/// Everything the panel renders, derived from one snapshot.
public struct PanelModel: Equatable, Sendable {
    /// Empty sections are dropped, so an empty `sections` is the all-clear state.
    public var sections: [PanelSection]
    /// The repo name shows in the meta line only when the list spans more than one
    /// repository (PRD §12.3).
    public var showsRepoNames: Bool
    /// Rows that are ready to merge and not snoozed — the icon's green badge.
    public var readyCount: Int
    public var attentionCount: Int
    public var unreadCount: Int
    public var summary: PanelSummary

    /// `readyCount` defaults to zero for the same reason ``PanelSummary/draftCount`` does:
    /// it arrived after the callers did, and every one of them that predates the green
    /// badge is a panel with nothing green to say.
    public init(
        sections: [PanelSection],
        showsRepoNames: Bool,
        readyCount: Int = 0,
        attentionCount: Int,
        unreadCount: Int,
        summary: PanelSummary
    ) {
        self.sections = sections
        self.showsRepoNames = showsRepoNames
        self.readyCount = readyCount
        self.attentionCount = attentionCount
        self.unreadCount = unreadCount
        self.summary = summary
    }

    public var rows: [PanelRow] { sections.flatMap(\.rows) }
    public var isEmpty: Bool { sections.isEmpty }

    public func row(_ id: PRID) -> PanelRow? {
        rows.first { $0.id == id }
    }
}
