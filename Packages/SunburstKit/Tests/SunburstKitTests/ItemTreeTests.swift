import XCTest
@testable import SunburstKit

/// The ready-made tree: an app's own items, numbered for the chart.
@MainActor
final class ItemTreeTests: XCTestCase {
    struct Cost: Equatable {
        var name: String
        var cents: Int = 0
        var parts: [Cost] = []
    }

    private let budget = Cost(name: "Budget", parts: [
        Cost(name: "Home", parts: [Cost(name: "Rent", cents: 120_000), Cost(name: "Power", cents: 9_000)]),
        Cost(name: "Food", parts: [Cost(name: "Shop", cents: 30_000), Cost(name: "Out", cents: 30_000), Cost(name: "Coffee", cents: 4_000)]),
        Cost(name: "Bus", cents: 6_000),
    ])

    private func names(_ tree: ItemTree<Cost>, _ nodes: [UInt32]) -> [String] { nodes.map { tree.name(of: $0) } }

    func testItemsAreNumberedInTheOrderGivenEachBeforeWhatsInsideIt() {
        let tree = ItemTree(budget, name: \.name, size: \.cents, children: \.parts)
        XCTAssertEqual(tree.count, 9)
        XCTAssertEqual((0..<9).map { tree.name(of: $0) }, ["Budget", "Home", "Rent", "Power", "Food", "Shop", "Out", "Coffee", "Bus"])
        XCTAssertEqual(tree[4], budget.parts[1], "a node gives back its item")
        XCTAssertEqual(tree.parent(of: 7), 4)
        XCTAssertEqual(tree.parent(of: 0), 0)
    }

    func testSizesAddUpAndWhatsInsideComesBiggestFirst() {
        let tree = ItemTree(budget, name: \.name, size: \.cents, children: \.parts)
        XCTAssertEqual(tree.size(of: 0), 199_000)
        XCTAssertEqual(tree.size(of: 1), 129_000)
        XCTAssertEqual(tree.ownSize(of: 1), 0)
        XCTAssertEqual(names(tree, tree.children(of: 0)), ["Home", "Food", "Bus"])
        XCTAssertEqual(names(tree, tree.children(of: 4)), ["Shop", "Out", "Coffee"], "of the same size, in the order given")
        XCTAssertTrue(tree.isFolder(4))
        XCTAssertFalse(tree.isFolder(5))
        XCTAssertEqual(tree.role(of: 4), .container)
        XCTAssertEqual(tree.role(of: 8), .item)
        XCTAssertEqual(tree.firstChild(of: 8), 0)
    }

    /// The same items with new sizes keep their numbers, so the chart can take the new tree in place of the old one.
    func testNewSizesKeepTheNumbers() {
        var later = budget
        later.parts[2].cents = 500_000
        let before = ItemTree(budget, name: \.name, size: \.cents, children: \.parts)
        let after = ItemTree(later, name: \.name, size: \.cents, children: \.parts)
        XCTAssertEqual((0..<9).map { after.name(of: $0) }, (0..<9).map { before.name(of: $0) })
        XCTAssertEqual((0..<9).map { after.nameKey(of: $0) }, (0..<9).map { before.nameKey(of: $0) })
        XCTAssertEqual(names(after, after.children(of: 0)), ["Bus", "Home", "Food"], "only the order changed")
    }

    /// Items an app already has, whatever their shape: optional lists, any whole number, or children worked out as asked.
    func testAnyItemsWithAnyWholeNumbers() {
        struct Entry { var title: String; var count: UInt8; var inside: [Entry]? }
        let entries = ItemTree(Entry(title: "All", count: 0, inside: [Entry(title: "a", count: 3, inside: nil),
                                                                       Entry(title: "b", count: 5, inside: [])]),
                               name: \.title, size: \.count, children: \.inside)
        XCTAssertEqual(entries.size(of: 0), 8)
        XCTAssertFalse(entries.isFolder(2), "an empty list is nothing inside")

        let negative = ItemTree(Cost(name: "x", cents: -5), name: \.name, size: \.cents, children: \.parts)
        XCTAssertEqual(negative.size(of: 0), 0, "below nothing counts as nothing")

        // Numbers as items, each holding the next: a chain far deeper than any stack would take.
        let deep = ItemTree(0, name: { "\($0)" }, size: { _ in 1 }, children: { $0 < 100_000 ? [$0 + 1] : nil })
        XCTAssertEqual(deep.count, 100_001)
        XCTAssertEqual(deep.size(of: 0), 100_001)
        XCTAssertEqual(deep[100_000], 100_000)
    }

    func testFindingNodesByTheirItems() {
        let tree = ItemTree(budget, name: \.name, size: \.cents, children: \.parts)
        XCTAssertEqual(tree.nodes { $0.cents >= 30_000 }, [2, 5, 6])
        XCTAssertEqual(tree.nodes { $0.name == "Nothing" }, [])
    }

    /// A number from outside, such as an agent's, can be checked before the tree is asked about it.
    func testWhichNodesATreeHas() {
        let tree = ItemTree(budget, name: \.name, size: \.cents, children: \.parts)
        XCTAssertTrue(tree.hasNode(0))
        XCTAssertTrue(tree.hasNode(8))
        XCTAssertFalse(tree.hasNode(9))
        XCTAssertFalse(tree.hasNode(.max))

        // A tree of its own finds it from the root down.
        let other = TestTree([("a/b", 5), ("c", 3)])
        XCTAssertTrue(other.hasNode(0))
        XCTAssertTrue(other.hasNode(other.node("a/b")))
        XCTAssertFalse(other.hasNode(UInt32(other.nodes.count)))
        XCTAssertFalse(other.hasNode(.max))
    }

    /// A chart of one names its pieces from it, and from any tree shown later.
    func testAChartNamesItsPiecesFromTheTree() {
        let tree = ItemTree(budget, name: \.name, size: \.cents, children: \.parts)
        let chart = SunburstChart(tree: tree, sizeText: { "$\($0 / 100)" }, engine: SunburstEngine(reducesMotion: { false }))
        let summary = chart.summary(limit: 3)
        XCTAssertEqual(summary.name, "Budget")
        XCTAssertEqual(summary.sizeText, "$1990")
        XCTAssertEqual(summary.pieces.map(\.name), ["Home", "Rent", "Food"])

        chart.show(ItemTree(Cost(name: "Trip", parts: [Cost(name: "Train", cents: 9_000)]), name: \.name, size: \.cents, children: \.parts))
        XCTAssertEqual(chart.summary().name, "Trip")
        XCTAssertEqual(chart.summary().pieces.map(\.name), ["Train"])
    }
}
