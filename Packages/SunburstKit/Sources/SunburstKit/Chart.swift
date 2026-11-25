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
/// (`onClick`), how pointing at something lights the ring (`lighting`), what it hears about the pointer (`onPoint`), what's
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
    @ObservationIgnored private var quietTree: Tree
    /// The node in the middle: 0, the root, until something is zoomed into.
    public private(set) var focus: UInt32 = 0
    /// The node under the pointer, or otherwise lit as if it were, if any.
    public internal(set) var hovered: UInt32?
    /// The piece that's lit as pointed at, if any: an index into the picture's pieces. Apps hear it in `onPoint`.
    var hoveredPiece: Int?
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
    /// palette, with everything inside it close to that colour (`BranchColours`).
    @ObservationIgnored public var colours: ((_ tree: Tree, _ focus: UInt32) -> RingLayout.Colorer)? {
        didSet { if !batching { redraw(.recolor) } }
    }
    /// The colours branches take while `colours` is nil, and that a colorer of your own can use too: `.spectrum` by default.
    @ObservationIgnored public var palette: SunburstPalette = .spectrum {
        didSet { if palette != oldValue, !batching { redraw(.recolor) } }
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
        didSet { engine.setGlow(showsGlow ? glow : 0) }
    }
    /// Whether pieces glow at all. Off, no halo is drawn and the work of drawing one is skipped. On by default.
    @ObservationIgnored public var showsGlow = true {
        didSet { if showsGlow != oldValue { engine.setGlow(showsGlow ? glow : 0) } }
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
    /// Whether a name that doesn't fit is written by what tells it apart from its neighbours (`ShortNames`): "S01E03" for
    /// one of a season's episodes, rather than the show's name cut short. On by default.
    @ObservationIgnored public var shortensNames = true {
        didSet { if shortensNames != oldValue { namesChanged() } }
    }
    /// Whether a name at the side says its share of what's in the middle after its size: "45.2 GB · 9%". Off by default:
    /// the piece's angle already shows its share, and a second number beside every name is more to read.
    @ObservationIgnored public var showsShares = false {
        didSet { if showsShares != oldValue { namesChanged() } }
    }
    /// The ways the names were written when they were last placed.
    @ObservationIgnored var shortNames = ShortNames()

    /// The ways a piece's name can be written, longest first, as the names around the ring were last placed: for a readout
    /// of your own that has less room than the whole name. Just `full` for a piece that isn't among them.
    public func nameForms(ofPiece index: Int, full: String) -> [String] { shortNames.forms(of: index, full: full) }
    /// Whether names are shown around the ring. On by default; off while the ring shows something passing, say.
    public var showsLabels = true {
        didSet { if showsLabels != oldValue { placeLabels(after: showsLabels ? 0.3 : 0) } }
    }
    /// Room kept clear above and below the ring for what's drawn there, so no name goes under it. 24 points each by default.
    @ObservationIgnored public var labelInsets = EdgeInsets(top: 24, leading: 0, bottom: 24, trailing: 0) {
        didSet { namesChanged() }
    }

    // MARK: Hooks

    /// How pointing at a node lights the ring, beyond the node and what's inside it (`SunburstLighting`): what else lights
    /// with it, such as every copy of it, and a colour for what's lit or for some of it, such as what's backed up. Nil, or
    /// nil for a node, for nothing more.
    @ObservationIgnored public var lighting: ((UInt32) -> SunburstLighting?)?
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
    public internal(set) var labels: [SunburstLabel] = [] {
        didSet {
            namedNodes = Set(labels.map(\.node))
            labelLights.keep(namedNodes)
            // New names, lit by what's pointed at as the old ones were.
            if hovered != nil { labelLight = labelLightNow() }
        }
    }
    /// Names wait while the pieces fly to their places after a zoom or a first picture, then fade in.
    public internal(set) var labelsVisible = true
    /// Where the ring was when the names were placed: they follow it from there as it moves (`SunburstChartLabels`).
    @ObservationIgnored public internal(set) var labelsPlacedFor = RingPlacement()
    /// Which names light up with what's pointed at.
    public internal(set) var labelLight = LabelLight() {
        didSet { labelLights.show(labelLight) }
    }
    /// The same, name by name: what `SunburstChartLabels` reads, so that the pointer moving redraws only the names whose
    /// light changes.
    @ObservationIgnored public let labelLights = LabelLights()

    // The chart's own state. It's read and changed by the parts of the chart in its other files (`Chart+Pointer`,
    // `Chart+Names`, `Chart+View`), and by nothing else.

    /// Where the ring is to rest in its view, and the view's size (`place(center:radius:size:)`): where the names are laid
    /// out. Where it's drawn now is `ringNow`.
    @ObservationIgnored var place = (center: CGPoint.zero, radius: CGFloat(0), size: CGSize.zero)
    @ObservationIgnored weak var view: SunburstView?
    /// Counts the pictures, so what's worked out for one isn't used for the next.
    @ObservationIgnored var version = 0
    @ObservationIgnored var batching = false
    @ObservationIgnored var pendingMove: (node: UInt32, move: SunburstMove)?

    /// Who points at the ring: the pointer, a name or the app, or a node held.
    @ObservationIgnored var attention = RingAttention()
    /// What's lit for the piece pointed at, so the names of what's lit light with it.
    @ObservationIgnored var pointedEmphasis: RingEmphasis?
    /// The piece `onPoint` last said, by its key, so it speaks only when that changes.
    @ObservationIgnored var lastPointed: UInt64??
    /// Light from outside the ring, shown while nothing is pointed at.
    @ObservationIgnored var highlight: Highlight?
    /// What the highlight lights in the picture on screen, worked out once for each picture.
    @ObservationIgnored var highlightShown: (version: Int, emphasis: RingEmphasis)?
    @ObservationIgnored var hoverTask: Task<Void, Never>?

    /// The nodes that have a name, so a name lights with its piece.
    @ObservationIgnored var namedNodes: Set<UInt32> = []
    /// Counts changes to how names and sizes are written, so the centre is read again after one.
    var textVersion = 0
    @ObservationIgnored var labelTask: Task<Void, Never>?
    /// Waits to let the names go after the pointer left what lit them.
    @ObservationIgnored var namesTask: Task<Void, Never>?

    /// Light from outside the ring: pointing from somewhere else, such as a row in a list. Worked out again as the numbers
    /// change.
    enum Highlight {
        case nodes([UInt32], primary: UInt32?, tint: SIMD3<Float>?, gathered: RingLayout.GatheredLight)
        case workedOut((RingLayout) -> RingLight, tint: SIMD3<Float>?)
    }

    /// `name` says what each node is called. `sizeText` writes a size: by default in bytes, as `SunburstFormat.bytes`.
    /// `valueText`, if given, is written for a node in place of its size. `parts` are the chart's parts. The first picture
    /// unfurls at once, unless `appears` is false: then nothing is drawn until the app, having set its hooks, asks
    /// (`change(_:_:)`, `redraw(_:)`).
    public init(
        tree: Tree, name: @escaping (UInt32) -> String, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
        valueText: ((UInt32) -> String)? = nil, parts: SunburstParts = SunburstParts(), engine: SunburstEngine = SunburstEngine(),
        appears: Bool = true
    ) {
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
    public func picture(width: Int, height: Int, scale: CGFloat = 2, dithered: Bool = true, inPlace: Bool = false) -> CGImage? {
        engine.picture(width: width, height: height, scale: scale, dithered: dithered, inPlace: inPlace)
    }

    /// What's on the ring, in words: the node in the middle, and the biggest pieces with their names, sizes, shares and where
    /// they are. `limit` is the most pieces it lists.
    public func summary(limit: Int = 60) -> SunburstSummary {
        let layout = engine.layout
        let whole = tree.size(of: focus)
        let order = layout.pieces.indices.sorted { layout.pieces[$0].size > layout.pieces[$1].size }
        let items = order.prefix(max(limit, 0)).map { at -> SunburstSummary.Piece in
            let p = layout.pieces[at]
            return SunburstSummary.Piece(
                node: p.node, name: pieceName(p), size: p.size, sizeText: amountText(p),
                share: Double(p.size) / Double(max(whole, 1)), ring: Int(p.ring),
                inside: p.parent >= 0 ? layout.pieces[Int(p.parent)].tail : focus,
                from: Double(p.a0) * 180 / .pi, to: Double(p.a1) * 180 / .pi,
                isGathered: p.isSmaller, isMarked: p.marked > 0)
        }
        return SunburstSummary(
            focus: focus, name: name(focus), size: whole, sizeText: amountText(focus), rings: layout.rings,
            hovered: hovered, pieces: items, more: max(layout.pieces.count - items.count, 0))
    }

    // MARK: Pictures

    /// The picture the chart would draw now, made without drawing it: to time it, or for a test.
    @_spi(Diagnostics) public func makeLayout() -> RingLayout {
        let colorer = colours?(tree, focus) ?? BranchColours(tree: tree, focus: focus, palette: palette).colorer
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
            redraw(.zoomIn(piece.map(ZoomMapping.init)))
        case .outFrom(let old):
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
        pointedEmphasis = nil
        labelLight = LabelLight()
        if transition.travels {
            // Names and what's under the pointer wait until the pieces are nearly where they're going. Until then nothing is.
            let settled = transition.settlesIn
            placeLabels(after: settled)
            tellPointed(nil)
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(settled + 0.08))
                guard let self, !Task.isCancelled else { return }
                self.rehover()
            }
        } else {
            placeLabels(after: transition.isLive || transition.isInstant ? 0 : 0.18)
            rehover()
        }
        if hoveredPiece == nil, highlight != nil { showHighlight() }
        // New numbers many times a second would keep VoiceOver starting over.
        if !transition.isLive { view?.voiceOverLayoutChanged() }
    }
}

extension SunburstChart {
    /// A chart of an `ItemTree`, each piece named from its item: from the tree on the ring, so a tree shown later with
    /// `show(_:)` names its own pieces.
    public convenience init<Item>(
        tree: ItemTree<Item>, sizeText: @escaping (UInt64) -> String = SunburstFormat.bytes,
        valueText: ((UInt32) -> String)? = nil, parts: SunburstParts = SunburstParts(),
        engine: SunburstEngine = SunburstEngine()
    ) where Tree == ItemTree<Item> {
        self.init(tree: tree, name: { tree.name(of: $0) }, sizeText: sizeText, valueText: valueText, parts: parts, engine: engine)
        name = { [unowned self] node in self.quietTree.name(of: node) }
    }
}
