import AppKit

/// A chart in a view: where the ring is, and what the pointer, clicks and keys there do.
@MainActor
extension SunburstChart {
    /// The node under a point on the ring, if any: an angle in radians clockwise from 12 o'clock, and a distance from the
    /// middle as a share of the ring's radius.
    public func node(at point: Polar) -> UInt32? {
        engine.layout.hit(angle: point.angle, radius: point.radius).map { engine.layout.pieces[$0].node }
    }

    /// Where the ring is on screen now, in the chart view's coordinates: as it's drawn, so while the view glides to a new
    /// size the pointer still finds the piece it's over. Before anything is drawn, where the chart was told the ring goes.
    /// A radius of 0 before the chart has been placed.
    private var ringNow: (center: CGPoint, radius: CGFloat) {
        let drawn = engine.place
        return drawn.radius > 0 ? drawn : (place.center, place.radius)
    }

    /// A point in the chart view's coordinates, in polar form: its angle clockwise from 12 o'clock, and its distance from the
    /// middle as a share of the ring's radius. Nil before the chart has been placed.
    public func polar(of point: CGPoint) -> Polar? {
        let ring = ringNow
        guard ring.radius > 0 else { return nil }
        return polarPoint(dx: Float(point.x - ring.center.x), dy: Float(point.y - ring.center.y), radius: Float(ring.radius))
    }

    /// Where a node's piece is on screen, in the chart view's coordinates: its middle. For something too small to have a
    /// piece, the piece that holds it. Nil before the chart has been placed, or for a node out of view.
    public func location(of node: UInt32) -> CGPoint? {
        let ring = ringNow
        guard ring.radius > 0, let at = engine.layout.nearestPiece(to: node, tree: tree) else { return nil }
        let p = engine.layout.pieces[at]
        let angle = CGFloat(p.midAngle), radius = CGFloat(p.r0 + p.r1) / 2 * ring.radius
        return CGPoint(x: ring.center.x + sin(angle) * radius, y: ring.center.y - cos(angle) * radius)
    }

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
            guard let self else { return nil }
            let ring = self.ringNow
            guard ring.radius > 0 else { return nil }
            return ("\(self.focus) \(self.version)", ring.center, ring.radius)
        }
        view.describePiece = { [weak self] piece, share in
            guard let self else { return ("", "") }
            if let describe = self.describe { return describe(piece, share) }
            return (self.pieceName(piece), "\(self.amountText(piece)), \(Self.percent(share))")
        }
        view.onPress = { [weak self] index in self?.click(piece: index, count: 1) }
    }

    /// Where the ring is to rest in its view, in the view's coordinates, and the view's size: on every change, so the
    /// names follow. While it moves, as when the window is resized, the names move with it, and once it rests they're
    /// placed again for where it is. The ring itself is drawn where its engine is told on each frame
    /// (`SunburstEngine.setPlace(center:radius:)`, as `RingPlace` does), and that's where the pointer finds its pieces.
    public func place(center: CGPoint, radius: CGFloat, size: CGSize) {
        func far(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) > 0.5 }
        let first = place.radius == 0
        let moved =
            far(place.center.x, center.x) || far(place.center.y, center.y) || far(place.radius, radius)
            || far(place.size.width, size.width) || far(place.size.height, size.height)
        place = (center, radius, size)
        if first { placeLabels() } else if moved { relabelWhenRested() }
    }

    /// A click on a name: it opens what it names.
    @_spi(Diagnostics) public func labelClicked(piece index: Int, count: Int) {
        guard index < engine.layout.pieces.count else { return }
        let p = engine.layout.pieces[index]
        click(SunburstClick(target: .label(SunburstPointed(p, at: index)), count: count))
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
        click(SunburstClick(target: .piece(SunburstPointed(p, at: index)), count: count))
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
        let pointed = SunburstPointed(p, at: index)
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
        case 53, 51:  // escape, delete: back out
            guard focus != 0 || onBack != nil else { return false }
            goBack()
            return true
        default:
            return false
        }
    }
}
