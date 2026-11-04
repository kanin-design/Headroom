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
    private static let keepSnapshots = 60

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

    /// Keeps every snapshot from the last two days, then one a day, and at most `keepSnapshots`.
    private static func prune(_ folder: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "snap" }
            .sorted { (Double($0.deletingPathExtension().lastPathComponent) ?? 0) > (Double($1.deletingPathExtension().lastPathComponent) ?? 0) }
        var seenDays = Set<Int>()
        let now = Date().timeIntervalSince1970
        var kept = 0
        for file in files {
            let time = Double(file.deletingPathExtension().lastPathComponent) ?? 0
            let day = Int(time / 86_400)
            let recent = now - time < 2 * 86_400
            if (recent || !seenDays.contains(day)) && kept < keepSnapshots {
                seenDays.insert(day)
                kept += 1
            } else {
                try? FileManager.default.removeItem(at: file)
            }
        }
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
    private static let magic: UInt64 = 0x4852_4F4F_4D30_3033

    /// Folders smaller than this are folded into their parent in the saved copy. They wouldn't show on the ring.
    private static let smallest: UInt64 = 1 << 20

    private static func url(_ volume: String) -> URL {
        AppData.folder.appendingPathComponent("last-" + String(volume.map { $0.isLetter || $0.isNumber ? $0 : "_" }) + ".scan")
    }

    static func save(_ tree: DiskTree, for facts: VolumeFacts) {
        let n = tree.count
        let nodes = tree.nodes
        guard n > 0 else { return }
        var newID = [UInt32](repeating: UInt32.max, count: n)
        var keptOld: [UInt32] = []
        keptOld.reserveCapacity(n / 4)
        for i in 0..<n {
            let keep = i == 0 || nodes[i].has(NodeFlag.synthetic) || nodes[i].has(NodeFlag.anchor)
                || (tree.totals[i] >= smallest && newID[Int(nodes[i].parent)] != UInt32.max)
            if keep {
                newID[i] = UInt32(keptOld.count)
                keptOld.append(UInt32(i))
            }
        }
        let count = keptOld.count
        var outNodes = [Node](repeating: Node(), count: count)
        var outStats = [UInt32](repeating: 0, count: count * DiskTree.statStride)
        var outTotals = [UInt64](repeating: 0, count: count)
        var outFiles = [UInt32](repeating: 0, count: count)
        var outAlias = [UInt64](repeating: 0, count: count)
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
            for f in 0..<DiskTree.statStride { outStats[at * DiskTree.statStride + f] = tree.stats[Int(old) * DiskTree.statStride + f] }
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
        var out = Data()
        let header: [UInt64] = [magic, UInt64(count), UInt64(names.count), UInt64(metaData.count)]
        header.withUnsafeBytes { out.append(contentsOf: $0) }
        out.append(metaData)
        outNodes.withUnsafeBytes { out.append(contentsOf: $0) }
        outStats.withUnsafeBytes { out.append(contentsOf: $0) }
        outTotals.withUnsafeBytes { out.append(contentsOf: $0) }
        outFiles.withUnsafeBytes { out.append(contentsOf: $0) }
        outAlias.withUnsafeBytes { out.append(contentsOf: $0) }
        out.append(names)
        try? out.write(to: url(facts.name), options: .atomic)
    }

    static func load(for facts: VolumeFacts) -> DiskTree? {
        guard let data = try? Data(contentsOf: url(facts.name), options: .alwaysMapped), data.count > 32 else { return nil }
        return data.withUnsafeBytes { raw -> DiskTree? in
            let stored = raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self)
            guard stored == magic else { return nil }
            let count = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
            let nameBytes = Int(raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
            let metaBytes = Int(raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
            var at = 32
            guard at + metaBytes <= raw.count, count > 0, count < DiskTree.capacity else { return nil }
            guard let meta = try? JSONDecoder().decode(Meta.self, from: Data(bytes: raw.baseAddress! + at, count: metaBytes)) else { return nil }
            at += metaBytes
            let needed = count * MemoryLayout<Node>.stride + count * DiskTree.statStride * 4 + count * 8 + count * 4 + count * 8 + nameBytes
            guard at + needed <= raw.count else { return nil }
            let tree = DiskTree()
            func copy<T>(_ target: UnsafeMutablePointer<T>, _ items: Int) {
                let bytes = items * MemoryLayout<T>.stride
                UnsafeMutableRawPointer(target).copyMemory(from: raw.baseAddress! + at, byteCount: bytes)
                at += bytes
            }
            copy(tree.nodes, count)
            copy(tree.stats, count * DiskTree.statStride)
            copy(tree.totals, count)
            copy(tree.totalFiles, count)
            copy(tree.aliasTotals, count)
            copy(tree.names, nameBytes)
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
            tree.isFinished = true
            return tree
        }
    }
}
