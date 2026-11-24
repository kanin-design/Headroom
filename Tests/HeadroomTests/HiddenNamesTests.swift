import XCTest

@testable import Headroom

/// A screenshot taken with `--hide-names` can end up anywhere, so a path has to say what the ring says and nothing else.
final class HiddenNamesTests: XCTestCase {
    private func disk() -> FakeDisk {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Media/Secret Show/Season 13/secret.episode.mkv", 5_000_000_000, kind: .video)
        disk.file("/Volumes/Fake/Media/Secret Show/Season 13/another.mkv", 4_000_000_000, kind: .video)
        disk.file("/Volumes/Fake/Downloads/private.zip", 1_000_000_000)
        disk.finish()
        HiddenNames.apply(to: disk.tree)
        return disk
    }

    /// What something is called on the disk decides what it is, whatever name is being shown for it.
    func testWhatsFoundByNameIsStillFoundWithNamesHidden() throws {
        let disk = FakeDisk()
        let old = UInt32(Date().timeIntervalSince1970 - 30 * 86_400)
        let file = disk.file("/Volumes/Fake/Downloads/private film.mkv.crdownload", 700_000_000, modTime: old)
        disk.finish()
        disk.tree.home = disk.node("/Volumes/Fake")
        HiddenNames.apply(to: disk.tree)
        XCTAssertNotEqual(disk.tree.name(file), disk.tree.rawName(file), "the name on screen is made up")
        let rows = Wins.build(tree: disk.tree, rules: RuleBook(homePath: "/Volumes/Fake"))
        XCTAssertEqual(rows.first { $0.id == "junk:unfinished" }?.nodes, [file])
        XCTAssertFalse(rows.contains { $0.title.contains("private") || $0.subtitle.contains("private") }, "and no row shows the real one")
    }

    func testAPathSaysWhatTheRingSays() {
        let disk = disk()
        let file = disk.node("/Volumes/Fake/Media/Secret Show/Season 13/secret.episode.mkv")
        var names: [String] = []
        var at = file
        while !disk.tree.nodes[Int(at)].has(NodeFlag.anchor) {
            names.insert(disk.tree.name(at), at: 0)
            at = disk.tree.nodes[Int(at)].parent
        }
        let path = "/Volumes/Fake/Media/Secret Show/Season 13/secret.episode.mkv"
        XCTAssertEqual(HiddenNames.madeUp(path: path, in: disk.tree), "/Volumes/External Disk/" + names.joined(separator: "/"))
    }

    func testNoRealNameGetsThrough() {
        let disk = disk()
        for path in [
            "/Volumes/Fake", "/Volumes/Fake/Media/Secret Show", "/Volumes/Fake/Media/Secret Show/Season 13",
            "/Volumes/Fake/Media/Secret Show/Season 13/secret.episode.mkv",
        ] {
            let shown = HiddenNames.madeUp(path: path, in: disk.tree)
            for real in ["Fake", "Media", "Secret", "Season", "episode"] { XCTAssertFalse(shown.contains(real), shown) }
        }
    }

    func testANameEveryMacHasStays() {
        let disk = disk()
        XCTAssertEqual(HiddenNames.madeUp(path: "/Volumes/Fake/Downloads", in: disk.tree), "/Volumes/External Disk/Downloads")
    }

    func testWhatTheMapDoesNotKnowIsNotNamed() {
        let disk = disk()
        XCTAssertEqual(HiddenNames.madeUp(path: "/Volumes/Fake/Downloads/not on the map/deeper", in: disk.tree), "/Volumes/External Disk/Downloads/…")
        XCTAssertEqual(HiddenNames.madeUp(path: "/Volumes/Another Disk/Secret", in: disk.tree), "/Volumes/External Disk/…")
        XCTAssertEqual(HiddenNames.madeUp(path: "/some/other/place", in: disk.tree), "/…")
    }

    func testAPathAlreadyMadeUpIsLeftAlone() {
        let disk = disk()
        XCTAssertEqual(HiddenNames.madeUp(path: "~/Videos/Series 1", in: disk.tree), "~/Videos/Series 1")
    }

    func testADiskKeepsItsNameWhenNamesAreShown() {
        // It isn't on when this runs, so a disk keeps its name.
        XCTAssertFalse(HiddenNames.isOn)
        XCTAssertEqual(HiddenNames.name(ofDisk: "My Disk", isBoot: false), "My Disk")
    }
}
