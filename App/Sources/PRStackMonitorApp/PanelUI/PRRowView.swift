import AppKit
import SwiftUI
import PRStackCore

/// One row, left to right: unread gutter, status chip on the spine, title over meta,
/// reviewers, release track — and a ✕ on Done rows.
///
/// The row makes no decisions. Which phrase, which tone, whether the repo name appears,
/// which way the spine draws: all of that arrived resolved in ``RowPresentation``, which
/// is a type this package cannot even build against a Mac-only API. What is left here is
/// geometry and colour.
struct PRRowView: View {
    var row: RowPresentation
    var isHovered: Bool
    /// The panel field, so the chip's halo and the reviewer rings sit on the right
    /// background when the row itself is untinted.
    var fieldColor: Color

    var onOpen: () -> Void = {}
    var onOpenIssue: (IssueRef) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: Tokens.Row.gap) {
            unreadGutter
            chipColumn
            titleAndMeta
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
        // One element per row, not one per control. A panel of 25 rows is 100+ views;
        // exposing each separately turns a glanceable list into a long walk by ear. The
        // named actions below are what keeps that from hiding anything — VoiceOver
        // reaches the issue link and the ✕ through the row's action rotor, so combining
        // the children costs navigation depth and not reachability.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: "Open issue", when: row.issues.first != nil) {
            if let issue = row.issues.first { onOpenIssue(issue) }
        }
        .accessibilityAction(named: "Dismiss", when: row.isDismissible, perform: onDismiss)
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
    /// the panel field otherwise. Both need it opaque: a halo drawn in a clear colour
    /// stops hiding the spine.
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
        StatusChipView(tone: row.chipTone, glyph: row.chipGlyph, haloColor: haloColor)
            .frame(width: Tokens.Row.chip)
            // The spine is behind the chip and its halo, and it runs past the row's own
            // bounds, so it must not participate in layout.
            .background(StackSpineView(draw: row.spine))
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
            }
            ReleaseTrackView(segments: row.segments)
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

/// The meta line: identifier · repo · #number · phrase · age.
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
            Menu(token.text) {
                ForEach(Array(issues.enumerated()), id: \.offset) { item in
                    Button(menuTitle(for: item.element)) { onOpenIssue(item.element) }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Tokens.textTertiary.color)

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
