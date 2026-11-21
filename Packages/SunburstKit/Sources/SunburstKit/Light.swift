/// A set of nodes, each with everything inside it: what's selected, what a plan will remove, what a search found. Lighting
/// asks a set only these two things, so an app whose tree can answer them faster (Headroom numbers its nodes in depth
/// first order) hands over its own set.
public protocol SunburstNodeSet {
    /// The set's nodes that aren't inside another of its nodes.
    var tops: [UInt32] { get }
    /// Whether the node is one of the set's, or inside one of them.
    func contains(_ node: UInt32) -> Bool
}

/// A set of nodes in any tree, answered by walking up from a node to the root.
public struct SunburstNodes<Tree: SunburstTree>: SunburstNodeSet {
    public let tops: [UInt32]
    @usableFromInline let members: Set<UInt32>
    @usableFromInline let tree: Tree

    public init(_ nodes: [UInt32], in tree: Tree) {
        let members = Set(nodes)
        var seen = Set<UInt32>()
        var tops: [UInt32] = []
        for node in nodes where seen.insert(node).inserted {
            var up = node
            var inside = false
            while up != 0 {
                up = tree.parent(of: up)
                if members.contains(up) {
                    inside = true
                    break
                }
            }
            if !inside { tops.append(node) }
        }
        self.tops = tops
        self.members = members
        self.tree = tree
    }

    @inlinable
    public func contains(_ node: UInt32) -> Bool {
        var at = node
        while true {
            if members.contains(at) { return true }
            if at == 0 { return false }
            at = tree.parent(of: at)
        }
    }
}

/// What lights up on a picture for a set of nodes: pieces lit whole, and the pieces on the way out to them.
public struct RingLight: Sendable, Equatable {
    /// Pieces lit whole, each with everything drawn inside it, as ranges of the picture's `pieces`.
    public var full: [Range<Int>]
    /// Pieces lit less: the folders that hold something lit, and the "smaller items" that something lit is gathered into.
    /// In the order of the picture's pieces.
    public var holding: [Int]

    public init(full: [Range<Int>] = [], holding: [Int] = []) {
        self.full = full
        self.holding = holding
    }

    public var isEmpty: Bool { full.isEmpty && holding.isEmpty }
}

extension RingLayout {
    /// How something too small to draw shows when it's lit: by the piece that holds it, which is its "smaller items" if it
    /// has one.
    public enum GatheredLight: Sendable {
        /// Lit less, as the way out to it: for what's selected, where the thing itself is the point.
        case held
        /// Lit as fully as the thing itself would be, so every place it is shows: for copies of one thing, say.
        case shown
    }

    /// What lights up for a set of nodes. Whatever has a piece of its own lights that piece, with everything inside it. What's
    /// too small to draw, or is drawn as part of something else, lights the piece that holds it (see `GatheredLight`), so
    /// pointing at a thing always shows. Room and what can't be read never light.
    @inlinable
    public func light<T: SunburstTree, S: SunburstNodeSet>(_ set: S, in tree: T, gathered: GatheredLight = .held) -> RingLight {
        var full: [Range<Int>] = []
        var holding = Set<Int>()
        @inline(__always) func addParents(of index: Int) {
            var up = _pieces[index].parent
            while up >= 0 {
                for stretch in stretches(around: Int(up)) { holding.insert(stretch) }
                up = _pieces[Int(up)].parent
            }
        }
        // Every piece of the set, whole: one pass over the pieces, skipping what's inside a lit one.
        var i = 0
        while i < _pieces.count {
            let p = _pieces[i]
            if !p.isSmaller, !p.role.isSpace, set.contains(p.node) || set.contains(p.tail) {
                let whole = extent(of: i)
                full.append(whole)
                addParents(of: i)
                i = max(whole.upperBound, i + 1)
            } else {
                i += 1
            }
        }
        // What has no piece of its own lights what it's drawn in. A node with a lit piece inside it is shown already.
        var shown = Set<UInt32>()
        for range in full {
            let p = _pieces[range.lowerBound]
            for start in [p.node, p.tail] {
                var up = start
                while shown.insert(up).inserted, up != 0 { up = tree.parent(of: up) }
            }
        }
        for top in set.tops {
            if focus != 0, !tree.isInside(top, focus) { continue }
            if shown.contains(top) { continue }
            var walk = top
            while true {
                if let at = piece(of: walk) {
                    let target = smallerPiece(in: at) ?? at
                    if gathered == .shown { full.append(target..<target + 1) } else { holding.insert(target) }
                    addParents(of: target)
                    break
                }
                if walk == focus || walk == 0 {
                    if let outerSmaller {
                        if gathered == .shown { full.append(outerSmaller..<outerSmaller + 1) } else { holding.insert(outerSmaller) }
                    }
                    break
                }
                walk = tree.parent(of: walk)
            }
        }
        return RingLight(full: full, holding: holding.sorted())
    }

    /// What lights up for these nodes, as the tree's own set of them (`SunburstTree.branches(_:)`); see `light(_:in:)`.
    @inlinable
    public func light<T: SunburstTree>(_ nodes: [UInt32], in tree: T, gathered: GatheredLight = .held) -> RingLight {
        light(tree.branches(nodes), in: tree, gathered: gathered)
    }

    /// The biggest piece that stands for a set, or the outermost of what holds it if it has none: where to put a name for it.
    @inlinable
    public func bestPiece<T: SunburstTree, S: SunburstNodeSet>(for set: S, in tree: T) -> Int? {
        let found = light(set, in: tree)
        if let best = found.full.map(\.lowerBound).max(by: { _pieces[$0].size < _pieces[$1].size }) { return best }
        return found.holding.max { _pieces[$0].r0 < _pieces[$1].r0 }
    }

    /// The biggest piece that stands for these nodes, as the tree's own set of them; see `bestPiece(for:in:)` for a set.
    @inlinable
    public func bestPiece<T: SunburstTree>(for nodes: [UInt32], in tree: T) -> Int? {
        bestPiece(for: tree.branches(nodes), in: tree)
    }
}
