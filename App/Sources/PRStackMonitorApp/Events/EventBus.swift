import Foundation
import PRStackCore

/// What a sink is handed alongside the events.
///
/// One deliberate widening of IMPLEMENTATION_PLAN §1's `context: PanelModel`. The icon's
/// first rule is that disconnected outranks everything, and disconnection is not in the
/// model — it is a property of the sources that produced it. A notification sink will want
/// the same thing for the same reason: nothing should be announced from data the app
/// cannot currently verify. Carrying the resolved ``IconState`` too means a sink never
/// re-derives a rule that core already owns.
struct EventContext {
    /// The panel as it stands after the derivation these events came out of.
    var model: PanelModel
    /// Where each source stands. What tells a sink whether the model is worth acting on.
    var status: PanelStatus
    /// The icon core resolved for this model and status, so no sink re-derives the rule.
    var icon: IconState
}

/// Anything that wants to hear about derivation's transitions.
///
/// v1 registers exactly one — ``IconSink``. Adding "notify me when my pull request reaches
/// production" later means writing a `UserNotificationSink` (request authorisation, map
/// event → `UNNotification`, respect the toggle in ``EventPreferences``) and registering
/// it here. No change to core, to sync, or to the panel.
///
/// Main-actor isolated: every sink there will ever be drives something on screen — the
/// status item today, a notification banner later.
@MainActor
protocol EventSink: AnyObject {
    func handle(_ events: [DomainEvent], context: EventContext)
}

/// Which event types are allowed through to the sinks.
///
/// Kept from M4 even though the only sink ignores them, so the notification extension is a
/// drop-in rather than a retrofit. Stored in `UserDefaults` per IMPLEMENTATION_PLAN §3;
/// M7's Settings window binds a checkbox per ``DomainEventKind`` and needs nothing else.
struct EventPreferences: Equatable {
    /// Absent means enabled. Storing only the *exceptions* is what makes an event type
    /// added in a later version default to on rather than silently off for everyone who
    /// already has a stored preferences dictionary.
    private var disabled: Set<DomainEventKind>

    init(disabled: Set<DomainEventKind> = []) {
        self.disabled = disabled
    }

    /// Everything on — what a fresh install gets.
    static let all = EventPreferences()

    /// Whether events of this type reach the sinks.
    func allows(_ kind: DomainEventKind) -> Bool {
        !disabled.contains(kind)
    }

    /// What M7's Settings checkbox calls.
    mutating func setEnabled(_ enabled: Bool, for kind: DomainEventKind) {
        if enabled {
            disabled.remove(kind)
        } else {
            disabled.insert(kind)
        }
    }

    // MARK: Storage

    /// The `UserDefaults` key one toggle is stored under. Derived from the case name, so
    /// an event type added later needs no second list to be registered in.
    static func defaultsKey(for kind: DomainEventKind) -> String {
        "events.\(kind.rawValue).enabled"
    }

    /// Reads every toggle. Absent keys stay enabled.
    static func load(from defaults: UserDefaults = .standard) -> EventPreferences {
        var preferences = EventPreferences()
        for kind in DomainEventKind.allCases {
            // `object(forKey:)` rather than `bool(forKey:)`: the latter cannot tell an
            // absent key from a stored `false`, which would make every event type default
            // to off on a fresh install.
            guard let stored = defaults.object(forKey: defaultsKey(for: kind)) as? Bool else { continue }
            preferences.setEnabled(stored, for: kind)
        }
        return preferences
    }

    /// Writes every toggle, including the enabled ones, so a value flipped back on
    /// overwrites the stored exception rather than leaving it behind.
    func save(to defaults: UserDefaults = .standard) {
        for kind in DomainEventKind.allCases {
            defaults.set(allows(kind), forKey: EventPreferences.defaultsKey(for: kind))
        }
    }
}

/// The registry between derivation and whatever is listening.
///
/// Deliberately dumb: it filters by ``EventPreferences`` and fans out. Anything cleverer —
/// coalescing, rate limiting, ordering — would be a rule about events, and rules about
/// events belong in core where they can be tested without a Mac.
@MainActor
final class EventBus {
    var preferences: EventPreferences

    /// Sinks are held strongly; they are owned by nothing else, and a sink that has been
    /// deallocated is a sink that has stopped working silently. Each one holds whatever it
    /// drives weakly instead.
    private var sinks: [any EventSink] = []

    init(preferences: EventPreferences = .load()) {
        self.preferences = preferences
    }

    /// Adds a sink. Registration is one-way — nothing in v1 has a reason to unregister.
    func register(_ sink: any EventSink) {
        sinks.append(sink)
    }

    /// Publishes to every sink, **including when `events` is empty**.
    ///
    /// The empty call is not a waste: the icon is a function of the whole context, not of
    /// the transitions, so a poll that changes only the connection's health has no events
    /// and still has to reach the menu bar.
    func publish(_ events: [DomainEvent], context: EventContext) {
        let allowed = events.filter { preferences.allows($0.kind) }
        for sink in sinks {
            sink.handle(allowed, context: context)
        }
    }
}
