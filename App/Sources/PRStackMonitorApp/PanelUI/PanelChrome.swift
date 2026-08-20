import SwiftUI
import PRStackCore

/// `Pull requests` · `10 in review · 2 drafts · 3 shipping` · refresh · overflow menu.
struct PanelHeaderView: View {
    var header: HeaderPresentation
    var onRefresh: () -> Void
    var onMarkAllRead: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(header.title)
                .font(Tokens.text(13, .semibold))
                .foregroundStyle(Tokens.textPrimary.color)
                .fixedSize()

            if !header.summary.isEmpty {
                Text(header.summary)
                    .font(Tokens.text(11.5))
                    .foregroundStyle(Tokens.textTertiary.color)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary.color)
                    .frame(width: 22, height: 22)
                    // The control does not spin: a poll takes a few hundred milliseconds
                    // and an animation that short reads as a glitch. Disabling it is the
                    // honest "in progress", and it also stops a second poll being queued.
                    .opacity(header.isRefreshing ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(header.isRefreshing)
            .accessibilityLabel("Refresh")

            Menu {
                Button("Mark all read", action: onMarkAllRead)
                Divider()
                Button("Settings…", action: onOpenSettings)
                Divider()
                // The only way out of the app that does not involve Activity Monitor.
                // ⌘Q reaches the same place (``MainMenu``), but only while the app is
                // active — and an app whose entire UI is a popover spends most of its life
                // not being active, so the way out has to be inside the popover.
                Button("Quit PRStackMonitor", action: onQuit)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary.color)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Tokens.chrome.color)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// The 1 pt rule between the chrome and the field.
private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.separator.color)
            .frame(height: 1)
    }
}

/// The amber strip over cached rows. Only an authentication failure raises it — the app
/// can retry a timeout by itself, and cannot retry an expired token at all.
struct PanelBannerView: View {
    var banner: BannerPresentation
    var onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Tokens.amber.color)
                .frame(width: 6, height: 6)
            Text(banner.message)
                .font(Tokens.text(11.5, .medium))
                .foregroundStyle(Tokens.amberText.color)
            Spacer(minLength: 0)
            Button(banner.actionTitle, action: onReconnect)
                .buttonStyle(.plain)
                .font(Tokens.text(11, .semibold))
                .foregroundStyle(Tokens.amber.color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Tokens.amberChip.color)
        .accessibilityElement(children: .combine)
    }
}

/// Project name (or `Other`, or `Done`), its count, and `Clear all` on Done.
///
/// Plain text with no colour, whichever section it is: colour means status and nothing
/// else (PRD §11). `Done` is greyed rather than tinted, which is a value of the text
/// token, not a status colour.
struct SectionHeaderView: View {
    var section: SectionPresentation
    var isFirst: Bool
    var onClearAll: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.heading)
                .font(Tokens.text(Tokens.Section.headingSize, Tokens.Section.headingWeight))
                .foregroundStyle(section.isMuted ? Tokens.textTertiary.color : Tokens.sectionHeading.color)
            Text("\(section.count)")
                .font(Tokens.text(Tokens.Section.countSize))
                .foregroundStyle(Tokens.sectionCount.color)
            Spacer(minLength: 0)
            if let title = section.clearAllTitle {
                Button(title, action: onClearAll)
                    .buttonStyle(.plain)
                    .font(Tokens.text(11, .medium))
                    .foregroundStyle(Tokens.accent.color)
            }
        }
        .padding(.horizontal, Tokens.Section.horizontalPadding)
        .padding(.top, isFirst ? Tokens.Section.firstTopPadding : Tokens.Section.topPadding)
        .padding(.bottom, Tokens.Section.bottomPadding)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Sync dot, `synced 34s ago`, `Mark all read`, `Settings`.
///
/// The dot-and-label is a control, not just a readout: clicking it opens a popover of the
/// sync's steps — live while a poll runs, the last sync's between them. It stays a plain label
/// until a sync has actually produced steps, so there is nothing to open onto an empty list.
struct PanelFooterView: View {
    var footer: FooterPresentation
    var onMarkAllRead: () -> Void
    var onOpenSettings: () -> Void
    /// Toggles the step card, which ``PanelView`` owns and overlays — the footer only asks for
    /// it, so the card can float above the rows rather than being clipped inside the footer.
    var onToggleProgress: () -> Void = {}
    /// Whether that card is showing, for the chevron's direction.
    var isProgressShown: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                syncControl
                if let note = footer.linearNote {
                    // Tertiary and unaccented on purpose. Linear being down does not make
                    // the rows wrong, only their headings possibly behind, so it reads as a
                    // footnote rather than as the amber the sync dot uses (§4).
                    Text("· " + note)
                        .font(Tokens.text(11))
                        .foregroundStyle(Tokens.textTertiary.color)
                        .help(footer.detail ?? note)
                }
                Spacer(minLength: 0)
                if footer.showsMarkAllRead {
                    Button("Mark all read", action: onMarkAllRead)
                        .buttonStyle(.plain)
                        .font(Tokens.text(11.5))
                        .foregroundStyle(Tokens.textSecondary.color)
                    Rectangle()
                        .fill(Tokens.separator.color)
                        .frame(width: 1, height: 11)
                }
                Button("Settings", action: onOpenSettings)
                    .buttonStyle(.plain)
                    .font(Tokens.text(11.5))
                    .foregroundStyle(Tokens.textSecondary.color)
            }

            // Only while it lasts, and only for the failures nothing else states — so the
            // footer is one line in every healthy state and grows a second one exactly
            // when there is something to read.
            if let error = footer.errorMessage {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Tokens.amber.color)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(Tokens.text(11))
                        .foregroundStyle(Tokens.amberText.color)
                        // Two lines is enough for every message the kits produce, and a
                        // cap is what keeps a server's HTML error page from pushing the
                        // rows off the panel.
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(error)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Tokens.chrome.color)
        .overlay(alignment: .top) { Hairline() }
    }

    /// The sync dot and its text. A button that opens the step popover once a sync has
    /// produced steps, and a plain label until then — an empty list is nothing to open onto.
    @ViewBuilder
    private var syncControl: some View {
        if footer.progressSteps.isEmpty {
            HStack(spacing: 8) {
                SyncDot(tone: footer.syncTone, isSyncing: footer.isSyncing)
                Text(footer.syncText)
                    .font(Tokens.text(11))
                    .foregroundStyle(Tokens.textTertiary.color)
            }
            .help(footer.detail ?? footer.syncText)
        } else {
            Button(action: onToggleProgress) {
                HStack(spacing: 6) {
                    SyncDot(tone: footer.syncTone, isSyncing: footer.isSyncing)
                    Text(footer.syncText)
                        .font(Tokens.text(11))
                        .foregroundStyle(Tokens.textTertiary.color)
                    // The affordance that this line opens something, and the direction it
                    // opens: the card lifts up off a footer pinned to the panel's bottom, so
                    // the chevron points up to open and flips down to close.
                    Image(systemName: isProgressShown ? "chevron.down" : "chevron.up")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Tokens.textTertiary.color)
                        .opacity(0.7)
                }
                // The gaps between dot, text and chevron are part of the hit target, so the
                // whole label clicks rather than only its glyphs.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(footer.detail ?? "Show sync steps")
        }
    }
}

/// The 5 pt sync dot, which pulses while a poll is in flight.
///
/// The pulse is the whole point of the state existing separately from the text beside it:
/// "syncing…" appears and disappears within a few hundred milliseconds on a healthy poll,
/// which is long enough to read only if you happened to be looking. Motion is what gets
/// noticed peripherally, and a poll that is *not* finishing quickly — the case where the
/// question is actually being asked — keeps it going for as long as it takes.
private struct SyncDot: View {
    var tone: StatusTone
    var isSyncing: Bool

    /// A repeating pulse is exactly the kind of motion Reduce Motion is turned on to stop,
    /// and it would run for the whole of every poll. The text beside the dot already says
    /// `syncing…`, so honouring the preference costs the state nothing: it stays legible
    /// without the animation, which is the test for whether motion was decoration.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pulses: Bool { isSyncing && !reduceMotion }

    var body: some View {
        let dot = Circle()
            .fill(Tokens.foreground(tone))
            .frame(width: 5, height: 5)
            .accessibilityHidden(true)

        // A `.animation(_:value:)` holding a `repeatForever` curve was the wrong tool: while
        // that pulse is live it is the view's active animation, so the *next* change to the
        // dot's position gets swept into it too — and the footer moves the dot constantly
        // (the text flips to `syncing…`, the error and Linear lines come and go, the panel
        // resizes as rows load). The result was the dot sliding up and down the popover on
        // an endless autoreverse instead of fading in place.
        //
        // A `PhaseAnimator` confines its animation to the transition between the phases of
        // its own content — here, opacity — so a relayout that shifts the dot is never part
        // of it. Mounting it only while `pulses` also means nothing runs once the poll lands
        // or when Reduce Motion is on: the branch is torn down and the plain dot is all that
        // is left.
        if pulses {
            dot.phaseAnimator([false, true]) { content, isDim in
                content.opacity(isDim ? 0.3 : 1)
            } animation: { _ in
                .easeInOut(duration: 0.55)
            }
        } else {
            dot
        }
    }
}

/// `Everything's clear` — a stated message, not an empty list (§5).
struct AllClearView: View {
    var message: AllClearMessage

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Tokens.success.color)
                .padding(.bottom, 6)
            Text(message.title)
                .font(Tokens.text(13.5, .semibold))
                .foregroundStyle(Tokens.textPrimary.color)
            Text(message.detail)
                .font(Tokens.text(11.5))
                .foregroundStyle(Tokens.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 34)
        .accessibilityElement(children: .combine)
    }
}

/// The sync checklist the footer's label opens: a floating card of what the poll is doing,
/// or — between polls — what the last one did.
///
/// A *card inside the panel*, not a second `NSPopover`: the panel is itself a transient
/// popover, and a nested one would fight it for focus and be dismissed by the same click that
/// opened it. Drawn as an overlay in ``PanelView`` it has none of that trouble, and it reads
/// as a popover all the same — rounded, bordered, lifted off the panel with a shadow.
///
/// A list, left-aligned, because it is a sequence of steps and a sequence reads down a column.
/// Each step carries the same three-state vocabulary the rest of the panel uses: a done step
/// takes the success check the all-clear view leads with, an active one a dot that pulses
/// *only while a poll is actually running*, a pending one a quiet outline. The pulse gate is
/// what keeps an interrupted step — active when the poll stopped — from pulsing on forever in
/// the last-sync summary.
struct SyncProgressPopover: View {
    var steps: [SyncStepPresentation]
    /// Whether a poll is in flight right now (``FooterPresentation/isSyncing``). Decides both
    /// the header wording and whether the active step pulses.
    var isSyncing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(isSyncing ? "Syncing…" : "Last sync")
                .font(Tokens.text(12, .semibold))
                .foregroundStyle(Tokens.textPrimary.color)

            VStack(alignment: .leading, spacing: 9) {
                // Keyed by stage, not position: a conditional step appearing pushes nothing
                // else's identity, so the rows that were already there stay put rather than
                // being reused for a different step.
                ForEach(steps, id: \.stage) { step in
                    SyncStepRow(step: step, isSyncing: isSyncing)
                }
            }
        }
        .frame(width: 240, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tokens.chrome.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tokens.separator.color, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 14, y: 5)
        .accessibilityElement(children: .combine)
    }
}

/// One line of the checklist: state glyph, label, and its running count.
private struct SyncStepRow: View {
    var step: SyncStepPresentation
    var isSyncing: Bool

    var body: some View {
        HStack(spacing: 9) {
            SyncStepGlyph(state: step.state, isSyncing: isSyncing)
                // A fixed box so every label starts at the same x whatever glyph precedes it.
                .frame(width: 15, height: 15)
            Text(step.title)
                .font(Tokens.text(12, step.state == .active ? .medium : .regular))
                .foregroundStyle(
                    step.state == .pending ? Tokens.textTertiary.color : Tokens.textPrimary.color
                )
            if let detail = step.detail {
                Text(detail)
                    .font(Tokens.text(11))
                    .foregroundStyle(Tokens.textTertiary.color)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The state glyph: a filled check for done, a dot for active — pulsing only while a poll
/// runs — and an outline for pending.
private struct SyncStepGlyph: View {
    var state: SyncStepPresentation.State
    var isSyncing: Bool

    /// The same reasoning as ``SyncDot``: the pulse is exactly the motion Reduce Motion turns
    /// off, and the label beside it already says which step is running, so dropping the
    /// animation costs nothing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Tokens.success.color)
                .accessibilityHidden(true)
        case .active:
            activeDot
        case .pending:
            Circle()
                .strokeBorder(Tokens.textTertiary.color.opacity(0.5), lineWidth: 1.5)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var activeDot: some View {
        let dot = Circle()
            .fill(Tokens.accent.color)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)

        // Pulses only while a poll is actually in flight and motion is allowed. A step left
        // active because its poll was interrupted sits as a static dot in the last-sync
        // summary — a `PhaseAnimator` for the same reason ``SyncDot`` uses one: it confines
        // the animation to the dot's own opacity, so a relayout is never swept into an
        // endless autoreverse.
        if isSyncing, !reduceMotion {
            dot.phaseAnimator([false, true]) { content, isDim in
                content.opacity(isDim ? 0.3 : 1)
            } animation: { _ in
                .easeInOut(duration: 0.6)
            }
        } else {
            dot
        }
    }
}

/// Design 1e: nothing connected yet.
struct ConnectPromptView: View {
    var prompt: ConnectPrompt
    var onConnectGitHub: () -> Void
    var onConnectLinear: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                sourceGlyph(systemName: "chevron.left.forwardslash.chevron.right", tint: Tokens.textSecondary.color)
                Rectangle()
                    .fill(Tokens.separator.color)
                    .frame(width: 14, height: 1.5)
                sourceGlyph(systemName: "circle", tint: Tokens.accent.color)
            }
            .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(prompt.title)
                    .font(Tokens.text(13.5, .semibold))
                    .foregroundStyle(Tokens.textPrimary.color)
                Text(prompt.detail)
                    .font(Tokens.text(11.5))
                    .foregroundStyle(Tokens.textSecondary.color)
                    .multilineTextAlignment(.center)
            }

            // Only the accounts that are actually missing, and no row at all when both are
            // set — an empty `HStack` still takes the enclosing spacing, which would leave
            // the message floating above a gap where the buttons used to be.
            if prompt.githubActionTitle != nil || prompt.linearActionTitle != nil {
                HStack(spacing: 8) {
                    if let title = prompt.githubActionTitle {
                        connectButton(
                            title,
                            fill: Tokens.solidNeutral.color,
                            label: Tokens.solidNeutralLabel.color,
                            action: onConnectGitHub
                        )
                    }
                    if let title = prompt.linearActionTitle {
                        connectButton(
                            title,
                            fill: Tokens.solidAccent.color,
                            label: .white,
                            action: onConnectLinear
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 30)
    }

    private func sourceGlyph(systemName: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Tokens.chrome.color)
            .frame(width: 34, height: 34)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
            }
    }

    private func connectButton(
        _ title: String,
        fill: Color,
        label: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.text(11.5, .medium))
                .foregroundStyle(label)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        }
        .buttonStyle(.plain)
    }
}
