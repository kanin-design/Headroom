import XCTest
@testable import Headroom

/// What used to be able to stop the app: a map saved by another version or damaged on disk, odd numbers from a file or the
/// system, and things done twice.
final class CrashTests: XCTestCase {
    private let facts = VolumeFacts(name: "HeadroomCrashTest", mountPath: "/Volumes/Fake", capacity: 500_000_000_000, free: 50_000_000_000, isBoot: false)
    private var savedMap: URL { AppData.folder.appendingPathComponent("last-HeadroomCrashTest.scan") }
    private let rules = RuleBook(homePath: "/Users/nobody")

    override func tearDown() {
        try? FileManager.default.removeItem(at: savedMap)
        super.tearDown()
    }

    private func sampleDisk() -> FakeDisk {
        let disk = FakeDisk()
        _ = disk.file("/Volumes/Fake/One/big", 50_000_000)
        _ = disk.file("/Volumes/Fake/One/inner/clip.mov", 20_000_000, kind: .video)
        _ = disk.file("/Volumes/Fake/Two/small", 5_000_000)
        disk.finish()
        return disk
    }

    // MARK: The saved map

    func testAMapSavedUnderOtherRulesIsNotShown() throws {
        TreeCache.save(sampleDisk().tree, for: facts, rules: rules)
        XCTAssertNotNil(TreeCache.load(for: facts, rules: rules), "the same rules read it back")
        let other = RuleBook(homePath: "/Users/nobody/somewhere/else/entirely")
        XCTAssertNotEqual(other.fingerprint, rules.fingerprint)
        XCTAssertNil(TreeCache.load(for: facts, rules: other), "its rule numbers could name the wrong rules, or ones past the last")
    }

    func testTheSameRulesGiveTheSameFingerprint() {
        XCTAssertEqual(RuleBook(homePath: "/Users/nobody").fingerprint, rules.fingerprint)
    }

    func testTheRulesFitTheirTable() {
        XCTAssertLessThan(rules.rules.count, RuleBook.ruleSlots)
    }

    func testARuleNumberPastTheLastIsNoRule() {
        XCTAssertEqual(rules.rule(UInt16.max).title, "")
        XCTAssertNil(rules.forcedKind(UInt16.max))
    }

    func testASavedMapCutShortIsIgnoredAtOnce() throws {
        TreeCache.save(sampleDisk().tree, for: facts, rules: rules)
        let whole = try Data(contentsOf: savedMap)
        try whole.prefix(whole.count / 2).write(to: savedMap)
        // It used to keep reading for ever, at every launch.
        let read = expectation(description: "read")
        let facts = self.facts, rules = self.rules
        DispatchQueue.global().async {
            XCTAssertNil(TreeCache.load(for: facts, rules: rules))
            read.fulfill()
        }
        wait(for: [read], timeout: 10)
    }

    func testASavedMapThatPointsOutsideItselfIsIgnored() {
        let disk = sampleDisk()
        disk.tree.nodes[Int(disk.node("/Volumes/Fake/Two"))].firstChild = 4_000_000
        TreeCache.save(disk.tree, for: facts, rules: rules)
        XCTAssertNil(TreeCache.load(for: facts, rules: rules))
    }

    func testASavedMapWhoseListGoesRoundIsIgnored() {
        let disk = sampleDisk()
        let two = disk.node("/Volumes/Fake/Two")
        disk.tree.nodes[Int(two)].nextSibling = two
        TreeCache.save(disk.tree, for: facts, rules: rules)
        // Walking that folder's list used to go round for ever, at every launch.
        let read = expectation(description: "read")
        let facts = self.facts, rules = self.rules
        DispatchQueue.global().async {
            XCTAssertNil(TreeCache.load(for: facts, rules: rules))
            read.fulfill()
        }
        wait(for: [read], timeout: 10)
    }

    // MARK: Things done twice

    func testTakingOutTwiceCountsItOnce() {
        let disk = sampleDisk()
        let one = disk.node("/Volumes/Fake/One"), parent = disk.tree.nodes[Int(one)].parent
        let before = disk.tree.totals[Int(parent)], bytes = disk.tree.totals[Int(one)]
        disk.tree.remove(one)
        disk.tree.remove(one)
        XCTAssertEqual(disk.tree.totals[Int(parent)], before - bytes)
    }

    func testPuttingBackTwiceDoesNotLinkAFolderToItself() {
        let disk = sampleDisk()
        let one = disk.node("/Volumes/Fake/One"), parent = disk.tree.nodes[Int(one)].parent
        let before = disk.tree.totals[Int(parent)]
        disk.tree.remove(one)
        disk.tree.restore(one)
        disk.tree.restore(one)
        XCTAssertEqual(disk.tree.totals[Int(parent)], before, "counted back once")
        var seen = Set<UInt32>()
        var c = disk.tree.nodes[Int(parent)].firstChild
        while c != 0 {
            guard seen.insert(c).inserted else { return XCTFail("the folder's list goes round in a loop") }
            c = disk.tree.nodes[Int(c)].nextSibling
        }
    }

    func testWhatsInTheTrashIsNotFoundBySearch() {
        let disk = sampleDisk()
        let one = disk.node("/Volumes/Fake/One")
        disk.tree.remove(one)
        XCTAssertFalse(Search.run("one", in: disk.tree).contains(one))
        XCTAssertTrue(Search.run("clip", in: disk.tree).isEmpty, "nor anything in it")
        XCTAssertFalse(Search.run("two", in: disk.tree).isEmpty, "what's still there is")
    }

    // MARK: Odd numbers

    func testSecondsOutsideWhatFitsAreHeldAtTheEnds() {
        XCTAssertEqual(UInt32(seconds: .nan), 0)
        XCTAssertEqual(UInt32(seconds: -5), 0)
        XCTAssertEqual(UInt32(seconds: 1e20), .max)
        XCTAssertEqual(UInt32(seconds: 1_700_000_000.7), 1_700_000_000)
    }

    func testSnapshotsWithOddNamesAreLeftOut() {
        let now = 1_700_200_000.0
        let keep = History.snapshotsToKeep([.infinity, .nan, 1e300, 1e30, -1, 1_700_000_000, 1_700_100_000, 1_699_000_000], now: now)
        XCTAssertEqual(keep.filter { !$0.isFinite || $0 > 1e11 || $0 < 0 }, [])
        XCTAssertTrue(keep.isSuperset(of: [1_700_100_000, 1_700_000_000]), "the two newest real ones")
    }

    // MARK: Quitting

    func testStoppingACleanEndsTheWaitForTheFinder() {
        // Stands in for osascript waiting on a password box that nobody answers.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["30"]
        let stop = LockedFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { stop.value = true }
        let started = Date()
        XCTAssertThrowsError(try FinderAsk.runToEnd(task, stop: stop)) { error in
            guard let failure = error as? Cleaner.Failure, case .stopped = failure else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "quitting used to wait as long as the Finder's box stayed up")
    }

    func testWhatTheFinderSaysStillComesBack() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/echo")
        task.arguments = ["moved"]
        XCTAssertEqual(try FinderAsk.runToEnd(task, stop: LockedFlag()), "moved")
    }

    // MARK: Odd input

    func testAHugeLengthInATorrentFileIsNoCrash() {
        XCTAssertNil(Bencode.parse(Data("9223372036854775800:abc".utf8)))
        XCTAssertNil(Bencode.parse(Data("d4:name9223372036854775807:xe".utf8)))
        XCTAssertNotNil(Bencode.parse(Data("d4:name3:abce".utf8)), "a proper one still reads")
    }
}
