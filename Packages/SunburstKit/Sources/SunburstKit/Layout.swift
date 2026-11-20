import Foundation
import simd

/// How a piece is drawn. The shaders know these by number: see `StyleFree` and the others in `Shaders.metal`.
public enum PieceStyle: Float, Sendable {
    /// A folder, or anything else with things in it.
    case folder = 0
    /// Free space: a plain wedge, lit from inside.
    case free = 1
    /// Space nobody can look into: hatched.
    case hidden = 2
    /// What's too small to draw on its own, gathered at the end of its folder.
    case smaller = 3
    /// The end of a branch.
    case file = 4
    /// Something that isn't here any more but is shown where it was: faint.
    case ghost = 5
}

/// One drawn piece of the ring.
public struct Piece: Sendable {
    public var node: UInt32              // the node, or its parent for a "smaller items" piece
    public var tail: UInt32              // the deepest folder it stands for, when a chain like Media › TV is drawn as one
    public var key: UInt64               // the same on every scan, so a piece can glide from its old place to its new one
    public var a0: Float, a1: Float      // radians, clockwise from 12 o'clock
    public var r0: Float, r1: Float      // fractions of the ring's radius
    public var ring: Int32
    public var parent: Int32             // index of the piece it sits on, or -1
    public var end: Int32                // index after its last descendant
    public var isSmaller: Bool
    public var smallerCount: Int32       // how many things a "smaller items" piece stands for
    public var color: SIMD3<Float>
    public var style: PieceStyle
    public var seed: Float
    public var bytes: UInt64
    public var calm: Float = 0           // how far it steps back until you point at it
    public var planned: Float = 0        // 1 when it's marked: drawn striped
    public var deeper: Float = 0         // in the outermost ring, how much of it is in folders that aren't drawn, 0 to 1

    public var sweep: Float { a1 - a0 }
    public var midAngle: Float { (a0 + a1) * 0.5 }
}

/// How many rings the map draws and how thick they are.
public struct RingSizes: Equatable, Sendable {
    /// The most rings of folders the map draws, not counting the thin band around the whole disk. A picture never gets more
    /// than it can fill.
    public var depth = 6
    public var style = RingStyle.tapered

    /// The most rings there can be.
    public static let most = 12

    public init(depth: Int = 6, style: RingStyle = .tapered) {
        self.depth = depth
        self.style = style
    }
}

/// How thick each ring is, and which rings a picture can fill. Rings always get thinner going out, so far-out folders don't
/// look bigger than they are.
public enum RingStyle: String, CaseIterable, Sendable {
    /// The curve six rings have always had, stretched or squeezed to however many there are.
    case standard
    /// Each ring a fifth thinner than the one inside it, so the rings near the middle keep more of their room as rings are
    /// added. With many rings it eases off, so the outermost is never thinner than `thinnestTip` of the first.
    case tapered
    /// Each ring as thick as it's full, every ring with something in it, and a lip on folders in the outermost ring that go on.
    case adaptive

    /// Each ring's share of the room, from the middle out. `fill` is how far around each ring goes, as a share of the first.
    public func shares(count: Int, fill: [Float]) -> [Float] {
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
    public var leastFill: Float { self == .adaptive ? 0 : 0.03 }

    /// Whether folders in the outermost ring show that they go on.
    public var marksDeeper: Bool { self == .adaptive }

    /// A fifth thinner each time keeps five and six rings practically as they are in the standard curve. What changes is
    /// what more rings cost: the first ring keeps more of its room than in the standard curve, and the tips less.
    public static let taper: Float = 0.8
    /// The thinnest the outermost tapered ring gets, as a share of the first: about halfway between the standard curve and
    /// a fifth thinner all the way out, so the tips stay easy to read.
    public static let thinnestTip: Float = 0.3
    private static let sixRings: [Float] = [0.150, 0.128, 0.108, 0.090, 0.074, 0.060]
}

/// Turns part of a tree into pieces of a ring, sorted clockwise from 12 o'clock with the biggest first.
public struct RingLayout: Sendable {
    /// The middle, where the numbers go, as a share of the ring's radius.
    public static let hole: Float = 0.34
    /// The thin ring around the middle of the whole tree, when the tree has one (`SunburstTree.hasBand`). It keeps its width
    /// however many rings there are, and the rings of folders share out the rest.
    public static let band: Float = 0.029
    /// Pieces shorter than this at their ring's middle, in points on a typical window, merge into "smaller items".
    public static let minimumArc: Float = 2.2
    public static let typicalRadius: Float = 400
    /// A folder at least this share one subfolder is drawn together with it.
    public static let chainShare = 0.88

    public private(set) var pieces: [Piece] = []
    public var focus: UInt32 = 0
    /// How many rings of folders are drawn, and how many this picture could fill, up to the most there can be.
    public private(set) var rings = 0
    public private(set) var reach = 0

    /// What sets a piece's colour, in linear Display P3. The geometry is the same whatever the colours, so you keep your place.
    public typealias Colorer = (_ node: UInt32) -> SIMD3<Float>
    /// Whether a piece is marked, such as selected: it's drawn striped.
    public typealias Planner = (_ node: UInt32) -> Bool

    private var marksDeeper = false
    /// Whether the whole tree has its thin band around the middle.
    private var banded = true
    /// While measuring: how far around each ring goes, added up as the folders are gone through, with no piece made.
    private var around: [Float]?

    // Where things are in `pieces`, worked out once when the picture is made, so nothing has to search it.
    private var pieceOf: [UInt32: Int32] = [:]
    private var smallerIn: [Int32: Int32] = [:]
    /// The "smaller items" piece of the folder in view itself.
    public private(set) var outerSmaller: Int?
    /// The free space piece.
    public private(set) var freePiece: Int?

    public init() {}

    /// The piece that stands for a node: its own, or the one a chain like Media › TV is drawn as, for any folder in the chain.
    public func piece(of node: UInt32) -> Int? { pieceOf[node].map(Int.init) }

    /// The "smaller items" piece directly inside a piece.
    public func smallerPiece(in piece: Int) -> Int? { smallerIn[Int32(piece)].map(Int.init) }

    /// The piece for a node, or for the nearest folder above it that has one. Something too small to draw lights what holds it.
    public func nearestPiece<T: SunburstTree>(to node: UInt32, tree: T) -> Int? {
        var target = node
        while true {
            if let at = pieceOf[target] { return Int(at) }
            if target == 0 || target == focus { return nil }
            target = tree.parent(of: target)
        }
    }

    private mutating func indexPieces() {
        pieceOf = [UInt32: Int32](minimumCapacity: pieces.count)
        smallerIn = [:]
        outerSmaller = nil
        freePiece = nil
        for (at, p) in pieces.enumerated() {
            let at32 = Int32(at)
            if p.isSmaller {
                if p.parent >= 0 { smallerIn[p.parent] = at32 } else { outerSmaller = at }
            } else {
                if pieceOf[p.node] == nil { pieceOf[p.node] = at32 }
                if pieceOf[p.tail] == nil { pieceOf[p.tail] = at32 }
                if p.style == .free, freePiece == nil { freePiece = at }
            }
        }
    }

    /// The picture of `focus` and what's inside it. It gets as many rings as asked for, but never more than it can fill, so
    /// there's no empty ring around the edge.
    public static func build<T: SunburstTree>(tree: T, focus: UInt32, colorer: Colorer, planned: Planner? = nil,
                                              sizes: RingSizes = RingSizes()) -> RingLayout {
        let style = sizes.style
        let fill = fill(tree: tree, focus: focus, style: style)
        let reach = fill.prefix { $0 > 0 && $0 >= style.leastFill }.count
        let count = max(min(sizes.depth, reach), 1)
        var layout = draw(tree: tree, focus: focus, colorer: colorer, planned: planned,
                          shares: style.shares(count: count, fill: fill), marksDeeper: style.marksDeeper)
        layout.rings = count
        layout.reach = reach
        layout.indexPieces()
        return layout
    }

    /// How far around each ring would go with the most rings there can be, as the `fill` of that picture, without making the
    /// picture: this runs before every one that is made. With fewer rings, every ring sits further out, so each goes at
    /// least as far around then as it does here.
    public static func fill<T: SunburstTree>(tree: T, focus: UInt32, style: RingStyle) -> [Float] {
        // Adaptive rings are measured on the taper, the fixed curve nearest to them.
        let measuring: RingStyle = style == .standard ? .standard : .tapered
        let measured = draw(tree: tree, focus: focus, colorer: { _ in .zero }, planned: nil,
                            shares: measuring.shares(count: RingSizes.most, fill: []), marksDeeper: false, measuring: true)
        return shares(of: Array((measured.around ?? []).dropFirst(focus == 0 && tree.hasBand ? 1 : 0)))
    }

    /// The thinnest a ring gets: five points on a typical window, so it stays easy to see and to point at.
    public static let thinnest: Float = 5 / typicalRadius

    /// Shares of the room turned into widths that fill it, none thinner than `thinnest`.
    public static func widths(_ shares: [Float], filling room: Float) -> [Float] {
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
    /// the whole tree the band isn't counted.
    public var fill: [Float] {
        let first: Int32 = focus == 0 && banded ? 1 : 0
        var around: [Float] = []
        for p in pieces where p.ring >= first {
            let i = Int(p.ring - first)
            if i >= around.count { around += [Float](repeating: 0, count: i + 1 - around.count) }
            around[i] += p.sweep
        }
        return Self.shares(of: around)
    }

    private static func shares(of around: [Float]) -> [Float] {
        guard let whole = around.first, whole > 0 else { return [] }
        return around.map { $0 / whole }
    }

    private static func draw<T: SunburstTree>(tree: T, focus: UInt32, colorer: Colorer, planned: Planner?,
                                              shares: [Float], marksDeeper: Bool, measuring: Bool = false) -> RingLayout {
        var layout = RingLayout()
        layout.focus = focus
        layout.marksDeeper = marksDeeper
        if measuring { layout.around = [] } else { layout.pieces.reserveCapacity(4096) }
        let isRoot = focus == 0
        guard tree.size(of: focus) > 0 else { return layout }
        layout.banded = isRoot && tree.hasBand
        var edges: [Float] = [hole]
        if layout.banded { edges.append(hole + band) }
        for width in widths(shares, filling: 1 - edges[edges.count - 1]) { edges.append(edges[edges.count - 1] + width) }
        layout.place(tree, planner: planned, parentNode: focus, parentPiece: -1, parentKey: measuring ? 0 : pathKey(tree, focus),
                     a0: 0, a1: 2 * .pi, ring: 0, edges: edges, colorer: colorer)
        if layout.banded, !measuring { layout.reachLikeTheRest(tree, atLeast: edges[2]) }
        return layout
    }

    /// Tiny pieces step back until you point at them, so the big ones are easier to see.
    public mutating func calmTinyPieces(viewBytes: UInt64) {
        let total = Float(max(viewBytes, 1))
        for i in pieces.indices { pieces[i].calm = min(max(1 - Float(pieces[i].bytes) / total / 0.006, 0), 0.8) }
    }

    /// What's drawn directly inside a folder, once a folder that's nearly all one subfolder is drawn as one with it.
    public static func visibleChildren<T: SunburstTree>(tree: T, of parent: UInt32) -> (kids: [UInt32], tail: UInt32, ownBytes: UInt64) {
        @inline(__always) func total(_ id: UInt32) -> UInt64 { tree.size(of: id) }
        func listChildren(_ id: UInt32, into out: inout [UInt32]) {
            var c = tree.firstChild(of: id)
            while c != 0 {
                if total(c) > 0 { out.append(c) }
                c = tree.nextSibling(of: c)
            }
        }
        var kids: [UInt32] = []
        // Both halves are drawn, even one with nothing in it: an empty half says the folder isn't there.
        if parent == 0, tree.hasHalves {
            var c = tree.firstChild(of: 0)
            while c != 0 {
                if tree.isHalf(c) { kids.append(c) }
                c = tree.nextSibling(of: c)
            }
            return (kids, 0, 0)
        }
        listChildren(parent, into: &kids)
        var ownBytes = tree.ownSize(of: parent)
        var tail = parent
        var flattened = false
        guard parent != 0 else { return (kids, tail, ownBytes) }
        while !tree.isStillGrowing(tail), let topIndex = kids.indices.max(by: { total(kids[$0]) < total(kids[$1]) }) {
            let top = kids[topIndex]
            guard tree.isFolder(top), tree.firstChild(of: top) != 0,
                  Double(total(top)) >= Double(total(tail)) * chainShare else { break }
            kids.remove(at: topIndex)
            listChildren(top, into: &kids)
            ownBytes &+= tree.ownSize(of: top)
            tail = top
            flattened = true
        }
        if flattened { kids.sort { total($0) > total($1) } }
        return (kids, tail, ownBytes)
    }

    /// Whether a node draws as one with its biggest subfolder, and which one that ends at.
    public static func chainTail<T: SunburstTree>(tree: T, _ id: UInt32) -> UInt32 {
        guard id != 0 else { return id }
        var tail = id
        // While a folder is still being read, what looks like nearly all of it may turn out to be a small part.
        while !tree.isStillGrowing(tail) {
            var best: UInt32 = 0
            var c = tree.firstChild(of: tail)
            while c != 0 {
                if best == 0 || tree.size(of: c) > tree.size(of: best) { best = c }
                c = tree.nextSibling(of: c)
            }
            guard best != 0, tree.isFolder(best), tree.firstChild(of: best) != 0,
                  Double(tree.size(of: best)) >= Double(tree.size(of: tail)) * chainShare else { return tail }
            tail = best
        }
        return tail
    }

    /// A folder's key is made from the key of the folder it's in and its own name, so the names on the way down from the
    /// top are each read once for a whole picture, not once for every piece under them.
    @inline(__always) private static func key<T: SunburstTree>(_ tree: T, _ id: UInt32, in parentKey: UInt64) -> UInt64 {
        (parentKey &* 0x0000_0100_0000_01B3) ^ tree.nameKey(of: id)
    }

    /// The key of any node, from the top of the tree down to it.
    public static func pathKey<T: SunburstTree>(_ tree: T, _ id: UInt32) -> UInt64 {
        var path: [UInt32] = []
        var i = id
        while i != 0 {
            path.append(i)
            i = tree.parent(of: i)
        }
        return path.reversed().reduce(0xCBF2_9CE4_8422_2325) { key(tree, $1, in: $0) }
    }

    /// Plain shapes, such as free space, have nothing inside them drawn, so a fixed depth would make them look bigger or
    /// smaller than they are. They reach as far out as the rest of the tree does on average instead, so each covers the
    /// same share of the ring as of the whole.
    private mutating func reachLikeTheRest<T: SunburstTree>(_ tree: T, atLeast: Float) {
        func isOwnShape(_ p: Piece) -> Bool { p.ring == 0 && tree.isPlainShape(p.node) }
        var area: Float = 0, sweep: Float = 0
        for p in pieces where !isOwnShape(p) {
            area += p.sweep * (p.r1 * p.r1 - p.r0 * p.r0)
            if p.ring == 0 { sweep += p.sweep }
        }
        // With nothing else drawn yet, they are the whole tree between them and can fill the ring.
        let reach = sweep > 0 ? min(max((Self.hole * Self.hole + area / sweep).squareRoot(), atLeast), 1) : 1
        for i in pieces.indices where isOwnShape(pieces[i]) { pieces[i].r1 = reach }
    }

    /// How much of a folder is in folders inside it, rather than in files of its own.
    private static func folderShare<T: SunburstTree>(_ tree: T, of id: UInt32) -> Float {
        let inFolders = visibleChildren(tree: tree, of: id).kids
            .filter { tree.isFolder($0) }
            .reduce(UInt64(0)) { $0 &+ tree.size(of: $1) }
        return Float(Double(inFolders) / Double(max(tree.size(of: id), 1)))
    }

    /// What's in a folder in the order it's drawn: by the tree's own order when it has one, then biggest first.
    private static func ordered<T: SunburstTree>(_ tree: T, _ kids: [UInt32]) -> [UInt32] {
        guard tree.hasGroups else { return kids }
        return kids.sorted { x, y in
            let rx = tree.group(of: x) ?? .max, ry = tree.group(of: y) ?? .max
            return rx != ry ? rx < ry : tree.size(of: x) > tree.size(of: y)
        }
    }

    /// One stretch of a folder cut by the tree's order: the things in it, its share of the folder, and its colour, which is
    /// that of the first thing in it. The last stretch also holds what's too small to draw and the folder's own files.
    private struct Run {
        var kids: [UInt32]
        var bytes: UInt64
        var rest: UInt64 = 0
        var restCount: Int32 = 0
        var a0: Float = 0
        var a1: Float = 0
        var color: SIMD3<Float>
    }

    /// A folder's stretches, when the tree has an order and what's drawn inside the folder has more than one of it.
    private func runs<T: SunburstTree>(_ tree: T, of id: UInt32, a0: Float, a1: Float, childRing: Int, edges: [Float], colorer: Colorer) -> [Run]? {
        @inline(__always) func total(_ n: UInt32) -> UInt64 { tree.size(of: n) }
        let folder = total(id)
        guard folder > 0 else { return nil }
        let visible = Self.visibleChildren(tree: tree, of: id)
        let perByte = (a1 - a0) / Float(folder)
        let midArc = (edges[childRing] + edges[childRing + 1]) * 0.5 * Self.typicalRadius
        var runs: [Run] = []
        var rest = visible.ownBytes, restCount: Int32 = 0
        for kid in Self.ordered(tree, visible.kids) {
            let bytes = total(kid)
            if Float(bytes) * perByte * midArc < Self.minimumArc {
                rest &+= bytes
                restCount += 1
                continue
            }
            if let last = runs.last, let first = last.kids.first, tree.group(of: first) == tree.group(of: kid) {
                runs[runs.count - 1].kids.append(kid)
                runs[runs.count - 1].bytes &+= bytes
            } else {
                runs.append(Run(kids: [kid], bytes: bytes, color: colorer(kid)))
            }
        }
        guard runs.count > 1 else { return nil }
        runs[runs.count - 1].rest = rest
        runs[runs.count - 1].restCount = restCount
        runs[runs.count - 1].bytes &+= rest
        var at = a0
        for i in runs.indices {
            runs[i].a0 = at
            at += Float(runs[i].bytes) * perByte
            runs[i].a1 = at
        }
        runs[runs.count - 1].a1 = a1
        return runs
    }

    /// `parentKey` is the key of `parentNode`. `only`, with `rest`, draws part of a folder: one of its stretches.
    private mutating func place<T: SunburstTree>(_ tree: T, planner plannerNow: Planner?, parentNode: UInt32, parentPiece: Int32,
                                                 parentKey: UInt64, a0: Float, a1: Float, ring: Int, edges: [Float], colorer: Colorer,
                                                 only: [UInt32]? = nil, rest: UInt64 = 0, restCount: Int32 = 0) {
        guard ring + 1 < edges.count else { return }
        let measuring = around != nil
        @inline(__always) func total(_ id: UInt32) -> UInt64 { tree.size(of: id) }
        let parentTotal = only.map { $0.reduce(rest) { $0 &+ total($1) } } ?? total(parentNode)
        guard parentTotal > 0 else { return }
        let r0 = edges[ring], r1 = edges[ring + 1]
        let midArc = (r0 + r1) * 0.5 * Self.typicalRadius

        // A folder that is nearly all one subfolder would only repeat its shape on the next ring. Those chains are
        // drawn as one piece, so every ring shows something new.
        let visible = Self.visibleChildren(tree: tree, of: parentNode)
        var kids = only ?? visible.kids
        let ownBytes = only == nil ? visible.ownBytes : rest
        if only == nil, parentNode != 0 { kids = Self.ordered(tree, kids) }
        // What's drawn inside a chain is in the folder at its end, and keyed from there.
        var kidsKey = parentKey
        if parentNode != 0 {
            if visible.tail != parentNode, !measuring {
                if parentPiece >= 0 { pieces[Int(parentPiece)].tail = visible.tail }
                var chain: [UInt32] = []
                var link = visible.tail
                while link != parentNode, link != 0 {
                    chain.append(link)
                    link = tree.parent(of: link)
                }
                for link in chain.reversed() { kidsKey = Self.key(tree, link, in: kidsKey) }
            }
        } else if !tree.hasHalves {
            // Around the root, the host's ranks first: in a disk, free space closes the circle, right after what's hidden.
            kids.sort { x, y in
                let rx = tree.rootRank(of: x), ry = tree.rootRank(of: y)
                return rx != ry ? rx < ry : total(x) > total(y)
            }
        }

        let perByte = (a1 - a0) / Float(parentTotal)
        let halves = parentNode == 0 && tree.hasHalves
        var angle = a0
        var smallerBytes: UInt64 = 0
        var smallerCount: Int32 = only == nil ? 0 : restCount
        for id in kids {
            let bytes = total(id)
            let sweep = halves ? (a1 - a0) / Float(max(kids.count, 1)) : Float(bytes) * perByte
            let special = parentNode == 0
            if sweep * midArc < Self.minimumArc && !special {
                smallerBytes &+= bytes
                smallerCount += 1
                continue
            }
            let hasChildren = tree.firstChild(of: id) != 0
            if measuring {
                add(sweep, toRing: ring)
                if hasChildren, ring + 2 < edges.count {
                    place(tree, planner: nil, parentNode: id, parentPiece: -1, parentKey: 0, a0: angle, a1: angle + sweep, ring: ring + 1,
                          edges: edges, colorer: colorer)
                }
                angle += sweep
                continue
            }
            let index = Int32(pieces.count)
            let seed = Self.seed(id)
            let color = colorer(id)
            let style = tree.style(of: id)
            let key = Self.key(tree, id, in: kidsKey)
            // A folder whose contents are in more than one place is drawn as one stretch for each, over what it's made of.
            if tree.hasGroups, parentNode != 0, hasChildren, ring + 2 < edges.count,
               let runs = runs(tree, of: id, a0: angle, a1: angle + sweep, childRing: ring + 1, edges: edges, colorer: colorer) {
                let planned: Float = plannerNow?(id) == true ? 1 : 0
                for (r, run) in runs.enumerated() {
                    let at = Int32(pieces.count)
                    pieces.append(Piece(node: id, tail: id, key: key ^ (UInt64(r + 1) << 56), a0: run.a0, a1: run.a1, r0: r0, r1: r1,
                                        ring: Int32(ring), parent: parentPiece, end: at + 1, isSmaller: false, smallerCount: 0,
                                        color: run.color, style: style, seed: seed, bytes: run.bytes, planned: planned))
                    place(tree, planner: plannerNow, parentNode: id, parentPiece: at, parentKey: key, a0: run.a0, a1: run.a1, ring: ring + 1,
                          edges: edges, colorer: colorer, only: run.kids, rest: run.rest, restCount: run.restCount)
                    pieces[Int(at)].end = Int32(pieces.count)
                }
                angle += sweep
                continue
            }
            pieces.append(Piece(node: id, tail: id, key: key, a0: angle, a1: angle + sweep, r0: r0, r1: r1,
                                ring: Int32(ring), parent: parentPiece, end: index + 1, isSmaller: false, smallerCount: 0,
                                color: color, style: style, seed: seed, bytes: bytes, planned: plannerNow?(id) == true ? 1 : 0))
            if hasChildren {
                if ring + 2 < edges.count {
                    place(tree, planner: plannerNow, parentNode: id, parentPiece: index, parentKey: key, a0: angle, a1: angle + sweep,
                          ring: ring + 1, edges: edges, colorer: colorer)
                    pieces[Int(index)].end = Int32(pieces.count)
                } else if marksDeeper {
                    pieces[Int(index)].deeper = Self.folderShare(tree, of: id)
                }
            }
            angle += sweep
        }

        // What's left: the folder's own small files, and anything too thin to draw on its own.
        let rest = smallerBytes &+ (parentNode == 0 ? 0 : ownBytes)
        if rest > 0 && parentNode != 0 {
            let sweep = a1 - angle
            if sweep * midArc > 0.6, measuring {
                add(sweep, toRing: ring)
            } else if sweep * midArc > 0.6 {
                let seed = Self.seed(parentNode &* 31 &+ 7)
                let color = colorer(parentNode)
                let index = Int32(pieces.count)
                pieces.append(Piece(node: parentNode, tail: parentNode, key: parentKey ^ 0x5555_5555_5555 ^ (only == nil ? 0 : 0x77 << 48), a0: angle, a1: a1, r0: r0, r1: r1,
                                    ring: Int32(ring), parent: parentPiece, end: index + 1, isSmaller: true, smallerCount: smallerCount,
                                    color: color, style: .smaller, seed: seed, bytes: rest, planned: plannerNow?(parentNode) == true ? 1 : 0))
            }
        }
    }

    private mutating func add(_ sweep: Float, toRing ring: Int) {
        if ring >= around!.count { around! += [Float](repeating: 0, count: ring + 1 - around!.count) }
        around![ring] += sweep
    }

    @inline(__always) public static func seed(_ id: UInt32) -> Float {
        let h = id &* 2654435761
        return Float(h >> 8 & 0xFFFF) / 65535
    }

    /// The piece under a point, given in polar form. Pieces come in depth-first order, so going down the rings skips
    /// whole subtrees at once.
    public func hit(angle: Float, radius: Float) -> Int? {
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
