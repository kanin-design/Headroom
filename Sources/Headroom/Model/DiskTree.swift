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
    static let gone: UInt16 = 1 << 15        // moved to the Trash since this was read
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

extension UInt32 {
    /// Seconds from 1970 as the map keeps them. Before 1970, past 2106, or not a number at all, they're held at the nearest
    /// end instead of stopping the app.
    init(seconds: Double) {
        self = seconds.isNaN || seconds <= 0 ? 0 : seconds >= Double(UInt32.max) ? .max : UInt32(seconds)
    }
}

/// A block of names. A scan and its pictures share one, and a picture can outlive the block's use by the scan.
final class NameStore: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<UInt8>
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        pointer = vmAlloc(UInt8.self, capacity)
    }

    deinit { vmFree(pointer, capacity) }
}

/// The scan's tables, kept flat and memory-mapped: they're touched only as far as they're used, their addresses
/// never move while workers write to them, and a parent's index is always lower than its children's.
final class DiskTree: @unchecked Sendable {
    static let capacity = 48_000_000
    static let namesCapacity = 3_000_000_000
    /// Fields per node in `stats`: bytes per Kind, then recency, all in units of 16 KiB. Recency is what changed in the last
    /// so many days: 1, 7, 30 and 14, then three months and a year, which say by what's left what's gone untouched. Last, how
    /// many symbolic links there are, which take no room but say where things point: Copies opens only folders that hold one.
    static let statStride = 19
    static let statRecent1 = Kind.count, statRecent7 = Kind.count + 1, statRecent30 = Kind.count + 2, statRecent14 = Kind.count + 3
    static let statRecent91 = Kind.count + 4, statRecent365 = Kind.count + 5
    static let statSymlinks = Kind.count + 6
    /// Each recency field, and how many days back it reaches.
    static let recency: [(field: Int, days: UInt32)] = [(statRecent1, 1), (statRecent7, 7), (statRecent14, 14), (statRecent30, 30),
                                                        (statRecent91, 91), (statRecent365, 365)]

    let nodes: UnsafeMutablePointer<Node>
    /// One row per node until `compactStats`, and only the different rows after it. Read it through `statRow`.
    private(set) var statTable: UnsafeMutablePointer<UInt32>
    /// Which row each node has, once there's a row for each different set of numbers.
    private var statIndex: UnsafeMutablePointer<UInt32>?
    private var statRowCapacity = 0
    private var statIndexCount = 0
    private var nextStatRow: UInt32 = 0
    /// In `statIndex`: this row is this node's alone, so it can be changed where it is.
    static let ownRow: UInt32 = 1 << 31
    let totals: UnsafeMutablePointer<UInt64>
    let totalFiles: UnsafeMutablePointer<UInt32>
    let dfsIn: UnsafeMutablePointer<UInt32>
    let dfsSize: UnsafeMutablePointer<UInt32>
    private var nameStore: NameStore
    private(set) var names: UnsafeMutablePointer<UInt8>
    /// Links and clones inside a folder that are counted somewhere else.
    let aliasTotals: UnsafeMutablePointer<UInt64>

    /// Number of nodes in use. Written by the scanner.
    var count = 0
    /// A picture of a scan that's still running: some of the disk hasn't been read yet.
    var isPartial = false
    /// The same for every picture of one scan, whose node numbers all mean the same thing.
    var scanID = UUID()
    var displayNames: [UInt32: String] = [:]
    /// Files with more than one path, by key, once the scan has finished. See `Accounting`.
    var links: [LinkRecord] = []
    /// Hard-linked files with only one of their paths on the map. A refresh reads their folders again, as it does the
    /// folders in `links`, so it always knows where each one is counted.
    var singleLinks: [LinkRecord] = []

    var finishedAt = Date()
    var scanSeconds = 0.0
    /// Every folder and big file the scan found, as it left them. Only a whole map can be the start of a refresh, and taking
    /// something out of it by hand, after a clean, makes it a picture of what's expected rather than of what was read.
    var isWhole = false
    /// Whether the folders macOS guards were read.
    var readGuarded = false
    /// Where the disk's change journal was when this was read, so a refresh can ask what has changed since.
    var journal: ChangeJournal.Place?
    /// When every folder was last read from the disk, rather than copied over from the map before.
    var fullReadAt = Date.distantPast
    /// How many bytes of names are in use, once they're packed.
    private(set) var nameBytes = 0

    // Well-known nodes.
    var home: UInt32 = 0
    var free: UInt32 = 0
    var hidden: UInt32 = 0
    var volumeName = ""
    var capacityBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var rootPath = ""

    init(sharingNamesWith owner: DiskTree? = nil) {
        nodes = vmAlloc(Node.self, Self.capacity)
        statTable = vmAlloc(UInt32.self, Self.capacity * Self.statStride)
        totals = vmAlloc(UInt64.self, Self.capacity)
        totalFiles = vmAlloc(UInt32.self, Self.capacity)
        dfsIn = vmAlloc(UInt32.self, Self.capacity)
        dfsSize = vmAlloc(UInt32.self, Self.capacity)
        nameStore = owner?.nameStore ?? NameStore(capacity: Self.namesCapacity)
        names = nameStore.pointer
        aliasTotals = vmAlloc(UInt64.self, Self.capacity)
    }

    deinit {
        vmFree(nodes, Self.capacity)
        if let statIndex {
            vmFree(statTable, statRowCapacity * Self.statStride)
            vmFree(statIndex, statIndexCount)
        } else {
            vmFree(statTable, Self.capacity * Self.statStride)
        }
        vmFree(totals, Self.capacity)
        vmFree(totalFiles, Self.capacity)
        vmFree(dfsIn, Self.capacity)
        vmFree(dfsSize, Self.capacity)
        vmFree(aliasTotals, Self.capacity)
    }

    /// A copy of where a running scan has got to. The interface only ever reads copies like this one, so everything in it
    /// (hovering, zooming, the panels) works during a scan, while the workers keep writing to the original.
    func picture() -> DiskTree {
        let copy = DiskTree(sharingNamesWith: self)
        let n = count
        memcpy(copy.nodes, nodes, n * MemoryLayout<Node>.stride)
        memcpy(copy.statTable, statTable, n * Self.statStride * MemoryLayout<UInt32>.stride)
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
        // Taken out twice, its bytes would be counted out twice.
        guard !nodes[Int(id)].has(NodeFlag.gone) else { return }
        isWhole = false
        let bytes = totals[Int(id)], files = totalFiles[Int(id)]
        let parent = nodes[Int(id)].parent
        markSubtree(id, gone: true)
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
        let gone = statRow(id)
        var i = parent
        while true {
            totals[Int(i)] = totals[Int(i)] &- min(totals[Int(i)], bytes)
            totalFiles[Int(i)] = totalFiles[Int(i)] &- min(totalFiles[Int(i)], files)
            let s = changeableStatRow(i)
            for f in 0..<Self.statStride { s[f] = s[f] &- min(s[f], gone[f]) }
            if i == 0 { break }
            i = nodes[Int(i)].parent
        }
    }

    /// Adds bytes to a node, and to everything above it.
    func add(_ bytes: UInt64, to id: UInt32) {
        isWhole = false
        nodes[Int(id)].bytes &+= bytes
        var i = id
        while true {
            totals[Int(i)] &+= bytes
            if i == 0 { break }
            i = nodes[Int(i)].parent
        }
    }

    /// Whatever walks the whole table has to know this is no longer on the disk.
    private func markSubtree(_ id: UInt32, gone: Bool) {
        if gone { nodes[Int(id)].flags |= NodeFlag.gone } else { nodes[Int(id)].flags &= ~NodeFlag.gone }
        var c = nodes[Int(id)].firstChild
        while c != 0 {
            markSubtree(c, gone: gone)
            c = nodes[Int(c)].nextSibling
        }
    }

    /// Takes bytes out of a node's own, and out of everything above it.
    func subtract(_ bytes: UInt64, from id: UInt32) {
        isWhole = false
        let amount = min(bytes, nodes[Int(id)].bytes)
        nodes[Int(id)].bytes &-= amount
        var i = id
        while true {
            totals[Int(i)] &-= min(totals[Int(i)], amount)
            if i == 0 { break }
            i = nodes[Int(i)].parent
        }
    }

    /// Puts back something taken out with `remove`: it never stopped knowing what it held.
    func restore(_ id: UInt32) {
        // Put back twice, it would be linked in after itself, and every walk of that folder would go round for ever.
        guard nodes[Int(id)].has(NodeFlag.gone) else { return }
        isWhole = false
        markSubtree(id, gone: false)
        let parent = nodes[Int(id)].parent
        let bytes = totals[Int(id)], files = totalFiles[Int(id)]
        var before: UInt32 = 0
        var c = nodes[Int(parent)].firstChild
        while c != 0, totals[Int(c)] >= bytes {
            before = c
            c = nodes[Int(c)].nextSibling
        }
        nodes[Int(id)].nextSibling = c
        if before == 0 { nodes[Int(parent)].firstChild = id } else { nodes[Int(before)].nextSibling = id }
        let back = statRow(id)
        var i = parent
        while true {
            totals[Int(i)] &+= bytes
            totalFiles[Int(i)] &+= files
            let s = changeableStatRow(i)
            for f in 0..<Self.statStride { s[f] &+= back[f] }
            if i == 0 { break }
            i = nodes[Int(i)].parent
        }
    }

    /// The folders the scan started from, by their paths. They're always among the first nodes.
    var anchors: [(path: String, id: UInt32)] {
        (0..<min(count, 64)).compactMap { i in nodes[i].has(NodeFlag.anchor) ? (rawName(UInt32(i)), UInt32(i)) : nil }
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
                // The name on disk: a path says that, even when made-up names are being shown.
                if rawName(c) == part { found = c; break }
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
        return rawName(id)
    }

    /// The name on disk, even when another one is being shown.
    func rawName(_ id: UInt32) -> String {
        let n = nodes[Int(id)]
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
        var p = HiddenNames.isOn ? HiddenNames.madeUp(path: path) : path
        if let demo = Demo.home, p == demo || p.hasPrefix(demo + "/") { return "~" + p.dropFirst(demo.count) }
        let home = NSHomeDirectory()
        let dataHome = "/System/Volumes/Data" + home
        if PathMath.isInside(p, dataHome) { p = "~" + p.dropFirst(dataHome.count) }
        else if PathMath.isInside(p, home) { p = "~" + p.dropFirst(home.count) }
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
        let s = statRow(id)
        return (0..<Kind.count).map { UInt64(s[$0]) << 14 }
    }

    func dominantKind(_ id: UInt32) -> Kind {
        let n = nodes[Int(id)]
        if !n.has(NodeFlag.directory) && !n.has(NodeFlag.synthetic) { return Kind(rawValue: n.kind) ?? .other }
        let s = statRow(id)
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

    /// Runs once after the scan: totals, kinds, recency, sorted children and subtree ranges. `totalsReady` when they've just
    /// been added up, so they aren't added up twice.
    func finish(totalsReady: Bool = false) {
        let n = count
        guard n > 0 else { return }
        if !totalsReady { sumTotals() }
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
            let from = statTable + i * stride, to = statTable + p * stride
            for f in 0..<stride { to[f] &+= from[f] }
            i -= 1
        }
        sortChildren()
        numberSubtrees()
    }

    // MARK: What a finished tree can do without

    @inline(__always) func statRow(_ id: Int) -> UnsafePointer<UInt32> {
        if let statIndex { return UnsafePointer(statTable + Int(statIndex[id] & ~Self.ownRow) * Self.statStride) }
        return UnsafePointer(statTable + id * Self.statStride)
    }

    @inline(__always) func statRow(_ id: UInt32) -> UnsafePointer<UInt32> { statRow(Int(id)) }

    /// A node's row, to write to. A row other nodes share gets a copy first.
    func changeableStatRow(_ id: UInt32) -> UnsafeMutablePointer<UInt32> {
        guard let statIndex else { return statTable + Int(id) * Self.statStride }
        let at = statIndex[Int(id)]
        if at & Self.ownRow != 0 { return statTable + Int(at & ~Self.ownRow) * Self.statStride }
        let row = nextStatRow
        nextStatRow += 1
        let target = statTable + Int(row) * Self.statStride
        target.update(from: statTable + Int(at) * Self.statStride, count: Self.statStride)
        statIndex[Int(id)] = row | Self.ownRow
        return target
    }

    /// Most folders have one of a few sets of numbers, and over half have none at all, so a finished tree keeps each
    /// different set once. Pictures of a running scan keep a row each, because the numbers still change.
    func compactStats() {
        guard statIndex == nil, count > 0 else { return }
        let n = count, width = Self.statStride
        let index = vmAlloc(UInt32.self, n)
        // Row 0 stays all zeros. Each node can also end up with one row of its own, if it's changed later.
        let rowCapacity = 2 * n + 1
        let rows = vmAlloc(UInt32.self, rowCapacity * width)
        var slots = 1024
        while slots < 2 * n { slots <<= 1 }
        let seen = vmAlloc(UInt32.self, slots)
        defer { vmFree(seen, slots) }
        var next: UInt32 = 1
        let bytes = width * MemoryLayout<UInt32>.stride
        for i in 0..<n {
            let row = UnsafeRawPointer(statTable + i * width)
            var hash: UInt64 = 0
            var anything: UInt64 = 0
            for word in 0..<(bytes / 8) {
                let value = row.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self)
                anything |= value
                hash = (hash ^ value) &* 0x9E37_79B9_7F4A_7C15
                hash ^= hash >> 29
            }
            guard anything != 0 else { continue }
            var at = Int(truncatingIfNeeded: hash) & (slots - 1)
            while true {
                let candidate = seen[at]
                if candidate == 0 {
                    (rows + Int(next) * width).update(from: statTable + i * width, count: width)
                    seen[at] = next
                    index[i] = next
                    next += 1
                    break
                }
                if memcmp(rows + Int(candidate) * width, row, bytes) == 0 {
                    index[i] = candidate
                    break
                }
                at = (at + 1) & (slots - 1)
            }
        }
        vmFree(statTable, Self.capacity * width)
        statTable = rows
        statIndex = index
        statRowCapacity = rowCapacity
        statIndexCount = n
        nextStatRow = next
    }

    /// The same few names turn up everywhere, so a finished tree keeps each one once. Pictures still on screen keep the block
    /// they were made with, which goes when they do.
    func compactNames() {
        let n = count
        var total = 0
        for i in 0..<n { total += Int(nodes[i].nameLength) }
        guard total > 0 else { return }
        let packed = NameStore(capacity: total)
        var slots = 1024
        while slots < 2 * n { slots <<= 1 }
        let seen = vmAlloc(UInt32.self, slots)
        defer { vmFree(seen, slots) }
        var used: UInt32 = 0
        for i in 0..<n {
            let length = Int(nodes[i].nameLength)
            guard length > 0 else { continue }
            let name = names + Int(nodes[i].nameOffset)
            let hash = RuleBook.hash(UnsafePointer(name), length)
            var at = Int(truncatingIfNeeded: hash ^ hash >> 32) & (slots - 1)
            var found: UInt32?
            while seen[at] != 0 {
                let other = nodes[Int(seen[at]) - 1]
                if Int(other.nameLength) == length, memcmp(packed.pointer + Int(other.nameOffset), name, length) == 0 {
                    found = other.nameOffset
                    break
                }
                at = (at + 1) & (slots - 1)
            }
            if let found {
                nodes[i].nameOffset = found
            } else {
                (packed.pointer + Int(used)).update(from: name, count: length)
                nodes[i].nameOffset = used
                used += UInt32(length)
                seen[at] = UInt32(i) + 1
            }
        }
        nameStore = packed
        names = packed.pointer
        nameBytes = Int(used)
    }

    // MARK: Saving and reading back

    /// For saving a finished tree: its different rows of numbers, and which one each node has.
    var packedStats: (rows: UnsafePointer<UInt32>, rowCount: Int, index: UnsafePointer<UInt32>)? {
        guard let statIndex else { return nil }
        return (UnsafePointer(statTable), Int(nextStatRow), UnsafePointer(statIndex))
    }

    /// For reading one back: room for its rows and its index, to be filled in, as `compactStats` would have left them.
    func roomForPackedStats(rowCount: Int, nodes n: Int) -> (rows: UnsafeMutablePointer<UInt32>, index: UnsafeMutablePointer<UInt32>) {
        vmFree(statTable, Self.capacity * Self.statStride)
        let capacity = 2 * n + rowCount + 1
        statTable = vmAlloc(UInt32.self, capacity * Self.statStride)
        let index = vmAlloc(UInt32.self, n)
        statIndex = index
        statRowCapacity = capacity
        statIndexCount = n
        nextStatRow = UInt32(rowCount)
        return (statTable, index)
    }

    /// The names of a tree read back, already packed.
    func readNames(_ bytes: Int) -> UnsafeMutablePointer<UInt8> {
        nameBytes = bytes
        return names
    }

    /// After reading a whole map back: the sums that weren't saved, because they're quicker to add up again than to read.
    func restoreSums() {
        let n = count
        guard n > 0 else { return }
        sumTotals()
        for i in 0..<n {
            totalFiles[i] = nodes[i].fileCount
            aliasTotals[i] = nodes[i].has(NodeFlag.directory) ? nodes[i].aliasBytes : 0
        }
        var i = n - 1
        while i > 0 {
            let p = Int(nodes[i].parent)
            totalFiles[p] &+= totalFiles[i]
            aliasTotals[p] &+= aliasTotals[i]
            i -= 1
        }
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
    let tree: DiskTree
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
    /// A hard link's number of paths, everywhere, as the disk said when this one was read.
    var paths: UInt16 = 0

    /// A clone's key is its clone ID with the top bit set. Any other key is a hard link's file ID.
    var isClone: Bool { key >> 63 != 0 }
}

/// A big table for one piece of work, with one plain value per node. Mapped, so all of it goes back the moment the work is
/// done, where the heap would hold on to it.
final class Mapped<T> {
    let base: UnsafeMutablePointer<T>
    let count: Int

    /// Starts out as all zeros.
    init(count: Int) {
        self.count = max(count, 1)
        base = vmAlloc(T.self, self.count)
    }

    convenience init(repeating value: T, count: Int) {
        self.init(count: count)
        base.initialize(repeating: value, count: self.count)
    }

    deinit { vmFree(base, count) }

    @inline(__always) subscript(at: Int) -> T {
        get { base[at] }
        set { base[at] = newValue }
    }

    func bytes(_ items: Int? = nil) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: base, count: (items ?? count) * MemoryLayout<T>.stride)
    }
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
