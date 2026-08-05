import SwiftUI
import PRStackCore

// The four small pieces a row is built from. Split out because each one has a geometry
// that has to survive the others changing: the chip's halo is what lets the spine pass
// behind it, and the reviewer ring is what makes a state readable without colour.

/// The 16 pt status chip, with its 6 pt mark.
///
/// The `haloColor` is the row's own background. Painting a 3 pt ring of it around the
/// chip is what lets the spine run *behind* the chip and still read as a continuous line
/// — the alternative is clipping the spine per row, which needs every row to know its
/// neighbours' geometry (§5).
struct StatusChipView: View {
    var tone: StatusTone
    var glyph: ChipGlyph
    var haloColor: Color

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Row.chipRadius, style: .continuous)
            .fill(Tokens.chip(tone))
            .frame(width: Tokens.Row.chip, height: Tokens.Row.chip)
            .overlay(mark)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Row.chipRadius + Tokens.Row.chipHalo, style: .continuous)
                    .fill(haloColor)
                    .padding(-Tokens.Row.chipHalo)
            )
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

/// The 1.5 pt hairline through the chip's centre line.
///
/// Drawn as a background behind the chip column and extended past the row's bounds by
/// ``Tokens/Spine/overhang`` in each direction it draws, so it crosses the gap between
/// two rows. The top member draws downward only and the base upward only, which is what
/// makes a run's ends visible as ends.
struct StackSpineView: View {
    var draw: SpineDraw

    var body: some View {
        GeometryReader { proxy in
            let mid = proxy.size.height / 2
            let top = draw.drawsUp ? -Tokens.Spine.overhang : mid
            let bottom = draw.drawsDown ? proxy.size.height + Tokens.Spine.overhang : mid

            Tokens.spineLine.color
                .frame(width: Tokens.Spine.width, height: max(0, bottom - top))
                .offset(x: (proxy.size.width - Tokens.Spine.width) / 2, y: top)
        }
        .opacity(draw.isVisible ? 1 : 0)
        // The line is decoration for a relationship the status phrase already states
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
                    .fill(Tokens.foreground(reviewer.tone))
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
