import Darwin
import Foundation

private let attrFileTotalSize: UInt32 = 0x0000_0002

/// A look inside a folder, with a limit, so a huge one can't hold anything up. It reads the way a scan does: a whole folder in
/// one call, on several threads, with no file looked up by itself. That's about three times as fast as asking about each file.
enum Walker {
    /// Everything one pass finds out. It costs no more to know all of it.
    struct Look: Sendable, Equatable {
        /// What the files hold, which can be more than they take on the disk. It's what a copy has to read.
        var size: UInt64 = 0
        var largestFile: UInt64 = 0
        /// How much in here also has another name somewhere.
        var linkedBytes: UInt64 = 0
        /// The newest date on anything, in seconds.
        var newest: Int = 0
        var seen = 0
        /// False when the look stopped at its limit with folders still unread: what it says is then only about what it saw.
        var complete = true

        fileprivate mutating func add(_ other: Look) {
            size &+= other.size
            largestFile = max(largestFile, other.largestFile)
            linkedBytes &+= other.linkedBytes
            newest = max(newest, other.newest)
            seen += other.seen
            if !other.complete { complete = false }
        }

        var newestDate: Date { Date(timeIntervalSince1970: TimeInterval(newest)) }
    }

    /// The most a look ever reads: enough for any folder a person would move or throw away in one go.
    static let most = 2_000_000
    /// As far as a look goes while you're only ticking things: a few hundredths of a second.
    static let quick = 40_000

    static func newestChange(in path: String, limit: Int) -> Date { look(at: path, limit: limit).newestDate }
    static func size(of path: String) -> UInt64 { look(at: path, limit: most).size }

    /// Beyond this many threads the disk can't give any more.
    private static let threads = min(ProcessInfo.processInfo.activeProcessorCount, 6)

    static func look(at path: String, limit: Int) -> Look { looks(at: [path], limit: limit)[0] }

    /// Many looks at once, each with its own limit and its own answer: the same threads read them all, taking folders
    /// from whichever still has some. One after another, each look started its threads again and then mostly waited,
    /// as a small folder has little to read at any one time.
    static func looks(at paths: [String], limit: Int) -> [Look] {
        var totals = [Look](repeating: Look(), count: paths.count)
        var folders: [(path: String, root: Int)] = []
        for (root, path) in paths.enumerated() {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            totals[root].seen = 1
            totals[root].newest = info.st_mtimespec.tv_sec
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                folders.append((path, root))
            case S_IFREG:
                totals[root].size = UInt64(info.st_size)
                totals[root].largestFile = totals[root].size
                if info.st_nlink > 1 { totals[root].linkedBytes = UInt64(info.st_blocks) * 512 }
            default:
                break
            }
        }
        guard !folders.isEmpty else { return totals }
        // The first folders read are the ones asked about, in the order they were asked.
        let pool = Pool(folders.reversed(), roots: paths.count, limit: limit)
        DispatchQueue.concurrentPerform(iterations: threads) { _ in pool.work() }
        for root in 0..<paths.count { totals[root].add(pool.totals[root]) }
        return totals
    }

    // MARK: Remembering

    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memo: [String: (look: Look, at: Date, limit: Int)] = [:]

    /// For a check that runs again whenever you tick something: what was found out a moment ago is still true, and walking
    /// every planned folder each time wouldn't say anything new. With `maxAge` 0 it looks again, and remembers that.
    static func recentLook(at path: String, limit: Int, maxAge: TimeInterval) -> Look {
        memoLock.lock()
        let known = memo[path]
        memoLock.unlock()
        // A look that reached the end is as good as one with any higher limit.
        if let known, known.limit >= limit || known.look.complete, -known.at.timeIntervalSinceNow < maxAge { return known.look }
        let fresh = look(at: path, limit: limit)
        memoLock.lock()
        if memo.count > 5000 { memo.removeAll() }
        memo[path] = (fresh, Date(), limit)
        memoLock.unlock()
        return fresh
    }

    /// The same for many at once: what's known and new enough is used, and the rest are read together.
    static func recentLooks(at paths: [String], limit: Int, maxAge: TimeInterval) -> [Look] {
        var out = [Look?](repeating: nil, count: paths.count)
        memoLock.lock()
        for (i, path) in paths.enumerated() {
            if let known = memo[path], known.limit >= limit || known.look.complete, -known.at.timeIntervalSinceNow < maxAge { out[i] = known.look }
        }
        memoLock.unlock()
        let unknown = paths.indices.filter { out[$0] == nil }
        guard !unknown.isEmpty else { return out.map { $0 ?? Look() } }
        let fresh = looks(at: unknown.map { paths[$0] }, limit: limit)
        let now = Date()
        memoLock.lock()
        if memo.count > 5000 { memo.removeAll() }
        for (i, look) in zip(unknown, fresh) {
            memo[paths[i]] = (look, now, limit)
            out[i] = look
        }
        memoLock.unlock()
        return out.map { $0 ?? Look() }
    }

    // MARK: Reading

    /// Threads taking folders from one list. A thread only waits when the list is empty and another one may still add to it.
    /// Each folder belongs to one of the looks under way, and counts towards that look alone.
    private final class Pool: @unchecked Sendable {
        private let condition = NSCondition()
        private var folders: [(path: String, root: Int)]
        private var reading = 0
        private let limit: Int
        private(set) var totals: [Look]
        /// Looks that reached their limit: nothing more of theirs is read.
        private var stopped: [Bool]

        init(_ folders: [(path: String, root: Int)], roots: Int, limit: Int) {
            self.folders = folders
            self.limit = limit
            totals = [Look](repeating: Look(), count: roots)
            stopped = [Bool](repeating: false, count: roots)
        }

        func work() {
            let size = 64 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            defer { buffer.deallocate() }
            var list = attrlist()
            list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            list.commonattr = attrReturned | attrError | attrName | attrObjType | attrModTime
            list.fileattr = attrFileLinkCount | attrFileTotalSize | attrFileAllocSize
            var found: [String] = []
            while let folder = next() {
                found.removeAll(keepingCapacity: true)
                let look = read(folder.path, &list, buffer, size, &found)
                finished(look, found, of: folder.root)
            }
        }

        private func next() -> (path: String, root: Int)? {
            condition.lock()
            defer { condition.unlock() }
            while folders.isEmpty && reading > 0 { condition.wait() }
            guard let folder = folders.popLast() else { return nil }
            reading += 1
            return folder
        }

        private func finished(_ look: Look, _ found: [String], of root: Int) {
            condition.lock()
            totals[root].add(look)
            if stopped[root] {
                if !found.isEmpty { totals[root].complete = false }
            } else if totals[root].seen < limit {
                for path in found { folders.append((path, root)) }
            } else {
                // At its limit: what's still waiting to be read for this look is let go, and the others carry on.
                stopped[root] = true
                let before = folders.count
                folders.removeAll { $0.root == root }
                if !found.isEmpty || folders.count != before { totals[root].complete = false }
            }
            reading -= 1
            condition.broadcast()
            condition.unlock()
        }

        private func read(_ folder: String, _ list: inout attrlist, _ buffer: UnsafeMutableRawPointer, _ size: Int, _ found: inout [String]) -> Look {
            var look = Look()
            let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return look }
            defer { close(fd) }
            while true {
                let count = getattrlistbulk(fd, &list, buffer, size, optionNoFollow)
                if count <= 0 { break }
                var entry = UnsafeRawPointer(buffer)
                for _ in 0..<count {
                    let length = entry.loadUnaligned(as: UInt32.self)
                    defer { entry += Int(length) }
                    var p = entry + 4
                    let common = p.loadUnaligned(as: UInt32.self)
                    let fileAttrs = (p + 12).loadUnaligned(as: UInt32.self)
                    p += 20
                    if common & attrError != 0 {
                        if p.loadUnaligned(as: UInt32.self) != 0 { continue }
                        p += 4
                    }
                    guard common & attrName != 0 else { continue }
                    let name = p + Int(p.loadUnaligned(as: Int32.self))
                    p += 8
                    var type: UInt32 = 0
                    if common & attrObjType != 0 { type = p.loadUnaligned(as: UInt32.self); p += 4 }
                    if common & attrModTime != 0 {
                        look.newest = max(look.newest, p.loadUnaligned(as: Int.self))
                        p += 16
                    }
                    look.seen += 1
                    if type == objTypeDirectory {
                        found.append(folder + "/" + String(cString: name.assumingMemoryBound(to: CChar.self)))
                    } else if type == objTypeRegular {
                        var links: UInt32 = 1
                        if fileAttrs & attrFileLinkCount != 0 { links = p.loadUnaligned(as: UInt32.self); p += 4 }
                        if fileAttrs & attrFileTotalSize != 0 {
                            let bytes = p.loadUnaligned(as: UInt64.self)
                            look.size &+= bytes
                            look.largestFile = max(look.largestFile, bytes)
                            p += 8
                        }
                        if links > 1, fileAttrs & attrFileAllocSize != 0 { look.linkedBytes &+= p.loadUnaligned(as: UInt64.self) }
                    }
                }
            }
            return look
        }
    }
}
