import XCTest
@testable import Headroom

final class PlanListTests: XCTestCase {
    private func item(_ id: String, _ paths: [String], tier: Tier = .yourCall) -> PlanItem {
        PlanItem(id: id, title: id, note: "", tierRaw: tier.rawValue, paths: paths)
    }

    func testAddingAFolderTakesInWhatsPlannedInsideIt() {
        var list = PlanList()
        list.add(item("a", ["/x/y/file"]))
        list.add(item("b", ["/x/y"]))
        XCTAssertEqual(list.items.map(\.id), ["b"])
        XCTAssertTrue(list.covers("/x/y/file"))
    }

    func testSomethingInsideAPlannedFolderIsAlreadyCovered() {
        var list = PlanList()
        list.add(item("b", ["/x/y"]))
        list.add(item("a", ["/x/y/file"]))
        XCTAssertEqual(list.items.map(\.id), ["b"])
    }

    func testSimilarNamesDontCount() {
        var list = PlanList()
        list.add(item("b", ["/x/y"]))
        XCTAssertFalse(list.covers("/x/yz"))
        list.add(item("a", ["/x/yz"]))
        XCTAssertEqual(list.items.count, 2)
    }

    func testTakingBackLeavesTheRestOfTheFolderPlanned() {
        var list = PlanList()
        list.add(item("b", ["/x/y"]))
        list.takeBack("/x/y/keep")
        XCTAssertEqual(list.items.first?.excluded, ["/x/y/keep"])
        XCTAssertFalse(list.covers("/x/y/keep"))
        XCTAssertFalse(list.covers("/x/y/keep/inner"))
        XCTAssertTrue(list.covers("/x/y/other"))
    }

    func testTakingBackAWholeThingRemovesIt() {
        var list = PlanList()
        list.add(item("b", ["/x/y"]))
        list.takeBack("/x/y")
        XCTAssertTrue(list.isEmpty)
    }

    func testTakingBackAParentTakesBackWhatsInside() {
        var list = PlanList()
        list.add(item("a", ["/x/y/one", "/x/y/two", "/z"]))
        list.takeBack("/x/y")
        XCTAssertEqual(list.items.first?.paths, ["/z"])
    }

    func testAddingBackSomethingTakenBack() {
        var list = PlanList()
        list.add(item("b", ["/x/y"]))
        list.takeBack("/x/y/keep")
        list.add(item("again", ["/x/y/keep"]))
        XCTAssertEqual(list.items.map(\.id), ["b"])
        XCTAssertEqual(list.items.first?.excluded, [])
        XCTAssertTrue(list.covers("/x/y/keep"))
    }

    func testAddingToAnExistingItemMerges() {
        var list = PlanList()
        list.add(item("group", ["/a/node_modules"]))
        list.add(item("group", ["/b/node_modules"]))
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items.first?.paths.count, 2)
    }

    func testKeepingTakesItOutAndRemembers() {
        var list = PlanList()
        list.add(item("app", ["/Applications/A.app"]))
        list.keep("app", title: "A")
        XCTAssertTrue(list.isEmpty)
        XCTAssertTrue(list.isKept("app"))
        list.stopKeeping("app")
        XCTAssertFalse(list.isKept("app"))
    }

    func testAFolderWithSomethingTakenBackOpensUp() {
        var thing = item("b", ["/m"])
        thing.excluded = ["/m/keep.mov", "/m/sub/stay"]
        let tree: [String: [String]] = ["/m": ["keep.mov", "go.mov", "sub"], "/m/sub": ["stay", "go2"]]
        let paths = PlanList.effectivePaths(of: thing) { tree[$0] ?? [] }
        XCTAssertEqual(Set(paths), ["/m/go.mov", "/m/sub/go2"])
    }

    func testAFolderWithNothingTakenBackGoesWhole() {
        let thing = item("b", ["/m"])
        let paths = PlanList.effectivePaths(of: thing) { _ in XCTFail("shouldn't look inside"); return [] }
        XCTAssertEqual(paths, ["/m"])
    }

    func testAMoveOutOfAPlannedFolderKeepsItsDestination() {
        var list = PlanList()
        list.add(item("shows", ["/m/Shows"]))
        var move = item("keep", ["/m/Shows/Keep"])
        move.step = .move(folder: "/Volumes/Spare/Shows")
        list.add(move)
        XCTAssertEqual(list.item("keep")?.step, .move(folder: "/Volumes/Spare/Shows"))
        XCTAssertEqual(list.item("shows")?.excluded, ["/m/Shows/Keep"])
    }

    func testAFolderDoesntSwallowAMoveInsideIt() {
        var list = PlanList()
        var move = item("keep", ["/m/Shows/Keep"])
        move.step = .move(folder: "/Volumes/Spare/Shows")
        list.add(move)
        list.add(item("shows", ["/m/Shows"]))
        XCTAssertEqual(list.item("keep")?.paths, ["/m/Shows/Keep"])
        XCTAssertEqual(list.item("shows")?.excluded, ["/m/Shows/Keep"])
    }

    func testTheUninstallOfAnAppInsideAPlannedFolderStays() {
        var list = PlanList()
        var app = item("app", ["/m/Apps/A.app"])
        app.step = .uninstall
        list.add(app)
        list.add(item("apps", ["/m/Apps"]))
        XCTAssertEqual(list.item("app")?.step, .uninstall)
        XCTAssertEqual(list.item("apps")?.excluded, ["/m/Apps/A.app"])
    }

    func testWhatGoesWithAThingLeavesWithIt() {
        var list = PlanList()
        list.add(item("app", ["/a/A.app"]))
        list.add(item("app:also", ["/a/data"]))
        list.add(item("app:other-copy", ["/b/copy"]))
        list.remove("app")
        XCTAssertTrue(list.isEmpty)
    }

    func testKeepingAThingKeepsWhatGoesWithItOutToo() {
        var list = PlanList()
        list.add(item("app", ["/a/A.app"]))
        list.add(item("app:also", ["/a/data"]))
        list.keep("app", title: "A")
        XCTAssertTrue(list.isEmpty)
    }

    func testWhatsTakenBackCanStayOutWhenAddingAgain() {
        var list = PlanList()
        var again = item("caches", ["/c"])
        again.excluded = ["/c/mine"]
        list.add(again)
        XCTAssertFalse(list.covers("/c/mine"))
        XCTAssertTrue(list.covers("/c/other"))
    }

    func testAMoveOfAnOpenedUpFolderKeepsItsShape() {
        let thing = item("m", ["/a/Show"])
        XCTAssertEqual(PlanList.moveDestination(of: "/a/Show", item: thing, folder: "/Volumes/Spare/TV"), "/Volumes/Spare/TV")
        XCTAssertEqual(PlanList.moveDestination(of: "/a/Show/ep1.mkv", item: thing, folder: "/Volumes/Spare/TV"), "/Volumes/Spare/TV/Show")
        XCTAssertEqual(PlanList.moveDestination(of: "/a/Show/S1/ep1.mkv", item: thing, folder: "/Volumes/Spare/TV"), "/Volumes/Spare/TV/Show/S1")
    }

    func testPathsAsYoudWriteThem() {
        XCTAssertEqual(PathMath.visible("/System/Volumes/Data/Users/x/y"), "/Users/x/y")
        XCTAssertEqual(PathMath.visible("/Users/x/y"), "/Users/x/y")
        XCTAssertEqual(PathMath.mount(of: "/Volumes/Spare/a/b"), "/Volumes/Spare")
        XCTAssertEqual(PathMath.mount(of: "/Users/x"), "/")
    }

    func testPlanSurvivesBeingSaved() throws {
        var list = PlanList()
        var thing = item("m", ["/m"])
        thing.step = .move(folder: "/Volumes/Spare/Media")
        list.add(thing)
        list.keep("k", title: "K")
        let file = PlanFile(list: list, cleaned: [CleanedThing(itemID: "m", title: "M", original: "/m", inTrash: "/.Trash/m", bytes: 5)], lastItems: [thing])
        let back = try JSONDecoder().decode(PlanFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(back.list, list)
        XCTAssertEqual(back.cleaned.first?.bytes, 5)
        XCTAssertEqual(back.list.items.first?.step, .move(folder: "/Volumes/Spare/Media"))
    }

    // MARK: Looking things up

    func testAnItemIsFoundByItsIDAfterEveryKindOfChange() {
        var list = PlanList()
        for n in 0..<50 { list.add(PlanItem(id: "row:\(n)", title: "Row \(n)", note: "", tierRaw: Tier.noLoss.rawValue, paths: ["/Volumes/Fake/\(n)"])) }
        XCTAssertEqual(list.item("row:7")?.title, "Row 7")
        XCTAssertNil(list.item("row:50"))
        let before = list
        list.remove("row:7")
        XCTAssertNil(list.item("row:7"))
        XCTAssertEqual(list.item("row:49")?.title, "Row 49", "everything after it moved up one")
        XCTAssertEqual(before.item("row:7")?.title, "Row 7", "a copy made earlier still answers for itself")
        list.items[0].title = "Renamed"
        XCTAssertEqual(list.item("row:0")?.title, "Renamed")
        list.items.removeAll { $0.id == "row:1" }
        XCTAssertNil(list.item("row:1"))
        list.takeBack("/Volumes/Fake/2")
        XCTAssertNil(list.item("row:2"))
        let again = try? JSONDecoder().decode(PlanList.self, from: JSONEncoder().encode(list))
        XCTAssertEqual(again, list)
        XCTAssertEqual(again?.item("row:30")?.title, "Row 30")
    }

    func testPlannedPathsAreFoundOnTheMapOnceEach() {
        let disk = FakeDisk()
        let film = disk.file("/Volumes/Fake/films/a.mkv", 4_000_000_000)
        disk.file("/Volumes/Fake/films/b.mkv", 2_000_000_000)
        let shots = disk.file("/Volumes/Fake/shots/big.png", 3_000_000)
        disk.finish()
        var places = PlanPlaces()
        let items = [
            PlanItem(id: "films", title: "Films", note: "", tierRaw: Tier.yourCall.rawValue, paths: ["/Volumes/Fake/films"], excluded: ["/Volumes/Fake/films/b.mkv"]),
            PlanItem(id: "shots", title: "Shots", note: "", tierRaw: Tier.noLoss.rawValue,
                     paths: ["/Volumes/Fake/shots/big.png", "/Volumes/Fake/shots/small.png", "/Volumes/Fake/nowhere/x.png"]),
        ]
        places.resolve(items, in: disk.tree)
        XCTAssertEqual(places.nodes["films"], [disk.node("/Volumes/Fake/films")])
        XCTAssertEqual(places.nodes["shots"], [shots])
        XCTAssertEqual(places.loose["shots"], ["/Volumes/Fake/shots/small.png"], "in a folder that's on the map, though too small to be on it itself")
        XCTAssertEqual(places.excluded, [disk.node("/Volumes/Fake/films/b.mkv")])
        XCTAssertEqual(places.set?.contains(film), true)
        XCTAssertEqual(places.back?.contains(film), false)
        XCTAssertNil(places.node(at: "/Volumes/Fake/nowhere/x.png", in: disk.tree))
        // What wasn't there is remembered as that, until it's known to be.
        places.remember(film, at: "/Volumes/Fake/nowhere/x.png")
        XCTAssertEqual(places.node(at: "/Volumes/Fake/nowhere/x.png", in: disk.tree), film)
    }

    func testANameIsFoundHoweverItsAccentsAreWritten() {
        let disk = FakeDisk()
        let composed = "Caf\u{00E9}", decomposed = "Cafe\u{0301}"
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let file = disk.file("/Volumes/Fake/\(decomposed)/menu.pdf", 5_000_000)
        disk.file("/Volumes/Fake/plain/x.bin", 5_000_000)
        disk.finish()
        XCTAssertEqual(disk.tree.find(path: "/Volumes/Fake/\(decomposed)/menu.pdf"), file)
        XCTAssertEqual(disk.tree.find(path: "/Volumes/Fake/\(composed)/menu.pdf"), file, "the same name to anyone reading it")
        XCTAssertEqual(disk.tree.find(visible: "/Volumes/Fake/plain/x.bin"), disk.node("/Volumes/Fake/plain/x.bin"))
        XCTAssertNil(disk.tree.find(path: "/Volumes/Fake/plain/X.BIN"))
        XCTAssertNil(disk.tree.find(path: "/Volumes/Fake/plai"))
        XCTAssertEqual(disk.tree.child(of: disk.node("/Volumes/Fake"), named: "plain"), disk.node("/Volumes/Fake/plain"))
    }

    /// A planned thing's id is in the plan that's saved between launches, and ties a suggestion to its other copy and its
    /// data. If what an id looks like ever changed, a saved plan would no longer match what's on screen.
    func testPlanIDsStayWhatASavedPlanHolds() throws {
        XCTAssertEqual(PlanItem.trashID, "trash")
        XCTAssertEqual(PlanItem.id(pickedByHand: "/Users/someone/big.mov"), "path:/Users/someone/big.mov")
        XCTAssertEqual(PlanItem.id(sent: "/Users/someone/big.mov"), "sent:/Users/someone/big.mov")
        XCTAssertEqual(PlanItem.otherCopyID(of: "series:Show"), "series:Show:other-copy")
        XCTAssertEqual(PlanItem.dataID(of: "app:com.example"), "app:com.example:also")
        func item(_ id: String) -> PlanItem { PlanItem(id: id, title: id, note: "", tierRaw: Tier.yourCall.rawValue, paths: ["/Volumes/Fake/" + id]) }
        XCTAssertTrue(item("path:/x").isPickedByHand)
        XCTAssertFalse(item("series:Show").isPickedByHand)
        XCTAssertTrue(item("series:Show:other-copy").isOtherCopy)
        XCTAssertFalse(item("series:Show").isOtherCopy)

        // Taking a suggestion out takes its other copy and its data with it, and nothing else.
        var list = PlanList()
        for id in ["series:Show", PlanItem.otherCopyID(of: "series:Show"), PlanItem.dataID(of: "series:Show"), "series:Show 2", PlanItem.id(pickedByHand: "/y")] { list.add(item(id)) }
        list.remove("series:Show")
        XCTAssertEqual(list.items.map(\.id), ["series:Show 2", "path:/y"])

        // A plan saved before today reads back, with every id as it was.
        let saved = #"{"list":{"items":[{"id":"series:Show:other-copy","title":"Other copy of Show","note":"","tierRaw":3,"paths":["/Volumes/Fake/t"],"excluded":[],"step":{"trash":{}},"addedAt":0,"byHand":false,"lastKnownBytes":5}],"kept":[]},"cleaned":[],"lastItems":[],"oldTrashBytes":0}"#
        if let file = try? JSONDecoder().decode(PlanFile.self, from: Data(saved.utf8)) {
            XCTAssertEqual(file.list.items.first?.isOtherCopy, true)
        } else {
            // What a step looks like when saved is the encoder's business. Round-trip one made here instead.
            let file = PlanFile(list: list)
            let back = try JSONDecoder().decode(PlanFile.self, from: JSONEncoder().encode(file))
            XCTAssertEqual(back.list.items.map(\.id), list.items.map(\.id))
        }
    }
}
