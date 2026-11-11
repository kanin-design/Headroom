import XCTest
@testable import Headroom

/// What Free Up finds and how it's boxed: junk, old installers, old screenshots, the largest files, and what one click takes.
final class FreeUpBoxesTests: XCTestCase {
    private let gb: UInt64 = 1_000_000_000
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 86_400 * 20_000)

    private func row(_ id: String, _ d: FakeDisk, _ path: String, box: BoxKind, quick: Bool = false, inUse: String? = nil, askFirst: Bool = false) -> WinRow {
        let node = d.node(path)
        var r = WinRow(id: id, title: id, subtitle: "", detail: "", tier: .rebuilds, nodes: [node], bytes: d.tree.totals[Int(node)], paperBytes: d.tree.totals[Int(node)],
                       action: .trash, command: nil, bundleID: nil)
        r.isQuick = quick
        r.inUse = inUse
        r.askFirst = askFirst
        r.box = box
        return r
    }

    private func stamp(_ daysAgo: Double) -> UInt32 { UInt32(now.timeIntervalSince1970 - daysAgo * day) }

    // MARK: Recommended

    func testRecommendedIsWhatsSafeAndNotInUse() {
        let d = FakeDisk()
        for name in ["a", "b", "c", "d"] { d.file("/Volumes/Fake/Caches/\(name)/x", gb) }
        d.finish()
        let closed = row("closed", d, "/Volumes/Fake/Caches/a", box: .caches, quick: true)
        let open = row("open", d, "/Volumes/Fake/Caches/b", box: .caches, inUse: "Spotify is open")
        let unsure = row("unsure", d, "/Volumes/Fake/Caches/c", box: .caches, askFirst: true)
        let box = Box(id: "caches", title: "Caches", detail: "", color: Palette.Box.quick, rows: [closed, open, unsure])
        XCTAssertEqual(box.recommended.map(\.id), ["closed"])
        XCTAssertEqual(box.rowsATickTakes.map(\.id), ["closed"], "A tick on the box leaves an open app's cache alone too")
        var list = box
        list.isShortlist = true
        XCTAssertTrue(list.recommended.isEmpty, "Nothing in a shortlist is ever recommended")
    }

    // MARK: Old installers

    func testAnInstallerFromThisWeekIsntOld() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/Downloads/Old.dmg", 300_000_000, kind: .archive, modTime: stamp(60))
        d.file("/Volumes/Fake/Downloads/New.dmg", 300_000_000, kind: .archive, modTime: stamp(3))
        d.finish()
        let installers = Sections.build(from: [], tree: d.tree, now: now).sections.first { $0.id == "installers" }
        XCTAssertEqual(installers?.title, "Old installers")
        XCTAssertEqual(installers?.rows.map(\.title), ["Old.dmg"])
        XCTAssertEqual(installers?.detail, "1 file")
    }

    // MARK: Largest files

    func testTheLargestFilesAreTheOnesNothingElseLists() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/Movies/film.mkv", 30 * gb, kind: .video)
        d.file("/Volumes/Fake/Movies/small.mkv", 500_000_000, kind: .video)
        d.file("/Volumes/Fake/Applications/Big.app/Contents/data.bin", 9 * gb)
        d.file("/Volumes/Fake/LLM/model/weights.bin", 8 * gb)
        for i in 0..<25 { d.file("/Volumes/Fake/Disks/\(i).img", (2 + UInt64(i)) * gb) }
        d.finish()
        let model = row("model:m", d, "/Volumes/Fake/LLM/model", box: .models)
        let largest = Sections.build(from: [model], tree: d.tree, now: now).sections.first { $0.id == "largest" }
        let titles = largest?.rows.map(\.title) ?? []
        XCTAssertEqual(titles.first, "film.mkv", "Biggest first")
        XCTAssertEqual(titles.count, Sections.mostLargeFiles)
        XCTAssertFalse(titles.contains("small.mkv"), "Under a gigabyte isn't large")
        XCTAssertFalse(titles.contains("data.bin"), "Inside an app isn't a file of yours")
        XCTAssertFalse(titles.contains("weights.bin"), "Already in AI models")
        XCTAssertEqual(largest?.isShortlist, true)
        XCTAssertEqual(largest?.detail, "20 files")
    }

    // MARK: Screenshots

    func testScreenshotNamesInAnyLanguage() {
        for name in ["Screenshot 2026-11-09 at 12.00.00.png", "Screenshot 2026-11-09 at 9.05.11 PM.png", "Skjermbilde 2026-11-09 kl. 12.00.00.png",
                     "Screen Recording 2026-03-01 at 08.15.42.mov", "Bildschirmfoto 2026-01-02 um 10.11.12.png", "Screenshot 2026-11-09 at 12.00.00 (2).png",
                     "Capture d’écran 2026-05-05 à 14.00.01.jpg"] {
            XCTAssertTrue(Facts.isScreenshotName(name), name)
        }
        for name in ["Report 2026-11-09.pdf", "IMG_2026.png", "Screenshot.png", "notes 2026-11-09 at 12.00.00.txt", "2026-11-09.png"] {
            XCTAssertFalse(Facts.isScreenshotName(name), name)
        }
    }

    func testOnlyScreenshotsAreReadFromAFolder() throws {
        let folder = NSTemporaryDirectory() + "headroom-shots-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        for name in ["Screenshot 2026-11-09 at 12.00.00.png", "holiday.png", "Screen Recording 2026-03-01 at 08.15.42.mov"] {
            try Data(count: 2000).write(to: URL(fileURLWithPath: folder + "/" + name))
        }
        let found = Facts.readScreenshots(home: folder, folders: [folder])
        XCTAssertEqual(Set(found.map { ($0.path as NSString).lastPathComponent }), ["Screenshot 2026-11-09 at 12.00.00.png", "Screen Recording 2026-03-01 at 08.15.42.mov"])
        XCTAssertTrue(Facts.readScreenshots(home: folder, folders: [folder + "/missing"]).isEmpty, "A folder that isn't there adds nothing")
    }

    func testScreenshotsAreARowForEachFolderWhateverTheirAge() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/Desktop/Screen Recording 2026-03-01 at 08.15.42.mov", 40_000_000, kind: .video)
        d.finish()
        d.tree.home = d.node("/Volumes/Fake")
        var facts = Facts.none
        let old = now.addingTimeInterval(-90 * day), fresh = now.addingTimeInterval(-2 * day)
        facts.screenshots = [
            Facts.Screenshot(path: "/Volumes/Fake/Desktop/Screen Recording 2026-03-01 at 08.15.42.mov", bytes: 40_000_000, changed: old),
            Facts.Screenshot(path: "/Volumes/Fake/Desktop/Screenshot 2026-03-01 at 08.00.00.png", bytes: 300_000, changed: old),
            Facts.Screenshot(path: "/Volumes/Fake/Desktop/Screenshot 2026-11-08 at 08.00.00.png", bytes: 300_000, changed: fresh),
            Facts.Screenshot(path: "/Volumes/Fake/Pictures/Screenshots/Screenshot 2026-02-01 at 08.00.00.png", bytes: 200_000, changed: old),
        ]
        let rows = Advisors.screenshots(tree: d.tree, facts: facts, now: now)
        XCTAssertEqual(rows.count, 2, "One row a folder")
        let desktop = rows[0]
        XCTAssertEqual(desktop.nodes.count, 1, "The recording is big enough to be on the map")
        XCTAssertEqual(desktop.extraPaths.count, 2, "The small ones go by their paths, this week's too")
        XCTAssertEqual(desktop.bytes, 40_600_000)
        XCTAssertFalse(desktop.isRecommended, "They're your pictures: never part of the one click")
    }

    // MARK: Junk

    func testLogsAndUnfinishedDownloadsAreJunkHoweverSmall() throws {
        let rules = RuleBook(homePath: "/Volumes/Fake")
        let d = FakeDisk()
        d.file("/Volumes/Fake/Library/Logs/DiagnosticReports/crash.ips", 3_000_000)
        d.file("/Volumes/Fake/Library/Logs/App/app.log", 2_000_000)
        d.file("/Volumes/Fake/Downloads/film.mkv.crdownload", 700_000_000, modTime: UInt32(Date().timeIntervalSince1970 - 30 * day))
        d.file("/Volumes/Fake/Downloads/today.zip.part", 700_000_000, modTime: UInt32(Date().timeIntervalSince1970 - 3600))
        d.finish()
        let tree = d.tree
        tree.home = d.node("/Volumes/Fake")
        let logs = d.node("/Volumes/Fake/Library/Logs")
        tree.nodes[Int(logs)].rule = try XCTUnwrap(rules.ruleID(titled: "Logs"))
        tree.nodes[Int(logs)].flags |= NodeFlag.ruleRoot
        let rows = Wins.build(tree: tree, rules: rules)
        let logRow = try XCTUnwrap(rows.first { $0.title == "Logs" })
        XCTAssertEqual(logRow.box, .junk)
        XCTAssertEqual(logRow.nodes.count, 2, "What's in the folder goes; the folder stays")
        XCTAssertFalse(logRow.nodes.contains(logs))
        XCTAssertTrue(logRow.isRecommended)
        let unfinished = try XCTUnwrap(rows.first { $0.id == "junk:unfinished" })
        XCTAssertEqual(unfinished.nodes, [d.node("/Volumes/Fake/Downloads/film.mkv.crdownload")], "One still downloading today is left alone")
        XCTAssertTrue(unfinished.isRecommended)
    }
}
