import XCTest
@testable import Headroom

/// The demo flags work only in a scripted run, so your own copy never shows made-up sizes or hides a disk.
final class DemoTests: XCTestCase {
    func testTheDemoFlagsNeedAScript() {
        XCTAssertEqual(Demo.scale(in: ["Headroom", "--script", "a.txt", "--demo-scale", "200"]), 200)
        XCTAssertEqual(Demo.scale(in: ["Headroom", "--demo-scale", "200"]), 1, "not without a script")
        XCTAssertEqual(Demo.scale(in: ["Headroom", "--script", "a.txt", "--demo-scale", "x"]), 1)
        XCTAssertEqual(Demo.disks(in: ["Headroom", "--script", "a.txt", "--demo-disks", "/Volumes/A:/Volumes/B C"]), ["/Volumes/A", "/Volumes/B C"])
        XCTAssertNil(Demo.disks(in: ["Headroom", "--demo-disks", "/Volumes/A"]), "not without a script")
    }

    func testSizesScaleWithoutOverflowing() {
        XCTAssertEqual(Demo.scaled(4096, by: 200), 819_200)
        XCTAssertEqual(Demo.scaled(4096, by: 1), 4096)
        XCTAssertEqual(Demo.scaled(.max / 2, by: 200), .max, "a size too big to multiply counts as the most")
    }
}
