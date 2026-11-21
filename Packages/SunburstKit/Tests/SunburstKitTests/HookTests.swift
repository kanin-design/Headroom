import AppKit
import Foundation
import SwiftUI
import Testing
@testable @_spi(Diagnostics) import SunburstKit

/// What an app says its own way, through the chart's hooks, and what it drives from code.
@Suite("Hooks")
@MainActor
struct HookTests {
    private let mb: UInt64 = 1_000_000

    private func chart() -> (SunburstChart<TestTree>, TestTree) {
        let tree = TestTree([("Films/a.mov", 400 * mb), ("Films/b.mov", 200 * mb), ("Music/c.mp3", 150 * mb), ("other", 100 * mb)])
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { true }))
        chart.place(center: CGPoint(x: 400, y: 300), radius: 250, size: CGSize(width: 800, height: 600))
        return (chart, tree)
    }

    private func middle(_ chart: SunburstChart<TestTree>, of node: UInt32) throws -> Polar {
        let p = try #require(chart.engine.layout.piece(of: node).map { chart.engine.layout.pieces[$0] })
        return (angle: p.midAngle, radius: (p.r0 + p.r1) / 2)
    }

    @Test("A marking asked of each node stripes what it says, in place of the marked set")
    func marking() {
        let (chart, tree) = chart()
        let films = tree.node("Films")
        chart.marked = [tree.node("Music")]
        chart.isMarked = { $0 == films }
        let marked = chart.engine.layout.pieces.filter { $0.marked > 0 }.map(\.node)
        #expect(marked == [films])
    }

    @Test("What else lights with a piece under the pointer lights with it, in its tint")
    func alsoLight() throws {
        let (chart, tree) = chart()
        let a = tree.node("Films/a.mov"), c = tree.node("Music/c.mp3")
        chart.alsoLight = { $0 == a ? .init([c], tint: [1, 0, 0]) : nil }
        chart.pointerMoved(to: try middle(chart, of: a))
        #expect(chart.engine.litPieces == 4, "a and c, and the folders they're in")
        chart.pointerMoved(to: try middle(chart, of: tree.node("other")))
        #expect(chart.engine.litPieces == 1)
    }

    @Test("Of what lights with a folder, only what the app says takes the colour; nothing elsewhere lights")
    func tints() throws {
        let (chart, tree) = chart()
        let films = tree.node("Films"), a = tree.node("Films/a.mov"), b = tree.node("Films/b.mov"), c = tree.node("Music/c.mp3")
        let at = { (node: UInt32) in chart.engine.layout.piece(of: node)! }
        chart.alsoLight = { _ in SunburstAlsoLit(tint: [0, 1, 0], tints: { $0 == a || $0 == c }) }
        chart.pointerMoved(to: try middle(chart, of: films))
        let emphasis = chart.engine.emphasis, shares = chart.engine.tintShares
        #expect(emphasis[at(films)] == 2 && emphasis[at(a)] == 1 && emphasis[at(b)] == 1, "the folder and all of it light")
        #expect(emphasis[at(c)] == 0, "a match outside it doesn't")
        #expect(shares[at(a)] == 1)
        #expect(shares[at(b)] == 0 && shares[at(films)] == 0, "the rest keeps its own colour")
        chart.alsoLight = nil
        chart.pointerMoved(to: try middle(chart, of: tree.node("other")))
        #expect(chart.engine.tintShares.allSatisfy { $0 == 1 }, "with no say, a tint is for all that's lit")
    }

    @Test("The app hears what's lit once, as it changes, not with every new picture")
    func point() throws {
        let (chart, tree) = chart()
        var heard: [UInt32?] = []
        chart.onPoint = { heard.append($0?.node) }
        let films = tree.node("Films")
        chart.pointerMoved(to: try middle(chart, of: films))
        chart.redraw(.live)
        chart.redraw(.settle)
        chart.pointerMoved(to: nil)
        #expect(heard == [films, nil])
        chart.pointerMoved(to: try middle(chart, of: films))
        chart.refreshPointer()
        #expect(heard == [films, nil, films, films], "asked again")
    }

    @Test("A click goes to the app first; what it doesn't handle, the chart does")
    func clicks() throws {
        let (chart, tree) = chart()
        let films = tree.node("Films")
        var seen: [SunburstClick] = []
        chart.onClick = { click in
            seen.append(click)
            if case .piece(let p) = click.target { return p.node == films && click.count == 1 }
            return false
        }
        let at = try #require(chart.engine.layout.piece(of: films))
        chart.click(piece: at, count: 1)
        #expect(chart.focus == 0, "handled by the app")
        chart.click(piece: at, count: 2)
        #expect(chart.focus == 0, "a second click is the app's or nothing")
        chart.onClick = nil
        chart.click(piece: at, count: 1)
        #expect(chart.focus == films, "the chart's own: a zoom")
        chart.click(at: (angle: 0, radius: 0.1), count: 1)
        #expect(chart.focus == 0, "the middle goes back")
        #expect(seen.count == 2)
    }

    @Test("Going back is the app's when it says so")
    func back() throws {
        let (chart, tree) = chart()
        var backs = 0
        chart.onBack = { backs += 1; return true }
        chart.zoom(into: tree.node("Films"))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        #expect(chart.key(escape))
        #expect(backs == 1)
        #expect(chart.focus == tree.node("Films"), "the app went nowhere")
    }

    @Test("A held node lights whenever nothing else is pointed at")
    func hold() throws {
        let (chart, tree) = chart()
        let music = tree.node("Music"), films = tree.node("Films")
        chart.hold(music)
        #expect(chart.hovered == music)
        chart.pointerMoved(to: try middle(chart, of: films))
        #expect(chart.hovered == films, "the pointer still lights what it's on")
        chart.pointerMoved(to: nil)
        #expect(chart.hovered == music, "and moving off brings the held one back")
        chart.hold(nil)
        #expect(chart.hovered == nil)
    }

    @Test("Names light their pieces; leaving one for the next doesn't put the light out")
    func labels() throws {
        let (chart, tree) = chart()
        let films = try #require(chart.engine.layout.piece(of: tree.node("Films")))
        let music = try #require(chart.engine.layout.piece(of: tree.node("Music")))
        chart.pointerOnLabel(piece: films)
        chart.pointerOnLabel(piece: music)
        chart.pointerLeftLabel(piece: films)
        #expect(chart.hovered == tree.node("Music"))
        chart.pointerLeftLabel(piece: music)
        #expect(chart.hovered == nil)
    }

    @Test("Something over the ring takes the pointer: what the ring lit goes, what the app lit stays")
    func covered() throws {
        let (chart, tree) = chart()
        chart.pointerMoved(to: try middle(chart, of: tree.node("Films")))
        chart.pointerCovered()
        #expect(chart.hovered == nil)
        chart.point(at: tree.node("Music"))
        chart.pointerCovered()
        #expect(chart.hovered == tree.node("Music"))
    }

    @Test("Several changes, one picture; a move of the middle inside moves as it says")
    func change() throws {
        let (chart, tree) = chart()
        let films = tree.node("Films")
        var focused: [UInt32] = []
        chart.onFocus = { focused.append($0) }
        let piece = chart.engine.layout.piece(of: films).map { chart.engine.layout.pieces[$0] }
        chart.change(.recolor) {
            chart.marked = [films]
            chart.colours = { _, _ in { _ in [0.5, 0.5, 0.5] } }
            chart.setFocus(films, .into(piece))
        }
        #expect(chart.focus == films)
        #expect(focused == [films])
        #expect(chart.engine.layout.pieces.allSatisfy { $0.color == [0.5, 0.5, 0.5] })
        chart.setFocus(0, .outFrom(films))
        #expect(chart.focus == 0)
    }

    @Test("A highlighted thing too small to draw still shows; light worked out by the app shows as it works it out")
    func highlight() throws {
        var files: [(String, UInt64)] = [("big/a", 900 * mb)]
        for i in 0..<40 { files.append(("big/tiny\(i)", 10_000)) }
        let tree = TestTree(files)
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { true }))
        #expect(chart.engine.layout.piece(of: tree.node("big/tiny3")) == nil)
        chart.highlight([tree.node("big/tiny3")])
        #expect(chart.engine.litPieces >= 1)
        chart.highlight { _ in RingLight(full: [0..<1]) }
        #expect(chart.engine.litPieces == 1)
        chart.clearHighlight()
        #expect(chart.engine.litPieces == 0)
    }

    @Test("What's highlighted stays lit as the numbers change, worked out again each time")
    func highlightLasts() throws {
        let (chart, tree) = chart()
        let films = tree.node("Films")
        chart.highlight([films], primary: tree.node("Films/a.mov"))
        let lit = chart.engine.litPieces
        #expect(lit >= 3, "Films, a.mov and b.mov")
        chart.redraw(.live)
        #expect(chart.engine.litPieces == lit)
        var asked = 0
        chart.highlight { layout in
            asked += 1
            return RingLight(full: layout.piece(of: films).map { [$0..<$0 + 1] } ?? [])
        }
        chart.redraw(.live)
        chart.pointerCovered()
        #expect(chart.engine.litPieces == 1)
        #expect(asked == 2, "once for each picture, not each time it's shown again")
    }

    @Test("Light from outside the ring goes when the pointer comes onto it, or the picture changes")
    func highlightGoes() throws {
        let (chart, tree) = chart()
        let music = tree.node("Music")
        chart.highlight([music], tint: [1, 0, 0])
        #expect(chart.engine.litPieces >= 2)
        chart.pointerMoved(to: try middle(chart, of: tree.node("Films")))
        chart.pointerMoved(to: nil)
        #expect(chart.engine.litPieces == 0, "pointing at the ring let go of it, so leaving lights nothing")
        chart.highlight([music])
        chart.pointerMoved(to: (angle: 0, radius: 0.1))
        #expect(chart.engine.litPieces == 0, "the middle is the ring too")
        chart.highlight([music])
        chart.redraw(.recolor)
        #expect(chart.engine.litPieces == 0, "a new kind of picture")
    }

    @Test("A namer says what's named")
    func namer() {
        struct OnlyMusic: SunburstNamer {
            let music: UInt32
            func inside(_ piece: Piece) -> (title: String, value: String)? { piece.node == music ? ("Songs", "lots") : nil }
            func sides(_ layout: RingLayout, order: [Int], named: inout LabelPlacer.Placed) -> [LabelPlacer.Pick] { [] }
        }
        let (chart, tree) = chart()
        chart.namer = OnlyMusic(music: tree.node("Music"))
        #expect(chart.labels.map(\.title) == ["Songs"])
        chart.showsLabels = false
        #expect(!chart.labelsVisible)
    }

    @Test("A point on screen and a node's place on it agree")
    func geometry() throws {
        let (chart, tree) = chart()
        let films = tree.node("Films")
        let at = try #require(chart.location(of: films))
        let back = try #require(chart.polar(of: at))
        #expect(chart.node(at: back) == films)
    }

    @Test("A held node lights at once, even with the pointer resting on the ring")
    func holdTakesOver() throws {
        let (chart, tree) = chart()
        let music = tree.node("Music"), films = tree.node("Films")
        chart.pointerMoved(to: try middle(chart, of: films))
        chart.hold(music)
        #expect(chart.hovered == music)
        chart.redraw(.live)
        #expect(chart.hovered == music, "and stays lit through a new picture")
        chart.pointerMoved(to: try middle(chart, of: films))
        #expect(chart.hovered == films, "until the pointer moves")
    }

    @Test("Each stretch of a folder is heard as it's pointed at")
    func stretches() throws {
        var tree = TestTree([("Films/a.mov", 400 * mb), ("Films/b.mov", 200 * mb), ("other", 100 * mb)])
        let films = tree.node("Films")
        tree.cut[films] = [SunburstStretch(size: 1, key: 1), SunburstStretch(size: 1, key: 2)]
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, parts: tree.parts, engine: SunburstEngine(reducesMotion: { true }))
        chart.place(center: CGPoint(x: 400, y: 300), radius: 250, size: CGSize(width: 800, height: 600))
        var heard: [Int?] = []
        chart.onPoint = { heard.append($0?.piece) }
        let first = try #require(chart.engine.layout.piece(of: films))
        let pieces = chart.engine.layout.pieces
        for at in [first, first + 1, first + 1] {
            chart.pointerMoved(to: (angle: pieces[at].midAngle, radius: (pieces[at].r0 + pieces[at].r1) / 2))
        }
        #expect(heard == [first, first + 1])
    }

    @Test("While a zoom flies, nothing is pointed at; then what's under the pointer is said again")
    func zoomLetsGo() async throws {
        let (chart, tree) = chart()
        var heard: [UInt32?] = []
        chart.onPoint = { heard.append($0?.node) }
        let music = tree.node("Music")
        chart.pointerMoved(to: try middle(chart, of: music))
        chart.zoom(into: music)
        #expect(heard == [music, nil])
        // Once the pieces are nearly in place, 0.42 s on; later if other tests hold the main actor.
        for _ in 0..<60 where heard.count < 3 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(heard.count == 3, "said again once the pieces are in place")
    }

    @Test("Spreading two fingers over the middle is the app's, and never a way back")
    func pinch() throws {
        let (chart, tree) = chart()
        chart.zoom(into: tree.node("Films"))
        var seen: [SunburstClick] = []
        chart.onClick = { seen.append($0); return false }
        chart.pinchOpen(at: (angle: 0, radius: 0.1))
        #expect(seen == [SunburstClick(target: .centre, byPinch: true)])
        #expect(chart.focus == tree.node("Films"))
    }

    @Test("A different tree forgets what was pointed at and held")
    func newTree() throws {
        let (chart, tree) = chart()
        chart.hold(tree.node("Music"))
        chart.point(at: tree.node("Films"))
        chart.show(TestTree([("x", 10 * mb), ("y", 5 * mb)]))
        chart.pointerMoved(to: nil)
        #expect(chart.hovered == nil)
    }

    @Test("Several changes to what's named place the names once, with the new picture")
    func namesOnce() {
        final class Counting: SunburstNamer {
            var asked = 0
            func inside(_ piece: Piece) -> (title: String, value: String)? { nil }
            func sides(_ layout: RingLayout, order: [Int], named: inout LabelPlacer.Placed) -> [LabelPlacer.Pick] {
                asked += 1
                return []
            }
        }
        let (chart, _) = chart()
        let namer = Counting()
        chart.change(.instant) {
            chart.namer = namer
            chart.valueText = { _ in "–" }
            chart.labelInsets = EdgeInsets(top: 30, leading: 0, bottom: 30, trailing: 0)
        }
        #expect(namer.asked == 1)
        chart.place(center: CGPoint(x: 400.3, y: 300), radius: 250, size: CGSize(width: 800, height: 600))
        #expect(namer.asked == 1, "a move under half a point isn't one")
    }

    @Test("A pointer asked about again inside a change is said once, with the new picture")
    func refreshInsideChange() throws {
        let (chart, tree) = chart()
        var heard = 0
        chart.onPoint = { _ in heard += 1 }
        chart.pointerMoved(to: try middle(chart, of: tree.node("Films")))
        chart.change(.live) {
            chart.marked = [tree.node("Music")]
            chart.refreshPointer()
        }
        #expect(heard == 2)
    }

    @Test("New parts at once, or gliding")
    func setParts() {
        let (chart, _) = chart()
        chart.setParts(SunburstParts(rings: .init(RingSizes(depth: 1))), animated: false)
        #expect(chart.engine.layout.rings == 1)
        chart.setParts(SunburstParts())
        #expect(chart.engine.layout.rings > 1)
    }
}
