import XCTest
@testable import Headroom

/// What Changes lists as grown and shrunk, compared with an earlier scan.
final class GrewTests: XCTestCase {
    private let gb: UInt64 = 1_000_000_000

    /// The earlier scan: these paths at these sizes a day ago. Anything else counts as new.
    private func earlier(_ disk: FakeDisk, _ sizes: [String: UInt64]) -> ScanSnapshot {
        let keys = UnsafeMutablePointer<UInt64>.allocate(capacity: disk.tree.count)
        defer { keys.deallocate() }
        History.fillKeys(tree: disk.tree, into: keys)
        var table: [UInt64: UInt64] = [:]
        for (path, size) in sizes { table[keys[Int(disk.node(path))]] = size }
        return ScanSnapshot(date: Date(timeIntervalSinceNow: -86_400), free: 0, table: table)
    }

    func testWhatGrewInsideAFolderThatShrankOverallIsStillListed() {
        let disk = FakeDisk()
        _ = disk.file("/Volumes/Fake/Media/TV/Old show/e1", 2 * gb)
        _ = disk.file("/Volumes/Fake/Media/TV/New show/e1", 3 * gb)
        _ = disk.file("/Volumes/Fake/.Trash/left", gb / 10)
        _ = disk.file("/Volumes/Fake/Docs/a", 10 * gb)
        disk.finish()
        // A day ago the old show had 5 GB more, the new one wasn't there, and the Trash held 14 GB more.
        let map = ChangeMap(tree: disk.tree, comparingWith: earlier(disk, [
            "/Volumes/Fake": 31 * gb + gb / 10, "/Volumes/Fake/Media": 7 * gb, "/Volumes/Fake/Media/TV": 7 * gb,
            "/Volumes/Fake/Media/TV/Old show": 7 * gb, "/Volumes/Fake/Media/TV/Old show/e1": 2 * gb,
            "/Volumes/Fake/.Trash": 14 * gb + gb / 10, "/Volumes/Fake/.Trash/left": gb / 10,
            "/Volumes/Fake/Docs": 10 * gb, "/Volumes/Fake/Docs/a": 10 * gb,
        ]))
        let rules = RuleBook(homePath: "/Users/nobody")
        XCTAssertEqual(Double(map.value(of: disk.node("/Volumes/Fake/Media/TV"))), -2e9, accuracy: 1, "the TV folder shrank overall")

        let grew = map.rows(tree: disk.tree, rules: rules)
        XCTAssertEqual(grew.map(\.title), ["New show"], "the new show is found though everything around it shrank")
        XCTAssertEqual(Double(grew.first?.delta ?? 0), 3e9, accuracy: 1)

        let shrank = map.rows(tree: disk.tree, rules: rules, shrinking: true)
        XCTAssertEqual(shrank.map(\.title), [".Trash", "Old show"], "and what shrank is named, not the TV folder that holds both")
        XCTAssertEqual(shrank.map { Double($0.delta) }, [-14e9, -5e9])
    }

    func testAFolderThatOnlyGrewIsNamedForWhatItHolds() {
        let disk = FakeDisk()
        _ = disk.file("/Volumes/Fake/Work/Project/build/out", 2 * gb)
        _ = disk.file("/Volumes/Fake/Work/Project/src/main", gb)
        disk.finish()
        // The build folder is new. Nothing else changed, so the project it's in says it just as well.
        let map = ChangeMap(tree: disk.tree, comparingWith: earlier(disk, [
            "/Volumes/Fake": gb, "/Volumes/Fake/Work": gb, "/Volumes/Fake/Work/Project": gb,
            "/Volumes/Fake/Work/Project/src": gb, "/Volumes/Fake/Work/Project/src/main": gb,
        ]))
        let rules = RuleBook(homePath: "/Users/nobody")
        XCTAssertEqual(map.rows(tree: disk.tree, rules: rules).map(\.title), ["Work"])
        XCTAssertEqual(map.rows(tree: disk.tree, rules: rules, shrinking: true), [], "nothing shrank")
    }
}
