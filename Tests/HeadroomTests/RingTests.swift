import XCTest
@testable import Headroom

/// How many rings the map draws and how thick each is, and that any number of them fills the same circle.
final class RingTests: XCTestCase {
    private let gb: UInt64 = 1_000_000_000

    func testSixTaperedRingsAreWhatTheMapStartsWith() {
        XCTAssertEqual(RingSizes(), RingSizes(depth: 6, style: .tapered))
    }

    func testStandardSixRingsKeepTheirWidths() {
        XCTAssertEqual(RingStyle.standard.shares(count: 6, fill: []), [0.150, 0.128, 0.108, 0.090, 0.074, 0.060])
    }

    func testTaperedRingsAreAFifthThinnerUntilTheTipWouldGetTooThin() {
        for count in [5, 6, 8, 10, 12] {
            let shares = RingStyle.tapered.shares(count: count, fill: [])
            XCTAssertEqual(shares.count, count)
            let steps = zip(shares, shares.dropFirst()).map { $1 / $0 }
            for step in steps { XCTAssertEqual(step, steps[0], accuracy: 0.0001, "the same step all the way out") }
            if count <= 6 { XCTAssertEqual(steps[0], RingStyle.taper, accuracy: 0.0001, "a fifth thinner each time") }
            XCTAssertGreaterThanOrEqual(shares[count - 1] / shares[0], RingStyle.thinnestTip - 0.0001, "the tip never gets thinner than that")
        }
    }

    func testFiveRingsLookTheSameStandardOrTapered() {
        func normalised(_ shares: [Float]) -> [Float] {
            let total = shares.reduce(0, +)
            return shares.map { $0 / total }
        }
        let standard = normalised(RingStyle.standard.shares(count: 5, fill: []))
        let tapered = normalised(RingStyle.tapered.shares(count: 5, fill: []))
        for (a, b) in zip(standard, tapered) { XCTAssertEqual(a, b, accuracy: 0.005) }
    }

    func testMoreRingsReachDeeperInTheSameCircle() throws {
        let d = deepDisk()
        var firstRing: [RingStyle: [Int: Float]] = [:]
        for style in RingStyle.allCases {
            for depth in [5, 6, 8, 10] {
                let layout = RingLayout.build(tree: d.tree, focus: d.node("/Volumes/Fake/d1"), colorer: { _ in .zero },
                                              sizes: RingSizes(depth: depth, style: style))
                let pieces = layout.pieces
                XCTAssertEqual(pieces.map(\.ring).max(), Int32(depth - 1), "a ring for every level, as deep as asked")
                XCTAssertEqual(try XCTUnwrap(pieces.map(\.r1).max()), 1, accuracy: 0.0001, "the same circle at any depth")
                let first = try XCTUnwrap(pieces.first { $0.ring == 0 })
                firstRing[style, default: [:]][depth] = first.r1 - first.r0
            }
        }
        let standard = try XCTUnwrap(firstRing[.standard]), tapered = try XCTUnwrap(firstRing[.tapered])
        XCTAssertLessThan(try XCTUnwrap(standard[8]), try XCTUnwrap(standard[6]), "more rings are thinner rings")
        XCTAssertLessThan(try XCTUnwrap(standard[10]) / XCTUnwrap(standard[5]), 0.55)
        XCTAssertGreaterThan(try XCTUnwrap(tapered[10]) / XCTUnwrap(tapered[5]), try XCTUnwrap(standard[10]) / XCTUnwrap(standard[5]),
                             "tapered, the first ring keeps more of its room")
    }

    func testAPictureGetsNoMoreRingsThanItCanFill() throws {
        let d = deepDisk()
        // Each ring goes seven eighths as far around as the one inside it. Below the sixth folder there are seven rings.
        for (focus, fills) in [(d.node("/Volumes/Fake/d1"), 12), (d.node(deep(6)), 7), (UInt32(0), 12)] {
            for style in RingStyle.allCases {
                let layout = RingLayout.build(tree: d.tree, focus: focus, colorer: { _ in .zero }, sizes: RingSizes(depth: 12, style: style))
                XCTAssertEqual(layout.reach, fills)
                XCTAssertEqual(layout.rings, fills, "no more rings than it can fill")
                // Around the whole disk, ring 0 is the band.
                let pieces = layout.pieces.filter { focus != 0 || $0.ring > 0 }
                let outermost = Int32(focus == 0 ? fills : fills - 1)
                XCTAssertEqual(pieces.map(\.ring).max(), outermost)
                XCTAssertEqual(try XCTUnwrap(pieces.filter { $0.ring == outermost }.map(\.r1).max()), 1, accuracy: 0.0001, "and they reach the edge")
                let fewer = RingLayout.build(tree: d.tree, focus: focus, colorer: { _ in .zero }, sizes: RingSizes(depth: 5, style: style))
                XCTAssertEqual(fewer.rings, 5, "fewer than it can fill are drawn as asked")
                XCTAssertEqual(fewer.reach, fills)
            }
        }
    }

    func testAdaptiveRingsAreAsThickAsTheyAreFull() throws {
        let d = deepDisk()
        let layout = RingLayout.build(tree: d.tree, focus: d.node(deep(6)), colorer: { _ in .zero }, sizes: RingSizes(depth: 12, style: .adaptive))
        XCTAssertEqual(layout.rings, 7)
        let widths = try (0..<7).map { ring -> Float in
            let piece = try XCTUnwrap(layout.pieces.first { $0.ring == Int32(ring) })
            return piece.r1 - piece.r0
        }
        for (inner, outer) in zip(widths, widths.dropFirst()) { XCTAssertEqual(outer / inner, 0.875, accuracy: 0.001) }
    }

    func testARingWithOnlyASliverIsLeftOutOrThin() throws {
        for (share, fills) in [(1, 1), (5, 2)] {
            let d = FakeDisk()
            _ = d.file("/Volumes/Fake/x/big", UInt64(100 - share) * gb)
            _ = d.file("/Volumes/Fake/x/small/f", UInt64(share) * gb)
            d.finish()
            let x = d.node("/Volumes/Fake/x")
            let standard = RingLayout.build(tree: d.tree, focus: x, colorer: { _ in .zero }, sizes: RingSizes(depth: 6, style: .standard))
            XCTAssertEqual(standard.reach, fills, "a folder \(share)% of the way around")
            XCTAssertEqual(standard.rings, fills)
            // Adaptive rings keep a ring with anything in it, as thin as a ring gets.
            let adaptive = RingLayout.build(tree: d.tree, focus: x, colorer: { _ in .zero }, sizes: RingSizes(depth: 6, style: .adaptive))
            XCTAssertEqual(adaptive.rings, 2)
            let outer = try XCTUnwrap(adaptive.pieces.first { $0.ring == 1 })
            XCTAssertEqual(outer.r1, 1, accuracy: 0.0001)
            if share == 1 { XCTAssertEqual(outer.r1 - outer.r0, RingLayout.thinnest, accuracy: 0.0001) }
        }
    }

    func testAFolderInTheOutermostRingShowsItGoesOn() throws {
        let d = deepDisk()
        let focus = d.node("/Volumes/Fake/d1")
        let adaptive = RingLayout.build(tree: d.tree, focus: focus, colorer: { _ in .zero }, sizes: RingSizes(depth: 3, style: .adaptive))
        let last = adaptive.pieces.filter { $0.ring == 2 }
        // The fourth folder is seven eighths in the fifth. The file beside it is no folder, and the rings inside have more drawn.
        XCTAssertEqual(try XCTUnwrap(last.first { $0.node == d.node(deep(4)) }).deeper, 0.875, accuracy: 0.001)
        XCTAssertTrue(last.filter { $0.node != d.node(deep(4)) }.allSatisfy { $0.deeper == 0 })
        XCTAssertTrue(adaptive.pieces.filter { $0.ring < 2 }.allSatisfy { $0.deeper == 0 })
        let standard = RingLayout.build(tree: d.tree, focus: focus, colorer: { _ in .zero }, sizes: RingSizes(depth: 3, style: .standard))
        XCTAssertTrue(standard.pieces.allSatisfy { $0.deeper == 0 }, "standard rings stay as they were")
    }

    func testTheBandAroundTheWholeDiskKeepsItsWidth() throws {
        let d = deepDisk()
        for sizes in [RingSizes(depth: 4, style: .standard), RingSizes(depth: 10, style: .standard), RingSizes(depth: 10, style: .tapered),
                      RingSizes(depth: 10, style: .adaptive)] {
            let layout = RingLayout.build(tree: d.tree, focus: 0, colorer: { _ in .zero }, sizes: sizes)
            let band = try XCTUnwrap(layout.pieces.first { $0.ring == 0 && $0.node == d.node("/Volumes/Fake") })
            XCTAssertEqual(band.r1 - band.r0, RingLayout.band, accuracy: 0.0001)
        }
    }

    func testNoRingIsThinnerThanTheThinnest() {
        let widths = RingLayout.widths([1, 0.5, 0.01, 0.001], filling: 0.6)
        XCTAssertEqual(widths.reduce(0, +), 0.6, accuracy: 0.0001)
        XCTAssertEqual(widths[2], RingLayout.thinnest, accuracy: 0.0001)
        XCTAssertEqual(widths[3], RingLayout.thinnest, accuracy: 0.0001)
        XCTAssertEqual(widths[1] / widths[0], 0.5, accuracy: 0.0001, "the rest keep their proportions")
    }

    /// The path of the folder this many levels down.
    private func deep(_ level: Int) -> String {
        "/Volumes/Fake/" + (1...level).map { "d\($0)" }.joined(separator: "/")
    }

    /// Twelve folders, each inside the one before and seven eighths of it, so none is drawn as one with the next.
    private func deepDisk() -> FakeDisk {
        let d = FakeDisk()
        var inside = 7 * gb
        _ = d.file(deep(12) + "/f", inside)
        for level in (1...11).reversed() {
            _ = d.file(deep(level) + "/f", inside / 7)
            inside += inside / 7
        }
        d.finish()
        return d
    }
}
