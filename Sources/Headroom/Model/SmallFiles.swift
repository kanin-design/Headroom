import Darwin
import Foundation
import Synchronization

/// Files under 1 MiB aren't on the map: a disk has millions of them, and their names alone would take more memory than the
/// whole map. So the scan writes their names down as it reads each folder, in a catalogue of its own on disk, and a search
/// reads them from there without copying them into memory. macOS keeps what's searched in its file cache, and frees that
/// when anything else needs the room.
///
/// The catalogue is two files per disk, in Caches. One holds the names, a block per folder: how many, each one's size in
/// KB, then the names, each ended by a zero. Blocks are only ever added to it, so a refresh adds blocks for the folders it
/// reads again, and the folders it copies keep theirs. The other is the index for one map: for each of its nodes, where
/// that folder's block starts in the names, or 0.
enum SmallFiles {
    /// The same line the scanner draws: from here up, a file is on the map.
    static let limit: UInt64 = 1 << 20
    /// How many a search lists.
    static let shown = 120
    /// How many stretches a search reads at once. More answer sooner, but add more work than they save time.
    static let slices = 4
    /// Up to how many matches a search keeps, so that text typed on from it looks only among them.
    static let kept = 20_000

    /// The app's own folder in Caches. A scripted check keeps its catalogues apart, as it keeps its data (`AppData`).
    static let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var url = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Headroom", isDirectory: true)
        if ScriptRunner.path != nil { url.appendPathComponent("Headroom-check", isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func namesURL(_ volume: String, in folder: URL = folder) -> URL {
        folder.appendingPathComponent("small-" + History.safe(volume) + ".names")
    }
    static func indexURL(_ volume: String, in folder: URL = folder) -> URL {
        folder.appendingPathComponent("small-" + History.safe(volume) + ".index")
    }

    /// Every disk's catalogue, when it's turned off.
    static func removeAll(in folder: URL = folder) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("small-") { try? FileManager.default.removeItem(at: file) }
    }

    fileprivate static let namesMagic: UInt64 = 0x4852_534D_4C4E_3031
    fileprivate static let indexMagic: UInt64 = 0x4852_534D_4C49_3031
    /// The names file starts with its magic and its own random number, which the index names.
    fileprivate static let namesHeader = 16
    fileprivate static let indexHeader = 64
    /// What a map is known by: when it was finished, and how many nodes it has.
    fileprivate static func stamp(_ tree: DiskTree) -> UInt64 { tree.finishedAt.timeIntervalSince1970.bitPattern }

    /// The top bit of each byte in a word.
    static let tops: UInt64 = 0x8080_8080_8080_8080

    /// The top bit of each zero byte among a word's first few (1 to 8), as they lie in memory. Exact: no carry runs from
    /// one byte into the next.
    @inline(__always) static func zeros(in word: UInt64, first n: Int) -> UInt64 {
        let rest = ~tops
        let z = ~(((word & rest) &+ rest) | word | rest)
        return n >= 8 ? z : z & ((1 &<< UInt64(8 &* n)) &- 1)
    }

    /// How many bytes a folder's block takes, from its first eight.
    @inline(__always) fileprivate static func blockSize(_ p: UnsafeRawPointer) -> Int {
        let count = Int(p.load(as: UInt32.self)), nameBytes = Int(p.load(fromByteOffset: 4, as: UInt32.self))
        return (8 + 2 * count + nameBytes + 7) & ~7
    }
}

/// A file a search found.
struct SmallFile: Hashable, Sendable {
    /// The folder it's in, on the map it was found for, and the path of that folder.
    let folder: UInt32
    let folderPath: String
    let name: String
    let bytes: UInt64
    /// What it is by its extension, for its colour.
    let kind: Kind
    /// The folder on the ring: the same one, unless both disks are drawn, which number their halves anew.
    var onScreen: UInt32
}

/// Why the small files aren't listed.
enum SmallFilesGap {
    /// The map on screen has no catalogue yet.
    case notRead
    /// The folder in view is on the backup drive, whose files aren't catalogued.
    case onDrive
}

/// What a search found among the small files: how many, and the biggest.
struct SmallFileResults: Sendable {
    var count = 0
    var top: [SmallFile] = []
    /// Every match, when there are few enough to keep.
    fileprivate var kept: KeptMatches?
}

/// A search's matches, and what they were found for: text that holds this text can only be in these names.
private struct KeptMatches: Sendable {
    let text: String
    let scope: UInt32
    let catalogue: UInt64
    let hits: [Hit]

    /// Whether a search for this text, here, can look only among them.
    func cover(_ wanted: String, scope: UInt32, catalogue: UInt64) -> Bool {
        scope == self.scope && catalogue == self.catalogue && Search.narrows(wanted, from: text)
    }
}

/// A match: the file's size in KB, its folder, and where in the names it matched, which is a byte of its name: enough to
/// order it and to find the name again.
private struct Hit: Sendable {
    var kb: UInt16
    var folder: UInt32
    var at: UInt64
    /// Bigger first, then in the order they were written, so the same search always lists the same files.
    static func isBefore(_ a: Hit, _ b: Hit) -> Bool { a.kb != b.kb ? a.kb > b.kb : a.at < b.at }
}

/// Set from anywhere, read by a search between folders.
final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var isSet: Bool { flag.load(ordering: .relaxed) }
    func set() { flag.store(true, ordering: .relaxed) }
}

/// A file mapped into memory to be read. Its pages are the file's own, so they cost the app nothing it has to keep.
private final class MappedFile: @unchecked Sendable {
    let base: UnsafeRawPointer
    let length: Int

    init?(_ url: URL, minimum: Int) {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_size) >= minimum, info.st_size > 0,
            let p = mmap(nil, Int(info.st_size), PROT_READ, MAP_SHARED, fd, 0), p != UnsafeMutableRawPointer(bitPattern: -1)
        else { return nil }
        base = UnsafeRawPointer(p)
        length = Int(info.st_size)
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), length) }
}

/// One map's catalogue of its small files, mapped from its two files.
final class SmallFileCatalogue: @unchecked Sendable {
    let volume: String
    fileprivate let names: MappedFile
    fileprivate let index: MappedFile
    fileprivate let storeID: UInt64
    /// How far the names went when this was written, and how far they went at the last full read.
    fileprivate let namesLength: UInt64
    fileprivate let baseline: UInt64
    private let stamp: UInt64
    /// Nodes in the map it was written for.
    let count: Int
    /// Files in it.
    let files: UInt64
    /// What it's known by: its names and its map.
    private var identity: UInt64 { storeID ^ stamp }

    private init?(volume: String, names: MappedFile, index: MappedFile) {
        let h = index.base
        guard index.length >= SmallFiles.indexHeader, h.load(as: UInt64.self) == SmallFiles.indexMagic else { return nil }
        let count = Int(h.load(fromByteOffset: 16, as: UInt64.self))
        let namesLength = h.load(fromByteOffset: 32, as: UInt64.self)
        let storeID = h.load(fromByteOffset: 8, as: UInt64.self)
        guard count > 0, count < DiskTree.capacity, index.length >= SmallFiles.indexHeader + count * 4, namesLength <= UInt64(names.length),
            names.length >= SmallFiles.namesHeader, names.base.load(as: UInt64.self) == SmallFiles.namesMagic,
            names.base.load(fromByteOffset: 8, as: UInt64.self) == storeID
        else { return nil }
        self.volume = volume
        self.names = names
        self.index = index
        self.storeID = storeID
        self.count = count
        self.namesLength = namesLength
        stamp = h.load(fromByteOffset: 24, as: UInt64.self)
        baseline = h.load(fromByteOffset: 40, as: UInt64.self)
        files = h.load(fromByteOffset: 48, as: UInt64.self)
    }

    /// The catalogue written for this map, if there is one.
    static func load(volume: String, for tree: DiskTree, in folder: URL = SmallFiles.folder) -> SmallFileCatalogue? {
        guard let index = MappedFile(SmallFiles.indexURL(volume, in: folder), minimum: SmallFiles.indexHeader),
            let names = MappedFile(SmallFiles.namesURL(volume, in: folder), minimum: SmallFiles.namesHeader),
            let catalogue = SmallFileCatalogue(volume: volume, names: names, index: index), catalogue.matches(tree)
        else { return nil }
        return catalogue
    }

    /// Whether it was written for this map: its node numbers are the map's.
    func matches(_ tree: DiskTree) -> Bool {
        // The saved map's time comes back from text, so to the millisecond.
        tree.count == count && abs(Double(bitPattern: stamp) - tree.finishedAt.timeIntervalSince1970) < 0.001 && tree.volumeName == volume
    }

    /// Has both files read into memory, so that a search about to start doesn't wait on the disk. It takes some
    /// milliseconds, so not on the main thread.
    func warm() {
        madvise(UnsafeMutableRawPointer(mutating: names.base), names.length, MADV_WILLNEED)
        madvise(UnsafeMutableRawPointer(mutating: index.base), index.length, MADV_WILLNEED)
    }

    /// Where a folder's block starts in the names, in eighths, or 0.
    @inline(__always) fileprivate func entry(_ id: Int) -> UInt32 {
        index.base.load(fromByteOffset: SmallFiles.indexHeader + id * 4, as: UInt32.self)
    }

    /// Names holding the text, biggest first. Capitals don't matter, for any alphabet, as on the map. With a folder, only
    /// what's in it and in the folders inside it. Nil when stopped.
    /// With what an earlier search found, text that holds its text looks only among its matches, when it kept them.
    func search(
        _ query: String, in tree: DiskTree, within folder: UInt32 = 0, after earlier: SmallFileResults? = nil, stop: StopFlag
    ) -> SmallFileResults? {
        let wanted = query.precomposedStringWithCanonicalMapping.lowercased()
        let needle = Array(wanted.utf8).filter { $0 != 0 }
        guard !needle.isEmpty else { return SmallFileResults() }
        // A small letter matches both cases of itself with 0x20 added to the name's byte; anything else must be equal.
        let fold = needle.map { $0 &- 0x61 < 26 ? UInt8(0x20) : 0 }
        let n = min(count, tree.count)
        let scope = Int(folder) < n ? folder : 0
        if let kept = earlier?.kept, kept.cover(wanted, scope: scope, catalogue: identity) {
            return narrow(kept.hits, to: wanted, needle, fold, scope: scope, in: tree, stop: stop)
        }
        let slices = SmallFiles.slices
        let found = UnsafeMutableBufferPointer<Slice>.allocate(capacity: slices)
        found.initialize(repeating: Slice())
        defer { found.deinitialize().deallocate() }
        let nodes = tree.nodes
        needle.withUnsafeBufferPointer { needle in
            fold.withUnsafeBufferPointer { fold in
                DispatchQueue.concurrentPerform(iterations: slices) { s in
                    var slice = Slice()
                    for id in (n * s / slices)..<(n * (s + 1) / slices) {
                        if id & 1023 == 0, stop.isSet { return }
                        let at = Int(entry(id)) * 8
                        if at == 0 || at + 8 > Int(namesLength) { continue }
                        if scope != 0, !tree.isInside(UInt32(id), scope) { continue }
                        search(names.base + at, in: UInt32(id), nodes: nodes, needle: needle, fold: fold, wanted: wanted, into: &slice)
                    }
                    found[s] = slice
                }
            }
        }
        if stop.isSet { return nil }
        var results = SmallFileResults()
        var best = Top(SmallFiles.shown)
        for slice in found {
            results.count += slice.count
            for hit in slice.top.items { best.offer(hit) }
        }
        results.top = listed(best, in: tree)
        if results.count <= SmallFiles.kept {
            let hits = found.flatMap(\.kept)
            results.kept = KeptMatches(text: wanted, scope: scope, catalogue: identity, hits: hits)
        }
        return results
    }

    /// Only among an earlier search's matches: each name looked at again for the longer text, and what's been trashed
    /// since left out.
    private func narrow(
        _ earlier: [Hit], to wanted: String, _ needle: [UInt8], _ fold: [UInt8], scope: UInt32, in tree: DiskTree, stop: StopFlag
    ) -> SmallFileResults? {
        let nodes = tree.nodes
        let plain = needle.allSatisfy { $0 < 0x80 }
        var results = SmallFileResults()
        var best = Top(SmallFiles.shown)
        var hits: [Hit] = []
        for (k, hit) in earlier.enumerated() {
            if k & 1023 == 0, stop.isSet { return nil }
            guard nodes[Int(hit.folder)].flags & NodeFlag.gone == 0 else { continue }
            let (p, length) = name(around: hit)
            let holds =
                plain
                ? Self.holds(needle, fold, in: p, length: length)
                : String(decoding: UnsafeBufferPointer(start: p, count: length), as: UTF8.self).precomposedStringWithCanonicalMapping
                    .lowercased().contains(wanted)
            guard holds else { continue }
            results.count += 1
            best.offer(hit)
            hits.append(hit)
        }
        results.top = listed(best, in: tree)
        results.kept = KeptMatches(text: wanted, scope: scope, catalogue: identity, hits: hits)
        return results
    }

    /// Whether a name holds plain text, capitals or not.
    private static func holds(_ needle: [UInt8], _ fold: [UInt8], in p: UnsafePointer<UInt8>, length: Int) -> Bool {
        let m = needle.count
        guard length >= m else { return false }
        for at in 0...(length - m) {
            var j = 0
            while j < m, p[at + j] | fold[j] == needle[j] { j += 1 }
            if j == m { return true }
        }
        return false
    }

    /// The biggest found, as files to list.
    private func listed(_ best: Top, in tree: DiskTree) -> [SmallFile] {
        best.items.sorted(by: Hit.isBefore).map { hit in
            let (p, length) = name(around: hit)
            let name = String(decoding: UnsafeBufferPointer(start: p, count: length), as: UTF8.self)
            let kind = Kind(rawValue: ExtensionTable.shared.kind(name: p, length: length)) ?? .other
            let path = tree.path(hit.folder).map(PathMath.visible) ?? ""
            return SmallFile(folder: hit.folder, folderPath: path, name: name, bytes: UInt64(hit.kb) << 10, kind: kind, onScreen: hit.folder)
        }
    }

    /// The whole name a hit is in: back to the zero before it, or its block's first name, and on to the zero after it.
    private func name(around hit: Hit) -> (UnsafePointer<UInt8>, Int) {
        let block = names.base + Int(entry(Int(hit.folder))) * 8
        let first = (block + 8 + 2 * Int(block.load(as: UInt32.self))).assumingMemoryBound(to: UInt8.self)
        let end = names.base.assumingMemoryBound(to: UInt8.self) + Int(namesLength)
        var from = names.base.assumingMemoryBound(to: UInt8.self) + Int(hit.at)
        while from > first && from[-1] != 0 { from -= 1 }
        var to = from
        while to < end && to[0] != 0 { to += 1 }
        return (from, to - from)
    }

    /// What one stretch of folders found: how many, the biggest, and all of them while there are few.
    private struct Slice {
        var count = 0
        var top = Top(SmallFiles.shown)
        var kept: [Hit] = []
    }

    /// The biggest few, in a heap with the smallest of them on top.
    private struct Top {
        private(set) var items: [Hit] = []
        let size: Int

        init(_ size: Int) { self.size = size }

        mutating func offer(_ hit: Hit) {
            if items.count < size {
                items.append(hit)
                var i = items.count - 1
                while i > 0 {
                    let up = (i - 1) / 2
                    guard Hit.isBefore(items[up], items[i]) else { break }
                    items.swapAt(up, i)
                    i = up
                }
            } else if Hit.isBefore(hit, items[0]) {
                items[0] = hit
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var low = i
                    if l < items.count && Hit.isBefore(items[low], items[l]) { low = l }
                    if r < items.count && Hit.isBefore(items[low], items[r]) { low = r }
                    if low == i { break }
                    items.swapAt(low, i)
                    i = low
                }
            }
        }
    }

    /// One folder's block. Plain ASCII text is found by its first and last byte, sixteen places at a time, then checked in
    /// full; text with any other letter needs each name as text, as on the map (`Search`).
    @inline(__always)
    private func search(
        _ block: UnsafeRawPointer, in folder: UInt32, nodes: UnsafeMutablePointer<Node>, needle: UnsafeBufferPointer<UInt8>,
        fold: UnsafeBufferPointer<UInt8>, wanted: String, into slice: inout Slice
    ) {
        let count = Int(block.load(as: UInt32.self)), nameBytes = Int(block.load(fromByteOffset: 4, as: UInt32.self))
        let sizes = block + 8
        let start = block + 8 + 2 * count
        let p = start.assumingMemoryBound(to: UInt8.self)
        let offset = start - names.base
        guard nameBytes > 0, offset + nameBytes <= Int(namesLength) else { return }
        // The i-th name, matched at q.
        func record(_ i: Int, _ q: Int) {
            // Trashed since it was read: not on the disk to be found.
            guard i < count, nodes[Int(folder)].flags & NodeFlag.gone == 0 else { return }
            slice.count += 1
            let hit = Hit(kb: sizes.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self), folder: folder, at: UInt64(offset + q))
            slice.top.offer(hit)
            if slice.kept.count < SmallFiles.kept { slice.kept.append(hit) }
        }
        let m = needle.count
        guard needle.allSatisfy({ $0 < 0x80 }) else {
            // Only a name with a byte beyond ASCII can hold such text, and most folders have none: they're passed over
            // sixteen bytes at a time.
            var at = 0
            while at &+ 16 <= nameBytes,
                (start.loadUnaligned(fromByteOffset: at, as: UInt64.self) | start.loadUnaligned(fromByteOffset: at &+ 8, as: UInt64.self))
                    & SmallFiles.tops == 0
            {
                at &+= 16
            }
            while at < nameBytes, p[at] < 0x80 { at &+= 1 }
            guard at < nameBytes else { return }
            at = 0
            var i = 0
            while at < nameBytes {
                var to = at, wide = false
                while to < nameBytes && p[to] != 0 {
                    if p[to] >= 0x80 { wide = true }
                    to += 1
                }
                if wide,
                    String(decoding: UnsafeBufferPointer(start: p + at, count: to - at), as: UTF8.self).precomposedStringWithCanonicalMapping
                        .lowercased().contains(wanted)
                {
                    record(i, at)
                }
                at = to + 1
                i += 1
            }
            return
        }
        // The last place a match can start, and how far sixteen bytes can be read from here: past this block's names
        // are the next block's, up to what the catalogue wrote.
        let last = nameBytes - m
        guard last >= 0 else { return }
        let readable = Int(namesLength) - offset
        let first = needle[0], firstFold = fold[0], end = needle[m - 1], endFold = fold[m - 1]
        let n0 = SIMD16(repeating: first), f0 = SIMD16(repeating: firstFold)
        let n1 = SIMD16(repeating: end), f1 = SIMD16(repeating: endFold)
        // Names counted so far, up to where; and where the last name found ends.
        var i = 0, counted = 0, skip = 0
        var at = 0
        while at <= last {
            // A bit at the top of each byte of each half where the text could start.
            var low: UInt64 = 0, high: UInt64 = 0
            if at &+ 15 &+ m <= readable {
                let a = start.loadUnaligned(fromByteOffset: at, as: SIMD16<UInt8>.self)
                let b = start.loadUnaligned(fromByteOffset: at &+ m &- 1, as: SIMD16<UInt8>.self)
                let halves = unsafeBitCast(((a | f0) .== n0) .& ((b | f1) .== n1), to: SIMD2<UInt64>.self)
                low = halves[0] & SmallFiles.tops
                high = halves[1] & SmallFiles.tops
            } else {
                // The end of the catalogue: a byte at a time.
                for k in 0..<16 where at &+ k <= last && p[at &+ k] | firstFold == first && p[at &+ k &+ m &- 1] | endFold == end {
                    if k < 8 { low |= 0x80 &<< UInt64(8 &* k) } else { high |= 0x80 &<< UInt64(8 &* (k &- 8)) }
                }
            }
            while low | high != 0 {
                let q: Int
                if low != 0 {
                    q = at &+ low.trailingZeroBitCount >> 3
                    low &= low &- 1
                } else {
                    q = at &+ 8 &+ high.trailingZeroBitCount >> 3
                    high &= high &- 1
                }
                if q > last { break }
                if q < skip { continue }
                // The text holds no zero, so a match never runs from one name into the next.
                var j = 1
                while j < m - 1, p[q &+ j] | fold[j] == needle[j] { j &+= 1 }
                guard j >= m - 1 else { continue }
                // Which name it is: the zeros before it, eight bytes at a time.
                while counted &+ 8 <= q {
                    i &+= SmallFiles.zeros(in: start.loadUnaligned(fromByteOffset: counted, as: UInt64.self), first: 8).nonzeroBitCount
                    counted &+= 8
                }
                if counted < q, counted &+ 8 <= readable {
                    i &+= SmallFiles.zeros(in: start.loadUnaligned(fromByteOffset: counted, as: UInt64.self), first: q &- counted).nonzeroBitCount
                } else {
                    for k in counted..<max(counted, q) where p[k] == 0 { i &+= 1 }
                }
                record(i, q)
                // On past the zero that ends it.
                var to = q &+ m
                while to &+ 8 <= readable {
                    let z = SmallFiles.zeros(in: start.loadUnaligned(fromByteOffset: to, as: UInt64.self), first: 8)
                    if z != 0 {
                        to &+= z.trailingZeroBitCount >> 3
                        break
                    }
                    to &+= 8
                }
                to = min(to, nameBytes)
                while to < nameBytes && p[to] != 0 { to &+= 1 }
                i &+= 1
                counted = to &+ 1
                skip = counted
            }
            at = max(at &+ 16, skip)
        }
    }
}

/// Writes one scan's catalogue. Each scan worker has a lane of its own, which gathers a folder's names as they're read and
/// sends blocks to the file a megabyte at a time, so workers never wait on each other and the file is written in a few
/// hundred calls. A refresh adds to the names its map's catalogue has, unless they've grown to twice what a full read left:
/// then it starts new ones, copying the blocks of the folders it doesn't read.
final class SmallFileWriter: @unchecked Sendable {
    private let volume: String
    private let folder: URL
    private let base: SmallFileCatalogue?
    private let appending: Bool
    private let storeID: UInt64
    private let fd: Int32
    private let target: URL
    private let end: Atomic<UInt64>
    private let failed = Atomic<Bool>(false)
    private let files = Atomic<UInt64>(0)
    /// For each node, where its folder's block starts, in eighths. Mapped, as the tree's own tables are: only what's used
    /// takes memory, and all of it goes when the scan does.
    private var index: UnsafeMutablePointer<UInt32>?
    private var closed = false

    /// A new catalogue, or, with the one written for the map a refresh starts from, the next one after it.
    init?(volume: String, refreshing base: SmallFileCatalogue?, in folder: URL = SmallFiles.folder) {
        self.volume = volume
        self.folder = folder
        let names = SmallFiles.namesURL(volume, in: folder)
        // Added to since the last full read by as much as that read wrote: start again, keeping only what's still used.
        if let base, base.namesLength <= 2 * base.baseline + (16 << 20), let (fd, length) = Self.openToAdd(names, id: base.storeID) {
            self.fd = fd
            self.base = base
            appending = true
            storeID = base.storeID
            target = names
            end = Atomic((length + 7) & ~7)
        } else {
            target = names.appendingPathExtension("new")
            let fd = open(target.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return nil }
            var header: [UInt64] = [SmallFiles.namesMagic, UInt64.random(in: 1...UInt64.max)]
            guard header.withUnsafeMutableBytes({ pwrite(fd, $0.baseAddress, 16, 0) }) == 16 else {
                close(fd)
                unlink(target.path)
                return nil
            }
            self.fd = fd
            self.base = base
            appending = false
            storeID = header[1]
            end = Atomic(UInt64(SmallFiles.namesHeader))
        }
        index = vmAlloc(UInt32.self, DiskTree.capacity)
    }

    deinit { abandon() }

    /// The names the map's catalogue was mapped from, to add to, and how long they are. Nil if the file there isn't that one.
    private static func openToAdd(_ url: URL, id: UInt64) -> (Int32, UInt64)? {
        let fd = open(url.path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var header = [UInt64](repeating: 0, count: 2)
        var info = stat()
        guard header.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, 16, 0) }) == 16, header[0] == SmallFiles.namesMagic, header[1] == id,
            fstat(fd, &info) == 0
        else {
            close(fd)
            return nil
        }
        return (fd, UInt64(info.st_size))
    }

    /// A lane for one worker. Everything it gathered is written when it's let go of.
    func lane() -> Lane { Lane(self) }

    /// Where the folder a refresh started from had its block, if it had one and these names are added to.
    fileprivate func earlierBlock(_ old: UInt32) -> (at: UInt32, block: UnsafeRawPointer)? {
        guard appending, let base, Int(old) < base.count else { return nil }
        let at = base.entry(Int(old))
        guard at != 0, UInt64(at) * 8 + 8 <= base.namesLength else { return nil }
        let block = base.names.base + Int(at) * 8
        guard UInt64(at) * 8 + UInt64(SmallFiles.blockSize(block)) <= base.namesLength else { return nil }
        return (at, block)
    }

    /// A folder a refresh read again with the same files in it keeps the block it had.
    fileprivate func reuse(_ id: UInt32, at: UInt32, files: Int) {
        index?[Int(id)] = at
        counted(files)
    }

    /// A folder a refresh copies from the map it started from keeps its block.
    func keep(_ id: UInt32, was old: UInt32, lane: Lane?) {
        guard let base, Int(old) < base.count, Int(id) < DiskTree.capacity else { return }
        let at = base.entry(Int(old))
        guard at != 0, UInt64(at) * 8 + 8 <= base.namesLength else { return }
        if appending {
            index?[Int(id)] = at
            counted(Int(base.names.base.load(fromByteOffset: Int(at) * 8, as: UInt32.self)))
        } else {
            let block = base.names.base + Int(at) * 8
            let size = SmallFiles.blockSize(block)
            guard UInt64(at) * 8 + UInt64(size) <= base.namesLength else { return }
            lane?.copy(block, size: size, folder: id)
        }
    }

    /// Writes the index for the map the scan made, and maps both files. Nil when anything couldn't be written.
    func finish(_ tree: DiskTree) -> SmallFileCatalogue? {
        guard !closed, let index, !failed.load(ordering: .relaxed), tree.count > 0, tree.count < DiskTree.capacity else {
            abandon()
            return nil
        }
        let length = end.load(ordering: .relaxed)
        let header: [UInt64] = [
            SmallFiles.indexMagic, storeID, UInt64(tree.count), SmallFiles.stamp(tree), length, appending ? base?.baseline ?? length : length,
            files.load(ordering: .relaxed), 0,
        ]
        let indexURL = SmallFiles.indexURL(volume, in: folder)
        let temporary = indexURL.appendingPathExtension("new")
        let out = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        var wrote = out >= 0
        if wrote {
            wrote = header.withUnsafeBytes { Self.write(out, $0.baseAddress, $0.count, at: 0) }
            wrote = wrote && Self.write(out, index, tree.count * 4, at: UInt64(SmallFiles.indexHeader))
            close(out)
        }
        // A block written straight from where it was gathered leaves its last few bytes to the file's end.
        var info = stat()
        if fstat(fd, &info) == 0, UInt64(info.st_size) < length, ftruncate(fd, off_t(length)) != 0 { wrote = false }
        close(fd)
        closed = true
        vmFree(index, DiskTree.capacity)
        self.index = nil
        // The names go in place first: an index naming names that aren't there yet is simply not used.
        guard wrote, appending || rename(target.path, SmallFiles.namesURL(volume, in: folder).path) == 0, rename(temporary.path, indexURL.path) == 0
        else {
            unlink(temporary.path)
            if !appending { unlink(target.path) }
            return nil
        }
        return SmallFileCatalogue.load(volume: volume, for: tree, in: folder)
    }

    /// The scan stopped, or the catalogue was turned off: what was being written goes.
    func abandon() {
        guard !closed else { return }
        closed = true
        close(fd)
        if !appending { unlink(target.path) }
        if let index { vmFree(index, DiskTree.capacity) }
        index = nil
    }

    // MARK: Writing

    /// Room in the names for this many bytes, which a lane fills.
    fileprivate func reserve(_ bytes: Int) -> UInt64 { end.add(UInt64(bytes), ordering: .relaxed).oldValue }

    fileprivate func put(_ p: UnsafeRawPointer, _ count: Int, at: UInt64) {
        if !Self.write(fd, p, count, at: at) { failed.store(true, ordering: .relaxed) }
    }

    fileprivate func point(_ id: UInt32, at: UInt64) {
        // Past what four bytes can number in eighths, 32 GB of names: not a real disk's.
        guard at >> 3 <= UInt64(UInt32.max) else {
            failed.store(true, ordering: .relaxed)
            return
        }
        index?[Int(id)] = UInt32(at >> 3)
    }

    fileprivate func counted(_ n: Int) { files.add(UInt64(n), ordering: .relaxed) }

    private static func write(_ fd: Int32, _ p: UnsafeRawPointer?, _ count: Int, at: UInt64) -> Bool {
        guard let p else { return count == 0 }
        var done = 0
        while done < count {
            let n = pwrite(fd, p + done, count - done, off_t(at) + off_t(done))
            if n <= 0 { return false }
            done += n
        }
        return true
    }

    /// One worker's share of the writing. Only that worker uses it.
    final class Lane {
        private let writer: SmallFileWriter
        // The folder being read: its names, each ended by a zero, and their sizes. Room for a folder of millions of files.
        private var names = Buffer<UInt8>(1 << 28)
        private var sizes = Buffer<UInt16>(1 << 24)
        // Blocks waiting to be written, and the folders they're for with where each starts in them. A bigger block than
        // this goes to the file on its own.
        private var out = Buffer<UInt8>(2 * Lane.flushAt)
        private var pending = Buffer<UInt64>(1 << 16)
        private static let flushAt = 64 << 10

        fileprivate init(_ writer: SmallFileWriter) { self.writer = writer }

        deinit {
            flush()
            // Mapped, so all of it goes back to the system now, not to a heap that keeps it.
            names.free()
            sizes.free()
            out.free()
            pending.free()
        }

        /// A file in the folder being read.
        @inline(__always) func add(_ name: UnsafePointer<UInt8>, _ length: Int, _ bytes: UInt64) {
            guard names.has(room: length + 1), sizes.has(room: 1) else { return }
            (names.p + names.count).update(from: name, count: length)
            names.p[names.count + length] = 0
            names.count += length + 1
            sizes.p[sizes.count] = UInt16(min((bytes + 1023) >> 10, UInt64(UInt16.max)))
            sizes.count += 1
        }

        /// The folder's been read: its names become a block. `old` is the same folder in the map a refresh started from.
        func close(_ folder: UInt32, was old: UInt32) {
            let count = sizes.count, nameBytes = names.count
            guard count > 0 else { return }
            defer {
                names.empty()
                sizes.empty()
            }
            let size = (8 + 2 * count + nameBytes + 7) & ~7
            // How many, then how many bytes of names, as the block starts.
            var head = UInt64(nameBytes) << 32 | UInt64(count)
            // Read again for something else (it has linked files, or changed in the last day), with nothing new: no need
            // to add the same block twice.
            if let earlier = writer.earlierBlock(old), SmallFiles.blockSize(earlier.block) == size, earlier.block.load(as: UInt64.self) == head,
                memcmp(earlier.block + 8, sizes.p, 2 * count) == 0, memcmp(earlier.block + 8 + 2 * count, names.p, nameBytes) == 0
            {
                writer.reuse(folder, at: earlier.at, files: count)
                return
            }
            writer.counted(count)
            // A folder of many files goes to the file straight from where it was gathered. The few bytes that round it up
            // are never written, so they read as the zeros they are.
            if size > Self.flushAt {
                flush()
                let at = writer.reserve(size)
                withUnsafeBytes(of: &head) { if let start = $0.baseAddress { writer.put(start, 8, at: at) } }
                writer.put(sizes.p, 2 * count, at: at + 8)
                writer.put(names.p, nameBytes, at: at + 8 + UInt64(2 * count))
                writer.point(folder, at: at)
                return
            }
            guard makeRoom(size) else { return }
            let block = UnsafeMutableRawPointer(out.p + out.count)
            block.storeBytes(of: head, as: UInt64.self)
            (block + 8).copyMemory(from: sizes.p, byteCount: 2 * count)
            (block + 8 + 2 * count).copyMemory(from: names.p, byteCount: nameBytes)
            let used = 8 + 2 * count + nameBytes
            (block + used).initializeMemory(as: UInt8.self, repeating: 0, count: size - used)
            placed(folder, size)
        }

        /// A block as another catalogue has it, for a folder a refresh copies.
        fileprivate func copy(_ block: UnsafeRawPointer, size: Int, folder: UInt32) {
            writer.counted(Int(block.load(as: UInt32.self)))
            if size > Self.flushAt {
                flush()
                let at = writer.reserve(size)
                writer.put(block, size, at: at)
                writer.point(folder, at: at)
                return
            }
            guard makeRoom(size) else { return }
            UnsafeMutableRawPointer(out.p + out.count).copyMemory(from: block, byteCount: size)
            placed(folder, size)
        }

        /// Room for a block of this size, writing what's waiting first if need be.
        private func makeRoom(_ size: Int) -> Bool {
            if !out.has(room: size) || !pending.has(room: 1) { flush() }
            return out.has(room: size)
        }

        private func placed(_ folder: UInt32, _ size: Int) {
            pending.p[pending.count] = UInt64(folder) << 32 | UInt64(out.count)
            pending.count += 1
            out.count += size
            if out.count >= Self.flushAt { flush() }
        }

        /// Sends what's gathered to the file, in a stretch of its own.
        func flush() {
            guard out.count > 0 else { return }
            let at = writer.reserve(out.count)
            writer.put(out.p, out.count, at: at)
            for k in 0..<pending.count {
                let entry = pending.p[k]
                writer.point(UInt32(entry >> 32), at: at + (entry & 0xFFFF_FFFF))
            }
            out.count = 0
            pending.count = 0
        }
    }
}

/// A run of values in memory mapped for it, as the tree's own tables are: only what's written to takes memory, it never
/// moves as it grows, and all of it goes back to the system when it's let go of.
private struct Buffer<T> {
    let p: UnsafeMutablePointer<T>
    var count = 0
    private let capacity: Int

    init(_ capacity: Int) {
        self.capacity = capacity
        p = vmAlloc(T.self, capacity)
    }

    @inline(__always) func has(room more: Int) -> Bool { count + more <= capacity }

    /// Empty again. What a folder of thousands of files took past the first 64 KB goes back to the system, so ten workers
    /// don't each keep what their biggest folder needed.
    mutating func empty() {
        let used = count * MemoryLayout<T>.stride
        count = 0
        let page = Int(getpagesize())
        let from = ((64 << 10) + page - 1) & ~(page - 1)
        let to = (used + page - 1) & ~(page - 1)
        guard to > from else { return }
        // New pages in place of the old: nothing is kept, and the room is still there.
        _ = mmap(UnsafeMutableRawPointer(p) + from, to - from, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED | MAP_NORESERVE, -1, 0)
    }

    func free() { vmFree(p, capacity) }
}
