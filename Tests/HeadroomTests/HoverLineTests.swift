import XCTest
@testable import Headroom

/// When something's files also have another path, the middle of the ring says what it is and where that path is.
final class HoverLineTests: XCTestCase {
    private let gigabyte: UInt64 = 1_000_000_000
    private let show = "/Volumes/Fake/Media/Show"
    private let release = "/Volumes/Fake/Downloads/Release"

    private func line(_ disk: FakeDisk, _ path: String) -> String? {
        let node = disk.node(path)
        return Accounting.hoverLine(node, bytes: disk.tree.totals[Int(node)], in: disk.tree)
    }

    /// Two episodes that are also in a torrent folder, and a small file that's only here.
    private func series(clone: Bool = false) -> FakeDisk {
        let disk = FakeDisk()
        disk.linked(show + "/e1.mkv", release + "/e1.mkv", 2 * gigabyte, clone: clone)
        disk.linked(show + "/e2.mkv", release + "/e2.mkv", 2 * gigabyte, clone: clone)
        disk.file(show + "/original.nfo", 8_000)
        disk.finish()
        return disk
    }

    func testAFolderOfHardLinksSaysSoAndWhere() {
        XCTAssertEqual(line(series(), show), "Hard links to /Volumes/Fake/Downloads")
    }

    func testOneFileIsOneHardLink() {
        XCTAssertEqual(line(series(), show + "/e1.mkv"), "Hard link to /Volumes/Fake/Downloads")
    }

    func testClonesAreCalledClones() {
        XCTAssertEqual(line(series(clone: true), show), "Clones of /Volumes/Fake/Downloads")
        XCTAssertEqual(line(series(clone: true), show + "/e1.mkv"), "Clone of /Volumes/Fake/Downloads")
    }

    func testPartOfAFolderSaysHowMuch() {
        let disk = FakeDisk()
        disk.linked(show + "/e1.mkv", release + "/e1.mkv", 3 * gigabyte)
        disk.file(show + "/extras.mkv", 1 * gigabyte)
        disk.finish()
        XCTAssertEqual(line(disk, show), "\(formatBytes(3 * gigabyte)) is hard links to /Volumes/Fake/Downloads")
    }

    func testOnlyWhatsSharedWithTheNamedPlaceIsCounted() {
        let disk = FakeDisk()
        disk.linked(show + "/e1.mkv", release + "/e1.mkv", 3 * gigabyte)
        disk.linked(show + "/e2.mkv", "/Volumes/Fake/Backup/e2.mkv", 2 * gigabyte)
        disk.finish()
        XCTAssertEqual(line(disk, show), "\(formatBytes(3 * gigabyte)) is hard links to /Volumes/Fake/Downloads")
    }

    func testTheBiggerSortIsTheOneNamed() {
        let disk = FakeDisk()
        disk.linked(show + "/e1.mkv", release + "/e1.mkv", 3 * gigabyte, clone: true)
        disk.linked(show + "/e2.mkv", release + "/e2.mkv", 1 * gigabyte)
        disk.finish()
        XCTAssertEqual(line(disk, show), "Clones of /Volumes/Fake/Downloads")
    }

    func testIfMostOfItWouldComeBackItSaysNothing() {
        let disk = FakeDisk()
        disk.linked(show + "/e1.mkv", release + "/e1.mkv", gigabyte / 10)
        disk.file(show + "/e2.mkv", 10 * gigabyte)
        disk.finish()
        XCTAssertNil(line(disk, show))
    }

    func testPathsThatAreAllInsideItSayNothing() {
        let disk = FakeDisk()
        disk.linked(show + "/e1.mkv", show + "/Season 1/e1.mkv", 2 * gigabyte)
        disk.finish()
        XCTAssertNil(line(disk, show), "Removing it frees all of it")
        XCTAssertEqual(line(disk, show + "/e1.mkv"), "Hard link to \(show)/Season 1")
    }

    func testAFolderWithNoLinksSaysNothing() {
        let disk = FakeDisk()
        disk.file(show + "/e1.mkv", 2 * gigabyte)
        disk.finish()
        XCTAssertNil(line(disk, show))
    }

    func testThePlaceWhereItIsntCountedSaysNothing() {
        XCTAssertNil(line(series(), release), "None of its size is these files, so there's nothing to explain")
    }

    /// Only files too small to get a node of their own are merged, so these are records with no file.
    func testMergingLeavesTheWordsAlone() {
        for clone in [false, true] {
            let disk = FakeDisk()
            disk.file(show + "/small files", 4 * gigabyte)
            disk.file(release + "/info.nfo", 1_000)
            let here = disk.node(show), there = disk.node(release)
            for key in 1...4 as ClosedRange<UInt64> {
                let key = key | (clone ? 1 << 63 : 0)
                disk.tree.links.append(LinkRecord(key: key, bytes: gigabyte, dir: here, file: 0, when: 0, kind: 0, counted: true))
                disk.tree.links.append(LinkRecord(key: key, bytes: gigabyte, dir: there, file: 0, when: 0, kind: 0, counted: false))
            }
            disk.finish()
            let before = line(disk, show)
            XCTAssertEqual(before, clone ? "Clones of /Volumes/Fake/Downloads" : "Hard links to /Volumes/Fake/Downloads")
            Accounting.merge(&disk.tree.links)
            XCTAssertEqual(disk.tree.links.count, 2)
            XCTAssertEqual(line(disk, show), before)
        }
    }
}
