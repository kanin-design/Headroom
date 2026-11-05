import XCTest
@testable import Headroom

/// Working out a copy's top folder used to start over after every step. It has to come to the same answer without doing that.
final class ClimbTests: XCTestCase {
    /// Small and repeatable, so a failure can be run again.
    private struct Dice: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var x = state
            x ^= x >> 33
            x = x &* 0xff51afd7ed558ccd
            x ^= x >> 33
            return x
        }
    }

    /// The way it used to be done, starting over after every step, except that it takes the deepest first: the old one took them
    /// in whatever order they came. Being inside another answer wasn't looked at then either, so that's taken out here.
    private func theLongWay(_ start: Set<UInt32>, _ startCovered: [UInt32: UInt64], parent: (UInt32) -> UInt32, mayName: (UInt32) -> Bool, holds: (UInt32) -> UInt64) -> Set<UInt32> {
        func depth(_ node: UInt32) -> Int {
            var steps = 0, at = node
            while at != 0 {
                at = parent(at)
                steps += 1
            }
            return steps
        }
        var tops = start
        var covered = startCovered
        var changed = true
        while changed {
            changed = false
            for top in tops.sorted(by: { depth($0) != depth($1) ? depth($0) > depth($1) : $0 < $1 }) where covered[top] != nil {
                let up = parent(top)
                guard mayName(up) else { continue }
                var together: UInt64 = 0
                var siblings: [UInt32] = []
                for other in tops where parent(other) == up && covered[other] != nil {
                    together &+= covered[other] ?? 0
                    siblings.append(other)
                }
                if Double(together) >= Double(holds(up)) * 0.95 {
                    for sibling in siblings { tops.remove(sibling) }
                    tops.insert(up)
                    covered[up] = together
                    changed = true
                    break
                }
            }
        }
        return tops.filter { top in
            var at = top
            while at != 0 {
                at = parent(at)
                if tops.contains(at) { return false }
            }
            return true
        }
    }

    func testItComesToTheSameAnswerOnAnyTree() {
        for seed in 0..<300 {
            var dice = Dice(state: UInt64(seed) &* 77 &+ 1)
            let count = Int.random(in: 5...400, using: &dice)
            var parents = [UInt32](repeating: 0, count: count)
            for i in 1..<count { parents[i] = UInt32.random(in: 0..<UInt32(i), using: &dice) }
            var hasChild = [Bool](repeating: false, count: count)
            for i in 1..<count { hasChild[Int(parents[i])] = true }
            // Copies start at the ends of the tree. Some of the tree holds other things too, and some can't be named.
            var tops = Set<UInt32>()
            var covered: [UInt32: UInt64] = [:]
            var holdsHere = [UInt64](repeating: 0, count: count)
            for i in 1..<count where !hasChild[i] {
                let bytes = UInt64.random(in: 1...1000, using: &dice)
                if Bool.random(using: &dice) || count < 20 {
                    tops.insert(UInt32(i))
                    covered[UInt32(i)] = bytes
                }
                holdsHere[i] = bytes
            }
            var i = count - 1
            while i > 0 {
                if hasChild[i], Int.random(in: 0..<4, using: &dice) == 0 { holdsHere[i] &+= UInt64.random(in: 0...200, using: &dice) }
                holdsHere[Int(parents[i])] &+= holdsHere[i]
                i -= 1
            }
            var nameable = (0..<count).map { _ in Int.random(in: 0..<5, using: &dice) != 0 }
            nameable[0] = false
            let parent = { (node: UInt32) in parents[Int(node)] }
            let mayName = { (node: UInt32) in nameable[Int(node)] }
            let holds = { (node: UInt32) in holdsHere[Int(node)] }

            let expected = theLongWay(tops, covered, parent: parent, mayName: mayName, holds: holds)
            var found = tops
            var foundCovered = covered
            Accounting.climb(&found, covered: &foundCovered, parent: parent, mayName: mayName, holds: holds)
            XCTAssertEqual(found, expected, "seed \(seed)")

            // The same again, with everything found in a different order.
            var shuffled = Set<UInt32>(minimumCapacity: 2048)
            for top in tops.sorted(by: >) { shuffled.insert(top) }
            var shuffledCovered = covered
            Accounting.climb(&shuffled, covered: &shuffledCovered, parent: parent, mayName: mayName, holds: holds)
            XCTAssertEqual(shuffled, found, "seed \(seed)")

            // Everything it started with is still in the answer, and nothing in the answer is inside another.
            func isInAnswer(_ node: UInt32) -> Bool {
                var at = node
                while true {
                    if found.contains(at) { return true }
                    if at == 0 { return false }
                    at = parents[Int(at)]
                }
            }
            for top in tops { XCTAssertTrue(isInAnswer(top), "seed \(seed): lost \(top)") }
            for top in found where top != 0 { XCTAssertFalse(isInAnswer(parents[Int(top)]), "seed \(seed): \(top) is inside another answer") }
        }
    }

    func testSeasonsBecomeTheirShow() {
        // 0 the disk, 1 Show, 2 and 3 its seasons.
        var tops: Set<UInt32> = [2, 3]
        var covered: [UInt32: UInt64] = [2: 100, 3: 100]
        let parents: [UInt32] = [0, 0, 1, 1]
        Accounting.climb(&tops, covered: &covered, parent: { parents[Int($0)] }, mayName: { $0 != 0 }, holds: { $0 == 1 ? 205 : 100 })
        XCTAssertEqual(tops, [1])
        XCTAssertEqual(covered[1], 200)
    }

    func testAFolderHoldingMuchElseStaysOut() {
        var tops: Set<UInt32> = [2, 3]
        var covered: [UInt32: UInt64] = [2: 100, 3: 100]
        let parents: [UInt32] = [0, 0, 1, 1]
        Accounting.climb(&tops, covered: &covered, parent: { parents[Int($0)] }, mayName: { $0 != 0 }, holds: { $0 == 1 ? 900 : 100 })
        XCTAssertEqual(tops, [2, 3])
    }

    func testThousandsOfCopiesTakeNoTime() {
        // One folder with thousands of folders in it, each its own copy, in a folder that holds much else.
        var tops = Set<UInt32>()
        var covered: [UInt32: UInt64] = [:]
        for node in 2..<UInt32(20_002) {
            tops.insert(node)
            covered[node] = 10
        }
        let started = Date()
        Accounting.climb(&tops, covered: &covered, parent: { $0 < 2 ? 0 : 1 }, mayName: { $0 != 0 }, holds: { $0 == 1 ? 10_000_000 : 10 })
        XCTAssertEqual(tops.count, 20_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "Used to take far longer than the rest of a check put together")
    }
}
