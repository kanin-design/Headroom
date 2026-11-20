import Foundation
import simd

/// How a piece is drawn. The shaders know these by number: see `StyleFree` and the others in `Shaders.metal`.
public enum PieceStyle: Float, Sendable {
    /// Something with things in it, such as a folder: shaded from deep at the root to bright at the edge.
    case folder = 0
    /// Room that isn't used, such as free space on a disk: a plain wedge, nearly empty, with a fine edge.
    case free = 1
    /// Something that's there but can't be looked into: hatched.
    case hidden = 2
    /// What's too small to draw on its own, gathered at the end of what holds it, in its colour but quieter.
    case smaller = 3
    /// The end of a branch, such as a file.
    case file = 4
    /// Something that isn't here any more, shown where it was: its colour, nearly empty inside, with a clear outline.
    case ghost = 5
    /// Something being shared, such as a file a torrent is seeding: drawn as a folder or file is, with a bright dashed line
    /// along its outer edge.
    case shared = 6
}

/// One drawn piece of the ring. Pieces are listed depth first: a piece's descendants follow it, up to `end`.
public struct Piece: Sendable {
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
    /// Which ring it's in, from the middle out.
    public var ring: Int32
    /// The index of the piece it sits on, or -1 in the first ring.
    public var parent: Int32
    /// The index after its last descendant.
    public var end: Int32
    /// Whether it gathers what's too small to draw on its own.
    public var isSmaller: Bool
    /// How many things a "smaller items" piece stands for.
    public var smallerCount: Int32
    /// Its colour, in linear Display P3.
    public var color: SIMD3<Float>
    public var style: PieceStyle
    /// A number from 0 to 1 that tells neighbours apart.
    public var seed: Float
    /// The size it's drawn for: the node's size, or what a "smaller items" piece gathers.
    public var size: UInt64
    /// How far it steps back until it's pointed at, from 0 to 0.8. See `RingLayout.calmTinyPieces(total:)`.
    public var calm: Float = 0
    /// 1 when it's marked: drawn striped.
    public var marked: Float = 0
    /// In the outermost ring, how much of it is in rings that aren't drawn, from 0 to 1. It fades out past its edge by that much.
    public var deeper: Float = 0

    /// How far around it goes, in radians.
    public var sweep: Float { a1 - a0 }
    /// The angle of its middle.
    public var midAngle: Float { (a0 + a1) * 0.5 }

    @usableFromInline
    init(node: UInt32, tail: UInt32, key: UInt64, a0: Float, a1: Float, r0: Float, r1: Float, ring: Int32, parent: Int32, end: Int32,
         isSmaller: Bool, smallerCount: Int32, color: SIMD3<Float>, style: PieceStyle, seed: Float, size: UInt64, marked: Float = 0) {
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
        self.style = style
        self.seed = seed
        self.size = size
        self.marked = marked
    }
}

/// How many rings a picture draws and how thick they are.
public struct RingSizes: Equatable, Sendable {
    /// The most rings a picture draws, not counting the thin band around the whole tree. A picture never gets more than it
    /// can fill.
    public var depth = 6
    /// How thick each ring is.
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
///
/// The layout is generic over the host's tree and `@inlinable`, so the host's own build specialises it for its tree, and it
/// runs as fast as code written for that tree.
public struct RingLayout: Sendable {
    /// The middle, where the numbers go, as a share of the ring's radius.
    public static let hole: Float = 0.34
    /// The thin ring around the middle of the whole tree, when the tree has one (`SunburstTree.hasBand`). It keeps its width
    /// however many rings there are, and the rings of folders share out the rest.
    public static let band: Float = 0.029
    /// Pieces shorter than this at their ring's middle, in points on a typical window, merge into "smaller items".
    public static let minimumArc: Float = 2.2
    /// The radius, in points, that sizes in points above are measured on.
    public static let typicalRadius: Float = 400
    /// A folder at least this share one subfolder is drawn together with it.
    public static let chainShare = 0.88

    /// The pieces, depth first.
    public var pieces: [Piece] { _pieces }
    @usableFromInline var _pieces: [Piece] = []
    /// The node in the middle.
    public var focus: UInt32 = 0
    /// How many rings are drawn.
    public var rings: Int { _rings }
    @usableFromInline var _rings = 0
    /// How many rings this picture could fill, up to the most there can be.
    public var reach: Int { _reach }
    @usableFromInline var _reach = 0

    /// What sets a piece's colour, in linear Display P3. The geometry is the same whatever the colours, so you keep your place.
    public typealias Colorer = (_ node: UInt32) -> SIMD3<Float>
    /// Whether a piece is marked, such as selected: it's drawn striped.
    public typealias Marker = (_ node: UInt32) -> Bool

    @usableFromInline var marksDeeper = false
    /// Whether the whole tree has its thin band around the middle.
    @usableFromInline var banded = true
    /// While measuring: how far around each ring goes, added up as the folders are gone through, with no piece made.
    @usableFromInline var around: [Float]?

    // Where things are in `pieces`, worked out once when the picture is made, so nothing has to search it.
    @usableFromInline var pieceOf: [UInt32: Int32] = [:]
    /// The folders between the ends of each chain, and the piece the chain is drawn as.
    @usableFromInline var chainLinks: [(node: UInt32, piece: Int32)] = []
    @usableFromInline var smallerIn: [Int32: Int32] = [:]
    /// The "smaller items" piece of the node in the middle itself.
    public var outerSmaller: Int? { _outerSmaller }
    @usableFromInline var _outerSmaller: Int?
    /// The piece drawn in the free style, if there is one.
    public var freePiece: Int? { _freePiece }
    @usableFromInline var _freePiece: Int?

    public init() {}

    /// The piece that stands for a node: its own, or the one a chain like Media › TV is drawn as, for any folder in the chain.
    public func piece(of node: UInt32) -> Int? { pieceOf[node].map(Int.init) }

    /// The pieces a piece's node is drawn as side by side: just the piece, unless the tree cuts the node into stretches
    /// (`SunburstTree.stretches(of:)`).
    public func stretches(around piece: Int) -> ClosedRange<Int> {
        let p = _pieces[piece]
        guard !p.isSmaller else { return piece...piece }
        func same(_ i: Int) -> Bool {
            let q = _pieces[i]
            return q.node == p.node && q.ring == p.ring && q.parent == p.parent && !q.isSmaller
        }
        var first = piece, last = piece
        while first > 0, same(first - 1) { first -= 1 }
        while last + 1 < _pieces.count, same(last + 1) { last += 1 }
        return first...last
    }

    /// Everything a piece stands for, as a range of `pieces`: its node's piece or stretches, and everything drawn inside.
    public func extent(of piece: Int) -> Range<Int> {
        let span = stretches(around: piece)
        guard span.count > 1 else { return piece..<max(Int(_pieces[piece].end), piece + 1) }
        var end = span.upperBound + 1
        while end < _pieces.count, span.contains(Int(_pieces[end].parent)) { end = max(Int(_pieces[end].end), end + 1) }
        return span.lowerBound..<end
    }

    /// The "smaller items" piece directly inside a piece.
    public func smallerPiece(in piece: Int) -> Int? { smallerIn[Int32(piece)].map(Int.init) }

    /// The piece for a node, or for the nearest folder above it that has one. Something too small to draw lights what holds it.
    @inlinable
    public func nearestPiece<T: SunburstTree>(to node: UInt32, tree: T) -> Int? {
        var target = node
        while true {
            if let at = pieceOf[target] { return Int(at) }
            if target == 0 || target == focus { return nil }
            target = tree.parent(of: target)
        }
    }

    @usableFromInline
    mutating func indexPieces() {
        pieceOf = [UInt32: Int32](minimumCapacity: _pieces.count)
        smallerIn = [:]
        _outerSmaller = nil
        _freePiece = nil
        for (at, p) in _pieces.enumerated() {
            let at32 = Int32(at)
            if p.isSmaller {
                if p.parent >= 0 { smallerIn[p.parent] = at32 } else { _outerSmaller = at }
            } else {
                if pieceOf[p.node] == nil { pieceOf[p.node] = at32 }
                if pieceOf[p.tail] == nil { pieceOf[p.tail] = at32 }
                if p.style == .free, _freePiece == nil { _freePiece = at }
            }
        }
        for link in chainLinks where pieceOf[link.node] == nil { pieceOf[link.node] = link.piece }
    }

    /// The picture of `focus` and what's inside it. It gets as many rings as asked for, but never more than it can fill, so
    /// there's no empty ring around the edge. `colorer` colours each piece; `marked` says which are drawn striped.
    @inlinable
    public static func build<T: SunburstTree>(tree: T, focus: UInt32, colorer: Colorer, marked: Marker? = nil,
                                              sizes: RingSizes = RingSizes()) -> RingLayout {
        let style = sizes.style
        let fill = fill(tree: tree, focus: focus, style: style)
        let reach = fill.prefix { $0 > 0 && $0 >= style.leastFill }.count
        let count = max(min(sizes.depth, reach), 1)
        var layout = draw(tree: tree, focus: focus, colorer: colorer, marker: marked,
                          shares: style.shares(count: count, fill: fill), marksDeeper: style.marksDeeper)
        layout._rings = count
        layout._reach = reach
        layout.indexPieces()
        return layout
    }

    /// How far around each ring would go with the most rings there can be, as the `fill` of that picture, without making the
    /// picture: this runs before every one that is made. With fewer rings, every ring sits further out, so each goes at
    /// least as far around then as it does here.
    @inlinable
    public static func fill<T: SunburstTree>(tree: T, focus: UInt32, style: RingStyle) -> [Float] {
        // Adaptive rings are measured on the taper, the fixed curve nearest to them.
        let measuring: RingStyle = style == .standard ? .standard : .tapered
        let measured = draw(tree: tree, focus: focus, colorer: { _ in .zero }, marker: nil,
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
        for p in _pieces where p.ring >= first {
            let i = Int(p.ring - first)
            if i >= around.count { around += [Float](repeating: 0, count: i + 1 - around.count) }
            around[i] += p.sweep
        }
        return Self.shares(of: around)
    }

    @usableFromInline
    static func shares(of around: [Float]) -> [Float] {
        guard let whole = around.first, whole > 0 else { return [] }
        return around.map { $0 / whole }
    }

    @inlinable
    static func draw<T: SunburstTree>(tree: T, focus: UInt32, colorer: Colorer, marker: Marker?,
                                      shares: [Float], marksDeeper: Bool, measuring: Bool = false) -> RingLayout {
        var layout = RingLayout()
        layout.focus = focus
        layout.marksDeeper = marksDeeper
        if measuring { layout.around = [] } else { layout._pieces.reserveCapacity(4096) }
        let isRoot = focus == 0
        guard tree.size(of: focus) > 0 else { return layout }
        layout.banded = isRoot && tree.hasBand
        var edges: [Float] = [hole]
        if layout.banded { edges.append(hole + band) }
        for width in widths(shares, filling: 1 - edges[edges.count - 1]) { edges.append(edges[edges.count - 1] + width) }
        layout.place(tree, marker: marker, parentNode: focus, parentPiece: -1, parentKey: measuring ? 0 : pathKey(tree, focus),
                     a0: 0, a1: 2 * .pi, ring: 0, edges: edges, colorer: colorer)
        if layout.banded, !measuring { layout.reachLikeTheRest(tree, atLeast: edges[2]) }
        return layout
    }

    /// Tiny pieces step back until you point at them, so the big ones are easier to see. `total` is the size of the node in
    /// the middle; a piece under 0.6% of it steps back, the smaller the further.
    public mutating func calmTinyPieces(total: UInt64) {
        let whole = Float(max(total, 1))
        for i in _pieces.indices { _pieces[i].calm = min(max(1 - Float(_pieces[i].size) / whole / 0.006, 0), 0.8) }
    }

    /// What's drawn directly inside a folder, once a folder that's nearly all one subfolder is drawn as one with it.
    @inlinable
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
    @inlinable
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
    @inlinable @inline(__always)
    static func key<T: SunburstTree>(_ tree: T, _ id: UInt32, in parentKey: UInt64) -> UInt64 {
        (parentKey &* 0x0000_0100_0000_01B3) ^ tree.nameKey(of: id)
    }

    /// The key of any node, from the top of the tree down to it.
    @inlinable
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
    @inlinable
    mutating func reachLikeTheRest<T: SunburstTree>(_ tree: T, atLeast: Float) {
        func isOwnShape(_ p: Piece) -> Bool { p.ring == 0 && tree.isPlainShape(p.node) }
        var area: Float = 0, sweep: Float = 0
        for p in _pieces where !isOwnShape(p) {
            area += p.sweep * (p.r1 * p.r1 - p.r0 * p.r0)
            if p.ring == 0 { sweep += p.sweep }
        }
        // With nothing else drawn yet, they are the whole tree between them and can fill the ring.
        let reach = sweep > 0 ? min(max((Self.hole * Self.hole + area / sweep).squareRoot(), atLeast), 1) : 1
        for i in _pieces.indices where isOwnShape(_pieces[i]) { _pieces[i].r1 = reach }
    }

    /// How much of a folder is in folders inside it, rather than in files of its own.
    @inlinable
    static func folderShare<T: SunburstTree>(_ tree: T, of id: UInt32) -> Float {
        let inFolders = visibleChildren(tree: tree, of: id).kids
            .filter { tree.isFolder($0) }
            .reduce(UInt64(0)) { $0 &+ tree.size(of: $1) }
        return Float(Double(inFolders) / Double(max(tree.size(of: id), 1)))
    }

    /// What's in a folder in the order it's drawn: by the tree's own order when it has one, then biggest first. Things of
    /// the same size keep the order the tree lists them in, such as by name.
    @inlinable
    static func ordered<T: SunburstTree>(_ tree: T, _ kids: [UInt32]) -> [UInt32] {
        guard tree.hasGroups else { return kids }
        return kids.enumerated().sorted { x, y in
            let rx = tree.group(of: x.element) ?? .max, ry = tree.group(of: y.element) ?? .max
            if rx != ry { return rx < ry }
            let sx = tree.size(of: x.element), sy = tree.size(of: y.element)
            return sx != sy ? sx > sy : x.offset < y.offset
        }.map(\.element)
    }

    /// One stretch of a folder cut by the tree's order: the things in it, its share of the folder, and its colour, which is
    /// that of the first thing in it. The last stretch also holds what's too small to draw and the folder's own files.
    @usableFromInline
    struct Run {
        @usableFromInline var kids: [UInt32]
        @usableFromInline var bytes: UInt64
        @usableFromInline var rest: UInt64 = 0
        @usableFromInline var restCount: Int32 = 0
        @usableFromInline var a0: Float = 0
        @usableFromInline var a1: Float = 0
        @usableFromInline var color: SIMD3<Float>

        @inlinable
        init(kids: [UInt32], bytes: UInt64, color: SIMD3<Float>) {
            self.kids = kids
            self.bytes = bytes
            self.color = color
        }
    }

    /// A folder's stretches, when the tree has an order and what's drawn inside the folder has more than one of it.
    @inlinable
    func runs<T: SunburstTree>(_ tree: T, of id: UInt32, a0: Float, a1: Float, childRing: Int, edges: [Float], colorer: Colorer) -> [Run]? {
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
            if Float(bytes) * perByte * midArc < Self.minimumArc && !tree.isAlwaysDrawn(kid) {
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
    @inlinable
    mutating func place<T: SunburstTree>(_ tree: T, marker: Marker?, parentNode: UInt32, parentPiece: Int32,
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
                if parentPiece >= 0 { _pieces[Int(parentPiece)].tail = visible.tail }
                var chain: [UInt32] = []
                var link = visible.tail
                while link != parentNode, link != 0 {
                    chain.append(link)
                    link = tree.parent(of: link)
                }
                for link in chain.reversed() { kidsKey = Self.key(tree, link, in: kidsKey) }
                if parentPiece >= 0 { for link in chain { chainLinks.append((link, parentPiece)) } }
            }
        } else if !tree.hasHalves {
            // Around the root, the host's ranks first: in a disk, free space closes the circle, right after what's hidden.
            kids = kids.enumerated().sorted { x, y in
                let rx = tree.rootRank(of: x.element), ry = tree.rootRank(of: y.element)
                if rx != ry { return rx < ry }
                let sx = total(x.element), sy = total(y.element)
                return sx != sy ? sx > sy : x.offset < y.offset
            }.map(\.element)
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
            if sweep * midArc < Self.minimumArc && !special && !tree.isAlwaysDrawn(id) {
                smallerBytes &+= bytes
                smallerCount += 1
                continue
            }
            let hasChildren = tree.firstChild(of: id) != 0
            if measuring {
                add(sweep, toRing: ring)
                if hasChildren, ring + 2 < edges.count {
                    place(tree, marker: nil, parentNode: id, parentPiece: -1, parentKey: 0, a0: angle, a1: angle + sweep, ring: ring + 1,
                          edges: edges, colorer: colorer)
                }
                angle += sweep
                continue
            }
            let index = Int32(_pieces.count)
            let color = colorer(id)
            let style = tree.style(of: id)
            let key = Self.key(tree, id, in: kidsKey)
            let seed = Self.seed(key)
            // The tree's own stretches: one piece for each, side by side, with what's inside under them all.
            if let stretches = tree.stretches(of: id), stretches.count > 1 {
                let whole = Float(max(stretches.reduce(UInt64(0)) { $0 &+ $1.size }, 1))
                let first = _pieces.count
                var at = angle
                // Each stretch ends at itself, so a search that misses one goes on to the next; what's inside follows the last,
                // sitting on the first. `extent(of:)` gives all of it.
                for (n, stretch) in stretches.enumerated() {
                    let to = n == stretches.count - 1 ? angle + sweep : at + sweep * Float(stretch.size) / whole
                    _pieces.append(Piece(node: id, tail: id, key: key ^ ((UInt64(stretch.key) &+ 1) << 48), a0: at, a1: to, r0: r0, r1: r1,
                                         ring: Int32(ring), parent: parentPiece, end: Int32(_pieces.count + 1), isSmaller: false, smallerCount: 0,
                                         color: stretch.color ?? color, style: style, seed: seed, size: stretch.size,
                                         marked: stretch.isMarked ? 1 : 0))
                    at = to
                }
                if hasChildren {
                    if ring + 2 < edges.count {
                        place(tree, marker: marker, parentNode: id, parentPiece: Int32(first), parentKey: key, a0: angle,
                              a1: angle + sweep, ring: ring + 1, edges: edges, colorer: colorer)
                    } else if marksDeeper {
                        let deeper = Self.folderShare(tree, of: id)
                        for i in first..<first + stretches.count { _pieces[i].deeper = deeper }
                    }
                }
                angle += sweep
                continue
            }
            // A folder whose contents are in more than one place is drawn as one stretch for each, over what it's made of.
            if tree.hasGroups, parentNode != 0, hasChildren, ring + 2 < edges.count,
               let runs = runs(tree, of: id, a0: angle, a1: angle + sweep, childRing: ring + 1, edges: edges, colorer: colorer) {
                let marked: Float = marker?(id) == true ? 1 : 0
                for (r, run) in runs.enumerated() {
                    let at = Int32(_pieces.count)
                    _pieces.append(Piece(node: id, tail: id, key: key ^ (UInt64(r + 1) << 56), a0: run.a0, a1: run.a1, r0: r0, r1: r1,
                                         ring: Int32(ring), parent: parentPiece, end: at + 1, isSmaller: false, smallerCount: 0,
                                         color: run.color, style: style, seed: seed, size: run.bytes, marked: marked))
                    place(tree, marker: marker, parentNode: id, parentPiece: at, parentKey: key, a0: run.a0, a1: run.a1, ring: ring + 1,
                          edges: edges, colorer: colorer, only: run.kids, rest: run.rest, restCount: run.restCount)
                    _pieces[Int(at)].end = Int32(_pieces.count)
                }
                angle += sweep
                continue
            }
            _pieces.append(Piece(node: id, tail: id, key: key, a0: angle, a1: angle + sweep, r0: r0, r1: r1,
                                 ring: Int32(ring), parent: parentPiece, end: index + 1, isSmaller: false, smallerCount: 0,
                                 color: color, style: style, seed: seed, size: bytes, marked: marker?(id) == true ? 1 : 0))
            if hasChildren {
                if ring + 2 < edges.count {
                    place(tree, marker: marker, parentNode: id, parentPiece: index, parentKey: key, a0: angle, a1: angle + sweep,
                          ring: ring + 1, edges: edges, colorer: colorer)
                    _pieces[Int(index)].end = Int32(_pieces.count)
                } else if marksDeeper {
                    _pieces[Int(index)].deeper = Self.folderShare(tree, of: id)
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
                let color = colorer(parentNode)
                let index = Int32(_pieces.count)
                let key = parentKey ^ 0x5555_5555_5555 ^ (only == nil ? 0 : 0x77 << 48)
                let seed = Self.seed(key)
                _pieces.append(Piece(node: parentNode, tail: parentNode, key: key, a0: angle, a1: a1, r0: r0, r1: r1,
                                     ring: Int32(ring), parent: parentPiece, end: index + 1, isSmaller: true, smallerCount: smallerCount,
                                     color: color, style: .smaller, seed: seed, size: rest, marked: marker?(parentNode) == true ? 1 : 0))
            }
        }
    }

    @usableFromInline
    mutating func add(_ sweep: Float, toRing ring: Int) {
        if ring >= around!.count { around! += [Float](repeating: 0, count: ring + 1 - around!.count) }
        around![ring] += sweep
    }

    /// A number from 0 to 1 for a piece, from its key, so the same piece gets the same one in every picture.
    @inlinable @inline(__always)
    static func seed(_ key: UInt64) -> Float {
        var h = key ^ (key >> 30)
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 27
        return Float(h >> 48) / 65535
    }

    /// The piece under a point, given in polar form. Pieces come in depth-first order, so going down the rings skips
    /// whole subtrees at once.
    public func hit(angle: Float, radius: Float) -> Int? {
        var i = 0
        while i < _pieces.count {
            let p = _pieces[i]
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
