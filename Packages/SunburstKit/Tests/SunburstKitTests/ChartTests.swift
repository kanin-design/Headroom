import AppKit
import Metal
import XCTest
@testable @_spi(Diagnostics) import SunburstKit

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

    func testTheAppsOwnKeysComeFirst() throws {
        let (chart, tree) = chart()
        func press(_ code: UInt16) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                       context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                                       isARepeat: false, keyCode: code))
            return chart.key(event)
        }
        var spaces = 0
        chart.onKey = { event in
            guard event.keyCode == 49 else { return false }
            spaces += 1
            return true
        }
        XCTAssertTrue(try press(49))
        XCTAssertEqual(spaces, 1)
        chart.zoom(into: tree.node("Films"))
        XCTAssertTrue(try press(53), "a key the app leaves alone is the chart's: Escape backs out")
        XCTAssertEqual(chart.focus, 0)
        chart.zoom(into: tree.node("Films"))
        chart.onKey = { _ in true }
        XCTAssertTrue(try press(53))
        XCTAssertEqual(chart.focus, tree.node("Films"), "the app took Escape")
    }

    func testWhatThePointerIsOnStaysLitThroughNewSizesAndMarks() throws {
        let (chart, tree) = chart()
        let p = chart.engine.layout.pieces[try XCTUnwrap(chart.engine.layout.piece(of: tree.node("Films")))]
        chart.pointerMoved(to: (angle: p.midAngle, radius: (p.r0 + p.r1) / 2))
        let lit = chart.engine.litPieces
        XCTAssertGreaterThan(lit, 0)
        chart.tree = tree
        XCTAssertEqual(chart.hovered, tree.node("Films"), "new sizes")
        XCTAssertEqual(chart.readout.title, "Films")
        XCTAssertEqual(chart.engine.litPieces, lit)
        chart.marked = [tree.node("Films/a.mov")]
        XCTAssertEqual(chart.hovered, tree.node("Films"), "new marks")
        XCTAssertEqual(chart.engine.litPieces, lit)
        chart.pointerMoved(to: nil)
        chart.tree = tree
        XCTAssertNil(chart.hovered)
        XCTAssertEqual(chart.engine.litPieces, 0)
    }

    func testADoubleClickActsOnce() throws {
        let (chart, tree) = chart()
        var opened: [UInt32] = []
        chart.onOpen = { opened.append($0) }
        let films = chart.engine.layout.pieces[try XCTUnwrap(chart.engine.layout.piece(of: tree.node("Films")))]
        let point: Polar = (angle: films.midAngle, radius: (films.r0 + films.r1) / 2)
        chart.click(at: point, count: 1)
        XCTAssertEqual(chart.focus, tree.node("Films"))
        chart.click(at: point, count: 2)
        XCTAssertEqual(opened, [], "the second click doesn't open what the zoom put under the pointer")
        XCTAssertEqual(chart.focus, tree.node("Films"))
        chart.click(at: (angle: 1, radius: 0.1), count: 1)
        chart.click(at: (angle: 1, radius: 0.1), count: 2)
        XCTAssertEqual(chart.focus, 0)
    }

    func testSpreadingFingersOnlyEverZoomsIn() throws {
        let (chart, tree) = chart()
        var opened: [UInt32] = []
        chart.onOpen = { opened.append($0) }
        chart.zoom(into: tree.node("Films"))
        chart.pinchOpen(at: (angle: 1, radius: 0.1))
        XCTAssertEqual(chart.focus, tree.node("Films"), "over the middle, nothing")
        let file = chart.engine.layout.pieces[try XCTUnwrap(chart.engine.layout.piece(of: tree.node("Films/a.mov")))]
        chart.pinchOpen(at: (angle: file.midAngle, radius: (file.r0 + file.r1) / 2))
        XCTAssertEqual(opened, [], "a file isn't opened")
    }

    func testBackToTheRootIsOneMove() {
        let tree = TestTree([("A/B/C/D/d1", 100 * mb), ("A/B/C/D/d2", 100 * mb), ("A/B/C/C2", 100 * mb), ("A/B/B2", 300 * mb),
                             ("A/A2", 400 * mb), ("other", 300 * mb)])
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { false }))
        for path in ["A", "A/B", "A/B/C", "A/B/C/D"] { chart.zoom(into: tree.node(path)) }
        var told: [UInt32] = []
        chart.onFocus = { told.append($0) }
        chart.zoomToRoot()
        XCTAssertEqual(chart.focus, 0)
        XCTAssertEqual(told, [0])
    }

    func testAFolderInTheMiddleOfAChainLightsTheChain() throws {
        let tree = TestTree([("A/B/C/x.bin", 500 * mb), ("A/B/C/y.bin", 400 * mb), ("other.bin", 300 * mb)])
        let a = tree.node("A"), b = tree.node("A/B"), c = tree.node("A/B/C")
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { false }))
        let layout = chart.engine.layout
        let piece = try XCTUnwrap(layout.piece(of: a))
        XCTAssertEqual(layout.piece(of: b), piece, "A › B › C is one piece")
        XCTAssertEqual(layout.piece(of: c), piece)
        chart.highlight([a])
        let whole = chart.engine.litPieces
        chart.highlight([b])
        XCTAssertEqual(chart.engine.litPieces, whole)
        let x = try XCTUnwrap(chart.summary().pieces.first { $0.node == tree.node("A/B/C/x.bin") })
        XCTAssertEqual(x.inside, c, "inside the folder at the chain's end")
    }

    func testSomethingTooSmallToDrawLightsTheSmallerItemsItsIn() throws {
        var files: [(String, UInt64)] = [("big/one", 1000 * mb), ("other", 900 * mb)]
        for i in 0..<30 { files.append(("big/tiny\(i)", 1 * mb)) }
        let tree = TestTree(files)
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { false }))
        XCTAssertNil(chart.engine.layout.piece(of: tree.node("big/tiny3")))
        chart.highlight([tree.node("big/tiny3")])
        XCTAssertEqual(chart.engine.litPieces, 2, "the smaller items in big, and big as the way out to them")
    }

    func testPointingAtOneStretchLightsTheWholeNode() throws {
        let (_, plain) = chart()
        var tree = plain
        let films = tree.node("Films")
        tree.cut[films] = [SunburstStretch(size: 1, key: 0), SunburstStretch(size: 1, key: 1), SunburstStretch(size: 1, key: 2)]
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { false }))
        let at = try XCTUnwrap(chart.engine.layout.piece(of: films))
        let second = chart.engine.layout.pieces[at + 1]
        chart.pointerMoved(to: (angle: second.midAngle, radius: (second.r0 + second.r1) / 2))
        XCTAssertEqual(chart.hovered, films)
        XCTAssertEqual(chart.engine.litPieces, 3 + 2, "all three stretches, and the two films inside")
    }

    func testASharedPieceHasABrightDashedEdge() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no GPU here")
        func total(_ style: PieceStyle) throws -> Double {
            var (_, tree) = chart()
            tree.nodes[Int(tree.node("Films"))].style = style
            let finished = tree
            let chart = SunburstChart(tree: finished, name: { finished.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { false }))
            let image = try XCTUnwrap(chart.picture(width: 400, height: 300, dithered: false))
            var sum = 0.0
            for y in stride(from: 0, to: 300, by: 3) { for x in stride(from: 0, to: 400, by: 3) { sum += try brightness(of: image, x: x, y: y) } }
            return sum
        }
        XCTAssertGreaterThan(try total(.shared), try total(.folder) * 1.002)
    }

    /// A tree sized by one thing can say another: here each node's text is how many files are in it.
    func testANodesOwnTextIsWrittenInPlaceOfItsSize() throws {
        var files: [(String, UInt64)] = [("Films/a.mov", 400 * mb), ("Films/b.mov", 200 * mb), ("other", 300 * mb)]
        for i in 0..<30 { files.append(("Films/tiny\(i)", 10_000)) }
        var tree = TestTree(files)
        let counting = tree
        func count(_ node: UInt32) -> Int { counting.firstChild(of: node) == 0 ? 1 : counting.children(of: node).map(count).reduce(0, +) }
        let chart = SunburstChart(tree: counting, name: { counting.nodes[Int($0)].name.isEmpty ? "All" : counting.nodes[Int($0)].name },
                                  valueText: { "\(count($0)) files" }, engine: SunburstEngine(reducesMotion: { false }))
        let summary = chart.summary(limit: 100)
        XCTAssertEqual(summary.sizeText, "33 files")
        XCTAssertEqual(summary.pieces.first { $0.name == "Films" }?.sizeText, "32 files")
        let gathered = try XCTUnwrap(summary.pieces.first(where: \.isGathered))
        XCTAssertEqual(gathered.sizeText, SunburstFormat.bytes(gathered.size), "smaller items are part of a node: their own size")

        chart.setPlace(center: CGPoint(x: 400, y: 300), radius: 250, size: CGSize(width: 800, height: 600))
        XCTAssertTrue(chart.labels.contains { $0.title == "Films" && $0.value == "32 files" }, "\(chart.labels.map(\.value))")
        let films = try XCTUnwrap(chart.engine.layout.piece(of: tree.node("Films")))
        chart.hover(piece: films)
        XCTAssertEqual(chart.readout.text, "32 files")
        chart.hover(piece: nil)
        XCTAssertEqual(chart.readout.text, "33 files", "the middle")

        // A stretch is part of its node too.
        tree.cut[tree.node("Films")] = [SunburstStretch(size: 2, key: 0), SunburstStretch(size: 1, key: 1)]
        chart.tree = tree
        let stretch = try XCTUnwrap(chart.engine.layout.piece(of: tree.node("Films")))
        chart.hover(piece: stretch)
        XCTAssertEqual(chart.readout.text, SunburstFormat.bytes(2))

        chart.valueText = nil
        XCTAssertEqual(chart.summary().sizeText, SunburstFormat.bytes(900 * mb + 300_000), "back to sizes")
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
