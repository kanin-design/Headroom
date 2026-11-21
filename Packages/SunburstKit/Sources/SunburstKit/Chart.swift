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
    /// the middle and what's pointed at, so its node numbers must mean the same things. It can be set many times a second, as
    /// while something is measured: each piece glides on from where it is. For a different tree altogether, use `show(_:)`.
    public var tree: Tree {
        didSet {
            quietTree = tree
            if !replacing { redraw(.live) }
        }
    }
    /// The same tree, read without SwiftUI watching: reading `tree` costs about a microsecond, too much for a lookup made once
    /// for each node, such as a name while an agent searches the whole tree.
    @ObservationIgnored private(set) var quietTree: Tree
    /// The node in the middle: 0, the root, until something is zoomed into.
    public private(set) var focus: UInt32 = 0
    /// The node under the pointer, if any.
    public private(set) var hovered: UInt32?
    /// Nodes drawn striped, such as what's selected.
    public var marked: Set<UInt32> = [] {
        didSet { if marked != oldValue, !replacing { redraw(.live) } }
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
    /// What's written for a node in place of its size, on its piece, in the readout and in `summary(limit:)`: for a tree
    /// whose sizes count one thing while the text should say another, such as films sized by how many there are but shown in
    /// bytes. Nil, the default, writes the size with `sizeText`. A piece that's only part of a node (a stretch, or "smaller
    /// items") still writes its own size with `sizeText`.
    @ObservationIgnored public var valueText: ((UInt32) -> String)? {
        didSet { placeLabels(); updateReadout() }
    }
    /// The colour of each piece, given the node in the middle. By default each branch in view gets its own colour from the
    /// whole spectrum, with everything inside it close to that colour (`BranchColours`).
    @ObservationIgnored public var colours: ((_ tree: Tree, _ focus: UInt32) -> RingLayout.Colorer)? {
        didSet { redraw(.live) }
    }
    /// A click on a piece that has nothing inside to zoom into, such as a file.
    @ObservationIgnored public var onOpen: ((UInt32) -> Void)?
    /// The node in the middle changed.
    @ObservationIgnored public var onFocus: ((UInt32) -> Void)?
    /// A key pressed while the chart has the keyboard (a click on it gives it the keyboard), before the chart's own keys:
    /// Escape and Delete back out. Return true when the key is handled. `hovered` says what's under the pointer.
    @ObservationIgnored public var onKey: ((NSEvent) -> Bool)?
    /// The menu for a right-click on a node, such as one with Reveal in Finder. Nil for no menu.
    @ObservationIgnored public var menu: ((UInt32) -> NSMenu?)?
    /// A ⌘-click on a node. It does nothing else.
    @ObservationIgnored public var onCommandClick: ((UInt32) -> Void)?
    /// Whether the view takes the keyboard as soon as it appears, so keys work without a click first. Off by default.
    @ObservationIgnored public var takesKeyboardFocus = false {
        didSet { view?.takesKeyboardFocus = takesKeyboardFocus }
    }
    /// For a window whose content reaches under its title bar: a press along the top or on empty background moves the window.
    /// Off by default.
    @ObservationIgnored public var movesWindow = false {
        didSet { view?.movesWindow = movesWindow }
    }

    // What the view shows. Kept here so names and the readout follow the ring.
    var labels: [SunburstLabel] = []
    /// Names wait while the pieces fly to their places after a zoom or a first picture, then fade in.
    var labelsVisible = true
    var light = LabelLight()
    var readout = SunburstReadout()
    @ObservationIgnored private(set) var place = (center: CGPoint.zero, radius: CGFloat(0), size: CGSize.zero)
    @ObservationIgnored weak var view: SunburstView?
    @ObservationIgnored private var version = 0
    @ObservationIgnored private var hoveredPiece: Int?
    @ObservationIgnored private var lit: (nodes: [UInt32], tint: SIMD3<Float>?)?
    @ObservationIgnored private var replacing = false
    /// Where the pointer last was over the ring, so what's under it can be lit again after the picture changes.
    @ObservationIgnored private var lastPointer: Polar?
    @ObservationIgnored private var zoomedAt = Date.distantPast
    @ObservationIgnored private var labelTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    /// `name` says what each node is called. `sizeText` writes a size: by default in bytes, as `SunburstFormat.bytes`.
    /// `valueText`, if given, is written for a node in place of its size.
    public init(tree: Tree, name: @escaping (UInt32) -> String, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
                valueText: ((UInt32) -> String)? = nil, engine: SunburstEngine = SunburstEngine()) {
        self.tree = tree
        quietTree = tree
        self.name = name
        self.sizeText = sizeText
        self.valueText = valueText
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

    /// Back to the root, in one move.
    public func zoomToRoot() {
        guard focus != 0 else { return }
        let old = focus
        focus = 0
        lit = nil
        let layout = makeLayout()
        let mapping = layout.nearestPiece(to: old, tree: tree).map { ZoomMapping(layout.pieces[$0]) }
        show(layout, .zoomOut(mapping))
        onFocus?(0)
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
    /// Without `dithered`, the faint noise that keeps dark gradients smooth on screen is left out: as a PNG it's about half
    /// the size, for sending somewhere rather than looking at.
    public func picture(width: Int, height: Int, scale: CGFloat = 2, dithered: Bool = true) -> CGImage? {
        engine.picture(width: width, height: height, scale: scale, dithered: dithered)
    }

    /// What's on the ring, in words: the node in the middle, and the biggest pieces with their names, sizes, shares and where
    /// they are. `limit` is the most pieces it lists.
    public func summary(limit: Int = 60) -> SunburstSummary {
        let layout = engine.layout
        let whole = tree.size(of: focus)
        let order = layout.pieces.indices.sorted { layout.pieces[$0].size > layout.pieces[$1].size }
        let items = order.prefix(max(limit, 0)).map { at -> SunburstSummary.Piece in
            let p = layout.pieces[at]
            return SunburstSummary.Piece(node: p.node, name: pieceName(p), size: p.size, sizeText: amountText(p),
                                         share: Double(p.size) / Double(max(whole, 1)), ring: Int(p.ring),
                                         inside: p.parent >= 0 ? layout.pieces[Int(p.parent)].tail : focus,
                                         from: Double(p.a0) * 180 / .pi, to: Double(p.a1) * 180 / .pi,
                                         isGathered: p.isSmaller, isMarked: p.marked > 0)
        }
        return SunburstSummary(focus: focus, name: name(focus), size: whole, sizeText: amountText(focus), rings: layout.rings,
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
        // The same index may be another piece now.
        hoveredPiece = nil
        hovered = nil
        light = LabelLight()
        let flies: Bool
        switch transition {
        case .appear, .zoomIn, .zoomOut: flies = true
        case .recolor, .live, .settle: flies = false
        }
        if flies {
            // Names and what's under the pointer wait until the pieces are nearly where they're going.
            zoomedAt = Date()
            placeLabels(after: 0.34)
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.42))
                guard let self, !Task.isCancelled else { return }
                self.rehover()
            }
        } else {
            placeLabels(after: transition.isLive ? 0 : 0.18)
            rehover()
        }
        if hoveredPiece == nil, lit != nil { applyLight() }
        updateReadout()
        // New numbers many times a second would keep VoiceOver starting over.
        if !transition.isLive { view?.voiceOverLayoutChanged() }
    }

    // MARK: Pointer

    /// Lights what's under the pointer now, in the picture as it is.
    private func rehover() {
        hover(piece: lastPointer.flatMap { engine.layout.hit(angle: $0.angle, radius: $0.radius) }, force: true)
    }

    func pointerMoved(to point: Polar?) {
        lastPointer = point
        hover(piece: point.flatMap { engine.layout.hit(angle: $0.angle, radius: $0.radius) })
    }

    /// `force` lights it again even if it was lit before, as after the picture changed under the pointer.
    func hover(piece index: Int?, force: Bool = false) {
        guard force || index != hoveredPiece else { return }
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
            ancestors.append(contentsOf: layout.stretches(around: Int(up)))
            up = layout.pieces[Int(up)].parent
        }
        engine.setEmphasis(primary: index, related: [layout.extent(of: index)], ancestors: ancestors)
        hovered = p.node
        light = LabelLight(hovering: p.node, named: Set(labels.map(\.node)))
        updateReadout()
    }

    /// A click acts once: the second click of a double-click is part of the first, and whatever is under the pointer by
    /// then (after a zoom, something else) isn't what was meant.
    func click(at point: Polar?, count: Int) {
        guard let point, count < 2 else { return }
        if point.radius < RingLayout.hole {
            zoomOut()
        } else if let index = engine.layout.hit(angle: point.angle, radius: point.radius) {
            click(piece: index)
        }
    }

    func click(piece index: Int, count: Int = 1) {
        guard count < 2, index < engine.layout.pieces.count else { return }
        let p = engine.layout.pieces[index]
        // "Smaller items" stand for what holds them, which is already in view.
        if p.isSmaller { return }
        zoom(into: p.tail)
    }

    /// Spreading two fingers over a piece zooms into it. It never opens anything, and over the middle it does nothing.
    func pinchOpen(at point: Polar?) {
        guard let point, let index = engine.layout.hit(angle: point.angle, radius: point.radius) else { return }
        let p = engine.layout.pieces[index]
        guard !p.isSmaller, tree.firstChild(of: RingLayout.chainTail(tree: tree, p.tail)) != 0 else { return }
        zoom(into: p.tail)
    }

    /// The node of the piece at a point, unless it's "smaller items".
    private func ownNode(at point: Polar) -> UInt32? {
        guard let index = engine.layout.hit(angle: point.angle, radius: point.radius), !engine.layout.pieces[index].isSmaller else {
            return nil
        }
        return engine.layout.pieces[index].node
    }

    func key(_ event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
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
            guard let at = layout.nearestPiece(to: node, tree: tree) else {
                // Gathered into the "smaller items" around the middle.
                if node != focus, let outer = layout.outerSmaller, isInside(node, focus) { full.append(outer..<outer + 1) }
                continue
            }
            let p = layout.pieces[at]
            if layout.piece(of: node) == at {
                full.append(layout.extent(of: at))
            } else if let smaller = layout.smallerPiece(in: at) {
                // Too small to draw on its own: it's in the piece's "smaller items".
                full.append(smaller..<smaller + 1)
                holding.insert(at)
            } else {
                // Deeper than the rings go: the outermost piece that holds it.
                full.append(at..<at + 1)
            }
            var up = p.parent
            while up >= 0 {
                holding.formUnion(layout.stretches(around: Int(up)))
                up = layout.pieces[Int(up)].parent
            }
        }
        engine.setEmphasis(primary: nil, related: full, ancestors: Array(holding), tint: lit.tint)
    }

    private func isInside(_ node: UInt32, _ folder: UInt32) -> Bool {
        var at = node
        while at != 0 {
            if at == folder { return true }
            at = tree.parent(of: at)
        }
        return folder == 0
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

    /// What's written for a node: its `valueText`, or its size.
    private func amountText(_ node: UInt32) -> String {
        valueText?(node) ?? sizeText(tree.size(of: node))
    }

    /// What's written for a piece: its node's `valueText` when the piece stands for all of the node, or else its own size.
    private func amountText(_ p: Piece) -> String {
        if let valueText, !p.isSmaller, p.size == tree.size(of: p.node) { return valueText(p.node) }
        return sizeText(p.size)
    }

    /// Names for the picture as it is now, after `delay` seconds; until then the old names fade away.
    private func placeLabels(after delay: Double) {
        labelTask?.cancel()
        guard delay > 0 else {
            labelsVisible = true
            placeLabels()
            return
        }
        labelsVisible = false
        labelTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.placeLabels()
            self.labelsVisible = true
        }
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
            p.isSmaller ? nil : (self.name(p.node), self.amountText(p))
        }
        let picks = LabelPlacer.bigPieces(layout: layout, order: order, named: &named) { p in
            (self.name(p.node), self.amountText(p))
        }
        labels = inside + LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: false)
    }

    private func updateReadout() {
        let whole = tree.size(of: focus)
        if let hoveredPiece, hoveredPiece < engine.layout.pieces.count {
            let p = engine.layout.pieces[hoveredPiece]
            let share = Double(p.size) / Double(max(whole, 1))
            readout = SunburstReadout(title: pieceName(p), size: p.size, text: amountText(p), detail: Self.percent(share) + " of " + name(focus))
        } else if focus != 0 {
            // Zoomed in: what share of everything this is, and a way back out.
            let share = Double(whole) / Double(max(tree.size(of: 0), 1))
            readout = SunburstReadout(title: name(focus), size: whole, text: amountText(focus), detail: Self.percent(share) + " of " + name(0),
                                      goesBack: true)
        } else {
            readout = SunburstReadout(title: name(focus), size: whole, text: amountText(focus), detail: "")
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
            if opening { self?.pinchOpen(at: point) } else { self?.zoomOut() }
        }
        view.onKey = { [weak self] event in self?.key(event) ?? false }
        view.menuAt = { [weak self] point in
            guard let self, let menu = self.menu, let node = self.ownNode(at: point) else { return nil }
            return menu(node)
        }
        view.onCommandClick = { [weak self] point in
            guard let self, let node = self.ownNode(at: point) else { return }
            self.onCommandClick?(node)
        }
        view.takesKeyboardFocus = takesKeyboardFocus
        view.movesWindow = movesWindow
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
            return (self.pieceName(piece), "\(self.amountText(piece)), \(Self.percent(share))")
        }
        view.onPress = { [weak self] index in self?.click(piece: index) }
    }
}

public extension SunburstChart {
    /// A chart of an `ItemTree`, each piece named from its item: from the tree on the ring, so a tree shown later with
    /// `show(_:)` names its own pieces.
    convenience init<Item>(tree: ItemTree<Item>, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
                           valueText: ((UInt32) -> String)? = nil, engine: SunburstEngine = SunburstEngine()) where Tree == ItemTree<Item> {
        self.init(tree: tree, name: { tree.name(of: $0) }, sizeText: sizeText, valueText: valueText, engine: engine)
        name = { [unowned self] node in self.quietTree.name(of: node) }
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
/// To drive it from code, keep a `SunburstChart` and show that: `Sunburst(chart)`. A chart is shown in one view at a time,
/// so give each window its own chart.
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
    /// otherwise, and `valueText`, if given, is written for a node in place of its size. The chart is made when the view
    /// first appears, from the tree it's given then. To show a tree that changes, keep a `SunburstChart` and set its `tree`.
    public init(_ tree: Tree, name: @escaping (UInt32) -> String, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
                valueText: ((UInt32) -> String)? = nil) {
        given = nil
        make = { SunburstChart(tree: tree, name: name, sizeText: sizeText, valueText: valueText) }
    }

    /// A chart of an `ItemTree`, each piece named from its item.
    public init<Item>(_ tree: ItemTree<Item>, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
                      valueText: ((UInt32) -> String)? = nil) where Tree == ItemTree<Item> {
        given = nil
        make = { SunburstChart(tree: tree, sizeText: sizeText, valueText: valueText) }
    }

    public var body: some View {
        let chart = given ?? made.value { make!() }
        GeometryReader { geometry in
            let size = geometry.size
            let ring = Self.ring(in: size)
            ZStack(alignment: .topLeading) {
                SunburstCanvas(chart: chart)
                RingPlace(center: ring.center, radius: ring.radius, size: size, engine: chart.engine, view: { [chart] in chart.view })
                SunburstLabels(labels: chart.labels, light: chart.light, visible: chart.labelsVisible, width: size.width,
                               onEnter: { [chart] in chart.hover(piece: $0) }, onLeave: { [chart] _ in chart.hover(piece: nil) },
                               onOpen: { [chart] piece, clicks in chart.click(piece: piece, count: clicks) },
                               outer: { _ in EmptyModifier() })
                    .animation(.easeOut(duration: chart.labelsVisible ? 0.28 : 0.1), value: chart.labelsVisible)
                ReadoutView(readout: chart.readout, diameter: ring.radius * CGFloat(RingLayout.hole) * 2 * 0.86)
                    .position(ring.center)
                    .allowsHitTesting(false)
            }
            // A different chart is a different view: the ring's own view draws one engine for its whole life.
            .id(ObjectIdentifier(chart))
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
    /// The size, for the direction the number rolls in as it changes.
    var size: UInt64 = 0
    /// What's written for it: a number, then a space and a unit, such as "4.20 GB".
    var text = ""
    var detail = ""
    /// A click in the middle goes back out.
    var goesBack = false
}

/// The middle of the ring: a name above, the size large, and a line below. Each part keeps its place whatever is shown, so
/// nothing jumps as the pointer moves.
struct ReadoutView: View {
    let readout: SunburstReadout
    let diameter: CGFloat

    var body: some View {
        let d = max(diameter, 1)
        let room = d * 0.18
        let (value, unit) = Self.split(readout.text)
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
        /// The node it stands for, as the other calls take it.
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
        /// Whether it's drawn striped: one of `SunburstChart.marked`.
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
