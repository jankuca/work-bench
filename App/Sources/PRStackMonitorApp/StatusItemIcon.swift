import AppKit
import PRStackCore

/// Draws an ``IconState`` into the image the menu bar shows.
///
/// Hand-drawn rather than an SF Symbol, and non-template rather than template, both for
/// the same reason: the states differ by a badge that has to carry a colour and a count,
/// and one of them is a *dashed* outline of the glyph. Neither survives symbol rendering
/// or template tinting (IMPLEMENTATION_PLAN §1).
///
/// Geometry is design `1f`, point for point: a 15 pt rounded square at 1.6 pt with a 4 pt
/// dot inside; the unread dot 7 pt at `top:-2 right:-3`; the action badge 13 pt tall at
/// `top:-3 right:-6`, growing leftwards with the count. The canvas is 22 × 18 because
/// that is what the badge's overhang needs.
///
/// This file decides nothing. Which state to draw is ``IconState/resolve(github:attentionCount:unreadCount:)``,
/// which lives in core and is table-tested off-device.
enum StatusItemIcon {
    // MARK: - Geometry

    /// Sized from what actually gets drawn, not rounded to a convenient number.
    ///
    /// The glyph is bottom-left. The badge overhangs it by 6 pt to the right and 3 pt
    /// above, and ``punchHalo`` expands the badge by a further 1.5 pt in every direction —
    /// so the widest thing drawn reaches `15 + 6 + 1.5` and the tallest spans
    /// `3 + 1.5` above the glyph's top. A canvas sized to the glyph plus the badge alone
    /// would clip the halo along the top and right edges, which is exactly where the badge
    /// needs its separation from the menu bar's background.
    private static let canvas = NSSize(width: 22.5, height: 19.5)
    private static let glyphSide: CGFloat = 15
    private static let glyphStroke: CGFloat = 1.6
    private static let glyphRadius: CGFloat = 4
    private static let glyphDot: CGFloat = 4
    /// Bottom-left, so the overhang above it is the canvas's extra height.
    private static let glyphOrigin = NSPoint(x: 0, y: 0)

    private static let dotSide: CGFloat = 7
    private static let badgeHeight: CGFloat = 13
    private static let badgeMinWidth: CGFloat = 13
    private static let badgeTextInset: CGFloat = 3
    private static let badgeFontSize: CGFloat = 8.5
    /// The 1.5 pt ring the design draws in the tray's own background colour. Here it is
    /// punched *out* of the glyph instead of filled, so whatever the menu bar's background
    /// happens to be shows through — the one colour we cannot know at drawing time.
    private static let halo: CGFloat = 1.5

    private static let disconnectedOpacity: CGFloat = 0.45
    private static let dash: [CGFloat] = [2.4, 2.0]

    // MARK: - Colours

    /// `#5E6AD2`, `#CF222E` and `#9A6700` — the same three the panel uses. They are
    /// literal here rather than shared with `Tokens`, which is deliberate: those are panel
    /// tokens, resolved against the panel's own light and dark fields, and the menu bar is
    /// neither. A badge has to hold its meaning on any menu bar, including a wallpaper
    /// showing through one.
    private static let accent = NSColor(srgbRed: 0x5E / 255, green: 0x6A / 255, blue: 0xD2 / 255, alpha: 1)
    private static let danger = NSColor(srgbRed: 0xCF / 255, green: 0x22 / 255, blue: 0x2E / 255, alpha: 1)
    private static let amber = NSColor(srgbRed: 0x9A / 255, green: 0x67 / 255, blue: 0x00 / 255, alpha: 1)

    // MARK: - Rendering

    /// The image for one state, sized ``canvas`` and ready to hand to a status item button.
    static func image(for state: IconState) -> NSImage {
        // A block-backed image, so the glyph's `labelColor` resolves against whatever
        // appearance the menu bar is drawing in rather than the one that happened to be
        // current when the state changed. Redrawing on appearance changes is AppKit's job
        // here, not ours.
        let image = NSImage(size: canvas, flipped: true) { _ in
            draw(state)
            return true
        }
        // Not a template: the badge and the dot are the state, and a template image would
        // flatten both to the menu bar's foreground colour.
        image.isTemplate = false
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    /// Everything below draws in a *flipped* space — origin top-left, y downwards — so the
    /// numbers read the same way the design's CSS does.
    private static func draw(_ state: IconState) {
        switch state {
        case .disconnected:
            // No inner dot: the design's disconnected glyph is an empty dashed outline,
            // and dropping the dot is what makes the state legible without colour.
            drawGlyph(dashed: true, filled: false, alpha: disconnectedOpacity)

        case .idle:
            drawGlyph(dashed: false, filled: true, alpha: 1)

        case .unread:
            drawGlyph(dashed: false, filled: true, alpha: 1)
            drawDot(fill: accent)

        case .inFlight:
            // Reserved. Nothing resolves to it under tags-only release tracking; the case
            // is kept so a DeploymentAPITracker has somewhere to land.
            drawGlyph(dashed: false, filled: true, alpha: 1)
            drawDot(fill: amber)

        case .actionNeeded(let count):
            drawGlyph(dashed: false, filled: true, alpha: 1)
            drawBadge(count: count)
        }
    }

    /// The glyph's box, bottom-left of the canvas. Everything else is positioned from it.
    private static func glyphRect() -> NSRect {
        NSRect(
            x: glyphOrigin.x,
            y: canvas.height - glyphSide - glyphOrigin.y,
            width: glyphSide,
            height: glyphSide
        )
    }

    private static func drawGlyph(dashed: Bool, filled: Bool, alpha: CGFloat) {
        let frame = glyphRect().insetBy(dx: glyphStroke / 2, dy: glyphStroke / 2)
        let path = NSBezierPath(roundedRect: frame, xRadius: glyphRadius, yRadius: glyphRadius)
        path.lineWidth = glyphStroke
        if dashed {
            path.setLineDash(dash, count: dash.count, phase: 0)
        }

        // `labelColor` rather than a literal: the menu bar inverts with the appearance,
        // and this is the one part of the icon that is not a status colour.
        NSColor.labelColor.withAlphaComponent(alpha).setStroke()
        path.stroke()

        guard filled else { return }
        let centre = glyphRect()
        let dot = NSRect(
            x: centre.midX - glyphDot / 2,
            y: centre.midY - glyphDot / 2,
            width: glyphDot,
            height: glyphDot
        )
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    /// The 7 pt unread / in-flight dot, top-right of the glyph.
    private static func drawDot(fill: NSColor) {
        let glyph = glyphRect()
        let rect = NSRect(
            x: glyph.maxX + 3 - dotSide,
            y: glyph.minY - 2,
            width: dotSide,
            height: dotSide
        )
        punchHalo(around: NSBezierPath(ovalIn: rect.insetBy(dx: -halo, dy: -halo)))
        fill.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    /// The red badge: a capsule that grows leftwards from a fixed right edge, with the
    /// count centred in it.
    private static func drawBadge(count: Int) {
        let label = badgeLabel(for: count)
        // Tabular figures, per PRD §11 — `1` and `4` have to occupy the same width or the
        // badge changes size as the count does. Not a monospaced *face*: there is none
        // anywhere in this app.
        let font = NSFont.monospacedDigitSystemFont(ofSize: badgeFontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let textSize = text.size()

        let glyph = glyphRect()
        let width = max(badgeMinWidth, textSize.width + badgeTextInset * 2)
        let rect = NSRect(
            x: glyph.maxX + 6 - width,
            y: glyph.minY - 3,
            width: width,
            height: badgeHeight
        )
        let capsule = NSBezierPath(
            roundedRect: rect,
            xRadius: badgeHeight / 2,
            yRadius: badgeHeight / 2
        )

        punchHalo(
            around: NSBezierPath(
                roundedRect: rect.insetBy(dx: -halo, dy: -halo),
                xRadius: badgeHeight / 2 + halo,
                yRadius: badgeHeight / 2 + halo
            )
        )
        danger.setFill()
        capsule.fill()

        text.draw(
            at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            )
        )
    }

    /// Erases the glyph under `path`, leaving the menu bar's own background in the ring
    /// around the badge. `destinationOut` rather than a filled ring because the colour
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
    /// long before then — the panel is one click away and it has the list.
    private static func badgeLabel(for count: Int) -> String {
        count > 99 ? "99+" : "\(max(0, count))"
    }
}
