import XCTest
@testable import Headroom

/// The words that get copied, and where the other side of a link is.
final class NamedThingTests: XCTestCase {
    func testThePathIsTheOneMacOSShows() {
        XCTAssertEqual(ThingText.visible("/System/Volumes/Data/Users/someone/Media"), "/Users/someone/Media")
        XCTAssertEqual(ThingText.visible("/Volumes/Spare/Media"), "/Volumes/Spare/Media")
        XCTAssertEqual(ThingText.visible("/Applications/Some.app"), "/Applications/Some.app")
    }

    func testTheNameIsTheOneOnDisk() {
        XCTAssertEqual(ThingText.name(ofPath: "/Users/someone/Media/Season 01"), "Season 01")
        XCTAssertEqual(ThingText.name(ofPath: "/Users/someone/Media/a film (2020).mkv"), "a film (2020).mkv")
        XCTAssertEqual(ThingText.name(ofPath: "/"), "/")
    }

    func testAListIsANameAndASizeToALine() {
        let text = ThingText.list(title: "~/Media, 4 GB", rows: [("One", "3 GB"), ("Two", "1 GB")])
        XCTAssertEqual(text, "~/Media, 4 GB\nOne\t3 GB\nTwo\t1 GB")
    }

    // MARK: The other side

    private let gigabyte: UInt64 = 1_000_000_000
    private let show = "/Volumes/Fake/Media/Show"
    private let release = "/Volumes/Fake/Downloads/Release"

    private func disk() -> FakeDisk {
        let disk = FakeDisk()
        disk.linked(show + "/e1.mkv", release + "/e1.mkv", 2 * gigabyte)
        disk.linked(show + "/e2.mkv", release + "/e2.mkv", 2 * gigabyte)
        disk.finish()
        return disk
    }

    func testWhereItsCountedPointsAtTheOtherPath() throws {
        let disk = disk()
        let story = Accounting.story(disk.node(show), in: disk.tree)
        let places = story.placesWorthNaming(size: disk.tree.totals[Int(disk.node(show))])
        XCTAssertEqual(places.map(\.path), ["/Volumes/Fake/Downloads"])
        XCTAssertEqual(places.first?.node, disk.node("/Volumes/Fake/Downloads"))
    }

    func testWhereItIsntCountedPointsBackAtWhereItIs() {
        let disk = disk()
        let story = Accounting.story(disk.node(release), in: disk.tree)
        let places = story.placesWorthNaming(size: disk.tree.totals[Int(disk.node(release))])
        XCTAssertEqual(places.map(\.path), ["/Volumes/Fake/Media"])
        XCTAssertEqual(places.first?.node, disk.node("/Volumes/Fake/Media"))
    }

    func testALittleSharedInSomethingBigIsNotWorthNaming() {
        let disk = FakeDisk()
        disk.linked(show + "/e1.mkv", release + "/e1.mkv", 1_000_000)
        disk.file(show + "/e2.mkv", 40 * gigabyte)
        disk.finish()
        let story = Accounting.story(disk.node(show), in: disk.tree)
        XCTAssertGreaterThan(story.sharedOut, 0)
        XCTAssertTrue(story.placesWorthNaming(size: disk.tree.totals[Int(disk.node(show))]).isEmpty)
    }

    func testAFolderWithNoLinksHasNowhereToGo() {
        let disk = FakeDisk()
        disk.file(show + "/e1.mkv", gigabyte)
        disk.finish()
        XCTAssertTrue(Accounting.story(disk.node(show), in: disk.tree).placesWorthNaming(size: gigabyte).isEmpty)
    }
}
