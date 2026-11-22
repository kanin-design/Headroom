import AppKit
import Foundation
import Testing
@testable @_spi(Diagnostics) import SunburstKit

/// Who points at the ring, and what lights for it: the rules a chart follows, without a chart.
@Suite("Pointing and light")
@MainActor
struct AttentionTests {
    private let mb: UInt64 = 1_000_000

    private func picture() -> (RingLayout, TestTree) {
        let tree = TestTree([("Films/a.mov", 400 * mb), ("Films/b.mov", 200 * mb), ("Music/c.mp3", 150 * mb), ("other", 100 * mb)])
        return (RingLayout.build(tree: tree, focus: 0, parts: tree.parts, colorer: { _ in .zero }), tree)
    }

    private func middle(_ layout: RingLayout, of node: UInt32) throws -> Polar {
        let p = try #require(layout.piece(of: node).map { layout.pieces[$0] })
        return (angle: p.midAngle, radius: (p.r0 + p.r1) / 2)
    }

    // MARK: Who points

    @Test("The pointer on the ring points at the piece under it")
    func pointer() throws {
        let (layout, tree) = picture()
        var attention = RingAttention()
        #expect(attention.pointedPiece(in: layout, tree: tree) == nil)
        attention.pointerMoved(to: try middle(layout, of: tree.node("Music")))
        #expect(attention.pointedPiece(in: layout, tree: tree) == layout.piece(of: tree.node("Music")))
        attention.pointerMoved(to: (angle: 0, radius: 2))
        #expect(attention.pointedPiece(in: layout, tree: tree) == nil, "off the ring, nothing")
    }

    @Test("A node pointed at from outside stays pointed at until the pointer moves on the ring")
    func pointed() throws {
        let (layout, tree) = picture()
        let a = tree.node("Films/a.mov")
        var attention = RingAttention()
        attention.pointerMoved(to: try middle(layout, of: tree.node("Music")))
        attention.point(at: a)
        #expect(attention.pointedPiece(in: layout, tree: tree) == layout.piece(of: a), "it takes over from a resting pointer")
        attention.pointerMoved(to: try middle(layout, of: tree.node("other")))
        #expect(attention.pointedPiece(in: layout, tree: tree) == layout.piece(of: tree.node("other")))
        attention.pointerMoved(to: nil)
        #expect(attention.pointedPiece(in: layout, tree: tree) == nil, "and the pointer moving lets go of it")
    }

    @Test("Something over the ring taking the pointer puts out only what the pointer lit")
    func covered() throws {
        let (layout, tree) = picture()
        var attention = RingAttention()
        attention.pointerMoved(to: try middle(layout, of: tree.node("Music")))
        let pointerLit = attention.pointerCovered()
        #expect(pointerLit)
        #expect(attention.pointedPiece(in: layout, tree: tree) == nil)
        attention.point(at: tree.node("Films"))
        let nameLit = attention.pointerCovered()
        #expect(!nameLit, "what a name lit stays lit under the name")
        #expect(attention.pointedPiece(in: layout, tree: tree) == layout.piece(of: tree.node("Films")))
    }

    @Test("A held node takes over at once, and comes back whenever nothing else is pointed at")
    func held() throws {
        let (layout, tree) = picture()
        let films = tree.node("Films")
        var attention = RingAttention()
        attention.pointerMoved(to: try middle(layout, of: tree.node("Music")))
        attention.hold(films)
        #expect(attention.pointedPiece(in: layout, tree: tree) == nil, "the resting pointer no longer points")
        #expect(attention.heldPiece(in: layout, tree: tree) == layout.piece(of: films))
        attention.pointerMoved(to: try middle(layout, of: tree.node("other")))
        #expect(attention.pointedPiece(in: layout, tree: tree) == layout.piece(of: tree.node("other")))
        #expect(attention.heldPiece(in: layout, tree: tree) == layout.piece(of: films), "still held under it")
        attention.hold(nil)
        #expect(attention.heldPiece(in: layout, tree: tree) == nil)
        #expect(attention.pointedPiece(in: layout, tree: tree) == layout.piece(of: tree.node("other")), "letting go leaves the pointer")
    }

    @Test("Letting go of what was pointed at leaves a resting pointer where it is")
    func letGo() throws {
        let (layout, tree) = picture()
        var attention = RingAttention()
        attention.point(at: tree.node("Films"))
        attention.letGoOfPointed()
        #expect(attention.pointedPiece(in: layout, tree: tree) == nil)
        attention.pointerMoved(to: try middle(layout, of: tree.node("Music")))
        attention.letGoOfPointed()
        #expect(attention.pointedPiece(in: layout, tree: tree) == layout.piece(of: tree.node("Music")))
    }

    // MARK: What lights

    @Test("Pointing at a piece lights it most, what's inside it whole, and the way out to it less")
    func pointingLights() throws {
        let (layout, tree) = picture()
        let films = try #require(layout.piece(of: tree.node("Films"))), a = try #require(layout.piece(of: tree.node("Films/a.mov")))
        let onFolder = layout.emphasis(pointingAt: films, in: tree)
        #expect(onFolder.primary == films)
        #expect(onFolder.light.full == [layout.extent(of: films)])
        #expect(onFolder.light.holding.isEmpty, "nothing holds what's straight around the middle")
        #expect(onFolder.tint == nil && onFolder.tinted == nil)
        let onFile = layout.emphasis(pointingAt: a, in: tree)
        #expect(onFile.primary == a)
        #expect(onFile.light.full == [a..<a + 1])
        #expect(onFile.light.holding == [films])
    }

    @Test("What the app says goes with a piece lights with it, and takes its colour")
    func lightingAdds() throws {
        let (layout, tree) = picture()
        let a = try #require(layout.piece(of: tree.node("Films/a.mov"))), c = try #require(layout.piece(of: tree.node("Music/c.mp3")))
        let films = try #require(layout.piece(of: tree.node("Films"))), music = try #require(layout.piece(of: tree.node("Music")))
        let emphasis = layout.emphasis(pointingAt: a, in: tree, lighting: SunburstLighting(also: [tree.node("Music/c.mp3")], tint: [1, 0, 0]))
        #expect(emphasis.primary == a)
        #expect(emphasis.light.full == [a..<a + 1, c..<c + 1])
        #expect(Set(emphasis.light.holding) == [films, music])
        #expect(emphasis.tint == [1, 0, 0])
        #expect(emphasis.tinted == nil, "with no say, the tint is for all that's lit")
    }

    @Test("Of a piece and what's inside it, only what the app says takes the colour")
    func lightingTints() throws {
        let (layout, tree) = picture()
        let films = try #require(layout.piece(of: tree.node("Films"))), a = try #require(layout.piece(of: tree.node("Films/a.mov")))
        let wanted = tree.node("Films/a.mov"), elsewhere = tree.node("Music/c.mp3")
        let emphasis = layout.emphasis(pointingAt: films, in: tree,
                                       lighting: SunburstLighting(tint: [0, 1, 0], tints: { $0 == wanted || $0 == elsewhere }))
        #expect(emphasis.light.full == [layout.extent(of: films)], "nothing elsewhere lights")
        #expect(emphasis.tinted == [a..<a + 1])
    }

    @Test("Nodes lit from outside the ring light whole, with the way out, and the primary stands out")
    func highlight() throws {
        let (layout, tree) = picture()
        let a = try #require(layout.piece(of: tree.node("Films/a.mov"))), c = try #require(layout.piece(of: tree.node("Music/c.mp3")))
        let emphasis = layout.emphasis(lighting: [tree.node("Films/a.mov"), tree.node("Music/c.mp3")], primary: tree.node("Music/c.mp3"),
                                       in: tree, tint: [0, 0, 1])
        #expect(emphasis.primary == c)
        #expect(emphasis.light.full == [a..<a + 1, c..<c + 1])
        #expect(emphasis.light.holding.count == 2)
        #expect(emphasis.tint == [0, 0, 1])
        #expect(!emphasis.isEmpty && RingEmphasis().isEmpty)
    }

    @Test("An engine shows an emphasis as the pieces it names")
    func engineShows() throws {
        let (layout, tree) = picture()
        let engine = SunburstEngine(reducesMotion: { true })
        engine.apply(layout, .instant)
        let films = try #require(layout.piece(of: tree.node("Films")))
        engine.setEmphasis(layout.emphasis(pointingAt: films, in: tree))
        #expect(engine.litPieces == layout.extent(of: films).count)
        #expect(engine.emphasis[films] == 2)
        engine.setEmphasis(nil)
        #expect(engine.litPieces == 0)
    }

    // MARK: Where the ring is

    @Test("The pointer is read against the ring as it's drawn, not where it's going")
    func ringAsDrawn() throws {
        let (_, tree) = picture()
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { true }))
        #expect(chart.polar(of: CGPoint(x: 10, y: 10)) == nil, "nowhere yet")
        // The view is told where the ring will rest; nothing is drawn yet, so that's all there is to go by.
        chart.place(center: CGPoint(x: 400, y: 300), radius: 200, size: CGSize(width: 800, height: 600))
        let resting = try #require(chart.polar(of: CGPoint(x: 400, y: 200)))
        #expect(abs(resting.radius - 0.5) < 0.001 && abs(resting.angle) < 0.001)
        // Mid-glide, the ring is drawn somewhere else: smaller and to the left.
        chart.engine.setPlace(center: CGPoint(x: 300, y: 300), radius: 100)
        let drawn = try #require(chart.polar(of: CGPoint(x: 300, y: 250)))
        #expect(abs(drawn.radius - 0.5) < 0.001 && abs(drawn.angle) < 0.001)
        let films = tree.node("Films")
        let at = try #require(chart.location(of: films)), back = try #require(chart.polar(of: at))
        #expect(chart.node(at: back) == films, "a piece is found where it's said to be")
        #expect(abs(at.x - 300) <= 100 && abs(at.y - 300) <= 100, "inside the ring as drawn")
    }
}

/// Names lit one by one, and a number that rolls only when it should.
@Suite("Names and numbers at the pointer's pace")
@MainActor
struct PaceTests {
    @Test("A name's state says whether it's pointed at, lit, or stepped back")
    func states() {
        let named: Set<UInt32> = [1, 2, 3]
        #expect(LabelLight().state(of: 1) == .atRest, "nothing pointed at")
        let light = LabelLight(hovering: 1, named: named, lit: [1, 2])
        #expect(light.state(of: 1) == .pointedAt)
        #expect(light.state(of: 2) == .atRest, "lit with it: as easy to read as ever")
        #expect(light.state(of: 3) == .steppedBack)
        let unnamed = LabelLight(hovering: 9, named: named, lit: [2])
        #expect(unnamed.state(of: 2) == .atRest && unnamed.state(of: 1) == .steppedBack)
    }

    @Test("A change of light is told only to the names it changes")
    func lights() {
        let lights = LabelLights()
        let named: Set<UInt32> = [1, 2, 3]
        #expect(lights.state(of: 1) == .atRest)
        func changes(of node: UInt32, when change: () -> Void) -> Bool {
            let changed = Flag()
            withObservationTracking { _ = lights.state(of: node) } onChange: { changed.isSet = true }
            change()
            return changed.isSet
        }
        // The pointer comes onto 1, which lights 2: 3 steps back, 2 stays as it was.
        let first = LabelLight(hovering: 1, named: named, lit: [1, 2])
        #expect(!changes(of: 2) { lights.show(first, now: 10) })
        #expect(lights.state(of: 1) == .pointedAt && lights.state(of: 3) == .steppedBack)
        // On to something unnamed in the same branch: only the name that was pointed at changes.
        let second = LabelLight(hovering: 7, named: named, lit: [1, 2])
        #expect(!changes(of: 3) { lights.show(second, now: 10.01) })
        #expect(lights.state(of: 1) == .atRest)
        #expect(changes(of: 3) { lights.show(LabelLight(), now: 11) }, "and off the ring, what stepped back comes back")
        // A name first asked about later starts in the light as it is.
        lights.show(first, now: 12)
        #expect(lights.state(of: 3) == .steppedBack)
        lights.keep([1])
        lights.show(LabelLight(), now: 13)
        #expect(lights.state(of: 3) == .atRest, "a name forgotten and asked about again")
    }

    @Test("Lights that change in quick succession don't fade")
    func fades() {
        let lights = LabelLights()
        let named: Set<UInt32> = [1, 2]
        lights.show(LabelLight(hovering: 1, named: named), now: 100)
        #expect(lights.fades, "the first, after a rest")
        lights.show(LabelLight(hovering: 2, named: named), now: 100.03)
        #expect(!lights.fades, "the pointer is travelling")
        lights.show(LabelLight(hovering: 1, named: named), now: 100.5)
        #expect(lights.fades, "and has rested")
    }

    @Test("A number rolls when the same thing changes size, after a moment to be read")
    func rolls() {
        let pace = RollPace()
        #expect(!pace.rolls(to: 100, about: "a", now: 1), "the first value is simply there")
        #expect(pace.rolls(to: 120, about: "a", now: 2))
        #expect(pace.rolls(to: 120, about: "a", now: 2.001), "asked again for the same value, the same answer")
        #expect(!pace.rolls(to: 130, about: "a", now: 2.02), "replaced before it could be read")
        #expect(!pace.rolls(to: 900, about: "b", now: 5), "another thing: the number just changes")
        #expect(!pace.rolls(to: 900, about: "c", now: 9), "even at the same size")
        #expect(pace.rolls(to: 950, about: "c", now: 10))
        let plain = RollPace()
        _ = plain.rolls(to: 1, now: 1)
        #expect(plain.rolls(to: 2, now: 2), "with nothing said about what it's about, every new value rolls")
    }

    @Test("Names keep their light for a moment after the pointer leaves what lit them")
    func namesLetGoLate() async throws {
        let mb: UInt64 = 1_000_000
        let tree = TestTree([("Films/a.mov", 400 * mb), ("Films/b.mov", 200 * mb), ("Music/c.mp3", 150 * mb), ("other", 100 * mb)])
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { true }))
        chart.place(center: CGPoint(x: 400, y: 300), radius: 250, size: CGSize(width: 800, height: 600))
        chart.relabel()
        let films = tree.node("Films")
        let p = try #require(chart.engine.layout.piece(of: films).map { chart.engine.layout.pieces[$0] })
        chart.pointerMoved(to: (angle: p.midAngle, radius: (p.r0 + p.r1) / 2))
        #expect(chart.labelLight.onAnything)
        chart.pointerMoved(to: nil)
        #expect(chart.hovered == nil, "nothing is pointed at")
        #expect(chart.labelLight.onAnything, "but the names haven't moved yet")
        chart.pointerMoved(to: (angle: p.midAngle, radius: (p.r0 + p.r1) / 2))
        try await Task.sleep(for: .milliseconds(160))
        #expect(chart.labelLight.onAnything, "back on a piece in time: they never did")
        chart.pointerMoved(to: nil)
        #expect(await eventually { !chart.labelLight.onAnything }, "and off for good, they come back")
    }
}

private final class Flag: @unchecked Sendable {
    var isSet = false
}

/// Names stay on the ring while it moves, as when a window is resized.
@Suite("Names follow the ring")
@MainActor
struct FollowTests {
    private let mb: UInt64 = 1_000_000

    @Test("A name on a piece moves and scales with the ring; one at the side keeps its room from the edge")
    func following() {
        let old = RingPlacement(center: CGPoint(x: 400, y: 300), radius: 200), new = RingPlacement(center: CGPoint(x: 300, y: 250), radius: 100)
        let inside = SunburstLabel(id: 1, pieceIndex: 0, node: 1, title: "a", value: "1 GB", position: CGPoint(x: 400, y: 200),
                                   anchor: .zero, elbow: .zero, place: .inside, dark: false, large: false)
        #expect(inside.following(from: old, to: new).position == CGPoint(x: 300, y: 200), "halfway out, at 12 o'clock, either way")
        var arc = inside
        arc.place = .along
        arc.arc = .init(center: old.center, radius: 150, angle: 0.5, lines: .stacked)
        let movedArc = arc.following(from: old, to: new).arc
        #expect(movedArc?.center == new.center && movedArc?.radius == 75 && movedArc?.angle == 0.5)
        let side = SunburstLabel(id: 2, pieceIndex: 0, node: 2, title: "b", value: "2 GB", position: CGPoint(x: 634, y: 120),
                                 anchor: CGPoint(x: 541, y: 159), elbow: CGPoint(x: 580, y: 120), place: .right, dark: false, large: false)
        let movedSide = side.following(from: old, to: new)
        #expect(movedSide.position == CGPoint(x: 434, y: 70), "34 points out from the edge, as before, and up with the ring")
        #expect(movedSide.elbow == CGPoint(x: 380, y: 70))
        #expect(abs(movedSide.anchor.x - 370.5) < 0.001 && abs(movedSide.anchor.y - 179.5) < 0.001, "the line still starts on its piece")
        #expect(side.following(from: old, to: old) == side)
    }

    @Test("While the ring moves the names stay, following it, and once it rests they're placed again for where it is")
    func restsThenPlaces() async throws {
        let tree = TestTree([("Films/a.mov", 400 * mb), ("Films/b.mov", 200 * mb), ("Music/c.mp3", 150 * mb), ("other", 100 * mb)])
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { true }))
        chart.place(center: CGPoint(x: 400, y: 300), radius: 250, size: CGSize(width: 800, height: 600))
        // The first picture unfurls, and the names come once it has.
        #expect(await eventually { chart.labelsVisible && !chart.labels.isEmpty })
        let before = chart.labels
        #expect(chart.labelsPlacedFor == RingPlacement(center: CGPoint(x: 400, y: 300), radius: 250))
        chart.place(center: CGPoint(x: 350, y: 280), radius: 200, size: CGSize(width: 700, height: 560))
        #expect(chart.labelsVisible, "the names don't go while the ring moves")
        #expect(chart.labels == before && chart.labelsPlacedFor.radius == 250, "they're drawn following it, as placed for where it was")
        #expect(await eventually { chart.labelsPlacedFor == RingPlacement(center: CGPoint(x: 350, y: 280), radius: 200) },
                "and placed again once it rests")
        #expect(chart.labelsVisible)
    }

    @Test("A ring that moves while a new picture flies in still gets its names, placed for where it ends up")
    func movesWhileFlying() async throws {
        let tree = TestTree([("Films/a.mov", 400 * mb), ("Films/b.mov", 200 * mb), ("Music/c.mp3", 150 * mb), ("other", 100 * mb)])
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { true }))
        // The first picture is flying in: its names wait for it. Meanwhile the window gets its size, then another.
        #expect(!chart.labelsVisible)
        chart.place(center: CGPoint(x: 400, y: 300), radius: 250, size: CGSize(width: 800, height: 600))
        chart.place(center: CGPoint(x: 350, y: 280), radius: 200, size: CGSize(width: 700, height: 560))
        #expect(await eventually { chart.labelsVisible && !chart.labels.isEmpty }, "the names come all the same")
        #expect(await eventually { chart.labelsPlacedFor == RingPlacement(center: CGPoint(x: 350, y: 280), radius: 200) })
    }
}

/// Whether `done` comes true within `seconds`, asked every 20 ms. A wait for something the chart does a moment later: a fixed
/// sleep is too short on a slow machine, or one whose main actor is busy with other tests, as CI's can be. It counts its
/// tries rather than the clock: tests that draw hold the main actor for seconds on CI, and what the chart does next only
/// gets its turn between tries.
@MainActor
func eventually(within seconds: Double = 5, _ done: () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 50) {
        if done() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return done()
}
