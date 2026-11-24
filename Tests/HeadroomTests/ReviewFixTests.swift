import XCTest

@testable import Headroom

/// What the 2026-11-11 review found and fixed, pinned so it stays fixed.
final class ReviewFixTests: XCTestCase {
    func testOnlyARealTrashCountsBeforeDeletingForGood() {
        let home = NSHomeDirectory()
        XCTAssertTrue(Cleaner.isInTrash(home + "/.Trash/old.zip"))
        XCTAssertTrue(Cleaner.isInTrash("/System/Volumes/Data" + home + "/.Trash/folder/old.zip"))
        XCTAssertTrue(Cleaner.isInTrash("/Volumes/Spare/.Trashes/501/old.zip"))
        XCTAssertFalse(Cleaner.isInTrash(home + "/.Trash"), "The Trash itself isn't in the Trash")
        XCTAssertFalse(Cleaner.isInTrash("/Volumes/Spare/.Trashes/501"))
        XCTAssertFalse(Cleaner.isInTrash("/Volumes/Spare/.Trashes"))
        XCTAssertFalse(Cleaner.isInTrash(home + "/project/.Trash/notes.txt"), "A folder that's only called .Trash is yours")
        XCTAssertFalse(Cleaner.isInTrash(home + "/project/.Trashes/501/notes.txt"))
        XCTAssertTrue(Cleaner.isTrashFolder(home + "/.Trash"))
        XCTAssertTrue(Cleaner.isTrashFolder("/Volumes/Spare/.Trashes/501"))
        XCTAssertFalse(Cleaner.isTrashFolder(home + "/project/.Trash"))
    }

    func testAProtectedPlaceIsProtectedHoweverItsSpelled() {
        let home = NSHomeDirectory()
        XCTAssertFalse(Safety.canTrash(home + "/"), "A trailing slash is still your home folder")
        XCTAssertFalse(Safety.canTrash(home + "/Documents/"))
        XCTAssertFalse(Safety.canTrash(home + "//Documents"))
        XCTAssertFalse(Safety.canTrash(home + "/Movies/../Documents"))
        XCTAssertFalse(Safety.canTrash(""))
        XCTAssertTrue(Safety.canTrash(home + "/Movies/film.mov"))
        XCTAssertTrue(Safety.canTrash(home + "/Movies/old/"), "A folder of yours, with a slash after it, is still that folder")
    }

    func testAProjectsBuildFolderIsGroupedThoughXcodesOwnHasTheSameWords() throws {
        let rules = RuleBook(homePath: "/Users/nobody")
        let inProject = rules.rule(rules.ruleID(forName: "DerivedData"))
        XCTAssertTrue(inProject.groups, "DerivedData in a project is one row with the others")
        let xcodes = try XCTUnwrap(rules.ruleID(titled: "Xcode build output"))
        XCTAssertNotEqual(xcodes, rules.ruleID(forName: "DerivedData"))
    }

    /// A cache's one row gives way to a row per model in it, and keeps whatever else the cache holds.
    func testARowKeepsWhatTheThingsListedInItDontCover() throws {
        let d = FakeDisk()
        let a = d.file("/Volumes/Fake/cache/hub/models--a/blobs/1", 4_000_000_000)
        d.file("/Volumes/Fake/cache/hub/models--b/blobs/2", 2_000_000_000)
        d.file("/Volumes/Fake/cache/hub/datasets--c/data.parquet", 3_000_000_000)
        d.file("/Volumes/Fake/cache/xet/chunk.bin", 1_000_000_000)
        d.file("/Volumes/Fake/other/models--z/blobs/9", 5_000_000_000)
        d.finish()
        let tree = d.tree
        func row(_ path: String) -> WinRow {
            let node = d.node(path)
            return WinRow(
                id: path, title: path, subtitle: "", detail: "", tier: .redownload, nodes: [node], bytes: tree.totals[Int(node)],
                paperBytes: tree.totals[Int(node)], action: .trash, command: nil, bundleID: nil)
        }
        let models = [
            d.node("/Volumes/Fake/cache/hub/models--a"), a, d.node("/Volumes/Fake/cache/hub/models--b"), d.node("/Volumes/Fake/other/models--z"),
        ]

        var rows = [row("/Volumes/Fake/cache"), row("/Volumes/Fake/other"), row("/Volumes/Fake/cache/hub/models--a")]
        Advisors.leaveOut(models, from: &rows, tree: tree)
        let cache = try XCTUnwrap(rows.first { $0.id == "/Volumes/Fake/cache" }, "it holds 4 GB that no model row covers")
        XCTAssertEqual(Set(cache.nodes), [d.node("/Volumes/Fake/cache/hub/datasets--c"), d.node("/Volumes/Fake/cache/xet")])
        XCTAssertEqual(cache.bytes, 4_000_000_000)
        XCTAssertFalse(
            cache.nodes.contains { node in models.contains { tree.isInside($0, node) || tree.isInside(node, $0) } }, "no model is in two rows")
        XCTAssertNil(rows.first { $0.id == "/Volumes/Fake/other" }, "nothing but a model in it: the model's row is all there is to say")
        XCTAssertNotNil(rows.first { $0.id == "/Volumes/Fake/cache/hub/models--a" }, "a row that is a listed thing is someone else's to settle")
    }

    /// The folder all your projects are in never goes whole, whatever it's called. What's in it can.
    func testTheFolderYourProjectsAreInIsKeptWhole() {
        let home = NSHomeDirectory()
        for name in Safety.projectHomes {
            XCTAssertFalse(Safety.canTrash(home + "/" + name), name)
            XCTAssertFalse(Safety.canTrash("/System/Volumes/Data" + home + "/" + name + "/"), name)
            XCTAssertTrue(Safety.canTrash(home + "/" + name + "/an-old-project"), name)
        }
        XCTAssertTrue(Safety.canTrash(home + "/an-old-project"), "any other folder of yours can")
    }

    /// A game's folder is one plain name inside Steam's library. Anything else in its record could make the row for
    /// that game stand for the whole library, or for something outside it.
    func testAGameIsOnlyEverItsOwnFolder() throws {
        let home = NSTemporaryDirectory() + "headroom-steam-" + UUID().uuidString
        let library = home + "/Library/Application Support/Steam/steamapps"
        try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        func manifest(_ id: Int, _ dir: String) throws {
            let text =
                "\"AppState\"\n{\n\t\"appid\"\t\t\"\(id)\"\n\t\"name\"\t\t\"Game \(id)\"\n\t\"installdir\"\t\t\"\(dir)\"\n\t\"LastPlayed\"\t\t\"1700000000\"\n}\n"
            try text.write(toFile: library + "/appmanifest_\(id).acf", atomically: true, encoding: .utf8)
        }
        try manifest(1, "Good Game")
        try manifest(2, "")
        try manifest(3, "..")
        try manifest(4, "nested/inside")
        try manifest(5, ".")
        var facts = Facts.none
        Facts.readSteam(into: &facts, home: home)
        XCTAssertEqual(facts.games.map(\.folder), [library + "/common/Good Game"])
    }

    /// Another person's home folder that only starts like yours isn't yours.
    func testAFolderThatOnlyStartsLikeHomeIsntHome() {
        let home = NSHomeDirectory()
        XCTAssertEqual(DiskTree.friendly(home + "/Movies"), "~/Movies")
        XCTAssertEqual(DiskTree.friendly(home + "2/Movies"), home + "2/Movies")
        XCTAssertEqual(DiskTree.friendly("/System/Volumes/Data" + home + "2/x"), home + "2/x")
        XCTAssertEqual(DiskTree.friendly("/System/Volumes/Data" + home), "~")
    }
}
