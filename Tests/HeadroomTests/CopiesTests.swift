import Darwin
import XCTest
@testable import Headroom

/// Copies on a real little folder: real duplicates, files that only nearly are, a hard link, an APFS clone and aliases, read by
/// the real scan and the real duplicate search.
final class CopiesTests: XCTestCase {
    private var root = ""
    private let megabyte = 1 << 20
    private var original = Data()

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("headroom-copies-" + UUID().uuidString)
        root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        original = Data(count: 3 * megabyte)
        original.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, 3 * megabyte) }
        try write("films/a.bin", original)
        try write("Downloads/a copy.bin", original)
        try write("backup/old/a.bin", original)
        // The same size, and only one byte different: at the start, in the middle, at the very end.
        for (name, at) in [("first", 0), ("middle", 3 * megabyte / 2), ("last", 3 * megabyte - 1)] {
            var near = original
            near[at] ^= 0xFF
            try write("near/\(name).bin", near)
        }
        try write("other/longer.bin", original + Data([1]))
        // A hard link and a clone, each of a file of its own: neither is a duplicate, since neither takes room twice.
        try write("music/h.bin", random(3 * megabyte))
        try FileManager.default.createDirectory(atPath: root + "/links", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: root + "/music/h.bin", toPath: root + "/links/h-hard.bin")
        try write("photos/c.bin", random(3 * megabyte))
        try FileManager.default.createDirectory(atPath: root + "/clones", withIntermediateDirectories: true)
        XCTAssertEqual(clonefile(root + "/photos/c.bin", root + "/clones/c-clone.bin", 0), 0, "the temporary folder is on APFS")
        try FileManager.default.createDirectory(atPath: root + "/aliases", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/aliases/to-a", withDestinationPath: "../films/a.bin")
        try FileManager.default.createSymbolicLink(atPath: root + "/aliases/to-films", withDestinationPath: root + "/films")
        try FileManager.default.createSymbolicLink(atPath: root + "/aliases/gone", withDestinationPath: "../nowhere/b.bin")
        // Beside what it points to, which says nothing about where room went.
        try FileManager.default.createSymbolicLink(atPath: root + "/films/a-next", withDestinationPath: "a.bin")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func random(_ bytes: Int) -> Data {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        return data
    }

    private func write(_ path: String, _ data: Data) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: full))
    }

    private func scanned() -> (tree: DiskTree, rules: RuleBook) {
        let facts = VolumeFacts(name: "Test", mountPath: root, capacity: 1 << 40, free: 1 << 39, isBoot: false)
        let rules = RuleBook(homePath: NSHomeDirectory())
        let scan = DiskScan(facts: facts, rules: rules, fullAccess: false)
        let done = expectation(description: "the scan finishes")
        Thread.detachNewThread {
            scan.run(mode: .full, threads: 2)
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        return (scan.tree, rules)
    }

    private func node(_ tree: DiskTree, _ path: String) -> UInt32 {
        guard let id = tree.find(path: root + "/" + path) else {
            XCTFail("no node for \(path)")
            return 0
        }
        return id
    }

    private func duplicates(_ tree: DiskTree, _ rules: RuleBook) -> [Duplicates.Found] {
        let work = Duplicates.work(in: tree, rules: rules)
        let progress = Duplicates.Progress(groupsTotal: work.count)
        let lock = NSLock()
        nonisolated(unsafe) var found: [Duplicates.Found] = []
        Duplicates.find(work, threads: 3, stop: LockedFlag(), progress: progress) { _, sets in
            lock.lock()
            found += sets
            lock.unlock()
        }
        return found
    }

    func testFindsTheRealCopiesAndNothingElse() {
        let (tree, rules) = scanned()
        let found = duplicates(tree, rules)
        XCTAssertEqual(found.count, 1, "one set of real copies")
        let copies = Set(["films/a.bin", "Downloads/a copy.bin", "backup/old/a.bin"].map { node(tree, $0) })
        XCTAssertEqual(Set(found.first?.nodes ?? []), copies, "the three copies, without the hard link, the clone or the near ones")
        XCTAssertEqual(found.first?.size, UInt64(3 * megabyte))
    }

    func testCountsAliasesAndReadsWhereTheyPoint() {
        let (tree, rules) = scanned()
        let anchor = tree.anchors.first!.id
        XCTAssertEqual(tree.statRow(anchor)[DiskTree.statSymlinks], 4, "every link on the disk is counted, up the tree")
        let aliases = Aliases.find(in: tree, rules: rules, stop: LockedFlag())
        XCTAssertEqual(aliases.count, 3, "the one beside its own file says nothing")
        let byName = Dictionary(uniqueKeysWithValues: aliases.map { ($0.name, $0) })
        XCTAssertEqual(byName["to-a"]?.node, node(tree, "films/a.bin"))
        XCTAssertEqual(byName["to-films"]?.node, node(tree, "films"))
        XCTAssertEqual(byName["gone"]?.state, .broken)
        XCTAssertEqual(byName["gone"]?.target, root + "/nowhere/b.bin")
    }

    func testTheMapHasEachRelation() {
        let (tree, rules) = scanned()
        let map = CopiesMap.build(tree: tree, duplicates: duplicates(tree, rules), aliases: Aliases.find(in: tree, rules: rules, stop: LockedFlag()),
                                  duplicatesDone: true)
        let kinds = Dictionary(grouping: map.groups, by: \.kind)
        XCTAssertEqual(kinds[.duplicate]?.count, 1)
        XCTAssertEqual(kinds[.sameFile]?.count, 1, "the hard link")
        XCTAssertEqual(kinds[.sharedCopy]?.count, 1, "the clone")
        XCTAssertEqual(kinds[.alias]?.count, 2)
        XCTAssertEqual(kinds[.broken]?.count, 1)
        let dup = kinds[.duplicate]![0]
        XCTAssertEqual(dup.home, node(tree, "films/a.bin"), "the oldest, nearest the top, and not in Downloads")
        XCTAssertFalse(dup.others.contains(dup.home))
        XCTAssertNotEqual(tree.path(dup.home)?.contains("/Downloads/"), true, "the copy in Downloads isn't the one kept")
        XCTAssertEqual(map.back, dup.back)
        XCTAssertEqual(dup.back, dup.others.reduce(UInt64(0)) { $0 + tree.nodes[Int($1)].bytes })
        // The ring: every copy, the one that stays too, wears its set's colour, so the same colour is the same file.
        for copy in [dup.home] + dup.others {
            let lab = map.lab(copy, total: tree.totals[Int(copy)])
            XCTAssertEqual(lab.l, dup.colour.l, accuracy: 0.001)
            XCTAssertEqual(lab.a, dup.colour.a, accuracy: 0.001)
            XCTAssertEqual(lab.b, dup.colour.b, accuracy: 0.001)
        }
    }

    func testPiecesCoverEveryByteOnce() {
        let sizes: [Int64] = [1, 100, 16 << 10, (16 << 10) + 1, 1 << 20, 3 << 20, 50_000_123, 4_000_000_000]
        for size in sizes {
            var covered: Int64 = 0
            var seen: [(Int64, Int64)] = []
            for piece in Duplicates.pieces(of: size) {
                XCTAssertGreaterThan(piece.length, 0)
                XCTAssertLessThanOrEqual(piece.length, 4 << 20)
                seen.append((piece.offset, piece.offset + Int64(piece.length)))
                covered += Int64(piece.length)
            }
            XCTAssertEqual(covered, size, "every byte of \(size)")
            let sorted = seen.sorted { $0.0 < $1.0 }
            for (a, b) in zip(sorted, sorted.dropFirst()) { XCTAssertEqual(a.1, b.0, "no gaps and no overlaps in \(size)") }
        }
    }

    func testRemembersOnlyWhatHasNotChanged() {
        let memory = DuplicateMemory(file: nil)
        let files = [Duplicates.File(node: 5, path: "/a", modTime: 10), Duplicates.File(node: 6, path: "/b", modTime: 10),
                     Duplicates.File(node: 7, path: "/c", modTime: 12)]
        let work = Duplicates.Work(bytes: 1 << 20, files: files)
        XCTAssertNil(memory.recall(work), "nothing known yet")
        memory.note(work, found: [Duplicates.Found(size: 1 << 20, nodes: [5, 6])])
        XCTAssertEqual(memory.recall(work), [Duplicates.Found(size: 1 << 20, nodes: [5, 6])])
        var touched = work
        touched.files[2].modTime = 13
        XCTAssertNil(memory.recall(touched), "a file that changed means reading the group again")
        var more = work
        more.files.append(Duplicates.File(node: 8, path: "/d", modTime: 10))
        XCTAssertNil(memory.recall(more), "so does a new file of the same size")
    }

    func testAliasPathsAreMadeWhole() {
        XCTAssertEqual(Aliases.whole("../b/c", from: "/x/y"), "/x/b/c")
        XCTAssertEqual(Aliases.whole("./c", from: "/x/y"), "/x/y/c")
        XCTAssertEqual(Aliases.whole("/abs/./p/../q", from: "/x"), "/abs/q")
        XCTAssertEqual(Aliases.whole("../../../..", from: "/x"), "/")
    }

    func testKeepsTheCopyThatIsntInDownloads() {
        let disk = FakeDisk()
        let inDownloads = disk.file("/Volumes/Fake/Downloads/film.mov", 2_000_000_000, kind: .video, modTime: 100)
        let inFilms = disk.file("/Volumes/Fake/Films/film.mov", 2_000_000_000, kind: .video, modTime: 200)
        disk.finish()
        XCTAssertEqual(CopiesMap.keeper(of: [inDownloads, inFilms], in: disk.tree), inFilms, "Downloads loses, however old")
        let map = CopiesMap.build(tree: disk.tree, duplicates: [Duplicates.Found(size: 2_000_000_000, nodes: [inDownloads, inFilms])],
                                  aliases: [], duplicatesDone: true)
        XCTAssertEqual(map.groups.first?.others, [inDownloads])
        XCTAssertEqual(map.back, 2_000_000_000)
    }
}

/// The ring in Copies: every copy of a set wears the set's colour, a folder that's mostly one set wears it too, the rest is quiet.
final class CopiesRingTests: XCTestCase {
    func testCopiesWearTheirSetsColour() {
        let disk = FakeDisk()
        var sets: [Duplicates.Found] = []
        for i in 0..<40 {
            // Exported months after they were taken: older by days, which is what counts.
            let kept = disk.file("/Volumes/Fake/Pictures/Holiday/IMG_\(i).jpg", 4_000_000 + UInt64(i) * 4096, kind: .image, modTime: 86_400 * 10)
            let extra = disk.file("/Volumes/Fake/Pictures/Export/IMG_\(i).jpg", 4_000_000 + UInt64(i) * 4096, kind: .image, modTime: 86_400 * 200)
            sets.append(Duplicates.Found(size: 4_000_000, nodes: [kept, extra]))
        }
        for i in 40..<120 { disk.file("/Volumes/Fake/Pictures/Holiday/IMG_\(i).jpg", 4_000_000 + UInt64(i) * 4096, kind: .image, modTime: 86_400 * 10) }
        disk.finish()
        let tree = disk.tree
        let map = CopiesMap.build(tree: tree, duplicates: sets, aliases: [], duplicatesDone: true)
        let holiday = disk.node("/Volumes/Fake/Pictures/Holiday"), export = disk.node("/Volumes/Fake/Pictures/Export")
        for g in map.groups { for k in g.keepers { XCTAssertTrue(tree.isInside(k, holiday), "the older copy, in Holiday, stays") } }
        let set = map.groups[0]
        XCTAssertEqual(map.groups.filter { $0.kind == .duplicate }.count, 1, "forty copies in the same two folders are one row")
        let e = map.lab(export, total: tree.totals[Int(export)]), h = map.lab(holiday, total: tree.totals[Int(holiday)])
        XCTAssertEqual(e.l, set.colour.l, accuracy: 0.001, "Export is all copies: it wears the set's colour")
        XCTAssertEqual(e.chroma, set.colour.chroma, accuracy: 0.001)
        XCTAssertGreaterThan(h.chroma, Palette.quiet.chroma + 0.02, "a third of Holiday is the set, so it takes on some of its colour")
        XCTAssertLessThan(h.chroma, e.chroma, "less than the folder that's all copies")
        XCTAssertEqual(atan2(h.b, h.a), atan2(e.b, e.a), accuracy: 0.35, "the same hue, so the two folders read as one set")
        let kept = set.keepers[0]
        XCTAssertEqual(map.lab(kept, total: tree.totals[Int(kept)]).chroma, set.colour.chroma, accuracy: 0.001, "the photo that stays wears it too")
        XCTAssertEqual(map.set(of: export)?.id, set.id, "pointing at Export lights the set")

    }
}

final class CopyNamesTests: XCTestCase {
    func testNamesThatSayTheyreCopies() {
        for name in ["film copy.mov", "film copy 2.mov", "film (1).mov", "Installer (12).dmg", "notes 2.txt"] {
            XCTAssertTrue(CopiesMap.soundsLikeACopy(name), name)
        }
        for name in ["Trip 2025.mov", "hero-1.psd", "IMG_0005.jpg", "copy.txt", "Room 12.jpg", "film.mov"] {
            XCTAssertFalse(CopiesMap.soundsLikeACopy(name), name)
        }
        XCTAssertTrue(CopiesMap.soundsLikeACopy("Photos copy", folder: true))
        XCTAssertTrue(CopiesMap.soundsLikeACopy("Photos (1)", folder: true))
        XCTAssertFalse(CopiesMap.soundsLikeACopy("Season 2", folder: true), "a folder's number is a name of its own")
        XCTAssertFalse(CopiesMap.soundsLikeACopy("v2.0 final", folder: true))
    }

    /// Two downloads of the same installer, side by side: the name decides, though the copy is older.
    func testTheOneNamedLikeACopyGoesEvenInTheSameFolder() {
        let disk = FakeDisk()
        let copy = disk.file("/Volumes/Fake/Downloads/Installer (1).dmg", 262_000_000, kind: .archive, modTime: 86_400 * 10)
        let first = disk.file("/Volumes/Fake/Downloads/Installer.dmg", 262_000_000, kind: .archive, modTime: 86_400 * 20)
        disk.finish()
        XCTAssertEqual(CopiesMap.keeper(of: [copy, first], in: disk.tree), first)
        let map = CopiesMap.build(tree: disk.tree, duplicates: [Duplicates.Found(size: 262_000_000, nodes: [copy, first])], aliases: [], duplicatesDone: true)
        XCTAssertEqual(map.groups.first?.keepers, [first])
        XCTAssertEqual(map.groups.first?.extras, [copy])
    }

    /// A Finder copy has the original's date, so only its name tells them apart; the path alone would keep `film copy.mov`.
    func testAFinderCopyGoesThoughItHasTheSameDate() {
        let disk = FakeDisk()
        let copy = disk.file("/Volumes/Fake/Films/film copy.mov", 900_000_000, kind: .video, modTime: 500)
        let film = disk.file("/Volumes/Fake/Films/film.mov", 900_000_000, kind: .video, modTime: 500)
        disk.finish()
        XCTAssertEqual(CopiesMap.keeper(of: [copy, film], in: disk.tree), film)
    }

    /// A folder the Finder named as a copy, or one whose copies mostly are, isn't where they stay, even holding more files.
    func testAFolderNamedLikeACopyIsntWhereTheyStay() {
        let disk = FakeDisk()
        let a = disk.file("/Volumes/Fake/Films/trip.mov", 900_000_000, kind: .video, modTime: 500)
        let b = disk.file("/Volumes/Fake/Films copy/trip.mov", 900_000_000, kind: .video, modTime: 500)
        let c = disk.file("/Volumes/Fake/Edits/cut.mov", 700_000_000, kind: .video, modTime: 500)
        let d = disk.file("/Volumes/Fake/Archive/cut copy.mov", 700_000_000, kind: .video, modTime: 500)
        for i in 0..<5 {
            disk.file("/Volumes/Fake/Films copy/other \(i).mov", 2_000_000 + UInt64(i), kind: .video, modTime: 500)
            disk.file("/Volumes/Fake/Archive/other \(i).mov", 2_000_000 + UInt64(i), kind: .video, modTime: 500)
        }
        disk.finish()
        let map = CopiesMap.build(tree: disk.tree, duplicates: [Duplicates.Found(size: 900_000_000, nodes: [a, b]), Duplicates.Found(size: 700_000_000, nodes: [c, d])],
                                  aliases: [], duplicatesDone: true)
        XCTAssertTrue(map.groups.contains { $0.keepers == [a] && $0.extras == [b] }, "Films stays, not Films copy")
        XCTAssertTrue(map.groups.contains { $0.keepers == [c] && $0.extras == [d] }, "cut.mov stays, not cut copy.mov in the fuller folder")
    }

    /// One stray copy among a folder of originals doesn't send them all the other way.
    func testOneStrayCopyDoesntMoveTheWholeFolder() {
        let disk = FakeDisk()
        var sets: [Duplicates.Found] = []
        for i in 0..<6 {
            let size = 4_000_000 + UInt64(i) * 4096
            let kept = disk.file("/Volumes/Fake/Pictures/Holiday/IMG_\(i).jpg", size, kind: .image, modTime: 86_400 * 10)
            let extra = disk.file("/Volumes/Fake/Pictures/Export/IMG_\(i).jpg", size, kind: .image, modTime: 86_400 * 200)
            var nodes = [kept, extra]
            if i == 0 { nodes.append(disk.file("/Volumes/Fake/Pictures/Holiday/IMG_0 copy.jpg", size, kind: .image, modTime: 86_400 * 10)) }
            sets.append(Duplicates.Found(size: size, nodes: nodes))
        }
        disk.finish()
        let map = CopiesMap.build(tree: disk.tree, duplicates: sets, aliases: [], duplicatesDone: true)
        let holiday = disk.node("/Volumes/Fake/Pictures/Holiday")
        for g in map.groups { for k in g.keepers { XCTAssertEqual(disk.tree.nodes[Int(k)].parent, holiday, "the older Holiday copies stay") } }
        XCTAssertTrue(map.groups.contains { $0.extras.contains(disk.node("/Volumes/Fake/Pictures/Holiday/IMG_0 copy.jpg")) }, "the stray copy goes")
    }
}

/// How fast duplicates are found in files the file cache doesn't hold: `HEADROOM_BENCH=/a/folder swift test --filter
/// DuplicatesBench`. It writes about 7 GB there, past the cache, so the search reads from the disk itself, and removes it after.
final class DuplicatesBench: XCTestCase {
    private let mb = 1 << 20

    private func write(_ path: String, _ data: UnsafeRawBufferPointer, times: Int = 1, tweakLast: UInt8? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        for t in 0..<times {
            let full = times == 1 ? path : path + " \(t)"
            let fd = open(full, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            _ = fcntl(fd, F_NOCACHE, 1)
            var at = 0
            while at < data.count {
                let n = min(8 << 20, data.count - at)
                at += Darwin.write(fd, data.baseAddress! + at, n)
            }
            if let tweakLast {
                var byte = tweakLast
                _ = pwrite(fd, &byte, 1, off_t(data.count - 1))
            }
            close(fd)
        }
    }

    func testSpeed() throws {
        guard let base = ProcessInfo.processInfo.environment["HEADROOM_BENCH"] else { throw XCTSkip("set HEADROOM_BENCH to a folder on the disk to measure") }
        let root = URL(fileURLWithPath: base).resolvingSymlinksInPath().path + "/headroom-bench-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        func random(_ bytes: Int) -> UnsafeMutableRawBufferPointer {
            let b = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes, alignment: 16384)
            arc4random_buf(b.baseAddress!, bytes)
            return b
        }
        let made = Date()
        let film = random(1024 * mb)
        try write(root + "/Films/trip.mov", UnsafeRawBufferPointer(film))
        try write(root + "/Exports/trip final.mov", UnsafeRawBufferPointer(film))
        try write(root + "/Downloads/trip.mov", UnsafeRawBufferPointer(film))
        film.deallocate()
        let installer = random(512 * mb)
        try write(root + "/Downloads/Installer.dmg", UnsafeRawBufferPointer(installer))
        try write(root + "/Backup/Installer.dmg", UnsafeRawBufferPointer(installer))
        installer.deallocate()
        // 450 photos of exactly one size: 300 different ones, and copies of 150 of them, all in one group to sort out.
        for i in 0..<300 {
            let photo = random(4 * mb)
            try write(root + "/Photos/IMG_\(i).jpg", UnsafeRawBufferPointer(photo))
            if i < 150 { try write(root + "/Export/IMG_\(i).jpg", UnsafeRawBufferPointer(photo)) }
            photo.deallocate()
        }
        // Ten files that are the same but for their last byte: the end is read second, so each costs two small reads.
        let near = random(128 * mb)
        for i in 0..<10 { try write(root + "/Renders/take-\(i).mov", UnsafeRawBufferPointer(near), tweakLast: UInt8(i)) }
        near.deallocate()
        print(String(format: "bench: wrote the files in %.1f s", Date().timeIntervalSince(made)))

        let facts = VolumeFacts(name: "Bench", mountPath: root, capacity: 1 << 40, free: 1 << 39, isBoot: false)
        let rules = RuleBook(homePath: NSHomeDirectory())
        let scan = DiskScan(facts: facts, rules: rules, fullAccess: false)
        let done = expectation(description: "the scan finishes")
        Thread.detachNewThread {
            scan.run(mode: .full, threads: 4)
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        let tree = scan.tree

        let started = Date()
        let work = Duplicates.work(in: tree, rules: rules)
        let progress = Duplicates.Progress(groupsTotal: work.count)
        let memory = DuplicateMemory(file: nil)
        let lock = NSLock()
        nonisolated(unsafe) var found: [Duplicates.Found] = []
        Duplicates.find(work, threads: AppModel.copyThreadCount, stop: LockedFlag(), progress: progress) { at, sets in
            memory.note(work[at], found: sets)
            lock.lock()
            found += sets
            lock.unlock()
        }
        let seconds = Date().timeIntervalSince(started)
        let read = progress.bytesRead.load(ordering: .relaxed)
        let back = found.reduce(UInt64(0)) { $0 + $1.size * UInt64($1.nodes.count - 1) }
        print(String(format: "bench: %d sets, %.2f GB back; read %.2f GB of %d candidate files in %.2f s, %.2f GB/s, %d threads",
                     found.count, Double(back) / 1e9, Double(read) / 1e9, work.reduce(0) { $0 + $1.files.count }, seconds,
                     Double(read) / 1e9 / seconds, AppModel.copyThreadCount))
        XCTAssertEqual(found.count, 152, "the film, the installer and 150 photos")

        let again = Date()
        let recalled = work.compactMap { memory.recall($0) }.flatMap { $0 }
        print(String(format: "bench: the next time, %d sets remembered in %.3f s", recalled.count, Date().timeIntervalSince(again)))
        XCTAssertEqual(recalled.count, found.count)
    }
}

/// Linking copies: every byte is compared first, the copy goes to the Trash on record, and Undo puts it back as its own file.
/// The link itself only works on files Headroom may move, which are in your home folder or on other disks, so these use a
/// folder in your caches, and a pretend Trash beside it, so nothing reaches your real one.
final class LinkingTests: XCTestCase {
    private var root = ""
    private var limit: String?

    override func setUpWithError() throws {
        root = NSHomeDirectory() + "/Library/Caches/headroom-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/Trash", withIntermediateDirectories: true)
        // Only this folder may be touched, whatever another test left the limit at.
        limit = Cleaner.onlyInside
        Cleaner.onlyInside = root
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        Cleaner.onlyInside = limit
    }

    private func write(_ name: String, _ data: Data) throws -> String {
        let path = root + "/" + name
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func random(_ bytes: Int) -> Data {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        return data
    }

    /// Moves into the pretend Trash, as the real one would.
    private func pretendTrash(_ path: String) throws -> (place: String, identity: String?) {
        let place = root + "/Trash/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: place)
        return (place, nil)
    }

    func testEveryByteIsCompared() throws {
        let data = random(9 << 20)
        let a = try write("a.bin", data), b = try write("b.bin", data)
        var changed = data
        changed[changed.count - 1] ^= 1
        let c = try write("c.bin", changed), d = try write("d.bin", data + Data([0]))
        XCTAssertTrue(try Cleaner.sameBytes(a, b))
        XCTAssertFalse(try Cleaner.sameBytes(a, c), "one byte at the very end")
        XCTAssertFalse(try Cleaner.sameBytes(a, d), "one byte longer")
    }

    func testLinkingMakesOneFileAndUndoMakesTwo() throws {
        let data = random(3 << 20)
        let kept = try write("Films/trip.mov", data), copy = try write("Downloads/trip.mov", data)
        let moved = try Cleaner.link(copy, to: kept, trashing: pretendTrash)
        XCTAssertTrue(Cleaner.isSameFile(copy, kept), "the copy's path is now the same file as the one that stays")
        XCTAssertTrue(try Cleaner.sameBytes(moved.place, kept), "the copy itself waits in the Trash, whole")

        var thing = CleanedThing(itemID: "linked:" + copy, title: "trip.mov", original: copy, inTrash: moved.place, bytes: 0)
        thing.linkedTo = kept
        try Cleaner.putBack(thing)
        XCTAssertFalse(Cleaner.isSameFile(copy, kept), "its own file again")
        XCTAssertTrue(try Cleaner.sameBytes(copy, kept))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.place))
    }

    func testFilesThatDifferAreNeverLinked() throws {
        let data = random(2 << 20)
        var other = data
        other[1 << 20] ^= 1
        let kept = try write("a.bin", data), copy = try write("b.bin", other)
        XCTAssertThrowsError(try Cleaner.link(copy, to: kept, trashing: pretendTrash))
        XCTAssertFalse(Cleaner.isSameFile(copy, kept))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copy)), other, "left exactly as it was")
    }

    func testASymlinkTakesTheCopysPlaceAndUndoTakesItAway() throws {
        let data = random(2 << 20)
        let kept = try write("Films/trip.mov", data), copy = try write("Downloads/trip.mov", data)
        let moved = try Cleaner.replaceCopy(copy, of: kept, with: .symlink, trashing: pretendTrash)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copy), kept, "the copy's path points to the one kept")
        XCTAssertTrue(Cleaner.isLink(copy, to: kept))
        var thing = CleanedThing(itemID: "symlink:" + copy, title: "trip.mov", original: copy, inTrash: moved.place, bytes: 0)
        thing.linkedTo = kept
        try Cleaner.putBack(thing)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: copy), "a file again, not a symlink")
        XCTAssertTrue(try Cleaner.sameBytes(copy, kept))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.place))
    }

    func testDeleteTakesOnlyAFileThatIsStillACopy() throws {
        let data = random(2 << 20)
        var changed = data
        changed[7] ^= 1
        let kept = try write("a.bin", data), copy = try write("b.bin", data), edited = try write("c.bin", changed)
        let moved = try Cleaner.replaceCopy(copy, of: kept, with: .nothing, trashing: pretendTrash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy), "the copy is in the Trash")
        XCTAssertTrue(try Cleaner.sameBytes(moved.place, kept))
        XCTAssertThrowsError(try Cleaner.replaceCopy(edited, of: kept, with: .nothing, trashing: pretendTrash), "changed since it was compared")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: edited)), changed, "left as it was")
        try Cleaner.putBack(CleanedThing(itemID: "delete:" + copy, title: "b.bin", original: copy, inTrash: moved.place, bytes: 0))
        XCTAssertTrue(try Cleaner.sameBytes(copy, kept), "Undo puts it back")
    }

    func testUndoNeverRemovesWhatElseTookTheName() throws {
        let data = random(1 << 20)
        let kept = try write("a.bin", data)
        let trashed = try write("Trash/b.bin", data)
        let somethingNew = try write("b.bin", Data("something new".utf8))
        var thing = CleanedThing(itemID: "x", title: "b.bin", original: somethingNew, inTrash: trashed, bytes: 0)
        thing.linkedTo = kept
        XCTAssertThrowsError(try Cleaner.putBack(thing), "it isn't the link any more, so it stays")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: somethingNew)), Data("something new".utf8))
    }

    func testTheCopyYouPickStays() {
        let disk = FakeDisk()
        let films = disk.file("/Volumes/Fake/Films/trip.mov", 2_000_000_000, kind: .video, modTime: 86_400 * 10)
        let exports = disk.file("/Volumes/Fake/Exports/trip.mov", 2_000_000_000, kind: .video, modTime: 86_400 * 200)
        disk.finish()
        let set = [Duplicates.Found(size: 2_000_000_000, nodes: [films, exports])]
        XCTAssertEqual(CopiesMap.build(tree: disk.tree, duplicates: set, aliases: [], duplicatesDone: true).groups.first?.home, films, "the older one, by the rules")
        let picked = CopiesMap.build(tree: disk.tree, duplicates: set, aliases: [], duplicatesDone: true, kept: ["/Volumes/Fake/Exports/trip.mov"])
        XCTAssertEqual(picked.groups.first?.home, exports, "the one you picked")
        XCTAssertEqual(picked.groups.first?.extras, [films])
    }
}

final class CopyColourTests: XCTestCase {
    func testASetKeepsItsColourWhenAnotherGoes() {
        let disk = FakeDisk()
        let a1 = disk.file("/Volumes/Fake/Films/a.mov", 3_000_000_000, kind: .video), a2 = disk.file("/Volumes/Fake/Downloads/a.mov", 3_000_000_000, kind: .video)
        let b1 = disk.file("/Volumes/Fake/Films/b.mov", 2_000_000_000, kind: .video), b2 = disk.file("/Volumes/Fake/Downloads/b.mov", 2_000_000_000, kind: .video)
        disk.finish()
        let both = [Duplicates.Found(size: 3_000_000_000, nodes: [a1, a2]), Duplicates.Found(size: 2_000_000_000, nodes: [b1, b2])]
        let first = CopiesMap.build(tree: disk.tree, duplicates: both, aliases: [], duplicatesDone: true)
        let bColour = first.groups.first { $0.keepers.contains(b1) }!.colour
        let then = CopiesMap.build(tree: disk.tree, duplicates: [both[1]], aliases: [], duplicatesDone: true, colours: first.colourOf)
        let b = then.groups.first { $0.keepers.contains(b1) }!.colour
        XCTAssertEqual(b.l, bColour.l, accuracy: 0.0001)
        XCTAssertEqual(b.a, bColour.a, accuracy: 0.0001)
        XCTAssertEqual(b.b, bColour.b, accuracy: 0.0001, "the film that's left keeps its colour when the bigger one goes")
    }
}

final class KeeperTieTests: XCTestCase {
    func testATieIsSettledByThePathNotTheScanOrder() {
        for order in [["b", "a", "c"], ["c", "b", "a"], ["a", "c", "b"]] {
            let disk = FakeDisk()
            let nodes = order.map { disk.file("/Volumes/Fake/Projects/\($0)/bin/esbuild", 10_000_000, kind: .app, modTime: 500) }
            disk.finish()
            let map = CopiesMap.build(tree: disk.tree, duplicates: [Duplicates.Found(size: 10_000_000, nodes: nodes.sorted())], aliases: [], duplicatesDone: true)
            XCTAssertEqual(disk.tree.path(map.groups[0].home), "/Volumes/Fake/Projects/a/bin/esbuild", "the same copy stays, found in any order")
        }
    }
}

final class CopyRowTests: XCTestCase {
    /// Best versions copied to one folder from two projects: one row for that folder, whatever the films are.
    func testCopiesInOneFolderAreOneRowWhereverTheirOriginalsAre() {
        let disk = FakeDisk()
        let size: UInt64 = 596_600_000
        let v23 = disk.file("/Volumes/Fake/Projects/eye/final/eye-v23.mp4", size, kind: .video, modTime: 86_400 * 10)
        let v23gold = disk.file("/Volumes/Fake/Desktop/GOLD versions/eye-v23.mp4", size, kind: .video, modTime: 86_400 * 40)
        let v25 = disk.file("/Volumes/Fake/Projects/eye/renders/eye-v25.mp4", size, kind: .video, modTime: 86_400 * 20)
        let v25gold = disk.file("/Volumes/Fake/Desktop/GOLD versions/eye-v25.mp4", size, kind: .video, modTime: 86_400 * 40)
        disk.finish()
        let map = CopiesMap.build(tree: disk.tree, duplicates: [Duplicates.Found(size: size, nodes: [v23, v23gold]), Duplicates.Found(size: size, nodes: [v25, v25gold])],
                                  aliases: [], duplicatesDone: true)
        XCTAssertEqual(map.groups.count, 1, "one row")
        let row = map.groups[0]
        XCTAssertEqual(row.title, "2 duplicates in GOLD versions")
        XCTAssertEqual(Set(row.extras), [v23gold, v25gold])
        XCTAssertEqual(Set(row.keepers), [v23, v25])
        XCTAssertEqual(Set(row.homes), [disk.node("/Volumes/Fake/Projects/eye/final"), disk.node("/Volumes/Fake/Projects/eye/renders")])
        // Keeping one of the GOLD copies instead decides for that film only.
        let kept = CopiesMap.build(tree: disk.tree, duplicates: [Duplicates.Found(size: size, nodes: [v23, v23gold]), Duplicates.Found(size: size, nodes: [v25, v25gold])],
                                   aliases: [], duplicatesDone: true, kept: ["/Volumes/Fake/Desktop/GOLD versions/eye-v23.mp4"])
        let v23row = kept.groups.first { $0.keepers.contains(v23gold) }
        XCTAssertEqual(v23row?.extras, [v23], "v23 now keeps its GOLD copy")
        XCTAssertTrue(kept.groups.contains { $0.keepers == [v25] && $0.extras == [v25gold] }, "v25 still keeps the one in renders")
    }

    /// One file with two extra copies and another with one, in the same folder: each copy goes with its own original, for the
    /// open row, Keep this one, the tick's note and Link.
    func testEachExtraCopyGoesWithItsOwnOriginal() {
        let disk = FakeDisk()
        let a = disk.file("/Volumes/Fake/Pictures/Holiday/a.jpg", 5_000_000, kind: .image, modTime: 86_400 * 10)
        let a1 = disk.file("/Volumes/Fake/Pictures/Export/a.jpg", 5_000_000, kind: .image, modTime: 86_400 * 50)
        let a2 = disk.file("/Volumes/Fake/Pictures/Export/a copy.jpg", 5_000_000, kind: .image, modTime: 86_400 * 50)
        let b = disk.file("/Volumes/Fake/Pictures/Holiday/b.jpg", 4_000_000, kind: .image, modTime: 86_400 * 10)
        let b1 = disk.file("/Volumes/Fake/Pictures/Export/b.jpg", 4_000_000, kind: .image, modTime: 86_400 * 50)
        disk.finish()
        let map = CopiesMap.build(tree: disk.tree, duplicates: [Duplicates.Found(size: 4_000_000, nodes: [b, b1]), Duplicates.Found(size: 5_000_000, nodes: [a, a1, a2])],
                                  aliases: [], duplicatesDone: true)
        XCTAssertEqual(map.groups.count, 1, "one row for Export")
        let row = map.groups[0]
        XCTAssertEqual(row.sets.map(\.keeper), [a, b], "the bigger first")
        XCTAssertEqual(row.sets.map { Set($0.extras) }, [[a1, a2], [b1]])
        XCTAssertEqual(row.keeper(of: a2), a)
        XCTAssertEqual(row.keeper(of: b1), b, "not a, as an even split would have it")
        XCTAssertEqual(row.keeper(of: b), b)
    }
}

final class CopyPlaceTests: XCTestCase {
    /// The same `media/audio` in two projects: each place keeps the folder where they part.
    func testPlacesThatWouldReadTheSameAreToldApart() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/dev/storyboard/boards/demo/media/audio/x.wav", 5_000_000, kind: .audio)
        disk.file("/Volumes/Fake/dev/storyboard/boards/eye/media/audio/x.wav", 5_000_000, kind: .audio)
        disk.finish()
        let folders = [disk.node("/Volumes/Fake/dev/storyboard/boards/demo/media/audio"), disk.node("/Volumes/Fake/dev/storyboard/boards/eye/media/audio")]
        XCTAssertEqual(CopiesMap.places(folders, in: disk.tree, short: true), ["…/demo/media/audio", "…/eye/media/audio"])
        XCTAssertEqual(CopiesMap.places(folders, in: disk.tree), ["dev/storyboard/…/demo/media/audio", "dev/storyboard/…/eye/media/audio"])
        XCTAssertEqual(CopiesMap.place(folders[0], in: disk.tree, short: true), "…/media/audio", "alone, its last two folders say it")
    }

    /// A row of one file says where the copy that stays is and where the other is, without being opened.
    func testARowSaysWhereEachCopyIs() throws {
        let disk = FakeDisk()
        let kept = disk.file("/Volumes/Fake/dev/shop/build/app/outputs/flutter-apk/app-debug.apk", 164_000_000, kind: .app, modTime: 500)
        let other = disk.file("/Volumes/Fake/dev/shop/build/app/outputs/apk/debug/app-debug.apk", 164_000_000, kind: .app, modTime: 500)
        let first = disk.file("/Volumes/Fake/Downloads/Installer.dmg", 262_000_000, kind: .archive, modTime: 500)
        let second = disk.file("/Volumes/Fake/Downloads/Installer (1).dmg", 262_000_000, kind: .archive, modTime: 500)
        disk.finish()
        let map = CopiesMap.build(tree: disk.tree, duplicates: [Duplicates.Found(size: 164_000_000, nodes: [kept, other]), Duplicates.Found(size: 262_000_000, nodes: [first, second])],
                                  aliases: [], duplicatesDone: true)
        let apk = try XCTUnwrap(map.groups.first { $0.keepers == [kept] })
        XCTAssertEqual(CopiesMap.summary(of: apk, in: disk.tree), "2 copies · …/outputs/flutter-apk, …/apk/debug")
        let dmg = try XCTUnwrap(map.groups.first { $0.keepers == [first] })
        XCTAssertEqual(CopiesMap.summary(of: dmg, in: disk.tree), "2 copies in Downloads")
    }
}
