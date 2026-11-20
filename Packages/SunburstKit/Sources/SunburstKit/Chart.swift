import AppKit
import Observation
import SwiftUI

/// A sunburst with everything wired up: the ring, the names on and beside it, the readout in the middle, pointing, zooming
/// and VoiceOver. Show it with `Sunburst(chart)`.
///
/// Everything a person can do with the pointer can be done from code too: `zoom(into:)`, `zoomOut()`, `highlight(_:)`,
/// `node(at:)`, `summary(limit:)` for what's on the ring in words, and `picture(width:height:)` for an image of it. That's
/// what an app's own logic, or an agent, drives it with.
@MainActor
@Observable
public final class SunburstChart<Tree: SunburstTree> {
    /// Holds the picture and everything that moves.
    @ObservationIgnored public let engine: SunburstEngine

    /// The tree on the ring. Setting it again, as after sizes changed, moves every piece to its new place and keeps what's in
    /// the middle, so its node numbers must mean the same things. For a different tree altogether, use `show(_:)`.
    public var tree: Tree {
        didSet { if !replacing { redraw(.settle) } }
    }
    /// The node in the middle: 0, the root, until something is zoomed into.
    public private(set) var focus: UInt32 = 0
    /// The node under the pointer, if any.
    public private(set) var hovered: UInt32?
    /// Nodes drawn striped, such as what's selected.
    public var marked: Set<UInt32> = [] {
        didSet { if marked != oldValue, !replacing { redraw(.recolor) } }
    }
    /// How many rings, and how thick.
    public var sizes = RingSizes() {
        didSet { if sizes != oldValue { redraw(.settle) } }
    }

    /// What a node is called, on the ring and to VoiceOver.
    @ObservationIgnored public var name: (UInt32) -> String {
        didSet { placeLabels(); updateReadout() }
    }
    /// How a size is written: a number, then a space and a unit, such as "4.20 GB". The readout shows the unit smaller.
    @ObservationIgnored public var sizeText: (UInt64) -> String {
        didSet { placeLabels(); updateReadout() }
    }
    /// The colour of each piece, given the node in the middle. By default each branch in view gets its own colour from the
    /// whole spectrum, with everything inside it close to that colour (`BranchColours`).
    @ObservationIgnored public var colours: ((_ tree: Tree, _ focus: UInt32) -> RingLayout.Colorer)? {
        didSet { redraw(.recolor) }
    }
    /// A click on a piece that has nothing inside to zoom into, such as a file.
    @ObservationIgnored public var onOpen: ((UInt32) -> Void)?
    /// The node in the middle changed.
    @ObservationIgnored public var onFocus: ((UInt32) -> Void)?

    // What the view shows. Kept here so names and the readout follow the ring.
    var labels: [SunburstLabel] = []
    var light = LabelLight()
    var readout = SunburstReadout()
    @ObservationIgnored private(set) var place = (center: CGPoint.zero, radius: CGFloat(0), size: CGSize.zero)
    @ObservationIgnored weak var view: SunburstView?
    @ObservationIgnored private var version = 0
    @ObservationIgnored private var hoveredPiece: Int?
    @ObservationIgnored private var lit: (nodes: [UInt32], tint: SIMD3<Float>?)?
    @ObservationIgnored private var replacing = false

    /// `name` says what each node is called. `sizeText` writes a size: by default in bytes, as `SunburstFormat.bytes`.
    public init(tree: Tree, name: @escaping (UInt32) -> String, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
                engine: SunburstEngine = SunburstEngine()) {
        self.tree = tree
        self.name = name
        self.sizeText = sizeText
        self.engine = engine
        redraw(.appear)
    }

    // MARK: Driving it

    /// A different tree: back to its root, with nothing marked or lit, unfurling as a first picture does.
    public func show(_ tree: Tree) {
        replacing = true
        self.tree = tree
        marked = []
        replacing = false
        let wasAway = focus != 0
        focus = 0
        lit = nil
        redraw(.appear)
        if wasAway { onFocus?(0) }
    }

    /// Zooms into a node: it fills the ring, with what's inside it around it. A node with nothing inside it is opened
    /// instead (`onOpen`). Says whether it zoomed.
    @discardableResult
    public func zoom(into node: UInt32) -> Bool {
        let target = RingLayout.chainTail(tree: tree, node)
        guard target != focus, tree.firstChild(of: target) != 0 else {
            if tree.firstChild(of: node) == 0 { onOpen?(node) }
            return false
        }
        let mapping = engine.layout.piece(of: node).map { ZoomMapping(engine.layout.pieces[$0]) }
        focus = target
        lit = nil
        redraw(.zoomIn(mapping))
        onFocus?(focus)
        return true
    }

    /// One level back out, toward the root.
    public func zoomOut() {
        guard focus != 0 else { return }
        let old = focus
        var up = tree.parent(of: focus)
        // A folder drawn as one with the one it's nearly all of would show the same picture, so it's passed over.
        while up != 0, RingLayout.chainTail(tree: tree, up) == old { up = tree.parent(of: up) }
        focus = up
        lit = nil
        let layout = makeLayout()
        let mapping = layout.nearestPiece(to: old, tree: tree).map { ZoomMapping(layout.pieces[$0]) }
        show(layout, .zoomOut(mapping))
        onFocus?(focus)
    }

    /// Back to the root.
    public func zoomToRoot() {
        while focus != 0 { zoomOut() }
    }

    /// Lights these nodes, and what holds them, and lets everything else step back. In `tint`, if given, they and the way out
    /// to them take on one colour. A node too small to have a piece of its own lights the piece that holds it.
    public func highlight(_ nodes: [UInt32], tint: SIMD3<Float>? = nil) {
        lit = nodes.isEmpty ? nil : (nodes, tint)
        applyLight()
    }

    /// Everything back to how it was before `highlight(_:)`.
    public func clearHighlight() {
        highlight([])
    }

    /// The node under a point on the ring, if any: an angle in radians clockwise from 12 o'clock, and a distance from the
    /// middle as a share of the ring's radius.
    public func node(at point: Polar) -> UInt32? {
        engine.layout.hit(angle: point.angle, radius: point.radius).map { engine.layout.pieces[$0].node }
    }

    /// Draws the picture again, as after the tree changed in place.
    public func redraw() {
        redraw(.settle)
    }

    /// The ring as it is now, settled, in an image of `width` by `height` pixels. Names aren't in it. Nil without a GPU.
    public func picture(width: Int, height: Int, scale: CGFloat = 2) -> CGImage? {
        engine.picture(width: width, height: height, scale: scale)
    }

    /// What's on the ring, in words: the node in the middle, and the biggest pieces with their names, sizes, shares and where
    /// they are. `limit` is the most pieces it lists.
    public func summary(limit: Int = 60) -> SunburstSummary {
        let layout = engine.layout
        let whole = tree.size(of: focus)
        let order = layout.pieces.indices.sorted { layout.pieces[$0].size > layout.pieces[$1].size }
        let items = order.prefix(max(limit, 0)).map { at -> SunburstSummary.Piece in
            let p = layout.pieces[at]
            return SunburstSummary.Piece(node: p.node, name: pieceName(p), size: p.size, sizeText: sizeText(p.size),
                                         share: Double(p.size) / Double(max(whole, 1)), ring: Int(p.ring),
                                         inside: p.parent >= 0 ? layout.pieces[Int(p.parent)].node : focus,
                                         from: Double(p.a0) * 180 / .pi, to: Double(p.a1) * 180 / .pi,
                                         isGathered: p.isSmaller, isMarked: p.marked > 0)
        }
        return SunburstSummary(focus: focus, name: name(focus), size: whole, sizeText: sizeText(whole), rings: layout.rings,
                               hovered: hovered, pieces: Array(items), more: max(layout.pieces.count - items.count, 0))
    }

    // MARK: Pictures

    func makeLayout() -> RingLayout {
        let colorer = colours?(tree, focus) ?? BranchColours(tree: tree, focus: focus).colorer
        let marked = self.marked
        var layout = RingLayout.build(tree: tree, focus: focus, colorer: colorer, marked: marked.isEmpty ? nil : { marked.contains($0) },
                                      sizes: sizes)
        layout.calmTinyPieces(total: tree.size(of: focus))
        return layout
    }

    func redraw(_ transition: RingTransition) {
        show(makeLayout(), transition)
    }

    private func show(_ layout: RingLayout, _ transition: RingTransition) {
        engine.apply(layout, transition)
        version += 1
        hoveredPiece = nil
        hovered = nil
        placeLabels()
        updateReadout()
        if lit != nil { applyLight() }
        view?.voiceOverLayoutChanged()
    }

    // MARK: Pointer

    func pointerMoved(to point: Polar?) {
        hover(piece: point.flatMap { engine.layout.hit(angle: $0.angle, radius: $0.radius) })
    }

    func hover(piece index: Int?) {
        guard index != hoveredPiece else { return }
        hoveredPiece = index
        let layout = engine.layout
        guard let index, index < layout.pieces.count else {
            hovered = nil
            light = LabelLight()
            if lit != nil { applyLight() } else { engine.setEmphasis(primary: nil, related: []) }
            updateReadout()
            return
        }
        let p = layout.pieces[index]
        var ancestors: [Int] = []
        var up = p.parent
        while up >= 0 {
            ancestors.append(Int(up))
            up = layout.pieces[Int(up)].parent
        }
        engine.setEmphasis(primary: index, related: [index..<max(Int(p.end), index + 1)], ancestors: ancestors)
        hovered = p.node
        light = LabelLight(hovering: p.node, named: Set(labels.map(\.node)))
        updateReadout()
    }

    func click(at point: Polar?, count: Int) {
        guard let point else { return }
        if point.radius < RingLayout.hole {
            zoomOut()
        } else if let index = engine.layout.hit(angle: point.angle, radius: point.radius) {
            click(piece: index)
        }
    }

    func click(piece index: Int) {
        guard index < engine.layout.pieces.count else { return }
        let p = engine.layout.pieces[index]
        // "Smaller items" stand for what holds them, which is already in view.
        if p.isSmaller { return }
        zoom(into: p.tail)
    }

    func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53, 51:                     // escape, delete: back out
            guard focus != 0 else { return false }
            zoomOut()
            return true
        default:
            return false
        }
    }

    private func applyLight() {
        let layout = engine.layout
        guard let lit else {
            engine.setEmphasis(primary: nil, related: [])
            return
        }
        var full: [Range<Int>] = []
        var holding = Set<Int>()
        for node in lit.nodes {
            guard let at = layout.nearestPiece(to: node, tree: tree) else { continue }
            let p = layout.pieces[at]
            if p.node == node || p.tail == node {
                full.append(at..<max(Int(p.end), at + 1))
            } else {
                holding.insert(at)
            }
            var up = p.parent
            while up >= 0 {
                holding.insert(Int(up))
                up = layout.pieces[Int(up)].parent
            }
        }
        engine.setEmphasis(primary: nil, related: full, ancestors: Array(holding), tint: lit.tint)
    }

    // MARK: Names and the readout

    func setPlace(center: CGPoint, radius: CGFloat, size: CGSize) {
        let changed = place.center != center || place.radius != radius || place.size != size
        place = (center, radius, size)
        if changed { placeLabels() }
    }

    private func pieceName(_ p: Piece) -> String {
        p.isSmaller ? (p.smallerCount == 1 ? "1 smaller item" : "\(p.smallerCount) smaller items") : name(p.node)
    }

    func placeLabels() {
        let layout = engine.layout
        guard place.radius > 0, !layout.pieces.isEmpty else {
            labels = []
            return
        }
        let area = LabelArea(center: place.center, radius: place.radius, width: place.size.width, height: place.size.height,
                             top: 24, bottom: place.size.height - 24)
        let order = LabelPlacer.order(layout, halvesFirst: tree.hasHalves)
        var named = LabelPlacer.Placed()
        let inside = LabelPlacer.inside(layout: layout, order: order, area: area, halves: tree.hasHalves, named: &named) { p in
            p.isSmaller ? nil : (self.name(p.node), self.sizeText(p.size))
        }
        let picks = LabelPlacer.bigPieces(layout: layout, order: order, total: tree.size(of: focus), named: &named) { p in
            (self.name(p.node), self.sizeText(p.size))
        }
        labels = inside + LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: false)
    }

    private func updateReadout() {
        let whole = tree.size(of: focus)
        if let hoveredPiece, hoveredPiece < engine.layout.pieces.count {
            let p = engine.layout.pieces[hoveredPiece]
            let share = Double(p.size) / Double(max(whole, 1))
            readout = SunburstReadout(title: pieceName(p), size: p.size, detail: Self.percent(share) + " of " + name(focus))
        } else if focus != 0 {
            // Zoomed in: what share of everything this is, and a way back out.
            let share = Double(whole) / Double(max(tree.size(of: 0), 1))
            readout = SunburstReadout(title: name(focus), size: whole, detail: Self.percent(share) + " of " + name(0), goesBack: true)
        } else {
            readout = SunburstReadout(title: name(focus), size: whole, detail: "")
        }
    }

    static func percent(_ share: Double) -> String {
        share >= 0.095 || share == 0 ? "\(Int((share * 100).rounded()))%" : String(format: "%.1f%%", share * 100)
    }

    // MARK: VoiceOver

    func connect(_ view: SunburstView) {
        self.view = view
        view.onHover = { [weak self] point in self?.pointerMoved(to: point) }
        view.onClick = { [weak self] point, count in self?.click(at: point, count: count) }
        view.onPinch = { [weak self] opening, point in
            if opening { self?.click(at: point, count: 1) } else { self?.zoomOut() }
        }
        view.onKey = { [weak self] event in self?.key(event) ?? false }
        view.accessibilityName = { [weak self] in
            guard let self else { return "Chart" }
            return "Chart of " + self.name(self.focus)
        }
        view.accessibilityPicture = { [weak self] in
            guard let self, self.place.radius > 0 else { return nil }
            return ("\(self.focus) \(self.version)", self.place.center, self.place.radius)
        }
        view.describePiece = { [weak self] piece, share in
            guard let self else { return ("", "") }
            return (self.pieceName(piece), "\(self.sizeText(piece.size)), \(Self.percent(share))")
        }
        view.onPress = { [weak self] index in self?.click(piece: index) }
    }
}

// MARK: - The view

/// A sunburst chart of a tree: the ring, names on and beside it, a readout in the middle, pointing to light a branch, a
/// click to zoom into it, and a click in the middle (or Esc) to zoom back out.
///
/// ```swift
/// Sunburst(tree, name: { tree.name(of: $0) })
/// ```
///
/// To drive it from code, keep a `SunburstChart` and show that: `Sunburst(chart)`.
public struct Sunburst<Tree: SunburstTree>: View {
    private let given: SunburstChart<Tree>?
    private let make: (@MainActor () -> SunburstChart<Tree>)?
    /// A chart made by this view, made once: SwiftUI makes a view's value again on every change around it, and a chart
    /// isn't cheap to make.
    @State private var made = MadeOnce<SunburstChart<Tree>>()

    /// A chart you keep, to drive from code.
    public init(_ chart: SunburstChart<Tree>) {
        given = chart
        make = nil
    }

    /// A chart of this tree. `name` says what each node is called; sizes are written in bytes unless `sizeText` says
    /// otherwise. The chart is made when the view first appears, from the tree it's given then. To show a tree that
    /// changes, keep a `SunburstChart` and set its `tree`.
    public init(_ tree: Tree, name: @escaping (UInt32) -> String, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes) {
        given = nil
        make = { SunburstChart(tree: tree, name: name, sizeText: sizeText) }
    }

    public var body: some View {
        let chart = given ?? made.value { make!() }
        GeometryReader { geometry in
            let size = geometry.size
            let ring = Self.ring(in: size)
            ZStack(alignment: .topLeading) {
                SunburstCanvas(chart: chart)
                RingPlace(center: ring.center, radius: ring.radius, size: size, engine: chart.engine, view: { [chart] in chart.view })
                SunburstLabels(labels: chart.labels, light: chart.light, visible: true, width: size.width,
                               onEnter: { [chart] in chart.hover(piece: $0) }, onLeave: { [chart] _ in chart.hover(piece: nil) },
                               onOpen: { [chart] piece, _ in chart.click(piece: piece) }, outer: { _ in EmptyModifier() })
                ReadoutView(readout: chart.readout, sizeText: chart.sizeText, diameter: ring.radius * CGFloat(RingLayout.hole) * 2 * 0.86)
                    .position(ring.center)
                    .allowsHitTesting(false)
            }
            .onAppear { chart.setPlace(center: ring.center, radius: ring.radius, size: size) }
            .onChange(of: size) { _, new in
                let ring = Self.ring(in: new)
                chart.setPlace(center: ring.center, radius: ring.radius, size: new)
            }
        }
        .background(Color(red: 0.02, green: 0.02, blue: 0.027))
    }

    /// Where the ring goes in a view of this size: in the middle, leaving room for names at the sides when there's width
    /// for them.
    static func ring(in size: CGSize) -> (center: CGPoint, radius: CGFloat) {
        let fits = max(min(size.width, size.height) / 2 - 30, 10)
        let besideNames = (size.width - 340) / 2
        let radius = min(fits, max(besideNames, fits * 0.78))
        return (CGPoint(x: size.width / 2, y: size.height / 2), radius)
    }
}

/// Holds something made the first time it's asked for. A class, so asking from `body` changes no state SwiftUI watches.
@MainActor
final class MadeOnce<Value> {
    private var made: Value?

    func value(_ make: () -> Value) -> Value {
        if let made { return made }
        let new = make()
        made = new
        return new
    }
}

/// The ring's own view, connected to a chart.
struct SunburstCanvas<Tree: SunburstTree>: NSViewRepresentable {
    let chart: SunburstChart<Tree>

    func makeNSView(context: Context) -> SunburstView {
        let view = SunburstView(engine: chart.engine)
        chart.connect(view)
        return view
    }

    func updateNSView(_ view: SunburstView, context: Context) {}
}

/// What the middle of the ring says: the name of what's pointed at or in view, its size, and its share.
struct SunburstReadout: Equatable {
    var title = ""
    var size: UInt64 = 0
    var detail = ""
    /// A click in the middle goes back out.
    var goesBack = false
}

/// The middle of the ring: a name above, the size large, and a line below. Each part keeps its place whatever is shown, so
/// nothing jumps as the pointer moves.
struct ReadoutView: View {
    let readout: SunburstReadout
    let sizeText: (UInt64) -> String
    let diameter: CGFloat

    var body: some View {
        let d = max(diameter, 1)
        let room = d * 0.18
        let (value, unit) = Self.split(sizeText(readout.size))
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color.clear
                HStack(spacing: d * 0.018) {
                    if readout.goesBack {
                        Image(systemName: "chevron.left")
                            .font(.system(size: d * 0.055, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(readout.title)
                        .font(.system(size: d * 0.075, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(width: d * 0.9, height: room)
            HStack(alignment: .firstTextBaseline, spacing: d * 0.016) {
                Text(value)
                    .font(.system(size: d * 0.235, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: Double(readout.size)))
                Text(unit)
                    .font(.system(size: d * 0.105, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: d * 0.9, height: d * 0.28)
            .animation(.snappy(duration: 0.32), value: readout.size)
            ZStack(alignment: .top) {
                Color.clear
                Text(readout.detail)
                    .font(.system(size: d * 0.058, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: d * 0.9, height: room)
        }
        .frame(width: d, height: d)
        .multilineTextAlignment(.center)
    }

    /// "4.2 GB" as "4.2" and "GB". Text without a unit at its end stays whole.
    static func split(_ text: String) -> (String, String) {
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        let unit = text[text.index(after: space)...]
        guard !unit.isEmpty, !unit.contains(where: \.isNumber) else { return (text, "") }
        return (String(text[..<space]), String(unit))
    }
}

/// What's on a chart's ring, in words: for an app's own logic, a test, or an agent.
public struct SunburstSummary: Codable, Sendable, Equatable {
    /// One piece of the ring.
    public struct Piece: Codable, Sendable, Equatable {
        public var node: UInt32
        public var name: String
        public var size: UInt64
        public var sizeText: String
        /// Its share of the node in the middle, from 0 to 1.
        public var share: Double
        /// Which ring, from 0 in the middle.
        public var ring: Int
        /// The node it sits in.
        public var inside: UInt32
        /// Where it starts and ends, in degrees clockwise from 12 o'clock.
        public var from: Double
        public var to: Double
        /// Whether it gathers what's too small to draw alone.
        public var isGathered: Bool
        public var isMarked: Bool
    }

    /// The node in the middle, its name and size.
    public var focus: UInt32
    public var name: String
    public var size: UInt64
    public var sizeText: String
    /// How many rings are drawn.
    public var rings: Int
    /// The node under the pointer, if any.
    public var hovered: UInt32?
    /// The biggest pieces, biggest first.
    public var pieces: [Piece]
    /// How many smaller pieces aren't listed.
    public var more: Int
}
