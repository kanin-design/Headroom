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

/// The last scan, whole: so the map is on screen the moment the window opens, and so the next refresh only has to read what
/// has changed since. Its rows of numbers are kept as the tree keeps them, each different one once, and its totals are added
/// up again when it's read, which is quicker than reading them. It's compressed as it's written, with nothing copied first.
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
        var journal: ChangeJournal.Place?
        var fullReadAt: Date
        var readGuarded: Bool
        /// The build that wrote it. Another build may sort things differently, so then its map is shown, never refreshed.
        var build: String
    }

    /// Changes whenever the layout of a saved scan does, so an old file is simply ignored.
    private static let magic: UInt64 = 0x4852_4F4F_4D30_3037
    /// The file starts with this, and everything after it is compressed.
    private static let fileMagic: UInt64 = 0x4852_4F4F_4D5A_3032
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    static func url(_ volume: String) -> URL {
        AppData.folder.appendingPathComponent("last-" + String(volume.map { $0.isLetter || $0.isNumber ? $0 : "_" }) + ".scan")
    }

    static func save(_ tree: DiskTree, for facts: VolumeFacts) {
        let n = tree.count
        guard n > 0, let stats = tree.packedStats else { return }
        var display: [String: String] = [:]
        for (id, name) in tree.displayNames { display[String(id)] = name }
        let meta = Meta(volumeName: tree.volumeName, capacity: tree.capacityBytes, free: tree.freeBytes, rootPath: tree.rootPath, home: tree.home,
                        freeNode: tree.free, hiddenNode: tree.hidden, scanSeconds: tree.scanSeconds, finishedAt: tree.finishedAt,
                        displayNames: display, journal: tree.journal, fullReadAt: tree.fullReadAt, readGuarded: tree.readGuarded, build: build)
        guard let metaData = try? JSONEncoder().encode(meta) else { return }
        let header: [UInt64] = [magic, UInt64(n), UInt64(stats.rowCount), UInt64(tree.nameBytes), UInt64(tree.links.count),
                                UInt64(tree.singleLinks.count), UInt64(metaData.count)]

        // It only replaces the old one once it's all there.
        let target = url(facts.name)
        let temporary = target.appendingPathExtension("new")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil), let file = try? FileHandle(forWritingTo: temporary),
              let packer = Packer(file) else { return }
        [fileMagic].withUnsafeBytes { packer.write($0) }
        header.withUnsafeBytes(packer.add)
        metaData.withUnsafeBytes(packer.add)
        packer.add(UnsafeRawBufferPointer(start: tree.nodes, count: n * MemoryLayout<Node>.stride))
        packer.add(UnsafeRawBufferPointer(start: stats.index, count: n * MemoryLayout<UInt32>.stride))
        packer.add(UnsafeRawBufferPointer(start: stats.rows, count: stats.rowCount * DiskTree.statStride * MemoryLayout<UInt32>.stride))
        packer.add(UnsafeRawBufferPointer(start: tree.names, count: tree.nameBytes))
        tree.links.withUnsafeBytes(packer.add)
        tree.singleLinks.withUnsafeBytes(packer.add)
        let wrote = packer.finish()
        try? file.close()
        if wrote, rename(temporary.path, target.path) == 0 { return }
        try? FileManager.default.removeItem(at: temporary)
    }

    static func load(for facts: VolumeFacts) -> DiskTree? {
        guard let data = try? Data(contentsOf: url(facts.name), options: .alwaysMapped), data.count > 16 else { return nil }
        return data.withUnsafeBytes { file -> DiskTree? in
            guard file.loadUnaligned(fromByteOffset: 0, as: UInt64.self) == fileMagic,
                  let unpacker = Unpacker(UnsafeRawBufferPointer(rebasing: file[8...])) else { return nil }
            return read(unpacker)
        }
    }

    private static func read(_ unpacker: Unpacker) -> DiskTree? {
        var header = [UInt64](repeating: 0, count: 7)
        guard header.withUnsafeMutableBytes({ unpacker.take($0.baseAddress!, $0.count) }), header[0] == magic else { return nil }
        let count = Int(header[1]), rowCount = Int(header[2]), nameBytes = Int(header[3]), linkCount = Int(header[4])
        let singleCount = Int(header[5]), metaBytes = Int(header[6])
        // A row of numbers can be one node's own after the tree was changed by hand, so there can be up to twice as many.
        guard count > 0, count < DiskTree.capacity, rowCount <= 2 * count + 1, nameBytes < DiskTree.namesCapacity, linkCount < DiskTree.capacity,
              singleCount < DiskTree.capacity, metaBytes < 1 << 26 else { return nil }
        var metaData = Data(count: metaBytes)
        guard metaData.withUnsafeMutableBytes({ unpacker.take($0.baseAddress!, metaBytes) }),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData) else { return nil }
        let tree = DiskTree()
        guard unpacker.take(tree.nodes, count * MemoryLayout<Node>.stride) else { return nil }
        let stats = tree.roomForPackedStats(rowCount: rowCount, nodes: count)
        guard unpacker.take(stats.index, count * MemoryLayout<UInt32>.stride),
              unpacker.take(stats.rows, rowCount * DiskTree.statStride * MemoryLayout<UInt32>.stride),
              unpacker.take(tree.readNames(nameBytes), nameBytes) else { return nil }
        func records(_ count: Int) -> [LinkRecord]? {
            var read = true
            let records = [LinkRecord](unsafeUninitializedCapacity: count) { buffer, used in
                read = count == 0 || unpacker.take(buffer.baseAddress!, count * MemoryLayout<LinkRecord>.stride)
                used = count
            }
            return read ? records : nil
        }
        guard let links = records(linkCount), let singles = records(singleCount) else { return nil }
        tree.links = links
        tree.singleLinks = singles
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
        tree.fullReadAt = meta.fullReadAt
        tree.readGuarded = meta.readGuarded
        // Only a map written by this build can be refreshed, because only then do its rules match.
        tree.journal = meta.build == build ? meta.journal : nil
        tree.isWhole = true
        for (key, name) in meta.displayNames { if let id = UInt32(key) { tree.displayNames[id] = name } }
        tree.restoreSums()
        return tree
    }

    /// Compresses what it's given straight into a file, a buffer at a time.
    private final class Packer {
        private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        private let size = 1 << 20
        private let buffer: UnsafeMutablePointer<UInt8>
        private let file: FileHandle
        private var ok = true

        init?(_ file: FileHandle) {
            self.file = file
            buffer = .allocate(capacity: size)
            guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
                buffer.deallocate()
                stream.deallocate()
                return nil
            }
            stream.pointee.dst_ptr = buffer
            stream.pointee.dst_size = size
        }

        deinit {
            compression_stream_destroy(stream)
            stream.deallocate()
            buffer.deallocate()
        }

        /// Uncompressed, before anything else.
        func write(_ bytes: UnsafeRawBufferPointer) {
            guard ok else { return }
            do { try file.write(contentsOf: bytes) } catch { ok = false }
        }

        private func flush() {
            let used = size - stream.pointee.dst_size
            if used > 0 { write(UnsafeRawBufferPointer(start: buffer, count: used)) }
            stream.pointee.dst_ptr = buffer
            stream.pointee.dst_size = size
        }

        func add(_ bytes: UnsafeRawBufferPointer) {
            guard ok, let base = bytes.baseAddress, bytes.count > 0 else { return }
            stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
            stream.pointee.src_size = bytes.count
            while ok, stream.pointee.src_size > 0 {
                guard compression_stream_process(stream, 0) == COMPRESSION_STATUS_OK else { ok = false; return }
                if stream.pointee.dst_size == 0 { flush() }
            }
        }

        func finish() -> Bool {
            guard ok else { return false }
            stream.pointee.src_size = 0
            while ok {
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { return false }
                if status == COMPRESSION_STATUS_END || stream.pointee.dst_size == 0 { flush() }
                if status == COMPRESSION_STATUS_END { break }
            }
            return ok
        }
    }

    /// Decompresses a file straight into where each part goes, a part at a time.
    private final class Unpacker {
        private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)

        init?(_ source: UnsafeRawBufferPointer) {
            guard let base = source.baseAddress, compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
                stream.deallocate()
                return nil
            }
            stream.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
            stream.pointee.src_size = source.count
        }

        deinit {
            compression_stream_destroy(stream)
            stream.deallocate()
        }

        /// Exactly `count` bytes into `target`.
        func take(_ target: UnsafeMutableRawPointer, _ count: Int) -> Bool {
            guard count > 0 else { return true }
            stream.pointee.dst_ptr = target.assumingMemoryBound(to: UInt8.self)
            stream.pointee.dst_size = count
            while stream.pointee.dst_size > 0 {
                let status = compression_stream_process(stream, 0)
                if status == COMPRESSION_STATUS_ERROR { return false }
                if status == COMPRESSION_STATUS_END { return stream.pointee.dst_size == 0 }
            }
            return true
        }
    }
}
