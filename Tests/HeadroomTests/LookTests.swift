import XCTest
@testable import Headroom

/// What the card Space opens shows. It all comes from the map.
final class LookTests: XCTestCase {
    private let megabyte: UInt64 = 1_000_000
    private let shows = "/Volumes/Fake/Media/Shows"

    private func disk() -> FakeDisk {
        let disk = FakeDisk()
        disk.file(shows + "/small.mkv", 10 * megabyte, kind: .video)
        disk.file(shows + "/big.mkv", 30 * megabyte, kind: .video)
        disk.file(shows + "/middle.mkv", 20 * megabyte, kind: .video)
        disk.file("/Volumes/Fake/Media/notes.txt", 2 * megabyte, kind: .document)
        disk.finish()
        return disk
    }

    func testWhatsInsideComesBiggestFirst() {
        let disk = disk()
        let rows = LookContents.rows(of: disk.node(shows), in: disk.tree).map { disk.tree.name($0) }
        XCTAssertEqual(rows, ["big.mkv", "middle.mkv", "small.mkv"])
    }

    func testAFileHasNothingInside() {
        let disk = disk()
        XCTAssertTrue(LookContents.rows(of: disk.node(shows + "/big.mkv"), in: disk.tree).isEmpty)
        XCTAssertFalse(LookContents.isFolder(disk.node(shows + "/big.mkv"), in: disk.tree))
        XCTAssertTrue(LookContents.isFolder(disk.node(shows), in: disk.tree))
    }

    func testNextGoesOnThenBackThenUp() {
        let disk = disk()
        let big = disk.node(shows + "/big.mkv"), middle = disk.node(shows + "/middle.mkv"), small = disk.node(shows + "/small.mkv")
        XCTAssertEqual(LookContents.next(after: big, in: disk.tree), middle, "The next one along")
        XCTAssertEqual(LookContents.next(after: small, in: disk.tree), middle, "The last one goes to the one before")

        let alone = FakeDisk()
        alone.file(shows + "/only.mkv", megabyte, kind: .video)
        alone.finish()
        XCTAssertEqual(LookContents.next(after: alone.node(shows + "/only.mkv"), in: alone.tree), alone.node(shows), "Nothing next to it, so what held it")
    }

    func testPicturesOnlyWhenThatsMostlyWhatAFolderIs() {
        let photos = FakeDisk()
        photos.file(shows + "/a.jpg", 5 * megabyte, kind: .image)
        photos.file(shows + "/b.jpg", 9 * megabyte, kind: .image)
        photos.file(shows + "/notes.txt", 2 * megabyte, kind: .document)
        photos.finish()
        XCTAssertEqual(LookContents.media(in: photos.node(shows), tree: photos.tree).map { photos.tree.name($0) }, ["b.jpg", "a.jpg"])

        let papers = FakeDisk()
        papers.file(shows + "/a.jpg", 2 * megabyte, kind: .image)
        papers.file(shows + "/notes.pdf", 9 * megabyte, kind: .document)
        papers.finish()
        XCTAssertTrue(LookContents.media(in: papers.node(shows), tree: papers.tree).isEmpty)
    }

    func testVideoMacOSCantDrawIsLeftOut() {
        let disk = disk()
        XCTAssertTrue(LookContents.media(in: disk.node(shows), tree: disk.tree).isEmpty, ".mkv has no picture to give")
        let movies = FakeDisk()
        movies.file(shows + "/a.mov", 5 * megabyte, kind: .video)
        movies.file(shows + "/b.mkv", 9 * megabyte, kind: .video)
        movies.finish()
        XCTAssertEqual(LookContents.media(in: movies.node(shows), tree: movies.tree).map { movies.tree.name($0) }, ["a.mov"])
    }

    func testFactsSayWhatKindAndWhenItChanged() {
        let disk = FakeDisk()
        disk.file(shows + "/report.pdf", megabyte, kind: .document, modTime: 1_700_000_000)
        disk.file(shows + "/other.pdf", megabyte, kind: .document)
        disk.finish()
        // Anywhere inside counts, not only what's directly in the folder.
        XCTAssertEqual(LookContents.facts(of: disk.node("/Volumes/Fake/Media"), in: disk.tree)?.contains("changed"), true)
        XCTAssertEqual(LookContents.facts(of: disk.node(shows + "/report.pdf"), in: disk.tree)?.contains("PDF"), true)
        XCTAssertNil(LookContents.facts(of: 0, in: disk.tree))
    }
}
