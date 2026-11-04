import Darwin
import Foundation
import Synchronization

// Attribute bits from <sys/attr.h>. Entries come back in this order, and only the ones the file system supplied.
private let attrReturned: UInt32 = 0x8000_0000
private let attrError: UInt32 = 0x2000_0000
private let attrName: UInt32 = 0x0000_0001
private let attrObjType: UInt32 = 0x0000_0008
private let attrModTime: UInt32 = 0x0000_0400
private let attrFlags: UInt32 = 0x0004_0000
private let attrFileID: UInt32 = 0x0200_0000
private let attrAddedTime: UInt32 = 0x1000_0000
private let attrDirEntryCount: UInt32 = 0x0000_0002
private let attrDirMountStatus: UInt32 = 0x0000_0004
private let attrFileLinkCount: UInt32 = 0x0000_0001
private let attrFileAllocSize: UInt32 = 0x0000_0004
private let attrExtCloneID: UInt32 = 0x0000_0100
private let attrExtFlags: UInt32 = 0x0000_0200

// A mount point, or a trigger that would mount something (such as a network share) just by being opened.
private let mountStatusMounts: UInt32 = 0x0000_0003
private let extMaySharedBlocks: UInt64 = 0x1
private let objTypeRegular: UInt32 = 1
private let objTypeDirectory: UInt32 = 2
private let optionNoFollow: UInt64 = 0x1
private let optionExtended: UInt64 = 0x20

/// Walks a volume as fast as the disk allows. Every worker asks for whole directories' metadata in one system call
/// (`getattrlistbulk`), adds small files to their folder without making a String, and keeps a node only for folders
/// and for files of at least `promoteBytes`.
final class Scanner: @unchecked Sendable {
    let tree: DiskTree
    let rules: RuleBook
    /// Below this, a file is only counted in its folder.
    let promoteBytes: UInt64 = 1 << 20
    /// When false, folders macOS guards are left alone, so the scan brings up no permission prompts.
    let touchGuarded: Bool

    private let nextNode = Atomic<UInt32>(0)
    private let nextName = Atomic<UInt64>(0)
    private let filesSeen = Atomic<UInt64>(0)
    private let cancelled = Atomic<Bool>(false)

    private let now = UInt32(Date().timeIntervalSince1970)
    private let extensions = ExtensionTable.shared

    // Jobs shared between workers. A worker keeps its own stack and only hands jobs over when someone is idle.
    private let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let wake = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    private var shared: [UInt32] = []
    private var idleWorkers = 0
    private var workerCount = 1
    private var finished = false
    private let hungry = Atomic<Int>(0)

    // Which file IDs have been counted. Split so that workers rarely wait on each other.
    private struct Stripe {
        var lock = os_unfair_lock()
        var seen = Set<UInt64>()
    }
    private let stripes: UnsafeMutablePointer<Stripe>
    private static let stripeCount = 256

    private var workerLinks: [[LinkRecord]] = []
    private var homeID: UInt32 = 0
    private let libraryName = RuleBook.hash("Library")

    init(tree: DiskTree, rules: RuleBook, touchGuarded: Bool) {
        self.tree = tree
        self.rules = rules
        self.touchGuarded = touchGuarded
        stripes = .allocate(capacity: Self.stripeCount)
        stripes.initialize(repeating: Stripe(), count: Self.stripeCount)
        pthread_mutex_init(lock, nil)
        pthread_cond_init(wake, nil)
    }

    deinit {
        stripes.deinitialize(count: Self.stripeCount)
        stripes.deallocate()
        pthread_mutex_destroy(lock)
        pthread_cond_destroy(wake)
        lock.deallocate()
        wake.deallocate()
    }

    var filesSoFar: UInt64 { filesSeen.load(ordering: .relaxed) }
    /// Nodes in use. The counter itself can pass the table's size when a disk has more folders than the table holds.
    var nodesSoFar: Int { min(Int(nextNode.load(ordering: .relaxed)), DiskTree.capacity) }
    func cancel() { cancelled.store(true, ordering: .relaxed) }
    var wasCancelled: Bool { cancelled.load(ordering: .relaxed) }

    // MARK: Building the top of the tree

    /// Creates a node that isn't found by scanning: a group, a sealed volume or a scan root.
    func addNode(parent: UInt32, display: String, flags: UInt16, bytes: UInt64 = 0, rule: UInt16 = 0, kind: Kind = .other, path: String? = nil, ruleState: UInt8 = 0) -> UInt32 {
        let id = nextNode.add(1, ordering: .relaxed).oldValue
        var node = Node()
        node.parent = parent
        node.flags = flags
        node.bytes = bytes
        node.rule = rule
        node.kind = kind.rawValue
        node.ruleState = ruleState
        if let path {
            var copy = path
            copy.withUTF8 { p in
                let offset = nextName.add(UInt64(p.count), ordering: .relaxed).oldValue
                (tree.names + Int(offset)).update(from: p.baseAddress!, count: p.count)
                node.nameOffset = UInt32(offset)
                node.nameLength = UInt16(p.count)
            }
        }
        if id != parent {
            node.nextSibling = tree.nodes[Int(parent)].firstChild
            tree.nodes[Int(parent)].firstChild = id
        }
        tree.nodes[Int(id)] = node
        tree.displayNames[id] = display
        tree.count = Int(id) + 1
        if flags & NodeFlag.directory != 0 && path != nil { shared.append(id) }
        return id
    }

    func setHome(_ id: UInt32) { homeID = id }

    // MARK: Running

    /// Blocks until the whole volume has been read, then totals are ready to be finished.
    func run(threads: Int) {
        workerCount = max(1, threads)
        workerLinks = Array(repeating: [], count: workerCount)
        let group = DispatchGroup()
        for index in 0..<workerCount {
            group.enter()
            let thread = Thread { [self] in
                work(index)
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()
        tree.count = nodesSoFar
        tree.links = workerLinks.flatMap { $0 }
        workerLinks = []
    }

    private func work(_ index: Int) {
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
        var opened = OpenFolders()
        defer { buffer.deallocate(); pathBuffer.deallocate(); opened.closeAll() }
        var local: [UInt32] = []
        local.reserveCapacity(4096)
        var links: [LinkRecord] = []
        var cursor: UInt64 = 0
        var cursorEnd: UInt64 = 0

        while true {
            if let job = local.popLast() {
                if hungry.load(ordering: .relaxed) > 0 && local.count > 1 {
                    let give = local.count / 2
                    pthread_mutex_lock(lock)
                    shared.append(contentsOf: local[0..<give])
                    pthread_cond_broadcast(wake)
                    pthread_mutex_unlock(lock)
                    local.removeFirst(give)
                }
                scan(job, buffer, bufferSize, pathBuffer, &local, &links, &cursor, &cursorEnd, &opened)
                continue
            }
            pthread_mutex_lock(lock)
            var job: UInt32?
            while true {
                if let j = shared.popLast() { job = j; break }
                if finished { break }
                idleWorkers += 1
                if idleWorkers == workerCount {
                    finished = true
                    pthread_cond_broadcast(wake)
                    idleWorkers -= 1
                    break
                }
                hungry.add(1, ordering: .relaxed)
                pthread_cond_wait(wake, lock)
                hungry.subtract(1, ordering: .relaxed)
                idleWorkers -= 1
            }
            pthread_mutex_unlock(lock)
            guard let job else { break }
            local.append(job)
        }
        pthread_mutex_lock(lock)
        workerLinks[index] = links
        pthread_mutex_unlock(lock)
    }

    /// A worker's recently opened folders. Almost every job is a child of one of them, and opening relative to it
    /// avoids walking the same top-level folders as every other thread, which is where they'd otherwise queue up.
    private struct OpenFolders {
        static let size = 24
        var ids = [UInt32](repeating: UInt32.max, count: size)
        var fds = [Int32](repeating: -1, count: size)
        var hand = 0

        @inline(__always) func fd(of id: UInt32) -> Int32 {
            for i in 0..<Self.size where ids[i] == id { return fds[i] }
            return -1
        }

        mutating func keep(_ id: UInt32, _ fd: Int32) {
            if fds[hand] >= 0 { close(fds[hand]) }
            ids[hand] = id
            fds[hand] = fd
            hand = (hand + 1) % Self.size
        }

        mutating func closeAll() {
            for i in 0..<Self.size where fds[i] >= 0 { close(fds[i]) }
        }
    }

    /// Opens a folder from the nearest open ancestor, or from its absolute path if there is none.
    @inline(__always)
    private func openFolder(_ id: UInt32, _ out: UnsafeMutablePointer<UInt8>, _ open: inout OpenFolders) -> Int32 {
        var end = 8191
        out[end] = 0
        var i = id
        let nodes = tree.nodes, names = tree.names
        var base: Int32 = AT_FDCWD
        while true {
            let n = nodes[Int(i)]
            let length = Int(n.nameLength)
            end -= length
            if end < 8191 - 1023 { return -1 }
            (out + end).update(from: names + Int(n.nameOffset), count: length)
            if n.flags & NodeFlag.anchor != 0 { break }
            let parentFD = open.fd(of: n.parent)
            if parentFD >= 0 { base = parentFD; break }
            end -= 1
            out[end] = 0x2F
            i = n.parent
        }
        return (out + end).withMemoryRebound(to: CChar.self, capacity: 8191 - end) {
            openat(base, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
    }

    private func scan(_ id: UInt32, _ buffer: UnsafeMutableRawPointer, _ bufferSize: Int, _ pathBuffer: UnsafeMutablePointer<UInt8>,
                      _ local: inout [UInt32], _ links: inout [LinkRecord], _ cursor: inout UInt64, _ cursorEnd: inout UInt64,
                      _ opened: inout OpenFolders) {
        if cancelled.load(ordering: .relaxed) { return }
        let nodes = tree.nodes
        let fd = openFolder(id, pathBuffer, &opened)
        if fd < 0 {
            nodes[Int(id)].flags |= NodeFlag.denied
            nodes[Int(id)].fileCount = 0
            return
        }
        opened.keep(id, fd)

        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrReturned | attrError | attrName | attrObjType | attrModTime | attrFlags | attrFileID | attrAddedTime
        list.dirattr = attrDirEntryCount | attrDirMountStatus
        list.fileattr = attrFileLinkCount | attrFileAllocSize
        list.forkattr = attrExtCloneID | attrExtFlags

        let parent = nodes[Int(id)]
        let expected = parent.fileCount        // the parent's listing left the entry count here, when it knew it
        var entriesRead: UInt32 = 0
        let parentRule = parent.rule
        let parentState = parent.ruleState
        let forcedKind: UInt8? = parentRule == 0 ? nil : rules.forcedKind(parentRule)
        let isHome = id == homeID
        let isLibrary = !isHome && parent.parent == homeID && nameHash(id) == libraryName

        var bytes: UInt64 = 0
        var aliasBytes: UInt64 = 0
        var fileCount: UInt32 = 0
        var newest: UInt32 = 0
        var firstChild = parent.firstChild
        var kindBytes = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        var recent1: UInt64 = 0, recent7: UInt64 = 0, recent30: UInt64 = 0
        let day: UInt32 = 86_400
        let cut1 = now &- day, cut7 = now &- 7 * day, cut30 = now &- 30 * day

        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, optionNoFollow | optionExtended)
            if count <= 0 {
                if count < 0 { nodes[Int(id)].flags |= NodeFlag.denied }
                break
            }
            entriesRead &+= UInt32(count)
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = entry.loadUnaligned(as: UInt32.self)
                defer { entry += Int(length) }
                var p = entry + 4
                let common = p.loadUnaligned(as: UInt32.self)
                let dirAttrs = (p + 8).loadUnaligned(as: UInt32.self)
                let fileAttrs = (p + 12).loadUnaligned(as: UInt32.self)
                let extAttrs = (p + 16).loadUnaligned(as: UInt32.self)
                p += 20
                if common & attrError != 0 {
                    if p.loadUnaligned(as: UInt32.self) != 0 { continue }
                    p += 4
                }
                guard common & attrName != 0 else { continue }
                let nameOffset = p.loadUnaligned(as: Int32.self)
                let nameLength = Int(p.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) - 1
                guard nameLength > 0 else { continue }
                let name = (p + Int(nameOffset)).assumingMemoryBound(to: UInt8.self)
                p += 8
                var type: UInt32 = 0
                if common & attrObjType != 0 { type = p.loadUnaligned(as: UInt32.self); p += 4 }
                var mod: UInt32 = 0
                if common & attrModTime != 0 { mod = UInt32(truncatingIfNeeded: p.loadUnaligned(as: Int.self)); p += 16 }
                if common & attrFlags != 0 { p += 4 }
                var fileID: UInt64 = 0
                if common & attrFileID != 0 { fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
                if common & attrAddedTime != 0 {
                    let added = UInt32(truncatingIfNeeded: p.loadUnaligned(as: Int.self))
                    if added > mod { mod = added }
                    p += 16
                }

                if type == objTypeDirectory {
                    var entries: UInt32 = 0
                    var mountStatus: UInt32 = 0
                    if dirAttrs & attrDirEntryCount != 0 { entries = p.loadUnaligned(as: UInt32.self); p += 4 }
                    if dirAttrs & attrDirMountStatus != 0 { mountStatus = p.loadUnaligned(as: UInt32.self) }
                    let isMount = mountStatus & mountStatusMounts != 0

                    let child = nextNode.add(1, ordering: .relaxed).oldValue
                    guard Int(child) < DiskTree.capacity else { continue }
                    var node = Node()
                    node.parent = id
                    node.flags = NodeFlag.directory
                    node.modTime = mod
                    node.fileCount = dirAttrs & attrDirEntryCount != 0 ? entries : 0
                    storeName(&node, name, nameLength, &cursor, &cursorEnd)

                    // Rules: a rule above wins, so a node_modules inside a cache stays part of the cache. Neutral rules
                    // only set a colour, so anything more specific may still apply inside them.
                    let open = parentRule <= rules.neutralLimit
                    node.rule = parentRule
                    if parentState != 0 {
                        let (state, rule) = rules.step(state: parentState, name: name, length: nameLength)
                        node.ruleState = state
                        if open && rule != 0 {
                            node.rule = rule
                            node.flags |= NodeFlag.ruleRoot
                        }
                    }
                    // "node_modules" only means "safe to rebuild" in a project of yours. Inside an app, a Photos library,
                    // Homebrew or a tool's install, the same name is part of something that would stop working without it.
                    let inProjects = parent.flags & NodeFlag.projects != 0
                    let startsProjects = isHome && name[0] != 0x2E && !(nameLength == 7 && memcmp(name, "Library", 7) == 0)
                        && !(nameLength == 12 && memcmp(name, "Applications", 12) == 0)
                    if (inProjects || startsProjects) && !rules.isPackage(name, nameLength) { node.flags |= NodeFlag.projects }
                    if open && inProjects && node.flags & NodeFlag.ruleRoot == 0 {
                        let rule = rules.ruleForName(name, nameLength)
                        if rule != 0 {
                            node.rule = rule
                            node.flags |= NodeFlag.ruleRoot
                        }
                    }

                    var descend = !isMount
                    if isMount {
                        node.flags |= NodeFlag.mount
                        node.fileCount = 0
                    }
                    if !touchGuarded && (isHome || isLibrary) {
                        let text = String(decoding: UnsafeBufferPointer(start: name, count: nameLength), as: UTF8.self)
                        if isHome ? RuleBook.guardedInHome.contains(text) : RuleBook.guardedInLibrary.contains(text) {
                            node.flags |= NodeFlag.locked
                            node.fileCount = 0
                            descend = false
                        }
                    }
                    node.nextSibling = firstChild
                    nodes[Int(child)] = node
                    firstChild = child
                    // An empty folder needs no system calls at all.
                    if descend && !(dirAttrs & attrDirEntryCount != 0 && entries == 0) { local.append(child) }
                    continue
                }

                // A file, link or other object.
                var links32: UInt32 = 1
                var alloc: UInt64 = 0
                if fileAttrs & attrFileLinkCount != 0 { links32 = p.loadUnaligned(as: UInt32.self); p += 4 }
                if fileAttrs & attrFileAllocSize != 0 { alloc = p.loadUnaligned(as: UInt64.self); p += 8 }
                var cloneID: UInt64 = 0
                var ext: UInt64 = 0
                if extAttrs & attrExtCloneID != 0 { cloneID = p.loadUnaligned(as: UInt64.self); p += 8 }
                if extAttrs & attrExtFlags != 0 { ext = p.loadUnaligned(as: UInt64.self); p += 8 }

                fileCount &+= 1
                if mod > newest { newest = mod }
                if alloc == 0 { continue }

                var kind = forcedKind ?? extensions.kind(name: name, length: nameLength)
                // ".ts" is both TypeScript and MPEG video. Only one of those runs to many megabytes.
                if forcedKind == nil, kind == Kind.code.rawValue, alloc >= 8 << 20, nameLength > 3,
                   name[nameLength - 3] == 0x2E, name[nameLength - 2] | 0x20 == 0x74, name[nameLength - 1] | 0x20 == 0x73 {
                    kind = Kind.video.rawValue
                }
                // Hard links and clones count once. The first worker to see one counts it, and `Accounting` picks
                // a settled home for it when the scan ends.
                var counted = true
                var linkKey: UInt64 = 0
                if type == objTypeRegular {
                    // A clone's ID also covers its hard links, so it goes first.
                    if ext & extMaySharedBlocks != 0 && cloneID != 0 {
                        linkKey = cloneID | (1 << 63)
                    } else if links32 > 1 {
                        linkKey = fileID
                    }
                    if linkKey != 0 { counted = firstTime(linkKey) }
                }
                let share: UInt64 = counted ? alloc : 0
                if !counted { aliasBytes &+= alloc }

                var fileNode: UInt32 = 0
                if alloc >= promoteBytes {
                    fileNode = nextNode.add(1, ordering: .relaxed).oldValue
                    if Int(fileNode) < DiskTree.capacity {
                        var node = Node()
                        node.parent = id
                        node.bytes = share
                        node.aliasBytes = counted ? 0 : alloc
                        node.kind = kind
                        node.fileCount = 0
                        node.modTime = mod
                        node.rule = parentRule
                        if !counted { node.flags |= NodeFlag.alias }
                        storeName(&node, name, nameLength, &cursor, &cursorEnd)
                        node.nextSibling = firstChild
                        nodes[Int(fileNode)] = node
                        firstChild = fileNode
                    } else {
                        fileNode = 0
                        bytes &+= share
                    }
                } else {
                    bytes &+= share
                }

                if linkKey != 0 {
                    links.append(LinkRecord(key: linkKey, bytes: alloc, dir: id, file: fileNode, when: mod, kind: kind, counted: counted))
                }

                if share != 0 {
                    withUnsafeMutableBytes(of: &kindBytes) { $0.assumingMemoryBound(to: UInt64.self)[Int(kind)] &+= share }
                    if mod >= cut30 {
                        recent30 &+= share
                        if mod >= cut7 {
                            recent7 &+= share
                            if mod >= cut1 { recent1 &+= share }
                        }
                    }
                }
            }
            if expected != 0 && entriesRead >= expected { break }
        }

        filesSeen.add(UInt64(fileCount), ordering: .relaxed)

        let s = tree.stats + Int(id) * DiskTree.statStride
        withUnsafeBytes(of: &kindBytes) { raw in
            let k = raw.bindMemory(to: UInt64.self)
            for i in 0..<Kind.count { s[i] = Self.units(k[i]) }
        }
        s[DiskTree.statRecent1] = Self.units(recent1)
        s[DiskTree.statRecent7] = Self.units(recent7)
        s[DiskTree.statRecent30] = Self.units(recent30)

        nodes[Int(id)].fileCount = fileCount
        if newest > nodes[Int(id)].modTime || nodes[Int(id)].modTime == 0 { nodes[Int(id)].modTime = newest }
        nodes[Int(id)].aliasBytes = aliasBytes
        nodes[Int(id)].firstChild = firstChild
        nodes[Int(id)].bytes = bytes
        tree.count = max(tree.count, nodesSoFar)
    }

    @inline(__always) private static func units(_ bytes: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: min((bytes &+ 8191) >> 14, UInt64(UInt32.max)))
    }

    private func nameHash(_ id: UInt32) -> UInt64 {
        let n = tree.nodes[Int(id)]
        return RuleBook.hash(UnsafePointer(tree.names + Int(n.nameOffset)), Int(n.nameLength))
    }

    @inline(__always)
    private func storeName(_ node: inout Node, _ name: UnsafePointer<UInt8>, _ length: Int, _ cursor: inout UInt64, _ end: inout UInt64) {
        if cursor &+ UInt64(length) > end {
            let chunk: UInt64 = 1 << 20
            cursor = nextName.add(chunk, ordering: .relaxed).oldValue
            end = cursor + chunk
            if end > UInt64(DiskTree.namesCapacity) { cursor = 0; end = 0; return }
        }
        (tree.names + Int(cursor)).update(from: name, count: length)
        node.nameOffset = UInt32(cursor)
        node.nameLength = UInt16(length)
        cursor &+= UInt64(length)
    }

    @inline(__always)
    private func firstTime(_ key: UInt64) -> Bool {
        let stripe = stripes + Int(truncatingIfNeeded: (key &* 0x9E37_79B9_7F4A_7C15) >> 56)
        os_unfair_lock_lock(&stripe.pointee.lock)
        let inserted = stripe.pointee.seen.insert(key).inserted
        os_unfair_lock_unlock(&stripe.pointee.lock)
        return inserted
    }
}
