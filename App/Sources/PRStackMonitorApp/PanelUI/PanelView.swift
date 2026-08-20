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
                onOpenSettings: { controller.openSettings() },
                onQuit: { controller.quit() }
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

        case .syncing(let progress):
            SyncProgressView(progress: progress)
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
        // Keyed by `PRID`, not by position. With the offset as identity SwiftUI reuses the
        // view at each index for whatever row lands there, so a poll that inserts or
        // removes one moves every row below it into a neighbour's view — and the hover
        // highlight, which is now also the keyboard's target, would stay where the pointer
        // is not.
        ForEach(section.rows, id: \.id) { row in
            PRRowView(
                row: row,
                isHovered: controller.hovered == row.id,
                fieldColor: Tokens.field.color,
                onOpen: { controller.open(row: row) },
                onOpenIssue: { controller.open($0.url) },
                onMarkRead: { controller.markRead(row.id) },
                onSnooze: { controller.snooze(row.id, for: $0) },
                onWake: { controller.wake(row.id) },
                onDismiss: { controller.dismiss(row.id) }
            )
            // The hovered row lives on the controller, not in this view: it is the target
            // of the key monitor, which is an AppKit object outside the view tree.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    // `.active` arrives on every pointer move inside the row, and the
                    // hovered id is published — assigning the same value again would
                    // re-render the whole panel per mouse move.
                    if controller.hovered != row.id { controller.hovered = row.id }
                case .ended:
                    // Only clear what this row set. As the pointer crosses a boundary the
                    // two rows' `ended` and `active` can arrive in either order, and
                    // clearing unconditionally would drop the highlight the row below
                    // just claimed.
                    if controller.hovered == row.id { controller.hovered = nil }
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
