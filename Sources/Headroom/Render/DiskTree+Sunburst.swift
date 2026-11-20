@_exported import SunburstKit
import Foundation

/// The disk map is drawn by SunburstKit from the scanned tree as it is: each node's numbers are read where the scan keeps
/// them. What the map is about stays here: free space and hidden space around the whole disk, Backup's two halves, and the
/// order its halves' contents are drawn in.
extension DiskTree: SunburstTree {
    @inline(__always) func firstChild(of node: UInt32) -> UInt32 { nodes[Int(node)].firstChild }
    @inline(__always) func nextSibling(of node: UInt32) -> UInt32 { nodes[Int(node)].nextSibling }
    @inline(__always) func parent(of node: UInt32) -> UInt32 { nodes[Int(node)].parent }
    @inline(__always) func size(of node: UInt32) -> UInt64 { totals[Int(node)] }
    @inline(__always) func ownSize(of node: UInt32) -> UInt64 { nodes[Int(node)].bytes }
    @inline(__always) func isFolder(_ node: UInt32) -> Bool { nodes[Int(node)].has(NodeFlag.directory) }

    @inline(__always) func style(of node: UInt32) -> PieceStyle {
        let n = nodes[Int(node)]
        if n.has(NodeFlag.free) { return .free }
        if n.has(NodeFlag.hidden) || n.has(NodeFlag.locked) { return .hidden }
        if isGhost(node) { return .ghost }
        if !n.has(NodeFlag.directory) && !n.has(NodeFlag.synthetic) { return .file }
        return .folder
    }

    @inline(__always) func nameKey(of node: UInt32) -> UInt64 {
        let n = nodes[Int(node)]
        return n.nameLength > 0 ? RuleBook.hash(UnsafePointer(names + Int(n.nameOffset)), Int(n.nameLength)) : UInt64(node)
    }

    /// Backup's two sides: this Mac and the drive, each half the ring.
    var hasHalves: Bool { twoSides }
    @inline(__always) func isHalf(_ node: UInt32) -> Bool { nodes[Int(node)].has(NodeFlag.anchor) }
    /// The whole disk has the thin band that splits it into what's on it, what's hidden and what's free. Backup's two sides
    /// don't: their halves are a ring.
    var hasBand: Bool { !twoSides }

    /// Free space closes the circle, right after what's hidden. While a scan is running, the big groups keep their places
    /// instead of swapping as they fill up.
    @inline(__always) func rootRank(of node: UInt32) -> Int {
        if node == free { return 5 }
        if node == hidden { return 4 }
        if isPartial { return node == home ? 0 : (nodes[Int(node)].has(NodeFlag.synthetic) ? 1 : 2) }
        return 0
    }

    /// Free space and what's hidden are shapes of their own, the free wedge being the thing that grows when you clean up.
    @inline(__always) func isPlainShape(_ node: UInt32) -> Bool { node == free || node == hidden }

    /// Backup's halves draw what's in the same place on both sides together.
    var hasGroups: Bool { !order.isEmpty }
    @inline(__always) func group(of node: UInt32) -> UInt8? { order[node] }
}

/// The disk as it will be once the plan has run: what goes is gone and free space has grown. Everything else is the tree's.
struct AfterTree: SunburstTree {
    let tree: DiskTree
    let after: AfterPlan

    @inline(__always) func firstChild(of node: UInt32) -> UInt32 { tree.firstChild(of: node) }
    @inline(__always) func nextSibling(of node: UInt32) -> UInt32 { tree.nextSibling(of: node) }
    @inline(__always) func parent(of node: UInt32) -> UInt32 { tree.parent(of: node) }
    @inline(__always) func size(of node: UInt32) -> UInt64 { after.size(node) }
    @inline(__always) func ownSize(of node: UInt32) -> UInt64 { tree.ownSize(of: node) }
    @inline(__always) func isFolder(_ node: UInt32) -> Bool { tree.isFolder(node) }
    @inline(__always) func style(of node: UInt32) -> PieceStyle { tree.style(of: node) }
    @inline(__always) func nameKey(of node: UInt32) -> UInt64 { tree.nameKey(of: node) }
    var hasHalves: Bool { tree.hasHalves }
    @inline(__always) func isHalf(_ node: UInt32) -> Bool { tree.isHalf(node) }
    var hasBand: Bool { tree.hasBand }
    @inline(__always) func rootRank(of node: UInt32) -> Int { tree.rootRank(of: node) }
    @inline(__always) func isPlainShape(_ node: UInt32) -> Bool { tree.isPlainShape(node) }
    var hasGroups: Bool { tree.hasGroups }
    @inline(__always) func group(of node: UInt32) -> UInt8? { tree.group(of: node) }
    @inline(__always) func isStillGrowing(_ node: UInt32) -> Bool { tree.isStillGrowing(node) }
}

extension RingLayout {
    /// The picture of the disk, or of the disk as it will be after the plan has run.
    static func build(tree: DiskTree, focus: UInt32, colorer: Colorer, marked: Marker? = nil, after: AfterPlan?,
                      sizes: RingSizes = .saved) -> RingLayout {
        if let after { return build(tree: AfterTree(tree: tree, after: after), focus: focus, colorer: colorer, marked: marked, sizes: sizes) }
        return build(tree: tree, focus: focus, colorer: colorer, marked: marked, sizes: sizes)
    }

    /// What lights up for these things. Whatever has a piece of its own lights that piece, with everything inside it. What's too
    /// small to draw, or is drawn as part of something else, lights the piece that holds it, so pointing at a thing always shows.
    func lit(by nodes: [UInt32], tree: DiskTree) -> (full: [Range<Int>], holding: [Int]) {
        let set = NodeSet(nodes, in: tree)
        var full: [Range<Int>] = []
        var holding = Set<Int>()
        func addParents(of index: Int) {
            var up = pieces[index].parent
            while up >= 0 {
                holding.insert(Int(up))
                up = pieces[Int(up)].parent
            }
        }
        var i = 0
        while i < pieces.count {
            let p = pieces[i]
            if !p.isSmaller, p.style != .free, p.style != .hidden, set.contains(p.node) || set.contains(p.tail) {
                let end = max(Int(p.end), i + 1)
                full.append(i..<end)
                addParents(of: i)
                i = end
            } else {
                i += 1
            }
        }
        for top in set.tops {
            if focus != 0, !tree.isInside(top, focus) { continue }
            let drawn = full.contains { range in
                let p = pieces[range.lowerBound]
                return tree.isInside(p.node, top) || tree.isInside(p.tail, top)
            }
            if drawn { continue }
            var walk = top
            while true {
                if let at = piece(of: walk) {
                    let target = smallerPiece(in: at) ?? at
                    holding.insert(target)
                    addParents(of: target)
                    break
                }
                if walk == focus || walk == 0 {
                    if let outerSmaller { holding.insert(outerSmaller) }
                    break
                }
                walk = tree.nodes[Int(walk)].parent
            }
        }
        return (full, Array(holding))
    }

    /// The biggest piece that stands for these things, or what holds them if they have none.
    func bestPiece(for nodes: [UInt32], tree: DiskTree) -> Int? {
        let found = lit(by: nodes, tree: tree)
        if let best = found.full.map(\.lowerBound).max(by: { pieces[$0].size < pieces[$1].size }) { return best }
        return found.holding.max { pieces[$0].r0 < pieces[$1].r0 }
    }
}

extension RingSizes {
    /// Picked in View › Rings and kept for the next launch. For one run only: `--args -ringDepth 8 -ringStyle adaptive`.
    static var saved: RingSizes {
        let defaults = UserDefaults.standard
        let depth = defaults.integer(forKey: depthKey)
        let style = defaults.string(forKey: styleKey).flatMap(RingStyle.init(rawValue:))
        return RingSizes(depth: depth == 0 ? RingSizes().depth : min(max(depth, 1), most), style: style ?? RingSizes().style)
    }

    /// Only what changed, so a setting given for one run isn't kept.
    func save(changedFrom old: RingSizes) {
        if depth != old.depth { UserDefaults.standard.set(depth, forKey: Self.depthKey) }
        if style != old.style { UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey) }
    }

    private static let depthKey = "ringDepth", styleKey = "ringStyle"
}
