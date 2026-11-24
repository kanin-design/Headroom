/// One drawn piece of the ring. Pieces are listed depth first: a piece's descendants follow it, up to `end`.
public struct Piece: Sendable, Equatable {
    /// The node it stands for, or for a "smaller items" piece, the node that holds those items.
    public var node: UInt32
    /// The deepest node it stands for, when a chain such as Media › TV is drawn as one piece.
    public var tail: UInt32
    /// The same from one picture to the next, so a piece can glide from its old place to its new one.
    public var key: UInt64
    /// Where it starts and ends, in radians clockwise from 12 o'clock.
    public var a0: Float, a1: Float
    /// Its inner and outer edge, as shares of the ring's radius.
    public var r0: Float, r1: Float
    /// Which level it's in, from the middle out, counting bands: `RingLayout.levels[ring]` says which part that is.
    public var ring: Int32
    /// The index of the piece it sits on, or -1 in the first level.
    public var parent: Int32
    /// The index after its last descendant.
    public var end: Int32
    /// Whether it gathers what's too small to draw on its own.
    public var isSmaller: Bool
    /// How many things a "smaller items" piece stands for.
    public var smallerCount: Int32
    /// Its colour, in linear Display P3.
    public var color: SIMD3<Float>
    /// What its node is (`SunburstTree.role(of:)`). A "smaller items" piece is a container.
    public var role: SunburstRole
    /// Shared, such as seeding: a bright dashed line along its outer edge.
    public var isShared: Bool
    /// One of several pieces its node is drawn as, side by side: a stretch of a folder cut by group, or one the chart's
    /// `cuts` asked for. Its `size` is the stretch's.
    public var isStretch: Bool
    /// A number from 0 to 1 that tells neighbours apart.
    public var seed: Float
    /// The size it's drawn for: the node's size, or what a "smaller items" piece gathers.
    public var size: UInt64
    /// How far it steps back until it's pointed at, from 0 to 0.8. See `RingLayout.calmTinyPieces(total:)`.
    public var calm: Float = 0
    /// 1 when it's marked, such as selected: drawn striped.
    public var marked: Float = 0
    /// In the outermost ring, how much of it is in rings that aren't drawn, from 0 to 1. It fades out past its edge by that much.
    public var deeper: Float = 0

    /// How far around it goes, in radians.
    @inlinable public var sweep: Float { a1 - a0 }
    /// The angle of its middle.
    @inlinable public var midAngle: Float { (a0 + a1) * 0.5 }
    /// Room or what can't be read, as opposed to things: free space and hidden space on a disk.
    @inlinable public var isSpace: Bool { !isSmaller && role.isSpace }

    @inlinable
    init(
        node: UInt32, tail: UInt32, key: UInt64, a0: Float, a1: Float, r0: Float, r1: Float, ring: Int32, parent: Int32, end: Int32,
        isSmaller: Bool, smallerCount: Int32, color: SIMD3<Float>, role: SunburstRole, isShared: Bool, seed: Float, size: UInt64,
        marked: Float = 0, isStretch: Bool = false
    ) {
        self.node = node
        self.tail = tail
        self.key = key
        self.a0 = a0
        self.a1 = a1
        self.r0 = r0
        self.r1 = r1
        self.ring = ring
        self.parent = parent
        self.end = end
        self.isSmaller = isSmaller
        self.smallerCount = smallerCount
        self.color = color
        self.role = role
        self.isShared = isShared
        self.seed = seed
        self.size = size
        self.marked = marked
        self.isStretch = isStretch
    }

    /// The number the shaders know its look by (`Style` in Shaders.metal): what it is. Its marks, striped and shared, are
    /// drawn over that, whatever it is.
    var look: Float {
        if isSmaller { return 3 }
        switch role {
        case .container: return 0
        case .room: return 1
        case .unreadable: return 2
        case .item: return 4
        case .gone: return 5
        }
    }
}
