import AppKit
import CoreText
import SwiftUI
import os

/// One line of text as the outlines of its glyphs, each where it stands along a straight baseline: what's needed to set
/// the line along an arc instead. Made once for each text and font and kept, since names are placed again on every change
/// of picture and are mostly the same names.
struct GlyphLine: Sendable {
    struct Glyph: @unchecked Sendable {
        /// The glyph's outline around its own origin on the baseline, y up. Nil for a space.
        let outline: CGPath?
        /// Where its middle is along the baseline, from the start of the line.
        let middle: CGFloat
    }

    let glyphs: [Glyph]
    /// How long the line is.
    let width: CGFloat

    /// The line of `text` in a font. Kerning and ligatures are as CoreText sets them.
    static func make(_ text: String, font: NSFont) -> GlyphLine {
        let key = Key(text: text, font: ObjectIdentifier(font))
        if let known = cache.withLock({ $0[key] }) { return known }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var glyphs: [Glyph] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            // The run's own font: a character the line's font lacks comes from another.
            let attributes = CTRunGetAttributes(run) as NSDictionary
            // Core Text keeps a run's font as a CTFont, and a cast to a Core Foundation type can't be conditional.
            // swift-format-ignore: NeverForceUnwrap
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font as CTFont
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            for i in 0..<count {
                let half = advances[i].width / 2
                glyphs.append(Glyph(outline: outline(of: ids[i], in: runFont, half: half), middle: positions[i].x + half))
            }
        }
        let made = GlyphLine(glyphs: glyphs, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        cache.withLock { known in
            if known.count > 2048 { known.removeAll(keepingCapacity: true) }
            known[key] = made
        }
        return made
    }

    private struct Key: Hashable {
        let text: String
        let font: ObjectIdentifier
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Key: GlyphLine]())

    /// A glyph's outline around its own middle, so it turns about that when it's set on the arc. One outline for each glyph
    /// of a font, shared by every line it's in: an outline is never changed, and a few hundred names are the same hundred
    /// letters. With an outline made for each letter of each name, the names around one ring kept 13 MB of them.
    private static func outline(of glyph: CGGlyph, in font: CTFont, half: CGFloat) -> CGPath? {
        let key = OutlineKey(font: font, glyph: glyph, half: half)
        if let known = outlines.withLock({ $0[key] }) { return known.path }
        var toMiddle = CGAffineTransform(translationX: -half, y: 0)
        let made = Outline(path: CTFontCreatePathForGlyph(font, glyph, &toMiddle))
        outlines.withLock { known in
            if known.count > 4096 { known.removeAll(keepingCapacity: true) }
            known[key] = made
        }
        return made.path
    }

    /// A glyph of a font, moved back by half its advance: kerning can give the same glyph another advance.
    private struct OutlineKey: Hashable, @unchecked Sendable {
        let font: CTFont
        let glyph: CGGlyph
        let half: CGFloat

        static func == (a: OutlineKey, b: OutlineKey) -> Bool { a.glyph == b.glyph && a.half == b.half && CFEqual(a.font, b.font) }

        func hash(into hasher: inout Hasher) {
            hasher.combine(glyph)
            hasher.combine(half)
            hasher.combine(CFHash(font))
        }
    }

    /// Nil for a glyph with nothing to draw, such as a space, which is worth remembering too.
    private struct Outline: @unchecked Sendable {
        let path: CGPath?
    }

    private static let outlines = OSAllocatedUnfairLock(initialState: [OutlineKey: Outline]())
}

/// A line of text set along an arc of the ring: each glyph stands on a circle around the ring's middle, upright to it. It
/// reads clockwise with its top outwards, across the top and down both sides, so names next to each other read the same
/// way. Only in the bottom third, where that would be upside down, it's turned to read the other way round, top inwards.
///
/// It's a shape, so it's as sharp as the ring at any size, and glides with its piece while sizes change.
struct ArcText: Shape {
    let line: GlyphLine
    /// The ring's middle.
    var center: CGPoint
    /// The radius of the circle the baseline follows.
    var radius: CGFloat
    /// Where the line's middle is: clockwise from 12 o'clock, in radians.
    var angle: CGFloat
    /// Reads anticlockwise, top inwards: for the bottom third.
    let turned: Bool
    /// Extra room between glyphs, in points: text turned top inwards is squeezed at the top, and reads better let out a
    /// little.
    var tracking: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGPoint.AnimatableData> {
        get { AnimatablePair(AnimatablePair(angle, radius), center.animatableData) }
        set {
            angle = newValue.first.first
            radius = newValue.first.second
            center.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(Self.path(line, center: center, radius: radius, angle: angle, turned: turned, tracking: tracking))
    }

    /// Whether a name whose middle is at this angle is turned: in the bottom third, between 4 and 8 o'clock. Clockwise
    /// text there would be more than a third of the way to upside down; turned, it never tilts more than 60 degrees.
    static func isTurned(at angle: CGFloat) -> Bool {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return abs(a - .pi) < .pi / 3
    }

    /// How long the line is along its arc, with its tracking.
    static func length(_ line: GlyphLine, tracking: CGFloat) -> CGFloat {
        line.width + tracking * CGFloat(max(line.glyphs.count - 1, 0))
    }

    static func path(_ line: GlyphLine, center: CGPoint, radius: CGFloat, angle: CGFloat, turned: Bool, tracking: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        guard radius > 1 else { return path }
        let half = length(line, tracking: tracking) / 2
        for (i, glyph) in line.glyphs.enumerated() {
            guard let outline = glyph.outline else { continue }
            // How far along the arc from the line's middle, as an angle; the other way round when turned.
            let along = (glyph.middle + tracking * CGFloat(i) - half) / radius
            let at = turned ? angle - along : angle + along
            // The way the baseline runs there: clockwise is (cos, sin) on a screen whose y grows downwards.
            let turn = turned ? at + .pi : at
            var place = CGAffineTransform(translationX: center.x + sin(at) * radius, y: center.y - cos(at) * radius)
                .rotated(by: turn)
                // Glyphs are drawn y up.
                .scaledBy(x: 1, y: -1)
            if let placed = outline.copy(using: &place) { path.addPath(placed) }
        }
        return path
    }
}
