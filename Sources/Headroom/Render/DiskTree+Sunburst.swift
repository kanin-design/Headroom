@_exported import SunburstKit
import Foundation

/// The disk map is drawn by SunburstKit from the scanned tree as it is: each node's numbers are read where the scan keeps
/// them. What the map is about stays here: what each node is, and the parts each view is drawn with.
extension DiskTree: SunburstTree {
    @inline(__always) func firstChild(of node: UInt32) -> UInt32 { nodes[Int(node)].firstChild }
    @inline(__always) func nextSibling(of node: UInt32) -> UInt32 { nodes[Int(node)].nextSibling }
    @inline(__always) func parent(of node: UInt32) -> UInt32 { nodes[Int(node)].parent }
    @inline(__always) func size(of node: UInt32) -> UInt64 { totals[Int(node)] }
    @inline(__always) func ownSize(of node: UInt32) -> UInt64 { nodes[Int(node)].bytes }
    @inline(__always) func isFolder(_ node: UInt32) -> Bool { nodes[Int(node)].has(NodeFlag.directory) }
    /// Lighting asks Headroom's own sets, which answer from depth-first ranges rather than walking up from every piece.
    func branches(_ nodes: [UInt32]) -> NodeSet { NodeSet(nodes, in: self) }

    /// Free space is room, what Headroom can't read (hidden or locked) can't be looked into, a moved file drawn from its note
    /// is gone, and the rest are folders and files.
    @inline(__always) func role(of node: UInt32) -> SunburstRole {
        let n = nodes[Int(node)]
        if n.has(NodeFlag.free) { return .room }
        if n.has(NodeFlag.hidden) || n.has(NodeFlag.locked) { return .unreadable }
        if isGhost(node) { return .gone }
        if !n.has(NodeFlag.directory) && !n.has(NodeFlag.synthetic) { return .item }
        return .container
    }

    @inline(__always) func nameKey(of node: UInt32) -> UInt64 {
        let n = nodes[Int(node)]
        return n.nameLength > 0 ? RuleBook.hash(UnsafePointer(names + Int(n.nameOffset)), Int(n.nameLength)) : UInt64(node)
    }

    /// Backup's halves draw what's in the same place on both sides together.
    @inline(__always) func group(of node: UInt32) -> UInt8? { order[node] }
}

extension DiskTree {
    /// The parts Headroom draws a disk with. The whole disk has a thin band that says what it's made of (your files, apps,
    /// the system), with free space and what's hidden closing the circle. Backup's two sides are a split, thin as that band
    /// is, so the two disks frame their folders the same way; the dial counts each side from 0 to 100%, and the folders are
    /// ordered and cut by where their files are.
    func parts(_ sizes: RingSizes) -> SunburstParts {
        if twoSides { return SunburstParts(split: .band, rings: .init(sizes, order: .byGroup), dial: .init(counts: .eachSide)) }
        // While a scan is running, the big groups keep their places instead of swapping as they fill up.
        var band = SunburstParts.Band()
        if isPartial {
            let ranks = Dictionary(children(0).map { ($0, partialRank(of: $0)) }, uniquingKeysWith: { a, _ in a })
            band.order = .ranked { ranks[$0] ?? 2 }
        }
        return SunburstParts(bands: [band], rings: .init(sizes, order: order.isEmpty ? .bySize : .byGroup))
    }

    @inline(__always) func partialRank(of node: UInt32) -> Int {
        node == home ? 0 : (nodes[Int(node)].has(NodeFlag.synthetic) ? 1 : 2)
    }
}

/// What the ring shows: the disk, or the disk as it will be once the plan has run (`after`), with what goes gone and free
/// space grown. Everything else is the disk's.
struct MapTree: SunburstTree {
    let disk: DiskTree
    let after: AfterPlan?

    init(_ disk: DiskTree, after: AfterPlan? = nil) {
        self.disk = disk
        self.after = after
    }

    @inline(__always) func firstChild(of node: UInt32) -> UInt32 { disk.firstChild(of: node) }
    @inline(__always) func nextSibling(of node: UInt32) -> UInt32 { disk.nextSibling(of: node) }
    @inline(__always) func parent(of node: UInt32) -> UInt32 { disk.parent(of: node) }
    @inline(__always) func size(of node: UInt32) -> UInt64 {
        if let after { return after.size(node) }
        return disk.totals[Int(node)]
    }
    @inline(__always) func ownSize(of node: UInt32) -> UInt64 { disk.ownSize(of: node) }
    @inline(__always) func isFolder(_ node: UInt32) -> Bool { disk.isFolder(node) }
    @inline(__always) func role(of node: UInt32) -> SunburstRole { disk.role(of: node) }
    @inline(__always) func nameKey(of node: UInt32) -> UInt64 { disk.nameKey(of: node) }
    @inline(__always) func group(of node: UInt32) -> UInt8? { disk.group(of: node) }
    @inline(__always) func isInside(_ node: UInt32, _ folder: UInt32) -> Bool { disk.isInside(node, folder) }
    @inline(__always) func isStillGrowing(_ node: UInt32) -> Bool { disk.isStillGrowing(node) }
    func branches(_ nodes: [UInt32]) -> NodeSet { disk.branches(nodes) }

    /// Nothing yet: a root with nothing in it, before a disk is read.
    static let empty = MapTree(DiskTree())
}

extension RingLayout {
    /// The picture of the disk, or of the disk as it will be after the plan has run, in Headroom's parts.
    static func build(tree: DiskTree, focus: UInt32, colorer: Colorer, marked: Marker? = nil, after: AfterPlan? = nil,
                      sizes: RingSizes = .saved) -> RingLayout {
        let parts = tree.parts(sizes)
        if let after { return build(tree: MapTree(tree, after: after), focus: focus, parts: parts, colorer: colorer, marked: marked) }
        return build(tree: tree, focus: focus, parts: parts, colorer: colorer, marked: marked)
    }
}

/// Headroom's sets of things are numbered in depth-first order, so the kit's lighting asks them directly.
extension NodeSet: SunburstNodeSet {}

extension RingSizes {
    /// Picked in View › Rings and kept for the next launch. For one run only: `--args -ringDepth 8 -ringStyle adaptive`.
    static var saved: RingSizes {
        let defaults = UserDefaults.standard
        let depth = defaults.integer(forKey: depthKey)
        let style = defaults.string(forKey: styleKey).flatMap(RingStyle.init(rawValue:))
        return RingSizes(depth: depth == 0 ? RingSizes().depth : min(max(depth, 1), most), style: style ?? RingSizes().style)
    }

    /// Only what changed, so a setting given for one run isn't kept.
    func save(changedFrom old: RingSizes) {
        if depth != old.depth { UserDefaults.standard.set(depth, forKey: Self.depthKey) }
        if style != old.style { UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey) }
    }

    private static let depthKey = "ringDepth", styleKey = "ringStyle"
}
