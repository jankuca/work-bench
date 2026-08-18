import AppKit
import PRStackCore

/// Draws an ``IconState`` into the image the menu bar shows.
///
/// Hand-drawn rather than an SF Symbol, and non-template rather than template, both for
/// the same reason: the states differ by badges that have to carry a colour and a count,
/// and one of them is a *dashed* outline of the glyph. Neither survives symbol rendering
/// or template tinting (IMPLEMENTATION_PLAN §1).
///
/// Geometry follows design `1f`: a 15 pt rounded square at 1.6 pt with a 4 pt dot inside,
/// a 7 pt unread dot on its top-right corner and 13 pt count capsules. What does *not*
/// follow `1f` is where the counts sit — see ``badgeGap``. `1f` draws one badge on the
/// corner; there are two of them now, and they sit in a row *over* the glyph — same size,
/// same height as the plain icon — with the glyph centred behind them.
///
/// This file decides nothing. Which state to draw is ``IconState/resolve(github:readyCount:attentionCount:unreadCount:)``,
/// which lives in core and is table-tested off-device.
enum StatusItemIcon {
    // MARK: - Geometry

    private static let glyphSide: CGFloat = 15
    private static let glyphStroke: CGFloat = 1.6
    private static let glyphRadius: CGFloat = 4
    private static let glyphDot: CGFloat = 4

    private static let dotSide: CGFloat = 7
    private static let badgeHeight: CGFloat = 13
    private static let badgeMinWidth: CGFloat = 13
    private static let badgeTextInset: CGFloat = 3
    private static let badgeFontSize: CGFloat = 8.5
    /// The 1.5 pt ring the design draws in the tray's own background colour. Here it is
    /// punched *out* of the glyph instead of filled, so whatever the menu bar's background
    /// happens to be shows through — the one colour we cannot know at drawing time.
    private static let halo: CGFloat = 1.5

    /// How far the unread dot reaches past the glyph's right edge.
    ///
    /// Design `1f` puts the dot at `top:-2 right:-3` and the badge at `top:-3 right:-6`, and
    /// taking those literally is what made the icon sit low and left in the menu bar. A
    /// status item centres the *image*, so the glyph is only centred if the canvas is
    /// symmetric about it — and reserving 6 pt of overhang on the right and 3 pt above with
    /// nothing to match them on the left and below puts the glyph's centre 3.75 pt left of
    /// and 2.25 pt below the item's. Padding the two short sides instead would restore the
    /// design's offsets, at 30 × 24 pt: wider than any neighbour in the menu bar, and as tall
    /// as the bar itself with no clearance above or below.
    ///
    /// So the dot is tucked in: it reaches 3 pt past the right edge rather than sitting
    /// half-off, which makes the badgeless canvas 24 × 18 — the standard menu bar icon
    /// height, with the glyph exactly in the middle of it. What the design is saying is "a
    /// dot on the top-right corner", and that survives the change; being 3.75 pt off-centre
    /// forever does not.
    private static let overhang: CGFloat = 3

    /// The horizontal gap between the two count capsules.
    ///
    /// The counts sit in a row laid *over* the glyph — same size as the single `1f` badge,
    /// same height as the plain icon — rather than beside or above it. `1f`'s one badge
    /// overlaps the glyph's top-right corner; two of them overlap it centred, red first and
    /// green second, with this gap between them showing the menu bar's own background the
    /// way the halo does. The glyph is centred behind the pair, so the image never grows
    /// taller than the plain icon — only wider, by the width of the row.
    ///
    /// The unread dot keeps the corner instead of the centre. It is the one mark with no
    /// number in it, nothing to pair with, and moving it would cost the state its distinct
    /// *position* — half of what makes the icon legible without colour (IMPLEMENTATION_PLAN §5).
    private static let badgeGap: CGFloat = 2

    /// The glyph's inset from the badgeless canvas's top-left. A status item centres the
    /// *image*, so a symmetric canvas is what puts the glyph dead centre in the menu bar.
    ///
    /// Horizontally that is the dot's overhang plus its halo; vertically nothing reaches
    /// above the glyph's top but that same halo. The counts state centres the glyph in its
    /// own, wider canvas — see ``countsLayout(_:)`` — at the same height as this one.
    private static let padding = NSSize(width: overhang + halo, height: halo)
    private static let canvasHeight = glyphSide + padding.height * 2

    private static let disconnectedOpacity: CGFloat = 0.45
    private static let dash: [CGFloat] = [2.4, 2.0]

    // MARK: - Colours

    /// `#5E6AD2`, `#CF222E`, `#1A7F37` and `#9A6700` — the same four the panel uses. They
    /// are literal here rather than shared with `Tokens`, which is deliberate: those are
    /// panel tokens, resolved against the panel's own light and dark fields, and the menu
    /// bar is neither. A badge has to hold its meaning on any menu bar, including a
    /// wallpaper showing through one.
    ///
    /// The green is the panel's *light* success value rather than its dark one, as the red
    /// already is: both capsules carry white text, and the lightened dark-mode pair is a
    /// field for dark backgrounds, not a fill under white.
    private static let accent = NSColor(srgbRed: 0x5E / 255, green: 0x6A / 255, blue: 0xD2 / 255, alpha: 1)
    private static let danger = NSColor(srgbRed: 0xCF / 255, green: 0x22 / 255, blue: 0x2E / 255, alpha: 1)
    private static let success = NSColor(srgbRed: 0x1A / 255, green: 0x7F / 255, blue: 0x37 / 255, alpha: 1)
    private static let amber = NSColor(srgbRed: 0x9A / 255, green: 0x67 / 255, blue: 0x00 / 255, alpha: 1)

    // MARK: - Rendering

    /// The image for one state, sized to what that state draws and ready to hand to a
    /// status item button.
    ///
    /// The width varies with the counts — the badge row widens the image, but sitting over
    /// the glyph rather than above it leaves the height alone. It changes only when a count
    /// does, never on a poll that found nothing new.
    static func image(for state: IconState) -> NSImage {
        // A block-backed image, so the glyph's `labelColor` resolves against whatever
        // appearance the menu bar is drawing in rather than the one that happened to be
        // current when the state changed. Redrawing on appearance changes is AppKit's job
        // here, not ours.
        let image = NSImage(size: canvas(for: state), flipped: true) { _ in
            draw(state)
            return true
        }
        // Not a template: the badges and the dot are the state, and a template image would
        // flatten all of them to the menu bar's foreground colour.
        image.isTemplate = false
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    /// The glyph, plus room for whatever the state draws around it.
    ///
    /// With no capsules this is the symmetric 24 × 18 the dot states have always used, so
    /// the glyph sits dead centre in the menu bar item. With capsules the canvas is the same
    /// height and only wider: the badge row is laid over the glyph, so it widens the image
    /// to the wider of glyph and row but never makes it taller.
    private static func canvas(for state: IconState) -> NSSize {
        let badges = capsules(for: state)
        guard !badges.isEmpty else {
            return NSSize(width: glyphSide + padding.width * 2, height: canvasHeight)
        }
        return countsLayout(badges).canvas
    }

    /// Everything below draws in a *flipped* space — origin top-left, y downwards — so the
    /// numbers read the same way the design's CSS does.
    private static func draw(_ state: IconState) {
        switch state {
        case .disconnected:
            // No inner dot: the design's disconnected glyph is an empty dashed outline,
            // and dropping the dot is what makes the state legible without colour.
            drawGlyph(in: glyphRect(), dashed: true, filled: false, alpha: disconnectedOpacity)

        case .idle:
            drawGlyph(in: glyphRect(), dashed: false, filled: true, alpha: 1)

        case .unread:
            drawGlyph(in: glyphRect(), dashed: false, filled: true, alpha: 1)
            drawDot(fill: accent, on: glyphRect())

        case .inFlight:
            // Reserved. Nothing resolves to it under tags-only release tracking; the case
            // is kept so a DeploymentAPITracker has somewhere to land.
            drawGlyph(in: glyphRect(), dashed: false, filled: true, alpha: 1)
            drawDot(fill: amber, on: glyphRect())

        case .counts:
            let layout = countsLayout(capsules(for: state))
            drawGlyph(in: layout.glyph, dashed: false, filled: true, alpha: 1)
            drawCapsules(layout.badges)
        }
    }

    /// The counts state's geometry: the glyph centred, a row of capsules laid over its top.
    ///
    /// The badges are wider than the glyph the moment there are two of them, so it is the
    /// *glyph* that is centred under the row rather than the other way round — which is what
    /// "the icon centred beneath the badges" means once the row is the wider of the two. The
    /// whole thing is symmetric about that shared centre line, so the status item centring
    /// the image leaves the glyph centred in the menu bar with the badges over it.
    ///
    /// The row is set flush with the glyph's top rather than above it, so the image is the
    /// same height as the dot states — it grows only in width, which is what keeps it inside
    /// the menu bar. The badges are drawn opaque over the glyph, each with a punched halo, so
    /// the pair reads as sitting on the icon rather than merged into its strokes.
    private static func countsLayout(
        _ capsules: [Capsule]
    ) -> (canvas: NSSize, glyph: NSRect, badges: [(capsule: Capsule, rect: NSRect)]) {
        let widths = capsules.map(width(of:))
        let rowWidth = widths.reduce(0, +) + badgeGap * CGFloat(max(0, capsules.count - 1))
        let contentWidth = max(rowWidth, glyphSide)

        let canvasSize = NSSize(width: contentWidth + halo * 2, height: canvasHeight)

        let glyph = NSRect(
            x: (canvasSize.width - glyphSide) / 2,
            y: padding.height,
            width: glyphSide,
            height: glyphSide
        )

        var badges: [(capsule: Capsule, rect: NSRect)] = []
        var x = (canvasSize.width - rowWidth) / 2
        for (capsule, capsuleWidth) in zip(capsules, widths) {
            badges.append(
                (capsule, NSRect(x: x, y: glyph.minY, width: capsuleWidth, height: badgeHeight))
            )
            x += capsuleWidth + badgeGap
        }

        return (canvasSize, glyph, badges)
    }

    /// The count capsules a state draws, in drawing order: red first, then green.
    ///
    /// Red leads because it is the one that is asking — the count the icon exists to raise —
    /// so it takes the leading edge, where the single attention badge has always been; the
    /// green ready count follows it. A zero is not a capsule: `0 ready` is a statement the
    /// menu bar has no room to make and no reason to.
    private static func capsules(for state: IconState) -> [Capsule] {
        guard case .counts(let ready, let attention) = state else { return [] }
        var capsules: [Capsule] = []
        if attention > 0 { capsules.append(Capsule(count: attention, fill: danger)) }
        if ready > 0 { capsules.append(Capsule(count: ready, fill: success)) }
        return capsules
    }

    /// One count capsule: a colour and a number, with the geometry left to the drawing.
    private struct Capsule {
        var count: Int
        var fill: NSColor
    }

    /// The badgeless glyph's box: centred in the symmetric dot-state canvas. The counts
    /// state does not use this — it positions its glyph in ``countsLayout(_:)``.
    private static func glyphRect() -> NSRect {
        NSRect(x: padding.width, y: padding.height, width: glyphSide, height: glyphSide)
    }

    private static func drawGlyph(in frame: NSRect, dashed: Bool, filled: Bool, alpha: CGFloat) {
        let box = frame.insetBy(dx: glyphStroke / 2, dy: glyphStroke / 2)
        let path = NSBezierPath(roundedRect: box, xRadius: glyphRadius, yRadius: glyphRadius)
        path.lineWidth = glyphStroke
        if dashed {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }

        // `labelColor` rather than a literal: the menu bar inverts with the appearance,
        // and this is the one part of the icon that is not a status colour.
        NSColor.labelColor.withAlphaComponent(alpha).setStroke()
        path.stroke()

        guard filled else { return }
        let dot = NSRect(
            x: frame.midX - glyphDot / 2,
            y: frame.midY - glyphDot / 2,
            width: glyphDot,
            height: glyphDot
        )
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    /// The 7 pt unread / in-flight dot, on the glyph's top-right corner.
    private static func drawDot(fill: NSColor, on glyph: NSRect) {
        let rect = NSRect(
            x: glyph.maxX + overhang - dotSide,
            y: glyph.minY,
            width: dotSide,
            height: dotSide
        )
        punchHalo(around: NSBezierPath(ovalIn: rect.insetBy(dx: -halo, dy: -halo)))
        fill.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    /// The count capsules, at the positions ``countsLayout(_:)`` placed them — a row over
    /// the glyph's top, the count centred in each.
    ///
    /// Each gets a punched halo, the same 1.5 pt ring the corner dot has: the capsules are
    /// laid over the glyph's strokes, and the ring of menu-bar background around them is what
    /// keeps them reading as badges on the icon rather than smeared into it. The halos are
    /// punched first, under every fill, so a capsule never erases its neighbour.
    private static func drawCapsules(_ badges: [(capsule: Capsule, rect: NSRect)]) {
        for (_, rect) in badges {
            punchHalo(
                around: NSBezierPath(
                    roundedRect: rect.insetBy(dx: -halo, dy: -halo),
                    xRadius: badgeHeight / 2 + halo,
                    yRadius: badgeHeight / 2 + halo
                )
            )
        }

        for (capsule, rect) in badges {
            capsule.fill.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: badgeHeight / 2,
                yRadius: badgeHeight / 2
            ).fill()

            let text = label(for: capsule.count)
            let textSize = text.size()
            text.draw(
                at: NSPoint(
                    x: rect.midX - textSize.width / 2,
                    y: rect.midY - textSize.height / 2
                )
            )
        }
    }

    /// A capsule is as wide as its number needs, never narrower than a circle.
    private static func width(of capsule: Capsule) -> CGFloat {
        max(badgeMinWidth, label(for: capsule.count).size().width + badgeTextInset * 2)
    }

    /// The count, drawn in white.
    ///
    /// Tabular figures, per PRD §11 — `1` and `4` have to occupy the same width or a
    /// capsule changes size as its count does, and with two of them in a row a change in
    /// the first would shift the second. Not a monospaced *face*: there is none anywhere in
    /// this app.
    private static func label(for count: Int) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: badgeFontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        return NSAttributedString(string: badgeLabel(for: count), attributes: attributes)
    }

    /// Erases the glyph under `path`, leaving the menu bar's own background in the ring
    /// around the dot. `destinationOut` rather than a filled ring because the colour
    /// behind a status item is not ours to guess — it is a wallpaper as often as it is a
    /// system grey.
    private static func punchHalo(around path: NSBezierPath) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        NSColor.black.setFill()
        path.fill()
        context.restoreGraphicsState()
    }

    /// Three digits do not fit a menu bar badge, and the exact number stops mattering
    /// long before then — the panel is one click away and it has the list. `99+` just makes
    /// its capsule 3 pt wider rather than being clipped; the row is centred, so the extra
    /// width pushes out symmetrically and the glyph stays under the middle of it.
    private static func badgeLabel(for count: Int) -> String {
        count > 99 ? "99+" : "\(max(0, count))"
    }
}
