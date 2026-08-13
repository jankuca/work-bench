import AppKit
import SwiftUI

/// The popover's content: the SwiftUI panel, sized to what it draws, and clickable on the
/// **first** click.
///
/// `NSHostingController` does the sizing on its own — `sizingOptions = [.preferredContentSize]`
/// is what this replaced — and it is the shorter way to write the first half of this file.
/// What it cannot do is answer `acceptsFirstMouse`: the hosting view is one it builds, and
/// `NSHostingView` says no. AppKit swallows the click that brings an inactive app forward
/// unless the view under the pointer says otherwise, so with the panel set to stay open
/// (``AppDefaults/PanelDismissal/manual``) — where the app spends most of the panel's life in
/// the background — every visit would cost two clicks: one to activate, which goes nowhere,
/// and one for the row the user was aiming at the whole time.
///
/// So the hosting view is ours, and the sizing that came free has to be done here.
@MainActor
final class PanelHostingController<Content: View>: NSViewController {
    private let hosting: FirstMouseHostingView<Content>

    init(rootView: Content) {
        // Configured through a local rather than through the property: reading `self.hosting`
        // before `super.init` is not allowed, and writing it is the whole of phase one.
        let hosting = FirstMouseHostingView(rootView: rootView)
        // The intrinsic size only. `.minSize` and `.maxSize` would pin the view to what
        // SwiftUI wants with constraints, and ``updatePreferredContentSize()`` below already
        // tells the popover the same number — two authorities on one size, whose
        // disagreement during a resize surfaces as unsatisfiable constraints in the log
        // rather than as anything on screen.
        hosting.sizingOptions = [.intrinsicContentSize]
        self.hosting = hosting
        super.init(nibName: nil, bundle: nil)
    }

    /// Required by `NSViewController` and unreachable: there is no nib in this app, and this
    /// controller is built in one place.
    required init?(coder: NSCoder) {
        fatalError("PanelHostingController is not loaded from a nib")
    }

    override func loadView() {
        view = hosting
        // Before the popover ever measures: with `preferredContentSize` still zero it falls
        // back to the view's frame, which is also zero until something lays it out — and a
        // popover that opens at zero and grows is a flicker on every open.
        updatePreferredContentSize()
    }

    /// The panel's height follows its content — a poll that adds a row makes it taller, and
    /// the all-clear state is a short panel rather than an 800 pt one with a message at the
    /// top. SwiftUI reports that by invalidating the hosting view's intrinsic size, which
    /// arrives here as a layout pass; `preferredContentSize` is what turns it into a popover
    /// of the right size.
    override func viewDidLayout() {
        super.viewDidLayout()
        updatePreferredContentSize()
    }

    private func updatePreferredContentSize() {
        let size = contentSize
        // Zero is what an unmeasured hosting view answers, and writing it would collapse the
        // popover. Unchanged is skipped because the write is what makes the popover resize,
        // and a resize is another layout pass — this guard is what stops the two calling
        // each other.
        guard size.width > 0, size.height > 0, size != preferredContentSize else { return }
        preferredContentSize = size
    }

    /// What SwiftUI wants the panel to be, asked two ways.
    ///
    /// The intrinsic size is the direct answer and the one the sizing option above exists to
    /// produce; `fittingSize` is the layout engine's, and it is the fallback for the moment
    /// before the first measurement, when `intrinsicContentSize` is `noIntrinsicMetric` in
    /// both axes.
    private var contentSize: NSSize {
        let intrinsic = hosting.intrinsicContentSize
        guard intrinsic.width > 0, intrinsic.height > 0 else { return hosting.fittingSize }
        return intrinsic
    }
}

/// An `NSHostingView` that takes the click that brought the app forward, rather than
/// spending it on the activation.
///
/// The whole of the reason this subclass exists — see ``PanelHostingController``. SwiftUI has
/// no modifier for it: `acceptsFirstMouse` is asked of the `NSView` the click hit, and inside
/// a hosted tree that is the hosting view for everything the user can aim at.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
