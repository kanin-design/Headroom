import XCTest
@testable import Headroom

/// A look inside a real folder, against what the disk says.
final class WalkerTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("headroom-walker-" + UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root + "/a/b/c", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        chmod(root + "/shut", 0o755)
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ path: String, bytes: Int) throws {
        try Data(repeating: 7, count: bytes).write(to: URL(fileURLWithPath: root + path))
    }

    /// The slow way, one file at a time, so there's something to compare with.
    private func sizeByHand(_ path: String) -> (size: UInt64, files: Int) {
        var size: UInt64 = 0, files = 0
        func walk(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return }
            files += 1
            if info.st_mode & S_IFMT == S_IFREG { size &+= UInt64(info.st_size) }
            guard info.st_mode & S_IFMT == S_IFDIR else { return }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] { walk(path + "/" + name) }
        }
        walk(path)
        return (size, files)
    }

    func testItAddsUpWhatsThereAtAnyDepth() throws {
        try write("/one.bin", bytes: 1000)
        try write("/a/two.bin", bytes: 20_000)
        try write("/a/b/three.bin", bytes: 300)
        try write("/a/b/c/four.bin", bytes: 4)
        let look = Walker.look(at: root, limit: 1000)
        XCTAssertEqual(look.size, 21_304)
        XCTAssertEqual(Walker.size(of: root), 21_304)
        XCTAssertEqual(look.largestFile, 20_000)
        XCTAssertEqual(Walker.largestFile(in: root), 20_000)
        let byHand = sizeByHand(root)
        XCTAssertEqual(look.size, byHand.size)
        XCTAssertEqual(look.seen, byHand.files)
    }

    func testAManyFolderedTreeComesOutTheSameEveryTime() throws {
        for folder in 0..<60 {
            try FileManager.default.createDirectory(atPath: root + "/many/\(folder)/inner", withIntermediateDirectories: true)
            for file in 0..<8 {
                try write("/many/\(folder)/inner/\(file).bin", bytes: 100 + file)
            }
        }
        let byHand = sizeByHand(root)
        for _ in 0..<5 {
            let look = Walker.look(at: root, limit: 100_000)
            XCTAssertEqual(look.size, byHand.size)
            XCTAssertEqual(look.seen, byHand.files)
        }
    }

    func testALinkIsNotFollowedAndTakesNoSpace() throws {
        try write("/a/real.bin", bytes: 5000)
        try FileManager.default.createDirectory(atPath: root + "/elsewhere", withIntermediateDirectories: true)
        try write("/elsewhere/big.bin", bytes: 900_000)
        try FileManager.default.createSymbolicLink(atPath: root + "/a/to-elsewhere", withDestinationPath: root + "/elsewhere")
        try FileManager.default.createSymbolicLink(atPath: root + "/a/to-file", withDestinationPath: root + "/elsewhere/big.bin")
        XCTAssertEqual(Walker.size(of: root + "/a"), 5000)
    }

    func testAHardLinkIsCountedAsLinked() throws {
        try write("/a/first.bin", bytes: 64_000)
        try FileManager.default.linkItem(atPath: root + "/a/first.bin", toPath: root + "/empty/second.bin")
        XCTAssertGreaterThanOrEqual(Walker.linkedBytes(in: root + "/a"), 64_000)
        try write("/a/b/alone.bin", bytes: 64_000)
        XCTAssertEqual(Walker.linkedBytes(in: root + "/a/b"), 0)
    }

    func testTheNewestDateIsFoundAnywhere() throws {
        try write("/a/old.bin", bytes: 10)
        try write("/a/b/c/new.bin", bytes: 10)
        let old = Date(timeIntervalSince1970: 1_500_000_000), new = Date(timeIntervalSince1970: 1_700_000_000)
        for path in [root + "/a", root + "/a/b", root + "/a/b/c", root + "/a/old.bin"] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: root + "/a/b/c/new.bin")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root + "/a/b/c")
        XCTAssertEqual(Walker.newestChange(in: root + "/a", limit: 1000), new)
    }

    func testOneFileIsItsOwnAnswer() throws {
        try write("/one.bin", bytes: 1234)
        let look = Walker.look(at: root + "/one.bin", limit: 10)
        XCTAssertEqual(look.size, 1234)
        XCTAssertEqual(look.largestFile, 1234)
        XCTAssertEqual(look.seen, 1)
    }

    func testWhatsNotThereSaysNothing() {
        XCTAssertEqual(Walker.look(at: root + "/nothing", limit: 10), Walker.Look())
        XCTAssertEqual(Walker.size(of: root + "/empty"), 0)
    }

    func testTheLimitStopsIt() throws {
        for folder in 0..<40 {
            try FileManager.default.createDirectory(atPath: root + "/many/\(folder)", withIntermediateDirectories: true)
            for file in 0..<20 { try write("/many/\(folder)/\(file).bin", bytes: 1) }
        }
        let look = Walker.look(at: root, limit: 50)
        XCTAssertGreaterThanOrEqual(look.seen, 50)
        XCTAssertLessThan(look.seen, 840, "Nowhere near all of it")
    }

    func testAFolderItCantReadIsLeftOut() throws {
        try write("/a/readable.bin", bytes: 100)
        try FileManager.default.createDirectory(atPath: root + "/shut", withIntermediateDirectories: true)
        try write("/shut/hidden.bin", bytes: 999)
        chmod(root + "/shut", 0)
        XCTAssertEqual(Walker.size(of: root), 100)
    }

    func testARecentLookIsRememberedUntilItsTooOld() throws {
        try write("/a/one.bin", bytes: 100)
        let path = root + "/a"
        XCTAssertEqual(Walker.recentLook(at: path, limit: 100, maxAge: 60).size, 100)
        try write("/a/two.bin", bytes: 50)
        XCTAssertEqual(Walker.recentLook(at: path, limit: 100, maxAge: 60).size, 100, "A moment ago is good enough")
        XCTAssertEqual(Walker.recentLook(at: path, limit: 100, maxAge: 0).size, 150, "Asked to look again")
        try write("/a/three.bin", bytes: 5)
        XCTAssertEqual(Walker.recentLook(at: path, limit: 500, maxAge: 60).size, 155, "A wider look than the one remembered")
    }
}
