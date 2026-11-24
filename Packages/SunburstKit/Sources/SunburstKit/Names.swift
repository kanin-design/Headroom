/// What a chart names, and what it says: on the pieces a name fits, and out at the sides, with a line, for big ones that
/// can't hold their own. A chart with no namer of its own names each piece after its node, with its size or value.
///
/// An app names by its own rules: only free space on the ring while cleaning up, say, or at the sides the things its own
/// lists point at, scored by how much they matter there.
@MainActor
public protocol SunburstNamer {
    /// The title and value written on a piece, or nil to leave it unnamed. Asked biggest piece first.
    func inside(_ piece: Piece) -> (title: String, value: String)?
    /// What's named at the sides, best first. `named` holds what's already named on the ring; add what you pick to it, so
    /// nothing is named twice. The kit's own choice is `LabelPlacer.bigPieces(layout:order:named:name:)`.
    func sides(_ layout: RingLayout, order: [Int], named: inout LabelPlacer.Placed) -> [LabelPlacer.Pick]
    /// Whether a name just outside a piece that's already named is left out, as it would say nearly the same thing.
    /// True by default.
    var leavesOutRepeats: Bool { get }
    /// Whether the values at the sides are sizes, so each can say its share of what's in the middle after it
    /// (`SunburstChart.showsShares`). True by default; false where they say something else, such as a change.
    var valuesAreSizes: Bool { get }
}

extension SunburstNamer {
    public var leavesOutRepeats: Bool { true }
    public var valuesAreSizes: Bool { true }
}
