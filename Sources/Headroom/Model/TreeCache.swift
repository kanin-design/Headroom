import Compression
import Foundation

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
        /// The rule book that numbered its rules (`RuleBook.fingerprint`). Under another one, the map isn't shown at all.
        var ruleBook: UInt64
    }

    /// Changes whenever the layout of a saved scan does, so an old file is simply ignored.
    private static let magic: UInt64 = 0x4852_4F4F_4D30_3038
    /// The file starts with this, and everything after it is compressed.
    private static let fileMagic: UInt64 = 0x4852_4F4F_4D5A_3032
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    static func url(_ volume: String) -> URL {
        AppData.folder.appendingPathComponent("last-" + History.safe(volume) + ".scan")
    }

    static func save(_ tree: DiskTree, for facts: VolumeFacts, rules: RuleBook) {
        let n = tree.count
        guard n > 0, let stats = tree.packedStats else { return }
        var display: [String: String] = [:]
        for (id, name) in tree.displayNames { display[String(id)] = name }
        let meta = Meta(
            volumeName: tree.volumeName, capacity: tree.capacityBytes, free: tree.freeBytes, rootPath: tree.rootPath, home: tree.home,
            freeNode: tree.free, hiddenNode: tree.hidden, scanSeconds: tree.scanSeconds, finishedAt: tree.finishedAt,
            displayNames: display, journal: tree.journal, fullReadAt: tree.fullReadAt, readGuarded: tree.readGuarded, build: build,
            ruleBook: rules.fingerprint)
        guard let metaData = try? JSONEncoder().encode(meta) else { return }
        let header: [UInt64] = [
            magic, UInt64(n), UInt64(stats.rowCount), UInt64(tree.nameBytes), UInt64(tree.links.count),
            UInt64(tree.singleLinks.count), UInt64(metaData.count),
        ]

        // It only replaces the old one once it's all there.
        let target = url(facts.name)
        let temporary = target.appendingPathExtension("new")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil), let file = try? FileHandle(forWritingTo: temporary),
            let packer = Packer(file)
        else { return }
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

    static func load(for facts: VolumeFacts, rules: RuleBook) -> DiskTree? {
        guard let data = try? Data(contentsOf: url(facts.name), options: .alwaysMapped), data.count > 16 else { return nil }
        return data.withUnsafeBytes { file -> DiskTree? in
            guard file.loadUnaligned(fromByteOffset: 0, as: UInt64.self) == fileMagic,
                let unpacker = Unpacker(UnsafeRawBufferPointer(rebasing: file[8...]))
            else { return nil }
            return read(unpacker, rules: rules)
        }
    }

    private static func read(_ unpacker: Unpacker, rules: RuleBook) -> DiskTree? {
        var header = [UInt64](repeating: 0, count: 7)
        guard header.withUnsafeMutableBytes({ raw in raw.baseAddress.map { unpacker.take($0, raw.count) } ?? false }), header[0] == magic
        else { return nil }
        // Sizes past this aren't a map's, and couldn't even be made into numbers here.
        guard header.dropFirst().allSatisfy({ $0 < 1 << 40 }) else { return nil }
        let count = Int(header[1]), rowCount = Int(header[2]), nameBytes = Int(header[3]), linkCount = Int(header[4])
        let singleCount = Int(header[5]), metaBytes = Int(header[6])
        // A row of numbers can be one node's own after the tree was changed by hand, so there can be up to twice as many.
        guard count > 0, count < DiskTree.capacity, rowCount <= 2 * count + 1, nameBytes < DiskTree.namesCapacity, linkCount < DiskTree.capacity,
            singleCount < DiskTree.capacity, metaBytes < 1 << 26
        else { return nil }
        var metaData = Data(count: metaBytes)
        guard metaData.withUnsafeMutableBytes({ raw in raw.baseAddress.map { unpacker.take($0, metaBytes) } ?? false }),
            let meta = try? JSONDecoder().decode(Meta.self, from: metaData), meta.ruleBook == rules.fingerprint
        else { return nil }
        let tree = DiskTree()
        guard unpacker.take(tree.nodes, count * MemoryLayout<Node>.stride) else { return nil }
        let stats = tree.roomForPackedStats(rowCount: rowCount, nodes: count)
        guard unpacker.take(stats.index, count * MemoryLayout<UInt32>.stride),
            unpacker.take(stats.rows, rowCount * DiskTree.statStride * MemoryLayout<UInt32>.stride),
            unpacker.take(tree.readNames(nameBytes), nameBytes)
        else { return nil }
        func records(_ count: Int) -> [LinkRecord]? {
            var read = true
            let records = [LinkRecord](unsafeUninitializedCapacity: count) { buffer, used in
                read = count == 0 || (buffer.baseAddress.map { unpacker.take($0, count * MemoryLayout<LinkRecord>.stride) } ?? false)
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
        guard isSound(tree, count: count, rowCount: rowCount, nameBytes: nameBytes, index: stats.index) else { return nil }
        tree.restoreSums()
        return tree
    }

    /// A damaged file can hold any numbers at all. Everything that points at something else has to point inside the map,
    /// and every folder comes before what's in it, as a scan writes them, so climbing to the top always ends.
    private static func isSound(_ tree: DiskTree, count: Int, rowCount: Int, nameBytes: Int, index: UnsafeMutablePointer<UInt32>) -> Bool {
        let nodes = tree.nodes
        for i in 0..<count {
            let n = nodes[i]
            guard i == 0 || Int(n.parent) < i, Int(n.firstChild) < count, Int(n.nextSibling) < count,
                Int(n.nameOffset) + Int(n.nameLength) <= nameBytes, Int(index[i] & ~DiskTree.ownRow) < rowCount
            else { return false }
        }
        // Each folder's list holds only what's in it, each thing once and after the folder, so walking down ends too.
        let listed = Mapped<UInt8>(count: count)
        for folder in 0..<count {
            var c = Int(nodes[folder].firstChild)
            while c != 0 {
                guard c > folder, Int(nodes[c].parent) == folder, listed[c] == 0 else { return false }
                listed[c] = 1
                c = Int(nodes[c].nextSibling)
            }
        }
        guard Int(tree.home) < count, Int(tree.free) < count, Int(tree.hidden) < count else { return false }
        for link in tree.links where Int(link.dir) >= count || Int(link.file) >= count { return false }
        for link in tree.singleLinks where Int(link.dir) >= count || Int(link.file) >= count { return false }
        return true
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
            guard let base = source.baseAddress,
                compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK
            else {
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
                let before = (stream.pointee.src_size, stream.pointee.dst_size)
                let status = compression_stream_process(stream, 0)
                if status == COMPRESSION_STATUS_ERROR { return false }
                if status == COMPRESSION_STATUS_END { return stream.pointee.dst_size == 0 }
                // A file cut short: nothing more comes out and nothing more goes in, however often it's asked.
                if (stream.pointee.src_size, stream.pointee.dst_size) == before { return false }
            }
            return true
        }
    }
}
