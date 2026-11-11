import XCTest
@testable import Headroom

/// What the 2026-11-11 review found and fixed, pinned so it stays fixed.
final class ReviewFixTests: XCTestCase {
    func testOnlyARealTrashCountsBeforeDeletingForGood() {
        let home = NSHomeDirectory()
        XCTAssertTrue(Cleaner.isInTrash(home + "/.Trash/old.zip"))
        XCTAssertTrue(Cleaner.isInTrash("/System/Volumes/Data" + home + "/.Trash/folder/old.zip"))
        XCTAssertTrue(Cleaner.isInTrash("/Volumes/Spare/.Trashes/501/old.zip"))
        XCTAssertFalse(Cleaner.isInTrash(home + "/.Trash"), "The Trash itself isn't in the Trash")
        XCTAssertFalse(Cleaner.isInTrash("/Volumes/Spare/.Trashes/501"))
        XCTAssertFalse(Cleaner.isInTrash("/Volumes/Spare/.Trashes"))
        XCTAssertFalse(Cleaner.isInTrash(home + "/project/.Trash/notes.txt"), "A folder that's only called .Trash is yours")
        XCTAssertFalse(Cleaner.isInTrash(home + "/project/.Trashes/501/notes.txt"))
        XCTAssertTrue(Cleaner.isTrashFolder(home + "/.Trash"))
        XCTAssertTrue(Cleaner.isTrashFolder("/Volumes/Spare/.Trashes/501"))
        XCTAssertFalse(Cleaner.isTrashFolder(home + "/project/.Trash"))
    }

    func testAProtectedPlaceIsProtectedHoweverItsSpelled() {
        let home = NSHomeDirectory()
        XCTAssertFalse(Safety.canTrash(home + "/"), "A trailing slash is still your home folder")
        XCTAssertFalse(Safety.canTrash(home + "/Documents/"))
        XCTAssertFalse(Safety.canTrash(home + "//Documents"))
        XCTAssertFalse(Safety.canTrash(home + "/Movies/../Documents"))
        XCTAssertFalse(Safety.canTrash(""))
        XCTAssertTrue(Safety.canTrash(home + "/Movies/film.mov"))
        XCTAssertTrue(Safety.canTrash(home + "/Movies/old/"), "A folder of yours, with a slash after it, is still that folder")
    }

    func testAProjectsBuildFolderIsGroupedThoughXcodesOwnHasTheSameWords() throws {
        let rules = RuleBook(homePath: "/Users/nobody")
        let inProject = rules.rule(rules.ruleID(forName: "DerivedData"))
        XCTAssertTrue(inProject.groups, "DerivedData in a project is one row with the others")
        let xcodes = try XCTUnwrap(rules.ruleID(titled: "Xcode build output"))
        XCTAssertNotEqual(xcodes, rules.ruleID(forName: "DerivedData"))
    }
}
