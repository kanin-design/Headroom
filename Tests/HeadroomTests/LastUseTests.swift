import XCTest
import SQLite3
@testable import Headroom

/// The line under the size in the middle of the ring.
final class LastUseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lastuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testAFolderSaysWhenAnythingInsideLastChanged() {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Old/a.bin", 1_000_000, modTime: UInt32(daysAgo(40).timeIntervalSince1970))
        disk.file("/Volumes/Fake/Old/deeper/b.bin", 1_000_000, modTime: UInt32(daysAgo(3).timeIntervalSince1970))
        disk.finish()
        XCTAssertEqual(LastUse.line(disk.node("/Volumes/Fake/Old"), in: disk.tree, now: now, home: "/nonexistent"), "Changed 3 days ago")
    }

    func testGitsOwnLogGivesTheLastCommit() throws {
        let repo = try scratch()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/logs"), withIntermediateDirectories: true)
        let commit = Int(daysAgo(21).timeIntervalSince1970), checkout = Int(daysAgo(2).timeIntervalSince1970)
        let log = "0000 aaaa Someone <a@b.c> \(commit) +0100\tcommit (initial): first\n" + "aaaa aaaa Someone <a@b.c> \(checkout) +0100\tcheckout: moving from main to main\n"
        try log.write(to: repo.appendingPathComponent(".git/logs/HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(LastUse.lastCommit(in: repo.path).map { LastUse.ago($0, now: now) }, "3 weeks ago")
    }

    func testPlexIsAskedAboutJustThisPath() throws {
        let database = try scratch().appendingPathComponent("library.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database, &db), SQLITE_OK)
        let watched = Int(daysAgo(14).timeIntervalSince1970)
        let sql = """
            create table section_locations (root_path text);
            create table media_parts (id integer, media_item_id integer, file text);
            create table media_items (id integer, metadata_item_id integer);
            create table metadata_items (id integer, guid text);
            create table metadata_item_settings (guid text, view_count integer, last_viewed_at integer);
            insert into section_locations values ('/Media/Films');
            insert into media_parts values (1, 1, '/Media/Films/A/a.mkv'), (2, 2, '/Media/Films/B/b.mkv');
            insert into media_items values (1, 1), (2, 2);
            insert into metadata_items values (1, 'a'), (2, 'b');
            insert into metadata_item_settings values ('a', 1, \(watched));
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertEqual(LastUse.plexWatched("/Media/Films", database: database, now: now), "Watched 2 weeks ago")
        XCTAssertEqual(LastUse.plexWatched("/Media/Films/B", database: database, now: now), "Not watched yet")
        XCTAssertNil(LastUse.plexWatched("/Media/Films/Bonus", database: database, now: now))
        XCTAssertNil(LastUse.plexWatched("/Elsewhere", database: database, now: now))
    }

    func testSteamSaysWhenTheGameWasPlayed() throws {
        let library = try scratch().path
        let played = Int(daysAgo(14).timeIntervalSince1970)
        try "\"AppState\"\n{\n\t\"appid\"\t\t\"1\"\n\t\"installdir\"\t\t\"Some Game\"\n\t\"LastPlayed\"\t\t\"\(played)\"\n}\n"
            .write(toFile: library + "/appmanifest_1.acf", atomically: true, encoding: .utf8)
        XCTAssertEqual(LastUse.steamPlayed(library + "/common/Some Game", library: library).map { LastUse.ago($0, now: now) }, "2 weeks ago")
        XCTAssertNil(LastUse.steamPlayed(library + "/common/Some Game/saves", library: library))
        try "\"AppState\"\n{\n\t\"appid\"\t\t\"2\"\n\t\"installdir\"\t\t\"New Game\"\n\t\"LastPlayed\"\t\t\"0\"\n}\n"
            .write(toFile: library + "/appmanifest_2.acf", atomically: true, encoding: .utf8)
        XCTAssertEqual(LastUse.steamPlayed(library + "/common/New Game", library: library), .distantPast)
    }
}
