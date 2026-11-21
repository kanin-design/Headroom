import Foundation
import XCTest
@testable import SunburstKit

/// How long a picture of a million-node disk takes to make. Run in a release build, on the kit as it was and as it is:
/// BENCH=1 swift test -c release --filter LayoutBench
@MainActor
final class LayoutBench: XCTestCase {
    static let big: FixtureData = {
        var d = FixtureData()
        d.band = true
        let you = d.add("Your files", in: 0, folder: true)
        // Nested like a real disk: 8 folders of 8 folders of homes, so thousands of pieces are drawn.
        var seed: UInt64 = 1
        outer: for a in 0..<8 {
            let top = d.add("top\(a)", in: you, folder: true)
            for b in 0..<8 {
                let mid = d.add("mid\(b)", in: top, folder: true)
                for _ in 0..<5 {
                    let home = d.add("home\(seed)", in: mid, folder: true)
                    Fixtures.home(into: &d, at: home, seed: seed, scale: Double(1 + seed % 5))
                    seed += 1
                    if d.nodes.count > 880_000 { break outer }
                }
            }
        }
        // Folders with tens of thousands of files, as photo libraries and caches have.
        let photos = d.add("Photos Library", in: you, folder: true)
        for i in 0..<80_000 { d.add("IMG_\(i)", in: photos, own: UInt64(200 + (i * 7_919) % 3_000), folder: false) }
        let modules = d.add("node_modules", in: you, folder: true)
        for i in 0..<12_000 {
            let m = d.add("m\(i)", in: modules, folder: true)
            for j in 0..<3 { d.add("j\(j)", in: m, own: UInt64(1 + (i + j) % 40), folder: false) }
        }
        let used = d.nodes.reduce(UInt64(0)) { $0 &+ $1.own }
        d.hidden = d.add("Hidden", in: 0, own: used / 20, folder: false, kind: .hidden)
        d.free = d.add("Free", in: 0, own: used / 4, folder: false, kind: .free)
        d.ranks = [d.free: 5, d.hidden: 4]
        d.finish()
        return d
    }()

    private func time(_ label: String, runs: Int = 9, _ body: () -> Void) -> [Double] {
        body()
        var times: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        print(String(format: "BENCH %@: median %.2f ms, min %.2f, max %.2f", label, times[runs / 2], times[0], times[runs - 1]))
        return times
    }

    func testLayoutSpeed() throws {
        guard ProcessInfo.processInfo.environment["BENCH"] != nil else { throw XCTSkip("set BENCH=1 to time") }
        let tree = FixtureTree(Self.big)
        print("BENCH nodes \(Self.big.nodes.count)")
        let six = tree.parts(RingSizes()), twelve = tree.parts(RingSizes(depth: 12, style: .adaptive))
        var pieces = 0
        _ = time("whole disk, 6 tapered") {
            pieces = RingLayout.build(tree: tree, focus: 0, parts: six, colorer: FixtureTree.colour, marked: { $0 % 17 == 3 }).pieces.count
        }
        print("BENCH pieces \(pieces)")
        _ = time("whole disk, 12 adaptive") {
            pieces = RingLayout.build(tree: tree, focus: 0, parts: twelve, colorer: FixtureTree.colour).pieces.count
        }
        let yours = Self.big.node(named: "Your files")
        _ = time("your files, 6 tapered") {
            pieces = RingLayout.build(tree: tree, focus: yours, parts: six, colorer: FixtureTree.colour).pieces.count
        }
        let one = Self.big.node(named: "Your files/top0/mid0/home1")
        _ = time("one home, 6 tapered", runs: 31) {
            pieces = RingLayout.build(tree: tree, focus: one, parts: six, colorer: FixtureTree.colour).pieces.count
        }
        let lib = Self.big.node(named: "Your files/Photos Library")
        _ = time("photos library, 6 tapered") {
            pieces = RingLayout.build(tree: tree, focus: lib, parts: six, colorer: FixtureTree.colour).pieces.count
        }
        _ = time("chain tails, every node") {
            var sum: UInt64 = 0
            for n in stride(from: UInt32(0), to: UInt32(Self.big.nodes.count), by: 97) { sum &+= UInt64(RingLayout.chainTail(tree: tree, n)) }
            if sum == 42 { print("") }
        }
        // What a chart does on top of making the picture: names, and lighting what goes with what's pointed at.
        let chart = SunburstChart(tree: tree, name: { Self.big.nodes[Int($0)].name }, parts: six, engine: SunburstEngine(reducesMotion: { true }))
        chart.place(center: CGPoint(x: 600, y: 450), radius: 400, size: CGSize(width: 1400, height: 900))
        print("BENCH pieces on the chart \(chart.engine.layout.pieces.count)")
        _ = time("names around the ring", runs: 31) { chart.relabel() }
        let many = stride(from: UInt32(1), to: UInt32(Self.big.nodes.count), by: 4_001).map { $0 }
        _ = time("light \(many.count) nodes", runs: 31) { _ = chart.engine.layout.light(many, in: tree, gathered: .shown) }
        _ = time("a new picture, as a scan's", runs: 31) { chart.redraw(.live) }
    }
}
