import AppKit
import SwiftUI
import PRStackCore

/// One row, left to right: unread gutter, status chip in the stack sleeve, title over
/// meta, reviewers, release track — and a ✕ on Done rows.
///
/// The row makes no decisions. Which phrase, which tone, whether the repo name appears,
/// where the row sits in its stack: all of that arrived resolved in ``RowPresentation``,
/// which is a type this package cannot even build against a Mac-only API. What is left
/// here is geometry and colour.
struct PRRowView: View {
    var row: RowPresentation
    var isHovered: Bool
    /// The panel field, so the chip's halo and the reviewer rings sit on the right
    /// background when the row itself is untinted.
    var fieldColor: Color

    var onOpen: () -> Void = {}
    var onOpenIssue: (IssueRef) -> Void = { _ in }
    var onMarkRead: () -> Void = {}
    var onSnooze: (SnoozeOption) -> Void = { _ in }
    var onWake: () -> Void = {}
    var onDismiss: () -> Void = {}
    /// The ⋯ button: opens the row menu, built on demand by ``RowMenuPresenter``.
    var onShowMenu: () -> Void = {}

    var body: some View {
        HStack(spacing: Tokens.Row.gap) {
            unreadGutter
            chipColumn.opacity(contentOpacity)
            titleAndMeta.opacity(contentOpacity)
            trailing
        }
        .padding(.top, Tokens.Row.paddingTop)
        .padding(.trailing, Tokens.Row.paddingTrailing)
        .padding(.bottom, Tokens.Row.paddingBottom)
        .padding(.leading, Tokens.Row.paddingLeading)
        .background(rowBackground)
        .padding(.horizontal, Tokens.Row.horizontalMargin)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        // No `.contextMenu` here: right-click is ``HoverKeyMonitor``'s, which opens the same
        // menu as the ⋯ button and the `S` key — three paths, one builder in
        // ``RowMenuPresenter``. A SwiftUI context menu would rebuild that whole menu, with a
        // submenu entry for every other pull request, on every render of every row.
        // One element per row, not one per control. A panel of 25 rows is 100+ views;
        // exposing each separately turns a glanceable list into a long walk by ear. The
        // named actions below are what keeps that from hiding anything — VoiceOver
        // reaches the issue link and the ✕ through the row's action rotor, so combining
        // the children costs navigation depth and not reachability.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        // One per ticket, not one for "the issue": a pull request that resolves three of
        // them reaches the other two only through the `+N` menu, and combining the
        // children is what put that menu out of reach. Naming each by identifier also
        // makes the rotor say "Open BIL-313" rather than making the user guess which
        // ticket "Open issue" means.
        .accessibilityActions {
            ForEach(Array(row.issues.enumerated()), id: \.offset) { item in
                Button("Open \(item.element.identifier)") { onOpenIssue(item.element) }
            }
            // The rest of the row's actions, by the same rule and for the same reason: the
            // ⋯ menu and the right-click menu are both pointer targets, and combining the
            // row's children is what put them out of reach by ear.
            if row.supports(.markRead) {
                Button(RowAction.markRead.title, action: onMarkRead)
            }
            if row.isSnoozed {
                Button("Wake now", action: onWake)
            }
            if row.supports(.snooze) {
                // The option's own capitalisation, not a lowercased join: `Until Monday`
                // read as "until monday" turns the weekday into a common noun, which is
                // exactly the kind of thing only the rotor would ever say aloud.
                ForEach(rotorSnoozeOptions, id: \.self) { option in
                    Button("\(RowAction.snooze.title): \(option.title)") { onSnooze(option) }
                }
            }
        }
        .accessibilityAction(named: RowAction.dismiss.title, when: row.isDismissible, perform: onDismiss)
    }

    /// What the rotor offers: every plain option, and the targets in this row's own stack.
    ///
    /// Not every target. The submenus can list the whole account behind two entries, but the
    /// rotor is flat, and fifty `Until #N is released` entries would bury the rest of the
    /// row's actions. The stack is what a stacked row is almost always waiting on; anything
    /// further is a pointer away in the row menu.
    private var rotorSnoozeOptions: [SnoozeOption] {
        let stack = row.snoozeTargets.filter(\.isStackMember)
        return SnoozeOption.durations + SnoozeOption.events
            + stack.filter(\.isOpen).map { SnoozeOption.merged($0.id) }
            + stack.map { SnoozeOption.released($0.id) }
    }

    /// A snoozed row is drawn lighter. Applied to the content columns, not the row: the
    /// hover lift, the unread dot and the ⋯ button stay at full strength, so a snoozed row
    /// under the pointer still reads as the row the keys will act on.
    private var contentOpacity: Double {
        row.isSnoozed ? Tokens.Row.snoozedOpacity : 1
    }

    // MARK: - Background

    /// Tint and hover are separate layers, not alternatives. An attention row that is
    /// hovered has to still read as an attention row (§5), so the hover lift goes *over*
    /// the tint rather than replacing it.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Tokens.Row.cornerRadius, style: .continuous)
            .fill(row.isTinted ? Tokens.rowTint(row.chipTone) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Row.cornerRadius, style: .continuous)
                    .fill(isHovered ? Tokens.rowHover.color : Color.clear)
            }
    }

    /// What sits immediately behind the chip and the avatars — the tint when there is one,
    /// the panel field otherwise. Both need it opaque: the reviewer rings are cut apart by
    /// a 1 pt gap of this colour, and a clear one would let the ring behind show through.
    private var haloColor: Color {
        row.isTinted ? Tokens.rowTint(row.chipTone) : fieldColor
    }

    // MARK: - Columns

    /// Reserved whether or not the dot is drawn, so marking a row read never moves the
    /// column of titles.
    private var unreadGutter: some View {
        Circle()
            .fill(row.isUnread ? Tokens.accent.color : Color.clear)
            .frame(width: Tokens.Row.unreadDot, height: Tokens.Row.unreadDot)
            .frame(width: Tokens.Row.unreadGutter)
            .accessibilityHidden(true)
    }

    private var chipColumn: some View {
        StatusChipView(
            tone: row.chipTone,
            glyph: row.chipGlyph,
            // On a stacked row the sleeve is the chip's surround; see ``StatusChipView``.
            haloColor: row.spine.isVisible ? nil : haloColor
        )
        .frame(width: Tokens.Row.chip)
        // Stretched to the row's content height so the sleeve knows how tall its band has
        // to be. The chip stays centred — a frame with no alignment given centres — and
        // the column is 16 pt wide either way, so nothing else in the row moves.
        .frame(maxHeight: .infinity)
        // The sleeve is behind the chip and reaches past the column on all four sides, so
        // it must not participate in layout.
        .background(StackSleeveView(draw: row.spine))
    }

    private var titleAndMeta: some View {
        VStack(alignment: .leading, spacing: Tokens.Row.stackGap) {
            Text(row.title)
                .font(Tokens.text(Tokens.Row.titleSize, Tokens.titleWeight(row.emphasis)))
                .foregroundStyle(Tokens.titleColor(row.emphasis))
                .lineLimit(1)
                .truncationMode(.tail)

            MetaLineView(tokens: row.meta, issues: row.issues, onOpenIssue: onOpenIssue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trailing: some View {
        HStack(spacing: Tokens.Row.gap) {
            if !row.reviewers.isEmpty {
                ReviewerAvatarsView(
                    reviewers: row.reviewers,
                    overflow: row.overflowReviewers,
                    haloColor: haloColor
                )
                .opacity(contentOpacity)
            }
            ReleaseTrackView(segments: row.segments)
                .opacity(contentOpacity)
            if row.isDismissible {
                // The keyboard's `X` is an accelerator, never the only path (§5).
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Tokens.textTertiary.color)
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isHovered ? Tokens.rowHover.color : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss \(row.title)")
            }
        }
        .fixedSize()
        .overlay(alignment: .trailing) { menuButton }
    }

    /// The ⋯ that opens the row menu: the discoverable path to the actions `R`, `S` and `L`
    /// accelerate, since a right-click menu is not something a panel advertises.
    ///
    /// Drawn as an **overlay over the release track**, not as a column of its own. In the
    /// flow it would need a slot reserved on every row — the pointer running down the list
    /// must not shuffle the tracks sideways — and that slot would widen every row in design
    /// 2a to make room for a control 2a does not draw. Covering the track while the pointer
    /// is on the row is the trade design `1d` already makes, where the hovered row's trailing
    /// slot reads `snooze`, and the track is back the moment the pointer leaves.
    ///
    /// Done rows keep the ✕ instead: dismissal is the whole of what they offer, and it is
    /// already in the flow.
    ///
    /// A plain button, not a SwiftUI `Menu`: the menu is built by ``RowMenuPresenter`` when
    /// it is opened, because a `Menu` here would rebuild its contents — a submenu entry for
    /// every other pull request — on every render of every row.
    ///
    /// Mounted for every non-Done row and hidden by **opacity**, rather than added and
    /// removed with the hover, so the hover arriving changes nothing about the row's layout.
    /// `allowsHitTesting` is what keeps the invisible state from being a click target the
    /// row's own tap gesture never sees.
    @ViewBuilder
    private var menuButton: some View {
        if !row.isDismissible {
            Button(action: onShowMenu) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.textSecondary.color)
                    .frame(width: 18, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            // Opaque, and the hovered row's own two layers in order: what
                            // it covers has to stop showing through.
                            .fill(haloColor)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Tokens.rowHover.color)
                            }
                    )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            // The row is one accessibility element and its rotor already carries every
            // entry this menu holds; exposing the menu as well would offer each action
            // twice by ear.
            .accessibilityHidden(true)
        }
    }
}

/// Compared on what it draws, so a row whose inputs did not change is not re-rendered.
///
/// The hovered row is published on the controller, and the panel re-evaluates its body every
/// time it changes — which, while a long list scrolls under a still pointer, is every row
/// that passes beneath it. Without this each of those changes re-rendered every row in the
/// list; with it, only the row that lost the hover and the row that gained it.
///
/// The closures are left out on purpose. Each one calls the controller with this row's id,
/// so two rows with the same ``RowPresentation`` have closures that do the same thing.
extension PRRowView: Equatable {
    nonisolated static func == (lhs: PRRowView, rhs: PRRowView) -> Bool {
        lhs.row == rhs.row && lhs.isHovered == rhs.isHovered && lhs.fieldColor == rhs.fieldColor
    }
}

private extension View {
    /// `accessibilityAction(named:)`, applied only when the row actually has the action.
    /// An "Open issue" entry on a row with no ticket is a rotor entry that does nothing.
    @ViewBuilder
    func accessibilityAction(
        named name: String,
        when condition: Bool,
        perform action: @escaping () -> Void
    ) -> some View {
        if condition {
            accessibilityAction(named: Text(name), action)
        } else {
            self
        }
    }
}

/// The meta line: #number · [repo ·] phrase · [snooze ·] age · [identifier · +N].
///
/// Everything in brackets is conditional — the repo name on the list spanning more than
/// one repository, the snooze's condition on a row still asleep, the identifier on the pull
/// request naming a ticket at all. ``RowPresentation`` decides all of it; this view only
/// draws what arrives.
///
/// Laid out as an `HStack` of separate views rather than one attributed string because
/// the identifier and the `+N` affix are both click targets, and because the phrase's
/// colour is per-token. The identifier truncates last: it is the only token that
/// identifies the work rather than the pull request.
struct MetaLineView: View {
    var tokens: [MetaToken]
    var issues: [IssueRef]
    var onOpenIssue: (IssueRef) -> Void

    var body: some View {
        HStack(spacing: Tokens.Row.metaGap) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { item in
                view(for: item.element)
            }
        }
        .font(Tokens.text(Tokens.Row.metaSize))
        .lineLimit(1)
    }

    @ViewBuilder
    private func view(for token: MetaToken) -> some View {
        switch token {
        case .issue(_, let url):
            Button {
                if let issue = issues.first { onOpenIssue(issue) } else { NSWorkspace.shared.open(url) }
            } label: {
                Text(token.text).foregroundStyle(Tokens.accent.color)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

        case .additionalIssues:
            // Tertiary grey, so it reads as a count rather than a second link — but it
            // still opens the full list, which is the only way to reach the other tickets.
            Menu {
                ForEach(Array(issues.enumerated()), id: \.offset) { item in
                    Button(menuTitle(for: item.element)) { onOpenIssue(item.element) }
                }
            } label: {
                // The font goes on the label, not on the `Menu`: a menu's title takes the
                // system control size and ignores the line's environment font, which is
                // what made `+2` render a couple of points larger than every token beside
                // it.
                Text(token.text)
                    .font(Tokens.text(Tokens.Row.metaSize))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Tokens.textTertiary.color)
            // Pulled back against the stack's own spacing: the affix belongs to the
            // identifier in front of it, not to the line, so it sits a third of a gap
            // away rather than the full one every other token gets.
            .padding(.leading, Tokens.Row.metaAffixGap - Tokens.Row.metaGap)

        case .repository:
            // Truncates before the number does: the number is what the row is called.
            Text(token.text)
                .foregroundStyle(Tokens.textTertiary.color)
                .truncationMode(.middle)

        case .number, .age, .snooze:
            Text(token.text)
                .foregroundStyle(Tokens.textTertiary.color)
                .layoutPriority(1)

        case .phrase(let phrase, let tone):
            Text(phrase)
                .font(Tokens.text(Tokens.Row.metaSize, .semibold))
                .foregroundStyle(Tokens.foreground(tone))
                .layoutPriority(1)
        }
    }

    private func menuTitle(for issue: IssueRef) -> String {
        guard let project = issue.projectName else { return issue.identifier }
        return "\(issue.identifier) · \(project)"
    }
}
