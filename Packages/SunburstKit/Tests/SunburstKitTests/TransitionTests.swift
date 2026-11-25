import XCTest
@testable @_spi(Diagnostics) import SunburstKit

/// A change to a different picture: the old one goes first, then the new one comes.
@MainActor
final class TransitionTests: XCTestCase {
    func testOldPiecesGoFirstAndNewOnesWaitForThem() {
        let turn = SunburstEngine.handover
        // The old picture is gone by the handover, and stays gone.
        XCTAssertEqual(SunburstEngine.progress(0, turn: -turn), 0)
        XCTAssertEqual(SunburstEngine.progress(turn / 2, turn: -turn), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SunburstEngine.progress(turn, turn: -turn), 1)
        XCTAssertEqual(SunburstEngine.progress(1, turn: -turn), 1)
        // The new one hasn't started until then, and moves in the rest.
        XCTAssertEqual(SunburstEngine.progress(turn / 2, turn: turn), 0)
        XCTAssertEqual(SunburstEngine.progress(turn, turn: turn), 0)
        XCTAssertEqual(SunburstEngine.progress((1 + turn) / 2, turn: turn), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SunburstEngine.progress(1, turn: turn), 1)
        // Every other piece moves with the transition itself, overshoot and all.
        XCTAssertEqual(SunburstEngine.progress(0.4, turn: 0), 0.4)
        XCTAssertEqual(SunburstEngine.progress(1.02, turn: 0), 1.02)
    }

    func testADifferentPictureTravelsAndItsNamesWaitLonger() {
        XCTAssertTrue(RingTransition.replace.travels)
        XCTAssertGreaterThan(RingTransition.replace.settlesIn, RingTransition.zoomIn(nil).settlesIn)
    }

    func testADifferentPictureIsTheNewOneOnceItsDone() {
        let mb: UInt64 = 1_000_000
        let before = TestTree([("Films/a.mov", 400 * mb), ("Music/1.flac", 150 * mb)])
        let after = TestTree([("Drive/b.mov", 300 * mb), ("Mac/2.flac", 100 * mb), ("Mac/3.flac", 50 * mb)])
        var shown = before
        let chart = SunburstChart(tree: before, name: { shown.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { false }))
        chart.engine.settle()
        shown = after
        chart.change(.replace) { chart.tree = after }
        chart.engine.settle()
        let names = Set(chart.summary().pieces.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["Drive", "Mac", "b.mov"]))
        XCTAssertTrue(names.isDisjoint(with: ["Films", "Music"]), "nothing of the old picture is left")
    }
}
