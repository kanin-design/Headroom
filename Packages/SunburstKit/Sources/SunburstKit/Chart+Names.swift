import SwiftUI

/// What a chart writes: the names around its ring, and what its centre says.
@MainActor
extension SunburstChart {
    /// What the centre says now: what's pointed at, or the node in the middle. Worked out when it's read.
    public var readout: SunburstReadout {
        // What it says also changes with how names and sizes are written.
        _ = textVersion
        let whole = tree.size(of: focus)
        if let hoveredPiece, hoveredPiece < engine.layout.pieces.count {
            let p = engine.layout.pieces[hoveredPiece]
            let share = Double(p.size) / Double(max(whole, 1))
            return SunburstReadout(title: pieceName(p), size: p.size, text: amountText(p), detail: Self.percent(share) + " of " + name(focus))
        }
        if focus != 0 {
            // Zoomed in: what share of everything this is, and a way back out.
            let share = Double(whole) / Double(max(tree.size(of: 0), 1))
            return SunburstReadout(
                title: name(focus), size: whole, text: amountText(focus), detail: Self.percent(share) + " of " + name(0),
                goesBack: true)
        }
        return SunburstReadout(title: name(focus), size: whole, text: amountText(focus), detail: "")
    }

    func pieceName(_ p: Piece) -> String {
        p.isSmaller ? (p.smallerCount == 1 ? "1 smaller item" : "\(p.smallerCount) smaller items") : name(p.node)
    }

    /// What's written for a node: its `valueText`, or its size.
    func amountText(_ node: UInt32) -> String {
        valueText?(node) ?? sizeText(tree.size(of: node))
    }

    /// What's written for a piece: its node's `valueText` when the piece stands for all of the node, or else its own size.
    func amountText(_ p: Piece) -> String {
        if let valueText, !p.isSmaller, p.size == tree.size(of: p.node) { return valueText(p.node) }
        return sizeText(p.size)
    }

    /// What's named, or what the names say, changed in a way only the app knows: the names are placed again, at once, or
    /// after `delay` seconds while the old ones fade away.
    public func relabel(after delay: Double = 0) {
        placeLabels(after: delay)
    }

    /// Something the names are made from changed: they're placed again, unless a new picture, which places them, is coming.
    func namesChanged() {
        textVersion &+= 1
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

    /// The ring moved, as when the window is resized. The names follow it as it goes (`SunburstChartLabels`), and once it
    /// has rested a moment they're placed again for where it is, gliding there.
    func relabelWhenRested() {
        // Names waiting for a new picture are placed when it's ready, for where the ring is then.
        guard showsLabels, labelsVisible else { return }
        labelTask?.cancel()
        labelTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.15))
            guard let self, !Task.isCancelled, self.showsLabels else { return }
            withAnimation(.smooth(duration: 0.25)) { self.placeLabels() }
        }
    }

    /// Names for the picture as it is now, at once.
    func placeLabels() {
        let layout = engine.layout
        labelsPlacedFor = RingPlacement(center: place.center, radius: place.radius)
        guard place.radius > 0, !layout.pieces.isEmpty else {
            labels = []
            return
        }
        let area = LabelArea(
            center: place.center, radius: place.radius, width: place.size.width, height: place.size.height,
            top: labelInsets.top, bottom: place.size.height - labelInsets.bottom)
        let order = LabelPlacer.order(layout)
        // Names side by side can be written by what tells them apart, where the whole name doesn't fit.
        let short =
            shortensNames
            ? ShortNames(layout: layout, pieces: order.prefix(260), context: contextNames()) { i in
                self.name(layout.pieces[i].node)
            } : ShortNames()
        shortNames = short
        var named = LabelPlacer.Placed()
        if let namer {
            let inside = LabelPlacer.inside(layout: layout, order: order, area: area, named: &named, short: short) { namer.inside($0) }
            let picks = withShares(namer.sides(layout, order: order, named: &named), in: layout)
            labels = inside + LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: !namer.leavesOutRepeats, short: short)
            return
        }
        let inside = LabelPlacer.inside(layout: layout, order: order, area: area, named: &named, short: short) { p in
            p.isSmaller ? nil : (self.name(p.node), self.amountText(p))
        }
        let picks = LabelPlacer.bigPieces(layout: layout, order: order, named: &named) { p in
            (self.name(p.node), self.amountText(p))
        }
        labels = inside + LabelPlacer.sides(withShares(picks, in: layout), layout: layout, area: area, eachCounts: false, short: short)
    }

    /// The names of the node in the middle and of what it's in, which the names inside needn't say again.
    private func contextNames() -> [String] {
        var names: [String] = []
        var at = focus
        for _ in 0..<64 {
            names.append(name(at))
            if at == 0 { break }
            at = tree.parent(of: at)
        }
        return names
    }

    /// Each name at the side with its share of what's in the middle after its size: "45.2 GB · 9%". Not with a split, whose
    /// sides are wholes of their own.
    private func withShares(_ picks: [LabelPlacer.Pick], in layout: RingLayout) -> [LabelPlacer.Pick] {
        guard showsShares, namer?.valuesAreSizes ?? true, !layout.isSplit else { return picks }
        let whole = Double(max(tree.size(of: focus), 1))
        return picks.map { pick in
            guard pick.index < layout.pieces.count, !pick.value.isEmpty else { return pick }
            var with = pick
            with.value += " · " + Self.percent(Double(layout.pieces[pick.index].size) / whole)
            return with
        }
    }

    static func percent(_ share: Double) -> String {
        share >= 0.095 || share == 0 ? "\(Int((share * 100).rounded()))%" : String(format: "%.1f%%", share * 100)
    }
}

/// A chart's names around its ring, wired to it: pointing at one lights its piece, and a click opens it. `Sunburst` shows one;
/// a view of the app's own shows it over the ring. `outer` modifies each name at the side, such as with a menu of its own.
///
/// `ring` is where the ring is, as given to `RingPlace`: the names follow it while it moves, as when the window is resized,
/// and are placed again for where it rests. Without it, they stay where they were placed until then.
public struct SunburstChartLabels<Tree: SunburstTree, Outer: ViewModifier>: View {
    let chart: SunburstChart<Tree>
    let width: CGFloat
    let ring: RingPlacement?
    let outer: (SunburstLabel) -> Outer

    public init(_ chart: SunburstChart<Tree>, width: CGFloat, ring: RingPlacement? = nil, outer: @escaping (SunburstLabel) -> Outer) {
        self.chart = chart
        self.width = width
        self.ring = ring
        self.outer = outer
    }

    public var body: some View {
        let placedFor = chart.labelsPlacedFor
        SunburstLabels(
            labels: chart.labels, lights: chart.labelLights, visible: chart.labelsVisible, width: width,
            onEnter: { [chart] in chart.pointerOnLabel(piece: $0) }, onLeave: { [chart] in chart.pointerLeftLabel(piece: $0) },
            onOpen: { [chart] piece, clicks in chart.labelClicked(piece: piece, count: clicks) },
            outer: outer
        )
        .following(ring ?? placedFor, placedFor: placedFor)
        .animation(.easeOut(duration: chart.labelsVisible ? 0.28 : 0.1), value: chart.labelsVisible)
    }
}

extension SunburstChartLabels where Outer == EmptyModifier {
    public init(_ chart: SunburstChart<Tree>, width: CGFloat, ring: RingPlacement? = nil) {
        self.init(chart, width: width, ring: ring) { _ in EmptyModifier() }
    }
}
