import Foundation

/// What the menu bar icon shows. One value, resolved by a strict priority order.
///
/// This lives in core rather than beside the drawing code for the same reason
/// ``RowPresentation`` does: the rule is testable off-device and the drawing is not.
/// `StatusItemIcon` in the app turns one of these into an `NSImage` and decides nothing.
///
/// It is deliberately *not* a field on ``PanelPresentation``. The icon is not part of the
/// panel — it is what the user sees when the panel is closed, and its first rule reads a
/// source's health, which the panel's own presentation has already folded away.
public enum IconState: Hashable, Sendable {
    /// GitHub unreachable or unauthenticated. Dashed glyph outline, reduced opacity.
    case disconnected
    /// Glyph plus the count badges: green for pull requests ready to merge, red for the
    /// ones that need the user. Either count may be zero — never both, which is ``idle``.
    ///
    /// One case rather than two, because the two badges are not alternatives: a stack can
    /// perfectly well have two mergeable pull requests and a third with failing checks, and
    /// the menu bar is where the user finds that out without opening anything. A priority
    /// order between them would have to hide one of the two numbers that were asked for.
    case counts(ready: Int, attention: Int)
    /// Glyph plus the indigo dot.
    case unread
    /// Plain glyph.
    case idle
    /// Reserved — the design's amber pulsing "deploy in flight".
    ///
    /// Tags-only release tracking (IMPLEMENTATION_PLAN §3) has no input that produces it:
    /// a tag either contains the merge commit or it does not. ``resolve(github:readyCount:attentionCount:unreadCount:)``
    /// never returns this case, and the drawing code keeps it so a future
    /// `DeploymentAPITracker` lights it up without touching the state machine.
    case inFlight

    /// The priority table from IMPLEMENTATION_PLAN §5, in order. First match wins.
    ///
    /// **Disconnected outranks everything**, which is a deliberate change from the PRD's
    /// ordering. Every other state is derived from data that is, by definition, stale
    /// while GitHub is unreachable: a red badge counting three cached failures asserts
    /// something the app cannot currently verify. The panel still shows the last known
    /// list under a reconnect banner — the badge comes off the menu bar, not the
    /// information out of the panel.
    ///
    /// Only GitHub's health is read. Linear being unreachable costs the panel its project
    /// headings and nothing else, which is a footer staleness condition (§4).
    ///
    /// **Green counts as something to say.** A ready pull request outranks unread activity
    /// exactly as a red one does: both are states of the pull requests themselves, and the
    /// dot only ever meant "something changed, look when you can".
    public static func resolve(
        github: SourceHealth,
        readyCount: Int,
        attentionCount: Int,
        unreadCount: Int
    ) -> IconState {
        guard github.isConnected else { return .disconnected }
        // Negatives cannot arrive from derivation — both counts are `filter().count` — but
        // clamping here means the drawing code never has to ask.
        let ready = max(0, readyCount)
        let attention = max(0, attentionCount)
        if ready > 0 || attention > 0 { return .counts(ready: ready, attention: attention) }
        if unreadCount > 0 { return .unread }
        return .idle
    }

    public static func resolve(model: PanelModel, status: PanelStatus) -> IconState {
        resolve(
            github: status.github,
            readyCount: model.readyCount,
            attentionCount: model.attentionCount,
            unreadCount: model.unreadCount
        )
    }

    /// Whether the icon is asking for something. Opening the panel clears unread and
    /// never clears this.
    ///
    /// Only the red half. A green badge is a standing invitation, not a demand — and the
    /// PRD §5.2 invariant this backs ("a row that needs attention always has a matching
    /// icon") is about attention rows.
    public var isDemanding: Bool { attentionCount > 0 }

    /// The red badge's count, zero in every state that has no red badge.
    public var attentionCount: Int {
        if case .counts(_, let attention) = self { return attention }
        return 0
    }

    /// The green badge's count, zero in every state that has no green badge.
    public var readyCount: Int {
        if case .counts(let ready, _) = self { return ready }
        return 0
    }

    /// Stable spelling, for the table test and for logs.
    public var token: String {
        switch self {
        case .disconnected: return "disconnected"
        case .counts(let ready, let attention): return "counts:ready=\(ready),attention=\(attention)"
        case .unread: return "unread"
        case .idle: return "idle"
        case .inFlight: return "inFlight"
        }
    }

    /// What VoiceOver reads for the status item.
    ///
    /// The menu bar item is one control with one label, so the label has to carry the
    /// state — the badges are drawn into the image and are not elements of their own.
    /// With both badges up the label names both, in the order they are drawn.
    public var accessibilityLabel: String {
        switch self {
        case .disconnected: return "Pull requests, disconnected"
        case .counts(let ready, let attention):
            var parts: [String] = []
            if ready > 0 {
                parts.append("\(ready) ready to merge")
            }
            if attention > 0 {
                parts.append(attention == 1 ? "1 needs you" : "\(attention) need you")
            }
            return (["Pull requests"] + parts).joined(separator: ", ")
        case .unread: return "Pull requests, unread activity"
        case .idle: return "Pull requests"
        case .inFlight: return "Pull requests, release in flight"
        }
    }
}
