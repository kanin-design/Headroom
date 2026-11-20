import Metal
import XCTest
@testable import SunburstKit

/// What a person does with the pointer, done from code, as an app or an agent would.
@MainActor
final class ChartTests: XCTestCase {
    private let mb: UInt64 = 1_000_000

    private func chart() -> (SunburstChart<TestTree>, TestTree) {
        let tree = TestTree([("Films/a.mov", 400 * mb), ("Films/b.mov", 200 * mb), ("Music/Album/1.flac", 150 * mb),
                             ("Music/Album/2.flac", 120 * mb), ("notes.txt", 30 * mb)])
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name.isEmpty ? "All" : tree.nodes[Int($0)].name },
                                  engine: SunburstEngine(reducesMotion: { false }))
        return (chart, tree)
    }

    func testTheSummarySaysWhatIsOnTheRingBiggestFirst() {
        let (chart, tree) = chart()
        let summary = chart.summary(limit: 3)
        XCTAssertEqual(summary.focus, 0)
        XCTAssertEqual(summary.size, 900 * mb)
        XCTAssertEqual(summary.pieces.map(\.name), ["Films", "a.mov", "Music"])
        let films = summary.pieces[0]
        XCTAssertEqual(films.node, tree.node("Films"))
        XCTAssertEqual(films.share, 600.0 / 900, accuracy: 0.0001)
        XCTAssertEqual(films.ring, 0)
        XCTAssertEqual(films.to - films.from, 360 * 600.0 / 900, accuracy: 0.01, "its angle is its share of the circle")
        XCTAssertGreaterThan(summary.more, 0, "and it says how many it left out")
    }

    func testZoomingInAndOutMovesTheMiddle() {
        let (chart, tree) = chart()
        var told: [UInt32] = []
        chart.onFocus = { told.append($0) }
        chart.zoom(into: tree.node("Music"))
        // Music is nearly all one album, so the zoom goes to where the picture changes: the album.
        XCTAssertEqual(chart.focus, tree.node("Music/Album"))
        XCTAssertEqual(chart.summary().name, "Album")
        chart.zoomOut()
        XCTAssertEqual(chart.focus, 0, "out past Music, which would only show the album again")
        XCTAssertEqual(told, [tree.node("Music/Album"), 0])
    }

    func testAFileOpensInsteadOfZooming() {
        let (chart, tree) = chart()
        var opened: UInt32?
        chart.onOpen = { opened = $0 }
        chart.zoom(into: tree.node("notes.txt"))
        XCTAssertEqual(chart.focus, 0)
        XCTAssertEqual(opened, tree.node("notes.txt"))
    }

    func testAClickInTheMiddleGoesBackOut() {
        let (chart, tree) = chart()
        chart.zoom(into: tree.node("Films"))
        chart.click(at: (angle: 1, radius: 0.1), count: 1)
        XCTAssertEqual(chart.focus, 0)
    }

    func testMarkedNodesAreStriped() {
        let (chart, tree) = chart()
        chart.marked = [tree.node("Films/a.mov")]
        let marked = chart.summary().pieces.filter(\.isMarked).map(\.name)
        XCTAssertEqual(marked, ["a.mov"])
    }

    func testThePointerOnAPieceSaysWhatItIs() {
        let (chart, tree) = chart()
        guard let films = chart.engine.layout.piece(of: tree.node("Films")) else { return XCTFail("Films has a piece") }
        let p = chart.engine.layout.pieces[films]
        chart.pointerMoved(to: (angle: p.midAngle, radius: (p.r0 + p.r1) / 2))
        XCTAssertEqual(chart.hovered, tree.node("Films"))
        XCTAssertEqual(chart.readout.title, "Films")
        XCTAssertEqual(chart.readout.detail, "67% of All")
        XCTAssertEqual(chart.node(at: (angle: p.midAngle, radius: (p.r0 + p.r1) / 2)), tree.node("Films"))
        chart.pointerMoved(to: nil)
        XCTAssertNil(chart.hovered)
        XCTAssertEqual(chart.readout.title, "All")
    }

    func testThePictureHasTheRingInTheMiddle() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no GPU here")
        let (chart, _) = chart()
        let image = try XCTUnwrap(chart.picture(width: 400, height: 300))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)
        // Films, the biggest piece, starts at 12 o'clock and goes clockwise: just right of the top of the ring is lit, the
        // far corner is the dark background.
        let lit = try brightness(of: image, x: 230, y: 70), corner = try brightness(of: image, x: 3, y: 3)
        XCTAssertGreaterThan(lit, corner + 40, "a piece is drawn where Films is")
    }

    func testReadoutSplitsTheUnitOff() {
        XCTAssertEqual(ReadoutView.split("4.2 GB").0, "4.2")
        XCTAssertEqual(ReadoutView.split("4.2 GB").1, "GB")
        XCTAssertEqual(ReadoutView.split("1,024").1, "", "no unit, nothing split off")
        XCTAssertEqual(ReadoutView.split("12 3").1, "", "a number isn't a unit")
    }

    private func brightness(of image: CGImage, x: Int, y: Int) throws -> Double {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])
    }
}
