import Foundation
@testable import SunburstKit

/// The fixture data as the kit's tree, with the parts it was drawn with.
struct FixtureTree: SunburstTree {
    let data: FixtureData
    private let first: [UInt32]
    private let next: [UInt32]
    private let keys: [UInt64]

    init(_ data: FixtureData) {
        self.data = data
        var first = [UInt32](repeating: 0, count: data.nodes.count)
        var next = [UInt32](repeating: 0, count: data.nodes.count)
        for (i, n) in data.nodes.enumerated() {
            first[i] = n.children.first ?? 0
            for (a, b) in zip(n.children, n.children.dropFirst()) { next[Int(a)] = b }
        }
        self.first = first
        self.next = next
        keys = data.nodes.map { $0.name.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 } }
    }

    func firstChild(of node: UInt32) -> UInt32 { first[Int(node)] }
    func nextSibling(of node: UInt32) -> UInt32 { next[Int(node)] }
    func parent(of node: UInt32) -> UInt32 { data.nodes[Int(node)].parent }
    func size(of node: UInt32) -> UInt64 { data.totals[Int(node)] }
    func ownSize(of node: UInt32) -> UInt64 { data.nodes[Int(node)].own }
    func isFolder(_ node: UInt32) -> Bool { data.nodes[Int(node)].folder }
    func nameKey(of node: UInt32) -> UInt64 { keys[Int(node)] }
    func name(of node: UInt32) -> String { data.nodes[Int(node)].name }

    func role(of node: UInt32) -> SunburstRole {
        let n = data.nodes[Int(node)]
        switch n.kind {
        case .free: return .room
        case .hidden, .locked: return .unreadable
        case .ghost: return .gone
        case .shared, .thing: return n.folder ? .container : .item
        }
    }
    func isShared(_ node: UInt32) -> Bool { data.nodes[Int(node)].kind == .shared }
    func group(of node: UInt32) -> UInt8? { data.nodes[Int(node)].group }
    func isStillGrowing(_ node: UInt32) -> Bool { data.nodes[Int(node)].growing }

    /// The parts the fixture was drawn with before parts: its band, halves, groups, ranks, kept and cut nodes.
    func parts(_ sizes: RingSizes) -> SunburstParts {
        let data = data
        let hasAlways = data.nodes.contains { $0.always }
        let hasCuts = data.nodes.contains { $0.cuts != nil }
        let ranked = data.ranks.contains { data.nodes[Int($0.key)].kind == .thing }
        var rings = SunburstParts.Rings(sizes, order: data.groups ? .byGroup : .bySize)
        if hasAlways { rings.keep = { data.nodes[Int($0)].always } }
        if hasCuts {
            rings.cuts = { node in
                data.nodes[Int(node)].cuts?.enumerated().map { i, c in
                    SunburstStretch(size: c.size, color: c.color.map(FixtureTree.palette), isMarked: c.marked, key: UInt8(i))
                }
            }
        }
        let band = SunburstParts.Band(order: ranked ? .ranked { data.ranks[$0] ?? 0 } : .bySize)
        return SunburstParts(split: data.halves ? .ring : nil, bands: data.band ? [band] : [], rings: rings)
    }

    static func palette(_ i: Int) -> SIMD3<Float> { SIMD3(Float(i % 4) * 0.2 + 0.1, Float(i % 3) * 0.25 + 0.2, 0.5) }
    static func colour(_ node: UInt32) -> SIMD3<Float> {
        SIMD3(Float(node % 7) / 7, Float(node % 11) / 11, Float(node % 13) / 13)
    }
}
