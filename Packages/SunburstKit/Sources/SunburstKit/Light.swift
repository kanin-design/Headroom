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

/// What's lit on a picture, as an engine shows it (`SunburstEngine.setEmphasis(_:)`): the piece pointed at, which stands
/// out most; what's lit with it; and a colour for what's lit, or for some of it. Everything else steps back.
public struct RingEmphasis: Sendable, Equatable {
    /// The piece pointed at, an index into the picture's `pieces`.
    public var primary: Int?
    /// What's lit whole, and the pieces on the way out to it, lit less.
    public var light: RingLight
    /// One colour that what's lit takes on, and the way out part of.
    public var tint: SIMD3<Float>?
    /// With a tint: the pieces that take it. Nil for all that's lit.
    public var tinted: [Range<Int>]?

    public init(primary: Int? = nil, light: RingLight = RingLight(), tint: SIMD3<Float>? = nil, tinted: [Range<Int>]? = nil) {
        self.primary = primary
        self.light = light
        self.tint = tint
        self.tinted = tinted
    }

    /// Nothing is lit.
    public var isEmpty: Bool { primary == nil && light.isEmpty }
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

    /// What lights when a piece is pointed at: the piece most, everything drawn inside it whole, and the pieces on the way
    /// out to it less. `lighting` adds what the app says goes with it: the same thing elsewhere, and a colour for all of
    /// what's lit or for some of the piece and what's inside it.
    public func emphasis<T: SunburstTree>(pointingAt index: Int, in tree: T, lighting: SunburstLighting? = nil) -> RingEmphasis {
        var wayOut: [Int] = []
        var up = _pieces[index].parent
        while up >= 0 {
            wayOut.append(contentsOf: stretches(around: Int(up)))
            up = _pieces[Int(up)].parent
        }
        let whole = extent(of: index)
        var full = [whole]
        var tinted: [Range<Int>]?
        if let lighting {
            if !lighting.also.isEmpty {
                let more = light(lighting.also, in: tree, gathered: lighting.gathered)
                full += more.full
                wayOut += more.holding
            }
            if let tints = lighting.tints { tinted = pieces(in: whole, taking: tints) }
        }
        return RingEmphasis(primary: index, light: RingLight(full: full, holding: wayOut), tint: lighting?.tint, tinted: tinted)
    }

    /// What lights for nodes pointed at from outside the ring, such as a row in a list: each with everything inside it, and
    /// the way out to each. `primary`, one of them, stands out most.
    public func emphasis<T: SunburstTree>(
        lighting nodes: [UInt32], primary: UInt32? = nil, in tree: T, gathered: GatheredLight = .shown,
        tint: SIMD3<Float>? = nil
    ) -> RingEmphasis {
        // The primary's own piece: the first it lights, as it's lit among the others.
        let own = primary.flatMap { light([$0], in: tree, gathered: gathered).full.first?.lowerBound }
        return RingEmphasis(primary: own, light: light(nodes, in: tree, gathered: gathered), tint: tint)
    }

    /// The pieces in `extent` that take a tint: those whose node `tints` says do (a "smaller items" piece with the node that
    /// holds them), and each stretch of a folder cut by group when everything drawn in that stretch does. So the stretch
    /// that stands for what's backed up reads as backed up, though its folder as a whole isn't.
    public func pieces(in extent: Range<Int>, taking tints: (UInt32) -> Bool) -> [Range<Int>] {
        let base = extent.lowerBound
        var takes = [Bool](repeating: false, count: extent.count)
        var inside = [Int32](repeating: 0, count: extent.count), insideTaking = inside
        // Depth first, so going backwards meets everything drawn in a piece before the piece itself.
        for i in extent.reversed() {
            let p = _pieces[i], at = i - base
            var on = tints(p.node)
            // A stretch with its own things drawn in it, all of which take the tint.
            if !on, p.isStretch, inside[at] > 0, inside[at] == insideTaking[at] { on = true }
            takes[at] = on
            let parent = Int(p.parent)
            if parent >= base, parent < extent.upperBound {
                inside[parent - base] += 1
                if on { insideTaking[parent - base] += 1 }
            }
        }
        var out: [Range<Int>] = []
        var i = 0
        while i < takes.count {
            guard takes[i] else { i += 1; continue }
            var end = i + 1
            while end < takes.count, takes[end] { end += 1 }
            out.append(base + i..<base + end)
            i = end
        }
        return out
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
