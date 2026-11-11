import Darwin
import Foundation
import Synchronization

/// Files with the same bytes, for Copies. Only files big enough to have a piece of their own on the map are looked at, because
/// that's where the space is.
///
/// Size comes first, straight from the map, so most files are never opened. Files of one size are then read side by side in
/// growing pieces: the first 16 KB, the last 16 KB, then 64 KB, 256 KB, 1 MB and 4 MB at a time. A file drops out the moment
/// its bytes differ from every other's, so most cost one small read, and no byte is read twice. What's left at the end is the
/// same byte for byte, with no hash to take on trust. Nothing is read through the file cache, so what you have open stays fast.
enum Duplicates {
    /// Files with exactly the same bytes, in the tree's order. `size` is the length of one of them.
    struct Found: Equatable, Sendable {
        var size: UInt64
        var nodes: [UInt32]
    }

    /// The files that share one size on the map, so that some of them might be the same.
    struct Work: Sendable {
        var bytes: UInt64
        var files: [File]
        /// What reading them all could give back, so the biggest wins come first.
        var potential: UInt64 { bytes &* UInt64(max(files.count - 1, 0)) }
    }

    struct File: Sendable {
        var node: UInt32
        var path: String
        var modTime: UInt32
    }

    /// The smallest file looked at: the size at which a file gets a node of its own.
    static let smallest: UInt64 = 1 << 20

    /// Files of the same size where at least two might be the same, biggest wins first. On the startup disk only your own
    /// folders count, the ones Free Up's names apply in. On any other disk, all of it does, except the inside of apps and
    /// other packages. Hard links and clones counted somewhere else are left out: they already take no room.
    static func work(in tree: DiskTree, rules: RuleBook) -> [Work] {
        let nodes = tree.nodes
        let onBoot = tree.home != 0
        var bySize: [UInt64: [UInt32]] = [:]
        let skip = NodeFlag.directory | NodeFlag.synthetic | NodeFlag.alias | NodeFlag.gone | NodeFlag.hidden
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            guard n.flags & skip == 0, n.bytes >= smallest else { continue }
            let parent = nodes[Int(n.parent)]
            if onBoot {
                guard parent.has(NodeFlag.projects) else { continue }
            } else if isInsidePackage(UInt32(i), tree: tree, rules: rules) {
                continue
            }
            bySize[n.bytes, default: []].append(UInt32(i))
        }
        var work: [Work] = []
        for (bytes, group) in bySize where group.count >= 2 {
            let files = group.sorted().compactMap { node -> File? in
                guard let path = tree.path(node) else { return nil }
                return File(node: node, path: path, modTime: nodes[Int(node)].modTime)
            }
            if files.count >= 2 { work.append(Work(bytes: bytes, files: files)) }
        }
        return work.sorted { ($0.potential, $0.bytes) > ($1.potential, $1.bytes) }
    }

    static func isInsidePackage(_ node: UInt32, tree: DiskTree, rules: RuleBook) -> Bool {
        let nodes = tree.nodes
        var a = nodes[Int(node)].parent
        while a != 0 {
            let n = nodes[Int(a)]
            if n.has(NodeFlag.anchor) || n.has(NodeFlag.synthetic) { return false }
            if rules.isPackage(UnsafePointer(tree.names + Int(n.nameOffset)), Int(n.nameLength)) { return true }
            a = n.parent
        }
        return false
    }

    /// How far a search has got, for the panel. Written by the reading threads, read by anyone.
    final class Progress: Sendable {
        let bytesRead = Atomic<UInt64>(0)
        let groupsDone = Atomic<Int>(0)
        let groupsTotal: Int
        init(groupsTotal: Int) { self.groupsTotal = groupsTotal }
    }

    /// Reads the work on a few threads at once, biggest first, and calls `done` from them with each group's sets as soon as
    /// it's sure. A group that was stopped halfway isn't reported, so nothing half-read is ever taken as an answer.
    static func find(_ work: [Work], threads: Int, stop: LockedFlag, progress: Progress, done: @Sendable @escaping (Int, [Found]) -> Void) {
        guard !work.isEmpty else { return }
        let next = Atomic<Int>(0)
        let count = max(1, min(threads, work.count))
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            while !stop.value {
                let at = next.add(1, ordering: .relaxed).oldValue
                guard at < work.count else { return }
                let sets = split(work[at].files, stop: stop, progress: progress)
                if stop.value { return }
                done(at, sets)
                progress.groupsDone.add(1, ordering: .relaxed)
            }
        }
    }

    // MARK: Reading

    /// A file that's only in iCloud: reading it would download it.
    private static let dataless: UInt32 = 0x4000_0000

    private struct Handle {
        let file: File
        var fd: Int32 = -1
        var device: Int32 = 0
        var inode: UInt64 = 0
        var size: Int64 = 0
        var changed = timespec()
    }

    /// The pieces to compare, in order: the start, the end, then the middle in growing steps. The end goes early because
    /// that's where many files that start the same way differ, such as films whose index is written last.
    static func pieces(of size: Int64) -> [(offset: Int64, length: Int)] {
        let edge: Int64 = 16 << 10
        var out: [(Int64, Int)] = [(0, Int(min(edge, size)))]
        guard size > edge else { return out }
        let tailStart = max(edge, size - edge)
        out.append((tailStart, Int(size - tailStart)))
        var at = edge
        var step: Int64 = 64 << 10
        while at < tailStart {
            let length = min(step, tailStart - at)
            out.append((at, Int(length)))
            at += length
            step = min(step * 4, 4 << 20)
        }
        return out
    }

    /// The files that are the same as at least one other, in sets. Files that change, move or vanish while they're read drop out.
    static func split(_ files: [File], stop: LockedFlag, progress: Progress) -> [Found] {
        var handles: [Handle] = []
        for file in files {
            var st = stat()
            guard lstat(file.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & dataless == 0, st.st_size > 0 else { continue }
            handles.append(Handle(file: file, device: st.st_dev, inode: st.st_ino, size: st.st_size, changed: st.st_mtimespec))
        }
        // A few files stay open from one piece to the next. Many are opened for each piece, so a big set can't use up the
        // files the app may have open.
        let keepOpen = handles.count <= 8
        defer { for h in handles where h.fd >= 0 { close(h.fd) } }

        var bySize: [Int64: [Int]] = [:]
        for (at, h) in handles.enumerated() { bySize[h.size, default: []].append(at) }
        var out: [Found] = []
        for (size, members) in bySize where members.count >= 2 {
            var live: [[Int]] = [members]
            for piece in pieces(of: size) {
                if stop.value { return [] }
                var next: [[Int]] = []
                for group in live {
                    next += splitOnce(group, piece, &handles, keepOpen: keepOpen, progress: progress)
                }
                live = next
                if live.isEmpty { break }
            }
            // Still the same files, unchanged since the first look, after all that reading.
            for group in live {
                let same = group.filter { at in
                    var st = stat()
                    let h = handles[at]
                    guard lstat(h.file.path, &st) == 0 else { return false }
                    return st.st_ino == h.inode && st.st_dev == h.device && st.st_size == h.size
                        && st.st_mtimespec.tv_sec == h.changed.tv_sec && st.st_mtimespec.tv_nsec == h.changed.tv_nsec
                }
                if same.count >= 2 { out.append(Found(size: UInt64(size), nodes: same.map { handles[$0].file.node }.sorted())) }
            }
        }
        return out
    }

    /// One piece of every file in a group, and the group split by what it says. Groups of one are dropped.
    private static func splitOnce(_ group: [Int], _ piece: (offset: Int64, length: Int), _ handles: inout [Handle], keepOpen: Bool,
                                  progress: Progress) -> [[Int]] {
        var kinds: [(bytes: UnsafeMutableRawPointer, members: [Int])] = []
        defer { for k in kinds { k.bytes.deallocate() } }
        var spare = UnsafeMutableRawPointer.allocate(byteCount: piece.length, alignment: 16)
        defer { spare.deallocate() }
        for at in group {
            guard read(&handles[at], piece, into: spare, keepOpen: keepOpen) else { continue }
            progress.bytesRead.add(UInt64(piece.length), ordering: .relaxed)
            if let same = kinds.firstIndex(where: { memcmp($0.bytes, spare, piece.length) == 0 }) {
                kinds[same].members.append(at)
            } else {
                kinds.append((spare, [at]))
                spare = UnsafeMutableRawPointer.allocate(byteCount: piece.length, alignment: 16)
            }
        }
        return kinds.filter { $0.members.count >= 2 }.map(\.members)
    }

    /// One piece of one file. It has to be the same file as at the first look: same disk, same inode, same size and date.
    private static func read(_ h: inout Handle, _ piece: (offset: Int64, length: Int), into buffer: UnsafeMutableRawPointer, keepOpen: Bool) -> Bool {
        if h.fd < 0 {
            let fd = open(h.file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_ino == h.inode, st.st_dev == h.device, st.st_size == h.size, st.st_flags & dataless == 0,
                  st.st_mtimespec.tv_sec == h.changed.tv_sec, st.st_mtimespec.tv_nsec == h.changed.tv_nsec else {
                close(fd)
                return false
            }
            _ = fcntl(fd, F_NOCACHE, 1)
            h.fd = fd
        }
        defer {
            if !keepOpen {
                close(h.fd)
                h.fd = -1
            }
        }
        var done = 0
        while done < piece.length {
            let got = pread(h.fd, buffer + done, piece.length - done, off_t(piece.offset) + off_t(done))
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { return false }
            done += got
        }
        return true
    }
}

/// What earlier searches found, by path, so a search reads only what has changed since. A file is remembered with its size
/// and date, and with the set it was in, or as different from every other file its size. A group of files of one size is only
/// trusted if every one of them is remembered, unchanged. Kept in the app's own folder, so a search after a relaunch is quick too.
final class DuplicateMemory: @unchecked Sendable {
    struct Entry: Codable {
        var size: UInt64
        var modTime: UInt32
        /// Files with the same number had the same bytes. Zero: it was like none of the others.
        var set: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry]
    private var nextSet: Int
    private let file: URL?

    init(file: URL? = AppData.folder.appendingPathComponent("copies.json")) {
        self.file = file
        let loaded = file.flatMap { try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: $0)) } ?? [:]
        entries = loaded
        nextSet = (loaded.values.map(\.set).max() ?? 0) + 1
    }

    /// The sets this group was in last time, if nothing about it has changed. Nil: it has to be read.
    func recall(_ work: Duplicates.Work) -> [Duplicates.Found]? {
        lock.lock()
        defer { lock.unlock() }
        var sets: [Int: [UInt32]] = [:]
        for file in work.files {
            guard let e = entries[file.path], e.size == work.bytes, e.modTime == file.modTime else { return nil }
            if e.set != 0 { sets[e.set, default: []].append(file.node) }
        }
        return sets.values.filter { $0.count >= 2 }.map { Duplicates.Found(size: work.bytes, nodes: $0.sorted()) }
    }

    /// What reading this group found. Files in no set were like none of the others.
    func note(_ work: Duplicates.Work, found: [Duplicates.Found]) {
        lock.lock()
        defer { lock.unlock() }
        var setOf: [UInt32: Int] = [:]
        for set in found {
            let number = nextSet
            nextSet += 1
            for node in set.nodes { setOf[node] = number }
        }
        for file in work.files {
            entries[file.path] = Entry(size: work.bytes, modTime: file.modTime, set: setOf[file.node] ?? 0)
        }
    }

    /// Only what the map still has, so the file doesn't grow forever.
    func save(keeping paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        let copy = entries
        lock.unlock()
        guard let file else { return }
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(copy) { try? data.write(to: file, options: .atomic) }
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
