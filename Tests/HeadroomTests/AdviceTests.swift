import XCTest
@testable import Headroom

final class AccountingTests: XCTestCase {
    func testAFileWithAnotherPathFreesNothing() {
        let disk = FakeDisk()
        disk.linked("/Volumes/Fake/Media/TV/Show/ep1.mkv", "/Volumes/Fake/Downloads/Show.S01/ep1.mkv", 5_000_000_000)
        disk.finish()
        let media = disk.node("/Volumes/Fake/Media/TV/Show")
        let effect = Accounting.effect(of: [media], except: [], in: disk.tree)
        XCTAssertEqual(effect.paper, 5_000_000_000)
        XCTAssertEqual(effect.total, 0)
    }

    func testBothCopiesTogetherFreeItOnce() {
        let disk = FakeDisk()
        disk.linked("/Volumes/Fake/Media/TV/Show/ep1.mkv", "/Volumes/Fake/Downloads/Show.S01/ep1.mkv", 5_000_000_000)
        disk.finish()
        let effect = Accounting.effect(of: [disk.node("/Volumes/Fake/Media/TV/Show"), disk.node("/Volumes/Fake/Downloads/Show.S01")], except: [], in: disk.tree)
        XCTAssertEqual(effect.total, 5_000_000_000)
    }

    func testWhatsTakenBackDoesntCount() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Mixed/go.mov", 3_000_000_000)
        disk.file("/Volumes/Fake/Mixed/keep.mov", 1_000_000_000)
        disk.finish()
        let effect = Accounting.effect(of: [disk.node("/Volumes/Fake/Mixed")], except: [disk.node("/Volumes/Fake/Mixed/keep.mov")], in: disk.tree)
        XCTAssertEqual(effect.total, 3_000_000_000)
    }

    func testAFolderAndWhatsInItCountOnce() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/A/b/c.bin", 2_000_000_000)
        disk.finish()
        let effect = Accounting.effect(of: [disk.node("/Volumes/Fake/A"), disk.node("/Volumes/Fake/A/b")], except: [], in: disk.tree)
        XCTAssertEqual(effect.total, 2_000_000_000)
    }

    func testOtherCopiesFindTheSmallestFolder() {
        let disk = FakeDisk()
        disk.linked("/Volumes/Fake/Media/Show/ep1.mkv", "/Volumes/Fake/Downloads/Torrents/Show.S01/ep1.mkv", 5_000_000_000)
        disk.linked("/Volumes/Fake/Media/Show/ep2.mkv", "/Volumes/Fake/Downloads/Torrents/Show.S01/ep2.mkv", 5_000_000_000)
        disk.file("/Volumes/Fake/Downloads/Torrents/Other/thing.zip", 40_000_000_000)
        disk.finish()
        let found = Accounting.otherCopies(of: [disk.node("/Volumes/Fake/Media/Show")], in: disk.tree)
        XCTAssertEqual(found.bytes, 10_000_000_000)
        XCTAssertEqual(found.folders, [disk.node("/Volumes/Fake/Downloads/Torrents/Show.S01")])
    }

    func testASingleFileTorrentIsTheFileNotItsFolder() {
        let disk = FakeDisk()
        disk.linked("/Volumes/Fake/Movies/Film (2020)/Film.mkv", "/Volumes/Fake/Seeding/Film.mkv", 5_000_000_000)
        disk.file("/Volumes/Fake/Seeding/Someone Elses Thing.mkv", 40_000_000_000, kind: .video)
        disk.finish()
        let found = Accounting.otherCopies(of: [disk.node("/Volumes/Fake/Movies/Film (2020)")], in: disk.tree)
        XCTAssertEqual(found.folders, [disk.node("/Volumes/Fake/Seeding/Film.mkv")])
    }

    func testAFolderWithOtherThingsInItIsNeverTheOtherCopy() {
        let disk = FakeDisk()
        disk.linked("/Volumes/Fake/Shows/A/e1.mkv", "/Volumes/Fake/Pile/e1.mkv", 5_000_000_000)
        disk.linked("/Volumes/Fake/Shows/B/e1.mkv", "/Volumes/Fake/Pile/other.mkv", 5_000_000_000)
        disk.finish()
        let found = Accounting.otherCopies(of: [disk.node("/Volumes/Fake/Shows/A")], in: disk.tree)
        XCTAssertFalse(found.folders.contains(disk.node("/Volumes/Fake/Pile")))
        XCTAssertEqual(found.folders, [disk.node("/Volumes/Fake/Pile/e1.mkv")])
    }

    func testAFolderThatsOnlyTheCopyIsNamedAsOneThing() {
        let disk = FakeDisk()
        disk.linked("/Volumes/Fake/TV/Show/Season 1/e1.mkv", "/Volumes/Fake/Pile/Show.S01/Season 1/e1.mkv", 5_000_000_000)
        disk.linked("/Volumes/Fake/TV/Show/Season 2/e1.mkv", "/Volumes/Fake/Pile/Show.S01/Season 2/e1.mkv", 5_000_000_000)
        disk.file("/Volumes/Fake/Pile/Other/thing.zip", 3_000_000_000)
        disk.finish()
        let found = Accounting.otherCopies(of: [disk.node("/Volumes/Fake/TV/Show")], in: disk.tree)
        XCTAssertEqual(found.folders, [disk.node("/Volumes/Fake/Pile/Show.S01")])
    }

    func testAPlannedFileWithAnotherPathFreesNothing() {
        let disk = FakeDisk()
        disk.linked("/Volumes/Fake/Movies/Film.mkv", "/Volumes/Fake/Pile/Film.mkv", 5_000_000_000)
        disk.finish()
        let effect = Accounting.effect(of: [disk.node("/Volumes/Fake/Movies/Film.mkv")], except: [], in: disk.tree)
        XCTAssertEqual(effect.total, 0)
    }

    func testBothFilesTogetherFreeIt() {
        let disk = FakeDisk()
        disk.linked("/Volumes/Fake/Movies/Film.mkv", "/Volumes/Fake/Pile/Film.mkv", 5_000_000_000)
        disk.finish()
        let effect = Accounting.effect(of: [disk.node("/Volumes/Fake/Movies/Film.mkv"), disk.node("/Volumes/Fake/Pile/Film.mkv")], except: [], in: disk.tree)
        XCTAssertEqual(effect.total, 5_000_000_000)
    }

    func testWhatsBeenRemovedIsMarkedAllTheWayDown() {
        let disk = FakeDisk()
        let inner = disk.file("/Volumes/Fake/A/b/c.bin", 2_000_000_000)
        disk.finish()
        let top = disk.node("/Volumes/Fake/A")
        disk.tree.remove(top)
        XCTAssertTrue(disk.tree.nodes[Int(inner)].has(NodeFlag.gone))
        disk.tree.restore(top)
        XCTAssertFalse(disk.tree.nodes[Int(inner)].has(NodeFlag.gone))
    }

    func testTheAfterPictureAddsUpToTheDisk() {
        let disk = FakeDisk(capacity: 100_000_000_000, free: 10_000_000_000)
        disk.file("/Volumes/Fake/A/one.bin", 30_000_000_000)
        disk.file("/Volumes/Fake/A/two.bin", 20_000_000_000)
        disk.file("/Volumes/Fake/B/three.bin", 40_000_000_000)
        disk.finish()
        let ids = [disk.node("/Volumes/Fake/A")]
        let excluded = [disk.node("/Volumes/Fake/A/two.bin")]
        let effect = Accounting.effect(of: ids, except: excluded, in: disk.tree)
        let after = AfterPlan(tree: disk.tree, ids: ids, excluded: excluded, effect: effect)
        XCTAssertEqual(after.size(disk.tree.free), 40_000_000_000)
        XCTAssertEqual(after.size(disk.node("/Volumes/Fake/A")), 20_000_000_000)
        XCTAssertEqual(after.size(disk.node("/Volumes/Fake/A/one.bin")), 0)
        XCTAssertEqual(after.size(disk.node("/Volumes/Fake/A/two.bin")), 20_000_000_000)
        XCTAssertEqual(after.size(disk.node("/Volumes/Fake/B")), 40_000_000_000)
    }

    func testPutBackRestoresTheNumbers() {
        let disk = FakeDisk()
        let file = disk.file("/Volumes/Fake/A/one.bin", 30_000_000_000)
        disk.file("/Volumes/Fake/A/two.bin", 20_000_000_000)
        disk.finish()
        let before = disk.tree.totals[0]
        let folder = disk.node("/Volumes/Fake/A")
        disk.tree.remove(file)
        XCTAssertEqual(disk.tree.totals[Int(folder)], 20_000_000_000)
        disk.tree.restore(file)
        XCTAssertEqual(disk.tree.totals[Int(folder)], 50_000_000_000)
        XCTAssertEqual(disk.tree.totals[0], before)
        XCTAssertTrue(disk.tree.children(folder).contains(file))
    }
}

final class MediaAdviceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func library() -> FakeDisk {
        let disk = FakeDisk()
        for e in 1...6 {
            disk.linked("/Volumes/Fake/Media/TV/Big Show/Season 01/Big Show - S01E0\(e).mkv", "/Volumes/Fake/Downloads/Torrents/Big.Show.S01/Big.Show.S01E0\(e).mkv", 9_000_000_000)
        }
        for s in ["Small One", "Small Two", "Small Three"] {
            for e in 1...4 { disk.file("/Volumes/Fake/Media/TV/\(s)/Season 01/\(s) - S01E0\(e).mkv", 1_800_000_000, kind: .video) }
        }
        disk.finish()
        return disk
    }

    func testABigSeriesIsNamedAndCompared() throws {
        let disk = library()
        let rows = Advisors.media(tree: disk.tree, facts: .none, now: now)
        let big = try XCTUnwrap(rows.first { $0.title == "Big Show" })
        XCTAssertTrue(big.subtitle.contains("6 episodes"), big.subtitle)
        XCTAssertTrue(big.subtitle.contains("5x your other series"), big.subtitle)
        XCTAssertEqual(big.tier, .yourCall)
        XCTAssertEqual(big.nodes, [disk.node("/Volumes/Fake/Media/TV/Big Show")])
    }

    func testASmallSeriesIsntCalledBig() throws {
        let disk = library()
        let small = try XCTUnwrap(Advisors.media(tree: disk.tree, facts: .none, now: now).first { $0.title == "Small One" })
        XCTAssertFalse(small.subtitle.contains("your other series"), small.subtitle)
    }

    func testHardLinksAreTheOtherCopy() throws {
        let disk = library()
        let big = try XCTUnwrap(Advisors.media(tree: disk.tree, facts: .none, now: now).first { $0.title == "Big Show" })
        XCTAssertEqual(big.bytes, 0)
        XCTAssertEqual(big.paperBytes, 54_000_000_000)
        XCTAssertEqual(big.gain, 54_000_000_000)
        XCTAssertEqual(big.otherCopies, [disk.node("/Volumes/Fake/Downloads/Torrents/Big.Show.S01")])
    }

    func testTwoShowsWithOneNameAreTwoRows() throws {
        let disk = FakeDisk()
        for e in 1...3 { disk.file("/Volumes/Fake/Media/TV/Doctor Who (1963)/Season 01/Doctor Who - S01E0\(e).mkv", 500_000_000, kind: .video) }
        for e in 1...3 { disk.file("/Volumes/Fake/Media/TV/Doctor Who (2005)/Season 01/Doctor Who - S01E0\(e).mkv", 2_000_000_000, kind: .video) }
        disk.finish()
        let rows = Advisors.media(tree: disk.tree, facts: .none, now: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.title)), ["Doctor Who (1963)", "Doctor Who (2005)"])
    }

    func testLooseEpisodesDontTakeTheFolderTheyreIn() throws {
        let disk = FakeDisk()
        for e in 1...9 { disk.file("/Volumes/Fake/TV/Show A - S01E0\(e).mkv", 10_000_000_000, kind: .video) }
        disk.file("/Volumes/Fake/TV/Show B - S01E01.mkv", 5_000_000_000, kind: .video)
        disk.finish()
        let row = try XCTUnwrap(Advisors.media(tree: disk.tree, facts: .none, now: now).first { $0.title == "Show A" })
        XCTAssertFalse(row.nodes.contains(disk.node("/Volumes/Fake/TV")))
        XCTAssertEqual(row.nodes.count, 9)
    }

    func testAFolderWithAnotherNameIsntTheShow() throws {
        let disk = FakeDisk()
        for e in 1...9 { disk.file("/Volumes/Fake/Stuff/Show A - S01E0\(e).mkv", 10_000_000_000, kind: .video) }
        disk.finish()
        let row = try XCTUnwrap(Advisors.media(tree: disk.tree, facts: .none, now: now).first)
        XCTAssertFalse(row.nodes.contains(disk.node("/Volumes/Fake/Stuff")))
    }

    func testAFilmsFolderIsOnlyTakenIfItsThatFilm() throws {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Movies/Some Film (2020)/Some Film (2020).mkv", 9_000_000_000, kind: .video)
        disk.file("/Volumes/Fake/Movies/Loose Film.mkv", 9_000_000_000, kind: .video)
        disk.finish()
        let rows = Advisors.media(tree: disk.tree, facts: .none, now: now)
        XCTAssertEqual(rows.first { $0.title == "Some Film (2020)" }?.nodes, [disk.node("/Volumes/Fake/Movies/Some Film (2020)")])
        XCTAssertEqual(rows.first { $0.title == "Loose Film" }?.nodes, [disk.node("/Volumes/Fake/Movies/Loose Film.mkv")])
    }

    func testPlexAndSpotlightBecomeEvidence() throws {
        let disk = library()
        var facts = Facts()
        let path = "/Volumes/Fake/Media/TV/Small One/Season 01/Small One - S01E01.mkv"
        facts.plexFiles[path] = Facts.PlexFile(views: 1, lastViewed: nil)
        facts.plexFiles["/Volumes/Fake/Media/TV/Small One/Season 01/Small One - S01E02.mkv"] = Facts.PlexFile(views: 0, lastViewed: nil)
        facts.lastOpened[path] = now.addingTimeInterval(-86_400 * 3)
        let small = try XCTUnwrap(Advisors.media(tree: disk.tree, facts: facts, now: now).first { $0.title == "Small One" })
        XCTAssertTrue(small.subtitle.contains("1 of 2 watched in Plex"), small.subtitle)
        XCTAssertTrue(small.subtitle.contains("Opened"), small.subtitle)
    }

    func testAFreshTorrentIsCalledOut() throws {
        let disk = library()
        var facts = Facts()
        facts.torrents = [Facts.Torrent(path: "/Volumes/Fake/Downloads/Torrents/Big.Show.S01", name: "Big.Show.S01", finished: now.addingTimeInterval(-86_400 * 2), uploaded: 0, isPaused: false)]
        let big = try XCTUnwrap(Advisors.media(tree: disk.tree, facts: facts, now: now).first { $0.title == "Big Show" })
        XCTAssertEqual(big.otherCopiesTitle, "Also remove the torrent copy")
        XCTAssertTrue(big.otherCopiesNote?.contains("may still be sharing") == true, big.otherCopiesNote ?? "")
        XCTAssertTrue(big.otherCopiesCaution?.contains("may still be sharing") == true, "It's said again at the last look")
    }

    func testAnOldTorrentJustSaysWhatHappens() throws {
        let disk = library()
        var facts = Facts()
        facts.torrents = [Facts.Torrent(path: "/Volumes/Fake/Downloads/Torrents/Big.Show.S01", name: "Big.Show.S01", finished: now.addingTimeInterval(-86_400 * 30), uploaded: 0, isPaused: false)]
        let big = try XCTUnwrap(Advisors.media(tree: disk.tree, facts: facts, now: now).first { $0.title == "Big Show" })
        XCTAssertTrue(big.otherCopiesNote?.contains("stops sharing") == true, big.otherCopiesNote ?? "")
        XCTAssertNil(big.otherCopiesCaution)
    }

    func testAlreadyOnAnotherDisk() throws {
        let disk = library()
        var facts = Facts()
        for e in 1...4 {
            facts.elsewhere["small two - s01e0\(e).mkv"] = [DiskIndex.Entry(disk: "Spare", size: 1_810_000_000)]
        }
        let small = try XCTUnwrap(Advisors.media(tree: disk.tree, facts: facts, now: now).first { $0.title == "Small Two" })
        XCTAssertTrue(small.subtitle.hasPrefix("All 4 have the same name and size on Spare"), small.subtitle)
    }

    func testTwoQualitiesOfOneFilmAreOneDecision() throws {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Media/Movies/Some Film 2020/Some Film 2020 - 2160p.mkv", 20_000_000_000, kind: .video)
        disk.file("/Volumes/Fake/Media/Movies/Some Film 2020/Some Film 2020.mkv", 8_000_000_000, kind: .video)
        disk.file("/Volumes/Fake/Media/Movies/Other Film/Other Film.mkv", 9_000_000_000, kind: .video)
        disk.finish()
        let rows = Advisors.media(tree: disk.tree, facts: .none, now: now)
        let group = try XCTUnwrap(rows.first { $0.title.hasPrefix("Some Film 2020") })
        XCTAssertEqual(group.parts.count, 2)
        XCTAssertEqual(group.title, "Some Film 2020: 2 versions")
        XCTAssertEqual(group.nodes.count, 2)
        // A film on its own isn't a choice between anything.
        XCTAssertEqual(rows.first { $0.title == "Other Film" }?.parts.count, 0)
    }

    func testSameNameDifferentSizeIsntTheSameFile() throws {
        let disk = library()
        var facts = Facts()
        for e in 1...4 {
            facts.elsewhere["small two - s01e0\(e).mkv"] = [DiskIndex.Entry(disk: "Spare", size: 900_000_000)]
        }
        let small = try XCTUnwrap(Advisors.media(tree: disk.tree, facts: facts, now: now).first { $0.title == "Small Two" })
        XCTAssertFalse(small.subtitle.contains("Spare"), small.subtitle)
    }
}

final class AppAdviceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let day: TimeInterval = 86_400

    private func fact(newest: Date?, running: Bool = false, signs: Int = 3, maker: String? = nil) -> AppFact {
        AppFact(path: "/Volumes/Fake/Applications/Thing.app", name: "Thing", bundleID: "com.maker.thing", fromAppStore: false, addedAt: nil, newestSign: newest, signCount: signs, isRunning: running, makerNote: maker,
                settings: ["/Volumes/Fake/Library/Caches/com.maker.thing", "/Volumes/Fake/Library/Preferences/com.maker.thing.plist"], data: ["/Volumes/Fake/Library/Application Support/Thing"])
    }

    private func disk() -> FakeDisk {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Applications/Thing.app/Contents/MacOS/Thing", 500_000_000, kind: .app)
        disk.file("/Volumes/Fake/Library/Caches/com.maker.thing/blob", 100_000_000, kind: .cache)
        disk.file("/Volumes/Fake/Library/Application Support/Thing/work.db", 2_000_000_000)
        disk.finish()
        return disk
    }

    func testAQuietAppIsSuggestedWithItsCaches() throws {
        let d = disk()
        let row = try XCTUnwrap(Advisors.appRow(fact(newest: now.addingTimeInterval(-300 * day)), tree: d.tree, now: now))
        XCTAssertEqual(row.action, .uninstall)
        XCTAssertEqual(row.bytes, 600_000_000)
        XCTAssertTrue(row.subtitle.contains("No sign of use for"), row.subtitle)
        // Too small to be on the map, but it still goes.
        XCTAssertEqual(row.extraPaths, ["/Volumes/Fake/Library/Preferences/com.maker.thing.plist"])
    }

    func testItsDataIsYourChoice() throws {
        let d = disk()
        let row = try XCTUnwrap(Advisors.appRow(fact(newest: now.addingTimeInterval(-300 * day)), tree: d.tree, now: now))
        XCTAssertEqual(row.alsoNodes, [d.node("/Volumes/Fake/Library/Application Support/Thing")])
        XCTAssertFalse(row.nodes.contains(d.node("/Volumes/Fake/Library/Application Support/Thing")))
    }

    func testAnyRecentSignKeepsItQuiet() {
        let d = disk()
        XCTAssertNil(Advisors.appRow(fact(newest: now.addingTimeInterval(-20 * day)), tree: d.tree, now: now))
    }

    func testNoSignsMeansWeDontKnow() {
        let d = disk()
        XCTAssertNil(Advisors.appRow(fact(newest: nil, signs: 0), tree: d.tree, now: now))
    }

    func testARunningAppIsNeverSuggested() {
        let d = disk()
        XCTAssertNil(Advisors.appRow(fact(newest: now.addingTimeInterval(-300 * day), running: true), tree: d.tree, now: now))
    }

    func testItSaysWhenItsMakerIsStillAround() throws {
        let d = disk()
        let row = try XCTUnwrap(Advisors.appRow(fact(newest: now.addingTimeInterval(-300 * day), maker: "Helper, from the same maker, is running."), tree: d.tree, now: now))
        XCTAssertTrue(row.subtitle.contains("from the same maker"), row.subtitle)
    }

    func testWordingStatesFactsNotVerdicts() throws {
        let d = disk()
        let row = try XCTUnwrap(Advisors.appRow(fact(newest: now.addingTimeInterval(-300 * day)), tree: d.tree, now: now))
        for word in ["unused", "junk", "useless"] {
            XCTAssertFalse((row.title + row.subtitle + row.detail).lowercased().contains(word), word)
        }
    }
}

final class ProjectAdviceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func disk() -> FakeDisk {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/dev/old/data.bin", 2_000_000_000)
        disk.finish()
        return disk
    }

    private func fact(clean: Bool = true, pushed: Bool = true, remote: String? = "git@github.com:someone/old.git", age: TimeInterval = 300) -> Facts {
        var facts = Facts()
        facts.repos["/Volumes/Fake/dev/old"] = Facts.RepoFact(path: "/Volumes/Fake/dev/old", lastCommit: now.addingTimeInterval(-age * 86_400), remote: remote, isClean: clean, allPushed: pushed)
        return facts
    }

    func testAQuietPushedProjectCanGo() throws {
        let row = try XCTUnwrap(Advisors.projects(tree: disk().tree, facts: fact(), now: now).first)
        XCTAssertEqual(row.tier, .yourCall)
        XCTAssertTrue(row.subtitle.contains("github.com/someone/old"), row.subtitle)
    }

    func testNeverTheOnlyCopyOfYourWork() {
        let d = disk()
        XCTAssertTrue(Advisors.projects(tree: d.tree, facts: fact(clean: false), now: now).isEmpty)
        XCTAssertTrue(Advisors.projects(tree: d.tree, facts: fact(pushed: false), now: now).isEmpty)
        XCTAssertTrue(Advisors.projects(tree: d.tree, facts: fact(remote: nil), now: now).isEmpty)
    }

    func testARecentCommitKeepsItQuiet() {
        XCTAssertTrue(Advisors.projects(tree: disk().tree, facts: fact(age: 20), now: now).isEmpty)
    }
}

final class GitTests: XCTestCase {
    private var root = ""
    /// Long after the commits these make, because a project with a recent commit isn't looked at any further.
    private let later = Date().addingTimeInterval(TimeInterval(Advisors.projectQuietDays + 1) * 86_400)

    override func setUpWithError() throws {
        try XCTSkipUnless(Git.isAvailable)
        root = NSTemporaryDirectory() + "HeadroomGit-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func git(_ arguments: String..., in path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.tool!)
        process.arguments = ["-C", path, "-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// A project with a remote, everything pushed.
    private func project() throws -> String {
        let fm = FileManager.default
        let remote = root + "/remote.git", work = root + "/work"
        try fm.createDirectory(atPath: remote, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        git("init", "--bare", in: remote)
        git("init", "-b", "main", in: work)
        try "hello".write(toFile: work + "/a.txt", atomically: false, encoding: .utf8)
        git("add", ".", in: work)
        git("commit", "-m", "first", in: work)
        git("remote", "add", "origin", remote, in: work)
        git("push", "-u", "origin", "main", in: work)
        return work
    }

    func testEverythingPushed() throws {
        let fact = try XCTUnwrap(Git.read(try project(), now: later))
        XCTAssertTrue(fact.isClean)
        XCTAssertTrue(fact.allPushed)
        XCTAssertNotNil(fact.remote)
        XCTAssertNotNil(fact.lastCommit)
    }

    func testUncommittedWork() throws {
        let work = try project()
        try "more".write(toFile: work + "/b.txt", atomically: false, encoding: .utf8)
        XCTAssertEqual(Git.read(work, now: later)?.isClean, false)
    }

    func testAnUnpushedCommit() throws {
        let work = try project()
        try "more".write(toFile: work + "/a.txt", atomically: false, encoding: .utf8)
        git("commit", "-am", "second", in: work)
        XCTAssertEqual(Git.read(work, now: later)?.allPushed, false)
    }

    func testABranchThatsNowhereElse() throws {
        let work = try project()
        git("branch", "side", in: work)
        XCTAssertEqual(Git.read(work, now: later)?.allPushed, false)
    }

    func testABranchWhoseRemoteBranchIsGone() throws {
        let work = try project()
        git("checkout", "-b", "side", in: work)
        git("push", "-u", "origin", "side", in: work)
        git("checkout", "main", in: work)
        git("push", "origin", "--delete", "side", in: work)
        git("fetch", "--prune", in: work)
        XCTAssertEqual(Git.read(work, now: later)?.allPushed, false)
    }

    func testAStash() throws {
        let work = try project()
        try "more".write(toFile: work + "/a.txt", atomically: false, encoding: .utf8)
        git("stash", in: work)
        XCTAssertEqual(Git.read(work, now: later)?.allPushed, false)
    }

    func testADetachedHead() throws {
        let work = try project()
        git("checkout", "--detach", in: work)
        XCTAssertEqual(Git.read(work, now: later)?.allPushed, false)
    }

    func testAnotherWorkingFolder() throws {
        let work = try project()
        git("worktree", "add", root + "/other", "-b", "elsewhere", in: work)
        git("push", "-u", "origin", "elsewhere", in: root + "/other")
        XCTAssertEqual(Git.read(work, now: later)?.allPushed, false)
    }
}

final class WinsTests: XCTestCase {
    func testBuildOutputInAQuietProjectIsAQuickWin() {
        let rules = RuleBook(homePath: "/Users/nobody")
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/quiet/node_modules/x/big.bin", 200_000_000)
        disk.file("/Volumes/Fake/busy/node_modules/x/big.bin", 200_000_000)
        disk.finish()
        // Mark them the way the scanner would.
        let tree = disk.tree
        let id = rules.ruleID(forName: "node_modules")
        for path in ["/Volumes/Fake/quiet/node_modules", "/Volumes/Fake/busy/node_modules"] {
            let node = disk.node(path)
            tree.nodes[Int(node)].rule = id
            tree.nodes[Int(node)].flags |= NodeFlag.ruleRoot
        }
        tree.changeableStatRow(disk.node("/Volumes/Fake/busy"))[DiskTree.statRecent14] = 10
        let rows = Wins.build(tree: tree, rules: rules, recipeFound: { _, _ in true })
        let quiet = rows.first { $0.isQuick && $0.title == "node_modules" }
        let busy = rows.first { !$0.isQuick && $0.title == "node_modules" }
        XCTAssertEqual(quiet?.nodes, [disk.node("/Volumes/Fake/quiet/node_modules")])
        XCTAssertEqual(busy?.nodes, [disk.node("/Volumes/Fake/busy/node_modules")])
        XCTAssertNotNil(busy?.inUse)
    }

    /// A folder the way the scanner would mark it, under a rule found by its title.
    private func mark(_ disk: FakeDisk, _ path: String, _ bytes: UInt64, rule: UInt16) {
        disk.file(path + "/data.bin", bytes)
        let node = disk.node(path)
        disk.tree.nodes[Int(node)].rule = rule
        disk.tree.nodes[Int(node)].flags |= NodeFlag.ruleRoot
    }

    func testWithNothingToRebuildItFromItsNotAQuickWin() throws {
        let rules = RuleBook(homePath: "/Users/nobody")
        let disk = FakeDisk()
        let id = rules.ruleID(forName: "node_modules")
        mark(disk, "/Volumes/Fake/fine/node_modules", 200_000_000, rule: id)
        mark(disk, "/Volumes/Fake/lost/node_modules", 200_000_000, rule: id)
        disk.finish()
        let rows = Wins.build(tree: disk.tree, rules: rules, recipeFound: { folder, recipe in
            XCTAssertEqual(recipe, ["package.json"])
            return folder.hasSuffix("/fine")
        })
        let fine = try XCTUnwrap(rows.first { $0.id == "group:node_modules" })
        let lost = try XCTUnwrap(rows.first { $0.id == "group:node_modules:no-recipe" })
        XCTAssertTrue(fine.isQuick)
        XCTAssertEqual(fine.tier, .rebuilds)
        XCTAssertFalse(lost.isQuick)
        XCTAssertEqual(lost.tier, .yourCall)
        XCTAssertEqual(lost.nodes, [disk.node("/Volumes/Fake/lost/node_modules")])
        XCTAssertTrue(lost.subtitle.contains("Nothing says what's in this folder"))
    }

    func testARecipeCanBeAnyOfSeveralNames() throws {
        let folder = NSTemporaryDirectory() + "headroom-recipe-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let python = ["requirements*", "pyproject.toml"]
        XCTAssertFalse(Wins.hasRecipe(in: folder, python))
        FileManager.default.createFile(atPath: folder + "/requirements.lock.txt", contents: Data())
        XCTAssertTrue(Wins.hasRecipe(in: folder, python))
        XCTAssertFalse(Wins.hasRecipe(in: folder, ["package.json"]))
        XCTAssertFalse(Wins.hasRecipe(in: folder + "/nowhere", python))
    }

    func testAnOpenAppsCacheIsntAQuickWin() throws {
        let running: Set<String> = ["com.example.open", Wins.runningKey(name: "Plex Media Server")]
        XCTAssertTrue(Wins.isOpen(folder: "com.example.open", running: running))
        XCTAssertTrue(Wins.isOpen(folder: "com.example.open.ShipIt", running: running), "A helper's cache belongs to its app")
        XCTAssertTrue(Wins.isOpen(folder: "PlexMediaServer", running: running), "Named for the app itself")
        XCTAssertFalse(Wins.isOpen(folder: "com.example.openish", running: running))
        XCTAssertFalse(Wins.isOpen(folder: "com.example.closed", running: running))
    }

    func testTheSmallCachesOnlyHoldClosedAppsItCanName() throws {
        let rules = RuleBook(homePath: "/Users/nobody")
        let id = try XCTUnwrap(rules.ruleID(titled: "App cache"))
        let disk = FakeDisk()
        mark(disk, "/Volumes/Fake/Caches/com.example.closed", 60_000_000, rule: id)
        mark(disk, "/Volumes/Fake/Caches/com.example.open", 60_000_000, rule: id)
        mark(disk, "/Volumes/Fake/Caches/com.example.open.ShipIt", 60_000_000, rule: id)
        mark(disk, "/Volumes/Fake/Caches/mystery", 60_000_000, rule: id)
        mark(disk, "/Volumes/Fake/Caches/CloudKit", 60_000_000, rule: id)
        mark(disk, "/Volumes/Fake/Caches/com.apple.something", 60_000_000, rule: id)
        disk.finish()
        let rows = Wins.build(tree: disk.tree, rules: rules, running: ["com.example.open"])
        let small = try XCTUnwrap(rows.first { $0.id == Wins.smallerCachesID })
        XCTAssertEqual(small.nodes, [disk.node("/Volumes/Fake/Caches/com.example.closed")])
    }

    func testABigCacheOfAnOpenAppIsInUseAndMacOSsOwnIsLeftOut() throws {
        let rules = RuleBook(homePath: "/Users/nobody")
        let id = try XCTUnwrap(rules.ruleID(titled: "App cache"))
        let disk = FakeDisk()
        mark(disk, "/Volumes/Fake/Caches/Codex", 300_000_000, rule: id)
        mark(disk, "/Volumes/Fake/Caches/Quiet", 300_000_000, rule: id)
        mark(disk, "/Volumes/Fake/Caches/GeoServices", 300_000_000, rule: id)
        disk.finish()
        let rows = Wins.build(tree: disk.tree, rules: rules, running: [Wins.runningKey(name: "Codex")])
        let open = try XCTUnwrap(rows.first { $0.nodes == [disk.node("/Volumes/Fake/Caches/Codex")] })
        XCTAssertFalse(open.isQuick)
        XCTAssertNotNil(open.inUse)
        XCTAssertEqual(rows.first { $0.nodes == [disk.node("/Volumes/Fake/Caches/Quiet")] }?.isQuick, true)
        XCTAssertNil(rows.first { $0.nodes == [disk.node("/Volumes/Fake/Caches/GeoServices")] })
    }

    func testAModelCacheIsNeverOneSuggestion() throws {
        // It also holds the login, so only the models in it are ever suggested.
        let rules = RuleBook(homePath: "/Users/nobody")
        let id = try XCTUnwrap(rules.ruleID(titled: "Hugging Face models"))
        let disk = FakeDisk()
        mark(disk, "/Volumes/Fake/LLM/huggingface", 2_000_000_000, rule: id)
        disk.finish()
        XCTAssertTrue(Wins.build(tree: disk.tree, rules: rules).filter { $0.nodes.contains(disk.node("/Volumes/Fake/LLM/huggingface")) }.isEmpty)
    }

    func testAToolsCacheItDoesntKnowIsntTakenForGranted() throws {
        let rules = RuleBook(homePath: "/Users/nobody")
        let id = try XCTUnwrap(rules.ruleID(titled: "Tool cache"))
        let disk = FakeDisk()
        mark(disk, "/Volumes/Fake/.cache/pip", 300_000_000, rule: id)
        mark(disk, "/Volumes/Fake/.cache/some-voice-model", 300_000_000, rule: id)
        disk.finish()
        let rows = Wins.build(tree: disk.tree, rules: rules)
        let known = try XCTUnwrap(rows.first { $0.nodes == [disk.node("/Volumes/Fake/.cache/pip")] })
        XCTAssertTrue(known.isQuick)
        XCTAssertEqual(known.tier, .rebuilds)
        let unknown = try XCTUnwrap(rows.first { $0.nodes == [disk.node("/Volumes/Fake/.cache/some-voice-model")] })
        XCTAssertFalse(unknown.isQuick)
        XCTAssertTrue(unknown.askFirst, "The slider never picks it")
        XCTAssertEqual(unknown.tier, .redownload)
    }
}

final class LayoutTests: XCTestCase {
    func testMarksStayAtTheEndAndDontBreakHitTesting() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/A/big.bin", 100_000_000_000)
        disk.file("/Volumes/Fake/A/tiny.bin", 5_000_000)
        disk.file("/Volumes/Fake/B/other.bin", 100_000_000_000)
        disk.finish()
        var layout = RingLayout.build(tree: disk.tree, focus: 0, colorer: { _ in .zero })
        let before = layout.pieces.count
        layout.addMarks([RingLayout.Mark(node: disk.node("/Volumes/Fake/A/tiny.bin"), color: .one, planned: true)], tree: disk.tree)
        XCTAssertEqual(layout.pieces.count, before + 1)
        XCTAssertTrue(layout.pieces.last?.isMark == true)
        XCTAssertEqual(layout.pieces.last?.node, disk.node("/Volumes/Fake/A/tiny.bin"))
        // Every ordinary point still finds an ordinary piece.
        let piece = layout.pieces[0]
        let hit = layout.hit(angle: piece.midAngle, radius: (piece.r0 + piece.r1) / 2)
        XCTAssertEqual(hit, 0)
    }

    func testPlannedPiecesAreMarked() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/A/big.bin", 100_000_000_000)
        disk.file("/Volumes/Fake/B/other.bin", 100_000_000_000)
        disk.finish()
        let target = disk.node("/Volumes/Fake/A")
        let layout = RingLayout.build(tree: disk.tree, focus: 0, colorer: { _ in .zero }, planned: { $0 == target })
        XCTAssertEqual(layout.pieces.first { $0.node == target }?.planned, 1)
        XCTAssertEqual(layout.pieces.first { $0.node == disk.node("/Volumes/Fake/B") }?.planned, 0)
    }

    func testTheAfterPictureIsARealRing() {
        let disk = FakeDisk(capacity: 300_000_000_000, free: 100_000_000_000)
        disk.file("/Volumes/Fake/A/big.bin", 100_000_000_000)
        disk.file("/Volumes/Fake/B/other.bin", 100_000_000_000)
        disk.finish()
        let ids = [disk.node("/Volumes/Fake/A")]
        let effect = Accounting.effect(of: ids, except: [], in: disk.tree)
        let after = AfterPlan(tree: disk.tree, ids: ids, excluded: [], effect: effect)
        let layout = RingLayout.build(tree: disk.tree, focus: 0, colorer: { _ in .zero }, after: after)
        XCTAssertNil(layout.pieces.first { $0.node == ids[0] })
        let free = layout.pieces.first { $0.node == disk.tree.free }
        XCTAssertEqual(free?.bytes, 200_000_000_000)
    }
}

final class SafetyTests: XCTestCase {
    func testWhatsNeverOffered() {
        let home = NSHomeDirectory()
        for path in ["/", home, "/Applications", "/System/Library/CoreServices", home + "/Library", home + "/.ssh/id_rsa", home + "/Library/Keychains/login.keychain-db", home + "/Library/Mail/x", "/usr/local/bin/x", home + "/.Trash", home + "/Downloads", home + "/Documents",
                     home + "/Library/Mail", home + "/Library/Messages", home + "/.gnupg", home + "/Library/Mobile Documents", home + "/Library/CloudStorage", home + "/Music/Music",
                     home + "/Pictures/Photos Library.photoslibrary", home + "/Pictures/Photos Library.photoslibrary/originals/a.jpg", "/Applications/Thing.app/Contents/Resources/x", "/Volumes/Spare/Thing.app/Contents"] {
            XCTAssertFalse(Safety.canTrash(path), path)
        }
    }

    func testWhatCanGo() {
        let home = NSHomeDirectory()
        for path in [home + "/Downloads/x.zip", home + "/Library/Caches/com.maker.app", "/Applications/Thing.app", "/Volumes/Spare/Media/x.mkv", "/System/Volumes/Data" + home + "/Movies/x.mov"] {
            XCTAssertTrue(Safety.canTrash(path), path)
        }
    }

    func testAnAppsSettingsGoOnlyWithAnUninstall() {
        let plist = NSHomeDirectory() + "/Library/Preferences/com.maker.app.plist"
        XCTAssertFalse(Safety.canTrash(plist))
        XCTAssertTrue(Safety.canUninstall(plist))
        XCTAssertFalse(Safety.canUninstall(NSHomeDirectory() + "/Library/Preferences/ByHost"))
    }
}

final class CleanerTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "HeadroomTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        Cleaner.onlyInside = root
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        Cleaner.onlyInside = Cleaner.testDisk
    }

    private func write(_ path: String, _ text: String = String(repeating: "x", count: 5000)) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: false, encoding: .utf8)
    }

    func testNothingOutsideTheAllowedPlaceCanBeTouched() {
        XCTAssertFalse(Cleaner.mayTouch(NSHomeDirectory() + "/Documents/anything"))
        XCTAssertThrowsError(try Cleaner.trash(NSHomeDirectory() + "/Documents/anything"))
        XCTAssertThrowsError(try Cleaner.putBack(CleanedThing(itemID: "a", title: "a", original: "/Users/x", inTrash: "/Users/x/.Trash/a", bytes: 0)))
        XCTAssertThrowsError(try Cleaner.deleteForGood(CleanedThing(itemID: "a", title: "a", original: root + "/a", inTrash: NSHomeDirectory() + "/.Trash/a", bytes: 0)))
    }

    func testOnlyWhatsInTheTrashCanBeDeletedForGood() throws {
        try write(root + "/plain/file")
        XCTAssertThrowsError(try Cleaner.deleteForGood(CleanedThing(itemID: "a", title: "a", original: root + "/a", inTrash: root + "/plain/file", bytes: 0)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/plain/file"))
        try write(root + "/.Trash/gone")
        try Cleaner.deleteForGood(CleanedThing(itemID: "a", title: "a", original: root + "/a", inTrash: root + "/.Trash/gone", bytes: 0))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.Trash/gone"))
    }

    func testPuttingBackNeverReplacesAnything() throws {
        try write(root + "/.Trash/thing", "old")
        try write(root + "/thing", "new")
        let thing = CleanedThing(itemID: "a", title: "a", original: root + "/thing", inTrash: root + "/.Trash/thing", bytes: 0)
        XCTAssertThrowsError(try Cleaner.putBack(thing))
        XCTAssertEqual(try String(contentsOfFile: root + "/thing", encoding: .utf8), "new")
        try FileManager.default.removeItem(atPath: root + "/thing")
        try Cleaner.putBack(thing)
        XCTAssertEqual(try String(contentsOfFile: root + "/thing", encoding: .utf8), "old")
    }

    func testPuttingBackRemakesAMissingFolder() throws {
        try write(root + "/.Trash/thing")
        try Cleaner.putBack(CleanedThing(itemID: "a", title: "a", original: root + "/gone/deep/thing", inTrash: root + "/.Trash/thing", bytes: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/gone/deep/thing"))
    }

    func testAMoveOntoItselfIsRefused() throws {
        try write(root + "/here/file.bin")
        XCTAssertThrowsError(try Cleaner.copyAndVerify(root + "/here/file.bin", into: root + "/here", stop: LockedFlag()) { _ in })
        XCTAssertTrue(Cleaner.moveIsOntoItself(root + "/here/file.bin", into: root + "/here"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/here/file.bin"))
    }

    func testAMoveIntoItselfIsRefused() throws {
        try write(root + "/here/inner/file.bin")
        XCTAssertThrowsError(try Cleaner.copyAndVerify(root + "/here", into: root + "/here/inner/deep", stop: LockedFlag()) { _ in })
        XCTAssertTrue(Cleaner.moveIsOntoItself(root + "/here", into: root + "/here/inner/deep"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/here/inner/deep"))
    }

    func testAMoveThroughALinkBackToItselfIsRefused() throws {
        try write(root + "/here/file.bin")
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/here")
        XCTAssertThrowsError(try Cleaner.copyAndVerify(root + "/here/file.bin", into: root + "/link", stop: LockedFlag()) { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/here/file.bin"))
    }

    func testAFileThatLaterTookItsNameIsLeftAlone() throws {
        try write(root + "/.Trash/thing", "the original")
        let identity = Cleaner.identity(of: root + "/.Trash/thing")
        try FileManager.default.removeItem(atPath: root + "/.Trash/thing")
        try write(root + "/.Trash/thing", "something else entirely")
        let thing = CleanedThing(itemID: "a", title: "a", original: root + "/back", inTrash: root + "/.Trash/thing", bytes: 0, identity: identity == Cleaner.identity(of: root + "/.Trash/thing") ? "0:0" : identity)
        XCTAssertEqual(try Cleaner.deleteForGood(thing), false)
        XCTAssertThrowsError(try Cleaner.putBack(thing))
        XCTAssertEqual(try String(contentsOfFile: root + "/.Trash/thing", encoding: .utf8), "something else entirely")
    }

    func testOnlyWhatWasInTheTrashThenGoes() throws {
        try write(root + "/.Trash/old")
        let then = Cleaner.trashContents(root + "/.Trash")
        try write(root + "/.Trash/new")
        XCTAssertEqual(Cleaner.deleteFromTrash(then), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.Trash/old"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/.Trash/new"))
    }

    func testNothingOutsideATrashIsDeletedAsIfItWere() throws {
        try write(root + "/plain/file")
        XCTAssertEqual(Cleaner.deleteFromTrash([root + "/plain/file"]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/plain/file"))
    }

    func testAPlannedThingOnAnUnpluggedDiskStaysPlanned() {
        let item = PlanItem(id: "a", title: "a", note: "", tierRaw: Tier.yourCall.rawValue, paths: ["/Volumes/NoSuchDiskHere/thing"])
        let result = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: [])
        XCTAssertEqual(result["a"]?.isGone, false)
        XCTAssertEqual(result["a"]?.problems, [.diskMissing("NoSuchDiskHere")])
    }

    func testADifferentDiskWithTheSameNameIsntTouched() throws {
        try write(root + "/thing")
        let item = PlanItem(id: "a", title: "a", note: "", tierRaw: Tier.rebuilds.rawValue, paths: [root + "/thing"], diskID: "not-this-disk")
        let result = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: [])
        XCTAssertEqual(result["a"]?.canGo, false)
    }

    func testAMoveToWhereItAlreadyIsStops() throws {
        try write(root + "/here/thing")
        let item = PlanItem(id: "a", title: "a", note: "", tierRaw: Tier.yourCall.rawValue, paths: [root + "/here/thing"], step: .move(folder: root + "/here"))
        let result = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: [])
        XCTAssertEqual(result["a"]?.problems.contains(.alreadyThere), true)
    }

    func testCopyingAFolderChecksEveryFile() throws {
        try write(root + "/from/Show/Season 1/ep1.mkv")
        try write(root + "/from/Show/Season 1/ep2.mkv", "other contents")
        try write(root + "/from/Show/info.nfo", "nfo")
        try Cleaner.copyAndVerify(root + "/from/Show", into: root + "/to/TV", stop: LockedFlag()) { _ in }
        let fm = FileManager.default
        XCTAssertTrue(fm.contentsEqual(atPath: root + "/from/Show", andPath: root + "/to/TV/Show"))
        // The original is untouched: it only goes once the caller moves it to the Trash.
        XCTAssertTrue(fm.fileExists(atPath: root + "/from/Show/info.nfo"))
    }

    func testCopyingKeepsFileDates() throws {
        try write(root + "/from/old.bin")
        let date = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root + "/from/old.bin")
        try Cleaner.copyAndVerify(root + "/from/old.bin", into: root + "/to", stop: LockedFlag()) { _ in }
        let copied = try FileManager.default.attributesOfItem(atPath: root + "/to/old.bin")[.modificationDate] as? Date
        XCTAssertEqual(copied, date)
    }

    func testCopyingNeverReplacesADifferentFile() throws {
        try write(root + "/from/ep.mkv", "the original")
        try write(root + "/to/ep.mkv", "something else")
        XCTAssertThrowsError(try Cleaner.copyAndVerify(root + "/from/ep.mkv", into: root + "/to", stop: LockedFlag()) { _ in })
        XCTAssertEqual(try String(contentsOfFile: root + "/to/ep.mkv", encoding: .utf8), "something else")
    }

    func testTheSameFileAlreadyThereIsFine() throws {
        try write(root + "/from/ep.mkv", "same")
        try write(root + "/to/ep.mkv", "same")
        XCTAssertNoThrow(try Cleaner.copyAndVerify(root + "/from/ep.mkv", into: root + "/to", stop: LockedFlag()) { _ in })
    }

    func testStoppingLeavesNoPartLeftUnderARealName() throws {
        try write(root + "/from/big.bin", String(repeating: "y", count: 20 << 20))
        let stop = LockedFlag()
        stop.value = true
        XCTAssertThrowsError(try Cleaner.copyAndVerify(root + "/from/big.bin", into: root + "/to", stop: stop) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/to/big.bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/to/big.bin.headroom-partial"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/from/big.bin"))
    }

    func testChecksFindWhatsGone() {
        let item = PlanItem(id: "a", title: "a", note: "", tierRaw: Tier.rebuilds.rawValue, paths: [root + "/nothing-here"])
        let result = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: [])
        XCTAssertEqual(result["a"]?.isGone, true)
    }

    func testChecksFindAnOpenApp() throws {
        try write(root + "/Thing.app/Contents/x")
        let item = PlanItem(id: "a", title: "a", note: "", tierRaw: Tier.yourCall.rawValue, paths: [root + "/Thing.app"], bundleID: "com.maker.thing")
        let result = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: [PlanChecks.RunningApp(bundleID: "com.maker.thing", name: "Thing")])
        XCTAssertEqual(result["a"]?.canGo, false)
        XCTAssertEqual(result["a"]?.problems.contains(.appOpen(name: "Thing", bundleID: "com.maker.thing")), true)
    }

    func testChecksSeeWhatChangedAfterPlanning() throws {
        try write(root + "/project/file")
        var item = PlanItem(id: "a", title: "a", note: "", tierRaw: Tier.yourCall.rawValue, paths: [root + "/project"], byHand: true)
        item.addedAt = Date().addingTimeInterval(-3600)
        var result = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: [])
        XCTAssertEqual(result["a"]?.problems.contains { if case .changed = $0 { return true } else { return false } }, true)
        XCTAssertEqual(result["a"]?.canGo, false)
        // You saw that, and still want it gone.
        item.acceptedChange = Date().addingTimeInterval(10)
        result = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: [])
        XCTAssertEqual(result["a"]?.problems.contains { if case .changed = $0 { return true } else { return false } }, false)
    }

    func testAMissingDiskKeepsItPlanned() throws {
        try write(root + "/thing")
        let item = PlanItem(id: "a", title: "a", note: "", tierRaw: Tier.yourCall.rawValue, paths: [root + "/thing"], step: .move(folder: "/Volumes/NoSuchDiskHere/Media"))
        let result = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: [])
        XCTAssertEqual(result["a"]?.problems.contains(.diskMissing("NoSuchDiskHere")), true)
        XCTAssertEqual(result["a"]?.canGo, false)
    }

    func testGettingNothingBackIsSaidOutLoud() throws {
        try write(root + "/thing")
        let item = PlanItem(id: "a", title: "a", note: "", tierRaw: Tier.rebuilds.rawValue, paths: [root + "/thing"])
        let result = PlanChecks.run(items: [item], trueBytes: ["a": 100], otherCopy: ["a": (title: "~/Downloads/x", bytes: 5_000_000_000)], runningApps: [])
        XCTAssertEqual(result["a"]?.problems.contains(.noGain(other: "~/Downloads/x")), true)
        // It doesn't stop you, because removing it from the library may be exactly what you wanted.
        XCTAssertFalse(CheckProblem.noGain(other: "x").holdsBack)
    }
}

final class FinderAskTests: XCTestCase {
    func testWhatTheFinderSaysIsUnderstood() {
        XCTAssertEqual(FinderAsk.failure(from: "0:40: execution error: Not authorized to send Apple events to Finder. (-1743)\n"), .notAllowed)
        XCTAssertEqual(FinderAsk.failure(from: "1:2: execution error: Finder got an error: User canceled. (-128)"), .cancelled)
        XCTAssertEqual(FinderAsk.failure(from: "execution error: The folder can't be found. (-1728)\n"), .failed("The folder can't be found."))
        XCTAssertEqual(FinderAsk.failure(from: "0:9: execution error: Finder got an error: The file “Stuck” is locked (for now). (-45)\n"), .failed("The file “Stuck” is locked (for now)."))
    }

    func testEveryFailureSaysWhyInWords() {
        let failures: [Error] = [FinderAsk.Failure.notAllowed, FinderAsk.Failure.cancelled, FinderAsk.Failure.failed("x"), Cleaner.Failure.notAllowed,
                                 Cleaner.Failure.wouldOverwrite("/a"), Cleaner.Failure.copyDidNotMatch("/a"), Cleaner.Failure.sameFile, Cleaner.Failure.stopped,
                                 NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)]
        for failure in failures {
            guard case .couldntGo(let why, _) = Cleaner.whyItFailed(failure) else { return XCTFail("\(failure) has no reason") }
            XCTAssertFalse(why.isEmpty)
        }
        XCTAssertEqual(Cleaner.whyItFailed(FinderAsk.Failure.notAllowed), .couldntGo("macOS stopped Headroom from asking the Finder to move this. You can allow that in System Settings.", askSettings: true))
    }

    func testWhatFailedWaitsForYouToSayTryAgain() {
        XCTAssertTrue(CheckProblem.couldntGo("why", askSettings: false).holdsBack)
        XCTAssertFalse(CheckProblem.needsPassword.holdsBack, "A password is only something to know about. It still goes.")
    }

    func testSomethingNotYoursToMoveSaysItWillAskForAPassword() throws {
        // Somewhere the rules allow things to go from: nothing outside your home, your apps and other disks ever can.
        let root = NSHomeDirectory() + "/Library/Caches/HeadroomTests-" + UUID().uuidString
        let locked = root + "/Locked.app"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        chmod(locked, 0o555)
        defer {
            chmod(locked, 0o755)
            try? FileManager.default.removeItem(atPath: root)
        }
        let item = PlanItem(id: "a", title: "Locked", note: "", tierRaw: Tier.yourCall.rawValue, paths: [locked], step: .uninstall, lastKnownBytes: 1)
        let check = PlanChecks.run(items: [item], trueBytes: ["a": 1], otherCopy: [:], runningApps: [])["a"]
        XCTAssertEqual(check?.problems, [.needsPassword])
        XCTAssertEqual(check?.canGo, true)
    }

    func testAReadOnlyFileInYourOwnFolderMovesWithoutAPassword() throws {
        // Model caches keep their files read-only. That doesn't stop them being moved.
        let root = NSTemporaryDirectory() + "headroom-ro-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer {
            chmod(root, 0o755)
            try? FileManager.default.removeItem(atPath: root)
        }
        let file = root + "/weights.bin"
        FileManager.default.createFile(atPath: file, contents: Data([1]))
        chmod(file, 0o444)
        XCTAssertFalse(Cleaner.takesPassword(file))
        XCTAssertFalse(Cleaner.takesPassword(root))
        chmod(root, 0o555)
        XCTAssertTrue(Cleaner.takesPassword(file), "Its folder can't be changed")
        XCTAssertTrue(Cleaner.takesPassword(root), "A folder has to be writable itself to get a new parent")
    }
}
