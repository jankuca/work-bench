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
    /// Glyph plus the red badge, count centred.
    case actionNeeded(count: Int)
    /// Glyph plus the indigo dot.
    case unread
    /// Plain glyph.
    case idle
    /// Reserved — the design's amber pulsing "deploy in flight".
    ///
    /// Tags-only release tracking (IMPLEMENTATION_PLAN §3) has no input that produces it:
    /// a tag either contains the merge commit or it does not. ``resolve(github:attentionCount:unreadCount:)``
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
    public static func resolve(github: SourceHealth, attentionCount: Int, unreadCount: Int) -> IconState {
        guard github.isConnected else { return .disconnected }
        if attentionCount > 0 { return .actionNeeded(count: attentionCount) }
        if unreadCount > 0 { return .unread }
        return .idle
    }

    public static func resolve(model: PanelModel, status: PanelStatus) -> IconState {
        resolve(
            github: status.github,
            attentionCount: model.attentionCount,
            unreadCount: model.unreadCount
        )
    }

    /// Whether the icon is asking for something. Opening the panel clears unread and
    /// never clears this.
    public var isDemanding: Bool {
        if case .actionNeeded = self { return true }
        return false
    }

    /// Stable spelling, for the table test and for logs.
    public var token: String {
        switch self {
        case .disconnected: return "disconnected"
        case .actionNeeded(let count): return "actionNeeded:\(count)"
        case .unread: return "unread"
        case .idle: return "idle"
        case .inFlight: return "inFlight"
        }
    }

    /// What VoiceOver reads for the status item.
    ///
    /// The menu bar item is one control with one label, so the label has to carry the
    /// state — the badge is drawn into the image and is not an element of its own.
    public var accessibilityLabel: String {
        switch self {
        case .disconnected: return "Pull requests, disconnected"
        case .actionNeeded(let count):
            return count == 1 ? "Pull requests, 1 needs you" : "Pull requests, \(count) need you"
        case .unread: return "Pull requests, unread activity"
        case .idle: return "Pull requests"
        case .inFlight: return "Pull requests, release in flight"
        }
    }
}
