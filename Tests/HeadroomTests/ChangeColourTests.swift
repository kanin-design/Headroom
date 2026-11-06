import XCTest
@testable import Headroom

/// Changes colours each piece by how much of it is new or changed.
final class ChangeColourTests: XCTestCase {
    private func assertSame(_ x: Lab, _ y: Lab, _ message: String, line: UInt = #line) {
        XCTAssertEqual(x.l, y.l, accuracy: 1e-4, message, line: line)
        XCTAssertEqual(x.a, y.a, accuracy: 1e-4, message, line: line)
        XCTAssertEqual(x.b, y.b, accuracy: 1e-4, message, line: line)
    }

    func testAllNewIsYellowAndPartNewIsInBetween() {
        assertSame(Lenses.changeLab(delta: 100_000_000, bytes: 100_000_000), Palette.heat(1), "a wholly new file")
        assertSame(Lenses.changeLab(delta: 60_000_000_000, bytes: 100_000_000_000), Palette.heat(0.6), "60 of 100 GB")
        assertSame(Lenses.changeLab(delta: 0, bytes: 100_000_000_000), Palette.quiet, "nothing changed")
    }

    func testDustFadesTowardQuiet() {
        let dust = Lenses.changeLab(delta: 500_000_000, bytes: 1_000_000_000_000)
        XCTAssertGreaterThan(abs(dust.l - Palette.heat(0.0005).l) + abs(dust.a - Palette.heat(0.0005).a), 0.01, "half a GB of a TB is mostly quiet")
    }
}
