import ImageIO
import Metal
import XCTest
@_spi(Diagnostics) import SunburstKit
@testable @_spi(Diagnostics) import SunburstAgents

/// The chart's own tools: what an agent can read off a chart, and how it can move it.
@MainActor
final class ChartToolsTests: XCTestCase {
    private let mb: UInt64 = 1_000_000
    private let agent = AgentIdentity(name: "Test Agent", program: "/Applications/Test.app", signer: nil)

    private func chart() -> (SunburstChart<PathTree>, PathTree) {
        let tree = PathTree([("Films/a.mov", 400 * mb), ("Films/b.mov", 200 * mb), ("Music/Album/1.flac", 150 * mb),
                             ("Music/Album/2.flac", 120 * mb), ("notes.txt", 30 * mb)])
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name.isEmpty ? "All" : tree.nodes[Int($0)].name },
                                  engine: SunburstEngine(reducesMotion: { false }))
        return (chart, tree)
    }

    private func answer(_ chart: SunburstChart<PathTree>, _ tool: String, _ arguments: [String: Any] = [:]) throws -> AgentReply {
        try SunburstAgentTools.answer(AgentCall(tool: tool, arguments: arguments, agent: agent), chart: chart)
    }

    /// An answer read back as the agent reads it.
    private func json(_ reply: AgentReply) throws -> [String: Any] {
        let text = try XCTUnwrap(reply.content()?.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testTheToolsThatMoveTheChartNeedMoreThanLooking() {
        XCTAssertEqual(SunburstAgentTools.tools.map(\.name),
                       ["chart_summary", "chart_find", "chart_children", "chart_picture", "chart_zoom_in", "chart_zoom_out", "chart_highlight",
                        "chart_clear_highlight"])
        XCTAssertEqual(SunburstAgentTools.tools.filter(\.selects).map(\.name),
                       ["chart_zoom_in", "chart_zoom_out", "chart_highlight", "chart_clear_highlight"], "reading the chart and its tree are for agents that only look")
        for tool in SunburstAgentTools.tools {
            XCTAssertNotNil(AgentJSON.line(tool.schema), "\(tool.name)'s schema is JSON")
            XCTAssertFalse(tool.description.isEmpty)
        }
    }

    func testTheSummarySaysWhatIsOnTheRingInFewWords() throws {
        let (chart, tree) = chart()
        let reply = try answer(chart, "chart_summary", ["limit": 3])
        guard case .text(let text)? = reply.parts.first else { return XCTFail("the summary is text") }
        XCTAssertFalse(text.contains("\n"), "one line")
        let summary = try json(reply)
        XCTAssertEqual(summary["focus"] as? Int, 0)
        XCTAssertEqual(summary["size_text"] as? String, "900 MB", "names as agents write them")
        let pieces = try XCTUnwrap(summary["pieces"] as? [[String: Any]])
        XCTAssertEqual(pieces.compactMap { $0["name"] as? String }, ["Films", "a.mov", "Music"], "biggest first, as many as asked")
        XCTAssertEqual(pieces[0]["node"] as? Int, Int(tree.node("Films")))
        XCTAssertEqual(pieces[0]["share"] as? Double, 0.6667, "no more digits than help")
        XCTAssertEqual(pieces[0]["from"] as? Double, 0)
        XCTAssertEqual(pieces[0]["to"] as? Double ?? 0, 240, accuracy: 0.5, "its angle is its share of the circle")
        XCTAssertNotNil(pieces[0]["is_gathered"])
        XCTAssertGreaterThan(summary["more"] as? Int ?? 0, 0)
    }

    func testZoomingInAndOutMovesTheMiddle() throws {
        let (chart, tree) = chart()
        let into = try json(answer(chart, "chart_zoom_in", ["node": Int(tree.node("Films"))]))
        XCTAssertEqual(chart.focus, tree.node("Films"))
        XCTAssertEqual(into["name"] as? String, "Films")
        XCTAssertEqual(into["size"] as? Int, 600 * 1_000_000)
        XCTAssertEqual(try json(answer(chart, "chart_zoom_in", ["node": "\(tree.node("Films"))"]))["note"] as? String, "Already in the middle.",
                       "a number written as text is a number")

        let out = try json(answer(chart, "chart_zoom_out"))
        XCTAssertEqual(chart.focus, 0)
        XCTAssertEqual(out["name"] as? String, "All")
        XCTAssertEqual(try json(answer(chart, "chart_zoom_out"))["note"] as? String, "Already showing the whole tree.")

        _ = try answer(chart, "chart_zoom_in", ["node": Int(tree.node("Music"))])
        XCTAssertEqual(chart.focus, tree.node("Music/Album"), "Music is nearly all one album, so the zoom goes to the album")
        _ = try answer(chart, "chart_zoom_out", ["to_root": true])
        XCTAssertEqual(chart.focus, 0)
    }

    /// A file has nothing to zoom into. Zooming into one would open it, which is the app's to do, not an agent's.
    func testZoomingIntoAFileOpensNothing() throws {
        let (chart, tree) = chart()
        var opened: UInt32?
        chart.onOpen = { opened = $0 }
        XCTAssertThrowsError(try answer(chart, "chart_zoom_in", ["node": Int(tree.node("notes.txt"))])) { error in
            XCTAssertEqual((error as? AgentFailure)?.message, "notes.txt has nothing inside it to zoom into.")
        }
        XCTAssertNil(opened)
        XCTAssertEqual(chart.focus, 0)
    }

    /// A node the tree doesn't have is refused before the tree is asked anything about it.
    func testANodeTheTreeDoesntHaveIsRefused() throws {
        let (chart, _) = chart()
        for node in [99_999, Int(UInt32.max)] {
            for (tool, arguments) in [("chart_zoom_in", ["node": node]), ("chart_children", ["node": node]),
                                      ("chart_highlight", ["nodes": [node]])] as [(String, [String: Any])] {
                XCTAssertThrowsError(try answer(chart, tool, arguments)) { error in
                    XCTAssertEqual((error as? AgentFailure)?.message,
                                   "The tree has no node \(node). chart_summary, chart_find and chart_children give node numbers.", tool)
                }
            }
        }
        for bad: Any in [-1, 1.5, "Films", Int(UInt32.max) + 1] {
            XCTAssertThrowsError(try answer(chart, "chart_zoom_in", ["node": bad]), "\(bad)")
            XCTAssertThrowsError(try answer(chart, "chart_children", ["node": bad]), "\(bad)")
        }
        XCTAssertThrowsError(try answer(chart, "chart_highlight", ["nodes": []]))
        XCTAssertThrowsError(try answer(chart, "chart_find", ["name": "  "]))
        XCTAssertThrowsError(try answer(chart, "chart_find"))
        XCTAssertThrowsError(try answer(chart, "delete_everything")) { error in
            XCTAssertEqual((error as? AgentFailure)?.message, "No such tool: delete_everything")
        }
    }

    /// An agent can find something anywhere, look inside it and zoom to it, without knowing where it is on the ring.
    func testFindingByNameAnywhereInTheTree() throws {
        let (chart, tree) = chart()
        _ = try answer(chart, "chart_zoom_in", ["node": Int(tree.node("Films"))])
        let found = try json(answer(chart, "chart_find", ["name": "FLAC"]))
        let matches = try XCTUnwrap(found["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.compactMap { $0["name"] as? String }, ["1.flac", "2.flac"], "case ignored, biggest first")
        XCTAssertEqual(matches[0]["node"] as? Int, Int(tree.node("Music/Album/1.flac")))
        XCTAssertEqual(matches[0]["path"] as? [String], ["All", "Music", "Album", "1.flac"])
        XCTAssertEqual(matches[0]["size_text"] as? String, "150 MB")
        XCTAssertEqual(matches[0]["has_inside"] as? Bool, false)
        XCTAssertEqual(matches[0]["on_the_ring"] as? Bool, false, "Films is in the middle, so the music isn't on the ring")
        XCTAssertEqual(found["more"] as? Int, 0)
        XCTAssertEqual(chart.focus, tree.node("Films"), "finding moves nothing")

        let one = try json(answer(chart, "chart_find", ["name": "m", "limit": 1]))
        XCTAssertEqual((one["matches"] as? [[String: Any]])?.first?["name"] as? String, "Films", "the biggest name with an m in it")
        XCTAssertGreaterThan(one["more"] as? Int ?? 0, 0)

        let none = try json(answer(chart, "chart_find", ["name": "zebra"]))
        XCTAssertEqual((none["matches"] as? [Any])?.count, 0)
        XCTAssertEqual(none["note"] as? String, "No name has \"zebra\" in it.")

        // Off the ring, and still a node to zoom into.
        _ = try answer(chart, "chart_zoom_in", ["node": Int(tree.node("Music"))])
        XCTAssertEqual(chart.focus, tree.node("Music/Album"))
    }

    func testAccentsAreIgnoredInAName() throws {
        let tree = PathTree([("Café/menu.pdf", 5 * mb), ("other.bin", 3 * mb)])
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { false }))
        let found = try json(answer(chart, "chart_find", ["name": "cafe"]))
        XCTAssertEqual((found["matches"] as? [[String: Any]])?.first?["name"] as? String, "Café")
    }

    func testPartOfANameIgnoresCaseAndAccents() {
        XCTAssertTrue(NamePart("FLAC").isIn("1.flac"))
        XCTAssertTrue(NamePart("cafe").isIn("Le Café"))
        XCTAssertTrue(NamePart("CAFÉ").isIn("cafe menu"))
        XCTAssertTrue(NamePart("ab").isIn("xxAB"), "at the very end")
        XCTAssertFalse(NamePart("abc").isIn("ab"))
        XCTAssertFalse(NamePart("flac").isIn("fla c"))
        XCTAssertFalse(NamePart("[").isIn("{"), "only letters change case")
    }

    func testListingWhatIsInsideANode() throws {
        let (chart, tree) = chart()
        let top = try json(answer(chart, "chart_children"))
        XCTAssertEqual(top["name"] as? String, "All", "the node in the middle unless given")
        let children = try XCTUnwrap(top["children"] as? [[String: Any]])
        XCTAssertEqual(children.compactMap { $0["name"] as? String }, ["Films", "Music", "notes.txt"])
        XCTAssertEqual(children[0]["share"] as? Double, 0.6667)
        XCTAssertEqual(children[0]["has_inside"] as? Bool, true)
        XCTAssertEqual(children[2]["has_inside"] as? Bool, false)
        XCTAssertEqual(top["more"] as? Int, 0)

        let films = try json(answer(chart, "chart_children", ["node": Int(tree.node("Films")), "limit": 1]))
        XCTAssertEqual((films["children"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["a.mov"])
        XCTAssertEqual(films["more"] as? Int, 1)

        _ = try answer(chart, "chart_zoom_in", ["node": Int(tree.node("Films"))])
        let music = try json(answer(chart, "chart_children", ["node": Int(tree.node("Music"))]))
        XCTAssertEqual((music["children"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Album"], "outside the middle too")
        XCTAssertEqual(chart.focus, tree.node("Films"), "and the chart didn't move")
    }

    /// What the chart writes for a node, the agent reads too.
    func testAgentsReadTheChartsOwnTextForANode() throws {
        let (chart, tree) = chart()
        chart.valueText = { node in "\(tree.nodes[Int(node)].children.count) inside" }
        XCTAssertEqual(try json(answer(chart, "chart_summary"))["size_text"] as? String, "3 inside")
        let films = try json(answer(chart, "chart_children", ["node": Int(tree.node("Films"))]))
        XCTAssertEqual(films["size_text"] as? String, "2 inside")
        XCTAssertEqual((films["children"] as? [[String: Any]])?.first?["size_text"] as? String, "0 inside")
    }

    func testLightingNodesAndClearingThem() throws {
        let (chart, tree) = chart()
        XCTAssertEqual(chart.engine.litPieces, 0)
        let lit = try json(answer(chart, "chart_highlight", ["nodes": [Int(tree.node("Films/b.mov")), 99_999]]))
        XCTAssertEqual(lit["lit"] as? Int, 1)
        XCTAssertEqual(lit["unknown"] as? [Int], [99_999], "what the tree doesn't have is said, and the rest is lit")
        XCTAssertGreaterThan(chart.engine.litPieces, 0)
        _ = try answer(chart, "chart_clear_highlight")
        XCTAssertEqual(chart.engine.litPieces, 0)
    }

    /// Something too small for a piece lights what holds it; something outside the middle can't be lit until it's in view.
    func testLightingNodesThatArentOnTheRing() throws {
        var files: [(String, UInt64)] = [("big/one", 1000 * mb), ("other/two", 900 * mb)]
        for i in 0..<30 { files.append(("big/tiny\(i)", 1 * mb)) }
        let tree = PathTree(files)
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { false }))
        XCTAssertNil(chart.engine.layout.piece(of: tree.node("big/tiny3")))
        XCTAssertEqual(try json(answer(chart, "chart_highlight", ["nodes": [Int(tree.node("big/tiny3"))]]))["lit"] as? Int, 1)
        XCTAssertGreaterThan(chart.engine.litPieces, 0)

        _ = try answer(chart, "chart_zoom_in", ["node": Int(tree.node("big"))])
        let some = try json(answer(chart, "chart_highlight", ["nodes": [Int(tree.node("big/one")), Int(tree.node("other/two"))]]))
        XCTAssertEqual(some["lit"] as? Int, 1)
        XCTAssertEqual(some["not_in_view"] as? [Int], [Int(tree.node("other/two"))])
        XCTAssertThrowsError(try answer(chart, "chart_highlight", ["nodes": [Int(tree.node("other/two"))]])) { error in
            XCTAssertEqual((error as? AgentFailure)?.message, "Not in view now: \(tree.node("other/two")). They're outside big; zoom out to light them.")
        }
    }

    func testThePictureIsAPNGImage() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no GPU here")
        let (chart, _) = chart()
        let reply = try answer(chart, "chart_picture", ["width": 300, "height": 200])
        guard case .image(let data, let type)? = reply.parts.first else { return XCTFail("an image") }
        XCTAssertEqual(type, "image/png")
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "a PNG file")
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 200)
        let content = try XCTUnwrap(reply.content())
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual(content.first?["mimeType"] as? String, "image/png")

        let huge = try answer(chart, "chart_picture", ["width": 100_000, "height": 10])
        guard case .image(let big, _)? = huge.parts.first, let sized = CGImageSourceCreateWithData(big as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
        else { return XCTFail("an image") }
        XCTAssertEqual(sized.width, SunburstAgentTools.largestPicture, "kept to a size an agent can take")
        XCTAssertEqual(sized.height, 64)
    }

    func testAnAgentsPictureLeavesOutTheDitherForAPNGHalfTheSize() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no GPU here")
        let (chart, _) = chart()
        func png(_ dithered: Bool) throws -> Data {
            let image = try XCTUnwrap(chart.picture(width: 800, height: 800, dithered: dithered))
            guard case .image(let data, _)? = AgentReply.image(image)?.parts.first else { throw AgentFailure("no PNG") }
            return data
        }
        let plain = try png(false), dithered = try png(true)
        XCTAssertLessThan(Double(plain.count), Double(dithered.count) * 0.8, "\(plain.count) bytes against \(dithered.count)")
        guard case .image(let sent, _)? = try answer(chart, "chart_picture", ["width": 800, "height": 800]).parts.first else {
            return XCTFail("an image")
        }
        XCTAssertEqual(sent.count, plain.count, "the tool sends the plain one")
    }

    func testAFolderInTheMiddleOfAChainIsOnTheRing() throws {
        let tree = PathTree([("A/B/C/x.bin", 500 * mb), ("A/B/C/y.bin", 400 * mb), ("other.bin", 300 * mb)])
        let chart = SunburstChart(tree: tree, name: { tree.nodes[Int($0)].name }, engine: SunburstEngine(reducesMotion: { false }))
        let b = Int(tree.node("A/B"))
        XCTAssertEqual(try json(answer(chart, "chart_highlight", ["nodes": [b]]))["lit"] as? Int, 1)
        _ = try answer(chart, "chart_zoom_in", ["node": b])
        XCTAssertEqual(chart.focus, tree.node("A/B/C"), "into the chain's end, where the picture changes")
    }

    /// Through a door, as an app gives them: an agent allowed only to look can read the chart but not move it.
    func testAnAgentAllowedToLookCanReadTheChartButNotMoveIt() async throws {
        let (chart, tree) = chart()
        let folder = TestPlace.folder()
        defer { TestPlace.remove(folder) }
        let host = AgentHost(name: "FolderMap", version: "1", instructions: "", folder: folder, tools: SunburstAgentTools.tools)
        let door = AgentDoor(host) { call in try SunburstAgentTools.answer(call, chart: chart) }
        let session = door.session(program: "/Applications/Test.app", signer: nil)
        _ = await session.handle(Lines.message(0, "initialize", ["clientInfo": ["name": "Test Agent"]]))
        door.agents.answer(try XCTUnwrap(door.agents.requests.first), .lookOnly)

        let summary = Lines.object(await session.handle(Lines.message(1, "tools/call", ["name": "chart_summary"])))
        XCTAssertEqual(Lines.isError(summary), false)
        XCTAssertTrue(Lines.text(of: summary)?.contains("\"Films\"") ?? false)
        let found = Lines.object(await session.handle(Lines.message(3, "tools/call", ["name": "chart_find", "arguments": ["name": "flac"]])))
        XCTAssertEqual(Lines.isError(found), false)
        let inside = Lines.object(await session.handle(Lines.message(4, "tools/call", ["name": "chart_children"])))
        XCTAssertEqual(Lines.isError(inside), false)
        let zoom = Lines.object(await session.handle(Lines.message(2, "tools/call", ["name": "chart_zoom_in", "arguments": ["node": Int(tree.node("Films"))]])))
        XCTAssertEqual(Lines.isError(zoom), true)
        XCTAssertEqual(chart.focus, 0, "and the chart didn't move")
        XCTAssertEqual(door.agents.activity.last?.what, "chart_children")
    }
}
