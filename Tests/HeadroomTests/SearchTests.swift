import XCTest

@testable import Headroom

final class SearchTests: XCTestCase {
    private let disk = FakeDisk()

    override func setUp() {
        super.setUp()
        for name in ["Økonomi", "Ærlig talt", "Ålesund", "blåbær", "Résumé", "Заметки", "Big Show", "report.mkv", "plain"] {
            disk.file("/Volumes/Fake/Files/\(name)", 1_000_000)
        }
        // How some programs store å and é: the plain letter, then the mark on its own.
        disk.file("/Volumes/Fake/Files/Pa\u{030A} tur", 1_000_000)
        disk.file("/Volumes/Fake/Files/Cafe\u{0301}", 1_000_000)
        disk.finish()
    }

    private func found(_ query: String) -> Set<String> {
        Set(Search.run(query, in: disk.tree).map { disk.tree.name($0) })
    }

    /// Many finds are put in order another way than a few: both give the biggest first, the same size in the map's order.
    func testManyFindsAreInTheSameOrderAsAFew() {
        let tree = DiskTree()
        let count = 20_000
        tree.count = count
        var seed: UInt64 = 42
        for i in 0..<count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            // Sizes that often repeat, some of them huge, some nothing.
            tree.totals[i] = i % 7 == 0 ? 0 : (seed >> 33) % 500 << (seed >> 20 % 40)
        }
        tree.totals[17] = .max
        let found = (0..<UInt32(count)).filter { $0 % 3 != 1 }
        let expected = found.enumerated().sorted {
            let a = tree.totals[Int($0.element)], b = tree.totals[Int($1.element)]
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        var sorted = found
        Search.sortBySize(&sorted, in: tree)
        XCTAssertEqual(sorted, expected)
        var few = Array(found.prefix(100))
        Search.sortBySize(&few, in: tree)
        XCTAssertEqual(few, expected.filter { $0 < found[100] })
    }

    func testCapitalsMatchBeyondAToZ() {
        XCTAssertEqual(found("økonomi"), ["Økonomi"])
        XCTAssertEqual(found("ØKONOMI"), ["Økonomi"])
        XCTAssertEqual(found("ærlig"), ["Ærlig talt"])
        XCTAssertEqual(found("ålesund"), ["Ålesund"])
        XCTAssertEqual(found("BLÅBÆR"), ["blåbær"])
        XCTAssertEqual(found("заметки"), ["Заметки"])
    }

    func testALetterMatchesHoweverItIsStored() {
        XCTAssertEqual(found("på tur"), ["Pa\u{030A} tur"])
        XCTAssertEqual(found("café"), ["Cafe\u{0301}"])
        // Typed the other way round.
        XCTAssertEqual(found("re\u{0301}sume\u{0301}"), ["Résumé"])
    }

    func testPlainSearchesStillWork() {
        XCTAssertEqual(found("big show"), ["Big Show"])
        XCTAssertEqual(found("BIG"), ["Big Show"])
        XCTAssertEqual(found("mkv"), ["report.mkv"])
        // Inside a name that also has letters beyond A to Z.
        XCTAssertEqual(found("konomi"), ["Økonomi"])
    }

    func testADifferentLetterIsNotAMatch() {
        XCTAssertEqual(found("ålesunda"), [])
        XCTAssertEqual(found("zz"), [])
        XCTAssertEqual(found("økonomø"), [])
    }
}
