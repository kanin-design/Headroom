import XCTest
@testable import Headroom

/// A refresh reads only what the change journal says changed since a map, and copies the rest from it. Whatever changed,
/// it has to come out with the map a full read makes.
final class RefreshTests: XCTestCase {
    private var root = ""
    private var outside = ""
    private let megabyte = 1 << 20

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("headroom-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // The journal names folders by their real paths, with /private, which Foundation's own resolving leaves out.
        if let real = realpath(root, nil) {
            root = String(cString: real)
            free(real)
        }
        outside = root + "-elsewhere"
        for at in 0..<12 {
            try write("folder-\(at)/small.txt", bytes: 4096)
            try write("folder-\(at)/inner/deeper/small.txt", bytes: 8192)
            try write("folder-\(at)/inner/big.bin", bytes: 2 * megabyte)
        }
        try write("links/original.bin", bytes: 3 * megabyte)
        try FileManager.default.createDirectory(atPath: root + "/other", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: root + "/links/original.bin", toPath: root + "/other/linked.bin")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: outside)
    }

    private func write(_ path: String, bytes: Int) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: URL(fileURLWithPath: full))
    }

    /// Everything as if it was made days ago, so nothing counts as changed in the last day, which a refresh would read.
    /// The change dates this leaves have to be older than the map, by a second.
    private func ageEverything() {
        let old = Int(Date().timeIntervalSince1970) - 3 * 86_400
        let paths = (FileManager.default.subpaths(atPath: root) ?? []).map { root + "/" + $0 }
        for path in paths {
            var list = attrlist()
            list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            list.commonattr = attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ADDEDTIME)
            var times = [timespec](repeating: timespec(tv_sec: old, tv_nsec: 0), count: 2)
            _ = times.withUnsafeMutableBytes { setattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) }
        }
        Thread.sleep(forTimeInterval: 1.1)
    }

    private func newScan() -> DiskScan {
        let facts = VolumeFacts(name: "Test", mountPath: root, capacity: 1 << 40, free: 1 << 39, isBoot: false)
        return DiskScan(facts: facts, rules: RuleBook(homePath: NSHomeDirectory()), fullAccess: false)
    }

    /// Everything read, noting where the journal was, as the app does.
    private func fullRead() throws -> DiskTree {
        let scan = newScan()
        scan.place = ChangeJournal.now(for: root)
        XCTAssertNotNil(scan.place, "the disk has a change journal")
        scan.run(mode: .full, threads: 4)
        return scan.tree
    }

    /// The map, a watcher started from it as the app starts one, then the changes, then the refresh.
    private func refresh(after change: () throws -> Void, line: UInt = #line) throws -> (map: DiskTree, scan: DiskScan) {
        ageEverything()
        let map = try fullRead()
        let place = try XCTUnwrap(map.journal)
        let watcher = try XCTUnwrap(ChangeJournal.Watcher(from: place, roots: ChangeJournal.roots(of: map)))
        XCTAssertTrue(watcher.waitForHistory(timeout: 10), line: line)
        try change()
        Thread.sleep(forTimeInterval: 1)
        let taken = try XCTUnwrap(watcher.take(from: place), "the journal kept track", line: line)
        XCTAssertNil(watcher.take(from: place), "a lot is only taken once", line: line)
        watcher.stop()
        let scan = newScan()
        XCTAssertTrue(scan.refresh(from: map, changes: taken.changes, place: taken.next), line: line)
        scan.run(mode: .full, threads: 4)
        return (map, scan)
    }

    /// Each folder and named file by its path, with everything the map knows of it.
    private func summary(_ tree: DiskTree) -> [String: [UInt64]] {
        var out: [String: [UInt64]] = [:]
        for i in 0..<tree.count {
            let id = UInt32(i)
            let n = tree.nodes[i]
            guard let path = tree.path(id) ?? (n.has(NodeFlag.synthetic) ? "piece: " + tree.name(id) : nil) else { continue }
            let row = tree.statRow(id)
            out[path] = [tree.totals[i], UInt64(tree.totalFiles[i]), tree.aliasTotals[i], n.bytes, n.aliasBytes, UInt64(n.fileCount),
                         UInt64(n.flags), UInt64(n.modTime), UInt64(n.rule)] + (0..<DiskTree.statStride).map { UInt64(row[$0]) }
        }
        return out
    }

    private func linkSummary(_ tree: DiskTree) -> Set<String> {
        Set((tree.links + tree.singleLinks).map { "\($0.key) \(tree.path($0.dir) ?? "?") \($0.file == 0 ? "" : tree.path($0.file) ?? "?") \($0.bytes) \($0.counted)" })
    }

    private func assertSame(_ refreshed: DiskTree, _ read: DiskTree, line: UInt = #line) {
        let a = summary(refreshed), b = summary(read)
        let differences = Set(a.keys).union(b.keys).sorted().filter { a[$0] != b[$0] }
        XCTAssertTrue(differences.isEmpty, "refreshed and read differ at " + differences.prefix(5).map {
            "\($0.replacingOccurrences(of: root, with: "…")): \(a[$0].map(String.init(describing:)) ?? "missing") vs \(b[$0].map(String.init(describing:)) ?? "missing")"
        }.joined(separator: "; "), line: line)
        XCTAssertEqual(linkSummary(refreshed), linkSummary(read), "the same linked files, counted in the same places", line: line)
        XCTAssertTrue(refreshed.isWhole)
    }

    func testARefreshComesOutTheSameAsReadingEverything() throws {
        let fm = FileManager.default
        let (map, scan) = try refresh {
            try write("folder-1/new.txt", bytes: 4096)
            try write("folder-2/inner/new-big.bin", bytes: 2 * megabyte)
            try fm.removeItem(atPath: root + "/folder-3")
            try fm.moveItem(atPath: root + "/folder-4", toPath: root + "/folder-4-renamed")
            // A folder put where another was, with a folder inside of the same name, is still a new folder.
            try fm.moveItem(atPath: root + "/folder-5", toPath: root + "/folder-5-old")
            try write("folder-5/inner/fresh.txt", bytes: 4096)
            try fm.removeItem(atPath: root + "/folder-6/inner/big.bin")
            try write("folder-7/inner/deeper/small.txt", bytes: 64 * 1024)
            try write("new/a/b/file.bin", bytes: 3 * megabyte)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: root + "/links/original.bin"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 7, count: megabyte))
            try handle.close()
        }
        XCTAssertFalse(scan.surprised)
        XCTAssertLessThan(scan.foldersToRead, map.count / 2, "most of the map was copied")
        assertSame(scan.tree, try fullRead())
    }

    func testOnlyWhatChangedIsRead() throws {
        let (map, scan) = try refresh { try write("folder-1/new.txt", bytes: 4096) }
        XCTAssertFalse(scan.surprised)
        // The folder that changed, and the two with the linked file in them.
        XCTAssertLessThanOrEqual(scan.foldersToRead, 3)
        XCTAssertGreaterThan(map.count, 40)
        assertSame(scan.tree, try fullRead())
    }

    func testANewHardLinkToAFileThatWasCopiedMeansReadingEverything() throws {
        let (_, scan) = try refresh {
            try FileManager.default.linkItem(atPath: root + "/folder-8/inner/big.bin", toPath: root + "/folder-9/link.bin")
        }
        XCTAssertTrue(scan.surprised, "the file is still counted in the folder that was copied")
    }

    func testAHardLinkWithAPathOffTheMapIsKnown() throws {
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: root + "/folder-0/inner/big.bin", toPath: outside + "/big.bin")
        let (map, scan) = try refresh { try write("folder-0/inner/new.txt", bytes: 4096) }
        XCTAssertEqual(map.singleLinks.count, 1, "the map keeps the file it has only one path of")
        XCTAssertFalse(scan.surprised, "it isn't new")
        assertSame(scan.tree, try fullRead())
    }
}
