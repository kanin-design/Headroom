import AppKit
import Foundation
import Testing
@testable import SunburstKit

/// Names set along the arc of their piece.
@Suite("Names along arcs")
@MainActor
struct ArcTextTests {
    private let font = LabelFont.title.font
    private let mb: UInt64 = 1_000_000

    @Test("A line is its glyphs in reading order, each around its own middle")
    func glyphs() {
        let line = GlyphLine.make("Media 12", font: font)
        #expect(line.glyphs.count == 8)
        #expect(line.width > 30 && line.width < 80)
        #expect(zip(line.glyphs, line.glyphs.dropFirst()).allSatisfy { $0.middle < $1.middle })
        #expect(line.glyphs[5].outline == nil || line.glyphs[5].outline!.isEmpty, "a space draws nothing")
        let m = try! #require(line.glyphs[0].outline).boundingBoxOfPath
        #expect(abs(m.midX) < 1.5, "an outline sits around its own middle")
        #expect(GlyphLine.make("Media 12", font: font).width == line.width)
    }

    @Test("At the top it reads clockwise with its top outwards, on the circle it's given")
    func top() {
        let line = GlyphLine.make("Hxx", font: font)
        let path = ArcText.path(line, center: CGPoint(x: 200, y: 200), radius: 100, angle: 0, turned: false)
        let box = path.boundingBoxOfPath
        #expect(abs(box.midX - 200) < 1.5, "its middle is at the angle")
        #expect(abs(box.maxY - 100) < 1.2, "the baseline is on the circle")
        #expect(box.minY < 93 && box.minY > 88, "and capitals stand outwards from it")
        let first = ArcText.path(GlyphLine.make("H", font: font), center: CGPoint(x: 200, y: 200), radius: 100,
                                 angle: -line.width / 2 / 100, turned: false).boundingBoxOfPath
        #expect(first.midX < 200, "the first letter is on the left")
    }

    @Test("It reads clockwise across the top and down both sides; only the bottom third is turned, never upside down")
    func bottom() {
        #expect(!ArcText.isTurned(at: 0.3) && !ArcText.isTurned(at: 2 * .pi - 0.3))
        // Down the sides, past 3 and 9 o'clock, names still read clockwise, as their neighbours above them do.
        #expect(!ArcText.isTurned(at: .pi / 2 + 0.3) && !ArcText.isTurned(at: 3 * .pi / 2 - 0.3))
        #expect(!ArcText.isTurned(at: .pi * 0.66) && !ArcText.isTurned(at: .pi * 1.34))
        #expect(ArcText.isTurned(at: .pi) && ArcText.isTurned(at: .pi * 0.75) && ArcText.isTurned(at: .pi * 1.25))
        #expect(ArcText.isTurned(at: -.pi) && !ArcText.isTurned(at: 2 * .pi + 0.3), "any turn of the circle")
        let line = GlyphLine.make("Hxx", font: font)
        let center = CGPoint(x: 200, y: 200)
        let box = ArcText.path(line, center: center, radius: 100, angle: .pi, turned: true).boundingBoxOfPath
        #expect(abs(box.midX - 200) < 1.5)
        #expect(abs(box.maxY - 300) < 1.2, "the baseline is on the circle, at the bottom")
        #expect(box.minY > 288 && box.minY < 293, "and capitals stand inwards, which is up there")
        // The capital is the first letter: it's the tallest, so the left third of the line reaches highest.
        var leftTop = CGFloat.infinity, rightTop = CGFloat.infinity
        ArcText.path(line, center: center, radius: 100, angle: .pi, turned: true).applyWithBlock { element in
            let p = element.pointee.points[0]
            if p.x < box.minX + box.width / 3 { leftTop = min(leftTop, p.y) }
            if p.x > box.maxX - box.width / 3 { rightTop = min(rightTop, p.y) }
        }
        #expect(leftTop < rightTop - 1, "the capital H is on the left")
    }

    @Test("Stacked, the name is above its size: outside it where it reads clockwise, inside it where it's turned")
    func stacked() {
        func setting(at angle: CGFloat) -> ArcSetting {
            ArcSetting(title: "Films", value: "12 GB", arc: .init(center: .zero, radius: 200, angle: angle, lines: .stacked))
        }
        let up = setting(at: 0.4), down = setting(at: .pi + 0.4)
        #expect(up.lines.count == 2 && !up.turned && down.turned)
        #expect(up.lines[0].radius > up.lines[1].radius + 10)
        #expect(down.lines[0].radius < down.lines[1].radius - 10)
        #expect(!up.lines[0].isValue && up.lines[1].isValue)
    }

    @Test("On one line, the name comes first the way it reads")
    func inLine() {
        func setting(at angle: CGFloat) -> ArcSetting {
            ArcSetting(title: "Films", value: "12 GB", arc: .init(center: .zero, radius: 200, angle: angle, lines: .inLine))
        }
        let up = setting(at: 0.4), down = setting(at: .pi + 0.4)
        #expect(up.lines[0].angle < 0.4 && up.lines[1].angle > 0.4, "clockwise: the name at the smaller angle")
        #expect(down.lines[0].angle > .pi + 0.4 && down.lines[1].angle < .pi + 0.4, "turned: at the larger")
        #expect(abs(up.lines[0].radius - up.lines[1].radius) < 0.01)
        let alone = ArcSetting(title: "Films", value: "12 GB", arc: .init(center: .zero, radius: 200, angle: 0.4, lines: .titleOnly))
        #expect(alone.lines.count == 1 && abs(alone.lines[0].angle - 0.4) < 0.0001)
    }

    @Test("A name fits along an arc that's long enough, in as many lines as the band holds")
    func fitting() throws {
        // Films is a long piece of the second ring, too thin for a name set straight.
        let tree = TestTree([("Media/Films/a.mov", 350 * mb), ("Media/Films/b.mov", 250 * mb), ("Media/c.mov", 300 * mb), ("other", 100 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in .zero })
        let films = try #require(layout.piece(of: tree.node("Media/Films")).map { layout.pieces[$0] })
        #expect(films.ring == 1 && films.sweep > 3)
        func area(_ radius: CGFloat) -> LabelArea {
            LabelArea(center: CGPoint(x: 500, y: 400), radius: radius, width: 1000, height: 800, bottom: 776)
        }
        let band = CGFloat(films.r1 - films.r0)
        // A ring big enough that the band holds two lines, then one, then none.
        let two = try #require(LabelPlacer.along(title: "Films", value: "900 MB", piece: films, area: area(34 / band)))
        #expect(two.lines == .stacked)
        #expect(abs(two.radius - CGFloat(films.r0 + films.r1) / 2 * 34 / band) < 0.01 && two.center == CGPoint(x: 500, y: 400))
        #expect(abs(two.angle - CGFloat(films.midAngle)) < 0.0001)
        let one = try #require(LabelPlacer.along(title: "Films", value: "900 MB", piece: films, area: area(24 / band)))
        #expect(one.lines == .inLine)
        #expect(LabelPlacer.along(title: "Films", value: "900 MB", piece: films, area: area(14 / band)) == nil, "too thin for any")
        // A name too long for the arc with its size keeps the name; longer still, nothing.
        let long = String(repeating: "W", count: Int(CGFloat(films.sweep) * CGFloat(films.r0 + films.r1) / 2 * 24 / band / 13))
        #expect(LabelPlacer.along(title: long, value: "900 MB", piece: films, area: area(24 / band))?.lines == .titleOnly)
        #expect(LabelPlacer.along(title: long + long, value: "900 MB", piece: films, area: area(24 / band)) == nil)
        #expect(LabelPlacer.along(title: "Films", value: "", piece: films, area: area(34 / band))?.lines == .titleOnly, "nothing to say under it")
    }

    @Test("A long thin piece is named along its arc, and then not at the side as well")
    func placed() throws {
        let tree = TestTree([("Media/Films/a.mov", 350 * mb), ("Media/Films/b.mov", 250 * mb), ("Media/c.mov", 300 * mb), ("other", 100 * mb)])
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in .zero })
        let area = LabelArea(center: CGPoint(x: 500, y: 400), radius: 300, width: 1000, height: 800, bottom: 776)
        var named = LabelPlacer.Placed()
        let labels = LabelPlacer.inside(layout: layout, order: LabelPlacer.order(layout), area: area, named: &named) { p in
            // Too wide to sit straight in a band that curves away under it.
            p.isSmaller ? nil : (p.node == tree.node("Media/Films") ? "Films from the last ten years" : tree.nodes[Int(p.node)].name, "1 GB")
        }
        let films = try #require(labels.first { $0.node == tree.node("Media/Films") })
        #expect(films.place == .along && films.arc != nil && !films.isAtSide)
        let at = try #require(layout.piece(of: tree.node("Media/Films")))
        #expect(named.labelled.contains(at))
        let picks = LabelPlacer.bigPieces(layout: layout, order: LabelPlacer.order(layout), named: &named) { _ in ("x", "y") }
        #expect(!picks.contains { $0.index == at })
        // Its middle is on its own piece.
        let dx = films.position.x - 500, dy = films.position.y - 400
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        #expect(layout.hit(angle: Float(angle), radius: Float(hypot(dx, dy) / 300)) == at)
        #expect(labels.contains { $0.place == .inside }, "and what fits set straight still is")
        #expect(labels.filter { layout.pieces[$0.pieceIndex].ring == 0 }.allSatisfy { $0.place == .inside },
                "the first ring is always set straight")
    }

    @Test("Past a band, the first ring of things is the one set straight")
    func pastABand() throws {
        // The band holds the two folders; what's in them is the first ring of things.
        var tree = TestTree([("Media/Films/a.mov", 350 * mb), ("Media/Films/b.mov", 250 * mb), ("Media/c.mov", 300 * mb),
                             ("Other/d.mov", 100 * mb)])
        tree.hasBand = true
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in .zero })
        #expect(layout.levels.first?.isThin == true)
        let area = LabelArea(center: CGPoint(x: 500, y: 400), radius: 300, width: 1000, height: 800, bottom: 776)
        var named = LabelPlacer.Placed()
        let labels = LabelPlacer.inside(layout: layout, order: LabelPlacer.order(layout), area: area, named: &named) { p in
            p.isSmaller ? nil : (tree.nodes[Int(p.node)].name, "1 GB")
        }
        #expect(!labels.contains { layout.pieces[$0.pieceIndex].ring == 0 }, "nothing is named on the band")
        let first = labels.filter { layout.pieces[$0.pieceIndex].ring == 1 }
        #expect(first.count >= 2 && first.allSatisfy { $0.place == .inside })
        let a = try #require(labels.first { $0.node == tree.node("Media/Films/a.mov") })
        #expect(layout.pieces[a.pieceIndex].ring == 2 && a.place == .along)
    }
}

/// Names out at the sides, when the things they name are crowded together.
@Suite("Names at the sides")
@MainActor
struct SideNameTests {
    private let mb: UInt64 = 1_000_000

    /// Half the ring is one folder whose six small things end at six o'clock, on the right; the other half is one file.
    private func crowded() -> (RingLayout, TestTree, [LabelPlacer.Pick]) {
        var files: [(String, UInt64)] = [("A/big.mov", 300 * mb), ("B.mov", 500 * mb)]
        for i in 1...6 { files.append(("A/small\(i).mov", UInt64(40 - i) * mb)) }
        let tree = TestTree(files)
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in .zero })
        let picks = (1...6).map { i -> LabelPlacer.Pick in
            let at = layout.piece(of: tree.node("A/small\(i).mov"))!
            return LabelPlacer.Pick(index: at, title: "small\(i)", value: "1 MB", score: Double(40 - i))
        }
        return (layout, tree, picks)
    }

    private let area = LabelArea(center: CGPoint(x: 500, y: 400), radius: 250, width: 1000, height: 800, bottom: 776)

    @Test("Things crowded near six o'clock on one side are named on both")
    func shared() {
        let (layout, _, picks) = crowded()
        #expect(picks.allSatisfy { layout.pieces[$0.index].midAngle < .pi }, "all on the right, to begin with")
        let labels = LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: true)
        let right = labels.filter { $0.place == .right }, left = labels.filter { $0.place == .left }
        #expect(!left.isEmpty && !right.isEmpty)
        #expect(abs(left.count - right.count) <= 1)
        // What crossed over is what's nearest six o'clock.
        let crossed = left.map { layout.pieces[$0.pieceIndex].midAngle }, stayed = right.map { layout.pieces[$0.pieceIndex].midAngle }
        #expect(crossed.min()! > stayed.max()!)
    }

    @Test("No name is far from its piece, and no line crosses another")
    func near() {
        let (layout, _, picks) = crowded()
        let labels = LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: true)
        for side in [SunburstLabel.Place.left, .right] {
            let names = labels.filter { $0.place == side }.sorted { $0.position.y < $1.position.y }
            for (a, b) in zip(names, names.dropFirst()) {
                #expect(b.position.y - a.position.y >= 34.9, "a name has its own room")
                // Down the right side angles grow; down the left, past six o'clock, they shrink.
                let first = layout.pieces[a.pieceIndex].midAngle, second = layout.pieces[b.pieceIndex].midAngle
                #expect(side == .right ? first < second : first > second)
            }
            for name in names {
                let mid = CGFloat(layout.pieces[name.pieceIndex].midAngle)
                let level = min(max(400 - cos(mid) * (250 + 26), 24), 776)
                #expect(abs(name.position.y - level) <= 35 * 2.5 + 0.01)
            }
        }
    }

    @Test("Names pushed far from their pieces go, least important first")
    func farOnesGo() {
        // Twenty things in the last sixth of the right side: far more than fit near them.
        var files: [(String, UInt64)] = [("A/big.mov", 300 * mb), ("B.mov", 500 * mb)]
        for i in 1...20 { files.append(("A/s\(i).mov", UInt64(30 - i) * mb / 3)) }
        let tree = TestTree(files)
        let layout = RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in .zero })
        let picks = (1...20).compactMap { i -> LabelPlacer.Pick? in
            layout.piece(of: tree.node("A/s\(i).mov")).map { LabelPlacer.Pick(index: $0, title: "s\(i)", value: "1 MB", score: Double(30 - i)) }
        }
        #expect(picks.count >= 10)
        let labels = LabelPlacer.sides(picks, layout: layout, area: area, eachCounts: true)
        #expect(!labels.isEmpty && labels.count < picks.count)
        for name in labels {
            let mid = CGFloat(layout.pieces[name.pieceIndex].midAngle)
            let level = min(max(400 - cos(mid) * (250 + 26), 24), 776)
            #expect(abs(name.position.y - level) <= 35 * 2.5 + 0.01)
        }
        #expect(labels.contains { $0.title == "s1" }, "the most important is still named")
    }
}
