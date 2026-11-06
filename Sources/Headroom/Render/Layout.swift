import Foundation
import simd

/// One drawn piece of the ring.
struct Piece {
    var node: UInt32              // the node, or its parent for a "smaller items" piece
    var tail: UInt32              // the deepest folder it stands for, when a chain like Media › TV is drawn as one
    var key: UInt64               // the same on every scan, so a piece can glide from its old place to its new one
    var a0: Float, a1: Float      // radians, clockwise from 12 o'clock
    var r0: Float, r1: Float      // fractions of the ring's radius
    var ring: Int32
    var parent: Int32             // index of the piece it sits on, or -1
    var end: Int32                // index after its last descendant
    var isSmaller: Bool
    var smallerCount: Int32       // how many things a "smaller items" piece stands for
    var color: SIMD3<Float>
    var style: Float
    var seed: Float
    var bytes: UInt64
    var calm: Float = 0           // how far it steps back until you point at it
    var planned: Float = 0        // 1 when it goes at the next clean
    var isMark = false            // a tick outside the ring, not a piece of it
    var lit: Float = 0            // in Changes: how much of it, from where it starts, is what grew

    var sweep: Float { a1 - a0 }
    var midAngle: Float { (a0 + a1) * 0.5 }
}

/// Turns part of the tree into pieces of a ring, sorted clockwise from 12 o'clock with the biggest first.
struct RingLayout {
    /// Radial position of each ring. They get thinner going out, so a slice covers the same area on any ring and
    /// far-out folders don't look bigger than they are.
    static let hole: Float = 0.34
    static let bandWidth: Float = 0.028
    static let ringWidths: [Float] = [0.150, 0.128, 0.108, 0.090, 0.074, 0.060]
    /// Pieces shorter than this at their ring's middle, in points on a typical window, merge into "smaller items".
    static let minimumArc: Float = 2.2
    static let typicalRadius: Float = 400
    /// A folder at least this share one subfolder is drawn together with it.
    static let chainShare = 0.88

    var pieces: [Piece] = []
    var focus: UInt32 = 0
    /// In Changes, the most that grew in one lit piece: the yellow end of the scale.
    var mostGrowth: Int64 = 0

    /// What sets a piece's colour. The geometry is the same in every view, so you keep your place.
    typealias Colorer = (_ node: UInt32) -> SIMD3<Float>
    /// Whether a piece goes at the next clean.
    typealias Planner = (_ node: UInt32) -> Bool

    private var planner: Planner?
    private var after: AfterPlan?

    /// `after` draws the picture as it will be once the plan has run.
    /// `grown` lights what grew, for Changes.
    static func build(tree: DiskTree, focus: UInt32, colorer: Colorer, planned: Planner? = nil, after: AfterPlan? = nil,
                      grown: ((UInt32) -> Int64)? = nil) -> RingLayout {
        var layout = RingLayout()
        layout.focus = focus
        layout.planner = planned
        layout.after = after
        layout.pieces.reserveCapacity(4096)
        let isRoot = focus == 0
        guard (after?.size(focus) ?? tree.totals[Int(focus)]) > 0 else { return layout }
        var edges: [Float] = [hole]
        if isRoot { edges.append(hole + bandWidth) }
        for w in ringWidths { edges.append(edges[edges.count - 1] + w) }
        let scale = (1.0 - hole) / (edges[edges.count - 1] - hole)
        edges = edges.map { hole + ($0 - hole) * scale }
        layout.place(tree, parentNode: focus, parentPiece: -1, a0: 0, a1: 2 * .pi, ring: 0, edges: edges, colorer: colorer)
        if isRoot { layout.reachLikeTheRest(free: tree.free, hidden: tree.hidden, atLeast: edges[2]) }

        // A shallow folder gets thicker rings, so the picture fills the same space and every level is easier to see.
        if !isRoot, let deepest = layout.pieces.map(\.ring).max(), Int(deepest) + 2 < edges.count {
            let used = Int(deepest) + 1
            let current = edges[used] - hole
            let stretch = min((1 - hole) / current, 1.9)
            edges = edges.prefix(used + 1).map { hole + ($0 - hole) * stretch }
            layout.pieces.removeAll(keepingCapacity: true)
            layout.place(tree, parentNode: focus, parentPiece: -1, a0: 0, a1: 2 * .pi, ring: 0, edges: edges, colorer: colorer)
        }
        if let grown { layout.lightGrowth(grown) }
        return layout
    }

    /// How much of each outermost piece is what grew, so the light on the ring adds up to the growth and counts each byte
    /// once. A piece with pieces of its own drawn outside it stays dark: they show its growth, and its "smaller items"
    /// piece shows what's left of it.
    private mutating func lightGrowth(_ grown: (UInt32) -> Int64) {
        var lit: [(index: Int, delta: Int64)] = []
        for i in pieces.indices {
            let p = pieces[i]
            guard !p.isMark, p.style != 1, p.style != 2, Int(p.end) <= i + 1, p.bytes > 0 else { continue }
            var delta = grown(p.node)
            if p.isSmaller, p.parent >= 0 {
                // The folder's own growth, less what its pieces on this ring already show.
                var j = Int(p.parent) + 1
                while j < i {
                    let q = pieces[j]
                    if q.parent == p.parent, !q.isSmaller { delta -= grown(q.node) }
                    j = max(Int(q.end), j + 1)
                }
            }
            if delta > 0 {
                pieces[i].lit = min(Float(Double(delta) / Double(p.bytes)), 1)
                lit.append((i, delta))
            }
        }
        // The most growth in view glows yellow and a little stays deep red, so the colour says how much as the light does.
        // The square root spreads the small ones, which are most of them, across the scale.
        guard let most = lit.map(\.delta).max() else { return }
        mostGrowth = most
        for (i, delta) in lit {
            pieces[i].color = Palette.heat(Float(Double(delta) / Double(most)).squareRoot()).linearP3
        }
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
            if !p.isSmaller, p.style != 1, p.style != 2, set.contains(p.node) || set.contains(p.tail) {
                let end = p.isMark ? i + 1 : max(Int(p.end), i + 1)
                full.append(i..<end)
                addParents(of: i)
                i = end
            } else {
                i += 1
            }
        }
        var pieceOf = [UInt32: Int](minimumCapacity: pieces.count)
        var smallerOf: [Int: Int] = [:]
        var outerSmaller: Int?
        for (at, p) in pieces.enumerated() where !p.isMark {
            if p.isSmaller {
                if p.parent >= 0 { smallerOf[Int(p.parent)] = at } else { outerSmaller = at }
            } else {
                if pieceOf[p.node] == nil { pieceOf[p.node] = at }
                if pieceOf[p.tail] == nil { pieceOf[p.tail] = at }
            }
        }
        for top in set.tops {
            if focus != 0, !tree.isInside(top, focus) { continue }
            let drawn = full.contains { range in
                let p = pieces[range.lowerBound]
                return !p.isMark && (tree.isInside(p.node, top) || tree.isInside(p.tail, top))
            }
            if drawn { continue }
            var walk = top
            while true {
                if let at = pieceOf[walk] {
                    let target = smallerOf[at] ?? at
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
        if let best = found.full.map(\.lowerBound).filter({ !pieces[$0].isMark }).max(by: { pieces[$0].bytes < pieces[$1].bytes }) { return best }
        return found.holding.filter { !pieces[$0].isMark }.max { pieces[$0].r0 < pieces[$1].r0 }
    }

    /// Tiny pieces step back until you point at them, so the big ones are easier to see.
    mutating func calmTinyPieces(viewBytes: UInt64) {
        let total = Float(max(viewBytes, 1))
        for i in pieces.indices where !pieces[i].isMark { pieces[i].calm = min(max(1 - Float(pieces[i].bytes) / total / 0.006, 0), 0.8) }
    }

    /// What's drawn directly inside a folder, once a folder that's nearly all one subfolder is drawn as one with it.
    static func visibleChildren(tree: DiskTree, of parent: UInt32, after: AfterPlan? = nil) -> (kids: [UInt32], tail: UInt32, ownBytes: UInt64) {
        let nodes = tree.nodes
        @inline(__always) func total(_ id: UInt32) -> UInt64 { after?.size(id) ?? tree.totals[Int(id)] }
        func listChildren(_ id: UInt32, into out: inout [UInt32]) {
            var c = nodes[Int(id)].firstChild
            while c != 0 {
                if total(c) > 0 { out.append(c) }
                c = nodes[Int(c)].nextSibling
            }
        }
        var kids: [UInt32] = []
        listChildren(parent, into: &kids)
        var ownBytes = nodes[Int(parent)].bytes
        var tail = parent
        var flattened = false
        guard parent != 0 else { return (kids, tail, ownBytes) }
        while !tree.isStillGrowing(tail), let topIndex = kids.indices.max(by: { total(kids[$0]) < total(kids[$1]) }) {
            let top = kids[topIndex]
            let n = nodes[Int(top)]
            guard n.has(NodeFlag.directory), n.firstChild != 0,
                  Double(total(top)) >= Double(total(tail)) * chainShare else { break }
            kids.remove(at: topIndex)
            listChildren(top, into: &kids)
            ownBytes &+= n.bytes
            tail = top
            flattened = true
        }
        if flattened { kids.sort { total($0) > total($1) } }
        return (kids, tail, ownBytes)
    }

    /// Whether a node draws as one with its biggest subfolder, and which one that ends at.
    static func chainTail(tree: DiskTree, _ id: UInt32) -> UInt32 {
        guard id != 0 else { return id }
        let nodes = tree.nodes, totals = tree.totals
        var tail = id
        // While a folder is still being read, what looks like nearly all of it may turn out to be a small part.
        while !tree.isStillGrowing(tail) {
            var best: UInt32 = 0
            var c = nodes[Int(tail)].firstChild
            while c != 0 {
                if best == 0 || totals[Int(c)] > totals[Int(best)] { best = c }
                c = nodes[Int(c)].nextSibling
            }
            guard best != 0, nodes[Int(best)].has(NodeFlag.directory), nodes[Int(best)].firstChild != 0,
                  Double(totals[Int(best)]) >= Double(totals[Int(tail)]) * chainShare else { return tail }
            tail = best
        }
        return tail
    }

    private static func pathKey(_ tree: DiskTree, _ id: UInt32) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        var i = id
        let nodes = tree.nodes, names = tree.names
        while i != 0 {
            let n = nodes[Int(i)]
            if n.nameLength > 0 {
                h = (h &* 0x0000_0100_0000_01B3) ^ RuleBook.hash(UnsafePointer(names + Int(n.nameOffset)), Int(n.nameLength))
            } else {
                h = (h &* 0x0000_0100_0000_01B3) ^ UInt64(i)
            }
            i = n.parent
        }
        return h
    }

    /// Free space and what's hidden are shapes of their own, the free wedge being the thing that grows when you clean up.
    /// Nothing inside them is drawn, so a fixed depth would make them look bigger or smaller than they are. They reach as
    /// far out as the rest of the disk does on average instead, so each covers the same share of the ring as of the disk.
    private mutating func reachLikeTheRest(free: UInt32, hidden: UInt32, atLeast: Float) {
        func isOwnShape(_ p: Piece) -> Bool { p.ring == 0 && (p.node == free || p.node == hidden) }
        var area: Float = 0, sweep: Float = 0
        for p in pieces where !p.isMark && !isOwnShape(p) {
            area += p.sweep * (p.r1 * p.r1 - p.r0 * p.r0)
            if p.ring == 0 { sweep += p.sweep }
        }
        // With nothing else drawn yet, they are the whole disk between them and can fill the ring.
        let reach = sweep > 0 ? min(max((Self.hole * Self.hole + area / sweep).squareRoot(), atLeast), 1) : 1
        for i in pieces.indices where isOwnShape(pieces[i]) { pieces[i].r1 = reach }
    }

    private mutating func place(_ tree: DiskTree, parentNode: UInt32, parentPiece: Int32,
                                a0: Float, a1: Float, ring: Int, edges: [Float], colorer: Colorer) {
        guard ring + 1 < edges.count else { return }
        let after = self.after
        let plannerNow = self.planner
        let totals = tree.totals
        @inline(__always) func total(_ id: UInt32) -> UInt64 { after?.size(id) ?? totals[Int(id)] }
        let parentTotal = total(parentNode)
        guard parentTotal > 0 else { return }
        let nodes = tree.nodes
        let r0 = edges[ring], r1 = edges[ring + 1]
        let midArc = (r0 + r1) * 0.5 * Self.typicalRadius

        // A folder that is nearly all one subfolder would only repeat its shape on the next ring. Those chains are
        // drawn as one piece, so every ring shows something new.
        let visible = Self.visibleChildren(tree: tree, of: parentNode, after: after)
        var kids = visible.kids
        let ownBytes = visible.ownBytes
        if parentNode != 0 {
            if visible.tail != parentNode, parentPiece >= 0 { pieces[Int(parentPiece)].tail = visible.tail }
        } else {
            // Free space closes the circle, right after what's hidden.
            // While a scan is running, the big groups keep their places instead of swapping as they fill up.
            let growing = tree.isPartial
            kids.sort { x, y in
                func rank(_ id: UInt32) -> Int {
                    if id == tree.free { return 5 }
                    if id == tree.hidden { return 4 }
                    if growing { return id == tree.home ? 0 : (nodes[Int(id)].has(NodeFlag.synthetic) ? 1 : 2) }
                    return 0
                }
                let rx = rank(x), ry = rank(y)
                return rx != ry ? rx < ry : total(x) > total(y)
            }
        }

        let perByte = (a1 - a0) / Float(parentTotal)
        var angle = a0
        var smallerBytes: UInt64 = 0
        var smallerCount: Int32 = 0
        for id in kids {
            let bytes = total(id)
            let sweep = Float(bytes) * perByte
            let special = parentNode == 0
            if sweep * midArc < Self.minimumArc && !special {
                smallerBytes &+= bytes
                smallerCount += 1
                continue
            }
            let index = Int32(pieces.count)
            let n = nodes[Int(id)]
            let seed = Self.seed(id)
            let color = colorer(id)
            var style: Float = 0
            if n.has(NodeFlag.free) { style = 1 }
            else if n.has(NodeFlag.hidden) || n.has(NodeFlag.locked) { style = 2 }
            else if !n.has(NodeFlag.directory) && !n.has(NodeFlag.synthetic) { style = 4 }
            pieces.append(Piece(node: id, tail: id, key: Self.pathKey(tree, id), a0: angle, a1: angle + sweep, r0: r0, r1: r1,
                                ring: Int32(ring), parent: parentPiece, end: index + 1, isSmaller: false, smallerCount: 0,
                                color: color, style: style, seed: seed, bytes: bytes, planned: plannerNow?(id) == true ? 1 : 0))
            if n.firstChild != 0 {
                place(tree, parentNode: id, parentPiece: index, a0: angle, a1: angle + sweep, ring: ring + 1, edges: edges, colorer: colorer)
                pieces[Int(index)].end = Int32(pieces.count)
            }
            angle += sweep
        }

        // What's left: the folder's own small files, and anything too thin to draw on its own.
        let rest = smallerBytes &+ (parentNode == 0 ? 0 : ownBytes)
        if rest > 0 && parentNode != 0 {
            let sweep = a1 - angle
            if sweep * midArc > 0.6 {
                let seed = Self.seed(parentNode &* 31 &+ 7)
                let color = colorer(parentNode)
                let index = Int32(pieces.count)
                pieces.append(Piece(node: parentNode, tail: parentNode, key: Self.pathKey(tree, parentNode) ^ 0x5555_5555_5555, a0: angle, a1: a1, r0: r0, r1: r1,
                                    ring: Int32(ring), parent: parentPiece, end: index + 1, isSmaller: true, smallerCount: smallerCount,
                                    color: color, style: 3, seed: seed, bytes: rest, planned: plannerNow?(parentNode) == true ? 1 : 0))
            }
        }
    }

    /// A tick outside the ring, so that things too thin to see still show where they are.
    struct Mark {
        var node: UInt32
        var color: SIMD3<Float>
        var planned: Bool
    }

    /// Marks follow the pieces, so a thing that has its own piece gets a line along it, and anything smaller gets a tick at
    /// its place inside whichever piece holds it. Ticks that land on the same spot are one tick.
    mutating func addMarks(_ marks: [Mark], tree: DiskTree) {
        guard !marks.isEmpty else { return }
        let nodes = tree.nodes, totals = tree.totals
        var pieceOf = [UInt32: Int](minimumCapacity: pieces.count)
        for (i, p) in pieces.enumerated() where !p.isSmaller && pieceOf[p.node] == nil { pieceOf[p.node] = i }
        var taken = Set<Int>()
        var added = 0
        for mark in marks {
            if added >= 1600 { break }
            if focus != 0 && !tree.isInside(mark.node, focus) { continue }
            guard totals[Int(mark.node)] > 0 else { continue }
            var chain: [UInt32] = []
            var at = mark.node
            var lo: Float = 0, hi: Float = 2 * .pi
            while true {
                if let i = pieceOf[at] {
                    lo = pieces[i].a0
                    hi = pieces[i].a1
                    break
                }
                if at == focus || at == 0 { break }
                chain.append(at)
                at = nodes[Int(at)].parent
            }
            var parent = at
            for child in chain.reversed() {
                let whole = max(totals[Int(parent)], 1)
                var before: UInt64 = 0
                var c = nodes[Int(parent)].firstChild
                while c != 0 && c != child {
                    before &+= totals[Int(c)]
                    c = nodes[Int(c)].nextSibling
                }
                let span = hi - lo
                let start = lo + span * Float(Double(before) / Double(whole))
                hi = start + span * Float(Double(totals[Int(child)]) / Double(whole))
                lo = start
                parent = child
            }
            // What's big enough to see on the ring needs no tick. This is for what would otherwise be missed.
            if hi - lo > 0.09 { continue }
            let thinnest: Float = 0.0034
            if hi - lo < thinnest {
                let middle = (lo + hi) * 0.5
                lo = middle - thinnest / 2
                hi = middle + thinnest / 2
                let spot = Int(middle * 900) * 2 + (mark.planned ? 1 : 0)
                if !taken.insert(spot).inserted { continue }
            }
            let index = Int32(pieces.count)
            pieces.append(Piece(node: mark.node, tail: mark.node, key: Self.pathKey(tree, mark.node) ^ 0x3C3C_3C3C_3C3C, a0: lo, a1: hi,
                                r0: 1.018, r1: mark.planned ? 1.058 : 1.042, ring: 99, parent: -1, end: index + 1, isSmaller: false, smallerCount: 0,
                                color: mark.color, style: 5, seed: 0, bytes: 0, planned: mark.planned ? 1 : 0, isMark: true))
            added += 1
        }
    }

    @inline(__always) static func seed(_ id: UInt32) -> Float {
        let h = id &* 2654435761
        return Float(h >> 8 & 0xFFFF) / 65535
    }

    /// The piece under a point, given in polar form. Pieces come in depth-first order, so going down the rings skips
    /// whole subtrees at once.
    func hit(angle: Float, radius: Float) -> Int? {
        var i = 0
        while i < pieces.count {
            let p = pieces[i]
            if angle >= p.a0 && angle < p.a1 {
                if radius < p.r0 { return nil }
                if radius < p.r1 { return i }
                i += 1
            } else {
                i = Int(p.end)
            }
        }
        return nil
    }
}
