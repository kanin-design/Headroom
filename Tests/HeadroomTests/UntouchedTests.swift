import XCTest
@testable import Headroom

/// The other end of Changes: what nothing has changed in for a long time.
final class UntouchedTests: XCTestCase {
    private let gigabyte: UInt64 = 1_000_000_000
    private func daysAgo(_ days: Double) -> UInt32 { UInt32(Date().timeIntervalSince1970 - days * 86_400) }
    private func value(_ map: ChangeMap, _ disk: FakeDisk, _ path: String) -> Double { Double(map.value(of: disk.node(path))) }

    private func assertSame(_ x: Lab, _ y: Lab, _ message: String, line: UInt = #line) {
        XCTAssertEqual(x.l, y.l, accuracy: 1e-4, message, line: line)
        XCTAssertEqual(x.a, y.a, accuracy: 1e-4, message, line: line)
        XCTAssertEqual(x.b, y.b, accuracy: 1e-4, message, line: line)
    }

    func testAFolderSaysHowMuchOfItHasntChanged() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Old/a.bin", 60 * gigabyte, modTime: daysAgo(400))
        disk.file("/Volumes/Fake/Old/b.bin", 40 * gigabyte, modTime: daysAgo(40))
        disk.finish()
        let year = ChangeMap(tree: disk.tree, window: .untouched(365))
        XCTAssertTrue(year.isUntouched)
        XCTAssertEqual(value(year, disk, "/Volumes/Fake/Old"), 60e9, accuracy: 1e6, "60 of its 100 GB haven't changed in a year")
        XCTAssertEqual(value(year, disk, "/Volumes/Fake/Old/a.bin"), 60e9, accuracy: 1, "a file untouched for a year is untouched as a whole")
        XCTAssertEqual(value(year, disk, "/Volumes/Fake/Old/b.bin"), 0, "a file changed last month isn't untouched for a year")
        XCTAssertEqual(value(ChangeMap(tree: disk.tree, window: .untouched(91)), disk, "/Volumes/Fake/Old"), 60e9, accuracy: 1e6)
        XCTAssertEqual(value(ChangeMap(tree: disk.tree, window: .untouched(30)), disk, "/Volumes/Fake/Old"), 100e9, accuracy: 1e6, "neither changed in the last month")
    }

    func testFreeSpaceAndWhatsHiddenAreNeverUntouched() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Old/a.bin", 5 * gigabyte, modTime: daysAgo(900))
        disk.finish()
        let map = ChangeMap(tree: disk.tree, window: .untouched(365))
        XCTAssertEqual(map.value(of: disk.tree.free), 0, "free space has no files to be old")
        XCTAssertEqual(Double(map.total), 5e9, accuracy: 1e6, "the whole disk's untouched part leaves free space out")
    }

    func testSomethingYouUsedLatelyIsntUntouched() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Applications/Old.app/Contents/binary", 3 * gigabyte, kind: .app, modTime: daysAgo(1000))
        disk.file("/Volumes/Fake/Applications/Forgotten.app/Contents/binary", 2 * gigabyte, kind: .app, modTime: daysAgo(1000))
        disk.file("/Volumes/Fake/Media/film.mkv", 8 * gigabyte, kind: .video, modTime: daysAgo(800))
        disk.finish()
        var facts = Facts()
        facts.apps = [AppFact(path: "/Volumes/Fake/Applications/Old.app", name: "Old", bundleID: "com.example.old", fromAppStore: false, addedAt: nil,
                              newestSign: Date().addingTimeInterval(-3 * 86_400), signCount: 1, isRunning: false, makerNote: nil, settings: [], data: [])]
        facts.plexFiles["/Volumes/Fake/Media/film.mkv"] = Facts.PlexFile(views: 1, lastViewed: Date().addingTimeInterval(-20 * 86_400))
        let used = ChangeMap.usedRecently(facts, in: disk.tree, days: 365)
        XCTAssertEqual(Set(used), [disk.node("/Volumes/Fake/Applications/Old.app"), disk.node("/Volumes/Fake/Media/film.mkv")])
        let map = ChangeMap(tree: disk.tree, window: .untouched(365), used: used)
        XCTAssertEqual(value(map, disk, "/Volumes/Fake/Applications/Old.app"), 0, "opened three days ago")
        XCTAssertEqual(value(map, disk, "/Volumes/Fake/Applications"), 2e9, accuracy: 1e6, "only the app nobody opens counts")
        XCTAssertEqual(value(map, disk, "/Volumes/Fake/Media"), 0, "watched last month")
        XCTAssertTrue(ChangeMap.usedRecently(facts, in: disk.tree, days: 1).isEmpty, "nothing was used in the last day")
    }

    func testTheRingWearsHowMuchIsUntouched() {
        assertSame(Lenses.untouchedLab(untouched: 100 * gigabyte, bytes: 100 * gigabyte), Palette.frost(1), "all of it")
        assertSame(Lenses.untouchedLab(untouched: 60 * gigabyte, bytes: 100 * gigabyte), Palette.frost(0.6), "60 of 100 GB")
        assertSame(Lenses.untouchedLab(untouched: 0, bytes: 100 * gigabyte), Palette.quiet, "none of it")
        let warm = Palette.heat(1), cold = Palette.frost(1)
        XCTAssertLessThan(warm.b * cold.b, 0, "heat runs yellow and frost runs blue, so the two ends never look alike")
    }

    func testTheListNamesTheFolderThatHoldsIt() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Projects/Finished/footage.mov", 40 * gigabyte, kind: .video, modTime: daysAgo(500))
        disk.file("/Volumes/Fake/Projects/Current/edit.mov", 10 * gigabyte, kind: .video, modTime: daysAgo(2))
        disk.finish()
        let map = ChangeMap(tree: disk.tree, window: .untouched(365))
        let rows = map.rows(tree: disk.tree, rules: RuleBook(homePath: "/Users/nobody"))
        XCTAssertEqual(rows.first?.node, disk.node("/Volumes/Fake/Projects/Finished"))
        XCTAssertEqual(Double(rows.first?.delta ?? 0), 40e9, accuracy: 1e6)
        XCTAssertFalse(rows.contains { $0.node == disk.node("/Volumes/Fake/Projects/Current") }, "what's being worked on isn't listed")
    }

    func testTheWindowsSayHowLong() {
        XCTAssertEqual(ChangeWindow.untouchedWindows.map(\.title), ["1 month", "3 months", "1 year"])
        XCTAssertEqual(ChangeWindow.untouchedWindows.map(\.span), ["for a month", "for 3 months", "for a year"])
        XCTAssertFalse(ChangeWindow.days(7).isUntouched)
    }
}
