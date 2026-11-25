import Foundation
import Testing
@testable import SunburstKit

/// The parts a chart is made of, each doing its one job whatever else the chart has.
@Suite("Parts")
struct PartsTests {
    private let mb: UInt64 = 1_000_000
    private let none: RingLayout.Colorer = { _ in .zero }

    /// A disk: two big folders, a small one, and free space at the root.
    private func disk() -> TestTree {
        var tree = TestTree([("Mine/a/x", 400 * mb), ("Mine/b", 200 * mb), ("Apps/one", 150 * mb), ("System/core", 90 * mb),
                             ("free", 300 * mb)])
        tree.nodes[Int(tree.node("free"))].role = .room
        tree.nodes[Int(tree.node("free"))].folder = false
        return tree
    }

    /// Two sides with their own folders, and free space at the root that a split doesn't draw.
    private func pair() -> TestTree {
        var tree = TestTree([("mac/Films/a", 900 * mb), ("mac/Films/b", 300 * mb), ("mac/Music/c", 200 * mb),
                             ("drive/Films/a", 100 * mb), ("drive/Old/d", 50 * mb), ("free", 500 * mb)])
        tree.nodes[Int(tree.node("free"))].role = .room
        tree.nodes[Int(tree.node("free"))].folder = false
        return tree
    }

    @Test("A folder's things go round biggest first, or in the order asked for")
    func order() {
        let tree = TestTree([("Mine/c", 100 * mb), ("Mine/a", 50 * mb), ("Mine/b", 300 * mb)])
        let mine = tree.node("Mine")
        let names = Dictionary(uniqueKeysWithValues: ["a", "b", "c"].map { (tree.node("Mine/" + $0), $0) })
        func round(_ parts: SunburstParts) -> [String] {
            let layout = RingLayout.build(tree: tree, focus: mine, parts: parts, colorer: none)
            return layout.pieces.filter { tree.parent(of: $0.node) == mine }.sorted { $0.a0 < $1.a0 }.compactMap { names[$0.node] }
        }
        #expect(round(SunburstParts()) == ["b", "c", "a"])
        #expect(round(SunburstParts(rings: .init(before: { (names[$0] ?? "") < (names[$1] ?? "") }))) == ["a", "b", "c"])
    }

    @Test("A band keeps its width however many rings there are")
    func bandWidth() {
        let tree = disk()
        for depth in [3, 6, 12] {
            let parts = SunburstParts(bands: [.init()], rings: .init(RingSizes(depth: depth)))
            let layout = RingLayout.build(tree: tree, focus: 0, parts: parts, colorer: none)
            let band = layout.levels[0]
            #expect(band.part == .band && band.isThin)
            #expect(abs((band.r1 - band.r0) - RingLayout.band) < 1e-6)
            #expect(layout.levels.dropFirst().allSatisfy { $0.part == .ring && !$0.isThin })
        }
    }

    @Test("Room closes the circle as a wedge that reaches out, with or without a band")
    func roomWedge() throws {
        let tree = disk()
        for bands in [[SunburstParts.Band()], []] {
            let layout = RingLayout.build(tree: tree, focus: 0, parts: SunburstParts(bands: bands), colorer: none)
            let free = try #require(layout.roomPiece.map { layout.pieces[$0] })
            #expect(free.r0 == RingLayout.hole)
            #expect(free.r1 > layout.levels[bands.count].r1, "out past the first ring of things")
            let last = layout.pieces.filter { $0.ring == 0 }.max { $0.a1 < $1.a1 }
            #expect(last?.node == tree.node("free"), "after everything else")
        }
    }

    @Test("Something that can't be read, deep inside, is hatched in its own ring and isn't a wedge")
    func unreadableDeepInside() throws {
        var tree = disk()
        let locked = tree.node("Mine/a")
        tree.nodes[Int(locked)].role = .unreadable
        let layout = RingLayout.build(tree: tree, focus: 0, parts: SunburstParts(bands: [.init()]), colorer: none)
        let piece = try #require(layout.piece(of: locked).map { layout.pieces[$0] })
        #expect(piece.role == .unreadable)
        #expect(piece.r1 == layout.levels[Int(piece.ring)].r1)
    }

    @Test("Zooming into a band's segment leaves the band out")
    func zoomIntoBand() {
        let tree = disk()
        let parts = SunburstParts(bands: [.init()])
        #expect(RingLayout.build(tree: tree, focus: 0, parts: parts, colorer: none).levels.first?.part == .band)
        let inside = RingLayout.build(tree: tree, focus: tree.node("Mine"), parts: parts, colorer: none)
        #expect(inside.levels.first?.part == .ring)
    }

    @Test("A split gives each side half the circle, drawn thin or as a ring")
    func split() {
        let tree = pair()
        for look in [SunburstParts.Split.band, .ring] {
            let layout = RingLayout.build(tree: tree, focus: 0, parts: SunburstParts(split: look), colorer: none)
            let sides = layout.pieces.filter { $0.ring == 0 }
            #expect(sides.count == 2, "free space isn't a side")
            for side in sides { #expect(abs(side.sweep - .pi) < 1e-5) }
            #expect(layout.levels[0].part == .split)
            #expect(layout.levels[0].isThin == (look == .band))
            #expect(layout.showsSplit && layout.isSplit)
        }
        let one = RingLayout.build(tree: tree, focus: tree.node("mac"), parts: SunburstParts(split: .band), colorer: none)
        #expect(!one.showsSplit && one.isSplit, "zoomed into a side, it's alone")
    }

    @Test("The dial counts the whole circle, or each side")
    func dial() {
        let tree = pair()
        func sides(_ parts: SunburstParts, focus: UInt32 = 0) -> Int {
            RingLayout.build(tree: tree, focus: focus, parts: parts, colorer: none).dialSides
        }
        #expect(sides(SunburstParts(split: .band)) == 1)
        #expect(sides(SunburstParts(split: .band, dial: .init(counts: .eachSide))) == 2)
        #expect(sides(SunburstParts(split: .band, dial: .init(counts: .eachSide)), focus: tree.node("mac")) == 1, "one side, one whole")
        #expect(sides(SunburstParts(dial: .init(counts: .eachSide))) == 1, "no split, the whole")
        #expect(sides(SunburstParts(dial: nil)) == 0)
    }

    @Test("Bands stack under a split, each taking the next level, and go as they're zoomed past")
    func stacked() {
        let tree = pair()
        let parts = SunburstParts(split: .band, bands: [.init()])
        let root = RingLayout.build(tree: tree, focus: 0, parts: parts, colorer: none)
        #expect(root.levels.prefix(3).map(\.part) == [.split, .band, .ring])
        #expect(root.pieces.filter { $0.ring == 1 }.map(\.node).sorted() ==
                [tree.node("mac/Films"), tree.node("mac/Music"), tree.node("drive/Films"), tree.node("drive/Old")].sorted())
        let side = RingLayout.build(tree: tree, focus: tree.node("mac"), parts: parts, colorer: none)
        #expect(side.levels.prefix(2).map(\.part) == [.band, .ring])
        let deeper = RingLayout.build(tree: tree, focus: tree.node("mac/Films"), parts: parts, colorer: none)
        #expect(deeper.levels.first?.part == .ring)
    }

    @Test("Nothing is named on a band; a split drawn as a ring names its sides")
    @MainActor
    func names() {
        let tree = pair()
        let area = LabelArea(center: CGPoint(x: 500, y: 400), radius: 320, width: 1000, height: 800, top: 78, bottom: 760)
        func inside(_ split: SunburstParts.Split) -> [SunburstLabel] {
            let layout = RingLayout.build(tree: tree, focus: 0, parts: SunburstParts(split: split), colorer: { _ in [0.3, 0.3, 0.3] })
            var placed = LabelPlacer.Placed()
            return LabelPlacer.inside(layout: layout, order: LabelPlacer.order(layout), area: area, named: &placed) { p in
                (tree.nodes[Int(p.node)].name, SunburstFormat.bytes(p.size))
            }
        }
        let sides: Set = [tree.node("mac"), tree.node("drive")]
        #expect(inside(.band).allSatisfy { !sides.contains($0.node) })
        #expect(Set(inside(.ring).map(\.node)).isSuperset(of: sides))
    }

    @Test("A chart takes new parts and draws in them")
    @MainActor
    func chartParts() {
        let tree = disk()
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, parts: SunburstParts(bands: [.init()]),
                                  engine: SunburstEngine(reducesMotion: { true }))
        #expect(chart.engine.layout.levels.first?.part == .band)
        chart.parts = SunburstParts()
        #expect(chart.engine.layout.levels.first?.part == .ring)
        chart.sizes = RingSizes(depth: 2)
        #expect(chart.engine.layout.rings <= 2)
    }
}
