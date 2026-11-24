/// What lights on a chart's ring, and why. Who points is kept in `attention` (`RingAttention`): the pointer on the ring, a
/// node a name or the app points at, or a node held. Light from outside the ring, a highlight, shows whenever none of them
/// points at anything in view. Which pieces light for either is the layout's to say (`RingLayout.emphasis`); this hands
/// that to the engine, lights the names that go with it, and tells the app.
@MainActor
extension SunburstChart {
    // MARK: From the app

    /// Lights these nodes, and the way out to them, and lets everything else step back; `primary`, one of them, most. In
    /// `tint`, if given, they and the way out take on one colour. What's too small to draw shows by the piece that holds it:
    /// lit in full by default (`GatheredLight.shown`), or less, as the way out (`.held`). It's pointing from somewhere else,
    /// such as a row in a list: it stays lit as the numbers change (`.live`), and goes when the pointer comes onto the ring,
    /// or the picture changes in any other way. What's pointed at is let go.
    public func highlight(_ nodes: [UInt32], primary: UInt32? = nil, tint: SIMD3<Float>? = nil, gathered: RingLayout.GatheredLight = .shown) {
        setHighlight(nodes.isEmpty ? nil : .nodes(nodes, primary: primary, tint: tint, gathered: gathered))
    }

    /// Lights what the app works out from the picture itself, such as every piece of one kind: `light` is asked again as the
    /// numbers change. It goes as `highlight(_:primary:tint:gathered:)` does. What's pointed at is let go.
    public func highlight(tint: SIMD3<Float>? = nil, _ light: @escaping (RingLayout) -> RingLight) {
        setHighlight(.workedOut(light, tint: tint))
    }

    /// Everything back to how it was before `highlight`.
    public func clearHighlight() {
        setHighlight(nil)
    }

    /// Lights a node as if it were pointed at: from a row in a list, say. Nil lets go. The pointer on the ring takes over again
    /// as soon as it moves there.
    public func point(at node: UInt32?) {
        attention.point(at: node)
        hover(piece: attention.pointedPiece(in: engine.layout, tree: tree))
    }

    /// Keeps a node lit whenever nothing else is pointed at: while a card about it is open, say. It lights at once, even with
    /// the pointer resting on another piece; the pointer lights what it's on again when it moves, and moving off brings the
    /// held node back. Nil lets go.
    public func hold(_ node: UInt32?) {
        attention.hold(node)
        rehover()
    }

    /// Lights what's pointed at again, and says so to `onPoint` even if it's the same piece: after something changed that the
    /// app shows about it. Inside `change(_:_:)`, it's said with the new picture.
    public func refreshPointer() {
        lastPointed = nil
        if !batching { rehover() }
    }

    // MARK: From the view

    func pointerMoved(to point: Polar?) {
        attention.pointerMoved(to: point)
        // The pointer on the ring takes over from whatever was lit from outside it.
        let takesOver = point != nil && highlight != nil
        if takesOver { forgetHighlight() }
        hover(piece: attention.pointedPiece(in: engine.layout, tree: tree), force: takesOver)
    }

    /// Something drawn over the ring has the pointer now. To the ring that's nothing, but what's there may have lit something
    /// itself, which stays.
    func pointerCovered() {
        if attention.pointerCovered() { hover(piece: nil) }
    }

    /// The pointer is on a name: its piece lights, as on the ring.
    @_spi(Diagnostics) public func pointerOnLabel(piece index: Int) {
        attention.point(at: index < engine.layout.pieces.count ? engine.layout.pieces[index].node : nil)
        hover(piece: index)
    }

    /// The pointer left a name. Going straight from one name to the next, the next may have lit already, and then this one
    /// isn't lit any more.
    @_spi(Diagnostics) public func pointerLeftLabel(piece index: Int) {
        guard hoveredPiece == index else { return }
        attention.point(at: nil)
        hover(piece: nil)
    }

    // MARK: Lighting

    /// Lights again what's pointed at, or what's held, in the picture as it is: after it changed under the pointer.
    func rehover() {
        hover(piece: attention.pointedPiece(in: engine.layout, tree: tree), force: true)
    }

    /// Lights a piece as pointed at, or with none, what's held, or else the highlight. `force` lights it again even if it
    /// was lit before, as after the picture changed under it.
    func hover(piece pointedAt: Int?, force: Bool = false) {
        let layout = engine.layout
        let index = pointedAt ?? attention.heldPiece(in: layout, tree: tree)
        guard force || index != hoveredPiece else { return }
        hoveredPiece = index
        guard let index, index < layout.pieces.count else {
            hovered = nil
            pointedEmphasis = nil
            letNamesGo()
            showHighlight()
            tellPointed(nil)
            return
        }
        namesTask?.cancel()
        let p = layout.pieces[index]
        // "Smaller items" stand for many things: the app isn't asked what goes with them.
        let emphasis = layout.emphasis(pointingAt: index, in: tree, lighting: p.isSmaller ? nil : lighting?(p.node))
        engine.setEmphasis(emphasis)
        hovered = p.node
        pointedEmphasis = emphasis
        labelLight = labelLightNow()
        tellPointed(SunburstPointed(p, at: index), key: p.key)
    }

    /// Which names light: the pointed-at piece's, and those of the pieces lit with it.
    func labelLightNow() -> LabelLight {
        guard let lit = pointedEmphasis?.light else { return LabelLight(hovering: hovered, named: namedNodes) }
        // Not the way out to it: the name of the folder it's in, lit, reads as the name of what's pointed at, and is often
        // the biggest name on the ring.
        let names = labels.filter { label in lit.full.contains { $0.contains(label.pieceIndex) } }
        return LabelLight(hovering: hovered, named: namedNodes, lit: Set(names.map(\.node)))
    }

    /// The names come back a moment after the pointer leaves what it lit, not at once: crossing an empty stretch of the ring
    /// would otherwise fade every name up and back down again.
    private func letNamesGo() {
        namesTask?.cancel()
        guard labelLight != LabelLight() else { return }
        namesTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled, self.hovered == nil else { return }
            self.labelLight = LabelLight()
        }
    }

    /// Tells the app what's lit as pointed at, once for each piece: its key stays the same from one picture to the next.
    func tellPointed(_ value: SunburstPointed?, key: UInt64? = nil) {
        if let last = lastPointed, last == key { return }
        lastPointed = .some(key)
        onPoint?(value)
    }

    // MARK: Light from outside the ring

    private func setHighlight(_ new: Highlight?) {
        highlight = new
        highlightShown = nil
        // What's pointed at goes, for what the app lights instead.
        attention.letGoOfPointed()
        hoveredPiece = nil
        hovered = nil
        pointedEmphasis = nil
        labelLight = LabelLight()
        tellPointed(nil)
        showHighlight()
    }

    /// The highlight goes, without a new picture.
    func forgetHighlight() {
        highlight = nil
        highlightShown = nil
    }

    /// Shows the highlight, or with none, nothing lit. What it lights is worked out once for each picture.
    func showHighlight() {
        guard let highlight else {
            engine.setEmphasis(nil)
            return
        }
        if highlightShown?.version != version {
            let layout = engine.layout
            let emphasis: RingEmphasis
            switch highlight {
            case .nodes(let nodes, let primary, let tint, let gathered):
                emphasis = layout.emphasis(lighting: nodes, primary: primary, in: tree, gathered: gathered, tint: tint)
            case .workedOut(let light, let tint):
                emphasis = RingEmphasis(light: light(layout), tint: tint)
            }
            highlightShown = (version, emphasis)
        }
        engine.setEmphasis(highlightShown?.emphasis)
    }

    /// Forgets who pointed, what was held and what was lit: for a tree whose node numbers mean other things.
    func forgetPointing() {
        hoverTask?.cancel()
        hoverTask = nil
        pendingMove = nil
        attention = RingAttention()
        lastPointed = nil
        pointedEmphasis = nil
        namesTask?.cancel()
        forgetHighlight()
    }
}
