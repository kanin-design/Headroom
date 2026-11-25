import XCTest

@testable import Headroom

/// A folder's things go round the ring biggest first, or by name as the Finder sorts them, and the lists of them follow.
final class SortByTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("headroom-sort-" + UUID().uuidString)
        if let real = realpath(NSTemporaryDirectory(), nil) {
            root = (String(cString: real) as NSString).appendingPathComponent((root as NSString).lastPathComponent)
            free(real)
        }
        // A season whose later episodes are the bigger ones, so biggest first and by name go opposite ways round. Each is 1 MiB
        // or more, so on the map.
        for episode in 1...12 {
            try write("Show/Season 01/Show - S01E\(episode) - 1080p.mkv", bytes: (1 << 20) + 65536 * episode)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ path: String, bytes: Int) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: full))
    }

    private func scanned() throws -> DiskTree {
        let facts = VolumeFacts(name: "Test", mountPath: root, capacity: 1 << 40, free: 1 << 39, isBoot: false)
        let scan = DiskScan(facts: facts, rules: RuleBook(homePath: NSHomeDirectory()), fullAccess: false)
        scan.run(mode: .full, threads: 2)
        return scan.tree
    }

    func testNamesGoInTheFindersOrder() {
        let names = ["Ærø", "S01E10.mkv", "zebra", "episode 2", "a.txt", "S01E1.mkv", "Episode 10", "A", "S01E02.mkv", "Episode 1"]
        let sorted = names.sorted { NameOrder.compare($0, $1) < 0 }
        XCTAssertEqual(
            sorted, ["A", "a.txt", "Episode 1", "episode 2", "Episode 10", "S01E1.mkv", "S01E02.mkv", "S01E10.mkv", "zebra", "Ærø"])
        // A strict order: each name the same as itself only, and every pair one way round.
        for a in names {
            XCTAssertEqual(NameOrder.compare(a, a), 0)
            for b in names where a != b { XCTAssertEqual(NameOrder.compare(a, b) < 0, NameOrder.compare(b, a) > 0, "\(a), \(b)") }
        }
        XCTAssertNotEqual(NameOrder.compare("file01", "file1"), 0, "the same number written two ways still has an order")
    }

    /// A search lists a show's folder, its episodes and files of the same name elsewhere side by side. Each episode is cut
    /// as the ring cuts it among its season, not left whole beside names it shares nothing with but its first word.
    @MainActor
    func testFindsAreCutAmongTheirOwnFolder() {
        let season = "~/Media/TV/Lantern (2025)/Season 01"
        let torrent = "~/Downloads/Lantern.S01.2160p.WEB-DL"
        let names = [
            "Lantern (2025)", "Lantern (2025) - S01E02 - 4K DV WEB-DL.mkv", "Lantern (2025) - S01E09 - 4K DV WEB-DL.mkv",
            "Lantern (2025) - S01E01 - 4K DV WEB-DL.mkv", "Lantern.S01E02.The.Door.2160p.WEB-DL.mkv",
            "Lantern.S01E05.Night.Falls.2160p.WEB-DL.mkv",
        ]
        let folders = ["~/Media/TV", season, season, season, torrent, torrent]
        let forms = ListNames.forms(names, inFolders: folders)
        XCTAssertEqual(forms[0], ["Lantern (2025)"], "alone in its folder, and short: left whole")
        for (i, episode) in [(1, "S01E02"), (2, "S01E09"), (3, "S01E01")] {
            XCTAssertEqual(forms[i].first, names[i], "the whole name first")
            XCTAssertTrue(forms[i].contains("Lantern…\(episode)…mkv"), "\(forms[i])")
        }
        XCTAssertTrue(forms[4].dropFirst().allSatisfy { $0.contains("S01E02") }, "\(forms[4])")
        XCTAssertGreaterThan(forms[4].count, 1, "cut among the other files of its folder")
    }

    func testTheRingGoesRoundByNameOrBiggestFirst() throws {
        let tree = try scanned()
        let season = try XCTUnwrap(tree.find(path: root + "/Show/Season 01"))
        func round(_ order: SortBy) -> [String] {
            let layout = RingLayout.build(tree: tree, focus: season, parts: tree.parts(RingSizes(), by: order), colorer: { _ in .zero })
            return layout.pieces.filter { tree.nodes[Int($0.node)].parent == season }.sorted { $0.a0 < $1.a0 }.map { tree.name($0.node) }
        }
        let episodes = (1...12).map { "Show - S01E\($0) - 1080p.mkv" }
        XCTAssertEqual(round(.name), episodes)
        XCTAssertEqual(round(.size), episodes.reversed())
        // The card's list goes round the same way.
        let first = try XCTUnwrap(tree.find(path: root + "/Show/Season 01/" + episodes[0]))
        XCTAssertEqual(LookContents.siblings(of: first, in: tree, by: .name).map { tree.name($0) }, episodes)
        XCTAssertEqual(LookContents.siblings(of: first, in: tree, by: .size).map { tree.name($0) }, episodes.reversed())
    }
}
