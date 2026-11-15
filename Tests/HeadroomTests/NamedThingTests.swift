import XCTest
@testable import Headroom

/// The words that get copied, and where the other side of a link is.
final class NamedThingTests: XCTestCase {
    func testThePathIsTheOneMacOSShows() {
        XCTAssertEqual(PathMath.visible("/System/Volumes/Data/Users/someone/Media"), "/Users/someone/Media")
        XCTAssertEqual(PathMath.visible("/Volumes/Spare/Media"), "/Volumes/Spare/Media")
        XCTAssertEqual(PathMath.visible("/Applications/Some.app"), "/Applications/Some.app")
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

    // MARK: A thing inside a thing

    /// A file listed in an opened row is inside the row. Off the file and still on the row, the row is what's pointed at
    /// again, and its files light again.
    func testLeavingAFileInsideARowPointsAtTheRowAgain() {
        let row = PointedAt()
        row.thing = NamedThing(nodes: [10, 11, 12], title: "Chrome cache")
        row.isInside = true
        let file = NamedThing(11)
        XCTAssertEqual(PointedAt.afterLeaving(file, pointed: file, enclosing: row)?.title, "Chrome cache")
        XCTAssertEqual(PointedAt.litAfterLeaving(inside: row), [10, 11, 12])
    }

    /// Off the file and off the row in the same move, whichever of the two is told first.
    func testLeavingBothAtOncePointsAtNothingInEitherOrder() {
        let row = PointedAt()
        let rowThing = NamedThing(nodes: [10, 11, 12], title: "Chrome cache")
        row.thing = rowThing
        let file = NamedThing(11)

        // The file hears first, while the row still thinks the pointer is on it. Then the row.
        row.isInside = true
        var pointed = PointedAt.afterLeaving(file, pointed: file, enclosing: row)
        row.isInside = false
        pointed = PointedAt.afterLeaving(rowThing, pointed: pointed, enclosing: nil)
        XCTAssertNil(pointed)

        // The row hears first. Then the file.
        row.isInside = false
        pointed = PointedAt.afterLeaving(rowThing, pointed: file, enclosing: nil)
        XCTAssertEqual(pointed?.nodes, [11], "the row leaving doesn't take away what's still pointed at inside it")
        pointed = PointedAt.afterLeaving(file, pointed: pointed, enclosing: row)
        XCTAssertNil(pointed)
        XCTAssertEqual(PointedAt.litAfterLeaving(inside: row), [], "and nothing is left lit")
    }

    /// The pointer has already reached the next row when the one before hears it has left.
    func testTheNextRowStaysPointedAtWhenTheLastOneLeavesLate() {
        let next = NamedThing(nodes: [20], title: "Spotify cache")
        XCTAssertEqual(PointedAt.afterLeaving(NamedThing(11), pointed: next, enclosing: nil)?.title, "Spotify cache")
        XCTAssertNil(PointedAt.afterLeaving(NamedThing(11), pointed: NamedThing(11), enclosing: nil))
    }

    /// The names around the ring only need telling when the pointer comes onto the ring, leaves it, or reaches a piece
    /// that has a name: crossing pieces without one changes nothing for them.
    func testTheNamesAreOnlyToldWhatConcernsThem() {
        let named: Set<UInt32> = [5, 9]
        XCTAssertEqual(LabelLight(hovering: nil, named: named), LabelLight())
        let onUnnamed = LabelLight(hovering: 100, named: named)
        XCTAssertTrue(onUnnamed.onAnything)
        XCTAssertNil(onUnnamed.node)
        XCTAssertEqual(LabelLight(hovering: 101, named: named), onUnnamed, "another piece without a name: nothing new to draw")
        XCTAssertEqual(LabelLight(hovering: 9, named: named).node, 9)
        XCTAssertNotEqual(LabelLight(hovering: 9, named: named), onUnnamed)
    }
}
