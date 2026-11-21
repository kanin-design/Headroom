import Foundation
import simd

/// A picture of part of a tree: its pieces, sorted clockwise from 12 o'clock with the biggest first, and the levels they're
/// in. `build(tree:focus:parts:colorer:marked:)` makes one; the rest answers questions about it.
///
/// The layout is generic over the app's tree and `@inlinable`, so the app's own build specialises it for its tree, and it
/// runs as fast as code written for that tree.
public struct RingLayout: Sendable {
    /// The middle, where the numbers go, as a share of the ring's radius.
    public static let hole: Float = 0.34
    /// How thick a band is, or a split drawn as one: the same however many rings there are, while the rings share out the
    /// rest.
    public static let band: Float = 0.029
    /// Pieces shorter than this at their ring's middle, in points on a typical window, merge into "smaller items".
    public static let minimumArc: Float = 2.2
    /// The radius, in points, that sizes in points above are measured on.
    public static let typicalRadius: Float = 400
    /// A folder at least this share one subfolder is drawn together with it.
    public static let chainShare = 0.88
    /// The thinnest a ring gets: five points on a typical window, so it stays easy to see and to point at.
    public static let thinnest: Float = 5 / typicalRadius

    /// What sets a piece's colour, in linear Display P3. The geometry is the same whatever the colours, so you keep your place.
    public typealias Colorer = (_ node: UInt32) -> SIMD3<Float>
    /// Whether a piece is marked, such as selected: it's drawn striped.
    public typealias Marker = (_ node: UInt32) -> Bool

    /// One level of the picture, from the middle out: the part it belongs to and where it is.
    public struct Level: Sendable, Equatable {
        public enum Part: Sendable, Equatable { case split, band, ring }
        public var part: Part
        /// Drawn thin: a band, or a split drawn as one.
        public var isThin: Bool
        /// Its inner and outer edge, as shares of the ring's radius.
        public var r0: Float, r1: Float

        @inlinable
        public init(part: Part, isThin: Bool, r0: Float, r1: Float) {
            self.part = part
            self.isThin = isThin
            self.r0 = r0
            self.r1 = r1
        }
    }

    /// The pieces, depth first.
    public var pieces: [Piece] { _pieces }
    @usableFromInline var _pieces: [Piece] = []
    /// The node in the middle.
    public var focus: UInt32 = 0
    /// How many thick levels are drawn: the rings, and a split drawn as a ring. Bands aren't counted.
    public var rings: Int { _rings }
    @usableFromInline var _rings = 0
    /// How many rings this picture could fill, up to the most there can be.
    public var reach: Int { _reach }
    @usableFromInline var _reach = 0
    /// The levels, from the middle out: a split, bands, then the rings.
    public var levels: [Level] { _levels }
    @usableFromInline var _levels: [Level] = []
    /// How many wholes the dial counts across: 1 for the circle, more for a split's sides counted each on its own, 0 for
    /// no dial.
    public var dialSides: Int { _dialSides }
    @usableFromInline var _dialSides = 1

    // Where things are in `pieces`, worked out once when the picture is made, so nothing has to search it.
    @usableFromInline var pieceOf: [UInt32: Int32] = [:]
    /// The folders between the ends of each chain, and the piece the chain is drawn as.
    @usableFromInline var chainLinks: [(node: UInt32, piece: Int32)] = []
    @usableFromInline var smallerIn: [Int32: Int32] = [:]
    /// The "smaller items" piece of the node in the middle itself.
    public var outerSmaller: Int? { _outerSmaller }
    @usableFromInline var _outerSmaller: Int?
    /// The first piece of room, such as free space, if there is one.
    public var roomPiece: Int? { _roomPiece }
    @usableFromInline var _roomPiece: Int?

    public init() {}

    // MARK: Making a picture

    /// The picture of `focus` and what's inside it, in these parts. It gets as many rings as asked for, but never more than
    /// it can fill, so there's no empty ring around the edge. `colorer` colours each piece; `marked` says which are striped.
    @inlinable
    public static func build<T: SunburstTree>(tree: T, focus: UInt32, parts: SunburstParts = SunburstParts(), colorer: Colorer,
                                              marked: Marker? = nil) -> RingLayout {
        let plan = LevelPlan(tree: tree, focus: focus, parts: parts)
        let lists = ChildLists()
        let style = parts.rings.sizes.style
        let fill = measure(tree: tree, focus: focus, parts: parts, plan: plan, lists: lists)
        let reach = fill.prefix { $0 > 0 && $0 >= style.leastFill }.count
        // A split drawn as a ring with bands after it keeps a ring of things outside them: a band sits inside the rings.
        let least = plan.thickLeading > 0 && plan.thin.contains(true) ? plan.thickLeading + 1 : 1
        let count = max(min(parts.rings.sizes.depth, reach), least)
        var layout = withoutActuallyEscaping(colorer) { colorer in
            var builder = RingBuilder(tree: tree, focus: focus, parts: parts, plan: plan, lists: lists, colorer: colorer, marker: marked,
                                      measuring: false, marksDeeper: style.marksDeeper)
            return builder.draw(shares: style.shares(count: count, fill: fill))
        }
        layout._rings = count
        layout._reach = reach
        layout._dialSides = parts.dial == nil ? 0 : (parts.dial?.counts == .eachSide && plan.hasSplit ? max(plan.sides, 1) : 1)
        layout._isSplit = parts.split != nil
        layout.indexPieces()
        return layout
    }

    /// How far around each ring of things would go with the most rings there can be, as a share of the first, without
    /// making the picture. With fewer rings, every ring sits further out, so each goes at least as far around then as here.
    @inlinable
    public static func fill<T: SunburstTree>(tree: T, focus: UInt32, parts: SunburstParts = SunburstParts()) -> [Float] {
        measure(tree: tree, focus: focus, parts: parts, plan: LevelPlan(tree: tree, focus: focus, parts: parts), lists: ChildLists())
    }

    @inlinable
    static func measure<T: SunburstTree>(tree: T, focus: UInt32, parts: SunburstParts, plan: LevelPlan, lists: ChildLists) -> [Float] {
        // Adaptive rings are measured on the taper, the fixed curve nearest to them.
        let measuring: RingStyle = parts.rings.sizes.style == .standard ? .standard : .tapered
        var builder = RingBuilder(tree: tree, focus: focus, parts: parts, plan: plan, lists: lists, colorer: { _ in .zero }, marker: nil,
                                  measuring: true, marksDeeper: false)
        _ = builder.draw(shares: measuring.shares(count: RingSizes.most, fill: []))
        let around = builder.around.enumerated().filter { !plan.isThin($0.offset) }.map(\.element)
        return shares(of: around)
    }

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

    /// How far around each ring of things goes, from the first ring out, as a share of how far the first one goes. Bands
    /// aren't counted.
    public var fill: [Float] {
        var around: [Float] = []
        var ringOf = [Int](repeating: -1, count: _levels.count)
        var next = 0
        for (i, level) in _levels.enumerated() where !level.isThin {
            ringOf[i] = next
            next += 1
        }
        for p in _pieces {
            let i = Int(p.ring) < ringOf.count ? ringOf[Int(p.ring)] : -1
            guard i >= 0 else { continue }
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

    /// Whether the chart is split into sides (`SunburstParts.split`), even while one side is zoomed into and the split
    /// isn't drawn.
    public var isSplit: Bool { _isSplit }
    @usableFromInline var _isSplit = false
    /// Whether the split is drawn: its sides are the first level.
    public var showsSplit: Bool { _levels.first?.part == .split }

    /// Tiny pieces step back until you point at them, so the big ones are easier to see. `total` is the size of the node in
    /// the middle; a piece under 0.6% of it steps back, the smaller the further.
    public mutating func calmTinyPieces(total: UInt64) {
        let whole = Float(max(total, 1))
        for i in _pieces.indices { _pieces[i].calm = min(max(1 - Float(_pieces[i].size) / whole / 0.006, 0), 0.8) }
    }

    // MARK: The tree, as the rings see it

    /// What's drawn directly inside a folder, once a folder that's nearly all one subfolder is drawn as one with it.
    @inlinable
    public static func visibleChildren<T: SunburstTree>(tree: T, of parent: UInt32) -> (kids: [UInt32], tail: UInt32, ownBytes: UInt64) {
        let lists = ChildLists()
        let v = lists.visible(tree, of: parent, mode: .ring(byGroup: false))
        return (Array(lists.buffer[v.start..<v.start + v.count]), v.tail, v.own)
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

    /// A number from 0 to 1 for a piece, from its key, so the same piece gets the same one in every picture.
    @inlinable @inline(__always)
    static func seed(_ key: UInt64) -> Float {
        var h = key ^ (key >> 30)
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 27
        return Float(h >> 48) / 65535
    }

    // MARK: Finding pieces

    /// The piece that stands for a node: its own, or the one a chain like Media › TV is drawn as, for any folder in the chain.
    public func piece(of node: UInt32) -> Int? { pieceOf[node].map(Int.init) }

    /// The pieces a piece's node is drawn as side by side: just the piece, unless its node is cut into stretches.
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

    @usableFromInline
    mutating func indexPieces() {
        pieceOf = [UInt32: Int32](minimumCapacity: _pieces.count)
        smallerIn = [:]
        _outerSmaller = nil
        _roomPiece = nil
        for (at, p) in _pieces.enumerated() {
            let at32 = Int32(at)
            if p.isSmaller {
                if p.parent >= 0 { smallerIn[p.parent] = at32 } else { _outerSmaller = at }
            } else {
                if pieceOf[p.node] == nil { pieceOf[p.node] = at32 }
                if pieceOf[p.tail] == nil { pieceOf[p.tail] = at32 }
                if p.role == .room, _roomPiece == nil { _roomPiece = at }
            }
        }
        for link in chainLinks where pieceOf[link.node] == nil { pieceOf[link.node] = link.piece }
    }
}
