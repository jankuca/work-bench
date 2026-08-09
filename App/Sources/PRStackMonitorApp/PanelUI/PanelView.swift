import AppKit
import SwiftUI
import PRStackCore

/// The panel: header, optional banner, scrolling body, footer.
///
/// 440 pt wide, height to content up to 800 pt and then it scrolls. Nothing collapses —
/// not stacks, not projects — which is what makes position stability hold: a row never
/// moves because something above it folded (IMPLEMENTATION_PLAN §5).
struct PanelView: View {
    @ObservedObject var controller: PanelController

    @State private var contentHeight: CGFloat = Tokens.Panel.minBodyHeight

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                header: controller.panel.header,
                onRefresh: { controller.refresh() },
                onMarkAllRead: { controller.markAllRead() },
                onOpenSettings: { controller.openSettings() }
            )

            if let banner = controller.panel.banner {
                PanelBannerView(banner: banner, onReconnect: { controller.openSettings() })
            }

            content(for: controller.panel.body)

            PanelFooterView(
                footer: controller.panel.footer,
                onMarkAllRead: { controller.markAllRead() },
                onOpenSettings: { controller.openSettings() }
            )
        }
        .frame(width: Tokens.Panel.width)
        .background(Tokens.field.color)
    }

    @ViewBuilder
    private func content(for body: PanelPresentation.Body) -> some View {
        switch body {
        case .sections(let sections):
            ScrollView(.vertical) {
                // A plain `VStack`, not `LazyVStack`: the height below is measured from
                // this stack, and a lazy one only lays out what is on screen — it would
                // measure one screenful and report that as the whole list.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { item in
                        section(item.element, isFirst: item.offset == 0)
                    }
                }
                .padding(.bottom, 8)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            // Height to content, capped. `.frame(maxHeight:)` on its own would stretch a
            // three-row panel to the full 800.
            .frame(height: min(max(contentHeight, Tokens.Panel.minBodyHeight), Tokens.Panel.maxHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }

        case .allClear(let message):
            AllClearView(message: message)
                .frame(minHeight: Tokens.Panel.minBodyHeight)

        case .connect(let prompt):
            ConnectPromptView(
                prompt: prompt,
                onConnectGitHub: { controller.openSettings() },
                onConnectLinear: { controller.openSettings() }
            )
            .frame(minHeight: Tokens.Panel.minBodyHeight)
        }
    }

    @ViewBuilder
    private func section(_ section: SectionPresentation, isFirst: Bool) -> some View {
        SectionHeaderView(
            section: section,
            isFirst: isFirst,
            onClearAll: { controller.clearDone() }
        )
        ForEach(Array(section.rows.enumerated()), id: \.offset) { item in
            PRRowView(
                row: item.element,
                isHovered: controller.hovered == item.element.id,
                fieldColor: Tokens.field.color,
                onOpen: { controller.open(row: item.element) },
                onOpenIssue: { controller.open($0.url) },
                onMarkRead: { controller.markRead(item.element.id) },
                onSnooze: { controller.snooze(item.element.id, for: $0) },
                onWake: { controller.wake(item.element.id) },
                onDismiss: { controller.dismiss(item.element.id) }
            )
            // The hovered row lives on the controller, not in this view: it is the target
            // of the key monitor, which is an AppKit object outside the view tree.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    // `.active` arrives on every pointer move inside the row, and the
                    // hovered id is published — assigning the same value again would
                    // re-render the whole panel per mouse move.
                    if controller.hovered != item.element.id { controller.hovered = item.element.id }
                case .ended:
                    // Only clear what this row set. As the pointer crosses a boundary the
                    // two rows' `ended` and `active` can arrive in either order, and
                    // clearing unconditionally would drop the highlight the row below
                    // just claimed.
                    if controller.hovered == item.element.id { controller.hovered = nil }
                }
            }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
