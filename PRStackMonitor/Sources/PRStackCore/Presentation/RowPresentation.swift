import Foundation

// Everything the row view draws, decided here rather than in SwiftUI.
//
// The seam is deliberate and it is not the usual one. Colour is named semantically
// (``StatusTone``) and resolved to literal values in `PanelUI/Tokens.swift`; wording,
// ordering and *which* elements exist are decided here. That puts every rule worth a test
// — the status phrase, the meta line's composition, the release track, the spine's
// direction — in a module that builds and tests on Linux, and leaves the AppKit layer
// with nothing but geometry and colour.
//
// It moves one thing across the line that `PanelModel` had left on the view's side: the
// per-row status phrase. `PanelSummary`'s comment still holds for the header — core
// counts, the view words it — because the header's wording is a sentence about the panel.
// A row's phrase is not: `2 checks failed` needs `CheckRollup.failingCount` and
// `waiting on #4127` needs the parent's number, so leaving it to the view means the view
// re-derives from the domain model. Better to derive it once, where it can be pinned.

// MARK: - Semantic roles

/// The colour role of a status. `PanelUI/Tokens.swift` is the only place these become
/// literal colours, in either appearance.
public enum StatusTone: String, Hashable, Sendable {
    /// Grey. Blocked, in review, closed — nothing to act on and nothing achieved.
    case neutral
    /// Red. The three attention statuses.
    case danger
    /// Green. Approved, ready to merge, released.
    case success
    /// Purple. Merged, waiting for a release tag.
    case merged
    /// Amber. No ``RowStatus`` maps to it — the release track's running segment is the
    /// only thing that carries it, since IMPLEMENTATION_PLAN §3 removed the amber pulsing
    /// deploy state the design used it for.
    case inFlight
    /// Indigo. A link affordance, never a state signal — which is why the Linear
    /// identifier is the one other colour the meta line permits.
    case accent
}

/// The mark inside the 16 pt status chip.
///
/// Shape carries the state as well as colour does, which is what keeps the panel readable
/// under `Differentiate without colour` (IMPLEMENTATION_PLAN §5).
public enum ChipGlyph: String, Hashable, Sendable {
    /// 6 pt dot — the live states.
    case dot
    /// 6×2 pt bar — waiting on something else, or closed. Nothing is happening.
    case bar
    /// A bar rotated 45° — a merge conflict, the one status that is a collision.
    case slash
}

/// Title weight and colour, as one value. 2a runs 500 → 560 across these three.
public enum TitleEmphasis: String, Hashable, Sendable {
    /// Weight 500, secondary text. Blocked, terminal, or snoozed — present but not asking.
    case dim
    /// Weight 520, primary text. The default.
    case normal
    /// Weight 560, primary text. Attention rows.
    case strong
}

/// One of the three 9×3 pt release segments.
public enum SegmentState: String, Hashable, Sendable {
    case empty
    case passing
    case failing
    case running

    /// `nil` is the unfilled track colour rather than a state — an empty segment is a
    /// stage not reached, not a stage that went grey.
    public var tone: StatusTone? {
        switch self {
        case .empty: return nil
        case .passing: return .success
        case .failing: return .danger
        case .running: return .inFlight
        }
    }
}

/// Which way the spine hairline is drawn from the chip's centre line.
public struct SpineDraw: Hashable, Sendable {
    public var drawsUp: Bool
    public var drawsDown: Bool

    public init(drawsUp: Bool, drawsDown: Bool) {
        self.drawsUp = drawsUp
        self.drawsDown = drawsDown
    }

    public static let none = SpineDraw(drawsUp: false, drawsDown: false)

    public var isVisible: Bool { drawsUp || drawsDown }

    public init(_ position: SpinePosition) {
        switch position {
        case .none: self.init(drawsUp: false, drawsDown: false)
        case .top: self.init(drawsUp: false, drawsDown: true)
        case .middle: self.init(drawsUp: true, drawsDown: true)
        case .base: self.init(drawsUp: true, drawsDown: false)
        }
    }
}

// MARK: - Meta line

/// One token on the meta line. The view joins them with a separator; the order here is
/// the order they render in.
public enum MetaToken: Hashable, Sendable {
    case number(Int)
    /// `owner/name`, only when the list spans more than one repository (PRD §12.3).
    case repository(String)
    /// The one status phrase. The only coloured *status* token on the line.
    case phrase(String, tone: StatusTone)
    case age(String)
    /// `snoozed 2h`. Tertiary — a snooze is a fact about the user, not about the pull
    /// request.
    case snooze(String)
    /// The primary Linear issue. Indigo, opens the issue. Last on the line: the pull
    /// request's own number is what the row is called, and the ticket is where the row
    /// points.
    case issue(identifier: String, url: URL)
    /// `+2` — how many further tickets this pull request resolves. Tertiary grey, so it
    /// reads as a count rather than a second link, and it opens a menu of all of them.
    case additionalIssues(count: Int)

    /// What the token reads as, for the accessibility label and the text report.
    public var text: String {
        switch self {
        case .number(let number): return "#\(number)"
        case .repository(let name): return name
        case .phrase(let phrase, _): return phrase
        case .age(let age): return age
        case .snooze(let snooze): return snooze
        case .issue(let identifier, _): return identifier
        case .additionalIssues(let count): return "+\(count)"
        }
    }
}

// MARK: - Reviewers

/// One avatar. The image is not fetched at M3 — initials over a login-derived colour
/// index stand in, which is also the fallback when a fetch fails later.
public struct ReviewerBadge: Hashable, Sendable {
    public var login: String
    public var initials: String
    public var avatarURL: URL?
    /// The 3 pt ring: this reviewer's own state, not the row's.
    public var tone: StatusTone

    public init(login: String, initials: String, avatarURL: URL?, tone: StatusTone) {
        self.login = login
        self.initials = initials
        self.avatarURL = avatarURL
        self.tone = tone
    }

    /// Up to two letters. Login parts win over raw prefixes, so `jan-kuca` reads `JK`
    /// rather than `JA`.
    public static func initials(for login: String) -> String {
        let parts = login
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return "?" }
        if parts.count >= 2, let second = parts.dropFirst().first {
            return (String(first.prefix(1)) + String(second.prefix(1))).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }
}

// MARK: - Row

/// One row of the panel, fully resolved.
public struct RowPresentation: Equatable, Sendable {
    /// At most this many avatars render; the rest become a count.
    public static let avatarLimit = 3

    public var id: PRID
    public var title: String
    public var emphasis: TitleEmphasis
    public var url: URL
    /// The indigo gutter dot. The 5 pt gutter is reserved either way, so rows never
    /// shift when this flips.
    public var isUnread: Bool
    /// The warm row tint. Attention and nothing else — snooze suppresses it, and unread
    /// never causes it (IMPLEMENTATION_PLAN §5; the tint is the panel's only "act on
    /// this" signal, and spending it on "something changed" would make it mean neither).
    public var isTinted: Bool
    public var chipTone: StatusTone
    public var chipGlyph: ChipGlyph
    public var spine: SpineDraw
    public var meta: [MetaToken]
    public var reviewers: [ReviewerBadge]
    /// Reviewers past ``avatarLimit``, rendered as `+2`.
    public var overflowReviewers: Int
    public var segments: [SegmentState]
    /// Done rows carry a ✕. Every keyboard action needs a pointer affordance (§5).
    public var isDismissible: Bool
    /// Snoozed, with a wake time still ahead of it. The meta line already carries the
    /// remaining time; this is what turns the row menu's `Snooze` into `Wake now`, so the
    /// view does not have to read a display token back to find out.
    public var isSnoozed: Bool
    /// The primary issue's URL, for the `L` key and the identifier click.
    public var issueURL: URL?
    /// Every linked issue, primary first — what `+N` opens and what repeated `L` cycles.
    public var issues: [IssueRef]

    public init(
        id: PRID,
        title: String,
        emphasis: TitleEmphasis,
        url: URL,
        isUnread: Bool,
        isTinted: Bool,
        chipTone: StatusTone,
        chipGlyph: ChipGlyph,
        spine: SpineDraw,
        meta: [MetaToken],
        reviewers: [ReviewerBadge],
        overflowReviewers: Int,
        segments: [SegmentState],
        isDismissible: Bool,
        isSnoozed: Bool,
        issueURL: URL?,
        issues: [IssueRef]
    ) {
        self.id = id
        self.title = title
        self.emphasis = emphasis
        self.url = url
        self.isUnread = isUnread
        self.isTinted = isTinted
        self.chipTone = chipTone
        self.chipGlyph = chipGlyph
        self.spine = spine
        self.meta = meta
        self.reviewers = reviewers
        self.overflowReviewers = overflowReviewers
        self.segments = segments
        self.isDismissible = isDismissible
        self.isSnoozed = isSnoozed
        self.issueURL = issueURL
        self.issues = issues
    }

    /// One sentence for VoiceOver. The row is a single accessibility element: reading it
    /// as eight separate labels is how a list like this becomes unusable by ear.
    public var accessibilityLabel: String {
        var parts = [title]
        parts.append(contentsOf: meta.map(\.text))
        if isUnread { parts.append("unread") }
        return parts.joined(separator: ", ")
    }

    public static func make(row: PanelRow, showsRepoName: Bool, now: Date) -> RowPresentation {
        let pullRequest = row.pullRequest
        let tone = StatusTone(row.status)
        let reviewers = badges(for: pullRequest.reviews)

        return RowPresentation(
            id: row.id,
            title: pullRequest.title,
            emphasis: emphasis(for: row),
            url: pullRequest.url,
            isUnread: row.isUnread,
            isTinted: row.isAttention,
            chipTone: tone,
            chipGlyph: ChipGlyph(row.status),
            spine: SpineDraw(row.spine),
            meta: metaTokens(row: row, tone: tone, showsRepoName: showsRepoName, now: now),
            reviewers: Array(reviewers.prefix(avatarLimit)),
            overflowReviewers: max(0, reviewers.count - avatarLimit),
            segments: segments(for: row),
            isDismissible: row.status.belongsInDone,
            // `snoozedUntil` is already nil once the deadline has passed, so this is
            // "asleep now" rather than "has ever been snoozed".
            isSnoozed: row.snoozedUntil != nil,
            issueURL: row.primaryIssue?.url,
            issues: orderedIssues(of: pullRequest)
        )
    }

    // MARK: Meta line

    private static func metaTokens(
        row: PanelRow,
        tone: StatusTone,
        showsRepoName: Bool,
        now: Date
    ) -> [MetaToken] {
        var tokens: [MetaToken] = []

        // The number leads: it is what the row is called, it is on every row, and it is
        // the one token whose position never depends on what else the row happens to have.
        tokens.append(.number(row.pullRequest.number))
        if showsRepoName {
            tokens.append(.repository(row.pullRequest.repo))
        }
        tokens.append(.phrase(phrase(for: row), tone: tone))
        tokens.append(.age(age(for: row, now: now)))
        if let deadline = row.snoozedUntil {
            tokens.append(.snooze("snoozed " + RelativeTime.remaining(until: deadline, now: now)))
        }
        // The ticket trails the line, after the age. No placeholder when there is none:
        // design 2a's Other-section row reads `#4051 · merge conflict · 2d`, and the
        // section heading already says `Other` (IMPLEMENTATION_PLAN §5).
        if let issue = row.primaryIssue {
            tokens.append(.issue(identifier: issue.identifier, url: issue.url))
            if row.additionalIssueCount > 0 {
                tokens.append(.additionalIssues(count: row.additionalIssueCount))
            }
        }
        return tokens
    }

    /// Exactly one phrase per row, from the row's one status.
    ///
    /// Design 2a shows `3 new comments` on one row, which this does not reproduce:
    /// comment activity is not a ``RowStatus`` and a second phrase would break the
    /// single-status rule (§2). The gutter dot already says something changed, and the
    /// pull request page says what.
    static func phrase(for row: PanelRow) -> String {
        switch row.status {
        case .closed:
            return "closed without merging"
        case .shipped(let tag):
            // Not the design's "live in production". Tags-only tracking (§3) knows that a
            // release tag contains the merge commit and nothing about whether it was
            // deployed, so naming the tag is the whole of what was verified.
            return "released in \(tag)"
        case .merged:
            return "awaiting release"
        case .conflicted:
            return "merge conflict"
        case .changesRequested:
            return "changes requested"
        case .checksFailing:
            let failing = row.pullRequest.checks.failingCount
            // A rollup can report failing without a usable count — the `"checks":
            // "failing"` short form in a fixture, or a rollup GitHub summarised without
            // per-context detail. `0 checks failed` would be a contradiction.
            guard failing > 0 else { return "checks failed" }
            return failing == 1 ? "1 check failed" : "\(failing) checks failed"
        case .blocked(let parent):
            return "waiting on #\(parent.number)"
        case .readyToMerge:
            return "ready to merge"
        case .approved:
            return "approved"
        case .inReview:
            return "in review"
        }
    }

    /// Open rows date from their last update; Done rows date from the merge or close, in
    /// the past form, because "2d" on a finished pull request reads as a duration rather
    /// than a moment.
    private static func age(for row: PanelRow, now: Date) -> String {
        guard row.status.belongsInDone else {
            return RelativeTime.short(since: row.pullRequest.updatedAt, now: now)
        }
        let reference = row.pullRequest.mergedAt ?? row.pullRequest.updatedAt
        return RelativeTime.past(since: reference, now: now)
    }

    // MARK: Release track

    /// Segment 1 is CI, segment 2 fills on merge to trunk, segment 3 when a matching tag
    /// contains the merge commit. No pulse — there is no fourth thing to be in flight
    /// between (§3).
    private static func segments(for row: PanelRow) -> [SegmentState] {
        let checks: SegmentState
        switch row.pullRequest.checks.state {
        case .noChecks: checks = .empty
        case .running: checks = .running
        case .passing: checks = .passing
        case .failing: checks = .failing
        }

        let merged: SegmentState
        let released: SegmentState
        switch row.releaseStage {
        case .unmerged:
            merged = .empty
            released = .empty
        case .mergedAwaitingTag, .deploying:
            merged = .passing
            released = .empty
        case .released:
            merged = .passing
            released = .passing
        case .deployFailed:
            merged = .passing
            released = .failing
        }

        return [checks, merged, released]
    }

    // MARK: Reviewers

    /// One badge per reviewer, first appearance wins.
    ///
    /// GitHub reports a review per submission, so a reviewer who commented and then
    /// approved appears twice. Source order is the mapper's order, which is GitHub's
    /// newest-state-per-reviewer ordering — taking the first occurrence keeps the current
    /// state and drops the history.
    private static func badges(for reviews: [ReviewerState]) -> [ReviewerBadge] {
        var seen: Set<String> = []
        var badges: [ReviewerBadge] = []
        for review in reviews {
            guard seen.insert(review.login).inserted else { continue }
            badges.append(
                ReviewerBadge(
                    login: review.login,
                    initials: ReviewerBadge.initials(for: review.login),
                    avatarURL: review.avatarURL,
                    tone: StatusTone(review.state)
                )
            )
        }
        return badges
    }

    // MARK: Emphasis

    private static func emphasis(for row: PanelRow) -> TitleEmphasis {
        if row.isAttention { return .strong }
        // A snoozed row keeps its status but stops asking, so it dims with the rest of
        // the "nothing for you here" cases rather than staying at full weight.
        if row.isSuppressed || row.status.belongsInDone { return .dim }
        switch row.status {
        case .merged, .blocked: return .dim
        default: return .normal
        }
    }

    /// Primary first, then the rest in the pull request's own order. This is the order
    /// `+N` lists and repeated `L` presses cycle through (``IssueCycle``).
    private static func orderedIssues(of pullRequest: PullRequest) -> [IssueRef] {
        guard let primary = pullRequest.primaryIssue else { return [] }
        var rest = pullRequest.linearIssues
        // Remove the primary's own entry, not every entry equal to it — otherwise a pull
        // request that lists the same ticket twice would show `+1` and then offer one
        // issue in the menu the affix promises two of.
        guard let index = rest.firstIndex(of: primary) else { return [primary] }
        rest.remove(at: index)
        return [primary] + rest
    }
}

// MARK: - Tone mapping

extension StatusTone {
    public init(_ status: RowStatus) {
        switch status {
        case .conflicted, .changesRequested, .checksFailing:
            self = .danger
        case .approved, .readyToMerge, .shipped:
            self = .success
        case .merged:
            self = .merged
        case .closed, .blocked, .inReview:
            self = .neutral
        }
    }

    public init(_ state: ReviewState) {
        switch state {
        case .approved: self = .success
        case .changesRequested: self = .danger
        // A comment is not a verdict, and a dismissed review has been withdrawn. Neither
        // is a state to colour: only the two that gate the merge get one.
        case .commented, .pending, .dismissed: self = .neutral
        }
    }
}

extension ChipGlyph {
    public init(_ status: RowStatus) {
        switch status {
        case .conflicted:
            self = .slash
        case .blocked, .closed:
            self = .bar
        default:
            self = .dot
        }
    }
}
