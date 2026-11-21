import AppKit
import Observation
import SwiftUI

/// A sunburst with everything wired up: the ring, the names on and beside it, the centre, pointing, zooming and
/// VoiceOver. Show it with `Sunburst(chart)`, or in a view of your own with `attach(to:)`, `place(center:radius:size:)` and
/// `SunburstChartLabels`.
///
/// Everything a person can do with the pointer can be done from code too: `zoom(into:)`, `zoomOut()`, `highlight(_:)`,
/// `node(at:)`, `summary(limit:)` for what's on the ring in words, and `picture(width:height:)` for an image of it. That's
/// what an app's own logic, or an agent, drives it with.
///
/// The chart does what every ring does the same way: it makes the pictures, follows the pointer, lights things, moves
/// between pictures and places the names. What an app does its own way, it says through hooks: what a click means
/// (`onClick`), what else lights with what's pointed at (`alsoLight`), what it hears about the pointer (`onPoint`), what's
/// named (`namer`), what's striped (`isMarked`), and the centre (a slot of `Sunburst`).
@MainActor
@Observable
public final class SunburstChart<Tree: SunburstTree> {
    /// Holds the picture and everything that moves.
    public let engine: SunburstEngine

    // MARK: What's drawn

    /// The tree on the ring. Setting it again, as after sizes changed, moves every piece to its new place and keeps what's in
    /// the middle and what's pointed at, so its node numbers must mean the same things. It can be set many times a second, as
    /// while something is measured: each piece glides on from where it is. For a different tree altogether, use `show(_:)`.
    public var tree: Tree {
        didSet {
            quietTree = tree
            if !batching { redraw(.live) }
        }
    }
    /// The same tree, read without SwiftUI watching: reading `tree` costs about a microsecond, too much for a lookup made once
    /// for each node, such as a name while an agent searches the whole tree.
    @ObservationIgnored private(set) var quietTree: Tree
    /// The node in the middle: 0, the root, until something is zoomed into.
    public private(set) var focus: UInt32 = 0
    /// The node under the pointer, or otherwise lit as if it were, if any.
    public private(set) var hovered: UInt32?
    /// The piece that's lit as pointed at, if any: an index into the picture's pieces. Apps hear it in `onPoint`.
    private(set) var hoveredPiece: Int?
    /// Nodes drawn striped, such as what's selected.
    public var marked: Set<UInt32> = [] {
        didSet { if marked != oldValue, !batching { redraw(.live) } }
    }
    /// Whether a node is drawn striped, asked of each piece as the picture is made: for a selection too big to list, or one
    /// kept elsewhere. When it's set, `marked` isn't used.
    @ObservationIgnored public var isMarked: RingLayout.Marker? {
        didSet { if !batching { redraw(.live) } }
    }
    /// The chart's parts: a split, bands, the rings and the dial (`SunburstParts`). Setting them glides every piece to its
    /// place in the new arrangement; `setParts(_:animated:)` can do it at once.
    public var parts = SunburstParts() {
        didSet { if !batching { redraw(.settle) } }
    }
    /// How many rings, and how thick: the rings' part of `parts`.
    public var sizes: RingSizes {
        get { parts.rings.sizes }
        set { if newValue != parts.rings.sizes { parts.rings.sizes = newValue } }
    }
    /// The colour of each piece, given the node in the middle. By default each branch in view gets its own colour from the
    /// whole spectrum, with everything inside it close to that colour (`BranchColours`).
    @ObservationIgnored public var colours: ((_ tree: Tree, _ focus: UInt32) -> RingLayout.Colorer)? {
        didSet { if !batching { redraw(.recolor) } }
    }
    /// Whether pieces too small to matter step back until they're pointed at, so the big ones are easier to see. On by
    /// default.
    @ObservationIgnored public var calmsTinyPieces = true {
        didSet { if calmsTinyPieces != oldValue, !batching { redraw(.live) } }
    }
    /// How far pieces at rest hold back their colour and glow until something is pointed at, from 0 to 1 (the default).
    @ObservationIgnored public var calm: Float = 1 {
        didSet { engine.setCalm(calm) }
    }
    /// How strongly pieces glow, from 0 to 1 (the default).
    @ObservationIgnored public var glow: Float = 1 {
        didSet { engine.setGlow(glow) }
    }

    // MARK: What's written

    /// What a node is called, on the ring and to VoiceOver.
    @ObservationIgnored public var name: (UInt32) -> String {
        didSet { namesChanged() }
    }
    /// How a size is written: a number, then a space and a unit, such as "4.20 GB". The readout shows the unit smaller.
    @ObservationIgnored public var sizeText: (UInt64) -> String {
        didSet { namesChanged() }
    }
    /// What's written for a node in place of its size, on its piece, in the readout and in `summary(limit:)`: for a tree
    /// whose sizes count one thing while the text should say another, such as films sized by how many there are but shown in
    /// bytes. Nil, the default, writes the size with `sizeText`. A piece that's only part of a node (a stretch, or "smaller
    /// items") still writes its own size with `sizeText`.
    @ObservationIgnored public var valueText: ((UInt32) -> String)? {
        didSet { namesChanged() }
    }
    /// What's named, and what it says (`SunburstNamer`). Nil, the default, names each piece after its node with its size.
    @ObservationIgnored public var namer: (any SunburstNamer)? {
        didSet { namesChanged() }
    }
    /// Whether names are shown around the ring. On by default; off while the ring shows something passing, say.
    public var showsLabels = true {
        didSet { if showsLabels != oldValue { placeLabels(after: showsLabels ? 0.3 : 0) } }
    }
    /// Room kept clear above and below the ring for what's drawn there, so no name goes under it. 24 points each by default.
    @ObservationIgnored public var labelInsets = EdgeInsets(top: 24, leading: 0, bottom: 24, trailing: 0) {
        didSet { namesChanged() }
    }

    // MARK: Hooks

    /// What else lights up with a node under the pointer: the same thing on the other side of a split, or every copy of it,
    /// in a colour of their own; or, of what lights with it, what takes a colour of its own, such as what has a copy. Nil, or
    /// nil for a node, for nothing else.
    @ObservationIgnored public var alsoLight: ((UInt32) -> SunburstAlsoLit?)?
    /// What's lit moved to another piece, or off the ring (nil): as the pointer moves, or as `hold(_:)` or `point(at:)` light a
    /// node. A folder cut into stretches is heard for each stretch. Not called again for the same piece when only the picture
    /// changed under it (`refreshPointer()` asks again).
    @ObservationIgnored public var onPoint: ((SunburstPointed?) -> Void)?
    /// A click (`SunburstClick`), before the chart's own: on a piece, a zoom into it; in the middle, back out. Return true when
    /// the app has handled it.
    @ObservationIgnored public var onClick: ((SunburstClick) -> Bool)?
    /// Going back, as Escape, Delete and pinching closed ask, before the chart's own `zoomOut()`. Return true when handled.
    @ObservationIgnored public var onBack: (() -> Bool)?
    /// A click on a piece that has nothing inside to zoom into, such as a file.
    @ObservationIgnored public var onOpen: ((UInt32) -> Void)?
    /// The node in the middle changed.
    @ObservationIgnored public var onFocus: ((UInt32) -> Void)?
    /// A key pressed while the chart has the keyboard (a click on it gives it the keyboard), before the chart's own keys:
    /// Escape and Delete go back. Return true when the key is handled. `hovered` says what's under the pointer.
    @ObservationIgnored public var onKey: ((NSEvent) -> Bool)?
    /// The menu for a right-click on a node (in the middle, the node in the middle), such as one with Reveal in Finder. Nil for
    /// no menu.
    @ObservationIgnored public var menu: ((UInt32) -> NSMenu?)?
    /// A ⌘-click on a node (in the middle, the node in the middle). It does nothing else.
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

    // MARK: VoiceOver

    /// What VoiceOver calls the chart: "chart" by default, or "disk map", say.
    @ObservationIgnored public var accessibilityKind = "chart" {
        didSet { view?.accessibilityKind = accessibilityKind }
    }
    /// The chart's name to VoiceOver. By default "Chart of" and the node in the middle.
    @ObservationIgnored public var accessibilityTitle: (() -> String)?
    /// What VoiceOver says for a piece, given its share of the node in the middle. By default its name, and its size or
    /// value with the share.
    @ObservationIgnored public var describe: ((_ piece: Piece, _ share: Double) -> (label: String, value: String))?

    // MARK: What the view shows

    /// The names around the ring, as `SunburstChartLabels` shows them.
    public private(set) var labels: [SunburstLabel] = [] {
        didSet { namedNodes = Set(labels.map(\.node)) }
    }
    /// Names wait while the pieces fly to their places after a zoom or a first picture, then fade in.
    public private(set) var labelsVisible = true
    /// Which names light up with what's pointed at.
    public private(set) var labelLight = LabelLight()
    /// What the centre says now: what's pointed at, or the node in the middle. Worked out when it's read.
    public var readout: SunburstReadout {
        let whole = tree.size(of: focus)
        if let hoveredPiece, hoveredPiece < engine.layout.pieces.count {
            let p = engine.layout.pieces[hoveredPiece]
            let share = Double(p.size) / Double(max(whole, 1))
            return SunburstReadout(title: pieceName(p), size: p.size, text: amountText(p), detail: Self.percent(share) + " of " + name(focus))
        }
        if focus != 0 {
            // Zoomed in: what share of everything this is, and a way back out.
            let share = Double(whole) / Double(max(tree.size(of: 0), 1))
            return SunburstReadout(title: name(focus), size: whole, text: amountText(focus), detail: Self.percent(share) + " of " + name(0),
                                   goesBack: true)
        }
        return SunburstReadout(title: name(focus), size: whole, text: amountText(focus), detail: "")
    }

    @ObservationIgnored private(set) var place = (center: CGPoint.zero, radius: CGFloat(0), size: CGSize.zero)
    @ObservationIgnored weak var view: SunburstView?
    @ObservationIgnored private var version = 0
    @ObservationIgnored private var held: UInt32?
    @ObservationIgnored private var lit: Lit?
    /// What `lit` lights in the picture on screen, worked out once for each picture.
    @ObservationIgnored private var litLight: (version: Int, light: RingLight, primary: Int?)?
    /// The nodes that have a name, so a name lights with its piece.
    @ObservationIgnored private var namedNodes: Set<UInt32> = []
    @ObservationIgnored private var batching = false
    @ObservationIgnored private var pendingMove: (node: UInt32, move: SunburstMove)?
    /// Where the pointer last was over the ring, so what's under it can be lit again after the picture changes.
    @ObservationIgnored private var lastPointer: Polar?
    /// Whether what's lit was lit by the pointer on the ring, rather than by a name or the app.
    @ObservationIgnored private var pointerLit = true
    /// What a name or the app lit as pointed at, so it's lit again when the picture changes under it.
    @ObservationIgnored private var pointedNode: UInt32?
    /// The piece `onPoint` last said, by its key, so it speaks only when that changes.
    @ObservationIgnored private var lastPointed: UInt64??
    @ObservationIgnored private var labelTask: Task<Void, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    /// What's lit, other than what's pointed at: pointing from outside the ring. Worked out again as the numbers change.
    private enum Lit {
        case nodes([UInt32], primary: UInt32?, tint: SIMD3<Float>?, gathered: RingLayout.GatheredLight)
        case workedOut((RingLayout) -> RingLight, tint: SIMD3<Float>?)
    }

    /// `name` says what each node is called. `sizeText` writes a size: by default in bytes, as `SunburstFormat.bytes`.
    /// `valueText`, if given, is written for a node in place of its size. `parts` are the chart's parts. The first picture
    /// unfurls at once, unless `appears` is false: then nothing is drawn until the app, having set its hooks, asks
    /// (`change(_:_:)`, `redraw(_:)`).
    public init(tree: Tree, name: @escaping (UInt32) -> String, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
                valueText: ((UInt32) -> String)? = nil, parts: SunburstParts = SunburstParts(), engine: SunburstEngine = SunburstEngine(),
                appears: Bool = true) {
        self.tree = tree
        quietTree = tree
        self.parts = parts
        self.name = name
        self.sizeText = sizeText
        self.valueText = valueText
        self.engine = engine
        if appears { redraw(.appear) }
    }

    // MARK: Driving it

    /// A different tree: back to its root, with nothing marked, lit or held, unfurling as a first picture does.
    public func show(_ tree: Tree) {
        let wasAway = focus != 0
        batching = true
        self.tree = tree
        marked = []
        isMarked = nil
        batching = false
        focus = 0
        forgetPointing()
        redraw(.appear)
        if wasAway { onFocus?(0) }
    }

    /// Changes several things at once and draws one new picture, moving from the last as `transition` says: new colours and
    /// marks together, say. A move of the middle made inside (`setFocus(_:_:)`) moves as it says instead.
    public func change(_ transition: RingTransition, _ body: () -> Void) {
        let was = batching
        batching = true
        body()
        batching = was
        guard !was else { return }
        if let pending = pendingMove {
            pendingMove = nil
            move(to: pending.node, pending.move)
        } else {
            redraw(transition)
        }
    }

    /// Moves the middle to a node, as `move` says: zooming in from the piece it was, out from where it was, or as a
    /// transition says. The chart's own `zoom(into:)` and `zoomOut()` are made of this; an app with its own rules for where
    /// to go, such as a way back the way you came, uses it directly.
    public func setFocus(_ node: UInt32, _ move: SunburstMove) {
        if batching {
            focus = node
            pendingMove = (node, move)
        } else {
            self.move(to: node, move)
        }
    }

    /// New parts, every piece gliding to its place in them, or there at once without `animated`.
    public func setParts(_ parts: SunburstParts, animated: Bool = true) {
        change(animated ? .settle : .instant) { self.parts = parts }
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
        setFocus(target, .into(engine.layout.piece(of: node).map { engine.layout.pieces[$0] }))
        return true
    }

    /// One level back out, toward the root.
    public func zoomOut() {
        guard focus != 0 else { return }
        var up = tree.parent(of: focus)
        // A folder drawn as one with the one it's nearly all of would show the same picture, so it's passed over.
        while up != 0, RingLayout.chainTail(tree: tree, up) == focus { up = tree.parent(of: up) }
        setFocus(up, .outFrom(focus))
    }

    /// Back to the root, in one move.
    public func zoomToRoot() {
        guard focus != 0 else { return }
        setFocus(0, .outFrom(focus))
    }

    /// Lights these nodes, and the way out to them, and lets everything else step back; `primary`, one of them, most. In
    /// `tint`, if given, they and the way out take on one colour. What's too small to draw shows by the piece that holds it:
    /// lit in full by default (`GatheredLight.shown`), or less, as the way out (`.held`). It's pointing from somewhere else,
    /// such as a row in a list: it stays lit as the numbers change (`.live`), and goes when the pointer comes onto the ring,
    /// or the picture changes in any other way. What's pointed at is let go.
    public func highlight(_ nodes: [UInt32], primary: UInt32? = nil, tint: SIMD3<Float>? = nil, gathered: RingLayout.GatheredLight = .shown) {
        setLit(nodes.isEmpty ? nil : .nodes(nodes, primary: primary, tint: tint, gathered: gathered))
    }

    /// Lights what the app works out from the picture itself, such as every piece of one kind: `light` is asked again as the
    /// numbers change. It goes as `highlight(_:primary:tint:gathered:)` does. What's pointed at is let go.
    public func highlight(tint: SIMD3<Float>? = nil, _ light: @escaping (RingLayout) -> RingLight) {
        setLit(.workedOut(light, tint: tint))
    }

    /// Everything back to how it was before `highlight`.
    public func clearHighlight() {
        setLit(nil)
    }

    private func setLit(_ new: Lit?) {
        lit = new
        litLight = nil
        letGoOfPointed()
        applyLight()
    }

    /// Lights a node as if it were pointed at: from a row in a list, say. Nil lets go. The pointer on the ring takes over again
    /// as soon as it moves there.
    public func point(at node: UInt32?) {
        pointerLit = false
        lastPointer = nil
        pointedNode = node
        hover(piece: node.flatMap { engine.layout.nearestPiece(to: $0, tree: tree) })
    }

    /// Keeps a node lit whenever nothing else is pointed at: while a card about it is open, say. It lights at once, even with
    /// the pointer resting on another piece; the pointer lights what it's on again when it moves, and moving off brings the
    /// held node back. Nil lets go.
    public func hold(_ node: UInt32?) {
        held = node
        if node != nil {
            lastPointer = nil
            pointedNode = nil
            pointerLit = false
        }
        rehover()
    }

    /// Lights what's pointed at again, and says so to `onPoint` even if it's the same piece: after something changed that the
    /// app shows about it. Inside `change(_:_:)`, it's said with the new picture.
    public func refreshPointer() {
        lastPointed = nil
        if !batching { rehover() }
    }

    /// The node under a point on the ring, if any: an angle in radians clockwise from 12 o'clock, and a distance from the
    /// middle as a share of the ring's radius.
    public func node(at point: Polar) -> UInt32? {
        engine.layout.hit(angle: point.angle, radius: point.radius).map { engine.layout.pieces[$0].node }
    }

    /// A point in the chart view's coordinates, in polar form: its angle clockwise from 12 o'clock, and its distance from the
    /// middle as a share of the ring's radius. Nil before the chart has been placed.
    public func polar(of point: CGPoint) -> Polar? {
        guard place.radius > 0 else { return nil }
        let dx = Float(point.x - place.center.x), dy = Float(point.y - place.center.y)
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return (angle, (dx * dx + dy * dy).squareRoot() / Float(place.radius))
    }

    /// Where a node's piece is on screen, in the chart view's coordinates: its middle. For something too small to have a
    /// piece, the piece that holds it. Nil before the chart has been placed, or for a node out of view.
    public func location(of node: UInt32) -> CGPoint? {
        guard place.radius > 0, let at = engine.layout.nearestPiece(to: node, tree: tree) else { return nil }
        let p = engine.layout.pieces[at]
        let angle = CGFloat(p.midAngle), radius = CGFloat(p.r0 + p.r1) / 2 * place.radius
        return CGPoint(x: place.center.x + sin(angle) * radius, y: place.center.y - cos(angle) * radius)
    }

    /// Draws the picture again, as after the tree changed in place.
    public func redraw() {
        redraw(.settle)
    }

    /// Draws the picture again, moving from the last one as `transition` says.
    public func redraw(_ transition: RingTransition) {
        display(makeLayout(), transition)
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

    // MARK: In a view

    /// Draws in this view and takes its pointer, clicks, keys and VoiceOver. `Sunburst` does this; a view of the app's own
    /// does it once it has made a `SunburstView` for the chart's engine.
    public func attach(to view: SunburstView) {
        self.view = view
        view.polar = { [weak self] point in self?.polar(of: point) }
        view.onHover = { [weak self] point in self?.pointerMoved(to: point) }
        view.onHoverCovered = { [weak self] in self?.pointerCovered() }
        view.onClick = { [weak self] point, count in self?.click(at: point, count: count) }
        view.onPinch = { [weak self] opening, point in
            if opening { self?.pinchOpen(at: point) } else { self?.goBack() }
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
        view.accessibilityKind = accessibilityKind
        view.accessibilityName = { [weak self] in
            guard let self else { return "Chart" }
            return self.accessibilityTitle?() ?? "Chart of " + self.name(self.focus)
        }
        view.accessibilityPicture = { [weak self] in
            guard let self, self.place.radius > 0 else { return nil }
            return ("\(self.focus) \(self.version)", self.place.center, self.place.radius)
        }
        view.describePiece = { [weak self] piece, share in
            guard let self else { return ("", "") }
            if let describe = self.describe { return describe(piece, share) }
            return (self.pieceName(piece), "\(self.amountText(piece)), \(Self.percent(share))")
        }
        view.onPress = { [weak self] index in self?.click(piece: index, count: 1) }
    }

    /// Where the ring is in its view, in the view's coordinates, and the view's size: on every change, so the names follow.
    /// While it moves, as when the window is resized, the names wait until it rests.
    public func place(center: CGPoint, radius: CGFloat, size: CGSize) {
        func far(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 0.5 }
        let first = place.radius == 0
        let moved = far(place.center.x, center.x) || far(place.center.y, center.y) || far(place.radius, radius)
            || far(place.size.width, size.width) || far(place.size.height, size.height)
        place = (center, radius, size)
        if first { placeLabels() } else if moved { placeLabels(after: 0.12) }
    }

    /// The pointer is on a name: its piece lights, as on the ring.
    @_spi(Diagnostics) public func pointerOnLabel(piece index: Int) {
        pointerLit = false
        lastPointer = nil
        pointedNode = index < engine.layout.pieces.count ? engine.layout.pieces[index].node : nil
        hover(piece: index)
    }

    /// The pointer left a name. Going straight from one name to the next, the next may have lit already, and then this one
    /// isn't lit any more.
    @_spi(Diagnostics) public func pointerLeftLabel(piece index: Int) {
        guard hoveredPiece == index else { return }
        pointedNode = nil
        hover(piece: nil)
    }

    /// A click on a name: it opens what it names.
    @_spi(Diagnostics) public func labelClicked(piece index: Int, count: Int) {
        guard index < engine.layout.pieces.count else { return }
        let p = engine.layout.pieces[index]
        click(SunburstClick(target: .label(SunburstPointed(node: p.node, piece: index, isGathered: p.isSmaller)), count: count))
    }

    /// A click, as the pointer or VoiceOver makes one: the app's `onClick` first, then the chart's own.
    public func click(_ click: SunburstClick) {
        if onClick?(click) == true { return }
        guard click.count < 2 else { return }
        switch click.target {
        case .centre:
            // Spreading two fingers is never a way back.
            if !click.byPinch { goBack() }
        case .piece(let p), .label(let p):
            // "Smaller items" stand for what holds them, which is already in view.
            guard !p.isGathered, p.piece < engine.layout.pieces.count else { return }
            zoom(into: engine.layout.pieces[p.piece].tail)
        case .nothing:
            break
        }
    }

    // MARK: Pictures

    /// The picture the chart would draw now, made without drawing it: to time it, or for a test.
    @_spi(Diagnostics) public func makeLayout() -> RingLayout {
        let colorer = colours?(tree, focus) ?? BranchColours(tree: tree, focus: focus).colorer
        let marked = self.marked
        let marker = isMarked ?? (marked.isEmpty ? nil : { marked.contains($0) })
        var layout = RingLayout.build(tree: tree, focus: focus, parts: parts, colorer: colorer, marked: marker)
        if calmsTinyPieces { layout.calmTinyPieces(total: tree.size(of: focus)) }
        return layout
    }

    private func move(to node: UInt32, _ move: SunburstMove) {
        focus = node
        switch move {
        case .into(let piece):
            // What was lit was about where you were.
            lit = nil
            redraw(.zoomIn(piece.map(ZoomMapping.init)))
        case .outFrom(let old):
            lit = nil
            let layout = makeLayout()
            display(layout, .zoomOut(layout.nearestPiece(to: old, tree: tree).map { ZoomMapping(layout.pieces[$0]) }))
        case .plain(let transition):
            redraw(transition)
        }
        onFocus?(node)
    }

    private func display(_ layout: RingLayout, _ transition: RingTransition) {
        engine.apply(layout, transition)
        version += 1
        // Light from outside the ring was about the picture it was made for: it lasts only while the numbers change.
        if !transition.isLive { forgetHighlight() }
        // The same index may be another piece now.
        hoveredPiece = nil
        hovered = nil
        labelLight = LabelLight()
        let flies: Bool
        switch transition {
        case .appear, .zoomIn, .zoomOut: flies = true
        case .recolor, .live, .settle, .instant: flies = false
        }
        if flies {
            // Names and what's under the pointer wait until the pieces are nearly where they're going. Until then nothing is.
            placeLabels(after: 0.34)
            pointed(nil)
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.42))
                guard let self, !Task.isCancelled else { return }
                self.rehover()
            }
        } else {
            placeLabels(after: transition.isLive || transition.isInstant ? 0 : 0.18)
            rehover()
        }
        if hoveredPiece == nil, lit != nil { applyLight() }
        // New numbers many times a second would keep VoiceOver starting over.
        if !transition.isLive { view?.voiceOverLayoutChanged() }
    }

    // MARK: Pointer

    /// Lights again what's under the pointer, or what a name or the app lit, or what's held, in the picture as it is.
    private func rehover() {
        let piece = lastPointer.flatMap { engine.layout.hit(angle: $0.angle, radius: $0.radius) }
            ?? pointedNode.flatMap { engine.layout.nearestPiece(to: $0, tree: tree) }
        hover(piece: piece, force: true)
    }

    func pointerMoved(to point: Polar?) {
        lastPointer = point
        pointerLit = true
        pointedNode = nil
        // The pointer on the ring takes over from whatever was lit from outside it.
        let takesOver = point != nil && lit != nil
        if takesOver { forgetHighlight() }
        hover(piece: point.flatMap { engine.layout.hit(angle: $0.angle, radius: $0.radius) }, force: takesOver)
    }

    /// Something drawn over the ring has the pointer now. To the ring that's nothing, but what's there may have lit something
    /// itself, which stays.
    func pointerCovered() {
        lastPointer = nil
        if pointerLit { hover(piece: nil) }
    }

    /// The piece of the held node, if it has one in view.
    private var heldPiece: Int? { held.flatMap { engine.layout.nearestPiece(to: $0, tree: tree) } }

    /// Lights a piece as pointed at, or with none, what's held, or else what the app lit. `force` lights it again even if it
    /// was lit before, as after the picture changed under it.
    func hover(piece pointedAt: Int?, force: Bool = false) {
        let index = pointedAt ?? heldPiece
        guard force || index != hoveredPiece else { return }
        hoveredPiece = index
        let layout = engine.layout
        guard let index, index < layout.pieces.count else {
            hovered = nil
            labelLight = LabelLight()
            if lit != nil { applyLight() } else { engine.setEmphasis(primary: nil, related: []) }
            pointed(nil)
            return
        }
        let p = layout.pieces[index]
        var ancestors: [Int] = []
        var up = p.parent
        while up >= 0 {
            ancestors.append(contentsOf: layout.stretches(around: Int(up)))
            up = layout.pieces[Int(up)].parent
        }
        let whole = layout.extent(of: index)
        var related = [whole]
        var tint: SIMD3<Float>?
        var tinted: [Range<Int>]?
        if !p.isSmaller, let also = alsoLight?(p.node) {
            if !also.nodes.isEmpty {
                let more = layout.light(also.nodes, in: tree, gathered: also.gathered)
                related += more.full
                ancestors += more.holding
            }
            tint = also.tint
            // Of the piece and what's inside it, what the app says takes the colour; the rest keeps its own.
            if let tints = also.tints {
                tinted = whole.filter { !layout.pieces[$0].isSmaller && tints(layout.pieces[$0].node) }.map { $0..<$0 + 1 }
            }
        }
        engine.setEmphasis(primary: index, related: related, ancestors: ancestors, tint: tint, tinted: tinted)
        hovered = p.node
        labelLight = LabelLight(hovering: p.node, named: namedNodes)
        pointed(SunburstPointed(node: p.node, piece: index, isGathered: p.isSmaller), key: p.key)
    }

    /// Tells the app what's lit as pointed at, once for each piece: its key stays the same from one picture to the next.
    private func pointed(_ value: SunburstPointed?, key: UInt64? = nil) {
        if let last = lastPointed, last == key { return }
        lastPointed = .some(key)
        onPoint?(value)
    }

    /// Light from outside the ring goes, without a new picture.
    private func forgetHighlight() {
        lit = nil
        litLight = nil
    }

    /// Forgets what was pointed at, held and lit: for a tree whose node numbers mean other things.
    private func forgetPointing() {
        hoverTask?.cancel()
        hoverTask = nil
        pendingMove = nil
        lastPointer = nil
        pointedNode = nil
        pointerLit = true
        lastPointed = nil
        held = nil
        lit = nil
        litLight = nil
    }

    /// What's pointed at goes, for something the app lights instead.
    private func letGoOfPointed() {
        pointedNode = nil
        hoveredPiece = nil
        hovered = nil
        labelLight = LabelLight()
        pointed(nil)
    }

    /// A click acts once: the second click of a double-click is part of the first, and whatever is under the pointer by
    /// then (after a zoom, something else) isn't what was meant. An app that wants double-clicks gets them in `onClick`.
    func click(at point: Polar?, count: Int) {
        guard let point else { return }
        if point.radius < RingLayout.hole {
            click(SunburstClick(target: .centre, count: count))
        } else if let index = engine.layout.hit(angle: point.angle, radius: point.radius) {
            click(piece: index, count: count)
        } else {
            click(SunburstClick(target: .nothing, count: count))
        }
    }

    func click(piece index: Int, count: Int) {
        guard index < engine.layout.pieces.count else { return }
        let p = engine.layout.pieces[index]
        click(SunburstClick(target: .piece(SunburstPointed(node: p.node, piece: index, isGathered: p.isSmaller)), count: count))
    }

    /// Spreading two fingers over a piece is a click on it that never opens anything. Over the middle or away from the ring
    /// it's a click there for the app (`byPinch`), which the chart itself leaves alone.
    func pinchOpen(at point: Polar?) {
        guard let point else { return }
        guard point.radius >= RingLayout.hole, let index = engine.layout.hit(angle: point.angle, radius: point.radius) else {
            click(SunburstClick(target: point.radius < RingLayout.hole ? .centre : .nothing, byPinch: true))
            return
        }
        let p = engine.layout.pieces[index]
        let pointed = SunburstPointed(node: p.node, piece: index, isGathered: p.isSmaller)
        if onClick?(SunburstClick(target: .piece(pointed), count: 1, byPinch: true)) == true { return }
        guard !p.isSmaller, tree.firstChild(of: RingLayout.chainTail(tree: tree, p.tail)) != 0 else { return }
        zoom(into: p.tail)
    }

    /// Back out, the app's way if it has one.
    private func goBack() {
        if onBack?() == true { return }
        zoomOut()
    }

    /// The node at a point, unless it's "smaller items": in the middle, the node in the middle.
    private func ownNode(at point: Polar) -> UInt32? {
        if point.radius < RingLayout.hole { return focus }
        guard let index = engine.layout.hit(angle: point.angle, radius: point.radius), !engine.layout.pieces[index].isSmaller else {
            return nil
        }
        return engine.layout.pieces[index].node
    }

    func key(_ event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        switch event.keyCode {
        case 53, 51:                     // escape, delete: back out
            guard focus != 0 || onBack != nil else { return false }
            goBack()
            return true
        default:
            return false
        }
    }

    private func applyLight() {
        guard let lit else {
            engine.setEmphasis(primary: nil, related: [])
            return
        }
        let now = litNow(lit)
        let tint: SIMD3<Float>?
        switch lit {
        case .nodes(_, _, let t, _), .workedOut(_, let t): tint = t
        }
        engine.setEmphasis(primary: now.primary, related: now.light.full, ancestors: now.light.holding, tint: tint)
    }

    /// What's lit, in the picture on screen: worked out once for each picture.
    private func litNow(_ lit: Lit) -> (light: RingLight, primary: Int?) {
        if let cached = litLight, cached.version == version { return (cached.light, cached.primary) }
        let layout = engine.layout
        let now: (light: RingLight, primary: Int?)
        switch lit {
        case let .nodes(nodes, primary, _, gathered):
            let light = layout.light(tree.branches(nodes), in: tree, gathered: gathered)
            // The primary's own piece: the first it lights, as it's lit among the others.
            let own = primary.flatMap { layout.light(tree.branches([$0]), in: tree, gathered: gathered).full.first?.lowerBound }
            now = (light, own)
        case let .workedOut(work, _):
            now = (work(layout), nil)
        }
        litLight = (version, now.light, now.primary)
        return now
    }

    // MARK: Names and the centre

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

    /// What's named, or what the names say, changed in a way only the app knows: the names are placed again, at once, or
    /// after `delay` seconds while the old ones fade away.
    public func relabel(after delay: Double = 0) {
        placeLabels(after: delay)
    }

    /// Something the names are made from changed: they're placed again, unless a new picture, which places them, is coming.
    private func namesChanged() {
        if !batching { placeLabels() }
    }

    /// Names for the picture as it is now, after `delay` seconds; until then the old names fade away.
    func placeLabels(after delay: Double) {
        labelTask?.cancel()
        guard showsLabels else {
            labelsVisible = false
            return
        }
        guard delay > 0 else {
            labelsVisible = true
            placeLabels()
            return
        }
        labelsVisible = false
        labelTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.showsLabels else { return }
            self.placeLabels()
            self.labelsVisible = true
        }
    }

    /// Names for the picture as it is now, at once.
    func placeLabels() {
        let layout = engine.layout
        guard place.radius > 0, !layout.pieces.isEmpty else {
            labels = []
            return
        }
        let area = LabelArea(center: place.center, radius: place.radius, width: place.size.width, height: place.size.height,
                             top: labelInsets.top, bottom: place.size.height - labelInsets.bottom)
        let order = LabelPlacer.order(layout)
        var named = LabelPlacer.Placed()
        if let namer {
            let inside = LabelPlacer.inside(layout: layout, order: order, area: area, named: &named) { namer.inside($0) }
            let picks = namer.sides(layout, order: order, named: &named)
            labels = inside + LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: !namer.leavesOutRepeats)
            return
        }
        let inside = LabelPlacer.inside(layout: layout, order: order, area: area, named: &named) { p in
            p.isSmaller ? nil : (self.name(p.node), self.amountText(p))
        }
        let picks = LabelPlacer.bigPieces(layout: layout, order: order, named: &named) { p in
            (self.name(p.node), self.amountText(p))
        }
        labels = inside + LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: false)
    }

    static func percent(_ share: Double) -> String {
        share >= 0.095 || share == 0 ? "\(Int((share * 100).rounded()))%" : String(format: "%.1f%%", share * 100)
    }
}

public extension SunburstChart {
    /// A chart of an `ItemTree`, each piece named from its item: from the tree on the ring, so a tree shown later with
    /// `show(_:)` names its own pieces.
    convenience init<Item>(tree: ItemTree<Item>, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
                           valueText: ((UInt32) -> String)? = nil, parts: SunburstParts = SunburstParts(),
                           engine: SunburstEngine = SunburstEngine()) where Tree == ItemTree<Item> {
        self.init(tree: tree, name: { tree.name(of: $0) }, sizeText: sizeText, valueText: valueText, parts: parts, engine: engine)
        name = { [unowned self] node in self.quietTree.name(of: node) }
    }
}

/// How the middle moves to a node (`SunburstChart.setFocus(_:_:)`).
public enum SunburstMove: Sendable, Equatable {
    /// Zooming in: everything scales around the piece the node was drawn as, given from the picture before, until it fills
    /// the ring.
    case into(Piece?)
    /// Zooming out: the old picture shrinks into the piece that now holds the node that was in the middle.
    case outFrom(UInt32)
    /// As a transition says.
    case plain(RingTransition)
}

/// What's under the pointer, or otherwise lit as if it were: a node, the piece it's drawn as, and whether that's "smaller
/// items".
public struct SunburstPointed: Sendable, Equatable {
    public var node: UInt32
    public var piece: Int
    public var isGathered: Bool

    public init(node: UInt32, piece: Int, isGathered: Bool) {
        self.node = node
        self.piece = piece
        self.isGathered = isGathered
    }
}

/// A click on a chart: where, how many in a row, and whether two fingers spreading made it.
public struct SunburstClick: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// The middle of the ring.
        case centre
        /// A piece of the ring.
        case piece(SunburstPointed)
        /// A name around the ring.
        case label(SunburstPointed)
        /// The ring's view, away from any piece.
        case nothing
    }

    public var target: Target
    /// 1 for a click, 2 for the second of a double-click, and so on.
    public var count: Int
    /// Two fingers spreading over a piece: a click that shouldn't open anything.
    public var byPinch: Bool

    public init(target: Target, count: Int = 1, byPinch: Bool = false) {
        self.target = target
        self.count = count
        self.byPinch = byPinch
    }
}

/// More to light with what's pointed at (`SunburstChart.alsoLight`): the same thing elsewhere, in a colour of its own; or a
/// colour for some of what lights with it.
public struct SunburstAlsoLit: Sendable {
    /// The same thing elsewhere, lit with what's pointed at.
    public var nodes: [UInt32]
    /// How what's too small to draw shows.
    public var gathered: RingLayout.GatheredLight
    /// One colour that what lights takes on.
    public var tint: SIMD3<Float>?
    /// Of the piece pointed at and what's inside it, the nodes that take `tint`: what has a copy, say. Nil, the default:
    /// everything lit takes it.
    public var tints: (@Sendable (UInt32) -> Bool)?

    public init(_ nodes: [UInt32] = [], gathered: RingLayout.GatheredLight = .held, tint: SIMD3<Float>? = nil,
                tints: (@Sendable (UInt32) -> Bool)? = nil) {
        self.nodes = nodes
        self.gathered = gathered
        self.tint = tint
        self.tints = tints
    }
}

/// A chart's names around its ring, wired to it: pointing at one lights its piece, and a click opens it. `Sunburst` shows one;
/// a view of the app's own shows it over the ring. `outer` modifies each name at the side, such as with a menu of its own.
public struct SunburstChartLabels<Tree: SunburstTree, Outer: ViewModifier>: View {
    let chart: SunburstChart<Tree>
    let width: CGFloat
    let outer: (SunburstLabel) -> Outer

    public init(_ chart: SunburstChart<Tree>, width: CGFloat, outer: @escaping (SunburstLabel) -> Outer) {
        self.chart = chart
        self.width = width
        self.outer = outer
    }

    public var body: some View {
        SunburstLabels(labels: chart.labels, light: chart.labelLight, visible: chart.labelsVisible, width: width,
                       onEnter: { [chart] in chart.pointerOnLabel(piece: $0) }, onLeave: { [chart] in chart.pointerLeftLabel(piece: $0) },
                       onOpen: { [chart] piece, clicks in chart.labelClicked(piece: piece, count: clicks) },
                       outer: outer)
            .animation(.easeOut(duration: chart.labelsVisible ? 0.28 : 0.1), value: chart.labelsVisible)
    }
}

public extension SunburstChartLabels where Outer == EmptyModifier {
    init(_ chart: SunburstChart<Tree>, width: CGFloat) {
        self.init(chart, width: width) { _ in EmptyModifier() }
    }
}
