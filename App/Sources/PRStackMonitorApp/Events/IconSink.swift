import Foundation
import PRStackCore

/// Whatever the menu bar item is. A protocol so ``IconSink`` does not reach into AppKit,
/// and so the sink can be exercised against a recording double.
@MainActor
protocol IconPresenter: AnyObject {
    func show(_ state: IconState)
}

/// v1's only sink: it keeps the menu bar icon in step with derivation.
///
/// The icon is a pure function of the context, not of the transitions, so `handle` reads
/// `context.icon` and ignores `events` entirely. That is not a placeholder — it is the
/// point. Deciding what the icon shows is core's job (``IconState/resolve(github:attentionCount:unreadCount:)``,
/// table-tested off-device); this sink's job is to be the one place that decision reaches
/// AppKit, and to prove the bus is wired before there is a second consumer of it.
///
/// The presenter is held weakly: the status item owns the panel controller, which owns the
/// bus, which owns this.
@MainActor
final class IconSink: EventSink {
    private weak var presenter: (any IconPresenter)?
    /// The last state pushed, so an unchanged icon is not redrawn on every poll. Redrawing
    /// is cheap; assigning `button.image` is not free of flicker on every menu bar.
    private var shown: IconState?

    /// - Parameter presenter: held weakly; the status item outlives this sink, not the
    ///   other way round.
    init(presenter: any IconPresenter) {
        self.presenter = presenter
    }

    func handle(_ events: [DomainEvent], context: EventContext) {
        guard shown != context.icon else { return }
        shown = context.icon
        presenter?.show(context.icon)
    }
}
