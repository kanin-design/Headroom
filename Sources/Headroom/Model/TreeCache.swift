import Compression
import Foundation

/// The last scan, whole: so the map is on screen the moment the window opens, and so the next refresh only has to read what
/// has changed since. Its rows of numbers are kept as the tree keeps them, each different one once, and its totals are added
/// up again when it's read, which is quicker than reading them. It's compressed in pieces, on every core at once.
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
    /// The file starts with this. After it: how long the head is, as it is and packed, how many parts follow and how
    /// long each is packed, then the head and the parts.
    private static let fileMagic: UInt64 = 0x4852_4F4F_4D5A_3033
    /// The tables are packed a piece of this many bytes at a time, each on its own, so the pieces are packed and
    /// unpacked on every core at once: in one stream, saving took 100 ms and reading 15, on one core.
    private static let pieceBytes = 1 << 20
    /// In a part's length: it's kept as it is, because packing didn't make it smaller.
    private static let asIs: UInt64 = 1 << 63
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    static func url(_ volume: String) -> URL {
        AppData.folder.appendingPathComponent("last-" + History.safe(volume) + ".scan")
    }

    /// One table cut into pieces, each a part of the file.
    private static func pieces(of base: UnsafeRawPointer?, _ bytes: Int) -> [UnsafeRawBufferPointer] {
        guard let base, bytes > 0 else { return [] }
        return stride(from: 0, to: bytes, by: pieceBytes).map { UnsafeRawBufferPointer(start: base + $0, count: min(pieceBytes, bytes - $0)) }
    }

    /// What's packed, to be let go once it's written.
    private struct Packed {
        var bytes: UnsafeMutablePointer<UInt8>
        var count: Int
        var asIs: Bool
    }

    /// Never fails: what can't be made smaller is kept as it is.
    private static func pack(_ raw: UnsafeRawBufferPointer) -> Packed {
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: max(raw.count, 1))
        guard let base = raw.baseAddress, raw.count > 0 else { return Packed(bytes: out, count: 0, asIs: true) }
        let used = compression_encode_buffer(out, raw.count, base.assumingMemoryBound(to: UInt8.self), raw.count, nil, COMPRESSION_LZFSE)
        if used > 0, used < raw.count { return Packed(bytes: out, count: used, asIs: false) }
        memcpy(out, base, raw.count)
        return Packed(bytes: out, count: raw.count, asIs: true)
    }

    /// Exactly as many bytes as `target` has room for, or it isn't what was saved.
    private static func unpack(_ packed: UnsafeRawBufferPointer, asIs: Bool, into target: UnsafeMutableRawBufferPointer) -> Bool {
        guard let from = packed.baseAddress, let to = target.baseAddress, target.count > 0 else { return target.count == 0 && packed.count == 0 }
        if asIs {
            guard packed.count == target.count else { return false }
            memcpy(to, from, target.count)
            return true
        }
        let got = compression_decode_buffer(
            to.assumingMemoryBound(to: UInt8.self), target.count, from.assumingMemoryBound(to: UInt8.self), packed.count, nil, COMPRESSION_LZFSE)
        return got == target.count
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
        var head = header.withUnsafeBytes { Data($0) }
        head.append(metaData)

        tree.links.withUnsafeBytes { links in
            tree.singleLinks.withUnsafeBytes { singles in
                let parts =
                    pieces(of: tree.nodes, n * MemoryLayout<Node>.stride) + pieces(of: stats.index, n * MemoryLayout<UInt32>.stride)
                    + pieces(of: stats.rows, stats.rowCount * DiskTree.statStride * MemoryLayout<UInt32>.stride)
                    + pieces(of: tree.names, tree.nameBytes) + pieces(of: links.baseAddress, links.count)
                    + pieces(of: singles.baseAddress, singles.count)
                let packedHead = head.withUnsafeBytes { pack($0) }
                let packed = UnsafeMutablePointer<Packed>.allocate(capacity: max(parts.count, 1))
                defer {
                    packedHead.bytes.deallocate()
                    for i in 0..<parts.count { packed[i].bytes.deallocate() }
                    packed.deallocate()
                }
                // Each piece writes only its own place.
                nonisolated(unsafe) let places = packed
                parts.withUnsafeBufferPointer { parts in
                    nonisolated(unsafe) let parts = parts
                    DispatchQueue.concurrentPerform(iterations: parts.count) { i in places[i] = pack(parts[i]) }
                }
                var table: [UInt64] = [fileMagic, UInt64(head.count), UInt64(packedHead.count) | (packedHead.asIs ? asIs : 0), UInt64(parts.count)]
                for i in 0..<parts.count { table.append(UInt64(packed[i].count) | (packed[i].asIs ? asIs : 0)) }

                // It only replaces the old one once it's all there.
                let target = url(facts.name)
                let temporary = target.appendingPathExtension("new")
                guard FileManager.default.createFile(atPath: temporary.path, contents: nil), let file = try? FileHandle(forWritingTo: temporary)
                else { return }
                var ok = true
                func write(_ bytes: UnsafeRawBufferPointer) {
                    guard ok else { return }
                    do { try file.write(contentsOf: bytes) } catch { ok = false }
                }
                table.withUnsafeBytes(write)
                write(UnsafeRawBufferPointer(start: packedHead.bytes, count: packedHead.count))
                for i in 0..<parts.count { write(UnsafeRawBufferPointer(start: packed[i].bytes, count: packed[i].count)) }
                try? file.close()
                if ok, rename(temporary.path, target.path) == 0 { return }
                try? FileManager.default.removeItem(at: temporary)
            }
        }
    }

    static func load(for facts: VolumeFacts, rules: RuleBook) -> DiskTree? {
        guard let data = try? Data(contentsOf: url(facts.name), options: .alwaysMapped), data.count > 32 else { return nil }
        return data.withUnsafeBytes { file -> DiskTree? in
            guard file.loadUnaligned(fromByteOffset: 0, as: UInt64.self) == fileMagic else { return nil }
            return read(file, rules: rules)
        }
    }

    private static func read(_ file: UnsafeRawBufferPointer, rules: RuleBook) -> DiskTree? {
        func word(_ at: Int) -> UInt64 { file.loadUnaligned(fromByteOffset: at * 8, as: UInt64.self) }
        let headBytes = word(1), headPacked = word(2), partCount = word(3)
        // Sizes past these aren't a map's: a file cut short, or not one of these, is left at once.
        guard headBytes >= 56, headBytes < 1 << 27, partCount < 1 << 24, 32 + Int(partCount) * 8 <= file.count else { return nil }
        let partsAt = 32 + Int(partCount) * 8 + Int(headPacked & ~asIs & 0xFFFF_FFFF)
        guard headPacked & ~asIs < 1 << 27, partsAt <= file.count else { return nil }
        var head = [UInt8](repeating: 0, count: Int(headBytes))
        let headRead = head.withUnsafeMutableBytes {
            unpack(UnsafeRawBufferPointer(rebasing: file[(32 + Int(partCount) * 8)..<partsAt]), asIs: headPacked & asIs != 0, into: $0)
        }
        guard headRead else { return nil }
        let header = head.withUnsafeBytes { raw in (0..<7).map { raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self) } }
        guard header[0] == magic else { return nil }
        // Sizes past this aren't a map's, and couldn't even be made into numbers here.
        guard header.dropFirst().allSatisfy({ $0 < 1 << 40 }) else { return nil }
        let count = Int(header[1]), rowCount = Int(header[2]), nameBytes = Int(header[3]), linkCount = Int(header[4])
        let singleCount = Int(header[5]), metaBytes = Int(header[6])
        // A row of numbers can be one node's own after the tree was changed by hand, so there can be up to twice as many.
        guard count > 0, count < DiskTree.capacity, rowCount <= 2 * count + 1, nameBytes < DiskTree.namesCapacity, linkCount < DiskTree.capacity,
            singleCount < DiskTree.capacity, metaBytes < 1 << 26, metaBytes == head.count - 56
        else { return nil }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: Data(head[56...])), meta.ruleBook == rules.fingerprint
        else { return nil }
        let tree = DiskTree()
        let stats = tree.roomForPackedStats(rowCount: rowCount, nodes: count)
        let links = UnsafeMutablePointer<LinkRecord>.allocate(capacity: max(linkCount, 1))
        let singles = UnsafeMutablePointer<LinkRecord>.allocate(capacity: max(singleCount, 1))
        defer {
            links.deallocate()
            singles.deallocate()
        }
        // The same pieces as were saved, each read straight into where it goes.
        let targets =
            pieces(of: tree.nodes, count * MemoryLayout<Node>.stride) + pieces(of: stats.index, count * MemoryLayout<UInt32>.stride)
            + pieces(of: stats.rows, rowCount * DiskTree.statStride * MemoryLayout<UInt32>.stride)
            + pieces(of: tree.readNames(nameBytes), nameBytes) + pieces(of: links, linkCount * MemoryLayout<LinkRecord>.stride)
            + pieces(of: singles, singleCount * MemoryLayout<LinkRecord>.stride)
        guard targets.count == Int(partCount) else { return nil }
        var starts = [Int](repeating: partsAt, count: targets.count + 1)
        for i in 0..<targets.count {
            let length = word(4 + i) & ~asIs
            guard length <= UInt64(pieceBytes) else { return nil }
            starts[i + 1] = starts[i] + Int(length)
        }
        guard starts[targets.count] <= file.count else { return nil }
        let failed = LockedFlag()
        targets.withUnsafeBufferPointer { targets in
            starts.withUnsafeBufferPointer { starts in
                nonisolated(unsafe) let targets = targets, starts = starts, file = file
                DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                    let packed = UnsafeRawBufferPointer(rebasing: file[starts[i]..<starts[i + 1]])
                    let kept = file.loadUnaligned(fromByteOffset: (4 + i) * 8, as: UInt64.self) & asIs != 0
                    if !unpack(packed, asIs: kept, into: UnsafeMutableRawBufferPointer(mutating: targets[i])) { failed.value = true }
                }
            }
        }
        guard !failed.value else { return nil }
        tree.links = Array(UnsafeBufferPointer(start: links, count: linkCount))
        tree.singleLinks = Array(UnsafeBufferPointer(start: singles, count: singleCount))
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
}
