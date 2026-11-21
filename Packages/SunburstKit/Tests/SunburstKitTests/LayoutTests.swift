import XCTest
@testable import SunburstKit

/// A small tree made from paths and sizes, as a host would hand one over.
struct TestTree: SunburstTree {
    struct Node {
        var name: String
        var parent: UInt32
        var children: [UInt32] = []
        var own: UInt64 = 0
        var folder = true
        var role = SunburstRole.container
        var shared = false
        var group: UInt8?
    }
    var nodes: [Node] = [Node(name: "", parent: 0)]
    var totals: [UInt64] = []
    var hasHalves = false
    var hasBand = false
    var always: Set<UInt32> = []
    var cut: [UInt32: [SunburstStretch]] = [:]

    /// Files at these paths, of these sizes. Folders are made on the way.
    init(_ files: [(String, UInt64)], halves: Bool = false) {
        hasHalves = halves
        for (path, bytes) in files {
            var at: UInt32 = 0
            let parts = path.split(separator: "/").map(String.init)
            for (i, part) in parts.enumerated() {
                if let found = nodes[Int(at)].children.first(where: { nodes[Int($0)].name == part }) {
                    at = found
                    continue
                }
                let id = UInt32(nodes.count)
                let isFile = i == parts.count - 1
                nodes.append(Node(name: part, parent: at, own: isFile ? bytes : 0, folder: !isFile, role: isFile ? .item : .container))
                nodes[Int(at)].children.append(id)
                at = id
            }
        }
        total()
    }

    mutating func total() {
        totals = [UInt64](repeating: 0, count: nodes.count)
        func sum(_ id: UInt32) -> UInt64 {
            let t = nodes[Int(id)].children.reduce(nodes[Int(id)].own) { $0 + sum($1) }
            totals[Int(id)] = t
            return t
        }
        _ = sum(0)
        // Children biggest first, as the protocol asks.
        for i in nodes.indices { nodes[i].children.sort { totals[Int($0)] > totals[Int($1)] } }
    }

    func node(_ path: String) -> UInt32 {
        var at: UInt32 = 0
        for part in path.split(separator: "/") { at = nodes[Int(at)].children.first { nodes[Int($0)].name == part }! }
        return at
    }

    func firstChild(of node: UInt32) -> UInt32 { nodes[Int(node)].children.first ?? 0 }
    func nextSibling(of node: UInt32) -> UInt32 {
        let siblings = nodes[Int(nodes[Int(node)].parent)].children
        guard node != 0, let at = siblings.firstIndex(of: node), at + 1 < siblings.count else { return 0 }
        return siblings[at + 1]
    }
    func parent(of node: UInt32) -> UInt32 { nodes[Int(node)].parent }
    func size(of node: UInt32) -> UInt64 { totals[Int(node)] }
    func ownSize(of node: UInt32) -> UInt64 { nodes[Int(node)].own }
    func isFolder(_ node: UInt32) -> Bool { nodes[Int(node)].folder }
    func role(of node: UInt32) -> SunburstRole { nodes[Int(node)].role }
    func isShared(_ node: UInt32) -> Bool { nodes[Int(node)].shared }
    func nameKey(of node: UInt32) -> UInt64 {
        nodes[Int(node)].name.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }
    func group(of node: UInt32) -> UInt8? { nodes[Int(node)].group }

    /// The parts this tree is drawn with: a split for halves, a band, by group when any node has one, and what's kept
    /// and cut.
    var parts: SunburstParts {
        let always = always, cut = cut
        var rings = SunburstParts.Rings(order: nodes.contains { $0.group != nil } ? .byGroup : .bySize)
        if !always.isEmpty { rings.keep = { always.contains($0) } }
        if !cut.isEmpty { rings.cuts = { cut[$0] } }
        return SunburstParts(split: hasHalves ? .ring : nil, bands: hasBand ? [SunburstParts.Band()] : [], rings: rings)
    }
}

final class LayoutTests: XCTestCase {
    private let mb: UInt64 = 1_000_000
    private let none: RingLayout.Colorer = { _ in .zero }

    func testSixTaperedRingsAreWhatTheMapStartsWith() {
        XCTAssertEqual(RingSizes(), RingSizes(depth: 6, style: .tapered))
        XCTAssertEqual(RingStyle.standard.shares(count: 6, fill: []), [0.150, 0.128, 0.108, 0.090, 0.074, 0.060])
    }

    func testNoRingIsThinnerThanTheThinnest() {
        let widths = RingLayout.widths([1, 0.5, 0.01, 0.001], filling: 0.6)
        XCTAssertEqual(widths.reduce(0, +), 0.6, accuracy: 0.0001)
        XCTAssertEqual(widths[2], RingLayout.thinnest, accuracy: 0.0001)
        XCTAssertEqual(widths[3], RingLayout.thinnest, accuracy: 0.0001)
    }

    func testEachThingTakesItsShareOfTheCircleBiggestFirst() throws {
        let tree = TestTree([("a/x", 60 * mb), ("b/y", 30 * mb), ("c", 10 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: none)
        let first = layout.pieces.filter { $0.ring == 0 }
        XCTAssertEqual(first.map(\.node), [tree.node("a"), tree.node("b"), tree.node("c")])
        XCTAssertEqual(first[0].sweep, 2 * .pi * 0.6, accuracy: 0.0001)
        XCTAssertEqual(first[1].a0, first[0].a1, accuracy: 0.0001)
        XCTAssertEqual(first[2].a1, 2 * .pi, accuracy: 0.0001)
        XCTAssertEqual(first[2].role, .item)
        XCTAssertEqual(first[0].r0, RingLayout.hole, accuracy: 0.0001)
    }

    func testAFolderThatIsNearlyAllOneFolderIsDrawnAsOneWithIt() throws {
        let tree = TestTree([("top/media/tv/show", 90 * mb), ("top/media/note", 1 * mb), ("other", 50 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: none)
        let at = try XCTUnwrap(layout.piece(of: tree.node("top")))
        XCTAssertEqual(layout.pieces[at].tail, tree.node("top/media/tv"), "Top › Media › TV is one piece")
        XCTAssertEqual(layout.piece(of: tree.node("top/media/tv")), at, "found by the folder at its end too")
        XCTAssertEqual(RingLayout.chainTail(tree: tree, tree.node("top")), tree.node("top/media/tv"))
    }

    func testThePointerFindsThePieceUnderIt() throws {
        let tree = TestTree([("a/x", 60 * mb), ("a/y", 20 * mb), ("b", 20 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: none)
        let a = try XCTUnwrap(layout.piece(of: tree.node("a")))
        let p = layout.pieces[a]
        XCTAssertEqual(layout.hit(angle: p.midAngle, radius: (p.r0 + p.r1) / 2), a)
        XCTAssertNil(layout.hit(angle: p.midAngle, radius: RingLayout.hole / 2), "the middle is no piece")
        let x = try XCTUnwrap(layout.piece(of: tree.node("a/x")))
        XCTAssertEqual(layout.hit(angle: layout.pieces[x].midAngle, radius: (layout.pieces[x].r0 + layout.pieces[x].r1) / 2), x)
        XCTAssertEqual(layout.nearestPiece(to: tree.node("a/x"), tree: tree), x)
    }

    func testSomethingTooSmallToDrawIsInSmallerItems() throws {
        var files: [(String, UInt64)] = [("big/one", 1000 * mb)]
        for i in 0..<30 { files.append(("big/tiny\(i)", 1 * mb)) }
        let tree = TestTree(files)
        let layout = RingLayout.build(tree: tree, focus: tree.node("big"), parts: tree.parts, colorer: none)
        let smaller = try XCTUnwrap(layout.outerSmaller)
        XCTAssertTrue(layout.pieces[smaller].isSmaller)
        XCTAssertEqual(layout.pieces[smaller].smallerCount, 30)
        XCTAssertNil(layout.piece(of: tree.node("big/tiny3")))
        XCTAssertEqual(layout.nearestPiece(to: tree.node("big/tiny3"), tree: tree), nil, "the folder in view has no piece of its own")
    }

    func testWhatIsAlwaysDrawnIsNeverGatheredIntoSmallerItems() throws {
        var files: [(String, UInt64)] = [("big/one", 1000 * mb)]
        for i in 0..<30 { files.append(("big/tiny\(i)", 1 * mb)) }
        var tree = TestTree(files)
        tree.always = [tree.node("big/tiny3")]
        let layout = RingLayout.build(tree: tree, focus: tree.node("big"), parts: tree.parts, colorer: none)
        XCTAssertNotNil(layout.piece(of: tree.node("big/tiny3")), "drawn, however thin")
        XCTAssertEqual(layout.pieces[try XCTUnwrap(layout.outerSmaller)].smallerCount, 29)

        // The same in a folder drawn as stretches of its groups.
        var grouped = TestTree([("top/f/a", 400 * mb), ("top/f/b", 300 * mb), ("top/f/tiny", 1 * mb), ("top/f/tiny2", 1 * mb),
                               ("top/g", 300 * mb), ("other", 100 * mb)])
        grouped.nodes[Int(grouped.node("top/f/a"))].group = 0
        grouped.nodes[Int(grouped.node("top/f/b"))].group = 1
        grouped.nodes[Int(grouped.node("top/f/tiny"))].group = 1
        grouped.nodes[Int(grouped.node("top/f/tiny2"))].group = 1
        grouped.always = [grouped.node("top/f/tiny")]
        let stretched = RingLayout.build(tree: grouped, focus: 0, parts: grouped.parts, colorer: none)
        XCTAssertEqual(stretched.pieces.filter { $0.node == grouped.node("top/f") && !$0.isSmaller }.count, 2, "drawn as stretches")
        XCTAssertNotNil(stretched.piece(of: grouped.node("top/f/tiny")))
        XCTAssertNil(stretched.piece(of: grouped.node("top/f/tiny2")), "the rest are still gathered")
    }

    func testATreeCanCutAPieceIntoStretchesWithWhatsInsideUnderThemAll() throws {
        var tree = TestTree([("top/f/a", 60 * mb), ("top/f/b", 40 * mb), ("top/g", 100 * mb), ("other", 100 * mb)])
        let f = tree.node("top/f")
        tree.cut[f] = [SunburstStretch(size: 1, color: [1, 0, 0], key: 3),
                       SunburstStretch(size: 2, color: [0, 1, 0], isMarked: true, key: 1),
                       SunburstStretch(size: 1, key: 2)]
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in [0.5, 0.5, 0.5] })
        let at = try XCTUnwrap(layout.piece(of: f))
        let parts = Array(layout.pieces[at..<at + 3])
        XCTAssertTrue(parts.allSatisfy { $0.node == f && !$0.isSmaller })
        let sweep = parts[2].a1 - parts[0].a0
        XCTAssertEqual((parts[0].a1 - parts[0].a0) / sweep, 0.25, accuracy: 0.0001)
        XCTAssertEqual((parts[1].a1 - parts[1].a0) / sweep, 0.5, accuracy: 0.0001, "each takes its share of the piece")
        XCTAssertEqual(parts.map(\.color), [[1, 0, 0], [0, 1, 0], [0.5, 0.5, 0.5]], "its own colour, or the node's")
        XCTAssertEqual(parts.map(\.marked), [0, 1, 0])
        XCTAssertEqual(Set(parts.map(\.key)).count, 3)
        let inside = layout.pieces.indices.filter { layout.pieces[$0].node == tree.node("top/f/a") || layout.pieces[$0].node == tree.node("top/f/b") }
        XCTAssertEqual(inside.count, 2)
        for i in inside {
            XCTAssertEqual(Int(layout.pieces[i].parent), at)
            XCTAssertGreaterThanOrEqual(layout.pieces[i].a0, parts[0].a0 - 0.0001)
            XCTAssertLessThanOrEqual(layout.pieces[i].a1, parts[2].a1 + 0.0001)
        }
        XCTAssertEqual(layout.pieces[inside[0]].a0, parts[0].a0, accuracy: 0.0001, "what's inside runs under the whole piece")
        XCTAssertEqual(layout.extent(of: at + 1), at..<inside.max()! + 1, "a stretch stands for the whole node and what's inside")
        XCTAssertEqual(layout.stretches(around: at + 2), at...at + 2)
        let a = layout.pieces[inside[0]], b = layout.pieces[inside[1]]
        XCTAssertEqual(layout.hit(angle: (parts[2].a0 + parts[2].a1) / 2, radius: (parts[2].r0 + parts[2].r1) / 2), at + 2, "every stretch can be pointed at")
        XCTAssertEqual(layout.hit(angle: (b.a0 + b.a1) / 2, radius: (b.r0 + b.r1) / 2), inside[1], "and what's inside")
        XCTAssertEqual(layout.hit(angle: (a.a0 + a.a1) / 2, radius: (a.r0 + a.r1) / 2), inside[0])

        // The same stretches in the next tree glide to their places.
        let again = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in [0.5, 0.5, 0.5] })
        XCTAssertEqual(again.pieces.map(\.key), layout.pieces.map(\.key))
    }

    func testThingsOfTheSameSizeKeepTheTreesOrder() {
        var tree = TestTree([("top/f/c", 10 * mb), ("top/f/a", 10 * mb), ("top/f/b", 10 * mb), ("top/g", 5 * mb)])
        for name in ["a", "b", "c"] { tree.nodes[Int(tree.node("top/f/" + name))].group = 0 }
        let f = Int(tree.node("top/f"))
        func drawn() -> [String] {
            RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: none).pieces.filter { $0.parent >= 0 && $0.ring == 2 }
                .map { tree.nodes[Int($0.node)].name }
        }
        let names = tree.nodes.map(\.name)
        tree.nodes[f].children.sort { names[Int($0)] < names[Int($1)] }
        XCTAssertEqual(drawn(), ["a", "b", "c"])
        tree.nodes[f].children.reverse()
        XCTAssertEqual(drawn(), ["c", "b", "a"])
    }

    func testTwoHalvesTakeHalfTheRingWhateverTheirSizes() throws {
        let tree = TestTree([("mac/films/a", 900 * mb), ("drive/films/a", 100 * mb)], halves: true)
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: none)
        let halves = layout.pieces.filter { $0.ring == 0 }
        XCTAssertEqual(halves.count, 2)
        for half in halves { XCTAssertEqual(half.sweep, .pi, accuracy: 0.0001) }
    }

    func testGroupsInAFolderAreDrawnAsStretchesOfTheirOwn() throws {
        var tree = TestTree([("top/f/a", 40 * mb), ("top/f/b", 30 * mb), ("top/f/c", 20 * mb), ("top/g", 50 * mb), ("other", 10 * mb)])
        tree.nodes[Int(tree.node("top/f/a"))].group = 1
        tree.nodes[Int(tree.node("top/f/b"))].group = 0
        tree.nodes[Int(tree.node("top/f/c"))].group = 1
        let colours: [UInt32: SIMD3<Float>] = [tree.node("top/f/a"): [1, 0, 0], tree.node("top/f/b"): [0, 1, 0], tree.node("top/f/c"): [0, 0, 1]]
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { colours[$0] ?? .zero })
        let f = tree.node("top/f")
        let stretches = layout.pieces.filter { $0.node == f && !$0.isSmaller }
        XCTAssertEqual(stretches.count, 2, "one stretch for each group")
        XCTAssertEqual(stretches[0].color, [0, 1, 0], "group 0 first, coloured by the first thing in it")
        XCTAssertEqual(stretches[1].color, [1, 0, 0])
        XCTAssertNotEqual(stretches[0].key, stretches[1].key)
        let inSecond = layout.pieces[(layout.pieces.firstIndex { $0.key == stretches[1].key }! + 1)...].prefix(2).map(\.node)
        XCTAssertEqual(inSecond, [tree.node("top/f/a"), tree.node("top/f/c")])
    }

    func testABandAroundTheWholeTreeAndPlainShapesThatReachLikeTheRest() throws {
        var tree = TestTree([("files/a/b", 50 * mb), ("free", 50 * mb)])
        tree.hasBand = true
        tree.nodes[Int(tree.node("free"))].role = .room
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: none)
        let band = try XCTUnwrap(layout.pieces.first { $0.ring == 0 && $0.node == tree.node("files") })
        XCTAssertEqual(band.r1 - band.r0, RingLayout.band, accuracy: 0.0001)
        let free = try XCTUnwrap(layout.roomPiece)
        XCTAssertGreaterThan(layout.pieces[free].r1, band.r1, "free space reaches out past the band")
        XCTAssertLessThanOrEqual(layout.pieces[free].r1, 1)
    }

    func testMeasuringAgreesWithThePictureItMeasuresFor() {
        var files: [(String, UInt64)] = []
        for i in 0..<6 { for j in 0..<5 { files.append(("d\(i)/e\(j)/f\(j)/g", UInt64(i + j + 1) * mb)) } }
        let tree = TestTree(files)
        for style in [RingStyle.standard, .tapered] {
            let measured = RingLayout.fill(tree: tree, focus: 0, parts: tree.parts.with(sizes: RingSizes(depth: 6, style: style)))
            let drawn = RingLayout.build(tree: tree, focus: 0, parts: tree.parts.with(sizes: RingSizes(depth: RingSizes.most, style: style)), colorer: none)
            XCTAssertEqual(measured.count, drawn.fill.count)
            for (m, d) in zip(measured, drawn.fill) { XCTAssertEqual(m, d, accuracy: 0.0001) }
        }
    }

    func testAPiecesKeyIsItsPathWhateverItsNumber() throws {
        let one = TestTree([("a/x", 10 * mb), ("b/y", 20 * mb)])
        let two = TestTree([("b/y", 20 * mb), ("c", 1 * mb), ("a/x", 10 * mb)])
        XCTAssertNotEqual(one.node("a/x"), two.node("a/x"))
        XCTAssertEqual(RingLayout.pathKey(one, one.node("a/x")), RingLayout.pathKey(two, two.node("a/x")))
        let k1 = RingLayout.build(tree: one, focus: 0, parts: one.parts, colorer: none).pieces.first { $0.node == one.node("a/x") }?.key
        let k2 = RingLayout.build(tree: two, focus: 0, parts: two.parts, colorer: none).pieces.first { $0.node == two.node("a/x") }?.key
        XCTAssertEqual(k1, k2, "so it glides from its old place to its new one")
    }

    func testMarkedPiecesAreStriped() {
        let tree = TestTree([("a", 10 * mb), ("b", 20 * mb)])
        let a = tree.node("a")
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: none, marked: { $0 == a })
        XCTAssertEqual(layout.pieces.first { $0.node == a }?.marked, 1)
        XCTAssertEqual(layout.pieces.first { $0.node == tree.node("b") }?.marked, 0)
    }
}

final class LabelTests: XCTestCase {
    func testABigPieceIsNamedInsideItAndASmallOneAtTheSide() throws {
        let mb: UInt64 = 1_000_000
        let tree = TestTree([("big/a", 900 * mb), ("small/b", 25 * mb), ("rest", 75 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in [0.2, 0.2, 0.2] })
        let area = LabelArea(center: CGPoint(x: 600, y: 430), radius: 300, width: 1200, height: 860, bottom: 780)
        var placed = LabelPlacer.Placed()
        let order = LabelPlacer.order(layout)
        let inside = LabelPlacer.inside(layout: layout, order: order, area: area, named: &placed) { p in
            (tree.nodes[Int(p.node)].name, "\(p.size / mb) MB")
        }
        XCTAssertTrue(inside.contains { $0.title == "big" && $0.place == .inside })
        let picks = LabelPlacer.bigPieces(layout: layout, order: order, named: &placed) { p in
            (tree.nodes[Int(p.node)].name, "\(p.size / mb) MB")
        }
        let sides = LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: false)
        for label in sides {
            XCTAssertNotEqual(label.place, .inside)
            XCTAssertGreaterThan(abs(label.position.x - area.center.x), area.radius, "out beside the ring")
        }
        XCTAssertFalse(sides.contains { $0.title == "big" }, "a piece named inside isn't named again")
    }

    func testASideNameIsForWhatTakesUpTheRingNotForItsSizeAlone() {
        let mb: UInt64 = 1_000_000
        let tree = TestTree([("mac/films", 1960 * mb), ("mac/notes", 20 * mb), ("mac/rest", 20 * mb),
                             ("drive/films", 60 * mb), ("drive/notes", 20 * mb), ("drive/rest", 20 * mb)], halves: true)
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in [0.2, 0.2, 0.2] })
        var placed = LabelPlacer.Placed()
        let picks = LabelPlacer.bigPieces(layout: layout, order: LabelPlacer.order(layout), named: &placed) { p in
            (tree.nodes[Int(p.node)].name + "@" + tree.nodes[Int(tree.nodes[Int(p.node)].parent)].name, "")
        }
        let titles = picks.map(\.title)
        // 20 MB of 2.1 GB is under 1%, but on the drive's half it takes a tenth of the ring.
        XCTAssertTrue(titles.contains("notes@drive"), "named: \(titles)")
        XCTAssertFalse(titles.contains("notes@mac"), "the same size on the big half is a sliver")
    }

    func testWithoutHalvesAPiecesAngleIsItsShare() {
        let mb: UInt64 = 1_000_000
        let tree = TestTree([("a/x", 500 * mb), ("a/y", 120 * mb), ("b/z", 300 * mb), ("c", 33 * mb), ("d/e/f", 47 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in .zero })
        for p in layout.pieces {
            XCTAssertEqual(Double(p.a1 - p.a0) / (2 * .pi), Double(p.size) / Double(tree.size(of: 0)), accuracy: 1e-5)
        }
    }
}
