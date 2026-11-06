import XCTest
@testable import Headroom

/// Real scans of a real little folder, on real threads. A scan that hangs fails here instead of in the app.
final class ScannerTests: XCTestCase {
    private var root = ""
    private let megabyte = 1 << 20

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("headroom-scan-" + UUID().uuidString)
        root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        for at in 0..<30 {
            try write("folder-\(at)/small.txt", bytes: 4096)
            try write("folder-\(at)/inner/deeper/small.txt", bytes: 4096)
        }
        try write("big/big.bin", bytes: 3 * megabyte)
        try write("torrent/placeholder.txt", bytes: 16)
        try FileManager.default.linkItem(atPath: root + "/big/big.bin", toPath: root + "/torrent/big-link.bin")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ path: String, bytes: Int) throws {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Random, so that nothing about the disk can make it smaller.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: URL(fileURLWithPath: full))
    }

    private func newScan() -> DiskScan {
        let facts = VolumeFacts(name: "Test", mountPath: root, capacity: 1 << 40, free: 1 << 39, isBoot: false)
        return DiskScan(facts: facts, rules: RuleBook(homePath: NSHomeDirectory()), fullAccess: false)
    }

    /// The scan on its own thread, with a limit: a hang is a failed test, not a stuck run.
    private func finishes(_ scan: DiskScan, mode: ScanMode, threads: Int, seconds: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let done = expectation(description: "the scan finishes")
        Thread.detachNewThread {
            scan.run(mode: mode, threads: threads)
            done.fulfill()
        }
        let result = XCTWaiter().wait(for: [done], timeout: seconds)
        if result != .completed { XCTFail("The scan didn't finish with \(threads) threads", file: file, line: line) }
        return result == .completed
    }

    private func files(in tree: DiskTree) -> UInt32 {
        tree.children(0).first { tree.path($0) == root } ?? 0
    }

    func testAScanFinishesWithAnyNumberOfThreads() {
        for threads in [1, 2, 8] {
            XCTAssertTrue(finishes(newScan(), mode: .full, threads: threads))
        }
    }

    func testAQuietScanFinishesToo() {
        XCTAssertTrue(finishes(newScan(), mode: .quiet, threads: 3))
    }

    func testAFirstLookFinishesToo() {
        XCTAssertTrue(finishes(newScan(), mode: .firstLook, threads: 4))
    }

    func testAScanStoppedHalfwayStillEnds() {
        let scan = newScan()
        scan.scanner.cancel()
        XCTAssertTrue(finishes(scan, mode: .full, threads: 4))
    }

    func testEveryFolderIsReadAndNothingCountsTwice() throws {
        let scan = newScan()
        XCTAssertTrue(finishes(scan, mode: .full, threads: 4))
        let tree = scan.tree
        XCTAssertEqual(scan.scanner.filesSoFar, 60 + 3, "Every file seen, the linked one once for each path or once in all")
        let top = files(in: tree)
        XCTAssertNotEqual(top, 0)
        // The big file has two paths and one copy on the disk.
        let total = tree.totals[Int(top)]
        XCTAssertGreaterThanOrEqual(total, UInt64(3 * megabyte))
        XCTAssertLessThan(total, UInt64(4 * megabyte), "60 small files come to a few hundred KB, and the big file counts once")
    }

    func testAHardLinkIsRememberedWithBothOfItsPaths() throws {
        let scan = newScan()
        XCTAssertTrue(finishes(scan, mode: .full, threads: 4))
        let tree = scan.tree
        let big = tree.links.filter { $0.bytes >= UInt64(3 * megabyte) }
        XCTAssertEqual(big.count, 2)
        XCTAssertEqual(Set(big.map(\.key)).count, 1, "One file")
        XCTAssertEqual(big.filter(\.counted).count, 1, "Counted at one of its paths only")
    }

    /// More than one worker's stretch of the table, all saying the same two places, so they end up as one group.
    func testThousandsOfLinksBetweenTwoFoldersAreOneGroup() throws {
        let many = 10_000
        try write("shared/original-0.txt", bytes: 4096)
        try FileManager.default.createDirectory(atPath: root + "/links", withIntermediateDirectories: true)
        let bytes = Data(count: 4096)
        for at in 0..<many {
            try bytes.write(to: URL(fileURLWithPath: root + "/shared/one-\(at).txt"))
            try FileManager.default.linkItem(atPath: root + "/shared/one-\(at).txt", toPath: root + "/links/one-\(at).txt")
        }
        let scan = newScan()
        XCTAssertTrue(finishes(scan, mode: .full, threads: 4))
        let tree = scan.tree
        let top = files(in: tree)
        let shared = try XCTUnwrap(tree.children(top).first { tree.name($0) == "shared" })
        let links = try XCTUnwrap(tree.children(top).first { tree.name($0) == "links" })

        let groups = tree.links.filter { $0.dir == shared || $0.dir == links }
        XCTAssertEqual(groups.count, 2, "\(many) files, but only two places")
        XCTAssertEqual(Set(groups.map(\.key)).count, 1)
        XCTAssertEqual(groups.filter(\.counted).count, 1)
        let each = try XCTUnwrap(groups.first?.bytes)
        XCTAssertGreaterThanOrEqual(each, UInt64(many * 4096))

        // Counted once, wherever it settled, and neither folder alone gives any of it back.
        XCTAssertGreaterThanOrEqual(tree.totals[Int(shared)] + tree.totals[Int(links)], each)
        XCTAssertLessThan(tree.totals[Int(shared)] + tree.totals[Int(links)], each + UInt64(2 * megabyte))
        let lone = min(Accounting.reclaimable([shared], in: tree), Accounting.reclaimable([links], in: tree))
        XCTAssertLessThan(lone, UInt64(megabyte))
        XCTAssertGreaterThanOrEqual(Accounting.reclaimable([shared, links], in: tree), each)
    }

    /// A folder that couldn't be opened because too many files were open isn't one you may not read. It used to be written
    /// off as denied, and a whole scan could quietly lose thousands of folders.
    func testRunningOutOfOpenFilesDoesntLoseFolders() throws {
        for at in 0..<400 { try write("many/folder-\(at)/inner/small.txt", bytes: 4096) }
        var limit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &limit), 0)
        let before = limit
        // Short of files for eight workers, whatever the tests before this one left open: they all count against the limit.
        let open = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 32
        limit.rlim_cur = rlim_t(open + 64)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limit), 0)
        defer {
            var back = before
            setrlimit(RLIMIT_NOFILE, &back)
        }
        let scan = newScan()
        XCTAssertTrue(finishes(scan, mode: .full, threads: 8, seconds: 60))
        let tree = scan.tree
        var denied = 0
        for i in 0..<tree.count where tree.nodes[i].has(NodeFlag.denied) { denied += 1 }
        XCTAssertEqual(denied, 0, "Every folder here can be read")
        XCTAssertEqual(scan.scanner.filesSoFar, 60 + 3 + 400)
    }

    func testAskingForMoreOpenFilesLeavesRoomForEveryWorker() {
        Scanner.askForEnoughOpenFiles()
        var limit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &limit), 0)
        XCTAssertGreaterThanOrEqual(limit.rlim_cur, 2048)
    }

    func testAPictureOfAFinishedScanAddsUp() {
        let scan = newScan()
        XCTAssertTrue(finishes(scan, mode: .full, threads: 4))
        let tree = scan.tree
        let parts = tree.children(0).reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
        XCTAssertEqual(parts, tree.capacityBytes, "Every piece of the ring together is the whole disk")
    }
}
