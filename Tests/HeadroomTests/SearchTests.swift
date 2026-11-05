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
