import XCTest
@testable import Headroom

/// Merging links is only allowed because no answer changes. So every question is asked before and after.
final class LinksTests: XCTestCase {
    private struct Answers: Equatable {
        var reclaim: [UInt64] = []
        var sharedOut: [UInt64] = []
        var linkedIn: [UInt64] = []
        var total: [UInt64] = []
        var paper: [UInt64] = []
        var copies: [UInt64] = []
        var copyFolders: [[UInt32]] = []
        var rows: [UInt64] = []
    }

    private func answers(_ disk: FakeDisk, _ folders: [UInt32]) -> Answers {
        var out = Answers()
        for one in folders {
            out.reclaim.append(Accounting.reclaimable([one], in: disk.tree))
            let story = Accounting.story(one, in: disk.tree)
            out.sharedOut.append(story.sharedOut)
            out.linkedIn.append(story.linkedIn)
            let effect = Accounting.effect(of: [one], except: [], in: disk.tree)
            out.total.append(effect.total)
            out.paper.append(effect.paper)
            let found = Accounting.otherCopies(of: [one], in: disk.tree)
            out.copies.append(found.bytes)
            out.copyFolders.append(found.folders.sorted())
        }
        for pair in zip(folders, folders.dropFirst()) {
            let effect = Accounting.effect(of: [pair.0, pair.1], except: [], in: disk.tree)
            out.total.append(effect.total)
        }
        var rows = folders.map { node in
            WinRow(id: String(node), title: "", subtitle: "", detail: "", tier: .yourCall, nodes: [node], bytes: 0, paperBytes: disk.tree.totals[Int(node)], action: .trash, command: nil, bundleID: nil)
        }
        Wins.settleReclaim(&rows, tree: disk.tree)
        out.rows = rows.map(\.bytes)
        return out
    }

    func testMergingChangesNoAnswer() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let disk = FakeDisk()
            let names = ["A", "B", "C", "D", "E", "A/inner", "B/inner"]
            var folderFiles: [String: UInt32] = [:]
            for name in names { folderFiles[name] = disk.file("/Volumes/Fake/\(name)/filler", 50_000_000) }
            var big: [UInt32] = []
            for at in 0..<6 { big.append(disk.file("/Volumes/Fake/\(names[at % names.count])/big\(at).mov", 20_000_000, kind: .video)) }
            disk.finish()
            let dirs = names.map { disk.node("/Volumes/Fake/\($0)/filler") }.map { disk.tree.nodes[Int($0)].parent }

            var records: [LinkRecord] = []
            var key: UInt64 = 1
            // Small files have no node of their own, so most of them say the same places.
            for _ in 0..<300 {
                let size = Int.random(in: 2...3, using: &generator)
                let places = (0..<size).map { _ in dirs.randomElement(using: &generator)! }
                let bytes = UInt64.random(in: 4096...500_000, using: &generator)
                let counted = Int.random(in: 0..<size, using: &generator)
                let kind: Kind = Bool.random(using: &generator) ? .video : .code
                for (at, dir) in places.enumerated() {
                    records.append(LinkRecord(key: key, bytes: bytes, dir: dir, file: 0, when: 0, kind: kind.rawValue, counted: at == counted))
                }
                key += 1
            }
            // A big file has a node of its own, which can be picked by itself.
            for one in big.dropLast() {
                let other = dirs.randomElement(using: &generator)!
                records.append(LinkRecord(key: key, bytes: disk.tree.totals[Int(one)], dir: disk.tree.nodes[Int(one)].parent, file: one, when: 0, kind: Kind.video.rawValue, counted: true))
                records.append(LinkRecord(key: key, bytes: disk.tree.totals[Int(one)], dir: other, file: 0, when: 0, kind: Kind.video.rawValue, counted: false))
                key += 1
            }
            disk.tree.links = records
            let asked = dirs + big
            let before = answers(disk, asked)
            var merged = records
            Accounting.merge(&merged)
            XCTAssertLessThan(merged.count, records.count, "Many of them say the same thing")
            disk.tree.links = merged
            XCTAssertEqual(answers(disk, asked), before)

            // Doing it again changes nothing.
            var again = merged
            Accounting.merge(&again)
            XCTAssertEqual(again.count, merged.count)
        }
    }

    func testGroupingPutsEachFilesRecordsTogether() {
        var generator = SystemRandomNumberGenerator()
        // IDs of files and of clones, whose top bit is set, plus some that all share their upper half.
        let keys: [UInt64] = (0..<3000).map { at in
            switch at % 3 {
            case 0: return UInt64.random(in: 1...5000, using: &generator)
            case 1: return UInt64.random(in: 1...900, using: &generator) | (1 << 63)
            default: return UInt64.random(in: 1...UInt64.max, using: &generator)
            }
        }
        var records = keys.enumerated().map { at, key in
            LinkRecord(key: key, bytes: UInt64(at), dir: UInt32(at), file: 0, when: 0, kind: 0, counted: false)
        }
        records.withUnsafeMutableBufferPointer { Accounting.groupByKey($0) }
        XCTAssertEqual(records.map(\.key), keys.sorted())
        XCTAssertEqual(Set(records.map(\.dir)).count, keys.count, "Nothing lost, and nothing there twice")
        for record in records { XCTAssertEqual(keys[Int(record.dir)], record.key, "Each stays whole") }

        var one = [LinkRecord(key: 7, bytes: 1, dir: 1, file: 0, when: 0, kind: 0, counted: true)]
        one.withUnsafeMutableBufferPointer { Accounting.groupByKey($0) }
        XCTAssertEqual(one.count, 1)
        var none: [LinkRecord] = []
        none.withUnsafeMutableBufferPointer { Accounting.groupByKey($0) }
        XCTAssertTrue(none.isEmpty)
    }

    func testPathsInOnePlaceAreLeftOut() {
        var links = [
            LinkRecord(key: 1, bytes: 10, dir: 5, file: 0, when: 0, kind: 0, counted: true),
            LinkRecord(key: 1, bytes: 10, dir: 5, file: 0, when: 0, kind: 0, counted: false),
        ]
        Accounting.merge(&links)
        XCTAssertTrue(links.isEmpty)
    }

    func testAFileWithItsOwnNodeStays() {
        var links = [
            LinkRecord(key: 1, bytes: 10, dir: 5, file: 8, when: 0, kind: 0, counted: true),
            LinkRecord(key: 1, bytes: 10, dir: 5, file: 9, when: 0, kind: 0, counted: false),
        ]
        Accounting.merge(&links)
        XCTAssertEqual(links.count, 2, "Either one can be picked by itself")
    }

    func testOnlyTheSameThingIsAddedUp() {
        func group(_ key: UInt64, _ first: UInt32, _ second: UInt32, kind: UInt8 = 0, countedFirst: Bool = true) -> [LinkRecord] {
            [LinkRecord(key: key, bytes: 100, dir: first, file: 0, when: 0, kind: kind, counted: countedFirst),
             LinkRecord(key: key, bytes: 100, dir: second, file: 0, when: 0, kind: kind, counted: !countedFirst)]
        }
        var same = group(1, 5, 6) + group(2, 6, 5, countedFirst: false)
        Accounting.merge(&same)
        XCTAssertEqual(same.count, 2, "The same two places, found the other way round")
        XCTAssertEqual(same.map(\.bytes), [200, 200], "Every record in a group says its size")

        var otherKind = group(1, 5, 6) + group(2, 5, 6, kind: 3)
        Accounting.merge(&otherKind)
        XCTAssertEqual(otherKind.count, 4, "Videos are looked for by their kind")

        var otherHome = group(1, 5, 6) + group(2, 5, 6, countedFirst: false)
        Accounting.merge(&otherHome)
        XCTAssertEqual(otherHome.count, 4, "Counted in different places")

        var threePlaces = group(1, 5, 6) + [LinkRecord(key: 2, bytes: 100, dir: 5, file: 0, when: 0, kind: 0, counted: true),
                                            LinkRecord(key: 2, bytes: 100, dir: 6, file: 0, when: 0, kind: 0, counted: false),
                                            LinkRecord(key: 2, bytes: 100, dir: 7, file: 0, when: 0, kind: 0, counted: false)]
        Accounting.merge(&threePlaces)
        XCTAssertEqual(threePlaces.count, 5)
    }

    func testASavedMapGivesTheSameAnswersWithFarFewerRecords() throws {
        let disk = FakeDisk()
        for at in 0..<200 {
            disk.linked("/Volumes/Fake/One/folder\(at % 40)/file\(at).mov", "/Volumes/Fake/Two/folder\(at % 40)/file\(at).mov", 200_000, kind: .video)
        }
        _ = disk.file("/Volumes/Fake/One/big", 50_000_000)
        _ = disk.file("/Volumes/Fake/Two/big", 50_000_000)
        _ = disk.file("/Volumes/Fake/Three/big", 50_000_000)
        disk.finish()
        XCTAssertEqual(disk.tree.links.count, 400)

        let facts = VolumeFacts(name: "HeadroomLinksTest", mountPath: "/Volumes/Fake", capacity: 500_000_000_000, free: 50_000_000_000, isBoot: false)
        TreeCache.save(disk.tree, for: facts)
        defer { try? FileManager.default.removeItem(at: AppData.folder.appendingPathComponent("last-HeadroomLinksTest.scan")) }
        let loaded = try XCTUnwrap(TreeCache.load(for: facts))
        XCTAssertEqual(loaded.links.count, 2, "All of it is between the same two folders now")
        XCTAssertEqual(Set(loaded.links.map(\.bytes)), [40_000_000])

        for path in ["/Volumes/Fake/One", "/Volumes/Fake/Two", "/Volumes/Fake/Three"] {
            let before = disk.node(path), after = try XCTUnwrap(loaded.find(path: path))
            XCTAssertEqual(loaded.totals[Int(after)], disk.tree.totals[Int(before)])
            XCTAssertEqual(Accounting.reclaimable([after], in: loaded), Accounting.reclaimable([before], in: disk.tree), path)
            XCTAssertEqual(Accounting.story(after, in: loaded).sharedOut, Accounting.story(before, in: disk.tree).sharedOut, path)
            XCTAssertEqual(Accounting.story(after, in: loaded).linkedIn, Accounting.story(before, in: disk.tree).linkedIn, path)
        }
    }
}

final class SnapshotTests: XCTestCase {
    func testScansMinutesApartDontCrowdOutTheOldOnes() {
        let now = 1_800_000_000.0
        // Every 20 minutes for two days, and one a day for 40 days before that.
        var times = stride(from: 0.0, to: 2 * 86_400, by: 1_200).map { now - $0 }
        times += (2..<42).map { now - Double($0) * 86_400 - 3_600 }
        let keep = History.snapshotsToKeep(times, now: now)
        XCTAssertLessThanOrEqual(keep.count, 60)
        XCTAssertLessThan(keep.filter { now - $0 < 2 * 86_400 }.count, 20, "Not 144")
        XCTAssertTrue(keep.contains(now), "The last scan is always there to compare with")
        XCTAssertTrue(keep.contains(now - 1_200), "And the one before it")
        for (days, label) in [(1.0, "a day"), (7.0, "a week"), (14.0, "two weeks"), (30.0, "a month")] {
            // What a comparison looks for: close to the window, between 0.85 and 2 times as old.
            let seconds = days * 86_400
            XCTAssertTrue(keep.contains { now - $0 >= seconds * 0.85 && now - $0 <= seconds * 2 }, "Something from \(label) ago")
        }
    }

    func testNothingOldIsLostWhenThereAreFew() {
        let now = 1_800_000_000.0
        let times = [now - 100, now - 90_000, now - 500_000, now - 2_000_000]
        XCTAssertEqual(History.snapshotsToKeep(times, now: now), Set(times))
    }
}
