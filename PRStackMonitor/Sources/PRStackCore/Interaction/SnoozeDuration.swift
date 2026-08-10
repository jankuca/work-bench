import Foundation

/// The choices the snooze menu offers, and the wake time each one resolves to.
///
/// The arithmetic is here rather than in the menu that presents it for the same reason the
/// status phrase is (see ``RowPresentation``): "until Monday" is a rule, and rules that can
/// be got subtly wrong belong where a Linux container can pin them. What the AppKit layer
/// is left with is a list of titles and a call.
///
/// `now` is injected everywhere, so the whole thing is deterministic — the same instant and
/// the same calendar always resolve to the same deadline.
public enum SnoozeDuration: String, Hashable, Sendable, CaseIterable {
    case oneHour
    case fourHours
    case tomorrow
    case nextWeek

    /// The wording in the menu and in the row's action rotor.
    public var title: String {
        switch self {
        case .oneHour: return "For 1 hour"
        case .fourHours: return "For 4 hours"
        case .tomorrow: return "Until tomorrow"
        case .nextWeek: return "Until Monday"
        }
    }

    /// What the two day-based choices wake at. Early enough to be there before the working
    /// day starts, late enough that a snooze is not spent overnight.
    public static let morningHour = 9

    /// The deadline this choice resolves to, from `now`.
    ///
    /// The calendar is a parameter and defaults to the autoupdating current one: the wake
    /// times are wall-clock times ("tomorrow morning"), so they have to follow the user's
    /// own time zone, including across a change of it. Tests pass a fixed calendar.
    public func wakeTime(from now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        switch self {
        case .oneHour:
            return now.addingTimeInterval(3600)
        case .fourHours:
            return now.addingTimeInterval(4 * 3600)
        case .tomorrow:
            return SnoozeDuration.morning(daysAfter: 1, from: now, calendar: calendar)
        case .nextWeek:
            return SnoozeDuration.nextMondayMorning(from: now, calendar: calendar)
        }
    }

    // MARK: - Wall-clock arithmetic

    /// `days` midnights from now, at ``morningHour``.
    ///
    /// Every step is failable in `Calendar` and every fallback is the same: the elapsed
    /// form of the same span. A snooze that lands an hour off because the machine is on a
    /// calendar nobody anticipated is a bad wake time; a snooze that does not happen at all
    /// because a `guard` returned `now` is a control that visibly does nothing.
    private static func morning(daysAfter days: Int, from now: Date, calendar: Calendar) -> Date {
        let fallback = now.addingTimeInterval(Double(days) * 24 * 3600)
        guard let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)),
              let wake = calendar.date(
                  bySettingHour: morningHour,
                  minute: 0,
                  second: 0,
                  of: day,
                  matchingPolicy: .nextTime
              )
        else { return fallback }
        // A wake time in the past would be a snooze that expires the moment it is set. It
        // takes a calendar without the requested hour on that day to get here — a DST
        // spring-forward over 09:00 — but the guard is a line and the failure is silent.
        return wake > now ? wake : fallback
    }

    /// The next Monday at ``morningHour``, counting from tomorrow.
    ///
    /// Counting from tomorrow rather than from today is what makes "Until Monday" mean the
    /// *next* one when it is pressed on a Monday, instead of a snooze that expires the same
    /// morning it was set.
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
