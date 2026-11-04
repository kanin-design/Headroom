import Darwin
import Foundation

enum NodeFlag {
    static let directory: UInt16 = 1 << 0
    static let denied: UInt16 = 1 << 1       // the system refused to open it
    static let locked: UInt16 = 1 << 2       // skipped until Full Disk Access is granted
    static let anchor: UInt16 = 1 << 3       // its name is an absolute path, and its display name is stored apart
    static let synthetic: UInt16 = 1 << 4    // has no path on disk: a group, a sealed volume, free space
    static let ruleRoot: UInt16 = 1 << 5     // outermost node a rule applies to
    static let mount: UInt16 = 1 << 6        // mount point, not crossed
    static let alias: UInt16 = 1 << 7        // its bytes are counted at another path (hard link or clone)
    static let free: UInt16 = 1 << 8         // the free space piece
    static let hidden: UInt16 = 1 << 9       // space the scan can't account for
    static let projects: UInt16 = 1 << 10    // your own folders, not an app, a tool's install or ~/Library
    static let later: UInt16 = 1 << 11       // read after everything else: build folders and caches
    static let unread: UInt16 = 1 << 12      // waiting to be read
    static let incomplete: UInt16 = 1 << 13  // something inside it hasn't been read yet
    static let shyLinks: UInt16 = 1 << 14    // a link found here doesn't claim the file's bytes
}

/// One folder, or one file big enough to be worth naming. Small files are summed into their folder.
struct Node {
    var parent: UInt32 = 0
    var firstChild: UInt32 = 0              // 0 means none: the root is never anyone's child
    var nextSibling: UInt32 = 0
    var nameOffset: UInt32 = 0
    var nameLength: UInt16 = 0
    var rule: UInt16 = 0                    // nearest rule at or above this node
    var ruleState: UInt8 = 0                // position in the path rule table
    var kind: UInt8 = 0                     // files only
    var flags: UInt16 = 0
    var fileCount: UInt32 = 0               // files directly inside, big or small
    var modTime: UInt32 = 0                 // newest file date directly inside, in seconds
    var bytes: UInt64 = 0                   // small files directly inside, or the file itself
    var aliasBytes: UInt64 = 0              // links and clones here that are counted elsewhere

    @inline(__always) func has(_ flag: UInt16) -> Bool { flags & flag != 0 }
}

/// The scan's tables, kept flat and memory-mapped: they're touched only as far as they're used, their addresses
/// never move while workers write to them, and a parent's index is always lower than its children's.
final class DiskTree: @unchecked Sendable {
    static let capacity = 48_000_000
    static let namesCapacity = 3_000_000_000
    /// Fields per node in `stats`: bytes per Kind, then recency, all in units of 16 KiB.
    static let statStride = 16
    static let statRecent1 = Kind.count, statRecent7 = Kind.count + 1, statRecent30 = Kind.count + 2

    let nodes: UnsafeMutablePointer<Node>
    let stats: UnsafeMutablePointer<UInt32>
    let totals: UnsafeMutablePointer<UInt64>
    let totalFiles: UnsafeMutablePointer<UInt32>
    let dfsIn: UnsafeMutablePointer<UInt32>
    let dfsSize: UnsafeMutablePointer<UInt32>
    let names: UnsafeMutablePointer<UInt8>
    /// Links and clones inside a folder that are counted somewhere else.
    let aliasTotals: UnsafeMutablePointer<UInt64>

    /// Number of nodes in use. Written by the scanner.
    var count = 0
    /// A picture of a scan that's still running: some of the disk hasn't been read yet.
    var isPartial = false
    /// The same for every picture of one scan, whose node numbers all mean the same thing.
    var scanID = UUID()
    private let namesOwner: DiskTree?
    var displayNames: [UInt32: String] = [:]
    /// Files with more than one path, by key, once the scan has finished. See `Accounting`.
    var links: [LinkRecord] = []

    var finishedAt = Date()
    var scanSeconds = 0.0

    // Well-known nodes.
    var home: UInt32 = 0
    var free: UInt32 = 0
    var hidden: UInt32 = 0
    var volumeName = ""
    var capacityBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var rootPath = ""

    init(sharingNamesWith owner: DiskTree? = nil) {
        namesOwner = owner
        nodes = vmAlloc(Node.self, Self.capacity)
        stats = vmAlloc(UInt32.self, Self.capacity * Self.statStride)
        totals = vmAlloc(UInt64.self, Self.capacity)
        totalFiles = vmAlloc(UInt32.self, Self.capacity)
        dfsIn = vmAlloc(UInt32.self, Self.capacity)
        dfsSize = vmAlloc(UInt32.self, Self.capacity)
        names = owner?.names ?? vmAlloc(UInt8.self, Self.namesCapacity)
        aliasTotals = vmAlloc(UInt64.self, Self.capacity)
    }

    deinit {
        vmFree(nodes, Self.capacity)
        vmFree(stats, Self.capacity * Self.statStride)
        vmFree(totals, Self.capacity)
        vmFree(totalFiles, Self.capacity)
        vmFree(dfsIn, Self.capacity)
        vmFree(dfsSize, Self.capacity)
        if namesOwner == nil { vmFree(names, Self.namesCapacity) }
        vmFree(aliasTotals, Self.capacity)
    }

    /// A copy of where a running scan has got to. The interface only ever reads copies like this one, so everything in it
    /// (hovering, zooming, the panels) works during a scan, while the workers keep writing to the original.
    func picture() -> DiskTree {
        let copy = DiskTree(sharingNamesWith: self)
        let n = count
        memcpy(copy.nodes, nodes, n * MemoryLayout<Node>.stride)
        memcpy(copy.stats, stats, n * Self.statStride * MemoryLayout<UInt32>.stride)
        // A folder finishing during the copy can already point at children past the end of it. And until a folder is read,
        // its file count is really how many entries it has.
        for i in 0..<n {
            if copy.nodes[i].firstChild >= n { copy.nodes[i].firstChild = 0 }
            if copy.nodes[i].flags & NodeFlag.unread != 0 { copy.nodes[i].fileCount = 0 }
        }
        copy.count = n
        copy.isPartial = true
        copy.scanID = scanID
        copy.displayNames = displayNames
        copy.home = home
        copy.free = free
        copy.hidden = hidden
        copy.volumeName = volumeName
        copy.capacityBytes = capacityBytes
        copy.freeBytes = freeBytes
        copy.rootPath = rootPath
        return copy
    }

    /// Whether this size may still grow, because something inside hasn't been read yet.
    @inline(__always) func isStillGrowing(_ id: UInt32) -> Bool {
        nodes[Int(id)].flags & (NodeFlag.unread | NodeFlag.incomplete) != 0
    }

    /// A size as it should read on screen. The dots mean there's more to come.
    func sizeText(_ id: UInt32) -> String {
        formatBytes(totals[Int(id)]) + (isStillGrowing(id) ? "…" : "")
    }

    /// Takes a removed folder or file out of the sums, so the ring can update at once without a new scan.
    func remove(_ id: UInt32) {
        let bytes = totals[Int(id)], files = totalFiles[Int(id)]
        let parent = nodes[Int(id)].parent
        var c = nodes[Int(parent)].firstChild
        if c == id {
            nodes[Int(parent)].firstChild = nodes[Int(id)].nextSibling
        } else {
            while c != 0 {
                let next = nodes[Int(c)].nextSibling
                if next == id { nodes[Int(c)].nextSibling = nodes[Int(id)].nextSibling; break }
                c = next
            }
        }
        let gone = stats + Int(id) * Self.statStride
        var i = parent
        while true {
            totals[Int(i)] = totals[Int(i)] &- min(totals[Int(i)], bytes)
            totalFiles[Int(i)] = totalFiles[Int(i)] &- min(totalFiles[Int(i)], files)
            let s = stats + Int(i) * Self.statStride
            for f in 0..<Self.statStride { s[f] = s[f] &- min(s[f], gone[f]) }
            if i == 0 { break }
            i = nodes[Int(i)].parent
        }
    }

    /// Adds bytes to a node, and to everything above it.
    func add(_ bytes: UInt64, to id: UInt32) {
        nodes[Int(id)].bytes &+= bytes
        var i = id
        while true {
            totals[Int(i)] &+= bytes
            if i == 0 { break }
            i = nodes[Int(i)].parent
        }
    }

    /// Finds a node by its absolute path, by walking down from the scan roots.
    func find(path: String) -> UInt32? {
        var best: UInt32?
        var bestLength = 0
        for i in 0..<min(count, 64) where nodes[i].has(NodeFlag.anchor) {
            let raw = String(decoding: UnsafeBufferPointer(start: names + Int(nodes[i].nameOffset), count: Int(nodes[i].nameLength)), as: UTF8.self)
            if (path == raw || path.hasPrefix(raw + "/")) && raw.count > bestLength {
                best = UInt32(i)
                bestLength = raw.count
            }
        }
        guard var at = best else { return nil }
        let rest = path.dropFirst(bestLength).split(separator: "/")
        for part in rest {
            var c = nodes[Int(at)].firstChild
            var found: UInt32?
            while c != 0 {
                if name(c) == part { found = c; break }
                c = nodes[Int(c)].nextSibling
            }
            guard let found else { return nil }
            at = found
        }
        return at
    }

    // MARK: Reading

    func name(_ id: UInt32) -> String {
        if let display = displayNames[id] { return display }
        let n = nodes[Int(id)]
        guard n.nameLength > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: names + Int(n.nameOffset), count: Int(n.nameLength)), as: UTF8.self)
    }

    /// Absolute path on disk, or nil for a piece that has none.
    func path(_ id: UInt32) -> String? {
        var parts: [String] = []
        var i = id
        while true {
            let n = nodes[Int(i)]
            if n.has(NodeFlag.synthetic) { return nil }
            let raw = String(decoding: UnsafeBufferPointer(start: names + Int(n.nameOffset), count: Int(n.nameLength)), as: UTF8.self)
            parts.append(raw)
            if n.has(NodeFlag.anchor) { break }
            i = n.parent
        }
        return parts.reversed().joined(separator: "/")
    }

    /// The path as you'd say it: `~/Downloads`, `/Library`.
    func friendlyPath(_ id: UInt32) -> String {
        guard let path = path(id) else { return name(id) }
        return Self.friendly(path)
    }

    static func friendly(_ path: String) -> String {
        var p = path
        let home = NSHomeDirectory()
        let dataHome = "/System/Volumes/Data" + home
        if p.hasPrefix(dataHome) { p = "~" + p.dropFirst(dataHome.count) }
        else if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        else if p.hasPrefix("/System/Volumes/Data/") { p = String(p.dropFirst("/System/Volumes/Data".count)) }
        return p
    }

    func children(_ id: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        var c = nodes[Int(id)].firstChild
        while c != 0 {
            out.append(c)
            c = nodes[Int(c)].nextSibling
        }
        return out
    }

    @inline(__always) func isInside(_ id: UInt32, _ ancestor: UInt32) -> Bool {
        dfsIn[Int(id)] &- dfsIn[Int(ancestor)] < dfsSize[Int(ancestor)]
    }

    func kindBytes(_ id: UInt32) -> [UInt64] {
        let s = stats + Int(id) * Self.statStride
        return (0..<Kind.count).map { UInt64(s[$0]) << 14 }
    }

    func dominantKind(_ id: UInt32) -> Kind {
        let n = nodes[Int(id)]
        if !n.has(NodeFlag.directory) && !n.has(NodeFlag.synthetic) { return Kind(rawValue: n.kind) ?? .other }
        let s = stats + Int(id) * Self.statStride
        var best = 0
        var bestValue: UInt32 = 0
        for k in 0..<Kind.count where s[k] > bestValue { best = k; bestValue = s[k] }
        return bestValue == 0 ? (Kind(rawValue: n.kind) ?? .other) : (Kind(rawValue: UInt8(best)) ?? .other)
    }

    func ancestors(of id: UInt32) -> [UInt32] {
        var out: [UInt32] = []
        var i = id
        while i != 0 { out.append(i); i = nodes[Int(i)].parent }
        out.append(0)
        return out.reversed()
    }

    // MARK: Summing up

    /// Sums every node into its parent. Fast enough to run many times during a scan, because parents come first.
    func sumTotals() {
        let n = count
        guard n > 0 else { return }
        for i in 0..<n { totals[i] = nodes[i].bytes }
        var i = n - 1
        while i > 0 {
            totals[Int(nodes[i].parent)] &+= totals[i]
            i -= 1
        }
    }

    /// Runs once after the scan: totals, kinds, recency, sorted children and subtree ranges.
    func finish() {
        let n = count
        guard n > 0 else { return }
        sumTotals()
        let stride = Self.statStride
        for i in 0..<n {
            totalFiles[i] = nodes[i].fileCount
            aliasTotals[i] = nodes[i].has(NodeFlag.directory) ? nodes[i].aliasBytes : 0
        }
        var i = n - 1
        while i > 0 {
            let p = Int(nodes[i].parent)
            totalFiles[p] &+= totalFiles[i]
            aliasTotals[p] &+= aliasTotals[i]
            if nodes[i].flags & (NodeFlag.unread | NodeFlag.incomplete) != 0 { nodes[p].flags |= NodeFlag.incomplete }
            let from = stats + i * stride, to = stats + p * stride
            for f in 0..<stride { to[f] &+= from[f] }
            i -= 1
        }
        sortChildren()
        numberSubtrees()
    }

    func sortChildren() {
        let n = count
        var scratch: [UInt32] = []
        scratch.reserveCapacity(4096)
        for i in 0..<n {
            var c = nodes[i].firstChild
            if c == 0 || nodes[Int(c)].nextSibling == 0 { continue }
            scratch.removeAll(keepingCapacity: true)
            while c != 0 { scratch.append(c); c = nodes[Int(c)].nextSibling }
            let t = totals
            scratch.sort { t[Int($0)] > t[Int($1)] }
            nodes[i].firstChild = scratch[0]
            for k in 0..<(scratch.count - 1) { nodes[Int(scratch[k])].nextSibling = scratch[k + 1] }
            nodes[Int(scratch[scratch.count - 1])].nextSibling = 0
        }
    }

    func numberSubtrees() {
        let n = count
        for i in 0..<n { dfsSize[i] = 1 }
        var i = n - 1
        while i > 0 {
            dfsSize[Int(nodes[i].parent)] &+= dfsSize[i]
            i -= 1
        }
        // A parent knows its own position, so each child's follows from the sizes of the siblings before it.
        dfsIn[0] = 0
        for p in 0..<n {
            var next = dfsIn[p] &+ 1
            var c = nodes[p].firstChild
            while c != 0 {
                dfsIn[Int(c)] = next
                next &+= dfsSize[Int(c)]
                c = nodes[Int(c)].nextSibling
            }
        }
    }
}

/// A set of folders, asked "is this inside one of them?" many times over. A group row can hold thousands of folders and
/// the disk hundreds of thousands of links, so this is a binary search over subtree positions, not a list to walk.
struct NodeSet {
    private let tree: DiskTree
    private(set) var tops: [UInt32] = []

    init(_ ids: [UInt32], in tree: DiskTree) {
        self.tree = tree
        for id in ids.sorted(by: { tree.dfsIn[Int($0)] < tree.dfsIn[Int($1)] }) {
            if let last = tops.last, tree.isInside(id, last) { continue }
            tops.append(id)
        }
    }

    @inline(__always) func contains(_ node: UInt32) -> Bool {
        let position = tree.dfsIn[Int(node)]
        var low = 0, high = tops.count
        while low < high {
            let mid = (low + high) / 2
            if tree.dfsIn[Int(tops[mid])] <= position { low = mid + 1 } else { high = mid }
        }
        return low > 0 && tree.isInside(node, tops[low - 1])
    }
}

/// One path of a file that has several, or one of a set of APFS clones.
struct LinkRecord {
    var key: UInt64
    var bytes: UInt64
    var dir: UInt32
    var file: UInt32           // its own node if it was big enough to get one, otherwise 0
    var when: UInt32
    var kind: UInt8
    var counted: Bool
}

func vmAlloc<T>(_ type: T.Type, _ capacity: Int) -> UnsafeMutablePointer<T> {
    let bytes = capacity * MemoryLayout<T>.stride
    guard let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0),
          p != UnsafeMutableRawPointer(bitPattern: -1) else { fatalError("out of address space") }
    return p.bindMemory(to: T.self, capacity: capacity)
}

func vmFree<T>(_ p: UnsafeMutablePointer<T>, _ capacity: Int) {
    munmap(UnsafeMutableRawPointer(p), capacity * MemoryLayout<T>.stride)
}
