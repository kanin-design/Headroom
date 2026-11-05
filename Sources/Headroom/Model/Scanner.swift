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

/// Reads a volume in the order that gets the picture right soonest. On a typical disk, under 1% of the files hold 90% of
/// the bytes, and a folder holding big files has few entries, so folders are read fewest entries first, with build folders
/// and caches last. After the first look the rest is read quietly: a few threads, at low priority.
///
/// Every worker asks for whole directories' metadata in one system call (`getattrlistbulk`), adds small files to their
/// folder without making a String, and keeps a node only for folders and for files of at least `promoteBytes`.
final class Scanner: @unchecked Sendable {
    /// A Mac app may only hold 256 open files unless it asks for more, and a scan's workers alone can keep nearly that many
    /// folders open. Whatever else was open at launch would tip it over.
    static func askForEnoughOpenFiles() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(rlim_t(OPEN_MAX), limit.rlim_max)
        if limit.rlim_cur < wanted {
            limit.rlim_cur = wanted
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }

    let tree: DiskTree
    let rules: RuleBook
    /// Below this, a file is only counted in its folder.
    let promoteBytes: UInt64 = 1 << 20
    /// When false, folders macOS guards are left alone, so the scan brings up no permission prompts.
    let touchGuarded: Bool

    private let nextNode = Atomic<UInt32>(0)
    private let nextName = Atomic<UInt64>(0)
    private let nextLink = Atomic<UInt64>(0)
    private let filesSeen = Atomic<UInt64>(0)
    private let cancelled = Atomic<Bool>(false)

    private let now = UInt32(Date().timeIntervalSince1970)
    private let extensions = ExtensionTable.shared

    /// One folder waiting to be read. The lowest key goes first: what you're looking at, then what's cheap, then the rest.
    private struct Job {
        var key: UInt64
        var id: UInt32
        var isUrgent: Bool { key >> 48 == 0 }
    }

    // All of this is guarded by `lock`.
    private let lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let wake = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    private var queue: [Job] = []
    private var seeds: [UInt32] = []
    private var inFlight = 0
    private var running = 0
    private var sleepers = 0
    private var urgentWaiting = 0
    private var urgentInFlight = 0
    private var quiet = false
    private var hurry = false
    /// Strict order gets the big things on screen soonest. Once that's done, or with nobody watching, the cheapest order
    /// wins: a folder's subfolders right after it, because they open relative to it.
    private var inOrder = true
    private var focus: UInt32?
    private var focusGeneration = 0
    private var workerCount = 1
    private var finished = false
    /// How many threads read while nobody is waiting.
    private static let quietWorkers = 3

    // Which file IDs have been counted. Split so that workers rarely wait on each other.
    private struct Stripe {
        var lock = os_unfair_lock()
        var seen = Set<UInt64>()
    }
    private let stripes: UnsafeMutablePointer<Stripe>
    private static let stripeCount = 256

    /// Every path of a file that has several, until `Accounting` has settled them. Mapped, like the tree's own tables: each
    /// worker fills its own stretch, nothing moves as it grows, and all of it goes back the moment it's let go of.
    private var linkTable: UnsafeMutablePointer<LinkRecord>?
    private static let linkCapacity = DiskTree.capacity
    private var homeID: UInt32 = 0
    private let libraryName = RuleBook.hash("Library")

    init(tree: DiskTree, rules: RuleBook, touchGuarded: Bool) {
        self.tree = tree
        self.rules = rules
        self.touchGuarded = touchGuarded
        linkTable = vmAlloc(LinkRecord.self, Self.linkCapacity)
        stripes = .allocate(capacity: Self.stripeCount)
        stripes.initialize(repeating: Stripe(), count: Self.stripeCount)
        pthread_mutex_init(lock, nil)
        pthread_cond_init(wake, nil)
    }

    deinit {
        freeLinks()
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
    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        pthread_mutex_lock(lock)
        queue.removeAll()
        urgentWaiting = 0
        pthread_cond_broadcast(wake)
        pthread_mutex_unlock(lock)
    }
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
        if flags & NodeFlag.directory != 0 && path != nil { node.flags |= NodeFlag.unread }
        if let path {
            // A path can come from a system call as a string with no bytes of its own yet. An array always has them.
            Array(path.utf8).withUnsafeBufferPointer { p in
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
        if flags & NodeFlag.directory != 0 && path != nil { seeds.append(id) }
        return id
    }

    func setHome(_ id: UInt32) { homeID = id }

    // MARK: Running

    /// Blocks until the whole volume has been read.
    func run(threads: Int) {
        workerCount = max(1, threads)
        pthread_mutex_lock(lock)
        for id in seeds { push(Job(key: key(tree.nodes[Int(id)], urgent: false), id: id)) }
        seeds = []
        pthread_mutex_unlock(lock)
        let group = DispatchGroup()
        for index in 0..<workerCount {
            group.enter()
            let thread = Thread { [self] in
                work(index)
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = quiet ? .utility : .userInitiated
            thread.start()
        }
        group.wait()
        tree.count = nodesSoFar
        // What the scan needed only while it was reading goes as soon as it's done.
        queue = []
        for index in 0..<Self.stripeCount { stripes[index].seen = [] }
    }

    /// The links that were found, all together. The stretches the workers didn't finish are closed up.
    func collectedLinks() -> UnsafeMutableBufferPointer<LinkRecord> {
        guard let table = linkTable else { return UnsafeMutableBufferPointer(start: nil, count: 0) }
        var count = 0
        for at in 0..<min(Int(nextLink.load(ordering: .relaxed)), Self.linkCapacity) where table[at].key != 0 {
            if count != at { table[count] = table[at] }
            count += 1
        }
        return UnsafeMutableBufferPointer(start: table, count: count)
    }

    func freeLinks() {
        if let table = linkTable { vmFree(table, Self.linkCapacity) }
        linkTable = nil
    }

    /// From here on, read at low priority with a few threads.
    func slowDown() {
        pthread_mutex_lock(lock)
        quiet = true
        inOrder = false
        pthread_mutex_unlock(lock)
    }

    /// Nobody is watching this scan's picture, so only the total time matters.
    func stopKeepingOrder() {
        pthread_mutex_lock(lock)
        inOrder = false
        pthread_mutex_unlock(lock)
    }

    /// Whether someone is waiting for the whole picture. That beats being quiet.
    func setHurry(_ value: Bool) {
        pthread_mutex_lock(lock)
        hurry = value
        pthread_cond_broadcast(wake)
        pthread_mutex_unlock(lock)
    }

    var isQuiet: Bool {
        pthread_mutex_lock(lock)
        defer { pthread_mutex_unlock(lock) }
        return quiet && !hurry
    }

    /// Whether what you're looking at is being read right now.
    var hasUrgentWork: Bool {
        pthread_mutex_lock(lock)
        defer { pthread_mutex_unlock(lock) }
        return urgentWaiting > 0 || urgentInFlight > 0
    }

    /// What's inside this folder goes to the front of the queue, at full power, because you're looking at it.
    func prioritize(_ folder: UInt32?) {
        pthread_mutex_lock(lock)
        defer { pthread_mutex_unlock(lock) }
        let nodes = tree.nodes
        focus = folder
        focusGeneration += 1
        urgentWaiting = 0
        for i in queue.indices {
            let urgent = isInFocus(queue[i].id)
            queue[i].key = key(nodes[Int(queue[i].id)], urgent: urgent)
            if urgent { urgentWaiting += 1 }
        }
        // Back into heap order, from the last parent down.
        var i = queue.count / 2 - 1
        while i >= 0 {
            sink(i)
            i -= 1
        }
        if urgentWaiting > 0 { pthread_cond_broadcast(wake) }
    }

    /// Call with the lock held.
    private func isInFocus(_ id: UInt32) -> Bool {
        guard let focus else { return false }
        let nodes = tree.nodes
        var at = id
        while true {
            if at == focus { return true }
            if at == 0 { return false }
            at = nodes[Int(at)].parent
        }
    }

    @inline(__always) private func key(_ node: Node, urgent: Bool) -> UInt64 {
        let order: UInt64 = urgent ? 0 : (node.flags & NodeFlag.later != 0 ? 2 : 1)
        return order << 48 | UInt64(node.fileCount)         // until a folder is read, fileCount is its entry count
    }

    private func push(_ job: Job) {
        queue.append(job)
        var i = queue.count - 1
        while i > 0 {
            let up = (i - 1) / 2
            if queue[up].key <= queue[i].key { break }
            queue.swapAt(up, i)
            i = up
        }
    }

    private func pop() -> Job {
        let top = queue[0]
        let last = queue.removeLast()
        if !queue.isEmpty {
            queue[0] = last
            sink(0)
        }
        return top
    }

    private func sink(_ start: Int) {
        var i = start
        while true {
            let l = 2 * i + 1, r = l + 1
            var low = i
            if l < queue.count && queue[l].key < queue[low].key { low = l }
            if r < queue.count && queue[r].key < queue[low].key { low = r }
            if low == i { return }
            queue.swapAt(low, i)
            i = low
        }
    }

    private func work(_ index: Int) {
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        let pathBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
        var opened = OpenFolders()
        defer { buffer.deallocate(); pathBuffer.deallocate(); opened.closeAll() }
        var local: [UInt32] = []
        local.reserveCapacity(4096)
        var batch: [Job] = []
        var found: [Job] = []
        var linkCursor = 0
        var linkEnd = 0
        var cursor: UInt64 = 0
        var cursorEnd: UInt64 = 0
        var speed = quiet ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED

        pthread_mutex_lock(lock)
        while true {
            while !finished {
                if !queue.isEmpty && running < allowedWorkers { break }
                if queue.isEmpty && inFlight == 0 {
                    finished = true
                    pthread_cond_broadcast(wake)
                    break
                }
                sleepers += 1
                pthread_cond_wait(wake, lock)
                sleepers -= 1
            }
            if finished { break }

            // A short list keeps the order strict while it matters. A long one means less waiting on the lock.
            batch.removeAll(keepingCapacity: true)
            let keepOrder = inOrder
            var urgentTaken = 0
            for _ in 0..<(keepOrder ? min(queue.count / (workerCount * 8) + 1, 24) : 1) {
                let job = pop()
                if job.isUrgent {
                    urgentWaiting -= 1
                    urgentTaken += 1
                }
                batch.append(job)
            }
            let taken = batch.count
            urgentInFlight += urgentTaken
            running += 1
            inFlight += taken
            let generation = focusGeneration
            let wanted = allowedWorkers == workerCount ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY
            pthread_mutex_unlock(lock)

            if wanted != speed {
                pthread_set_qos_class_self_np(wanted, 0)
                speed = wanted
            }
            found.removeAll(keepingCapacity: true)
            var read = 0
            while let job = batch.popLast() {
                scan(job.id, buffer, bufferSize, pathBuffer, &local, &linkCursor, &linkEnd, &cursor, &cursorEnd, &opened)
                read += 1
                for child in local {
                    let next = Job(key: key(tree.nodes[Int(child)], urgent: job.isUrgent), id: child)
                    // Carry on down this branch, but not for long, or the lock's list stops meaning anything. A build folder
                    // inside it still waits its turn.
                    if !keepOrder && read < 48 && batch.count < 64 && next.key >> 48 <= job.key >> 48 {
                        batch.append(next)
                    } else {
                        found.append(next)
                    }
                }
                local.removeAll(keepingCapacity: true)
            }

            pthread_mutex_lock(lock)
            // You may have moved on while these were being read, so what's urgent may have changed.
            let focusMoved = generation != focusGeneration
            for var job in found {
                if focusMoved { job.key = key(tree.nodes[Int(job.id)], urgent: isInFocus(job.id)) }
                push(job)
                if job.isUrgent { urgentWaiting += 1 }
            }
            urgentInFlight -= urgentTaken
            inFlight -= taken
            running -= 1
            // This worker takes the next job itself, so wake only as many others as there's work and room for.
            var helpers = min(sleepers, allowedWorkers - running - 1, queue.count - 1)
            while helpers > 0 {
                pthread_cond_signal(wake)
                helpers -= 1
            }
        }
        pthread_mutex_unlock(lock)
    }

    /// Call with the lock held. Full power unless it's quiet time and nobody is waiting on anything.
    private var allowedWorkers: Int {
        quiet && !hurry && urgentWaiting == 0 && urgentInFlight == 0 ? min(Self.quietWorkers, workerCount) : workerCount
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
            for i in 0..<Self.size where fds[i] >= 0 {
                close(fds[i])
                fds[i] = -1
                ids[i] = UInt32.max
            }
        }
    }

    /// Opens a folder from the nearest open ancestor, or from its absolute path if there is none. A path longer than the
    /// system accepts is opened a stretch at a time.
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
            if end < 1 { return -1 }
            (out + end).update(from: names + Int(n.nameOffset), count: length)
            if n.flags & NodeFlag.anchor != 0 { break }
            let parentFD = open.fd(of: n.parent)
            if parentFD >= 0 { base = parentFD; break }
            end -= 1
            out[end] = 0x2F
            i = n.parent
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        func openHere(_ from: Int32, _ at: Int) -> Int32 {
            (out + at).withMemoryRebound(to: CChar.self, capacity: 8191 - at) { openat(from, $0, flags) }
        }
        var at = end
        var current = base
        while 8191 - at > 1000 {
            var cut = at + 1000
            while cut > at && out[cut] != 0x2F { cut -= 1 }
            if cut == at {
                if current != base { close(current) }
                return -1
            }
            out[cut] = 0
            let next = openHere(current, at)
            if current != base { close(current) }
            if next < 0 { return -1 }
            current = next
            at = cut + 1
        }
        let fd = openHere(current, at)
        let failure = errno
        if current != base { close(current) }
        errno = failure
        return fd
    }

    /// The same, but running out of open files isn't a locked door. This worker lets go of what it's keeping, waits for
    /// the others to do the same, and tries again, so that the folder isn't written off as one it wasn't allowed to read.
    private func openFolderPatiently(_ id: UInt32, _ out: UnsafeMutablePointer<UInt8>, _ open: inout OpenFolders) -> Int32 {
        var fd = openFolder(id, out, &open)
        var tries = 0
        while fd < 0, errno == EMFILE || errno == ENFILE, tries < 400 {
            open.closeAll()
            usleep(5_000)
            fd = openFolder(id, out, &open)
            tries += 1
        }
        return fd
    }

    private func scan(_ id: UInt32, _ buffer: UnsafeMutableRawPointer, _ bufferSize: Int, _ pathBuffer: UnsafeMutablePointer<UInt8>,
                      _ local: inout [UInt32], _ linkCursor: inout Int, _ linkEnd: inout Int, _ cursor: inout UInt64, _ cursorEnd: inout UInt64,
                      _ opened: inout OpenFolders) {
        if cancelled.load(ordering: .relaxed) { return }
        let nodes = tree.nodes
        let fd = openFolderPatiently(id, pathBuffer, &opened)
        if fd < 0 {
            nodes[Int(id)].flags = (nodes[Int(id)].flags | NodeFlag.denied) & ~NodeFlag.unread
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
        var recent1: UInt64 = 0, recent7: UInt64 = 0, recent14: UInt64 = 0, recent30: UInt64 = 0
        let day: UInt32 = 86_400
        let cut1 = now &- day, cut7 = now &- 7 * day, cut14 = now &- 14 * day, cut30 = now &- 30 * day

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
                    if parent.flags & NodeFlag.later != 0 || rules.isSlowFolder(name, nameLength) { node.flags |= NodeFlag.later }
                    if open && inProjects && node.flags & NodeFlag.ruleRoot == 0 {
                        let rule = rules.ruleForName(name, nameLength)
                        if rule != 0 {
                            node.rule = rule
                            node.flags |= NodeFlag.ruleRoot
                        }
                    }

                    // A link in Downloads or a cache rarely marks a file's real home, so it doesn't claim the bytes.
                    // Otherwise the picture would show them in the wrong folder, then jump when the scan ends.
                    if parent.flags & NodeFlag.shyLinks != 0 || node.rule > rules.neutralLimit
                        || (isHome && nameLength == 9 && memcmp(name, "Downloads", 9) == 0) {
                        node.flags |= NodeFlag.shyLinks
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
                    // An empty folder needs no system calls at all.
                    let toRead = descend && !(dirAttrs & attrDirEntryCount != 0 && entries == 0)
                    if toRead { node.flags |= NodeFlag.unread }
                    node.nextSibling = firstChild
                    nodes[Int(child)] = node
                    firstChild = child
                    if toRead { local.append(child) }
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
                    if linkKey != 0 { counted = parent.flags & NodeFlag.shyLinks == 0 && firstTime(linkKey) }
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
                    addLink(LinkRecord(key: linkKey, bytes: alloc, dir: id, file: fileNode, when: mod, kind: kind, counted: counted), &linkCursor, &linkEnd)
                }

                if share != 0 {
                    withUnsafeMutableBytes(of: &kindBytes) { $0.assumingMemoryBound(to: UInt64.self)[Int(kind)] &+= share }
                    if mod >= cut30 {
                        recent30 &+= share
                        if mod >= cut14 { recent14 &+= share }
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
        s[DiskTree.statRecent14] = Self.units(recent14)

        nodes[Int(id)].fileCount = fileCount
        if newest > nodes[Int(id)].modTime || nodes[Int(id)].modTime == 0 { nodes[Int(id)].modTime = newest }
        nodes[Int(id)].aliasBytes = aliasBytes
        nodes[Int(id)].firstChild = firstChild
        nodes[Int(id)].bytes = bytes
        nodes[Int(id)].flags &= ~NodeFlag.unread
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
    private func addLink(_ record: LinkRecord, _ cursor: inout Int, _ end: inout Int) {
        if cursor == end {
            let stretch = 4096
            cursor = Int(nextLink.add(UInt64(stretch), ordering: .relaxed).oldValue)
            end = cursor + stretch
            // More than the table holds. The file is still counted, but what you'd get back may be a little off.
            if end > Self.linkCapacity { cursor = 0; end = 0; return }
        }
        linkTable?[cursor] = record
        cursor += 1
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
