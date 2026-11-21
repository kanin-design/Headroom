import Foundation

/// The data a sunburst is drawn from. The kit never owns it: the app keeps its own tree and answers these questions about
/// it. Nodes are numbers. Node 0 is the root, and 0 as a child or a sibling means there is none. Children are listed
/// biggest first.
///
/// The tree says only what exists, how big it is and what it is. How it's drawn (bands, a split, how many rings, what's
/// cut into stretches) is the chart's: see `SunburstParts`.
public protocol SunburstTree {
    // MARK: Shape

    func firstChild(of node: UInt32) -> UInt32
    func nextSibling(of node: UInt32) -> UInt32
    func parent(of node: UInt32) -> UInt32
    /// Everything in the node: the size that sets its angle.
    func size(of node: UInt32) -> UInt64
    /// What the node holds itself, outside its children: a folder's own files. Drawn with what's too small to draw alone.
    func ownSize(of node: UInt32) -> UInt64
    /// A folder that's nearly all one subfolder is drawn as one piece with it. Only folders chain.
    func isFolder(_ node: UInt32) -> Bool
    /// A number from its name that stays the same from one tree to the next, so a piece can glide from its old place to
    /// its new one when the tree changes.
    func nameKey(of node: UInt32) -> UInt64

    // MARK: What a node is

    /// What the node is, which sets how it looks. By default a folder is a container and anything else an item.
    func role(of node: UInt32) -> SunburstRole
    /// Being shared, such as a file a torrent is seeding: drawn with a bright dashed line along its outer edge.
    func isShared(_ node: UInt32) -> Bool
    /// Which group the node is in, for rings drawn by group (`SunburstParts.Rings.Order.byGroup`), such as a place:
    /// on both disks, only on this one. Nil for none.
    func group(of node: UInt32) -> UInt8?
    /// Still being read: what looks like nearly all of it may turn out to be a small part, so it doesn't chain yet.
    func isStillGrowing(_ node: UInt32) -> Bool
    /// Whether the tree has a node with this number, so a number from outside, such as an agent's, can be checked before the
    /// tree is asked anything about it. By default it's looked for from the root down; a tree that numbers its nodes in a
    /// row can answer at once.
    func hasNode(_ node: UInt32) -> Bool
    /// Whether `node` is `folder` or inside it. By default it walks up from the node; a tree that numbers its nodes in
    /// depth-first order can answer at once.
    func isInside(_ node: UInt32, _ folder: UInt32) -> Bool

    // MARK: Lighting

    /// A set of nodes, each with everything inside it, as lighting asks about it once for every piece on the ring.
    associatedtype Branches: SunburstNodeSet = SunburstNodes<Self>
    /// These nodes as a set, for lighting: by default one that walks up from each node it's asked about. A tree that numbers
    /// its nodes in depth-first order can answer from ranges, much faster on a big ring.
    func branches(_ nodes: [UInt32]) -> Branches
}

/// One stretch of a node's piece: see `SunburstParts.Rings.cuts`.
public struct SunburstStretch: Sendable, Equatable {
    /// How much of the node it is: its angle is its share of all the node's stretches.
    public var size: UInt64
    /// Its colour, in linear Display P3, or nil for the node's own.
    public var color: SIMD3<Float>?
    /// Drawn striped, as a marked node is.
    public var isMarked: Bool
    /// Tells it apart from the node's other stretches, the same from one tree to the next, so it glides to its new place.
    public var key: UInt8

    public init(size: UInt64, color: SIMD3<Float>? = nil, isMarked: Bool = false, key: UInt8) {
        self.size = size
        self.color = color
        self.isMarked = isMarked
        self.key = key
    }
}

public extension SunburstTree where Branches == SunburstNodes<Self> {
    func branches(_ nodes: [UInt32]) -> SunburstNodes<Self> { SunburstNodes(nodes, in: self) }
}

public extension SunburstTree {
    func role(of node: UInt32) -> SunburstRole { isFolder(node) ? .container : .item }
    func isShared(_ node: UInt32) -> Bool { false }
    func group(of node: UInt32) -> UInt8? { nil }
    func isStillGrowing(_ node: UInt32) -> Bool { false }

    func isInside(_ node: UInt32, _ folder: UInt32) -> Bool {
        var at = node
        while true {
            if at == folder { return true }
            if at == 0 { return false }
            at = parent(of: at)
        }
    }

    func hasNode(_ node: UInt32) -> Bool {
        if node == 0 { return true }
        // Only nodes reached from the root are asked about, so a number the tree doesn't have is never looked up.
        var stack: [UInt32] = [0]
        while let at = stack.popLast() {
            var c = firstChild(of: at)
            while c != 0 {
                if c == node { return true }
                stack.append(c)
                c = nextSibling(of: c)
            }
        }
        return false
    }

    /// The node's children, in the tree's order.
    func children(of node: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        var c = firstChild(of: node)
        while c != 0 {
            out.append(c)
            c = nextSibling(of: c)
        }
        return out
    }

    /// How many levels the node is below the root: 0 for the root.
    @inlinable
    func depth(of node: UInt32) -> Int {
        var depth = 0
        var at = node
        while at != 0 {
            at = parent(of: at)
            depth += 1
        }
        return depth
    }
}
