import XCTest
@testable import Headroom

final class TitlesTests: XCTestCase {
    func testEpisodeNames() {
        let cases: [(String, String, Int, Int)] = [
            ("Quiet Harbour - S05E01 - The Long Tide.mkv", "Quiet Harbour", 5, 1),
            ("Fjord.Crew.Reserve.S05E04.NORWEGiAN.1080p.TV2.WEB-DL.H.264-GROUP.mkv", "Fjord Crew Reserve", 5, 4),
            ("North.Ridge.s27e01.1080p.mkv", "North Ridge", 27, 1),
            ("Show Name 3x07 Title.avi", "Show Name", 3, 7),
            ("Show_Name_S1E2.mp4", "Show Name", 1, 2),
            ("Long Show S12 E101.mkv", "Long Show", 12, 101),
        ]
        for (name, show, season, episode) in cases {
            let parsed = Titles.parseEpisode(name)
            XCTAssertEqual(parsed?.show, show, name)
            XCTAssertEqual(parsed?.season, season, name)
            XCTAssertEqual(parsed?.episode, episode, name)
        }
    }

    func testThingsThatArentEpisodes() {
        for name in ["Blade Runner (1982).mkv", "video_1920x1080.mp4", "Movie.2019.x264.mkv", "clips1e2.mov", "Dress2.mkv", "S01.mkv", "Season 1.mkv", "render_4x3.mov", "100x20.mkv"] {
            XCTAssertNil(Titles.parseEpisode(name), name)
        }
    }

    func testKeysMatchSpellingsOfOneShow() {
        XCTAssertEqual(Titles.key("Quiet Harbour (2022)"), Titles.key("Quiet.Harbour".replacingOccurrences(of: ".", with: " ")))
        XCTAssertEqual(Titles.key("Fjord Crew: Reserve"), Titles.key("Fjord Crew Reserve"))
        XCTAssertNotEqual(Titles.key("Fjord Crew"), Titles.key("Fjord Crew Reserve"))
    }

    func testTwoShowsCanShareAName() {
        XCTAssertNotEqual(Titles.folderKey("Doctor Who (1963)"), Titles.folderKey("Doctor Who (2005)"))
        XCTAssertEqual(Titles.key("Doctor Who (1963)"), Titles.key("Doctor Who (2005)"))
    }

    func testGeneralFolders() {
        for name in ["Downloads", "Torrents", "TV", "Movies", "media"] { XCTAssertTrue(Titles.isGeneralFolder(name), name) }
        for name in ["Quiet Harbour", "Big.Show.S01"] { XCTAssertFalse(Titles.isGeneralFolder(name), name) }
    }

    func testSeasonFolders() {
        for name in ["Season 05", "season 1", "Sesong 3", "S02", "Specials", "Staffel 4"] { XCTAssertTrue(Titles.isSeasonFolder(name), name) }
        for name in ["Seasons", "Quiet Harbour", "Season", "Series of Tubes", "S", "Sxx"] { XCTAssertFalse(Titles.isSeasonFolder(name), name) }
    }

    func testFrames() {
        for name in ["shot_00123.png", "frame0001.exr", "12.jpg"] { XCTAssertTrue(Titles.isNumberedFrame(name), name) }
        for name in ["cover.png", "shot_1.png", "final-v2a.png", "IMG_0001.JPG", "DSC01234.ARW", "PXL_20260101_123456.jpg", "GOPR0012.MP4", "Screenshot 2026-01-01 at 12.00.00.png"] {
            XCTAssertFalse(Titles.isNumberedFrame(name), name)
        }
    }

    func testTimes() {
        XCTAssertEqual(Titles.timesText(4.6), "nearly 5x")
        XCTAssertEqual(Titles.timesText(4.05), "4x")
        XCTAssertEqual(Titles.timesText(3.4), "over 3x")
    }

    func testTransmissionRecord() throws {
        let raw = "d8:activity-date" + "i1793682221e" + "11:destination" + "31:/Users/someone/Downloads/Torrent".dropLast(0) + "e"
        _ = raw
        let text = "d9:done-datei1793682221e11:destination6:/a/b/c4:name5:Thing6:pausedi0e5:peersl2:abee"
        let value = try XCTUnwrap(Bencode.parse(Data(text.utf8))?.dict)
        XCTAssertEqual(value["done-date"]?.int, 1793682221)
        XCTAssertEqual(value["destination"]?.string, "/a/b/c")
        XCTAssertEqual(value["name"]?.string, "Thing")
        XCTAssertEqual(value["paused"]?.int, 0)
    }

    func testBrokenRecordsDontCrash() {
        for text in ["", "d", "i12", "5:ab", "d3:ke", "l", "d1:ai1e", "99999999999999999999:x"] {
            _ = Bencode.parse(Data(text.utf8))
        }
    }

    func testSteamManifest() {
        let text = "\"AppState\"\n{\n\t\"appid\"\t\t\"1332010\"\n\t\"name\"\t\t\"Stray\"\n\t\"SizeOnDisk\"\t\t\"8367235193\"\n\t\"LastPlayed\"\t\t\"1788276879\"\n}\n"
        let values = SteamText.values(text)
        XCTAssertEqual(values["name"], "Stray")
        XCTAssertEqual(values["SizeOnDisk"], "8367235193")
        XCTAssertEqual(values["LastPlayed"], "1788276879")
    }
}
