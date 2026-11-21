import Foundation
import simd

/// What each level of a picture is, worked out once from the parts and the node in the middle: the split and the bands
/// that are drawn at this focus, in order from the middle, and which of them are thin. Every level after them is a ring.
@usableFromInline
struct LevelPlan {
    @usableFromInline enum Kind {
        case split
        case band(SunburstParts.Band)
        case ring
    }

    @usableFromInline let leading: [Kind]
    @usableFromInline let thin: [Bool]
    /// The split is drawn: the node in the middle is the root.
    @usableFromInline let hasSplit: Bool
    /// How many sides the split has.
    @usableFromInline let sides: Int

    @inlinable
    init<T: SunburstTree>(tree: T, focus: UInt32, parts: SunburstParts) {
        var leading: [Kind] = [], thin: [Bool] = []
        var sides = 0
        if parts.split != nil || !parts.bands.isEmpty {
            // Each part takes the next level of the tree from the root down; a part is drawn while the node in the middle is
            // above its level.
            let depth = focus == 0 ? 0 : tree.depth(of: focus)
            var level = 1
            if let split = parts.split {
                if depth < level {
                    leading.append(.split)
                    thin.append(split.look == .band)
                    var c = tree.firstChild(of: 0)
                    while c != 0 {
                        if !tree.role(of: c).isSpace { sides += 1 }
                        c = tree.nextSibling(of: c)
                    }
                }
                level += 1
            }
            for band in parts.bands {
                if depth < level {
                    leading.append(.band(band))
                    thin.append(true)
                }
                level += 1
            }
        }
        self.leading = leading
        self.thin = thin
        hasSplit = leading.first.map { if case .split = $0 { true } else { false } } ?? false
        self.sides = sides
    }

    @inlinable func kind(_ level: Int) -> Kind { level < leading.count ? leading[level] : .ring }
    @inlinable func isThin(_ level: Int) -> Bool { level < thin.count && thin[level] }
    /// How many of the leading levels are thick (a split drawn as a ring): those take a ring's share of the room.
    @inlinable var thickLeading: Int { thin.lazy.filter { !$0 }.count }
}

/// What's drawn directly inside each node, listed once for a picture and kept for both of its passes: the one that
/// measures how many rings fit and the one that makes the pieces. A big folder's list, such as a photo library's tens of
/// thousands of files, is made once rather than four times.
@usableFromInline
final class ChildLists {
    /// A node's list: where it is in `buffer`, the chain's last folder, and the bytes of the node's (and the chain's) own
    /// files. `descending` says the list is biggest first, so the first thing too small to draw means all the rest are.
    @usableFromInline
    struct Visible {
        @usableFromInline var start: Int
        @usableFromInline var count: Int
        @usableFromInline var tail: UInt32
        @usableFromInline var own: UInt64
        @usableFromInline var descending: Bool

        @inlinable init(start: Int, count: Int, tail: UInt32, own: UInt64, descending: Bool) {
            self.start = start
            self.count = count
            self.tail = tail
            self.own = own
            self.descending = descending
        }

        @inlinable var range: Range<Int> { start..<start + count }
    }

    /// How a node's children are listed, which depends on the level they're drawn in.
    @usableFromInline
    enum Mode {
        /// A split's sides: the root's things, whatever their size, in the tree's order.
        case sides
        /// The level straight around the root, or a band: everything with a size, by rank (room and what can't be read
        /// last), then biggest first.
        case ranked(((UInt32) -> Int)?)
        /// A ring: what's drawn inside a folder, with chains followed, by group first if the rings go by group.
        case ring(byGroup: Bool)
    }

    @usableFromInline var buffer: [UInt32] = []
    @usableFromInline var known: [UInt64: Visible] = [:]
    /// A quick test of whether a node might be in `known`, so the many small folders never pay for a dictionary lookup.
    @usableFromInline var maybeKnown = [UInt64](repeating: 0, count: 1024)
    /// Lists this long or longer are kept for the second pass; shorter ones cost less to make again than to keep.
    @usableFromInline static let worthKeeping = 24

    @inlinable init() { buffer.reserveCapacity(1 << 14) }

    @inlinable @inline(__always)
    func bit(_ node: UInt32) -> (word: Int, mask: UInt64) {
        let h = Int((node &* 0x9E37_79B1) >> 16) & 0xFFFF
        return (h >> 6, 1 << UInt64(h & 63))
    }

    /// The same node can be listed two ways in one picture, as a band and as what's inside a ring, so a list is kept by both.
    @inlinable
    func visible<T: SunburstTree>(_ tree: T, of parent: UInt32, mode: Mode) -> Visible {
        let key: UInt64
        switch mode {
        case .sides: key = UInt64(parent) | 1 << 32
        case .ranked: key = UInt64(parent) | 2 << 32
        case .ring(let byGroup): key = UInt64(parent) | (byGroup ? 4 : 3) << 32
        }
        let (word, mask) = bit(parent)
        if maybeKnown[word] & mask != 0, let v = known[key] { return v }
        let v = list(tree, of: parent, mode: mode)
        if v.count >= Self.worthKeeping {
            known[key] = v
            maybeKnown[word] |= mask
        }
        return v
    }

    /// Appends the children with a size, in the tree's order, and says whether they came biggest first.
    @inlinable
    func appendChildren<T: SunburstTree>(_ tree: T, of node: UInt32) -> Bool {
        var descending = true
        var previous = UInt64.max
        var c = tree.firstChild(of: node)
        while c != 0 {
            let size = tree.size(of: c)
            if size > 0 {
                buffer.append(c)
                if size > previous { descending = false }
                previous = size
            }
            c = tree.nextSibling(of: c)
        }
        return descending
    }

    @inlinable
    func list<T: SunburstTree>(_ tree: T, of parent: UInt32, mode: Mode) -> Visible {
        @inline(__always) func total(_ id: UInt32) -> UInt64 { tree.size(of: id) }
        let start = buffer.count
        switch mode {
        case .sides:
            // Every side is drawn, even one with nothing in it: an empty side says the folder isn't there.
            var c = tree.firstChild(of: parent)
            while c != 0 {
                if !tree.role(of: c).isSpace { buffer.append(c) }
                c = tree.nextSibling(of: c)
            }
            return Visible(start: start, count: buffer.count - start, tail: parent, own: 0, descending: false)

        case .ranked(let rank):
            _ = appendChildren(tree, of: parent)
            // Room and what can't be read close the circle; before them the band's ranks, then biggest first. Things of the
            // same rank and size keep the tree's order.
            func rankOf(_ id: UInt32) -> Int {
                switch tree.role(of: id) {
                case .room: return Int.max
                case .unreadable: return Int.max - 1
                default: return rank?(id) ?? 0
                }
            }
            let sorted = buffer[start...].enumerated().sorted { x, y in
                let rx = rankOf(x.element), ry = rankOf(y.element)
                if rx != ry { return rx < ry }
                let sx = total(x.element), sy = total(y.element)
                return sx != sy ? sx > sy : x.offset < y.offset
            }
            for (i, kid) in sorted.enumerated() { buffer[start + i] = kid.element }
            return Visible(start: start, count: buffer.count - start, tail: parent, own: tree.ownSize(of: parent), descending: false)

        case .ring(let byGroup):
            var descending = appendChildren(tree, of: parent)
            var own = tree.ownSize(of: parent)
            var tail = parent
            var flattened = false
            // A folder that is nearly all one subfolder would only repeat its shape on the next ring. Those chains are
            // drawn as one piece, so every ring shows something new.
            if parent != 0 {
                while !tree.isStillGrowing(tail) {
                    var best = -1
                    var bestSize: UInt64 = 0
                    for i in start..<buffer.count {
                        let size = total(buffer[i])
                        if best < 0 || size > bestSize {
                            best = i
                            bestSize = size
                        }
                    }
                    guard best >= 0 else { break }
                    let top = buffer[best]
                    guard tree.isFolder(top), tree.firstChild(of: top) != 0,
                          Double(bestSize) >= Double(total(tail)) * RingLayout.chainShare else { break }
                    buffer.remove(at: best)
                    _ = appendChildren(tree, of: top)
                    own &+= tree.ownSize(of: top)
                    tail = top
                    flattened = true
                }
            }
            if flattened {
                var kids = Array(buffer[start...])
                kids.sort { total($0) > total($1) }
                buffer.replaceSubrange(start..., with: kids)
                descending = true
            }
            if byGroup, parent != 0 {
                // By the tree's groups first, then biggest first. Things of the same size keep the order they're listed in.
                let sorted = buffer[start...].enumerated().sorted { x, y in
                    let rx = tree.group(of: x.element) ?? .max, ry = tree.group(of: y.element) ?? .max
                    if rx != ry { return rx < ry }
                    let sx = total(x.element), sy = total(y.element)
                    return sx != sy ? sx > sy : x.offset < y.offset
                }
                for (i, kid) in sorted.enumerated() { buffer[start + i] = kid.element }
                descending = false
            }
            return Visible(start: start, count: buffer.count - start, tail: tail, own: own, descending: descending)
        }
    }
}

/// Places a tree's nodes into the levels of a picture. One builder makes one pass: the measuring pass works out how far
/// around each ring would go with the most rings there can be, and the drawing pass makes the pieces.
@usableFromInline
struct RingBuilder<Tree: SunburstTree> {
    @usableFromInline let tree: Tree
    @usableFromInline let focus: UInt32
    @usableFromInline let rings: SunburstParts.Rings
    @usableFromInline let plan: LevelPlan
    @usableFromInline let lists: ChildLists
    @usableFromInline let colorer: RingLayout.Colorer
    @usableFromInline let marker: RingLayout.Marker?
    @usableFromInline let measuring: Bool
    @usableFromInline let marksDeeper: Bool
    @usableFromInline var edges: [Float] = []
    @usableFromInline var layout = RingLayout()
    /// While measuring: how far around each level goes, added up as the folders are gone through, with no piece made.
    @usableFromInline var around: [Float] = []

    @inlinable
    init(tree: Tree, focus: UInt32, parts: SunburstParts, plan: LevelPlan, lists: ChildLists, colorer: @escaping RingLayout.Colorer,
         marker: RingLayout.Marker?, measuring: Bool, marksDeeper: Bool) {
        self.tree = tree
        self.focus = focus
        rings = parts.rings
        self.plan = plan
        self.lists = lists
        self.colorer = colorer
        self.marker = marker
        self.measuring = measuring
        self.marksDeeper = marksDeeper
    }

    /// The picture, with `shares` of the room for the rings (and a split drawn as a ring).
    @inlinable
    mutating func draw(shares: [Float]) -> RingLayout {
        layout.focus = focus
        if !measuring { layout._pieces.reserveCapacity(4096) }
        guard tree.size(of: focus) > 0 else { return layout }
        // The thin levels keep their width; the rings share out the rest.
        var used = RingLayout.hole
        for level in plan.thin.indices where plan.thin[level] { used += RingLayout.band }
        let widths = RingLayout.widths(shares, filling: 1 - used)
        let count = plan.leading.count + max(widths.count - plan.thickLeading, 0)
        edges = [RingLayout.hole]
        edges.reserveCapacity(count + 1)
        var next = 0
        var levels: [RingLayout.Level] = []
        for level in 0..<count {
            let thin = plan.isThin(level)
            var width = RingLayout.band
            if !thin {
                width = widths[next]
                next += 1
            }
            let r0 = edges[edges.count - 1]
            edges.append(r0 + width)
            let part: RingLayout.Level.Part = switch plan.kind(level) {
            case .split: .split
            case .band: .band
            case .ring: .ring
            }
            levels.append(RingLayout.Level(part: part, isThin: thin, r0: r0, r1: r0 + width))
        }
        layout._levels = levels
        place(parent: focus, piece: -1, key: measuring ? 0 : RingLayout.pathKey(tree, focus), a0: 0, a1: 2 * .pi, level: 0)
        if !measuring, focus == 0, !plan.hasSplit { reachLikeTheRest(atLeast: edges[min(plan.thin.count + 1, edges.count - 1)]) }
        return layout
    }

    // MARK: Placing

    /// Places what's inside `parentNode` in `level`, between `a0` and `a1`, and everything inside that further out.
    /// `parentKey` is the key of `parentNode`. `only`, with `rest`, places part of a folder: one of its stretches.
    @inlinable
    mutating func place(parent parentNode: UInt32, piece parentPiece: Int32, key parentKey: UInt64, a0: Float, a1: Float, level ring: Int,
                        only: Range<Int>? = nil, rest: UInt64 = 0, restCount: Int32 = 0) {
        guard ring + 1 < edges.count else { return }
        @inline(__always) func total(_ id: UInt32) -> UInt64 { tree.size(of: id) }
        let kind = plan.kind(ring)
        let mode: ChildLists.Mode
        switch kind {
        case .split: mode = .sides
        case .band(let band):
            if case .ranked(let rank) = band.order { mode = .ranked(rank) } else { mode = .ranked(nil) }
        case .ring: mode = parentNode == 0 ? .ranked(nil) : .ring(byGroup: rings.order == .byGroup)
        }
        let visible = lists.visible(tree, of: parentNode, mode: mode)
        let kids = only ?? visible.range
        var parentTotal: UInt64 = 0
        if only != nil {
            parentTotal = rest
            for i in kids { parentTotal &+= total(lists.buffer[i]) }
        } else {
            parentTotal = total(parentNode)
        }
        guard parentTotal > 0 else { return }
        let r0 = edges[ring], r1 = edges[ring + 1]
        let midArc = (r0 + r1) * 0.5 * RingLayout.typicalRadius
        let ownBytes = only == nil ? visible.own : rest

        // What's drawn inside a chain is in the folder at its end, and keyed from there.
        var kidsKey = parentKey
        if parentNode != 0, visible.tail != parentNode, !measuring {
            if parentPiece >= 0 { layout._pieces[Int(parentPiece)].tail = visible.tail }
            var chain: [UInt32] = []
            var link = visible.tail
            while link != parentNode, link != 0 {
                chain.append(link)
                link = tree.parent(of: link)
            }
            for link in chain.reversed() { kidsKey = RingLayout.key(tree, link, in: kidsKey) }
            if parentPiece >= 0 { for link in chain { layout.chainLinks.append((link, parentPiece)) } }
        }

        let perByte = (a1 - a0) / Float(parentTotal)
        let isSplit: Bool
        if case .split = kind { isSplit = true } else { isSplit = false }
        let isBand: Bool
        if case .band = kind { isBand = true } else { isBand = false }
        // What's straight around the root, and what's in a band, is always drawn, however small.
        let special = parentNode == 0 || isBand
        // Biggest first, nothing kept however thin: the first thing too small to draw means all the rest are too.
        let canStop = visible.descending && only == nil && rings.keep == nil && !special
        let keep = rings.keep
        var angle = a0
        var smallerBytes: UInt64 = 0
        var smallerCount: Int32 = only == nil ? 0 : restCount
        var i = kids.lowerBound
        while i < kids.upperBound {
            let id = lists.buffer[i]
            i += 1
            let bytes = total(id)
            let sweep = isSplit ? (a1 - a0) / Float(max(kids.count, 1)) : Float(bytes) * perByte
            if sweep * midArc < RingLayout.minimumArc && !special && !(keep?(id) ?? false) {
                if canStop {
                    smallerCount += Int32(kids.upperBound - i + 1)
                    if measuring {
                        smallerBytes = bytes
                    } else {
                        smallerBytes &+= bytes
                        while i < kids.upperBound {
                            smallerBytes &+= total(lists.buffer[i])
                            i += 1
                        }
                    }
                    break
                }
                smallerBytes &+= bytes
                smallerCount += 1
                continue
            }
            let hasChildren = tree.firstChild(of: id) != 0
            if measuring {
                add(sweep, to: ring)
                if hasChildren, ring + 2 < edges.count {
                    place(parent: id, piece: -1, key: 0, a0: angle, a1: angle + sweep, level: ring + 1)
                }
                angle += sweep
                continue
            }
            let index = Int32(layout._pieces.count)
            let color = colorer(id)
            let role = tree.role(of: id)
            let shared = tree.isShared(id)
            let key = RingLayout.key(tree, id, in: kidsKey)
            let seed = RingLayout.seed(key)
            // The node cut into stretches: one piece for each, side by side, with what's inside under them all.
            if case .ring = kind, let cuts = rings.cuts?(id), cuts.count > 1 {
                let whole = Float(max(cuts.reduce(UInt64(0)) { $0 &+ $1.size }, 1))
                let first = layout._pieces.count
                var at = angle
                // Each stretch ends at itself, so a search that misses one goes on to the next; what's inside follows the last,
                // sitting on the first. `extent(of:)` gives all of it.
                for (n, stretch) in cuts.enumerated() {
                    let to = n == cuts.count - 1 ? angle + sweep : at + sweep * Float(stretch.size) / whole
                    layout._pieces.append(Piece(node: id, tail: id, key: key ^ ((UInt64(stretch.key) &+ 1) << 48), a0: at, a1: to, r0: r0, r1: r1,
                                                ring: Int32(ring), parent: parentPiece, end: Int32(layout._pieces.count + 1), isSmaller: false,
                                                smallerCount: 0, color: stretch.color ?? color, role: role, isShared: shared, seed: seed,
                                                size: stretch.size, marked: stretch.isMarked ? 1 : 0))
                    at = to
                }
                if hasChildren {
                    if ring + 2 < edges.count {
                        place(parent: id, piece: Int32(first), key: key, a0: angle, a1: angle + sweep, level: ring + 1)
                    } else if marksDeeper {
                        let deeper = folderShare(of: id)
                        for p in first..<first + cuts.count { layout._pieces[p].deeper = deeper }
                    }
                }
                angle += sweep
                continue
            }
            // A folder whose contents are in more than one group is drawn as one stretch for each, over what it's made of.
            if rings.order == .byGroup, parentNode != 0, hasChildren, ring + 2 < edges.count, case .ring = kind,
               case .ring = plan.kind(ring + 1), let runs = runs(of: id, a0: angle, a1: angle + sweep, childLevel: ring + 1) {
                let marked: Float = marker?(id) == true ? 1 : 0
                for (r, run) in runs.enumerated() {
                    let at = Int32(layout._pieces.count)
                    layout._pieces.append(Piece(node: id, tail: id, key: key ^ (UInt64(r + 1) << 56), a0: run.a0, a1: run.a1, r0: r0, r1: r1,
                                                ring: Int32(ring), parent: parentPiece, end: at + 1, isSmaller: false, smallerCount: 0,
                                                color: run.color, role: role, isShared: shared, seed: seed, size: run.bytes, marked: marked))
                    let start = lists.buffer.count
                    lists.buffer.append(contentsOf: run.kids)
                    place(parent: id, piece: at, key: key, a0: run.a0, a1: run.a1, level: ring + 1, only: start..<lists.buffer.count,
                          rest: run.rest, restCount: run.restCount)
                    layout._pieces[Int(at)].end = Int32(layout._pieces.count)
                }
                angle += sweep
                continue
            }
            layout._pieces.append(Piece(node: id, tail: id, key: key, a0: angle, a1: angle + sweep, r0: r0, r1: r1, ring: Int32(ring),
                                        parent: parentPiece, end: index + 1, isSmaller: false, smallerCount: 0, color: color, role: role,
                                        isShared: shared, seed: seed, size: bytes, marked: marker?(id) == true ? 1 : 0))
            if hasChildren {
                if ring + 2 < edges.count {
                    place(parent: id, piece: index, key: key, a0: angle, a1: angle + sweep, level: ring + 1)
                    layout._pieces[Int(index)].end = Int32(layout._pieces.count)
                } else if marksDeeper {
                    layout._pieces[Int(index)].deeper = folderShare(of: id)
                }
            }
            angle += sweep
        }

        // What's left: the folder's own small files, and anything too thin to draw on its own.
        let leftover = smallerBytes &+ (parentNode == 0 ? 0 : ownBytes)
        if leftover > 0 && parentNode != 0 {
            let sweep = a1 - angle
            if sweep * midArc > 0.6, measuring {
                add(sweep, to: ring)
            } else if sweep * midArc > 0.6 {
                let color = colorer(parentNode)
                let index = Int32(layout._pieces.count)
                let key = parentKey ^ 0x5555_5555_5555 ^ (only == nil ? 0 : 0x77 << 48)
                layout._pieces.append(Piece(node: parentNode, tail: parentNode, key: key, a0: angle, a1: a1, r0: r0, r1: r1, ring: Int32(ring),
                                            parent: parentPiece, end: index + 1, isSmaller: true, smallerCount: smallerCount, color: color,
                                            role: .container, isShared: false, seed: RingLayout.seed(key), size: leftover,
                                            marked: marker?(parentNode) == true ? 1 : 0))
            }
        }
    }

    @inlinable
    mutating func add(_ sweep: Float, to level: Int) {
        if level >= around.count { around += [Float](repeating: 0, count: level + 1 - around.count) }
        around[level] += sweep
    }

    /// One stretch of a folder cut by group: the things in it, its share of the folder, and its colour, which is that of the
    /// first thing in it. The last stretch also holds what's too small to draw and the folder's own files.
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

    /// A folder's stretches, when what's drawn inside it falls in more than one group.
    @inlinable
    func runs(of id: UInt32, a0: Float, a1: Float, childLevel: Int) -> [Run]? {
        @inline(__always) func total(_ n: UInt32) -> UInt64 { tree.size(of: n) }
        let folder = total(id)
        guard folder > 0 else { return nil }
        let visible = lists.visible(tree, of: id, mode: .ring(byGroup: true))
        let perByte = (a1 - a0) / Float(folder)
        let midArc = (edges[childLevel] + edges[childLevel + 1]) * 0.5 * RingLayout.typicalRadius
        var runs: [Run] = []
        var rest = visible.own, restCount: Int32 = 0
        for i in visible.range {
            let kid = lists.buffer[i]
            let bytes = total(kid)
            if Float(bytes) * perByte * midArc < RingLayout.minimumArc && !(rings.keep?(kid) ?? false) {
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

    /// How much of a folder is in folders inside it, rather than in files of its own.
    @inlinable
    func folderShare(of id: UInt32) -> Float {
        let visible = lists.visible(tree, of: id, mode: .ring(byGroup: rings.order == .byGroup))
        var inFolders: UInt64 = 0
        for i in visible.range where tree.isFolder(lists.buffer[i]) { inFolders &+= tree.size(of: lists.buffer[i]) }
        return Float(Double(inFolders) / Double(max(tree.size(of: id), 1)))
    }

    /// Room and what can't be read, around the whole tree, have nothing inside them drawn, so a fixed depth would make them
    /// look bigger or smaller than they are. They reach as far out as the rest of the tree does on average instead, so
    /// each covers the same share of the ring as of the whole.
    @inlinable
    mutating func reachLikeTheRest(atLeast: Float) {
        @inline(__always) func isWedge(_ p: Piece) -> Bool { p.ring == 0 && p.isSpace }
        guard layout._pieces.contains(where: isWedge) else { return }
        var area: Float = 0, sweep: Float = 0
        for p in layout._pieces where !isWedge(p) {
            area += p.sweep * (p.r1 * p.r1 - p.r0 * p.r0)
            if p.ring == 0 { sweep += p.sweep }
        }
        // With nothing else drawn yet, they are the whole tree between them and can fill the ring.
        let reach = sweep > 0 ? min(max((RingLayout.hole * RingLayout.hole + area / sweep).squareRoot(), atLeast), 1) : 1
        for i in layout._pieces.indices where isWedge(layout._pieces[i]) { layout._pieces[i].r1 = reach }
    }
}
