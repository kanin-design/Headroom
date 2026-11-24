import Observation
import XCTest

@testable import Headroom

/// The row the pointer on the ring lights is told to that row alone.
@MainActor
final class LitRowTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private func changes(_ rows: LitRow, _ id: String, when change: () -> Void) -> Bool {
        let changed = Flag()
        withObservationTracking {
            _ = rows.isLit(id)
        } onChange: {
            changed.isSet = true
        }
        change()
        return changed.isSet
    }

    func testOnlyTheRowsThatChangeAreTold() {
        let rows = LitRow()
        XCTAssertFalse(rows.isLit("a"))
        XCTAssertTrue(changes(rows, "a") { rows.light("a") })
        XCTAssertTrue(rows.isLit("a"))
        XCTAssertFalse(changes(rows, "c") { rows.light("b") }, "a row that was dark and stays dark isn't made again")
        XCTAssertFalse(rows.isLit("a"))
        XCTAssertTrue(rows.isLit("b"))
        XCTAssertFalse(changes(rows, "b") { rows.light("b") }, "the same row again changes nothing")
        XCTAssertTrue(changes(rows, "b") { rows.light(nil) })
        XCTAssertNil(rows.lit)
    }

    func testARowFirstAskedAboutLaterKnowsItIsLit() {
        let rows = LitRow()
        rows.light("late")
        XCTAssertTrue(rows.isLit("late"))
        XCTAssertFalse(rows.isLit("other"))
    }
}
