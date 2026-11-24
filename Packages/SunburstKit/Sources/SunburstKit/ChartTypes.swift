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

    /// A piece of the picture, at this index in its pieces.
    init(_ piece: Piece, at index: Int) {
        self.init(node: piece.node, piece: index, isGathered: piece.isSmaller)
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

/// How pointing at a node lights the ring, beyond the node itself and what's inside it (`SunburstChart.lighting`): what
/// else lights with it, such as every copy of it, and a colour for what's lit, or for some of it, such as what's backed up.
public struct SunburstLighting: Sendable {
    /// The same thing elsewhere, lit with what's pointed at.
    public var also: [UInt32]
    /// How what's too small to draw shows.
    public var gathered: RingLayout.GatheredLight
    /// One colour that what lights takes on.
    public var tint: SIMD3<Float>?
    /// Of the piece pointed at and what's inside it, the nodes that take `tint`: what has a copy, say. A folder cut into
    /// stretches by group shows it on each stretch whose contents all take it. Nil, the default: everything lit takes it.
    public var tints: (@Sendable (UInt32) -> Bool)?

    public init(
        also: [UInt32] = [], gathered: RingLayout.GatheredLight = .held, tint: SIMD3<Float>? = nil,
        tints: (@Sendable (UInt32) -> Bool)? = nil
    ) {
        self.also = also
        self.gathered = gathered
        self.tint = tint
        self.tints = tints
    }
}
