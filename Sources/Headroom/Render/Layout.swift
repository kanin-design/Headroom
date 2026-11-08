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
    var deeper: Float = 0         // in the outermost ring, how much of it is in folders that aren't drawn, 0 to 1

    var sweep: Float { a1 - a0 }
    var midAngle: Float { (a0 + a1) * 0.5 }
}

/// How many rings the map draws and how thick they are, picked in View › Rings and kept for the next launch. For one run
/// only: `--args -ringDepth 8 -ringStyle adaptive`.
struct RingSizes: Equatable {
    /// The most rings of folders the map draws, not counting the thin band around the whole disk. A picture never gets more
    /// than it can fill.
    var depth = 6
    var style = RingStyle.tapered

    /// The most rings there can be.
    static let most = 12

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

/// How thick each ring is, and which rings a picture can fill. Rings always get thinner going out, so far-out folders don't
/// look bigger than they are.
enum RingStyle: String, CaseIterable {
    /// The curve six rings have always had, stretched or squeezed to however many there are.
    case standard
    /// Each ring a fifth thinner than the one inside it, so the rings near the middle keep more of their room as rings are
    /// added. With many rings it eases off, so the outermost is never thinner than `thinnestTip` of the first.
    case tapered
    /// Each ring as thick as it's full, every ring with something in it, and a lip on folders in the outermost ring that go on.
    case adaptive

    /// Each ring's share of the room, from the middle out. `fill` is how far around each ring goes, as a share of the first.
    func shares(count: Int, fill: [Float]) -> [Float] {
        switch self {
        case .standard:
            let last = Float(Self.sixRings.count - 1)
            return (0..<count).map { k in
                let x = count > 1 ? Float(k) * last / Float(count - 1) : 0
                let i = min(Int(x), Self.sixRings.count - 2)
                return Self.sixRings[i] + (Self.sixRings[i + 1] - Self.sixRings[i]) * (x - Float(i))
            }
        case .tapered:
            let step = count > 1 ? max(Self.taper, pow(Self.thinnestTip, 1 / Float(count - 1))) : 1
            return (0..<count).map { pow(step, Float($0)) }
        case .adaptive:
            return (0..<count).map { $0 < fill.count ? fill[$0] : 1 }
        }
    }

    /// The least a ring has to go around, as a share of the first, to be drawn. Less is a sliver or two in an empty ring,
    /// though a few thin spokes count: they show which folders go deeper. Adaptive rings draw every ring with something in
    /// it, since one that's nearly empty is thin.
    var leastFill: Float { self == .adaptive ? 0 : 0.03 }

    /// Whether folders in the outermost ring show that they go on.
    var marksDeeper: Bool { self == .adaptive }

    /// A fifth thinner each time keeps five and six rings practically as they are in the standard curve. What changes is
    /// what more rings cost: the first ring keeps more of its room than in the standard curve, and the tips less.
    static let taper: Float = 0.8
    /// The thinnest the outermost tapered ring gets, as a share of the first: about halfway between the standard curve and
    /// a fifth thinner all the way out, so the tips stay easy to read.
    static let thinnestTip: Float = 0.3
    private static let sixRings: [Float] = [0.150, 0.128, 0.108, 0.090, 0.074, 0.060]
}

/// Turns part of the tree into pieces of a ring, sorted clockwise from 12 o'clock with the biggest first.
struct RingLayout {
    /// The middle, where the numbers go, as a share of the ring's radius.
    static let hole: Float = 0.34
    /// The thin ring around the middle of the whole disk, which splits it into what's on it, what's hidden and what's
    /// free. It keeps its width however many rings there are, and the rings of folders share out the rest.
    static let band: Float = 0.029
    /// Pieces shorter than this at their ring's middle, in points on a typical window, merge into "smaller items".
    static let minimumArc: Float = 2.2
    static let typicalRadius: Float = 400
    /// A folder at least this share one subfolder is drawn together with it.
    static let chainShare = 0.88

    var pieces: [Piece] = []
    var focus: UInt32 = 0
    /// How many rings of folders are drawn, and how many this picture could fill, up to the most there can be.
    private(set) var rings = 0
    private(set) var reach = 0

    /// What sets a piece's colour. The geometry is the same in every view, so you keep your place.
    typealias Colorer = (_ node: UInt32) -> SIMD3<Float>
    /// Whether a piece goes at the next clean.
    typealias Planner = (_ node: UInt32) -> Bool

    private var planner: Planner?
    private var after: AfterPlan?
    private var marksDeeper = false

    /// `after` draws the picture as it will be once the plan has run. It gets as many rings as asked for, but never more
    /// than it can fill, so there's no empty ring around the edge.
    static func build(tree: DiskTree, focus: UInt32, colorer: Colorer, planned: Planner? = nil, after: AfterPlan? = nil,
                      sizes: RingSizes = .saved) -> RingLayout {
        let style = sizes.style
        let fill = measure(tree: tree, focus: focus, after: after, style: style).fill
        let reach = fill.prefix { $0 > 0 && $0 >= style.leastFill }.count
        let count = max(min(sizes.depth, reach), 1)
        var layout = draw(tree: tree, focus: focus, colorer: colorer, planned: planned, after: after,
                          shares: style.shares(count: count, fill: fill), marksDeeper: style.marksDeeper)
        layout.rings = count
        layout.reach = reach
        return layout
    }

    /// The picture with the most rings there can be, for measuring how far around each ring goes. With fewer rings, every
    /// ring sits further out, so each goes at least as far around then as it does here.
    static func measure(tree: DiskTree, focus: UInt32, after: AfterPlan? = nil, style: RingStyle) -> RingLayout {
        // Adaptive rings are measured on the taper, the fixed curve nearest to them.
        let measuring: RingStyle = style == .standard ? .standard : .tapered
        return draw(tree: tree, focus: focus, colorer: { _ in .zero }, planned: nil, after: after,
                    shares: measuring.shares(count: RingSizes.most, fill: []), marksDeeper: false)
    }

    /// The thinnest a ring gets: five points on a typical window, so it stays easy to see and to point at.
    static let thinnest: Float = 5 / typicalRadius

    /// Shares of the room turned into widths that fill it, none thinner than `thinnest`.
    static func widths(_ shares: [Float], filling room: Float) -> [Float] {
        var thin = [Bool](repeating: false, count: shares.count)
        while true {
            let rest = zip(shares, thin).filter { !$0.1 }.map(\.0).reduce(0, +)
            let scale = (room - thinnest * Float(thin.filter { $0 }.count)) / max(rest, .leastNonzeroMagnitude)
            let widths = zip(shares, thin).map { $0.1 ? thinnest : $0.0 * scale }
            let tooThin = widths.indices.filter { !thin[$0] && widths[$0] < thinnest }
            if tooThin.isEmpty || tooThin.count == thin.filter({ !$0 }).count { return widths }
            for i in tooThin { thin[i] = true }
        }
    }

    /// How far around each ring of folders goes, from the first ring out, as a share of how far the first one goes. Around
    /// the whole disk the band isn't counted.
    var fill: [Float] {
        let first: Int32 = focus == 0 ? 1 : 0
        var around: [Float] = []
        for p in pieces where p.ring >= first {
            let i = Int(p.ring - first)
            if i >= around.count { around += [Float](repeating: 0, count: i + 1 - around.count) }
            around[i] += p.sweep
        }
        guard let whole = around.first, whole > 0 else { return [] }
        return around.map { $0 / whole }
    }

    private static func draw(tree: DiskTree, focus: UInt32, colorer: Colorer, planned: Planner?, after: AfterPlan?,
                             shares: [Float], marksDeeper: Bool) -> RingLayout {
        var layout = RingLayout()
        layout.focus = focus
        layout.planner = planned
        layout.after = after
        layout.marksDeeper = marksDeeper
        layout.pieces.reserveCapacity(4096)
        let isRoot = focus == 0
        guard (after?.size(focus) ?? tree.totals[Int(focus)]) > 0 else { return layout }
        var edges: [Float] = [hole]
        if isRoot { edges.append(hole + band) }
        for width in widths(shares, filling: 1 - edges[edges.count - 1]) { edges.append(edges[edges.count - 1] + width) }
        layout.place(tree, parentNode: focus, parentPiece: -1, a0: 0, a1: 2 * .pi, ring: 0, edges: edges, colorer: colorer)
        if isRoot { layout.reachLikeTheRest(free: tree.free, hidden: tree.hidden, atLeast: edges[2]) }
        return layout
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
                let end = max(Int(p.end), i + 1)
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
        for (at, p) in pieces.enumerated() {
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
                return tree.isInside(p.node, top) || tree.isInside(p.tail, top)
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
        if let best = found.full.map(\.lowerBound).max(by: { pieces[$0].bytes < pieces[$1].bytes }) { return best }
        return found.holding.max { pieces[$0].r0 < pieces[$1].r0 }
    }

    /// Tiny pieces step back until you point at them, so the big ones are easier to see.
    mutating func calmTinyPieces(viewBytes: UInt64) {
        let total = Float(max(viewBytes, 1))
        for i in pieces.indices { pieces[i].calm = min(max(1 - Float(pieces[i].bytes) / total / 0.006, 0), 0.8) }
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
        for p in pieces where !isOwnShape(p) {
            area += p.sweep * (p.r1 * p.r1 - p.r0 * p.r0)
            if p.ring == 0 { sweep += p.sweep }
        }
        // With nothing else drawn yet, they are the whole disk between them and can fill the ring.
        let reach = sweep > 0 ? min(max((Self.hole * Self.hole + area / sweep).squareRoot(), atLeast), 1) : 1
        for i in pieces.indices where isOwnShape(pieces[i]) { pieces[i].r1 = reach }
    }

    /// How much of a folder is in folders inside it, rather than in files of its own.
    private static func folderShare(_ tree: DiskTree, of id: UInt32, after: AfterPlan?) -> Float {
        @inline(__always) func total(_ node: UInt32) -> UInt64 { after?.size(node) ?? tree.totals[Int(node)] }
        let inFolders = visibleChildren(tree: tree, of: id, after: after).kids
            .filter { tree.nodes[Int($0)].has(NodeFlag.directory) }
            .reduce(UInt64(0)) { $0 &+ total($1) }
        return Float(Double(inFolders) / Double(max(total(id), 1)))
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
                if ring + 2 < edges.count {
                    place(tree, parentNode: id, parentPiece: index, a0: angle, a1: angle + sweep, ring: ring + 1, edges: edges, colorer: colorer)
                    pieces[Int(index)].end = Int32(pieces.count)
                } else if marksDeeper {
                    pieces[Int(index)].deeper = Self.folderShare(tree, of: id, after: after)
                }
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
