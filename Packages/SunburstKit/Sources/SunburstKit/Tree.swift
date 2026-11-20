import Foundation

/// The tree a sunburst is drawn from. The package never owns it: the host keeps its own tree and answers these questions
/// about it. Nodes are numbers. Node 0 is the root, and 0 as a child or a sibling means there is none. Children are listed
/// biggest first.
///
/// Only the first group is required. The rest are the host's choices, with defaults that draw a plain sunburst.
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
    /// How its piece is drawn.
    func style(of node: UInt32) -> PieceStyle
    /// A number from its name that stays the same from one tree to the next, so a piece can glide from its old place to
    /// its new one when the tree changes.
    func nameKey(of node: UInt32) -> UInt64

    // MARK: Host's choices

    /// The root is two halves of the ring, whatever their sizes, such as one disk beside another.
    var hasHalves: Bool { get }
    /// Which of the root's children are the halves.
    func isHalf(_ node: UInt32) -> Bool
    /// The root has a thin band around the middle, and the rings of folders start outside it.
    var hasBand: Bool { get }
    /// Around the root, lower ranks are drawn first, then biggest first.
    func rootRank(of node: UInt32) -> Int
    /// A shape of its own in the first ring, such as free space: nothing inside it is drawn, and it reaches as far out as the
    /// rest of the ring does on average, so its area matches its share.
    func isPlainShape(_ node: UInt32) -> Bool
    /// Whether the tree has an order of its own. Then things in a folder are drawn by group first, and a folder whose
    /// contents fall in more than one group is drawn as one stretch for each, coloured by the first thing in it.
    var hasGroups: Bool { get }
    func group(of node: UInt32) -> UInt8?
    /// Still being read: what looks like nearly all of it may turn out to be a small part, so it doesn't chain yet.
    func isStillGrowing(_ node: UInt32) -> Bool
}

public extension SunburstTree {
    var hasHalves: Bool { false }
    func isHalf(_ node: UInt32) -> Bool { false }
    var hasBand: Bool { false }
    func rootRank(of node: UInt32) -> Int { 0 }
    func isPlainShape(_ node: UInt32) -> Bool { false }
    var hasGroups: Bool { false }
    func group(of node: UInt32) -> UInt8? { nil }
    func isStillGrowing(_ node: UInt32) -> Bool { false }

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
}
