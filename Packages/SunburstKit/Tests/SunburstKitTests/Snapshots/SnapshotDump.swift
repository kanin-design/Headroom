import AppKit
import ImageIO
import Testing
@testable import SunburstKit

/// Everything a picture is made of, written out as text: every piece's exact numbers, which piece stands for each node,
/// what's under the pointer across the ring, chain ends, ring fill, names and branch colours. The kit as it was wrote
/// these files (`Baseline/`); the kit as it is has to write the same.
enum SnapshotCases {
    struct Case {
        let name: String
        let data: FixtureData
        var focus: (FixtureData) -> UInt32 = { _ in 0 }
        var sizes = RingSizes()
        var marked = false
        var calm = false
        var labels = false
        var picture = false
        var colours = false
    }

    nonisolated(unsafe) static let homeData: FixtureData = {
        var d = FixtureData()
        Fixtures.home(into: &d, at: 0, seed: 3)
        d.finish()
        return d
    }()
    nonisolated(unsafe) static let diskData = Fixtures.disk()
    /// The home folder with every list smallest first, as a tree whose sizes changed after it was sorted can be.
    nonisolated(unsafe) static let unsortedData: FixtureData = {
        var d = homeData
        for i in d.nodes.indices { d.nodes[i].children.reverse() }
        return d
    }()
    nonisolated(unsafe) static let partialData = Fixtures.disk(partial: true)
    nonisolated(unsafe) static let pairData = Fixtures.pair()
    nonisolated(unsafe) static let libraryData = Fixtures.library()

    /// The first folder inside, `levels` times over: somewhere deep to zoom into.
    static func deep(_ path: String, _ levels: Int) -> (FixtureData) -> UInt32 {
        { d in
            var at = d.node(named: path)
            for _ in 0..<levels {
                guard let next = d.nodes[Int(at)].children.first(where: { d.nodes[Int($0)].folder }) else { break }
                at = next
            }
            return at
        }
    }

    static var all: [Case] {
        [
            Case(name: "home-tapered6", data: homeData, marked: true, calm: true, labels: true, picture: true, colours: true),
            Case(name: "home-standard6", data: homeData, sizes: RingSizes(depth: 6, style: .standard)),
            Case(name: "home-adaptive6", data: homeData, sizes: RingSizes(depth: 6, style: .adaptive), labels: true),
            Case(name: "home-tapered3", data: homeData, sizes: RingSizes(depth: 3, style: .tapered)),
            Case(name: "home-tapered12", data: homeData, sizes: RingSizes(depth: 12, style: .tapered)),
            Case(name: "home-zoom-library", data: homeData, focus: { $0.node(named: "Library") }, labels: true),
            Case(name: "home-zoom-deep", data: homeData, focus: deep("Videos", 2), marked: true),
            Case(name: "home-unsorted", data: unsortedData, sizes: RingSizes(depth: 7, style: .adaptive), labels: true),
            Case(name: "disk-root", data: diskData, marked: true, calm: true, labels: true, picture: true, colours: true),
            Case(name: "disk-root-adaptive", data: diskData, sizes: RingSizes(depth: 8, style: .adaptive)),
            Case(name: "disk-zoom-yours", data: diskData, focus: { $0.node(named: "Your files") }, labels: true, colours: true),
            Case(name: "disk-zoom-library", data: diskData, focus: { $0.node(named: "Your files/Library") }),
            Case(name: "disk-partial", data: partialData, labels: true),
            Case(name: "pair-root", data: pairData, marked: true, calm: true, labels: true, picture: true),
            Case(name: "pair-zoom-mac", data: pairData, focus: { $0.node(named: "This Mac") }, labels: true),
            Case(name: "pair-zoom-movies", data: pairData, focus: { $0.node(named: "This Mac/Movies") }),
            Case(name: "library-root", data: libraryData, marked: true, labels: true, picture: true),
            Case(name: "library-zoom-tv", data: libraryData, focus: { $0.node(named: "TV") }, sizes: RingSizes(depth: 4, style: .standard)),
        ]
    }

    static func bits(_ f: Float) -> String { String(f.bitPattern, radix: 16) }
    static func bits(_ d: CGFloat) -> String { String(Double(d).bitPattern, radix: 16) }
    static func bits(_ v: SIMD3<Float>) -> String { "\(bits(v.x)),\(bits(v.y)),\(bits(v.z))" }

    /// The layout and everything asked of it, for one case.
    @MainActor
    static func dump(_ c: Case) -> (text: String, layout: RingLayout, tree: FixtureTree) {
        let tree = FixtureTree(c.data)
        let focus = c.focus(c.data)
        let parts = tree.parts(c.sizes)
        var layout = RingLayout.build(tree: tree, focus: focus, parts: parts, colorer: FixtureTree.colour,
                                      marked: c.marked ? { $0 % 17 == 3 } : nil)
        if c.calm { layout.calmTinyPieces(total: tree.size(of: focus)) }
        var out = "case \(c.name) focus=\(focus) rings=\(layout.rings) reach=\(layout.reach) "
        out += "outer=\(layout.outerSmaller.map(String.init) ?? "-") free=\(layout.roomPiece.map(String.init) ?? "-")\n"
        out += "fill " + layout.fill.map(bits).joined(separator: " ") + "\n"
        out += "measured " + RingLayout.fill(tree: tree, focus: focus, parts: parts).map(bits).joined(separator: " ") + "\n"
        for (i, p) in layout.pieces.enumerated() {
            out += "P \(i) \(p.node) \(p.tail) \(String(p.key, radix: 16)) \(bits(p.a0)) \(bits(p.a1)) \(bits(p.r0)) \(bits(p.r1)) "
            out += "\(p.ring) \(p.parent) \(p.end) \(p.isSmaller ? 1 : 0) \(p.smallerCount) \(bits(p.color)) \(look(p)) "
            out += "\(bits(p.seed)) \(p.size) \(bits(p.calm)) \(bits(p.marked)) \(bits(p.deeper))\n"
        }
        for (i, _) in layout.pieces.enumerated() {
            let e = layout.extent(of: i), s = layout.stretches(around: i)
            out += "X \(i) \(e.lowerBound)..<\(e.upperBound) \(s.lowerBound)...\(s.upperBound) \(layout.smallerPiece(in: i).map(String.init) ?? "-")\n"
        }
        for node in 0..<UInt32(c.data.nodes.count) {
            let piece = layout.piece(of: node).map(String.init) ?? "-"
            let near = layout.nearestPiece(to: node, tree: tree).map(String.init) ?? "-"
            out += "N \(node) \(piece) \(near) \(RingLayout.chainTail(tree: tree, node))\n"
        }
        for node in 0..<UInt32(c.data.nodes.count) where c.data.nodes[Int(node)].folder && !(node == 0 && c.data.halves) {
            let v = RingLayout.visibleChildren(tree: tree, of: node)
            out += "V \(node) \(v.kids.map(String.init).joined(separator: ",")) \(v.tail) \(v.ownBytes)\n"
        }
        for a in 0..<96 {
            let angle = Float(a) / 96 * 2 * .pi + 0.013
            let hits = (0..<24).map { r in layout.hit(angle: angle, radius: Float(r) / 22).map(String.init) ?? "-" }
            out += "H \(a) " + hits.joined(separator: " ") + "\n"
        }
        if c.labels {
            let area = LabelArea(center: CGPoint(x: 600, y: 450), radius: 320, width: 1200, height: 900, top: 78, bottom: 860)
            let order = LabelPlacer.order(layout)
            out += "O " + order.prefix(200).map(String.init).joined(separator: ",") + "\n"
            var named = LabelPlacer.Placed()
            func said(_ p: Piece) -> (title: String, value: String) { (tree.name(of: p.node), SunburstFormat.bytes(p.size)) }
            let inside = LabelPlacer.inside(layout: layout, order: order, area: area, named: &named) { said($0) }
            let picks = LabelPlacer.bigPieces(layout: layout, order: order, named: &named) { said($0) }
            let sides = LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: false)
            for l in inside + sides {
                out += "L \(String(l.id, radix: 16)) \(l.pieceIndex) \(l.node) \(l.title)|\(l.value) \(bits(l.position.x)),\(bits(l.position.y)) "
                out += "\(bits(l.anchor.x)),\(bits(l.anchor.y)) \(bits(l.elbow.x)),\(bits(l.elbow.y)) \(l.place) \(l.dark) \(l.large)\n"
            }
        }
        if c.colours {
            let colours = BranchColours(tree: tree, focus: focus)
            for node in 0..<UInt32(c.data.nodes.count) {
                let lab = colours.lab(node)
                out += "C \(node) \(bits(lab.l)) \(bits(lab.a)) \(bits(lab.b))\n"
            }
        }
        return (out, layout, tree)
    }

    /// How the piece is drawn, in words that stay the same whatever the kit calls it.
    static func look(_ p: Piece) -> String { "s\(Int(p.look))" }

    /// The settled picture of a case, 360 points square at 2x, with no dither: the bytes and a PNG to look at.
    @MainActor
    static func picture(_ layout: RingLayout) -> (hash: UInt64, png: Data)? {
        let engine = SunburstEngine(reducesMotion: { true })
        guard engine.canDraw else { return nil }
        engine.apply(layout, .settle)
        guard let image = engine.picture(width: 720, height: 720, scale: 2, dithered: false),
              let bytes = image.dataProvider?.data as Data? else { return nil }
        let hash = bytes.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
        let png = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return (hash, png as Data)
    }
}

/// Writes the files the kit is checked against. Run once on the kit as it was: SNAPSHOT_OUT=<folder> swift test --filter SnapshotWriter
@Suite("Snapshot writer")
@MainActor
struct SnapshotWriter {
    @Test("Writes the snapshots", .enabled(if: ProcessInfo.processInfo.environment["SNAPSHOT_OUT"] != nil, "set SNAPSHOT_OUT to write"))
    func write() throws {
        let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SNAPSHOT_OUT"]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for c in SnapshotCases.all {
            let (text, layout, _) = SnapshotCases.dump(c)
            var all = text
            if c.picture, let pic = SnapshotCases.picture(layout) {
                all += "picture \(String(pic.hash, radix: 16))\n"
                try pic.png.write(to: folder.appendingPathComponent("\(c.name).png"))
            }
            try all.write(to: folder.appendingPathComponent("\(c.name).txt"), atomically: true, encoding: .utf8)
        }
    }
}
