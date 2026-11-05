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

        fileprivate mutating func add(_ other: Look) {
            size &+= other.size
            largestFile = max(largestFile, other.largestFile)
            linkedBytes &+= other.linkedBytes
            newest = max(newest, other.newest)
            seen += other.seen
        }

        var newestDate: Date { Date(timeIntervalSince1970: TimeInterval(newest)) }
    }

    static func newestChange(in path: String, limit: Int) -> Date { look(at: path, limit: limit).newestDate }
    static func size(of path: String) -> UInt64 { look(at: path, limit: 2_000_000).size }
    static func linkedBytes(in path: String) -> UInt64 { look(at: path, limit: 40_000).linkedBytes }
    static func largestFile(in path: String) -> UInt64 { look(at: path, limit: 200_000).largestFile }

    /// Beyond this many threads the disk can't give any more.
    private static let threads = min(ProcessInfo.processInfo.activeProcessorCount, 6)

    static func look(at path: String, limit: Int) -> Look {
        var total = Look()
        var info = stat()
        guard lstat(path, &info) == 0 else { return total }
        total.seen = 1
        total.newest = info.st_mtimespec.tv_sec
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            let pool = Pool(path, limit: limit)
            DispatchQueue.concurrentPerform(iterations: threads) { _ in pool.work() }
            total.add(pool.total)
        case S_IFREG:
            total.size = UInt64(info.st_size)
            total.largestFile = total.size
            if info.st_nlink > 1 { total.linkedBytes = UInt64(info.st_blocks) * 512 }
        default:
            break
        }
        return total
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
        if let known, known.limit >= limit, -known.at.timeIntervalSinceNow < maxAge { return known.look }
        let fresh = look(at: path, limit: limit)
        memoLock.lock()
        if memo.count > 5000 { memo.removeAll() }
        memo[path] = (fresh, Date(), limit)
        memoLock.unlock()
        return fresh
    }

    // MARK: Reading

    /// Threads taking folders from one list. A thread only waits when the list is empty and another one may still add to it.
    private final class Pool: @unchecked Sendable {
        private let condition = NSCondition()
        private var folders: [String]
        private var reading = 0
        private let limit: Int
        private(set) var total = Look()

        init(_ path: String, limit: Int) {
            folders = [path]
            self.limit = limit
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
                let look = read(folder, &list, buffer, size, &found)
                finished(look, found)
            }
        }

        private func next() -> String? {
            condition.lock()
            defer { condition.unlock() }
            while folders.isEmpty && reading > 0 { condition.wait() }
            guard let folder = folders.popLast() else { return nil }
            reading += 1
            return folder
        }

        private func finished(_ look: Look, _ found: [String]) {
            condition.lock()
            total.add(look)
            if total.seen < limit { folders.append(contentsOf: found) } else { folders.removeAll() }
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
