import SwiftUI
import PRStackCore

// The four small pieces a row is built from. Split out because each one has a geometry
// that has to survive the others changing: the sleeve is what makes a stack read as one
// object, and the reviewer ring is what makes a state readable without colour.

/// The 16 pt status chip, with its 6 pt mark.
///
/// The `haloColor` is the row's own background, painted as a 3 pt ring so the chip keeps
/// a clean edge against whatever it sits on. It is `nil` on a stacked row: there the
/// ``StackSleeveView`` is what surrounds the chip, and a ring of opaque row background
/// would punch a hole through the sleeve at every member.
struct StatusChipView: View {
    var tone: StatusTone
    var glyph: ChipGlyph
    var haloColor: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Row.chipRadius, style: .continuous)
            .fill(Tokens.chip(tone))
            .frame(width: Tokens.Row.chip, height: Tokens.Row.chip)
            .overlay(mark)
            .background(halo)
    }

    @ViewBuilder
    private var halo: some View {
        if let haloColor {
            RoundedRectangle(cornerRadius: Tokens.Row.chipRadius + Tokens.Row.chipHalo, style: .continuous)
                .fill(haloColor)
                .padding(-Tokens.Row.chipHalo)
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch glyph {
        case .dot:
            Circle()
                .fill(Tokens.foreground(tone))
                .frame(width: Tokens.Row.chipDot, height: Tokens.Row.chipDot)
        case .bar:
            Capsule()
                .fill(Tokens.foreground(tone))
                .frame(width: Tokens.Row.chipDot, height: 2)
        case .slash:
            Capsule()
                .fill(Tokens.foreground(tone))
                .frame(width: 7, height: 2)
                .rotationEffect(.degrees(45))
        }
    }
}

/// The rounded sleeve that groups the chips of one stack run.
///
/// Each member draws only its own band, and the bands tile into one continuous sleeve —
/// no row ever needs to know its neighbours' geometry (§5). What makes that work is the
/// chip column being stretched to the row's *content* height before this is used as its
/// background: a band that runs from `-paddingTop` to `height + paddingBottom` is exactly
/// the full row, and rows sit in a `VStack` with no spacing, so consecutive bands meet
/// edge to edge without overlapping into each other.
///
/// The ends are where the run becomes visible as a run. A member that does not draw
/// upward is the top of its run, so the band stops ``Tokens/Stack/inset`` above the chip
/// and rounds; the same downward for the base. A middle member squares both ends and
/// fills its row.
struct StackSleeveView: View {
    var draw: SpineDraw

    var body: some View {
        GeometryReader { proxy in
            // The chip is centred in the stretched column, and the caps are measured from
            // the chip rather than from the row: the sleeve wraps the icons, so its ends
            // have to sit the same distance from the chip as its sides do.
            let chipTop = (proxy.size.height - Tokens.Row.chip) / 2
            let top = draw.drawsUp
                ? -Tokens.Row.paddingTop
                : chipTop - Tokens.Stack.inset
            let bottom = draw.drawsDown
                ? proxy.size.height + Tokens.Row.paddingBottom
                : chipTop + Tokens.Row.chip + Tokens.Stack.inset

            UnevenRoundedRectangle(
                topLeadingRadius: draw.drawsUp ? 0 : Tokens.Stack.capRadius,
                bottomLeadingRadius: draw.drawsDown ? 0 : Tokens.Stack.capRadius,
                bottomTrailingRadius: draw.drawsDown ? 0 : Tokens.Stack.capRadius,
                topTrailingRadius: draw.drawsUp ? 0 : Tokens.Stack.capRadius,
                style: .continuous
            )
            .fill(Tokens.stackSleeve.color)
            .frame(
                width: proxy.size.width + Tokens.Stack.inset * 2,
                height: max(0, bottom - top)
            )
            // A `GeometryReader` places its child at the top leading corner, so the
            // sleeve is pulled back by its own inset to sit centred on the chip column.
            .offset(x: -Tokens.Stack.inset, y: top)
        }
        .opacity(draw.isVisible ? 1 : 0)
        // The grouping is decoration for a relationship the status phrase already states
        // ("waiting on #4127"), so reading it aloud would be repetition.
        .accessibilityHidden(true)
    }
}

/// The three 9×3 pt release segments: CI, merged to trunk, contained in a release tag.
struct ReleaseTrackView: View {
    var segments: [SegmentState]

    var body: some View {
        HStack(spacing: Tokens.Row.segmentGap) {
            ForEach(Array(segments.enumerated()), id: \.offset) { item in
                RoundedRectangle(cornerRadius: Tokens.Row.segmentRadius, style: .continuous)
                    .fill(item.element.tone.map(Tokens.foreground) ?? Tokens.emptySegment.color)
                    .frame(width: Tokens.Row.segmentWidth, height: Tokens.Row.segmentHeight)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        let names = ["checks", "merged", "released"]
        let reached = zip(names, segments)
            .filter { $0.1 != .empty }
            .map { "\($0.0) \($0.1.rawValue)" }
        return reached.isEmpty ? "not started" : reached.joined(separator: ", ")
    }
}

/// Reviewer avatars, overlapping by 2 pt, each ringed in that reviewer's own state.
///
/// Initials over a login-derived colour rather than the fetched image. At M3 there is no
/// image cache, and this is the fallback that has to exist anyway — an avatar URL that
/// 404s or a reviewer with no picture set.
struct ReviewerAvatarsView: View {
    var reviewers: [ReviewerBadge]
    var overflow: Int
    /// The row background, for the 1 pt gap between the avatar and its state ring.
    var haloColor: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(reviewers.enumerated()), id: \.offset) { item in
                avatar(item.element)
                    .padding(.leading, item.offset == 0 ? 0 : Tokens.Row.avatarOverlap)
                    .zIndex(Double(reviewers.count - item.offset))
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(Tokens.text(9, .semibold))
                    .foregroundStyle(Tokens.textTertiary.color)
                    .padding(.leading, 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func avatar(_ reviewer: ReviewerBadge) -> some View {
        Text(reviewer.initials)
            .font(Tokens.text(8.5, .semibold))
            .foregroundStyle(Color.white)
            .frame(width: Tokens.Row.avatar, height: Tokens.Row.avatar)
            .background(Circle().fill(AvatarPalette.color(for: reviewer.login)))
            .overlay(Circle().strokeBorder(haloColor, lineWidth: 1))
            .background(
                Circle()
                    .fill(Tokens.avatarRing(reviewer.tone))
                    .padding(-Tokens.Row.avatarRing + 1)
            )
            .help(reviewer.login)
    }

    private var label: String {
        guard !reviewers.isEmpty else { return "no reviewers" }
        let described = reviewers.map { "\($0.login) \($0.tone.rawValue)" }.joined(separator: ", ")
        return overflow > 0 ? described + ", and \(overflow) more" : described
    }
}

/// A stable colour per login.
///
/// FNV-1a rather than `hashValue`: Swift seeds its hashing per process, so a login's
/// avatar would change colour on every launch. That is not a correctness bug, which is
/// exactly why it would survive review — it just makes the panel feel unreliable.
enum AvatarPalette {
    /// GitHub-ish hues, all dark enough for white initials at 8.5 pt.
    private static let colors: [Color] = [
        Color(nsColor: NSColor(srgbRed: 0.29, green: 0.44, blue: 0.65, alpha: 1)),
        Color(nsColor: NSColor(srgbRed: 0.51, green: 0.31, blue: 0.87, alpha: 1)),
        Color(nsColor: NSColor(srgbRed: 0.04, green: 0.41, blue: 0.85, alpha: 1)),
        Color(nsColor: NSColor(srgbRed: 0.75, green: 0.22, blue: 0.54, alpha: 1)),
        Color(nsColor: NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1)),
        Color(nsColor: NSColor(srgbRed: 0.71, green: 0.33, blue: 0.04, alpha: 1))
    ]

    static func color(for login: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in login.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return colors[Int(hash % UInt32(colors.count))]
    }
}
