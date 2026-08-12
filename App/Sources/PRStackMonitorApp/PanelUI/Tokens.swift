import SwiftUI
import PRStackCore

/// Every colour and every measurement the panel draws with, in one place.
///
/// Light values are literal from `design/Tray App.dc.html`, iteration 2a. Dark values are
/// derived: the same hue and the same *relationship* between chip, dot and tint, re-anchored
/// on a dark field. They are not inversions — inverting `#FBE9E8` gives a saturated red
/// panel background, where the design's intent is a tint you notice without reading.
///
/// Nothing here decides *which* token a row gets. That is ``StatusTone`` and it lives in
/// PRStackCore, where it can be tested off-device (IMPLEMENTATION_PLAN §5).
enum Tokens {
    // MARK: - Palette

    /// One colour in both appearances. Resolved through `NSColor` rather than SwiftUI's
    /// `Color(light:dark:)` (which does not exist on macOS 14) so a single value follows
    /// the effective appearance of whatever view it is used in.
    struct Adaptive {
        /// Resolved once, at token definition, rather than on every body evaluation: the
        /// dynamic `NSColor` does the appearance lookup itself, so building a fresh one
        /// per row per redraw buys nothing.
        let color: Color

        private let light: NSColor
        private let dark: NSColor

        init(light: NSColor, dark: NSColor) {
            self.light = light
            self.dark = dark
            color = Color(nsColor: NSColor(name: nil) { $0.isDark ? dark : light })
        }

        /// The same colour, mixed toward white in each appearance.
        ///
        /// Derived rather than written out as its own hex pair so a lighter token can never
        /// drift off the hue it is meant to be a lighter version of.
        ///
        /// Lighter is not the same as quieter, and only one of those is symmetric across
        /// the appearances: white is *away* from a dark field. To soften a colour rather
        /// than lift it, use ``faded(into:light:dark:)``.
        func lightened(light lightAmount: Double, dark darkAmount: Double) -> Adaptive {
            let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            Adaptive(
                light: blend(light, white, lightAmount),
                dark: blend(dark, white, darkAmount)
            )
        }

        /// The same colour, mixed toward `surface` in each appearance.
        ///
        /// This is the one that means "less visible": each appearance moves toward its own
        /// background, so the token loses contrast in both rather than gaining it in one.
        /// Passing ``Tokens/field`` is the usual case — the surface a row sits on.
        func faded(into surface: Adaptive, light lightAmount: Double, dark darkAmount: Double) -> Adaptive {
            Adaptive(
                light: blend(light, surface.light, lightAmount),
                dark: blend(dark, surface.dark, darkAmount)
            )
        }
    }

    // Surfaces
    static let field = Adaptive(light: hex(0xF5F5F6), dark: hex(0x1C1C1E))
    static let chrome = Adaptive(light: hex(0xF0F0F1), dark: hex(0x232326))
    static let separator = Adaptive(light: black(0.06), dark: white(0.09))
    /// The hovered row's lift. Deliberately a *raise*, not a tint: an attention row must
    /// still read as an attention row while the pointer is on it (§5).
    static let rowHover = Adaptive(light: black(0.04), dark: white(0.06))

    // Text
    static let textPrimary = Adaptive(light: hex(0x1D1D1F), dark: hex(0xF2F2F4))
    static let textSecondary = Adaptive(light: hex(0x57606A), dark: hex(0xA8AEB8))
    static let textTertiary = Adaptive(light: hex(0x8A8F98), dark: hex(0x82868F))
    static let sectionHeading = Adaptive(light: hex(0x3C4149), dark: hex(0xC9CDD4))
    static let sectionCount = Adaptive(light: hex(0xA2A6AE), dark: hex(0x71757D))

    // Status
    static let danger = Adaptive(light: hex(0xCF222E), dark: hex(0xFF6B6B))
    static let dangerChip = Adaptive(light: hex(0xFFD5D1), dark: hex(0x5B2220))
    static let dangerTint = Adaptive(light: hex(0xFBE9E8), dark: hex(0x33201F))

    static let success = Adaptive(light: hex(0x1A7F37), dark: hex(0x4CC46A))
    static let successChip = Adaptive(light: hex(0xBCECC9), dark: hex(0x184024))

    static let mergedPurple = Adaptive(light: hex(0x8250DF), dark: hex(0xB18BF5))
    static let mergedChip = Adaptive(light: hex(0xE6D4FA), dark: hex(0x352247))

    static let amber = Adaptive(light: hex(0x9A6700), dark: hex(0xE3A72F))
    static let amberChip = Adaptive(light: hex(0xFFF8C5), dark: hex(0x3D3113))
    static let amberText = Adaptive(light: hex(0x7A5200), dark: hex(0xF0C463))

    /// Indigo. Unread dot, Linear links, `Clear all`.
    static let accent = Adaptive(light: hex(0x5E6AD2), dark: hex(0x8B95E8))
    static let accentChip = Adaptive(light: hex(0xECECF8), dark: hex(0x262A45))

    /// The ring a reviewer avatar wears, one step lighter than the status colour itself.
    ///
    /// Lighter than ``foreground`` on purpose: the ring is a solid 2 pt band around an
    /// 18 pt circle, so at full status strength it reads as a second chip competing with
    /// the real one. Lifted toward the field it stays legible as state without shouting.
    static let dangerRing = danger.lightened(light: 0.36, dark: 0.24)
    static let successRing = success.lightened(light: 0.36, dark: 0.24)
    static let mergedRing = mergedPurple.lightened(light: 0.36, dark: 0.24)
    static let amberRing = amber.lightened(light: 0.36, dark: 0.24)
    static let accentRing = accent.lightened(light: 0.36, dark: 0.24)

    /// Faded toward the field rather than lifted toward white, and much further than the
    /// coloured rings move at all.
    ///
    /// Neutral is the ring on a reviewer who has said nothing — commented, or asked and
    /// still thinking. It is the only ring carrying no verdict, so it is the only one that
    /// should recede instead of register, and receding is a different operation from
    /// lightening: white softens a ring on the light field and *sharpens* the same ring on
    /// the dark one. Moving each appearance toward its own background is what costs
    /// contrast in both.
    static let neutralRing = textTertiary.faded(into: field, light: 0.62, dark: 0.62)

    static let neutralChip = Adaptive(light: hex(0xE0E1E5), dark: hex(0x35353A))
    static let spineLine = Adaptive(light: hex(0xDDDEE3), dark: hex(0x3C3C42))
    static let emptySegment = Adaptive(light: hex(0xE4E4E7), dark: hex(0x38383D))

    // MARK: - Tone resolution

    /// The status colour: the dot inside the chip, and the phrase on the meta line.
    static func foreground(_ tone: StatusTone) -> Color {
        switch tone {
        case .neutral: return textTertiary.color
        case .danger: return danger.color
        case .success: return success.color
        case .merged: return mergedPurple.color
        case .inFlight: return amber.color
        case .accent: return accent.color
        }
    }

    /// The ring around a reviewer avatar.
    static func avatarRing(_ tone: StatusTone) -> Color {
        switch tone {
        case .neutral: return neutralRing.color
        case .danger: return dangerRing.color
        case .success: return successRing.color
        case .merged: return mergedRing.color
        case .inFlight: return amberRing.color
        case .accent: return accentRing.color
        }
    }

    /// The chip behind the dot.
    static func chip(_ tone: StatusTone) -> Color {
        switch tone {
        case .neutral: return neutralChip.color
        case .danger: return dangerChip.color
        case .success: return successChip.color
        case .merged: return mergedChip.color
        case .inFlight: return amberChip.color
        case .accent: return accentChip.color
        }
    }

    /// The row background behind an attention row.
    ///
    /// Only `danger` has one, and only `danger` needs one: attention is exactly the three
    /// red statuses (§2), so any other tone reaching here would be a row tinted for a
    /// reason the panel does not have.
    static func rowTint(_ tone: StatusTone) -> Color {
        tone == .danger ? dangerTint.color : Color.clear
    }

    // MARK: - Geometry

    /// 440 pt content width, height to content up to 800 pt, then scrolls (§5).
    enum Panel {
        static let width: CGFloat = 440
        static let maxHeight: CGFloat = 800
        /// Enough for the header, the footer and a message between them.
        static let minBodyHeight: CGFloat = 96
        static let cornerRadius: CGFloat = 10
    }

    enum Row {
        /// `padding: 6 10 6 8`, `margin: 0 6`, `radius: 7`, `gap: 9`.
        static let paddingTop: CGFloat = 6
        static let paddingTrailing: CGFloat = 10
        static let paddingBottom: CGFloat = 6
        static let paddingLeading: CGFloat = 8
        static let horizontalMargin: CGFloat = 6
        static let cornerRadius: CGFloat = 7
        static let gap: CGFloat = 9
        /// Always reserved, so a row never shifts when it is marked read.
        static let unreadGutter: CGFloat = 5
        static let unreadDot: CGFloat = 5
        static let chip: CGFloat = 16
        static let chipRadius: CGFloat = 5
        static let chipDot: CGFloat = 6
        static let chipHalo: CGFloat = 3
        static let titleSize: CGFloat = 12.5
        static let metaSize: CGFloat = 11
        static let metaGap: CGFloat = 7
        /// What separates the `+N` affix from the identifier it counts — a third of a
        /// `metaGap`. At the full gap the two read as two tokens, and the affix is not one:
        /// it is a suffix on the identifier, the way `+2` is on `BIL-312`.
        static let metaAffixGap: CGFloat = 2.5
        static let stackGap: CGFloat = 2
        static let avatar: CGFloat = 18
        static let avatarOverlap: CGFloat = -2
        static let avatarRing: CGFloat = 3
        static let segmentWidth: CGFloat = 9
        static let segmentHeight: CGFloat = 3
        static let segmentGap: CGFloat = 2
        static let segmentRadius: CGFloat = 2
    }

    enum Spine {
        static let width: CGFloat = 1.5
        /// The hairline runs 8 pt past the chip in each direction it draws, which is what
        /// carries it across the gap between two rows.
        static let overhang: CGFloat = 8
    }

    enum Section {
        static let headingSize: CGFloat = 11.5
        static let headingWeight: Font.Weight = .semibold
        static let countSize: CGFloat = 11
        static let topPadding: CGFloat = 16
        /// The first heading sits closer to the header than the rest do to each other.
        static let firstTopPadding: CGFloat = 14
        static let bottomPadding: CGFloat = 6
        static let horizontalPadding: CGFloat = 12
    }

    // MARK: - Typography

    /// No monospaced type anywhere, and tabular figures everywhere a numeral runs
    /// (PRD §11). `.monospacedDigit` on the system font gives even columns without a
    /// monospaced face.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// 2a runs 500 → 560 across the three tiers. AppKit exposes named weights, so these
    /// are the nearest three that stay visually distinct at 12.5 pt.
    static func titleWeight(_ emphasis: TitleEmphasis) -> Font.Weight {
        switch emphasis {
        case .dim: return .regular
        case .normal: return .medium
        case .strong: return .semibold
        }
    }

    static func titleColor(_ emphasis: TitleEmphasis) -> Color {
        emphasis == .dim ? textSecondary.color : textPrimary.color
    }

    // MARK: - Hex

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func black(_ alpha: Double) -> NSColor {
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha)
    }

    private static func white(_ alpha: Double) -> NSColor {
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
    }
}

/// Moves `color` `amount` of the way to `target`, in sRGB.
///
/// Component-wise rather than an HSB interpolation: the status colours are already at or
/// near full brightness in dark appearance, so only losing saturation changes them, and a
/// hue-space walk between two greys of different lightness has no hue to walk along.
private func blend(_ color: NSColor, _ target: NSColor, _ amount: Double) -> NSColor {
    let base = color.usingColorSpace(.sRGB) ?? color
    let onto = target.usingColorSpace(.sRGB) ?? target
    func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * CGFloat(amount) }
    return NSColor(
        srgbRed: mix(base.redComponent, onto.redComponent),
        green: mix(base.greenComponent, onto.greenComponent),
        blue: mix(base.blueComponent, onto.blueComponent),
        alpha: base.alphaComponent
    )
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
