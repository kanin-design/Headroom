import Compression
import Foundation

/// One moment in a disk's life, for the free-space chart.
struct HistoryPoint: Codable, Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    var free: UInt64
    var capacity: UInt64
    var system: UInt64
    var updates: UInt64
    var swap: UInt64
}

/// A compact record of sizes at one moment: every folder over a set size, by a hash of its path.
struct ScanSnapshot {
    var date: Date
    var free: UInt64
    var table: [UInt64: UInt64]
}

/// Where Headroom keeps what it remembers. A scripted check gets its own folder, so it can't touch your real history.
enum AppData {
    static let folder: URL = {
        let name = ScriptRunner.path == nil ? "Headroom" : "Headroom-check"
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

enum History {
    /// Folders below this aren't recorded, which keeps each snapshot to a few dozen kilobytes.
    static let smallestEntry: UInt64 = 32_000_000

    private static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private static func snapshotsFolder(_ volume: String) -> URL {
        let url = AppData.folder.appendingPathComponent("history-" + safe(volume), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func pointsURL(_ volume: String) -> URL { AppData.folder.appendingPathComponent("points-" + safe(volume) + ".json") }

    static func points(for facts: VolumeFacts) -> [HistoryPoint] {
        guard let data = try? Data(contentsOf: pointsURL(facts.name)) else { return [] }
        return (try? JSONDecoder().decode([HistoryPoint].self, from: data)) ?? []
    }

    /// A hash of each node's path, which stays the same from one scan to the next.
    static func fillKeys(tree: DiskTree, into keys: UnsafeMutablePointer<UInt64>) {
        let nodes = tree.nodes, names = tree.names
        keys[0] = 0xCBF2_9CE4_8422_2325
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            let own = n.nameLength > 0 ? RuleBook.hash(UnsafePointer(names + Int(n.nameOffset)), Int(n.nameLength)) : UInt64(i)
            keys[i] = (keys[Int(n.parent)] &* 0x0000_0100_0000_01B3) ^ own
        }
    }

    /// Adds this scan to the record, and returns the free-space history.
    static func record(tree: DiskTree, facts: VolumeFacts) -> [HistoryPoint] {
        var points = History.points(for: facts)
        let point = HistoryPoint(date: Date(), free: facts.free, capacity: facts.capacity, system: facts.system, updates: facts.preboot + facts.update, swap: facts.vm)
        points.append(point)
        if points.count > 1500 { points.removeFirst(points.count - 1500) }
        if let data = try? JSONEncoder().encode(points) { try? data.write(to: pointsURL(facts.name), options: .atomic) }

        let keys = vmAlloc(UInt64.self, max(tree.count, 1))
        defer { vmFree(keys, max(tree.count, 1)) }
        fillKeys(tree: tree, into: keys)
        var body = Data()
        var count: UInt32 = 0
        for i in 0..<tree.count where tree.totals[i] >= smallestEntry {
            withUnsafeBytes(of: keys[i]) { body.append(contentsOf: $0) }
            withUnsafeBytes(of: tree.totals[i]) { body.append(contentsOf: $0) }
            count += 1
        }
        var out = Data()
        var when = Date().timeIntervalSince1970
        var free = facts.free
        withUnsafeBytes(of: &when) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &free) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        out.append(body)
        let folder = snapshotsFolder(facts.name)
        let name = String(format: "%.0f.snap", when)
        try? out.write(to: folder.appendingPathComponent(name), options: .atomic)
        prune(folder)
        return points
    }

    private static func prune(_ folder: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "snap" }
        let keep = snapshotsToKeep(files.map { Double($0.deletingPathExtension().lastPathComponent) ?? 0 }, now: Date().timeIntervalSince1970)
        for file in files where !keep.contains(Double(file.deletingPathExtension().lastPathComponent) ?? 0) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The two newest, then what a comparison can use: it looks for one between 0.85 and 2 times the age it wants, and the
    /// longest it wants is 30 days. One every six hours for two days, one a day to two weeks, then one every four days.
    static func snapshotsToKeep(_ times: [Double], now: Double) -> Set<Double> {
        var seen = Set<Int>()
        var keep = Set<Double>()
        for (at, time) in times.sorted(by: >).enumerated() {
            let age = now - time
            if at < 2 { keep.insert(time); continue }
            guard age <= 60 * 86_400 else { continue }
            let span: Double = age < 2 * 86_400 ? 21_600 : (age < 14 * 86_400 ? 86_400 : 4 * 86_400)
            // Stretches of different lengths never get the same number.
            if seen.insert(Int(time / span) * 4 + (span == 21_600 ? 0 : (span == 86_400 ? 1 : 2))).inserted { keep.insert(time) }
        }
        return keep
    }

    /// The most recent snapshot at least `olderThan` seconds before this scan, or, for `isLast`, the one before it.
    static func snapshot(forVolume volume: String, olderThan seconds: TimeInterval, isLast: Bool, before date: Date) -> ScanSnapshot? {
        let folder = snapshotsFolder(volume)
        let times = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "snap" }
            .compactMap { Double($0.deletingPathExtension().lastPathComponent) }
            .sorted(by: >)
        let reference = date.timeIntervalSince1970
        let candidates = times.filter { $0 < reference - 60 }
        let chosen: Double?
        if isLast {
            chosen = candidates.first
        } else {
            // Close enough to the window that the comparison means what it says.
            chosen = candidates.first { reference - $0 >= seconds * 0.85 && reference - $0 <= seconds * 2 }
        }
        guard let chosen else { return nil }
        let url = folder.appendingPathComponent(String(format: "%.0f.snap", chosen))
        guard let data = try? Data(contentsOf: url), data.count >= 20 else { return nil }
        return data.withUnsafeBytes { raw -> ScanSnapshot in
            let when = raw.loadUnaligned(fromByteOffset: 0, as: Double.self)
            let free = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            let count = Int(raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
            var table = [UInt64: UInt64](minimumCapacity: count)
            for i in 0..<count {
                let at = 20 + i * 16
                guard at + 16 <= raw.count else { break }
                table[raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)] = raw.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self)
            }
            return ScanSnapshot(date: Date(timeIntervalSince1970: when), free: free, table: table)
        }
    }
}

/// The last scan, kept so that the map is on screen the moment the window opens.
enum TreeCache {
    private struct Meta: Codable {
        var volumeName: String
        var capacity: UInt64
        var free: UInt64
        var rootPath: String
        var home: UInt32
        var freeNode: UInt32
        var hiddenNode: UInt32
        var scanSeconds: Double
        var finishedAt: Date
        var displayNames: [String: String]
    }

    /// Changes whenever the layout of a saved scan does, so an old file is simply ignored.
    private static let magic: UInt64 = 0x4852_4F4F_4D30_3035
    /// A saved scan written whole and then compressed. The one above is what's inside it.
    private static let packedMagic: UInt64 = 0x4852_4F4F_4D5A_3031

    /// Folders smaller than this are folded into their parent in the saved copy. They wouldn't show on the ring.
    private static let smallest: UInt64 = 1 << 20

    private static func url(_ volume: String) -> URL {
        AppData.folder.appendingPathComponent("last-" + String(volume.map { $0.isLetter || $0.isNumber ? $0 : "_" }) + ".scan")
    }

    static func save(_ tree: DiskTree, for facts: VolumeFacts) {
        let n = tree.count
        let nodes = tree.nodes
        guard n > 0 else { return }
        let newID = Mapped<UInt32>(repeating: UInt32.max, count: n)
        var keptOld: [UInt32] = []
        keptOld.reserveCapacity(n / 4)
        for i in 0..<n {
            // Links take no space, but what they point at is still worth knowing: the other copy of a series, say.
            let matters = tree.totals[i] >= smallest || tree.aliasTotals[i] >= smallest || nodes[i].aliasBytes >= smallest
            let keep = i == 0 || nodes[i].has(NodeFlag.synthetic) || nodes[i].has(NodeFlag.anchor)
                || (matters && newID[Int(nodes[i].parent)] != UInt32.max)
            if keep {
                newID[i] = UInt32(keptOld.count)
                keptOld.append(UInt32(i))
            }
        }
        let count = keptOld.count
        let outNodes = Mapped<Node>(count: count)
        let outStats = Mapped<UInt32>(count: count * DiskTree.statStride)
        let outTotals = Mapped<UInt64>(count: count)
        let outFiles = Mapped<UInt32>(count: count)
        let outAlias = Mapped<UInt64>(count: count)
        var names = Data()
        for (at, old) in keptOld.enumerated() {
            var node = nodes[Int(old)]
            node.parent = newID[Int(node.parent)] == UInt32.max ? 0 : newID[Int(node.parent)]
            let offset = names.count
            if node.nameLength > 0 {
                names.append(UnsafeBufferPointer(start: tree.names + Int(node.nameOffset), count: Int(node.nameLength)))
            }
            node.nameOffset = UInt32(offset)
            // What's folded away joins the folder's own bytes.
            var folded: UInt64 = 0
            var c = nodes[Int(old)].firstChild
            while c != 0 {
                if newID[Int(c)] == UInt32.max { folded &+= tree.totals[Int(c)] }
                c = nodes[Int(c)].nextSibling
            }
            node.bytes &+= folded
            node.firstChild = 0
            node.nextSibling = 0
            outNodes[at] = node
            outTotals[at] = tree.totals[Int(old)]
            outFiles[at] = tree.totalFiles[Int(old)]
            outAlias[at] = tree.aliasTotals[Int(old)]
            let row = tree.statRow(old)
            for f in 0..<DiskTree.statStride { outStats[at * DiskTree.statStride + f] = row[f] }
        }
        // Children stay linked in their sorted order.
        for (at, old) in keptOld.enumerated() {
            var previous: UInt32 = 0
            var c = nodes[Int(old)].firstChild
            while c != 0 {
                let mapped = newID[Int(c)]
                if mapped != UInt32.max {
                    if previous == 0 { outNodes[at].firstChild = mapped } else { outNodes[Int(previous)].nextSibling = mapped }
                    previous = mapped
                }
                c = nodes[Int(c)].nextSibling
            }
        }
        var display: [String: String] = [:]
        for (id, name) in tree.displayNames where newID[Int(id)] != UInt32.max { display[String(newID[Int(id)])] = name }
        let meta = Meta(volumeName: tree.volumeName, capacity: tree.capacityBytes, free: tree.freeBytes, rootPath: tree.rootPath,
                        home: newID[Int(tree.home)] == UInt32.max ? 0 : newID[Int(tree.home)],
                        freeNode: newID[Int(tree.free)], hiddenNode: newID[Int(tree.hidden)], scanSeconds: tree.scanSeconds, finishedAt: tree.finishedAt,
                        displayNames: display)
        guard let metaData = try? JSONEncoder().encode(meta) else { return }
        // Files with several paths, so what you'd get back is right from the first frame after a restart. With the smallest
        // folders folded away, most of them now say the same thing.
        let remapped = Mapped<LinkRecord>(count: tree.links.count)
        for (at, link) in tree.links.enumerated() {
            var record = link
            var dir = record.dir
            while newID[Int(dir)] == UInt32.max { dir = nodes[Int(dir)].parent }
            record.dir = newID[Int(dir)]
            record.file = record.file != 0 && newID[Int(record.file)] != UInt32.max ? newID[Int(record.file)] : 0
            remapped[at] = record
        }
        let linkCount = tree.links.isEmpty ? 0 : Accounting.merge(UnsafeMutableBufferPointer(start: remapped.base, count: tree.links.count))
        let header: [UInt64] = [magic, UInt64(count), UInt64(names.count), UInt64(metaData.count), UInt64(linkCount)]

        // Mapped, so it all goes back as soon as it's written.
        let pieces = [outNodes.bytes(), outStats.bytes(), outTotals.bytes(), outFiles.bytes(), outAlias.bytes()]
        let whole = header.count * 8 + metaData.count + pieces.reduce(0) { $0 + $1.count } + names.count + remapped.bytes(linkCount).count
        let raw = vmAlloc(UInt8.self, whole)
        defer { vmFree(raw, whole) }
        var at = 0
        func put(_ bytes: UnsafeRawBufferPointer) {
            guard let base = bytes.baseAddress, bytes.count > 0 else { return }
            memcpy(raw + at, base, bytes.count)
            at += bytes.count
        }
        header.withUnsafeBytes(put)
        metaData.withUnsafeBytes(put)
        pieces.forEach(put)
        names.withUnsafeBytes(put)
        put(remapped.bytes(linkCount))

        // A sixth of the size, and quicker to read back than the time it takes to notice.
        let packed = vmAlloc(UInt8.self, whole)
        defer { vmFree(packed, whole) }
        let working = compression_encode_scratch_buffer_size(COMPRESSION_LZFSE)
        let scratch = vmAlloc(UInt8.self, max(working, 1))
        defer { vmFree(scratch, max(working, 1)) }
        let packedSize = compression_encode_buffer(packed, whole, raw, whole, scratch, COMPRESSION_LZFSE)

        // It only replaces the old one once it's all there.
        let target = url(facts.name)
        let temporary = target.appendingPathExtension("new")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil), let file = try? FileHandle(forWritingTo: temporary) else { return }
        var wrote = true
        func write(_ bytes: UnsafeRawBufferPointer) {
            guard wrote, bytes.count > 0 else { return }
            do { try file.write(contentsOf: bytes) } catch { wrote = false }
        }
        if packedSize > 0 {
            let start: [UInt64] = [packedMagic, UInt64(whole)]
            start.withUnsafeBytes(write)
            write(UnsafeRawBufferPointer(start: packed, count: packedSize))
        } else {
            write(UnsafeRawBufferPointer(start: raw, count: whole))
        }
        try? file.close()
        if wrote, rename(temporary.path, target.path) == 0 { return }
        try? FileManager.default.removeItem(at: temporary)
    }

    static func load(for facts: VolumeFacts) -> DiskTree? {
        guard let data = try? Data(contentsOf: url(facts.name), options: .alwaysMapped), data.count > 40 else { return nil }
        return data.withUnsafeBytes { file -> DiskTree? in
            guard file.loadUnaligned(fromByteOffset: 0, as: UInt64.self) == packedMagic else { return read(file) }
            let whole = Int(file.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            guard whole > 0, whole < 1 << 34, let source = file.baseAddress else { return nil }
            let raw = vmAlloc(UInt8.self, whole)
            defer { vmFree(raw, whole) }
            let working = compression_decode_scratch_buffer_size(COMPRESSION_LZFSE)
            let scratch = vmAlloc(UInt8.self, max(working, 1))
            defer { vmFree(scratch, max(working, 1)) }
            let bytes = source.assumingMemoryBound(to: UInt8.self) + 16
            guard compression_decode_buffer(raw, whole, bytes, file.count - 16, scratch, COMPRESSION_LZFSE) == whole else { return nil }
            return read(UnsafeRawBufferPointer(start: raw, count: whole))
        }
    }

    private static func read(_ raw: UnsafeRawBufferPointer) -> DiskTree? {
        guard raw.count > 40 else { return nil }
        let stored = raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
        guard stored == magic else { return nil }
        let count = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        let nameBytes = Int(raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
        let metaBytes = Int(raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
        let linkCount = Int(raw.loadUnaligned(fromByteOffset: 32, as: UInt64.self))
        var at = 40
        guard at + metaBytes <= raw.count, count > 0, count < DiskTree.capacity else { return nil }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: Data(bytes: raw.baseAddress! + at, count: metaBytes)) else { return nil }
        at += metaBytes
        let needed = count * MemoryLayout<Node>.stride + count * DiskTree.statStride * 4 + count * 8 + count * 4 + count * 8 + nameBytes + linkCount * MemoryLayout<LinkRecord>.stride
        guard at + needed <= raw.count else { return nil }
        let tree = DiskTree()
        func copy<T>(_ target: UnsafeMutablePointer<T>, _ items: Int) {
            let bytes = items * MemoryLayout<T>.stride
            UnsafeMutableRawPointer(target).copyMemory(from: raw.baseAddress! + at, byteCount: bytes)
            at += bytes
        }
        copy(tree.nodes, count)
        copy(tree.statTable, count * DiskTree.statStride)
        copy(tree.totals, count)
        copy(tree.totalFiles, count)
        copy(tree.aliasTotals, count)
        copy(tree.names, nameBytes)
        tree.links = [LinkRecord](unsafeUninitializedCapacity: linkCount) { buffer, used in
            UnsafeMutableRawPointer(buffer.baseAddress!).copyMemory(from: raw.baseAddress! + at, byteCount: linkCount * MemoryLayout<LinkRecord>.stride)
            used = linkCount
        }
        tree.count = count
        tree.volumeName = meta.volumeName
        tree.capacityBytes = meta.capacity
        tree.freeBytes = meta.free
        tree.rootPath = meta.rootPath
        tree.home = meta.home
        tree.free = meta.freeNode
        tree.hidden = meta.hiddenNode
        tree.scanSeconds = meta.scanSeconds
        tree.finishedAt = meta.finishedAt
        for (key, name) in meta.displayNames { if let id = UInt32(key) { tree.displayNames[id] = name } }
        tree.numberSubtrees()
        return tree
    }
}
