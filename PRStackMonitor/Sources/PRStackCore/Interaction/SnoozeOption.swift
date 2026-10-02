import Foundation

/// The choices the snooze menu offers.
///
/// The menu is in three parts and this type is all of them: the times (`For 1 day`, `For 1
/// week`, `Until Monday`), the events that need no target (`Until any change`, `Until the
/// next release`), and another pull request merging or being released. What each resolves
/// to is ``LocalState/snooze(_:_:in:now:calendar:)``'s business — the menu is left with a
/// list of titles and a call.
///
/// The arithmetic is here rather than in the menu that presents it for the same reason the
/// status phrase is (see ``RowPresentation``): "until Monday" is a rule, and rules that can
/// be got subtly wrong belong where a Linux container can pin them. `now` is injected
/// everywhere, so the same instant and the same calendar always resolve to the same deadline.
public enum SnoozeOption: Hashable, Sendable {
    case oneDay
    case oneWeek
    case untilMonday
    case anyChange
    case nextRelease
    case merged(PRID)
    case released(PRID)

    /// The time-based choices, in menu order.
    public static let durations: [SnoozeOption] = [.oneDay, .oneWeek, .untilMonday]

    /// The choices that wait for something to happen and name nothing to wait on.
    public static let events: [SnoozeOption] = [.anyChange, .nextRelease]

    /// The wording in the menu and in the row's action rotor.
    public var title: String {
        switch self {
        case .oneDay: return "For 1 day"
        case .oneWeek: return "For 1 week"
        case .untilMonday: return "Until Monday"
        case .anyChange: return "Until any change"
        case .nextRelease: return "Until the next release"
        case .merged(let target): return "Until #\(target.number) is merged"
        case .released(let target): return "Until #\(target.number) is released"
        }
    }

    /// The hour `Until Monday` wakes at. Early enough to be there before the working day
    /// starts, late enough that a snooze is not spent overnight.
    public static let morningHour = 9

    /// The deadline a time-based choice resolves to, from `now`; nil for the rest.
    ///
    /// The calendar is a parameter and defaults to the autoupdating current one: `Until
    /// Monday` is a wall-clock time, so it has to follow the user's own time zone, including
    /// across a change of it. The two spans are elapsed time — `1 day` is the next 24 hours,
    /// not a date that moves with a daylight saving change. Tests pass a fixed calendar.
    public func wakeTime(from now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        switch self {
        case .oneDay:
            return now.addingTimeInterval(24 * 3600)
        case .oneWeek:
            return now.addingTimeInterval(7 * 24 * 3600)
        case .untilMonday:
            return SnoozeOption.nextMondayMorning(from: now, calendar: calendar)
        case .anyChange, .nextRelease, .merged, .released:
            return nil
        }
    }

    // MARK: - Wall-clock arithmetic

    /// The next Monday at ``morningHour``, counting from tomorrow.
    ///
    /// Counting from tomorrow rather than from today is what makes "Until Monday" mean the
    /// *next* one when it is pressed on a Monday, instead of a snooze that expires the same
    /// morning it was set.
    ///
    /// Every step is failable in `Calendar` and every fallback is the same: a week of
    /// elapsed time. A snooze that lands an hour off because the machine is on a calendar
    /// nobody anticipated is a bad wake time; a snooze that does not happen at all because a
    /// `guard` returned `now` is a control that visibly does nothing.
    private static func nextMondayMorning(from now: Date, calendar: Calendar) -> Date {
        let fallback = now.addingTimeInterval(7 * 24 * 3600)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        else { return fallback }

        var components = DateComponents()
        // `weekday` counts from Sunday = 1 in the Gregorian calendar, so Monday is 2. It is
        // not relative to `firstWeekday`, which is a display preference — reading that
        // instead would land this on a different day per locale.
        components.weekday = 2
        components.hour = morningHour
        components.minute = 0
        components.second = 0

        // Searching from midnight tomorrow: `nextDate` answers strictly after the date it
        // is given, so a Monday start still finds that Monday's 09:00.
        guard let wake = calendar.nextDate(after: tomorrow, matching: components, matchingPolicy: .nextTime),
              wake > now
        else { return fallback }
        return wake
    }
}

/// Another pull request a row can be snoozed against — one entry in the `Until merged`
/// and `Until released` submenus.
public struct SnoozeTarget: Hashable, Sendable {
    public var id: PRID
    public var title: String
    /// In the same stack as the row the menu is for. These are listed first: waiting on
    /// the pull request underneath is what a stacked row is usually doing.
    public var isStackMember: Bool
    /// Still open, so `Until merged` can offer it. A merged pull request still waiting for
    /// its release is only a `released` target.
    public var isOpen: Bool

    public init(id: PRID, title: String, isStackMember: Bool, isOpen: Bool) {
        self.id = id
        self.title = title
        self.isStackMember = isStackMember
        self.isOpen = isOpen
    }

    /// What the submenu shows: the number, which is how the meta line names it, then the
    /// title — truncated, because a menu as wide as the longest title in the account is
    /// a menu nobody can aim at.
    public var menuTitle: String {
        let limit = 48
        let trimmed = title.count > limit ? String(title.prefix(limit - 1)) + "…" : title
        return "#\(id.number) \(trimmed)"
    }
}
