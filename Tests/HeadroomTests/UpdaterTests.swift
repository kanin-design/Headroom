import XCTest
@testable import Headroom

/// Which version is newer, which one is offered, and what the window says is new.
@MainActor
final class UpdaterTests: XCTestCase {
    func testVersionsCompareByTheirNumbers() {
        XCTAssertEqual(Updater.parse("v0.0.10-beta"), [0, 0, 10])
        XCTAssertEqual(Updater.parse("0.0.2"), [0, 0, 2])
        XCTAssertTrue(Updater.isNewer([0, 0, 10], than: [0, 0, 9]), "10 comes after 9, where as text it would come before")
        XCTAssertTrue(Updater.isNewer([0, 1], than: [0, 0, 9]))
        XCTAssertFalse(Updater.isNewer([0, 0, 2], than: [0, 0, 2]))
        XCTAssertFalse(Updater.isNewer([1], than: [1, 0, 0]), "a missing number is a zero")
    }

    func testANoLastsUntilANewerVersion() {
        XCTAssertTrue(Updater.shouldOffer([0, 0, 3], current: [0, 0, 2], skipped: nil))
        XCTAssertFalse(Updater.shouldOffer([0, 0, 3], current: [0, 0, 2], skipped: "0.0.3"), "you said no to it")
        XCTAssertTrue(Updater.shouldOffer([0, 0, 4], current: [0, 0, 2], skipped: "0.0.3"), "a newer one is asked about")
        XCTAssertFalse(Updater.shouldOffer([0, 0, 2], current: [0, 0, 2], skipped: nil), "the one you have")
    }

    func testALookThatCantGetThroughKeepsTheVersionItHadFound() {
        let found = Updater.Release(version: [9, 9, 9], stage: "beta", notes: "", download: URL(string: "https://example.com/9.dmg")!,
                                    size: 1, page: URL(string: "https://example.com/9")!)
        let offline: Result<Updater.Release?, Error> = .failure(URLError(.notConnectedToInternet))
        let current = [0, 0, 5]
        XCTAssertEqual(Updater.answer(offline, had: found, current: current), .available(found), "what was found is still there to install")
        guard case .couldNotCheck = Updater.answer(offline, had: nil, current: current) else {
            return XCTFail("with nothing found before, it says it couldn't look")
        }
        XCTAssertEqual(Updater.answer(.success(found), had: nil, current: current), .available(found))
        XCTAssertEqual(Updater.answer(.success(found), had: nil, current: [9, 9, 9]), .upToDate, "the one you have")
        XCTAssertEqual(Updater.answer(.success(nil), had: found, current: current), .upToDate, "an answer that there's nothing newer is believed")
    }

    func testTheNewestReleaseWithADiskImageIsOffered() throws {
        let json = """
        [{"tag_name": "v0.0.11-beta", "draft": true, "html_url": "https://example.com/11", "body": "",
          "assets": [{"name": "Headroom-0.0.11-beta.dmg", "browser_download_url": "https://example.com/11.dmg", "size": 11}]},
         {"tag_name": "v0.0.12-beta", "draft": false, "html_url": "https://example.com/12", "body": "", "assets": []},
         {"tag_name": "v0.0.10-beta", "draft": false, "html_url": "https://example.com/10", "body": "- One\\n- Two",
          "assets": [{"name": "Headroom-0.0.10-beta.dmg", "browser_download_url": "https://example.com/10.dmg", "size": 6020980}]},
         {"tag_name": "v0.0.9-beta", "draft": false, "html_url": "https://example.com/9", "body": "",
          "assets": [{"name": "Headroom-0.0.9-beta.dmg", "browser_download_url": "https://example.com/9.dmg", "size": 9}]}]
        """
        let release = try XCTUnwrap(Updater.newest(in: Data(json.utf8)), "a draft and a release with nothing to install are passed over")
        XCTAssertEqual(release.number, "0.0.10")
        XCTAssertEqual(release.shown, "0.0.10 beta")
        XCTAssertEqual(release.download.absoluteString, "https://example.com/10.dmg")
        XCTAssertEqual(release.size, 6_020_980)
        XCTAssertEqual(release.whatsNew, ["One", "Two"])
        XCTAssertNil(Updater.newest(in: Data("{\"message\": \"rate limited\"}".utf8)))
    }

    func testTheBuildNumberTellsTwoCopiesOfOneVersionApart() {
        XCTAssertTrue(Updater.isNewer([0, 0, 6], build: 130, than: [0, 0, 6], currentBuild: 124), "put out again with a newer build")
        XCTAssertFalse(Updater.isNewer([0, 0, 6], build: 124, than: [0, 0, 6], currentBuild: 124), "the build you have")
        XCTAssertFalse(Updater.isNewer([0, 0, 6], build: 110, than: [0, 0, 6], currentBuild: 124), "an older build")
        XCTAssertFalse(Updater.isNewer([0, 0, 6], build: nil, than: [0, 0, 6], currentBuild: 124), "a release that doesn't say its build")
        XCTAssertFalse(Updater.isNewer([0, 0, 5], build: 200, than: [0, 0, 6], currentBuild: 124), "never a lower version, whatever its build")
        XCTAssertTrue(Updater.isNewer([0, 0, 7], build: nil, than: [0, 0, 6], currentBuild: 124), "a higher version is newer by itself")
        XCTAssertTrue(Updater.isNewer([0, 0, 6, 0], build: 125, than: [0, 0, 6], currentBuild: 124), "0.0.6.0 is 0.0.6")
        let rebuilt = Updater.Release(version: [0, 0, 6], stage: "beta", notes: "", download: URL(string: "https://example.com/6.dmg")!,
                                      size: 1, page: URL(string: "https://example.com/6")!, build: 130)
        XCTAssertEqual(Updater.answer(.success(rebuilt), had: nil, current: [0, 0, 6], currentBuild: 124), .available(rebuilt))
        XCTAssertEqual(Updater.answer(.success(rebuilt), had: nil, current: [0, 0, 6], currentBuild: 130), .upToDate)
    }

    func testANoToABuildLastsUntilANewerBuild() {
        XCTAssertFalse(Updater.shouldOffer([0, 0, 6], build: 130, current: [0, 0, 6], currentBuild: 124, skipped: "0.0.6+130"), "you said no to it")
        XCTAssertTrue(Updater.shouldOffer([0, 0, 6], build: 131, current: [0, 0, 6], currentBuild: 124, skipped: "0.0.6+130"), "a newer build is asked about")
        XCTAssertTrue(Updater.shouldOffer([0, 0, 7], build: 140, current: [0, 0, 6], currentBuild: 124, skipped: "0.0.6+130"))
        XCTAssertEqual(Updater.skippedBuild("0.0.6+130"), 130)
        XCTAssertNil(Updater.skippedBuild("0.0.6"), "a no from before builds were kept")
    }

    func testAReleaseSaysItsBuildInAFileBesideItsDiskImage() throws {
        let json = """
        [{"tag_name": "v0.0.6-beta", "draft": false, "html_url": "https://example.com/6", "body": "",
          "assets": [{"name": "Headroom-0.0.6-beta.dmg", "browser_download_url": "https://example.com/6.dmg", "size": 6},
                     {"name": "Headroom-0.0.6-beta.json", "browser_download_url": "https://example.com/6.json", "size": 40}]}]
        """
        let release = try XCTUnwrap(Updater.newest(in: Data(json.utf8)))
        XCTAssertEqual(release.facts?.absoluteString, "https://example.com/6.json")
        XCTAssertNil(release.build, "read from that file afterwards")
        XCTAssertEqual(Updater.build(in: Data(#"{"version": "0.0.6", "build": 124}"#.utf8), version: [0, 0, 6]), 124)
        XCTAssertEqual(Updater.build(in: Data(#"{"version": "0.0.6", "build": "124"}"#.utf8), version: [0, 0, 6]), 124, "as Info.plist writes it, too")
        XCTAssertNil(Updater.build(in: Data(#"{"version": "0.0.5", "build": 124}"#.utf8), version: [0, 0, 6]), "about another version")
        XCTAssertNil(Updater.build(in: Data("not a file of facts".utf8), version: [0, 0, 6]))
    }

    func testTheWindowNamesTheBuildWhenOnlyTheBuildDiffers() {
        let rebuilt = Updater.Release(version: [0, 0, 6], stage: "beta", notes: "", download: URL(string: "https://example.com/6.dmg")!,
                                      size: 1, page: URL(string: "https://example.com/6")!, build: 130)
        XCTAssertEqual(Updater.name(of: rebuilt, current: [0, 0, 6]), "0.0.6 beta, build 130")
        XCTAssertEqual(Updater.name(of: rebuilt, current: [0, 0, 5]), "0.0.6 beta", "a new version is named by its version")
    }

    func testTheAccessGuideOpensOncePerVersionUntilYouSayNotNow() {
        XCTAssertTrue(AppModel.showsGuide(declined: nil, version: "0.0.3", scripted: false, locked: false))
        XCTAssertFalse(AppModel.showsGuide(declined: "0.0.3", version: "0.0.3", scripted: false, locked: false), "you said not now")
        XCTAssertTrue(AppModel.showsGuide(declined: "0.0.2", version: "0.0.3", scripted: false, locked: false), "a new version asks again")
        XCTAssertFalse(AppModel.showsGuide(declined: nil, version: "0.0.3", scripted: true, locked: false), "a check stays out of the way")
        XCTAssertTrue(AppModel.showsGuide(declined: nil, version: "0.0.3", scripted: true, locked: true), "unless it's checking the guide")
    }

    func testWhatsNewIsTheListInTheNotes() {
        let notes = "The second beta.\n\n## Install\n\n1. Open it.\n\nVersion 0.0.2 beta, build 61. Since build 51:\n\n- Coming back is quicker.\n- Changes looks back further.\n"
        XCTAssertEqual(Updater.newThings(in: notes), ["Coming back is quicker.", "Changes looks back further."])
        XCTAssertEqual(Updater.newThings(in: "## Headroom\n\nJust a paragraph.\n\nAnother."), ["Just a paragraph."], "with no list, the first paragraph")
    }
}
