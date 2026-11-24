import XCTest

@testable import Headroom

/// Files under 1 MB aren't on the map, so the scan writes their names to a catalogue of their own. A search has to find
/// every one of them, and none of what's on the map, and a refresh has to come out with what reading everything gives.
final class SmallFilesTests: XCTestCase {
    private var root = ""
    private var caches: URL!
    private let megabyte = 1 << 20

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("headroom-small-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // The journal names folders by their real paths, with /private.
        if let real = realpath(root, nil) {
            root = String(cString: real)
            free(real)
        }
        caches = URL(fileURLWithPath: root + "-caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        for at in 0..<12 {
            try write("folder-\(at)/small-\(at).txt", bytes: 4096)
            try write("folder-\(at)/inner/deeper/Notes-\(at).md", bytes: 8192 * (at + 1))
            try write("folder-\(at)/inner/big.bin", bytes: 2 * megabyte)
        }
        try write("empty/nothing.txt", bytes: 0)
        try write("letters/Blåbær.txt", bytes: 4096)
        // The same letter stored the other way: an a with its ring after it.
        try write("letters/Bla\u{30A}bær-decomposed.txt", bytes: 4096)
        try write("letters/README.md", bytes: 12_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(at: caches)
    }

    private func write(_ path: String, bytes: Int) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { if bytes > 0 { arc4random_buf($0.baseAddress!, bytes) } }
        try data.write(to: URL(fileURLWithPath: full))
    }

    private func newScan() -> DiskScan {
        let facts = VolumeFacts(name: "Test", mountPath: root, capacity: 1 << 40, free: 1 << 39, isBoot: false)
        return DiskScan(facts: facts, rules: RuleBook(homePath: NSHomeDirectory()), fullAccess: false)
    }

    /// Everything read, with a catalogue written as it goes.
    private func fullRead(journal: Bool = false) throws -> (DiskTree, SmallFileCatalogue) {
        let scan = newScan()
        if journal { scan.place = ChangeJournal.now(for: root) }
        let writer = try XCTUnwrap(SmallFileWriter(volume: "Test", refreshing: nil, in: caches))
        scan.scanner.smallFiles = writer
        scan.run(mode: .full, threads: 4)
        let catalogue = try XCTUnwrap(writer.finish(scan.tree))
        return (scan.tree, catalogue)
    }

    private func search(_ text: String, _ catalogue: SmallFileCatalogue, _ tree: DiskTree) throws -> SmallFileResults {
        try XCTUnwrap(catalogue.search(text, in: tree, stop: StopFlag()))
    }

    /// Every small file the search lists, by path, with its size.
    private func listed(_ found: SmallFileResults, _ tree: DiskTree) -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for file in found.top { out[(tree.path(file.folder) ?? "?") + "/" + file.name] = file.bytes }
        return out
    }

    /// What's on the disk under 1 MB, by `lstat`, as the scan counts it.
    private func smallOnDisk() -> [String: UInt64] {
        var out: [String: UInt64] = [:]
        for path in FileManager.default.subpaths(atPath: root) ?? [] {
            var info = stat()
            guard lstat(root + "/" + path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { continue }
            let allocated = UInt64(info.st_blocks) * 512
            if allocated < SmallFiles.limit { out[root + "/" + path] = ((allocated + 1023) >> 10) << 10 }
        }
        return out
    }

    func testEverySmallFileIsFoundAndNothingOnTheMap() throws {
        let (tree, catalogue) = try fullRead()
        let expected = smallOnDisk()
        XCTAssertEqual(Int(catalogue.files), expected.count)
        XCTAssertLessThan(expected.count, SmallFiles.shown, "few enough to list them all")
        // Every name has a dot in it.
        let found = try search(".", catalogue, tree)
        XCTAssertEqual(found.count, expected.count)
        XCTAssertEqual(listed(found, tree), expected)
        XCTAssertEqual(try search("big.bin", catalogue, tree).count, 0, "a file of 1 MB or more is on the map instead")
        XCTAssertEqual(Search.run("big.bin", in: tree).count, 12)
    }

    func testTheBiggestComeFirst() throws {
        let (tree, catalogue) = try fullRead()
        let found = try search("notes", catalogue, tree)
        XCTAssertEqual(found.count, 12)
        XCTAssertEqual(found.top.map(\.bytes), found.top.map(\.bytes).sorted(by: >))
        XCTAssertEqual(found.top.first?.name, "Notes-11.md")
        XCTAssertEqual(found.top.first.flatMap { tree.path($0.folder) }, root + "/folder-11/inner/deeper")
    }

    func testASearchInAFolderFindsOnlyWhatsInIt() throws {
        let (tree, catalogue) = try fullRead()
        let folder = try XCTUnwrap(tree.find(path: root + "/folder-3"))
        let deeper = try XCTUnwrap(tree.find(path: root + "/folder-3/inner/deeper"))
        // On the map: what's inside, not the folder itself.
        XCTAssertEqual(Search.run("big.bin", in: tree, within: folder).compactMap(tree.path), [root + "/folder-3/inner/big.bin"])
        XCTAssertEqual(Search.run("folder-3", in: tree, within: folder), [])
        XCTAssertEqual(Search.run("folder-3", in: tree).count, 1)
        // Small files: in the folder and in the folders inside it.
        let found = try XCTUnwrap(catalogue.search(".", in: tree, within: folder, stop: StopFlag()))
        XCTAssertEqual(Set(listed(found, tree).keys), [root + "/folder-3/small-3.txt", root + "/folder-3/inner/deeper/Notes-3.md"])
        let inner = try XCTUnwrap(catalogue.search(".", in: tree, within: deeper, stop: StopFlag()))
        XCTAssertEqual(inner.top.map(\.name), ["Notes-3.md"])
        XCTAssertEqual(inner.top.first?.folderPath, tree.path(deeper).map(PathMath.visible))
        XCTAssertEqual(inner.top.first?.onScreen, deeper)
    }

    func testCapitalsMatchBeyondAToZ() throws {
        let (tree, catalogue) = try fullRead()
        XCTAssertEqual(try search("BLÅBÆR", catalogue, tree).count, 2, "both ways of storing å")
        XCTAssertEqual(try search("readme", catalogue, tree).count, 1)
        XCTAssertEqual(try search("small-1", catalogue, tree).count, 3, "small-1, small-10 and small-11")
        XCTAssertEqual(try search("blæbær", catalogue, tree).count, 0)
    }

    func testOnlyMostAreListedButAllAreCounted() throws {
        for at in 0..<200 { try write("many/file-\(at).log", bytes: 4096 * (1 + at % 7)) }
        let (tree, catalogue) = try fullRead()
        let found = try search(".log", catalogue, tree)
        XCTAssertEqual(found.count, 200)
        XCTAssertEqual(found.top.count, SmallFiles.shown)
        let sizes = (0..<200).map { UInt64(4096 * (1 + $0 % 7)) }
        XCTAssertEqual(found.top.map(\.bytes), Array(sizes.sorted(by: >).prefix(SmallFiles.shown)), "the biggest")
    }

    func testAFolderOfManyLongNamesIsWrittenWhole() throws {
        // Over a megabyte of names in one folder: written on its own, and the room it took given back for the rest.
        let long = String(repeating: "x", count: 240)
        try FileManager.default.createDirectory(atPath: root + "/many", withIntermediateDirectories: true)
        for at in 0..<5000 { FileManager.default.createFile(atPath: root + "/many/\(long)-\(at).dat", contents: nil) }
        let (tree, catalogue) = try fullRead()
        XCTAssertEqual(Int(catalogue.files), smallOnDisk().count)
        XCTAssertEqual(try search(".dat", catalogue, tree).count, 5000)
        XCTAssertEqual(try search("x-4999.dat", catalogue, tree).top.map(\.name), [long + "-4999.dat"])
        XCTAssertEqual(try search("notes", catalogue, tree).count, 12)
        XCTAssertEqual(try search("small-", catalogue, tree).count, 12)
    }

    func testWhatsTrashedIsNotFound() throws {
        let (tree, catalogue) = try fullRead()
        let folder = try XCTUnwrap(tree.find(path: root + "/folder-3"))
        tree.remove(folder)
        let found = try search(".", catalogue, tree)
        XCTAssertEqual(found.count, smallOnDisk().count - 2)
        XCTAssertFalse(listed(found, tree).keys.contains { $0.hasPrefix(root + "/folder-3/") })
    }

    func testACatalogueIsOnlyUsedWithItsMap() throws {
        let (tree, catalogue) = try fullRead()
        XCTAssertNotNil(SmallFileCatalogue.load(volume: "Test", for: tree, in: caches))
        let (other, _) = try fullRead()
        XCTAssertFalse(catalogue.matches(other), "another read of the same disk numbers its folders its own way")
        XCTAssertNil(SmallFileCatalogue.load(volume: "Test", for: tree, in: caches), "the newer catalogue is for the newer map")
        XCTAssertNotNil(SmallFileCatalogue.load(volume: "Test", for: other, in: caches))
        // What the first one mapped is still there to search, until it's let go of.
        XCTAssertEqual(try search("notes", catalogue, tree).count, 12)
    }

    func testAStoppedSearchSaysSo() throws {
        let (tree, catalogue) = try fullRead()
        let stop = StopFlag()
        stop.set()
        XCTAssertNil(catalogue.search("notes", in: tree, stop: stop))
    }

    func testAnAbandonedScanLeavesTheLastCatalogue() throws {
        let (tree, _) = try fullRead()
        let writer = try XCTUnwrap(SmallFileWriter(volume: "Test", refreshing: nil, in: caches))
        writer.abandon()
        XCTAssertNotNil(SmallFileCatalogue.load(volume: "Test", for: tree, in: caches))
        let left = try FileManager.default.contentsOfDirectory(atPath: caches.path)
        XCTAssertEqual(Set(left), ["small-Test.names", "small-Test.index"])
    }

    func testRemovingTakesEveryDisksCatalogue() throws {
        _ = try fullRead()
        SmallFiles.removeAll(in: caches)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: caches.path), [])
    }

    // MARK: Refreshing

    /// Everything as if it was made days ago, so a refresh copies it rather than reading it for being new.
    private func ageEverything() {
        let old = Int(Date().timeIntervalSince1970) - 3 * 86_400
        for path in (FileManager.default.subpaths(atPath: root) ?? []).map({ root + "/" + $0 }) {
            var list = attrlist()
            list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            list.commonattr = attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ADDEDTIME)
            var times = [timespec](repeating: timespec(tv_sec: old, tv_nsec: 0), count: 2)
            _ = times.withUnsafeMutableBytes { setattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) }
        }
        Thread.sleep(forTimeInterval: 1.1)
    }

    /// A map and its catalogue, the changes, then a refresh of both, as the app does it.
    private func refresh(newNames: Bool = false, after change: () throws -> Void) throws -> (DiskTree, SmallFileCatalogue, DiskScan) {
        ageEverything()
        let (map, base) = try fullRead(journal: true)
        let place = try XCTUnwrap(map.journal)
        let watcher = try XCTUnwrap(ChangeJournal.Watcher(from: place, roots: ChangeJournal.roots(of: map)))
        XCTAssertTrue(watcher.waitForHistory(timeout: 10))
        try change()
        Thread.sleep(forTimeInterval: 1)
        let taken = try XCTUnwrap(watcher.take(from: place))
        watcher.stop()
        let scan = newScan()
        XCTAssertTrue(scan.refresh(from: map, changes: taken.changes, place: taken.next))
        // Names that can't be added to: the map's catalogue still has them mapped, so its blocks are copied from there.
        if newNames { try FileManager.default.removeItem(at: SmallFiles.namesURL("Test", in: caches)) }
        let writer = try XCTUnwrap(SmallFileWriter(volume: "Test", refreshing: base, in: caches))
        scan.scanner.smallFiles = writer
        scan.run(mode: .full, threads: 4)
        XCTAssertFalse(scan.surprised)
        return (scan.tree, try XCTUnwrap(writer.finish(scan.tree)), scan)
    }

    func testARefreshFindsWhatReadingEverythingFinds() throws {
        let fm = FileManager.default
        let names = SmallFiles.namesURL("Test", in: caches).path
        var before = 0
        let (tree, catalogue, scan) = try refresh {
            before = (try? fm.attributesOfItem(atPath: names)[.size] as? Int) ?? 0
            try write("folder-1/fresh-note.txt", bytes: 4096)
            try fm.removeItem(atPath: root + "/folder-3")
            try fm.moveItem(atPath: root + "/folder-4", toPath: root + "/folder-4-renamed")
            try write("folder-7/inner/deeper/Notes-7.md", bytes: 100 * 1024)
        }
        XCTAssertLessThan(scan.foldersToRead, tree.count / 2, "most of the map was copied")
        let after = (try? fm.attributesOfItem(atPath: names)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(after, before, "the folders read again were added to the names")
        XCTAssertLessThan(after, 2 * before, "and the rest kept theirs")
        let refreshed = listed(try search(".", catalogue, tree), tree)
        XCTAssertEqual(refreshed, smallOnDisk())
        XCTAssertEqual(Int(catalogue.files), refreshed.count, "the folders it kept are counted too")
        XCTAssertEqual(refreshed[root + "/folder-7/inner/deeper/Notes-7.md"], 100 * 1024)
        XCTAssertNotNil(refreshed[root + "/folder-4-renamed/small-4.txt"])
        let (read, full) = try fullRead()
        XCTAssertEqual(listed(try search(".", full, read), read), refreshed)
    }

    func testARefreshThatStartsNewNamesCopiesTheBlocksItKeeps() throws {
        let (tree, catalogue, _) = try refresh(newNames: true) {
            try write("folder-2/another.txt", bytes: 8192)
            try FileManager.default.removeItem(atPath: root + "/folder-5/small-5.txt")
        }
        let refreshed = listed(try search(".", catalogue, tree), tree)
        XCTAssertEqual(refreshed, smallOnDisk())
        XCTAssertEqual(Int(catalogue.files), refreshed.count)
        let (read, full) = try fullRead()
        XCTAssertEqual(listed(try search(".", full, read), read), refreshed)
    }

    func testAFolderReadAgainWithNothingNewKeepsItsBlock() throws {
        // A folder with linked files in it is read again by every refresh.
        try write("linked/one.txt", bytes: 4096)
        try FileManager.default.linkItem(atPath: root + "/linked/one.txt", toPath: root + "/linked/two.txt")
        let names = SmallFiles.namesURL("Test", in: caches).path
        var before = 0
        let (tree, catalogue, _) = try refresh {
            before = (try? FileManager.default.attributesOfItem(atPath: names)[.size] as? Int) ?? 0
            try write("folder-1/new.txt", bytes: 4096)
        }
        let after = (try? FileManager.default.attributesOfItem(atPath: names)[.size] as? Int) ?? 0
        // folder-1's new block: its two names and their sizes, and nothing for the linked folder.
        XCTAssertEqual(after - before, (8 + 2 * 2 + "small-1.txt".utf8.count + 1 + "new.txt".utf8.count + 1 + 7) & ~7)
        XCTAssertEqual(try search("two.txt", catalogue, tree).count, 1)
        XCTAssertEqual(listed(try search(".", catalogue, tree), tree), smallOnDisk())
    }
}
