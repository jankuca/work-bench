import SwiftUI
import PRStackCore

/// `Pull requests` · `10 in review · 3 shipping` · refresh · overflow menu.
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
struct PanelFooterView: View {
    var footer: FooterPresentation
    var onMarkAllRead: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                SyncDot(tone: footer.syncTone, isSyncing: footer.isSyncing)
                Text(footer.syncText)
                    .font(Tokens.text(11))
                    .foregroundStyle(Tokens.textTertiary.color)
                    .help(footer.detail ?? footer.syncText)
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

    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(Tokens.foreground(tone))
            .frame(width: 5, height: 5)
            .opacity(isSyncing && isDim ? 0.3 : 1)
            // One state change plus `repeatForever` is the whole animation: the dot is
            // handed a single new value and the repetition comes from the curve, so there
            // is no timer here and nothing to stop when the poll lands.
            .animation(pulse, value: isDim)
            // Driven off the flag rather than `onAppear`, because the footer is rebuilt in
            // place: the view does not re-appear when a poll starts, its input changes.
            .onChange(of: isSyncing) { _, syncing in isDim = syncing }
            .onAppear { isDim = isSyncing }
            .accessibilityHidden(true)
    }

    private var pulse: Animation {
        isSyncing ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true) : .default
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

            HStack(spacing: 8) {
                connectButton(prompt.githubActionTitle, fill: Tokens.textPrimary.color, action: onConnectGitHub)
                connectButton(prompt.linearActionTitle, fill: Tokens.accent.color, action: onConnectLinear)
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

    private func connectButton(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.text(11.5, .medium))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
        }
        .buttonStyle(.plain)
    }
}
