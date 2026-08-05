import Foundation

/// The two age spellings the meta line uses.
///
/// Hand-rolled rather than `RelativeDateTimeFormatter` for three reasons, all of which
/// matter more here than localisation does: the design's spellings are bare (`18m`, `3h`,
/// `2d`) and no formatter style produces them, the output has to be byte-stable for the
/// goldens, and the panel refreshes these strings every poll — a formatter allocation per
/// row per poll is the wrong shape for that.
///
/// Both forms round *down*, so a row never claims to be older than it is.
public enum RelativeTime {
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 60 * 60
    private static let day: TimeInterval = 24 * 60 * 60
    private static let week: TimeInterval = 7 * 24 * 60 * 60

    /// The bare form open rows use: `now`, `18m`, `3h`, `2d`, `5w`.
    ///
    /// A date in the future reads as `now` rather than growing a sign. Clock skew between
    /// GitHub and this machine is the usual cause, and a row labelled `-2m` would be
    /// reporting that skew rather than the pull request.
    public static func short(since date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        switch elapsed {
        case ..<minute: return "now"
        case ..<hour: return "\(Int(elapsed / minute))m"
        case ..<day: return "\(Int(elapsed / hour))h"
        case ..<week: return "\(Int(elapsed / day))d"
        default: return "\(Int(elapsed / week))w"
        }
    }

    /// The past form the footer and Done rows use: `34s ago`, `22m ago`, `3h ago`,
    /// `yesterday`, `2d ago`, `5w ago`.
    ///
    /// Seconds appear here and nowhere else. The footer's `synced 34s ago` is the one
    /// place a sub-minute number is worth reading — it is the panel's evidence that what
    /// is on screen is current — whereas a pull request that changed 34 seconds ago is
    /// simply new, and `now` says that better.
    ///
    /// `yesterday` is the one word-form, because the design uses it and because it only
    /// covers the 24–48h band — past that, counting days stays shorter than naming them.
    public static func past(since date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        switch elapsed {
        case ..<minute: return "\(Int(elapsed))s ago"
        case ..<hour: return "\(Int(elapsed / minute))m ago"
        case ..<day: return "\(Int(elapsed / hour))h ago"
        case ..<(2 * day): return "yesterday"
        case ..<week: return "\(Int(elapsed / day))d ago"
        default: return "\(Int(elapsed / week))w ago"
        }
    }

    /// How long is left, for the snooze token: `2h`, `45m`, `1d`.
    ///
    /// Rounds *up*, the opposite of the two above and for the same reason both round the
    /// way they do: a snooze with 90 seconds left reading `1m` would go on reading `1m`
    /// for a minute and a half. Anything under a minute is `<1m`, since a `0m` snooze
    /// looks expired while it is still suppressing the row.
    public static func remaining(until deadline: Date, now: Date) -> String {
        let left = deadline.timeIntervalSince(now)
        guard left > 0 else { return "<1m" }
        switch left {
        case ..<minute: return "<1m"
        case ..<hour: return "\(Int((left / minute).rounded(.up)))m"
        case ..<day: return "\(Int((left / hour).rounded(.up)))h"
        default: return "\(Int((left / day).rounded(.up)))d"
        }
    }
}
