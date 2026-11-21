import Foundation

/// A ready-made `SunburstTree` of your own items: give it the top item, what each one is called, how big it is and what's
/// inside it, and it numbers them for the chart.
///
/// ```swift
/// struct Cost { var name: String; var cents: Int; var parts: [Cost] = [] }
///
/// let tree = ItemTree(budget, name: \.name, size: \.cents, children: \.parts)
/// Sunburst(tree, sizeText: { "$\($0 / 100)" })
/// ```
///
/// `size` is what an item holds itself, in whole units such as bytes, cents or a count. A node's size is its own and
/// everything inside it, so only the items at the ends need one. An item with items inside it is drawn as a folder, the rest
/// as files.
///
/// Items are numbered in the order they're given: the top item is 0, and each item comes before what's inside it. So the
/// same items with new sizes keep their numbers, and a tree made again from them can be set as the chart's `tree`: every
/// piece glides to its new place.
public struct ItemTree<Item> {
    @usableFromInline let items: [Item]
    @usableFromInline let names: [String]
    @usableFromInline let keys: [UInt64]
    @usableFromInline let parents: [UInt32]
    @usableFromInline let firstChildren: [UInt32]
    @usableFromInline let siblings: [UInt32]
    @usableFromInline let totals: [UInt64]
    @usableFromInline let owns: [UInt64]
    @usableFromInline let roles: [SunburstRole]

    /// A tree of `root` and everything inside it. `children` may give nil or an empty list for an item with nothing inside.
    /// `role`, if given, says what an item is, such as money not yet spent being room (`SunburstRole.room`); by default an
    /// item with items inside it is a container and the rest are items.
    public init<Size: BinaryInteger>(_ root: Item, name: (Item) -> String, size: (Item) -> Size, children: (Item) -> [Item]?,
                                     role: ((Item) -> SunburstRole?)? = nil) {
        var items: [Item] = [], names: [String] = [], parents: [UInt32] = [], owns: [UInt64] = []
        // Depth first without recursion, so a deep tree can't run out of stack: each item is numbered before what's inside it,
        // and what's inside it in the order given.
        var stack: [(item: Item, parent: UInt32)] = [(root, 0)]
        while let (item, parent) = stack.popLast() {
            precondition(items.count < Int(UInt32.max), "An ItemTree holds at most \(UInt32.max) items.")
            let id = UInt32(items.count)
            items.append(item)
            names.append(name(item))
            parents.append(parent)
            owns.append(UInt64(clamping: size(item)))
            if let inside = children(item) {
                for child in inside.reversed() { stack.append((child, id)) }
            }
        }

        let count = items.count
        // Everything inside a node is numbered after it, so going backwards adds each node into its parent in one pass.
        var totals = owns
        for id in stride(from: count - 1, to: 0, by: -1) {
            let parent = Int(parents[id])
            let (sum, over) = totals[parent].addingReportingOverflow(totals[id])
            totals[parent] = over ? .max : sum
        }

        var lists = [[UInt32]](repeating: [], count: count)
        for id in 1..<count { lists[Int(parents[id])].append(UInt32(id)) }
        var firstChildren = [UInt32](repeating: 0, count: count)
        var siblings = [UInt32](repeating: 0, count: count)
        for (parent, list) in lists.enumerated() where !list.isEmpty {
            // Biggest first; of the same size, in the order given, which is the order they're numbered in.
            let ordered = list.count == 1 ? list : list.sorted { a, b in
                totals[Int(a)] != totals[Int(b)] ? totals[Int(a)] > totals[Int(b)] : a < b
            }
            firstChildren[parent] = ordered[0]
            for at in ordered.indices.dropLast() { siblings[Int(ordered[at])] = ordered[at + 1] }
        }

        self.items = items
        self.names = names
        self.keys = names.map(Self.key)
        self.parents = parents
        self.firstChildren = firstChildren
        self.siblings = siblings
        self.totals = totals
        self.owns = owns
        roles = items.indices.map { at in role?(items[at]) ?? (firstChildren[at] != 0 ? .container : .item) }
    }

    /// The item a node stands for.
    @inlinable
    public subscript(node: UInt32) -> Item { items[Int(node)] }

    /// How many nodes there are, the top one included. They're numbered from 0 to one less than this.
    @inlinable
    public var count: Int { items.count }

    /// What a node is called.
    @inlinable
    public func name(of node: UInt32) -> String { names[Int(node)] }

    /// The nodes whose items pass the test, in the order they're numbered: to mark them, light them or zoom into one.
    public func nodes(where test: (Item) throws -> Bool) rethrows -> [UInt32] {
        var out: [UInt32] = []
        for (at, item) in items.enumerated() where try test(item) { out.append(UInt32(at)) }
        return out
    }

    /// A number from a name that's the same from one run to the next (FNV-1a).
    static func key(_ name: String) -> UInt64 {
        name.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}

extension ItemTree: SunburstTree {
    @inlinable public func firstChild(of node: UInt32) -> UInt32 { firstChildren[Int(node)] }
    @inlinable public func nextSibling(of node: UInt32) -> UInt32 { siblings[Int(node)] }
    @inlinable public func parent(of node: UInt32) -> UInt32 { parents[Int(node)] }
    @inlinable public func size(of node: UInt32) -> UInt64 { totals[Int(node)] }
    @inlinable public func ownSize(of node: UInt32) -> UInt64 { owns[Int(node)] }
    @inlinable public func isFolder(_ node: UInt32) -> Bool { firstChildren[Int(node)] != 0 }
    @inlinable public func role(of node: UInt32) -> SunburstRole { roles[Int(node)] }
    @inlinable public func nameKey(of node: UInt32) -> UInt64 { keys[Int(node)] }
    @inlinable public func hasNode(_ node: UInt32) -> Bool { Int(node) < items.count }
}

extension ItemTree: Sendable where Item: Sendable {}
