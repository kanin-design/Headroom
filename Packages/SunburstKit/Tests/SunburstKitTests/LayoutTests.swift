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
        var style = PieceStyle.folder
        var group: UInt8?
    }
    var nodes: [Node] = [Node(name: "", parent: 0)]
    var totals: [UInt64] = []
    var hasHalves = false
    var hasBand = false
    var plain: Set<UInt32> = []

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
                nodes.append(Node(name: part, parent: at, own: isFile ? bytes : 0, folder: !isFile, style: isFile ? .file : .folder))
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
    func style(of node: UInt32) -> PieceStyle { nodes[Int(node)].style }
    func nameKey(of node: UInt32) -> UInt64 {
        nodes[Int(node)].name.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }
    func isHalf(_ node: UInt32) -> Bool { hasHalves && nodes[Int(node)].parent == 0 }
    func isPlainShape(_ node: UInt32) -> Bool { plain.contains(node) }
    var hasGroups: Bool { nodes.contains { $0.group != nil } }
    func group(of node: UInt32) -> UInt8? { nodes[Int(node)].group }
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
        let layout = RingLayout.build(tree: tree, focus: 0, colorer: none)
        let first = layout.pieces.filter { $0.ring == 0 }
        XCTAssertEqual(first.map(\.node), [tree.node("a"), tree.node("b"), tree.node("c")])
        XCTAssertEqual(first[0].sweep, 2 * .pi * 0.6, accuracy: 0.0001)
        XCTAssertEqual(first[1].a0, first[0].a1, accuracy: 0.0001)
        XCTAssertEqual(first[2].a1, 2 * .pi, accuracy: 0.0001)
        XCTAssertEqual(first[2].style, .file)
        XCTAssertEqual(first[0].r0, RingLayout.hole, accuracy: 0.0001)
    }

    func testAFolderThatIsNearlyAllOneFolderIsDrawnAsOneWithIt() throws {
        let tree = TestTree([("top/media/tv/show", 90 * mb), ("top/media/note", 1 * mb), ("other", 50 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, colorer: none)
        let at = try XCTUnwrap(layout.piece(of: tree.node("top")))
        XCTAssertEqual(layout.pieces[at].tail, tree.node("top/media/tv"), "Top › Media › TV is one piece")
        XCTAssertEqual(layout.piece(of: tree.node("top/media/tv")), at, "found by the folder at its end too")
        XCTAssertEqual(RingLayout.chainTail(tree: tree, tree.node("top")), tree.node("top/media/tv"))
    }

    func testThePointerFindsThePieceUnderIt() throws {
        let tree = TestTree([("a/x", 60 * mb), ("a/y", 20 * mb), ("b", 20 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, colorer: none)
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
        let layout = RingLayout.build(tree: tree, focus: tree.node("big"), colorer: none)
        let smaller = try XCTUnwrap(layout.outerSmaller)
        XCTAssertTrue(layout.pieces[smaller].isSmaller)
        XCTAssertEqual(layout.pieces[smaller].smallerCount, 30)
        XCTAssertNil(layout.piece(of: tree.node("big/tiny3")))
        XCTAssertEqual(layout.nearestPiece(to: tree.node("big/tiny3"), tree: tree), nil, "the folder in view has no piece of its own")
    }

    func testTwoHalvesTakeHalfTheRingWhateverTheirSizes() throws {
        let tree = TestTree([("mac/films/a", 900 * mb), ("drive/films/a", 100 * mb)], halves: true)
        let layout = RingLayout.build(tree: tree, focus: 0, colorer: none)
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
        let layout = RingLayout.build(tree: tree, focus: 0, colorer: { colours[$0] ?? .zero })
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
        tree.plain = [tree.node("free")]
        tree.nodes[Int(tree.node("free"))].style = .free
        let layout = RingLayout.build(tree: tree, focus: 0, colorer: none)
        let band = try XCTUnwrap(layout.pieces.first { $0.ring == 0 && $0.node == tree.node("files") })
        XCTAssertEqual(band.r1 - band.r0, RingLayout.band, accuracy: 0.0001)
        let free = try XCTUnwrap(layout.freePiece)
        XCTAssertGreaterThan(layout.pieces[free].r1, band.r1, "free space reaches out past the band")
        XCTAssertLessThanOrEqual(layout.pieces[free].r1, 1)
    }

    func testMeasuringAgreesWithThePictureItMeasuresFor() {
        var files: [(String, UInt64)] = []
        for i in 0..<6 { for j in 0..<5 { files.append(("d\(i)/e\(j)/f\(j)/g", UInt64(i + j + 1) * mb)) } }
        let tree = TestTree(files)
        for style in [RingStyle.standard, .tapered] {
            let measured = RingLayout.fill(tree: tree, focus: 0, style: style)
            let drawn = RingLayout.build(tree: tree, focus: 0, colorer: none, sizes: RingSizes(depth: RingSizes.most, style: style))
            XCTAssertEqual(measured.count, drawn.fill.count)
            for (m, d) in zip(measured, drawn.fill) { XCTAssertEqual(m, d, accuracy: 0.0001) }
        }
    }

    func testAPiecesKeyIsItsPathWhateverItsNumber() throws {
        let one = TestTree([("a/x", 10 * mb), ("b/y", 20 * mb)])
        let two = TestTree([("b/y", 20 * mb), ("c", 1 * mb), ("a/x", 10 * mb)])
        XCTAssertNotEqual(one.node("a/x"), two.node("a/x"))
        XCTAssertEqual(RingLayout.pathKey(one, one.node("a/x")), RingLayout.pathKey(two, two.node("a/x")))
        let k1 = RingLayout.build(tree: one, focus: 0, colorer: none).pieces.first { $0.node == one.node("a/x") }?.key
        let k2 = RingLayout.build(tree: two, focus: 0, colorer: none).pieces.first { $0.node == two.node("a/x") }?.key
        XCTAssertEqual(k1, k2, "so it glides from its old place to its new one")
    }

    func testMarkedPiecesAreStriped() {
        let tree = TestTree([("a", 10 * mb), ("b", 20 * mb)])
        let a = tree.node("a")
        let layout = RingLayout.build(tree: tree, focus: 0, colorer: none, marked: { $0 == a })
        XCTAssertEqual(layout.pieces.first { $0.node == a }?.marked, 1)
        XCTAssertEqual(layout.pieces.first { $0.node == tree.node("b") }?.marked, 0)
    }
}

final class LabelTests: XCTestCase {
    func testABigPieceIsNamedInsideItAndASmallOneAtTheSide() throws {
        let mb: UInt64 = 1_000_000
        let tree = TestTree([("big/a", 900 * mb), ("small/b", 25 * mb), ("rest", 75 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, colorer: { _ in [0.2, 0.2, 0.2] })
        let area = LabelArea(center: CGPoint(x: 600, y: 430), radius: 300, width: 1200, height: 860, bottom: 780)
        var placed = LabelPlacer.Placed()
        let order = LabelPlacer.order(layout, halvesFirst: false)
        let inside = LabelPlacer.inside(layout: layout, order: order, area: area, halves: false, named: &placed) { p in
            (tree.nodes[Int(p.node)].name, "\(p.size / mb) MB")
        }
        XCTAssertTrue(inside.contains { $0.title == "big" && $0.place == .inside })
        let picks = LabelPlacer.bigPieces(layout: layout, order: order, total: tree.size(of: 0), named: &placed) { p in
            (tree.nodes[Int(p.node)].name, "\(p.size / mb) MB")
        }
        let sides = LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: false)
        for label in sides {
            XCTAssertNotEqual(label.place, .inside)
            XCTAssertGreaterThan(abs(label.position.x - area.center.x), area.radius, "out beside the ring")
        }
        XCTAssertFalse(sides.contains { $0.title == "big" }, "a piece named inside isn't named again")
    }
}
