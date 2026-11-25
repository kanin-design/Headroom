import AppKit
import SwiftUI
import os

/// A name on the ring: inside a piece if it fits, set straight or along the piece's arc; otherwise out at the side with a
/// thin line to its piece.
public struct SunburstLabel: Identifiable, Equatable, Sendable {
    /// Inside its piece, set straight; inside it, along its arc (`arc` says how); or in the column of names to the left or
    /// right of the ring.
    public enum Place: Sendable { case inside, along, left, right }

    /// How a name is set along its piece's arc.
    public struct Arc: Equatable, Sendable {
        public enum Lines: Sendable {
            /// The name above its size, on two arcs.
            case stacked
            /// The name, then its size, on one arc.
            case inLine
            /// The name alone: there's no room for its size.
            case titleOnly
        }

        /// The ring's middle, in the view's points.
        public var center: CGPoint
        /// The radius of the middle of the band the name runs in.
        public var radius: CGFloat
        /// Where the name's middle is: clockwise from 12 o'clock, in radians.
        public var angle: CGFloat
        public var lines: Lines
    }

    public var id: UInt64
    /// The piece it names, in the layout it was placed for.
    public var pieceIndex: Int
    public var node: UInt32
    /// What it says: a name, and below it a size.
    public var title: String
    public var value: String
    /// Where the name's middle goes, inside a piece; for one at the side, where its column meets its line.
    public var position: CGPoint
    /// For a name at the side: where its line starts, at the edge of its piece.
    public var anchor: CGPoint
    /// For a name at the side: where its line turns level.
    public var elbow: CGPoint
    public var place: Place
    /// Written in dark text, on a light piece.
    public var dark: Bool
    /// Written larger, as on free space.
    public var large: Bool
    /// For a name set along its piece's arc (`.along`): how.
    public var arc: Arc?

    /// Whether it's out at the side, with a line to its piece.
    public var isAtSide: Bool { place == .left || place == .right }
}

/// Where a ring is in its view: its middle and its radius, in the view's points.
public struct RingPlacement: Sendable, Equatable {
    public var center: CGPoint
    public var radius: CGFloat

    public init(center: CGPoint = .zero, radius: CGFloat = 0) {
        self.center = center
        self.radius = radius
    }
}

extension SunburstLabel {
    /// The same name, moved with its ring from where it was placed for to where the ring is now: so names stay on the ring
    /// while it moves and grows or shrinks, as when a window is resized, until they're placed again for where it rests.
    /// What's on or beside a piece moves and scales with it; a name at the side keeps its size and its room from the next,
    /// and only follows the ring.
    public func following(from old: RingPlacement, to new: RingPlacement) -> SunburstLabel {
        guard old != new, old.radius > 0, new.radius > 0 else { return self }
        let scale = new.radius / old.radius
        func moved(_ p: CGPoint) -> CGPoint {
            CGPoint(x: new.center.x + (p.x - old.center.x) * scale, y: new.center.y + (p.y - old.center.y) * scale)
        }
        var out = self
        if isAtSide {
            // The column stays the same distance out from the ring's edge; the names keep their places in it.
            let side: CGFloat = place == .right ? 1 : -1
            let gap = abs(position.x - old.center.x) - old.radius
            let lift = new.center.y - old.center.y
            out.position = CGPoint(x: new.center.x + side * (new.radius + gap), y: position.y + lift)
            out.anchor = moved(anchor)
            let elbowGap = abs(elbow.x - old.center.x) - old.radius
            out.elbow = CGPoint(x: new.center.x + side * (new.radius + elbowGap), y: out.position.y)
        } else {
            out.position = moved(position)
            if var arc {
                arc.center = moved(arc.center)
                arc.radius *= scale
                out.arc = arc
            }
        }
        return out
    }
}

/// Whether the pointer is on anything on the ring, which named piece it's on, if any, and which names are lit with it.
public struct LabelLight: Equatable, Sendable {
    /// Whether the pointer is on the ring at all: then the names of what isn't lit step back.
    public var onAnything = false
    /// The named node the pointer is on, if any.
    public var node: UInt32?
    /// The named nodes that light with it: what's inside it, and what else lights with it. Their names stay as easy to read
    /// as their pieces are to see. The way out to it steps back with the rest: its names would read as naming what's
    /// pointed at.
    public var lit: Set<UInt32> = []

    public init() {}

    /// For the piece the pointer is on, if any, the pieces that have names, and those of them that light with it.
    public init(hovering node: UInt32?, named: Set<UInt32>, lit: Set<UInt32> = []) {
        onAnything = node != nil
        self.node = node.flatMap { named.contains($0) ? $0 : nil }
        self.lit = node == nil ? [] : lit
    }

    /// Whether a node's name is lit: the pointer is on it, or on something it lights with.
    public func isLit(_ node: UInt32) -> Bool { self.node == node || lit.contains(node) }

    /// How a node's name stands in this light.
    public func state(of node: UInt32) -> LabelState {
        if self.node == node { return .pointedAt }
        return onAnything && !lit.contains(node) ? .steppedBack : .atRest
    }
}

/// How a name stands while the pointer is over the ring.
public enum LabelState: Sendable {
    /// As it's drawn with nothing pointed at, or lit with what's pointed at: easy to read.
    case atRest
    /// The pointer is on its piece, or on the name: it stands out.
    case pointedAt
    /// Something else is pointed at, and it isn't lit with it: a name inside a piece steps back with its piece.
    case steppedBack
}

/// Each name's state, kept name by name. A view that reads one name's state is made again only when that name's changes,
/// so the pointer moving about inside one branch redraws no name at all, and crossing to another redraws the few that
/// change. A chart keeps one (`SunburstChart.labelLights`), and `SunburstLabels` can read it in place of a `LabelLight`.
@MainActor
public final class LabelLights {
    @Observable
    final class Entry {
        var state: LabelState
        init(_ state: LabelState) { self.state = state }
    }

    private var entries: [UInt32: Entry] = [:]
    private var light = LabelLight()
    private var changedAt = 0.0
    /// Whether the last change of light fades in: one that follows hard on another, as while the pointer travels across
    /// the ring, is just there. A fade is drawn on every frame, and there'd be nothing else.
    private(set) var fades = true

    public init() {}

    /// The state of a node's name. Read in a view's body, it's followed for that name alone.
    public func state(of node: UInt32) -> LabelState {
        if let entry = entries[node] { return entry.state }
        let entry = Entry(light.state(of: node))
        entries[node] = entry
        return entry.state
    }

    /// A new light: each name whose state it changes is told, and no other.
    public func show(_ light: LabelLight, now: Double = CACurrentMediaTime()) {
        guard light != self.light else { return }
        self.light = light
        fades = now - changedAt >= 0.15
        changedAt = now
        for (node, entry) in entries {
            let state = light.state(of: node)
            if entry.state != state { entry.state = state }
        }
    }

    /// Forgets every name but these: after the names changed.
    public func keep(_ nodes: Set<UInt32>) {
        guard entries.count > nodes.count else { return }
        entries = entries.filter { nodes.contains($0.key) }
    }
}

/// Where a name's view reads its state: from a light given whole, or name by name.
private enum LabelLightSource {
    case whole(LabelLight)
    case each(LabelLights)

    @MainActor func state(of node: UInt32) -> LabelState {
        switch self {
        case .whole(let light): light.state(of: node)
        case .each(let lights): lights.state(of: node)
        }
    }

    /// Whether the change of state just read fades in.
    @MainActor var fades: Bool {
        switch self {
        case .whole: true
        case .each(let lights): lights.fades
        }
    }
}

/// Where names can go: the ring, the width of the part of the window it's centred in, and how far up and down the names
/// at the sides may go.
public struct LabelArea: Sendable {
    /// The ring's middle and radius, in the view's points.
    public var center: CGPoint
    public var radius: CGFloat
    /// The size of the part of the view the ring is centred in.
    public var width: CGFloat
    public var height: CGFloat
    /// The highest a name at the side may sit, and the lowest.
    public var top: CGFloat
    public var bottom: CGFloat

    public init(center: CGPoint, radius: CGFloat, width: CGFloat, height: CGFloat, top: CGFloat = 24, bottom: CGFloat) {
        self.center = center
        self.radius = radius
        self.width = width
        self.height = height
        self.top = top
        self.bottom = bottom
    }
}

/// The fonts names inside pieces are drawn in: a name above, its size below, and both larger on free space.
enum LabelFont: Int, CaseIterable {
    case title, value, largeTitle, largeValue, arcTitle, arcValue
    /// A name at the side, as `OuterLabel` draws it.
    case sideTitle

    // Fonts don't change once made, so any thread may measure with them.
    nonisolated(unsafe) private static let made: [NSFont] = [
        .systemFont(ofSize: 12.5, weight: .semibold), .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .systemFont(ofSize: 14, weight: .semibold), .monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        // Names along an arc are a step smaller: they're further out, on thinner pieces, and there are more of them.
        .systemFont(ofSize: 11, weight: .semibold), .monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
        .systemFont(ofSize: 12, weight: .medium),
    ]
    var font: NSFont { Self.made[rawValue] }
}

/// A name set along an arc, worked out: its lines, each on its own circle and with its middle at its own angle. The placer
/// asks whether it fits its piece; the view draws exactly this.
struct ArcSetting {
    struct Line {
        let text: GlyphLine
        /// The circle its baseline follows.
        let radius: CGFloat
        /// Where its middle is.
        let angle: CGFloat
        let tracking: CGFloat
        let isValue: Bool

        /// How long it is along its arc.
        var length: CGFloat { ArcText.length(text, tracking: tracking) }
    }

    let lines: [Line]
    /// Reads anticlockwise, top inwards: in the bottom third of the ring.
    let turned: Bool

    /// How high capitals stand in the name's font and in its size's, and how far apart two lines are.
    private static let titleCap = LabelFont.arcTitle.font.capHeight, valueCap = LabelFont.arcValue.font.capHeight
    private static let pitch: CGFloat = 12.5
    /// The room between a name and its size on one line.
    private static let gap: CGFloat = 6
    /// The least band a line fits in, and two lines.
    fileprivate static let oneLine: CGFloat = 15, twoLines: CGFloat = 27
    /// Kept clear at each end of the arc.
    private static let pad: CGFloat = 7
    /// A tighter circle than this squeezes letters into each other.
    fileprivate static let leastRadius: CGFloat = 52

    init(title: String, value: String, arc: SunburstLabel.Arc) {
        let turned = ArcText.isTurned(at: arc.angle)
        // Out from the middle of the ring is up for text that isn't turned, and down for text that is.
        let up: CGFloat = turned ? -1 : 1
        // Turned text has its tops on the inside of the curve, where they crowd; a little air evens it out.
        let tracking: CGFloat = turned ? 0.5 : 0.12
        let name = GlyphLine.make(title, font: LabelFont.arcTitle.font), size = GlyphLine.make(value, font: LabelFont.arcValue.font)
        func line(_ text: GlyphLine, cap: CGFloat, raisedBy raise: CGFloat, along: CGFloat = 0, isValue: Bool) -> Line {
            // The line's own middle sits `raise` above the band's; its baseline half a capital below that.
            let radius = arc.radius + up * (raise - cap / 2)
            return Line(text: text, radius: radius, angle: arc.angle + up * along / max(radius, 1), tracking: tracking, isValue: isValue)
        }
        switch arc.lines {
        case .stacked:
            lines = [
                line(name, cap: Self.titleCap, raisedBy: Self.pitch / 2, isValue: false),
                line(size, cap: Self.valueCap, raisedBy: -Self.pitch / 2, isValue: true),
            ]
        case .inLine:
            let nameLength = ArcText.length(name, tracking: tracking), sizeLength = ArcText.length(size, tracking: tracking)
            let whole = nameLength + Self.gap + sizeLength
            lines = [
                line(name, cap: Self.titleCap, raisedBy: 0, along: -(whole - nameLength) / 2, isValue: false),
                line(size, cap: Self.titleCap, raisedBy: 0, along: (whole - sizeLength) / 2, isValue: true),
            ]
        case .titleOnly:
            lines = [line(name, cap: Self.titleCap, raisedBy: 0, isValue: false)]
        }
        self.turned = turned
    }

    /// Whether every line fits an arc that sweeps this far, with room kept at its ends.
    func fits(sweep: CGFloat, around angle: CGFloat) -> Bool {
        lines.allSatisfy { line in
            let half = line.length / 2 / max(line.radius, 1)
            let offset = abs(line.angle - angle)
            return offset + half <= sweep / 2 - Self.pad / max(line.radius, 1)
        }
    }
}

/// Places names on and around the ring. What each piece is called, and which pieces are named at the sides, is the host's:
/// these find where the names fit.
public enum LabelPlacer {
    private typealias Font = LabelFont

    /// How wide text is in one of the fonts. Names are placed again on every change of picture, many times a second while
    /// sizes are arriving, and mostly the same names, so each width is measured once.
    private static func width(_ text: String, _ font: Font) -> CGFloat {
        if let known = widths.withLock({ $0[font.rawValue][text] }) { return known }
        let measured = ceil((text as NSString).size(withAttributes: [.font: font.font]).width)
        widths.withLock { known in
            // Enough for every name a window shows at once, many times over; past that it starts again.
            if known.reduce(0, { $0 + $1.count }) > 8192 { known = Array(repeating: [:], count: Font.allCases.count) }
            known[font.rawValue][text] = measured
        }
        return measured
    }

    /// Widths measured so far, for each font.
    private static let widths = OSAllocatedUnfairLock(
        initialState: [[String: CGFloat]](repeating: [:], count: Font.allCases.count))

    // R is the ring's radius, as the geometry writes it.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    /// Where a box of this size fits inside a piece: its middle if possible, otherwise slid along the arc to where the
    /// ring runs closer to level. A name that fits nearby is better than one out at the side. `outward` moves the box out
    /// from the middle of the ring by that factor, as free space's name is.
    private static func fit(w: CGFloat, h: CGFloat, piece p: Piece, radius R: CGFloat, outward: CGFloat = 1) -> CGFloat? {
        let mid = CGFloat(p.midAngle)
        let sweep = CGFloat(p.sweep)
        // A big piece's name belongs on it, so those look harder for a place.
        let big = p.ring <= 1
        let steps: [CGFloat] =
            big
            ? [0, 0.08, -0.08, 0.16, -0.16, 0.24, -0.24, 0.3, -0.3, 0.36, -0.36, 0.42, -0.42]
            : [0, 0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.38, -0.38]
        for step in steps {
            let angle = mid + sweep * step
            if fits(w: w, h: h, angle: angle, piece: p, radius: R, margin: big ? 2 : 3, outward: outward) { return angle }
        }
        return nil
    }

    // R is the ring's radius, as the geometry writes it.
    // swift-format-ignore: AlwaysUseLowerCamelCase
    private static func fits(
        w: CGFloat, h: CGFloat, angle: CGFloat, piece p: Piece, radius R: CGFloat, margin: CGFloat,
        outward: CGFloat
    ) -> Bool {
        let mid = CGFloat(p.midAngle)
        let rm = CGFloat(p.r0 + p.r1) * 0.5 * R * outward
        let cx = sin(angle) * rm, cy = -cos(angle) * rm
        let inner = CGFloat(p.r0) * R + margin, outer = CGFloat(p.r1) * R - margin
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
            let x = cx + CGFloat(sx) * w / 2, y = cy + CGFloat(sy) * h / 2
            let r = hypot(x, y)
            if r < inner || r > outer { return false }
            var a = atan2(x, -y)
            if a < 0 { a += 2 * .pi }
            // Near 12 o'clock the angle wraps around, so measure from the piece's middle.
            var delta = a - mid
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            let half = CGFloat(p.sweep) * 0.5 - margin / max(r, 1)
            if abs(delta) > half { return false }
        }
        return true
    }

    private static func isBright(_ c: SIMD3<Float>) -> Bool {
        0.2289 * c.x + 0.6917 * c.y + 0.0793 * c.z > 0.40
    }

    /// A piece to name at the side, with what to call it.
    public struct Pick: Sendable {
        /// The piece to name, in the layout.
        public var index: Int
        public var title: String
        public var value: String
        /// How much it matters: the best are named first, as many as fit.
        public var score: Double
        /// Tells apart names that share a piece, such as two copies too small to show apart.
        public var salt: UInt64 = 0

        public init(index: Int, title: String, value: String, score: Double, salt: UInt64 = 0) {
            self.index = index
            self.title = title
            self.value = value
            self.score = score
            self.salt = salt
        }
    }

    /// What's been named so far, so a piece isn't named twice.
    public struct Placed: Sendable {
        /// Pieces named inside themselves.
        public var labelled = Set<Int>()
        /// A folder drawn as several stretches is named once.
        public var nodes = Set<UInt32>()

        public init() {}
    }

    /// Pieces biggest first. With a split, its sides come first, whatever they hold, and the rest go by how big they're
    /// drawn: a folder on the smaller side is drawn bigger than its size alone would say.
    public static func order(_ layout: RingLayout) -> [Int] {
        let halvesFirst = layout.isSplit
        return layout.pieces.indices.sorted { a, b in
            let pa = layout.pieces[a], pb = layout.pieces[b]
            if halvesFirst, (pa.ring == 0) != (pb.ring == 0) { return pa.ring == 0 }
            return halvesFirst ? pa.a1 - pa.a0 > pb.a1 - pb.a0 : pa.size > pb.size
        }
    }

    /// Names inside the pieces, biggest first, wherever they fit. `name` says what a piece is called and what it holds, or
    /// nil to leave it unnamed. A split drawn as a ring has its two sides always named, just either side of six o'clock.
    /// Nothing is named on a band: it's too thin, and the centre says what's pointed at.
    public static func inside(
        layout: RingLayout, order: [Int], area: LabelArea, named: inout Placed, short: ShortNames = ShortNames(),
        name: (Piece) -> (title: String, value: String)?
    ) -> [SunburstLabel] {
        let halves = layout.levels.first.map { $0.part == .split && !$0.isThin } ?? false
        let sides = halves ? layout.pieces.lazy.filter { $0.ring == 0 }.count : 0
        // R is the ring's radius, as the geometry writes it.
        // swift-format-ignore: AlwaysUseLowerCamelCase
        let R = area.radius
        guard R > 0, !layout.pieces.isEmpty else { return [] }
        // The first ring of things, past a band or a split: its names are set straight.
        let firstRing = layout.levels.firstIndex { !$0.isThin && $0.part != .split } ?? 0
        // The pieces that could be named, with what they'd say.
        var candidates: [(index: Int, said: (title: String, value: String), forms: [String])] = []
        var seen = Set<UInt32>()
        for i in order.prefix(160) {
            let p = layout.pieces[i]
            // The outer rings are for the shape: names go on the first few, where there's room to read them.
            if p.isSmaller || p.ring > 3 || named.nodes.contains(p.node) || seen.contains(p.node) { continue }
            if Int(p.ring) < layout.levels.count, layout.levels[Int(p.ring)].isThin, !p.isSpace { continue }
            guard let said = name(p) else { continue }
            seen.insert(p.node)
            candidates.append((i, said, short.forms(of: i, full: said.title)))
        }

        /// The name, written as `title`, where it fits on its piece, or nil.
        func place(_ i: Int, _ title: String, _ value: String) -> SunburstLabel? {
            let p = layout.pieces[i]
            let isFree = p.role == .room
            // A ghost is drawn faint, whatever its colour, so its name is light like on the dark parts.
            let isHidden = p.role == .unreadable || p.role == .gone
            // Free space reads best out in the open part of the wedge, away from the crowded middle.
            let outward: CGFloat = isFree ? 1.08 : 1
            let halfSpot: CGFloat? = halves && layout.focus == 0 && p.ring == 0 ? sideSpot(p, sides: sides) : nil
            let dark = !isFree && !isHidden && isBright(p.color)
            // The first ring is named straight, as it always was. From the second ring out the pieces are bands, and a
            // name runs clockwise along its band, as its neighbours' do; straight only where it doesn't fit that way.
            let curves = Int(p.ring) > firstRing && !isFree && halfSpot == nil
            if curves, let arc = along(title: title, value: value, piece: p, area: area) {
                return SunburstLabel(
                    id: p.key, pieceIndex: i, node: p.node, title: title, value: value,
                    position: point(area, arc.angle, arc.radius), anchor: .zero, elbow: .zero, place: .along,
                    dark: dark, large: false, arc: arc)
            }
            // Free space's name is written larger, and measured as it's drawn.
            let w =
                isFree
                ? max(width(title, .largeTitle), width(value, .largeValue)) + 2
                : max(width(title, .title), width(value, .value)) + 2
            let h: CGFloat = isFree ? 34 : 31
            guard let angle = halfSpot ?? fit(w: w, h: h, piece: p, radius: R, outward: outward) else { return nil }
            let rm = CGFloat(p.r0 + p.r1) * 0.5 * R * outward
            return SunburstLabel(
                id: p.key, pieceIndex: i, node: p.node, title: title, value: value,
                position: point(area, angle, rm), anchor: .zero, elbow: .zero, place: .inside,
                dark: dark, large: isFree)
        }

        // How far each name has to be cut to fit: all of it, or cut around what tells it apart from its neighbours.
        var firstFit: [Int: Int] = [:]
        for c in candidates {
            if let k = c.forms.indices.first(where: { place(c.index, c.forms[$0], c.said.value) != nil }) { firstFit[c.index] = k }
        }
        // Neighbours are written alike: as far cut as the one with least room needs.
        var level: [Int32: Int] = [:]
        for c in candidates where c.forms.count > 1 {
            guard let k = firstFit[c.index] else { continue }
            let parent = layout.pieces[c.index].parent
            level[parent] = max(level[parent] ?? 0, k)
        }

        var out: [SunburstLabel] = []
        for c in candidates {
            guard let k = firstFit[c.index] else { continue }
            let alike = c.forms.count > 1 ? min(max(level[layout.pieces[c.index].parent] ?? k, k), c.forms.count - 1) : k
            guard let label = place(c.index, c.forms[alike], c.said.value) ?? place(c.index, c.forms[k], c.said.value) else { continue }
            out.append(label)
            named.labelled.insert(c.index)
            named.nodes.insert(layout.pieces[c.index].node)
            if out.count >= 44 { break }
        }
        return out
    }

    /// How a piece's name fits along its arc, if it does: the name above its size where the band is thick enough for two
    /// lines, else both on one line, else the name alone. A long thin piece, which a straight name never fits, holds one
    /// this way.
    static func along(title: String, value: String, piece p: Piece, area: LabelArea) -> SunburstLabel.Arc? {
        // R is the ring's radius, as the geometry writes it.
        // swift-format-ignore: AlwaysUseLowerCamelCase
        let R = area.radius
        let thickness = CGFloat(p.r1 - p.r0) * R, middle = CGFloat(p.r0 + p.r1) * 0.5 * R
        guard thickness >= ArcSetting.oneLine, middle >= ArcSetting.leastRadius, !title.isEmpty else { return nil }
        let sweep = CGFloat(p.sweep), angle = CGFloat(p.midAngle)
        var arc = SunburstLabel.Arc(center: area.center, radius: middle, angle: angle, lines: .stacked)
        let ways: [SunburstLabel.Arc.Lines] =
            (thickness >= ArcSetting.twoLines && !value.isEmpty ? [.stacked] : [])
            + (value.isEmpty ? [] : [.inLine]) + [.titleOnly]
        for lines in ways {
            arc.lines = lines
            if ArcSetting(title: title, value: value, arc: arc).fits(sweep: sweep, around: angle) { return arc }
        }
        return nil
    }

    /// Where a side of a split names itself: as near six o'clock as its own arc allows, so two sides are named either side of
    /// it and more each inside their own.
    private static func sideSpot(_ p: Piece, sides: Int) -> CGFloat {
        if sides == 2 { return p.a0 < .pi ? .pi - 0.27 : .pi + 0.27 }
        let low = CGFloat(p.a0) + 0.27, high = CGFloat(p.a1) - 0.27
        return min(max(.pi, low), max(high, low))
    }

    /// What's big but couldn't hold its own name, to name at the side: anything drawn over 1.5% of the way round in the
    /// first five rings, unless a name on a piece just inside it says nearly the same thing. With halves, that's half its
    /// share of its own half, so the smaller half's big things are named too.
    public static func bigPieces(
        layout: RingLayout, order: [Int], named: inout Placed,
        name: (Piece) -> (title: String, value: String)
    ) -> [Pick] {
        var picks: [Pick] = []
        for i in order.prefix(260) where !named.labelled.contains(i) {
            let p = layout.pieces[i]
            if p.isSmaller || p.role == .room || p.ring > 4 || named.nodes.contains(p.node) { continue }
            let share = Double(p.a1 - p.a0) / (2 * .pi)
            if share < 0.015 { continue }
            // What the whole disk is made of is named on itself, except space that can't be read, which is a hatched wedge
            // too narrow for its name: it's named here, so the sizes add up.
            if p.ring == 0 && layout.focus == 0 && p.role != .unreadable { continue }
            // A band's segments aren't named: the centre says what's pointed at.
            if Int(p.ring) < layout.levels.count, layout.levels[Int(p.ring)].isThin, !p.isSpace { continue }
            var a = p.parent
            var redundant = false
            while a >= 0 {
                let q = layout.pieces[Int(a)]
                if named.labelled.contains(Int(a)) && Double(p.size) > Double(q.size) * 0.72 { redundant = true }
                a = q.parent
            }
            if redundant { continue }
            let said = name(p)
            picks.append(Pick(index: i, title: said.title, value: said.value, score: share * (1 - 0.13 * Double(p.ring))))
            named.nodes.insert(p.node)
        }
        return picks
    }

    @available(*, deprecated, message: "Pieces are judged by how much of the ring they take: drop `total`.")
    public static func bigPieces(
        layout: RingLayout, order: [Int], total: UInt64, named: inout Placed,
        name: (Piece) -> (title: String, value: String)
    ) -> [Pick] {
        bigPieces(layout: layout, order: order, named: &named, name: name)
    }

    /// Names out at the sides, best first, each with a thin line to its piece, as many as fit. Unless `eachCounts`, a name
    /// just outside a piece that's already named is left out, as it would say nearly the same thing.
    public static func sides(
        _ picks: [Pick], layout: RingLayout, area: LabelArea, eachCounts: Bool,
        short: ShortNames = ShortNames()
    ) -> [SunburstLabel] {
        // R is the ring's radius, as the geometry writes it.
        // swift-format-ignore: AlwaysUseLowerCamelCase
        let R = area.radius
        guard R > 0, !layout.pieces.isEmpty else { return [] }
        let cx = area.center.x, cy = area.center.y
        var candidates = picks
        candidates.sort { $0.score > $1.score }
        var kept: [Pick] = []
        for c in candidates {
            let p = layout.pieces[c.index]
            var a = p.parent
            var repeats = false
            while a >= 0 && !eachCounts {
                let q = layout.pieces[Int(a)]
                if kept.contains(where: { $0.index == Int(a) }) && Double(p.size) > Double(q.size) * 0.72 { repeats = true }
                a = q.parent
            }
            if !repeats { kept.append(c) }
        }
        candidates = kept

        let spacing: CGFloat = 35
        let maxPerSide = min(max(Int((area.height - 150) / spacing), 3), 7)
        var rightSide: [Pick] = [], leftSide: [Pick] = []
        // What's near six o'clock is as near one side as the other. It's named on its own side while there's room, and
        // on the other when its own is full.
        func isLow(_ c: Pick) -> Bool { abs(layout.pieces[c.index].midAngle - .pi) < 0.6 }
        for c in candidates {
            let onRight = layout.pieces[c.index].midAngle < .pi
            if onRight ? rightSide.count < maxPerSide : leftSide.count < maxPerSide {
                if onRight { rightSide.append(c) } else { leftSide.append(c) }
            } else if isLow(c), onRight ? leftSide.count < maxPerSide : rightSide.count < maxPerSide {
                if onRight { leftSide.append(c) } else { rightSide.append(c) }
            }
        }
        // Many names for things crowded at the bottom of one side stack up far from what they name, their lines crossing
        // the ring to reach it. The other side takes some, nearest six o'clock first, until the two are about even.
        func evenOut(from full: inout [Pick], to other: inout [Pick], rightToLeft: Bool) {
            while full.count >= other.count + 2 {
                let low = full.indices.filter { at in
                    let mid = layout.pieces[full[at].index].midAngle
                    return isLow(full[at]) && (mid < .pi) == rightToLeft
                }
                guard
                    let nearest = low.min(by: {
                        abs(layout.pieces[full[$0].index].midAngle - .pi) < abs(layout.pieces[full[$1].index].midAngle - .pi)
                    })
                else { return }
                other.append(full.remove(at: nearest))
            }
        }
        evenOut(from: &rightSide, to: &leftSide, rightToLeft: true)
        evenOut(from: &leftSide, to: &rightSide, rightToLeft: false)

        /// How far out this wedge reaches along its own centre line. The line to a name starts there, so it never
        /// crosses the ring.
        func silhouette(_ index: Int, _ angle: Float) -> Float {
            var edge = layout.pieces[index].r1
            let all = layout.extent(of: index)
            var j = all.lowerBound
            while j < all.upperBound {
                let q = layout.pieces[j]
                if angle >= q.a0 && angle < q.a1 {
                    edge = max(edge, q.r1)
                    j += 1
                } else {
                    j = max(Int(q.end), j + 1)
                }
            }
            return edge
        }

        var out: [SunburstLabel] = []
        func layoutSide(_ side: [Pick], right: Bool) {
            guard !side.isEmpty else { return }
            let reach = R + 26
            struct Slot { var c: Pick; var y: CGFloat; var mid: CGFloat }
            // Top to bottom in the order the pieces come down this side of the ring, and on past six o'clock for what was
            // taken from the other side: then no line crosses another.
            func down(_ mid: CGFloat) -> CGFloat { right ? mid : 2 * .pi - mid }
            let top = area.top, bottom = area.bottom
            /// Level with its piece, as near as the view allows.
            func level(_ mid: CGFloat) -> CGFloat { min(max(cy - cos(mid) * reach, top), bottom) }
            func stacked(_ picks: [Pick]) -> [Slot] {
                var slots = picks.map { c -> Slot in
                    let mid = CGFloat(layout.pieces[c.index].midAngle)
                    return Slot(c: c, y: cy - cos(mid) * reach, mid: mid)
                }.sorted { down($0.mid) < down($1.mid) }
                for i in slots.indices {
                    slots[i].y = max(slots[i].y, i == 0 ? top : slots[i - 1].y + spacing)
                }
                if let last = slots.last, last.y > bottom {
                    var limit = bottom
                    for i in slots.indices.reversed() {
                        slots[i].y = min(slots[i].y, limit)
                        limit = slots[i].y - spacing
                    }
                }
                return slots
            }
            // Names for things crowded together push each other up or down the column, and one pushed far from its piece
            // reaches it with a long line across the ring and across the others. Those go, least important first, until
            // every name left is near what it names.
            var picks = side
            var slots = stacked(picks)
            while let far = slots.filter({ abs($0.y - level($0.mid)) > spacing * 2.5 }).min(by: { $0.c.score < $1.c.score }) {
                picks.removeAll { $0.index == far.c.index && $0.salt == far.c.salt }
                slots = stacked(picks)
            }
            let columnX = right ? cx + R + 34 : cx - R - 34
            for slot in slots {
                let p = layout.pieces[slot.c.index]
                let edge = CGFloat(silhouette(slot.c.index, p.midAngle)) * R + 2
                let anchor = point(area, slot.mid, edge)
                // The line leaves along its wedge until it's level with the name, then runs dead level to it.
                let side: CGFloat = right ? 1 : -1
                let rise = slot.y - anchor.y
                let along = -cos(slot.mid)
                var bend = anchor.x + side * max(abs(rise) * 1.5, 14)
                if abs(along) > 0.05, rise * along > 0 { bend = anchor.x + sin(slot.mid) * rise / along }
                // Never back into the ring, and never past the name.
                let nameEnd = columnX - side * 7
                bend = right ? min(max(bend, anchor.x + 6), nameEnd - 8) : max(min(bend, anchor.x - 6), nameEnd + 8)
                // The longest way of writing the name that the column has room for, as the view gives it room.
                let room = max(right ? area.width - columnX - 6 : columnX - 12, 60)
                // It may shrink a fifth before it's cut; a name too long even cut short is cut once, in the middle, never
                // cut again.
                let forms = short.forms(of: slot.c.index, full: slot.c.title)
                let title = forms.first { width($0, .sideTitle) * 0.82 <= room } ?? slot.c.title
                // A name that changes sides is a new label, so it fades across instead of flying over the ring.
                out.append(
                    SunburstLabel(
                        id: p.key ^ (right ? 0xABCD : 0xDCBA) ^ slot.c.salt, pieceIndex: slot.c.index, node: p.node, title: title,
                        value: slot.c.value,
                        position: CGPoint(x: columnX, y: slot.y), anchor: anchor, elbow: CGPoint(x: bend, y: slot.y),
                        place: right ? .right : .left, dark: false, large: false))
            }
        }
        // Only when there's room beside the ring.
        if area.width - R * 2 > 200 {
            layoutSide(rightSide, right: true)
            layoutSide(leftSide, right: false)
        }
        return out
    }

    private static func point(_ area: LabelArea, _ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: area.center.x + sin(angle) * radius, y: area.center.y - cos(angle) * radius)
    }
}

/// The names: inside the pieces, and out at the sides with their lines. `outer` dresses each name at the side, such as
/// with a menu of its own.
public struct SunburstLabels<Outer: ViewModifier>: View {
    let labels: [SunburstLabel]
    private let light: LabelLightSource
    let visible: Bool
    /// The width of the part of the window the ring is centred in.
    let width: CGFloat
    let onEnter: (Int) -> Void
    let onLeave: (Int) -> Void
    let onOpen: (_ piece: Int, _ clicks: Int) -> Void
    let outer: (SunburstLabel) -> Outer
    /// Where the names were placed for, and where the ring is now: they follow it.
    private var follow: (from: RingPlacement, to: RingPlacement)?

    public init(
        labels: [SunburstLabel], light: LabelLight, visible: Bool, width: CGFloat, onEnter: @escaping (Int) -> Void,
        onLeave: @escaping (Int) -> Void, onOpen: @escaping (_ piece: Int, _ clicks: Int) -> Void,
        outer: @escaping (SunburstLabel) -> Outer
    ) {
        self.labels = labels
        self.light = .whole(light)
        self.visible = visible
        self.width = width
        self.onEnter = onEnter
        self.onLeave = onLeave
        self.onOpen = onOpen
        self.outer = outer
    }

    /// The same, lit name by name: a change of light makes again only the names it changes, where a `LabelLight` given whole
    /// makes them all again.
    public init(
        labels: [SunburstLabel], lights: LabelLights, visible: Bool, width: CGFloat, onEnter: @escaping (Int) -> Void,
        onLeave: @escaping (Int) -> Void, onOpen: @escaping (_ piece: Int, _ clicks: Int) -> Void,
        outer: @escaping (SunburstLabel) -> Outer
    ) {
        self.labels = labels
        light = .each(lights)
        self.visible = visible
        self.width = width
        self.onEnter = onEnter
        self.onLeave = onLeave
        self.onOpen = onOpen
        self.outer = outer
    }

    /// The names, placed for a ring at `placedFor`, drawn on the ring where it is now (`ring`): while the ring moves, as when
    /// a window is resized, they move with it. Give it the ring as it's given to `RingPlace`, and in an animation they move
    /// as the ring does, frame for frame.
    public func following(_ ring: RingPlacement, placedFor: RingPlacement) -> Self {
        var copy = self
        copy.follow = (placedFor, ring)
        return copy
    }

    /// Quicker than the glide of the names that stay, so a name on its way out is soon gone.
    private static var comeAndGo: AnyTransition { AnyTransition.opacity.animation(.easeOut(duration: 0.18)) }

    public var body: some View {
        let labels = follow.map { f in self.labels.map { $0.following(from: f.from, to: f.to) } } ?? self.labels
        ZStack(alignment: .topLeading) {
            ForEach(labels.filter(\.isAtSide)) { label in
                LeaderMark(label: label, light: light)
                    .allowsHitTesting(false)
                    .transition(Self.comeAndGo)
            }

            ForEach(labels) { label in
                if label.place == .inside {
                    InsideLabel(label: label, light: light)
                        .position(label.position)
                        .allowsHitTesting(false)
                        .transition(Self.comeAndGo)
                } else if label.place == .along {
                    if let arc = label.arc {
                        ArcLabel(label: label, arc: arc, light: light)
                            .allowsHitTesting(false)
                            .transition(Self.comeAndGo)
                    }
                } else {
                    let right = label.place == .right
                    let room = max(right ? width - label.position.x - 6 : label.position.x - 12, 60)
                    OuterLabel(label: label, light: light)
                        .onHover { inside in
                            if inside { onEnter(label.pieceIndex) } else { onLeave(label.pieceIndex) }
                        }
                        .onTapGesture { onOpen(label.pieceIndex, NSApp.currentEvent?.clickCount ?? 1) }
                        .modifier(outer(label))
                        .frame(width: room, alignment: right ? .leading : .trailing)
                        .position(x: right ? label.position.x + room / 2 : label.position.x - room / 2, y: label.position.y)
                        .transition(Self.comeAndGo)
                }
            }
        }
        .opacity(visible ? 1 : 0)
    }
}

/// The thin line from a piece to its name. It's a shape so that it can glide with the piece while sizes change.
private struct LeaderLine: Shape {
    var anchor: CGPoint
    var elbow: CGPoint
    var end: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>, CGPoint.AnimatableData> {
        get { AnimatablePair(AnimatablePair(anchor.animatableData, elbow.animatableData), end.animatableData) }
        set {
            anchor.animatableData = newValue.first.first
            elbow.animatableData = newValue.first.second
            end.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: anchor)
        path.addLine(to: elbow)
        path.addLine(to: end)
        return path
    }
}

/// A name's line from its piece, and the dot where it starts. They brighten with the name by fading, which costs no
/// drawing.
private struct LeaderMark: View {
    let label: SunburstLabel
    let light: LabelLightSource

    var body: some View {
        let isOn = light.state(of: label.node) == .pointedAt
        ZStack(alignment: .topLeading) {
            LeaderLine(
                anchor: label.anchor, elbow: label.elbow,
                end: CGPoint(x: label.position.x + (label.place == .right ? -7 : 7), y: label.position.y)
            )
            .stroke(.white, lineWidth: isOn ? 1 : 0.75)
            .opacity(isOn ? 0.7 : 0.26)
            Circle()
                .fill(.white)
                .frame(width: 3.2, height: 3.2)
                .opacity(isOn ? 1 : 0.7)
                .position(label.anchor)
        }
    }
}

private struct InsideLabel: View {
    let label: SunburstLabel
    let light: LabelLightSource

    var body: some View {
        let state = light.state(of: label.node)
        VStack(spacing: 0) {
            Text(label.title)
                .font(.system(size: label.large ? 14 : 12.5, weight: .semibold))
            Text(label.value)
                .font(.system(size: label.large ? 13 : 11, weight: .medium).monospacedDigit())
                .opacity(label.dark ? 0.72 : 0.78)
        }
        // New numbers replace the old ones at once. Fading between them would leave both on screen as the label moves.
        .contentTransition(.identity)
        .foregroundStyle(label.dark ? Color.black.opacity(0.84) : Color.white.opacity(0.96))
        .shadow(color: label.dark ? .clear : .black.opacity(0.45), radius: 2, y: 0.5)
        .lineLimit(1)
        .fixedSize()
        .opacity(state == .steppedBack ? 0.5 : 1)
        .animation(light.fades ? .easeOut(duration: 0.14) : nil, value: state)
    }
}

/// A name set along its piece's arc: the same name and size as a straight one, in the same fonts and colours, as glyph
/// outlines on circles around the ring's middle.
private struct ArcLabel: View {
    let label: SunburstLabel
    let arc: SunburstLabel.Arc
    let light: LabelLightSource

    var body: some View {
        let state = light.state(of: label.node)
        let setting = ArcSetting(title: label.title, value: label.value, arc: arc)
        ZStack {
            ForEach(Array(setting.lines.enumerated()), id: \.offset) { _, line in
                ArcText(
                    line: line.text, center: arc.center, radius: line.radius, angle: line.angle, turned: setting.turned,
                    tracking: line.tracking
                )
                .fill(label.dark ? Color.black.opacity(0.84) : Color.white.opacity(0.96))
                .opacity(line.isValue ? (label.dark ? 0.72 : 0.78) : 1)
            }
        }
        .shadow(color: label.dark ? .clear : .black.opacity(0.45), radius: 2, y: 0.5)
        .opacity(state == .steppedBack ? 0.5 : 1)
        .animation(light.fades ? .easeOut(duration: 0.14) : nil, value: state)
    }
}

/// A name at the side. It brightens under the pointer by fading, not by being written again in another colour, so
/// nothing is drawn or laid out again for it.
private struct OuterLabel: View {
    let label: SunburstLabel
    let light: LabelLightSource

    var body: some View {
        let state = light.state(of: label.node)
        let isOn = state == .pointedAt
        VStack(alignment: label.place == .left ? .trailing : .leading, spacing: 0) {
            Text(label.title)
                .font(.system(size: 12, weight: .medium))
                // Beside a panel there's less room: a long name gets a little smaller before it's cut short, in the middle
                // as the Finder cuts one, so the end that tells two files apart (a year, a version, a kind) stays.
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
                .opacity(isOn ? 1 : 0.88)
            Text(label.value)
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .opacity(isOn ? 0.85 : 0.5)
        }
        .foregroundStyle(.white)
        .contentTransition(.identity)
        .lineLimit(1)
        // While something else is pointed at, it steps back as the names inside the ring do, so the name of what's pointed
        // at is the one that reads.
        .opacity(state == .steppedBack ? 0.5 : 1)
        .animation(light.fades ? .easeOut(duration: 0.14) : nil, value: state)
        .contentShape(Rectangle())
    }
}
