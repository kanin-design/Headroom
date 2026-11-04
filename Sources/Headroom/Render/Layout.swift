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

    /// What sets a piece's colour. The geometry is the same in every view, so you keep your place.
    typealias Colorer = (_ node: UInt32) -> SIMD3<Float>

    static func build(tree: DiskTree, focus: UInt32, colorer: Colorer) -> RingLayout {
        var layout = RingLayout()
        layout.focus = focus
        layout.pieces.reserveCapacity(4096)
        let isRoot = focus == 0
        guard tree.totals[Int(focus)] > 0 else { return layout }
        var edges: [Float] = [hole]
        if isRoot { edges.append(hole + bandWidth) }
        for w in ringWidths { edges.append(edges[edges.count - 1] + w) }
        let scale = (1.0 - hole) / (edges[edges.count - 1] - hole)
        edges = edges.map { hole + ($0 - hole) * scale }
        layout.place(tree, parentNode: focus, parentPiece: -1, a0: 0, a1: 2 * .pi, ring: 0, edges: edges, colorer: colorer)

        // A shallow folder gets thicker rings, so the picture fills the same space and every level is easier to see.
        if !isRoot, let deepest = layout.pieces.map(\.ring).max(), Int(deepest) + 2 < edges.count {
            let used = Int(deepest) + 1
            let current = edges[used] - hole
            let stretch = min((1 - hole) / current, 1.9)
            edges = edges.prefix(used + 1).map { hole + ($0 - hole) * stretch }
            layout.pieces.removeAll(keepingCapacity: true)
            layout.place(tree, parentNode: focus, parentPiece: -1, a0: 0, a1: 2 * .pi, ring: 0, edges: edges, colorer: colorer)
        }
        return layout
    }

    /// Tiny pieces step back until you point at them, so the big ones are easier to see.
    mutating func calmTinyPieces(viewBytes: UInt64) {
        let total = Float(max(viewBytes, 1))
        for i in pieces.indices { pieces[i].calm = min(max(1 - Float(pieces[i].bytes) / total / 0.006, 0), 0.8) }
    }

    /// What's drawn directly inside a folder, once a folder that's nearly all one subfolder is drawn as one with it.
    static func visibleChildren(tree: DiskTree, of parent: UInt32) -> (kids: [UInt32], tail: UInt32, ownBytes: UInt64) {
        let nodes = tree.nodes, totals = tree.totals
        func listChildren(_ id: UInt32, into out: inout [UInt32]) {
            var c = nodes[Int(id)].firstChild
            while c != 0 {
                if totals[Int(c)] > 0 { out.append(c) }
                c = nodes[Int(c)].nextSibling
            }
        }
        var kids: [UInt32] = []
        listChildren(parent, into: &kids)
        var ownBytes = nodes[Int(parent)].bytes
        var tail = parent
        var flattened = false
        guard parent != 0 else { return (kids, tail, ownBytes) }
        while !tree.isStillGrowing(tail), let topIndex = kids.indices.max(by: { totals[Int(kids[$0])] < totals[Int(kids[$1])] }) {
            let top = kids[topIndex]
            let n = nodes[Int(top)]
            guard n.has(NodeFlag.directory), n.firstChild != 0,
                  Double(totals[Int(top)]) >= Double(totals[Int(tail)]) * chainShare else { break }
            kids.remove(at: topIndex)
            listChildren(top, into: &kids)
            ownBytes &+= n.bytes
            tail = top
            flattened = true
        }
        if flattened { kids.sort { totals[Int($0)] > totals[Int($1)] } }
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

    private mutating func place(_ tree: DiskTree, parentNode: UInt32, parentPiece: Int32,
                                a0: Float, a1: Float, ring: Int, edges: [Float], colorer: Colorer) {
        guard ring + 1 < edges.count else { return }
        let totals = tree.totals
        let parentTotal = totals[Int(parentNode)]
        guard parentTotal > 0 else { return }
        let nodes = tree.nodes
        let r0 = edges[ring], r1 = edges[ring + 1]
        let midArc = (r0 + r1) * 0.5 * Self.typicalRadius

        // A folder that is nearly all one subfolder would only repeat its shape on the next ring. Those chains are
        // drawn as one piece, so every ring shows something new.
        let visible = Self.visibleChildren(tree: tree, of: parentNode)
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
                return rx != ry ? rx < ry : totals[Int(x)] > totals[Int(y)]
            }
        }

        let perByte = (a1 - a0) / Float(parentTotal)
        var angle = a0
        var smallerBytes: UInt64 = 0
        var smallerCount: Int32 = 0
        for id in kids {
            let bytes = totals[Int(id)]
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
            // Free space runs the full depth of the ring: it's a real shape, the thing that grows when you clean up.
            // What's hidden goes a little way out, so it can't be mistaken for free.
            var outer = r1
            if id == tree.free { outer = 1 }
            else if id == tree.hidden { outer = edges[min(ring + 3, edges.count - 1)] }
            pieces.append(Piece(node: id, tail: id, key: Self.pathKey(tree, id), a0: angle, a1: angle + sweep, r0: r0, r1: outer,
                                ring: Int32(ring), parent: parentPiece, end: index + 1, isSmaller: false, smallerCount: 0,
                                color: color, style: style, seed: seed, bytes: bytes))
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
                                    color: color, style: 3, seed: seed, bytes: rest))
            }
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
