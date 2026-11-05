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
}
