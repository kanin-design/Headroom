import XCTest
@testable import Headroom

/// The map on screen is never changed where it is, because other threads read it. A change is made to a copy.
final class MapCopyTests: XCTestCase {
    private func disk(packed: Bool = true) -> FakeDisk {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/films/a.mkv", 4_000_000_000, kind: .video)
        disk.file("/Volumes/Fake/films/b.mkv", 2_000_000_000, kind: .video)
        disk.file("/Volumes/Fake/music/c.flac", 1_000_000_000, kind: .audio)
        disk.linked("/Volumes/Fake/films/d.mkv", "/Volumes/Fake/seeding/d.mkv", 3_000_000_000)
        if packed { disk.finish() } else { disk.tree.finish() }
        return disk
    }

    private func numbers(_ tree: DiskTree) -> [[UInt64]] {
        (0..<tree.count).map { i in
            let id = UInt32(i)
            return [tree.totals[i], UInt64(tree.totalFiles[i]), UInt64(tree.nodes[i].flags), UInt64(tree.nodes[i].firstChild), UInt64(tree.nodes[i].nextSibling),
                    tree.aliasTotals[i], UInt64(tree.dfsIn[i]), UInt64(tree.dfsSize[i])] + tree.kindBytes(id)
        }
    }

    func testACopyReadsTheSame() {
        for packed in [true, false] {
            let disk = disk(packed: packed)
            let copy = disk.tree.copy()
            XCTAssertEqual(numbers(copy), numbers(disk.tree))
            XCTAssertEqual(copy.scanID, disk.tree.scanID)
            XCTAssertEqual(copy.links.count, disk.tree.links.count)
            XCTAssertEqual(copy.path(disk.node("/Volumes/Fake/films/a.mkv")), "/Volumes/Fake/films/a.mkv")
            XCTAssertEqual(copy.find(path: "/Volumes/Fake/music/c.flac"), disk.node("/Volumes/Fake/music/c.flac"))
            XCTAssertEqual(copy.rootPath, disk.tree.rootPath)
            XCTAssertEqual(copy.free, disk.tree.free)
        }
    }

    func testTakingSomethingOutOfACopyLeavesTheOriginalAsItWas() {
        for packed in [true, false] {
            let disk = disk(packed: packed)
            let before = numbers(disk.tree)
            let copy = disk.tree.copy()
            let films = disk.node("/Volumes/Fake/films")
            copy.remove(films)
            copy.add(1_000, to: copy.free)
            XCTAssertEqual(numbers(disk.tree), before, "the map being read changed under its readers")
            XCTAssertFalse(disk.tree.nodes[Int(films)].has(NodeFlag.gone))
            XCTAssertTrue(copy.nodes[Int(films)].has(NodeFlag.gone))
            XCTAssertEqual(copy.totals[0], disk.tree.totals[0] - 9_000_000_000 + 1_000)
            XCTAssertEqual(copy.kindBytes(1)[Int(Kind.video.rawValue)], 0)
            XCTAssertGreaterThan(disk.tree.kindBytes(1)[Int(Kind.video.rawValue)], 8_999_000_000)
            XCTAssertNil(copy.find(path: "/Volumes/Fake/films/a.mkv"))
            XCTAssertNotNil(disk.tree.find(path: "/Volumes/Fake/films/a.mkv"))
        }
    }

    func testPuttingItBackInALaterCopyGivesTheFirstMapAgain() {
        let disk = disk()
        let before = numbers(disk.tree)
        let films = disk.node("/Volumes/Fake/films")
        let without = disk.tree.copy()
        without.remove(films)
        let back = without.copy()
        back.restore(films)
        XCTAssertEqual(numbers(back).map { $0[0] }, before.map { $0[0] })
        XCTAssertEqual(back.kindBytes(0), disk.tree.kindBytes(0))
        XCTAssertTrue(without.nodes[Int(films)].has(NodeFlag.gone))
        XCTAssertEqual(back.children(disk.node("/Volumes/Fake")).sorted(), disk.tree.children(disk.node("/Volumes/Fake")).sorted())
    }

    /// A copy made while the scan's workers write never holds a link to a node it hasn't got.
    func testAPictureCutsLinksPastItsEnd() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/a/one.bin", 5_000_000)
        let folder = disk.node("/Volumes/Fake/a")
        let picture = disk.tree.picture(upTo: Int(folder) + 1)
        XCTAssertEqual(picture.count, Int(folder) + 1)
        XCTAssertEqual(picture.nodes[Int(folder)].firstChild, 0)
        XCTAssertEqual(picture.path(folder), "/Volumes/Fake/a")
        for i in 0..<picture.count {
            XCTAssertLessThan(Int(picture.nodes[i].firstChild), picture.count)
            XCTAssertLessThan(Int(picture.nodes[i].nextSibling), picture.count)
        }
    }

    func testAMapReadBeforeSomethingLeftIsOutOfDate() {
        let shown = disk().tree, new = disk().tree
        XCTAssertFalse(AppModel.isOutOfDate(replacing: shown, with: new, cleaning: false, editsThen: 3, editsNow: 3))
        XCTAssertTrue(AppModel.isOutOfDate(replacing: shown, with: new, cleaning: true, editsThen: 3, editsNow: 3))
        XCTAssertTrue(AppModel.isOutOfDate(replacing: shown, with: new, cleaning: false, editsThen: 3, editsNow: 4))
        // Nothing on screen yet, or another disk's map: there's nothing for it to be behind.
        XCTAssertFalse(AppModel.isOutOfDate(replacing: nil, with: new, cleaning: true, editsThen: 3, editsNow: 4))
        let other = disk().tree
        other.rootPath = "/Volumes/Other"
        XCTAssertFalse(AppModel.isOutOfDate(replacing: other, with: new, cleaning: true, editsThen: 3, editsNow: 4))
    }

    /// When anything inside last changed is added up once, at the end of a scan, like the sizes, and a copy has it too.
    func testEveryFolderKnowsTheNewestDateInside() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/a/old.bin", 5_000_000, modTime: 1_000)
        disk.file("/Volumes/Fake/a/deep/er/new.bin", 5_000_000, modTime: 9_000)
        disk.file("/Volumes/Fake/b/mid.bin", 5_000_000, modTime: 4_000)
        disk.finish()
        for tree in [disk.tree, disk.tree.copy()] {
            XCTAssertEqual(tree.newest[Int(disk.node("/Volumes/Fake/a"))], 9_000)
            XCTAssertEqual(tree.newest[Int(disk.node("/Volumes/Fake/a/deep"))], 9_000)
            XCTAssertEqual(tree.newest[Int(disk.node("/Volumes/Fake/a/old.bin"))], 1_000)
            XCTAssertEqual(tree.newest[Int(disk.node("/Volumes/Fake/b"))], 4_000)
            XCTAssertEqual(tree.newest[Int(disk.node("/Volumes/Fake"))], 9_000)
        }
    }
}
