import Darwin
import Foundation

/// The numbers the disk itself reports. Everything Headroom draws has to add up to these.
struct VolumeFacts {
    var name: String
    var mountPath: String
    var capacity: UInt64
    var free: UInt64
    var isBoot: Bool
    // Boot disk only: what each APFS volume in the container is using.
    var system: UInt64 = 0
    var preboot: UInt64 = 0
    var update: UInt64 = 0
    var vm: UInt64 = 0
    var data: UInt64 = 0

    /// What to call this disk on screen. `name` is what it's filed under.
    var shownName: String { HiddenNames.name(ofDisk: name, isBoot: isBoot) }
    var used: UInt64 { capacity > free ? capacity - free : 0 }
    /// APFS volumes we can't mount, such as Recovery: whatever the container uses beyond the ones we can read.
    var recovery: UInt64 {
        let known = system + preboot + update + vm + data
        return used > known ? used - known : 0
    }

    static func spaceUsed(_ path: String) -> UInt64 {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var buffer = [UInt8](repeating: 0, count: 32)
        guard getattrlist(path, &list, &buffer, buffer.count, 0) == 0 else { return 0 }
        return buffer.withUnsafeBytes { UInt64(max(0, $0.loadUnaligned(fromByteOffset: 4, as: Int64.self))) }
    }

    static func read(path: String) -> VolumeFacts? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let block = UInt64(info.f_bsize)
        // Some network and cloud disks claim more blocks than a 64-bit count of bytes can hold: those count as the most.
        func bytes(_ blocks: UInt64) -> UInt64 {
            let (product, overflow) = blocks.multipliedReportingOverflow(by: block)
            return overflow ? .max : product
        }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey])
        var facts = VolumeFacts(
            name: values?.volumeLocalizedName ?? url.lastPathComponent,
            mountPath: path,
            capacity: Demo.scaled(bytes(UInt64(info.f_blocks))),
            free: Demo.scaled(bytes(UInt64(info.f_bavail))),
            isBoot: path == "/"
        )
        if facts.isBoot {
            facts.system = spaceUsed("/")
            facts.preboot = spaceUsed("/System/Volumes/Preboot")
            facts.update = spaceUsed("/System/Volumes/Update")
            facts.vm = spaceUsed("/System/Volumes/VM")
            facts.data = spaceUsed("/System/Volumes/Data")
        }
        return facts
    }

    /// Disks you can pick from: the boot disk, then anything else mounted that's a real disk.
    static func available() -> [VolumeFacts] {
        if let disks = Demo.disks { return disks.compactMap { read(path: $0) } }
        var out: [VolumeFacts] = []
        if let boot = read(path: "/") { out.append(boot) }
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for url in urls where url.path != "/" {
            let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsReadOnlyKey]
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal == true else { continue }
            if values.volumeIsReadOnly == true { continue }
            if let facts = read(path: url.path), facts.capacity > 1 << 30 { out.append(facts) }
        }
        return out
    }
}

/// How hard a scan pushes.
enum ScanMode {
    case firstLook      // nothing on screen yet: big things first, then the rest in the cheapest order, all at full power
    case quiet          // the map is already there: low priority from the start
    case full           // you asked for it: full power to the end
}

/// Starts a scan of one disk and builds the top of the tree so that the whole ring adds up to the disk.
final class DiskScan: @unchecked Sendable {
    let tree = DiskTree()
    let facts: VolumeFacts
    let rules: RuleBook
    private(set) var scanner: Scanner!
    private var systemGroup: UInt32 = 0
    /// Where the disk's change journal was when this began, for the refresh after it to start from.
    var place: ChangeJournal.Place?
    /// For a refresh: the keys of the linked files the map knew of, and when its folders were last all read.
    private var known: Set<UInt64>?
    private var fullReadAt: Date?
    /// How many of the map's folders a refresh reads again, and why.
    private(set) var foldersToRead = 0
    private(set) var whyRead = ""
    /// A refresh came across a new hard link to a file it may have copied from the map, still counted where it was. Only
    /// reading everything can say, so what this read is thrown away.
    private(set) var surprised = false
    /// What to watch in the change journal, for a refresh after this.
    var watchRoots: [String] { ChangeJournal.roots(of: tree) }

    init(facts: VolumeFacts, rules: RuleBook, fullAccess: Bool) {
        self.facts = facts
        self.rules = rules
        tree.volumeName = facts.name
        tree.capacityBytes = facts.capacity
        tree.freeBytes = facts.free
        tree.rootPath = facts.mountPath
        scanner = Scanner(tree: tree, rules: rules, touchGuarded: fullAccess)
        if facts.isBoot { planBootDisk() } else { planExternalDisk() }
    }

    private func planBootDisk() {
        let f = NodeFlag.self
        _ = scanner.addNode(parent: 0, display: facts.shownName, flags: f.synthetic | f.directory)
        let dataRoot = "/System/Volumes/Data"
        let home = NSHomeDirectory()
        let homeInData = dataRoot + home

        let (homeState, homeRule) = walk(home)
        let you = scanner.addNode(parent: 0, display: "Your files", flags: f.anchor | f.directory, rule: homeRule, path: homeInData, ruleState: homeState)
        scanner.setHome(you)
        tree.home = you

        let (appsState, appsRule) = walk("/Applications")
        _ = scanner.addNode(parent: 0, display: "Apps", flags: f.anchor | f.directory, rule: appsRule, kind: .app, path: dataRoot + "/Applications", ruleState: appsState)

        let system = scanner.addNode(parent: 0, display: "System", flags: f.synthetic | f.directory, kind: .system)
        systemGroup = system
        _ = scanner.addNode(parent: system, display: "macOS", flags: f.synthetic, bytes: facts.system, rule: rules.macOSRule, kind: .system)
        _ = scanner.addNode(parent: system, display: "Startup and updates", flags: f.synthetic, bytes: facts.preboot + facts.update, rule: rules.updatesRule, kind: .system)
        _ = scanner.addNode(parent: system, display: "Memory swap", flags: f.synthetic, bytes: facts.vm, rule: rules.swapRule, kind: .system)
        _ = scanner.addNode(parent: system, display: "Recovery", flags: f.synthetic, bytes: facts.recovery, rule: rules.recoveryRule, kind: .system)

        // Everything else on the Data volume, each scanned from its own root.
        let skip: Set<String> = ["Users", "Applications", "Volumes", "home"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dataRoot)) ?? []
        for name in names where !skip.contains(name) && !name.hasPrefix(".") {
            var isDir: ObjCBool = false
            let path = dataRoot + "/" + name
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            if name == "System" {
                // Only the part of /System that lives on this volume.
                let inner = path + "/Library"
                let (state, rule) = walk("/System/Library")
                _ = scanner.addNode(parent: system, display: "/System", flags: f.anchor | f.directory, rule: rule, kind: .system, path: inner, ruleState: state)
            } else {
                let (state, rule) = walk("/" + name)
                _ = scanner.addNode(parent: system, display: "/" + name, flags: f.anchor | f.directory, rule: rule, kind: .system, path: path, ruleState: state)
            }
        }
        let otherUsers = ((try? FileManager.default.contentsOfDirectory(atPath: dataRoot + "/Users")) ?? [])
            .filter { !$0.hasPrefix(".") && dataRoot + "/Users/" + $0 != homeInData }
        for user in otherUsers {
            _ = scanner.addNode(parent: system, display: user, flags: f.anchor | f.directory, kind: .other, path: dataRoot + "/Users/" + user)
        }

        tree.hidden = scanner.addNode(parent: 0, display: "Hidden", flags: f.synthetic | f.hidden, rule: rules.hiddenRule, kind: .system)
        tree.free = scanner.addNode(parent: 0, display: "Free", flags: f.synthetic | f.free, bytes: facts.free)
    }

    private func planExternalDisk() {
        let f = NodeFlag.self
        _ = scanner.addNode(parent: 0, display: facts.shownName, flags: f.synthetic | f.directory)
        _ = scanner.addNode(parent: 0, display: "Files", flags: f.anchor | f.directory | f.projects, path: facts.mountPath)
        tree.hidden = scanner.addNode(parent: 0, display: "Hidden", flags: f.synthetic | f.hidden, rule: rules.hiddenRule, kind: .system)
        tree.free = scanner.addNode(parent: 0, display: "Free", flags: f.synthetic | f.free, bytes: facts.free)
    }

    /// Follows the rule table along a path from the volume's root.
    private func walk(_ path: String) -> (UInt8, UInt16) {
        var state: UInt8 = 0
        var rule: UInt16 = 0
        var first = true
        for part in path.split(separator: "/") {
            let (next, found) = first ? rules.stepFromRoot(String(part)) : stepNamed(state, String(part))
            first = false
            state = next
            if found != 0 { rule = found }
            if state == 0 { break }
        }
        return (state, rule)
    }

    private func stepNamed(_ state: UInt8, _ name: String) -> (UInt8, UInt16) {
        guard state != 0 else { return (0, 0) }
        let bytes = Array(name.utf8)
        return bytes.withUnsafeBufferPointer { rules.step(state: state, name: $0.baseAddress!, length: $0.count) }
    }

    /// Makes this scan a refresh of `base`. What the journal says has changed since is read again, and so are the folders
    /// with linked files in them, those with something changed in the last day (so that day is right to the minute), and
    /// those that couldn't be read. Everything else is copied. False when there'd be nothing to copy.
    func refresh(from base: DiskTree, changes: ChangeJournal.Changes, place: ChangeJournal.Place) -> Bool {
        guard base.isWhole, let since = base.journal, base.count > 0 else { return false }
        let n = base.count
        let nodes = base.nodes
        let marks = Mapped<UInt8>(count: n)
        let read = Scanner.Refresh.read, readAll = Scanner.Refresh.readAll
        let anchors = base.anchors
        // The boot disk is read from the Data volume, which the journal leaves out of its paths.
        let prefix = facts.isBoot ? ChangeJournal.dataPrefix : ""
        let finder = PathFinder(base)

        for path in changes.folders {
            if let node = finder.deepest(prefix + path) { marks[Int(node)] = max(marks[Int(node)], read) }
        }
        for path in changes.everythingUnder {
            let raw = prefix + path
            if let node = finder.deepest(raw) { marks[Int(node)] = readAll }
            for anchor in anchors where anchor.path.hasPrefix(raw == "/" ? "/" : raw + "/") { marks[Int(anchor.id)] = readAll }
        }
        guard anchors.contains(where: { marks[Int($0.id)] != readAll }) else { return false }

        // Each folder's own part of the last day: all of it, less what's in the folders and files inside it.
        let day = Mapped<UInt32>(count: n)
        let dayField = DiskTree.statRecent1
        for i in 0..<n { day[i] = base.statRow(i)[dayField] }
        for i in 1..<n { day[Int(nodes[i].parent)] &-= base.statRow(i)[dayField] }
        let dayAgo = scanner.now &- 86_400
        for i in 0..<n {
            let node = nodes[i]
            if i > 0, marks[Int(node.parent)] == readAll { marks[i] = readAll; continue }
            guard node.flags & NodeFlag.directory != 0 else { continue }
            if node.flags & (NodeFlag.denied | NodeFlag.unread) != 0 || (day[i] != 0 && node.modTime >= dayAgo) { marks[i] = max(marks[i], read) }
        }
        for r in base.links { marks[Int(r.dir)] = max(marks[Int(r.dir)], read) }
        for r in base.singleLinks { marks[Int(r.dir)] = max(marks[Int(r.dir)], read) }
        foldersToRead = (0..<n).reduce(0) { $0 + (marks[$1] != 0 && nodes[$1].flags & NodeFlag.directory != 0 ? 1 : 0) }
        var changed = 0, lastDay = 0, unread = 0, linked = Set<UInt32>()
        for path in changes.folders { if finder.deepest(prefix + path) != nil { changed += 1 } }
        for i in 0..<n where nodes[i].flags & NodeFlag.directory != 0 {
            if nodes[i].flags & (NodeFlag.denied | NodeFlag.unread) != 0 { unread += 1 } else if day[i] != 0 && nodes[i].modTime >= dayAgo { lastDay += 1 }
        }
        for r in base.links { linked.insert(r.dir) }
        for r in base.singleLinks { linked.insert(r.dir) }
        whyRead = "\(changed) changed, \(linked.count) with linked files, \(lastDay) with something from the last day, \(unread) that couldn't be read"

        let was = Dictionary(anchors.map { ($0.path, $0.id) }, uniquingKeysWith: { first, _ in first })
        for anchor in tree.anchors { if let old = was[anchor.path] { scanner.seed(anchor.id, was: old) } }
        // Dates are in whole seconds, so only those before the second the map began are sure to be older than it.
        scanner.refresh(from: base, marks: marks, unchangedSince: UInt32(seconds: since.time.rounded(.down) - 1))
        known = Set(base.links.lazy.map(\.key)).union(base.singleLinks.lazy.map(\.key))
        fullReadAt = base.fullReadAt
        self.place = place
        return true
    }

    /// Finds the deepest folder the map has along a path, a name at a time, with big folders' names looked up in a table.
    private final class PathFinder {
        private let tree: DiskTree
        private let anchors: [(path: [UInt8], id: UInt32)]
        private var tables: [UInt32: [UInt64: UInt32]] = [:]
        private var known: [String: UInt32] = [:]

        init(_ tree: DiskTree) {
            self.tree = tree
            anchors = tree.anchors.map { (Array($0.path.utf8), $0.id) }
        }

        func deepest(_ path: String) -> UInt32? {
            if let hit = known[path] { return hit }
            let bytes = Array(path.utf8)
            var best: (length: Int, id: UInt32)?
            for anchor in anchors where bytes.count >= anchor.path.count && anchor.path.count > (best?.length ?? -1)
                && bytes.starts(with: anchor.path) && (bytes.count == anchor.path.count || bytes[anchor.path.count] == 0x2F) {
                best = (anchor.path.count, anchor.id)
            }
            guard let best else { return nil }
            var node = best.id
            var at = best.length
            while at < bytes.count {
                at += 1
                var end = at
                while end < bytes.count && bytes[end] != 0x2F { end += 1 }
                guard end > at, let next = child(of: node, bytes, at, end - at) else { break }
                node = next
                at = end
            }
            known[path] = node
            return node
        }

        private func child(of folder: UInt32, _ bytes: [UInt8], _ start: Int, _ length: Int) -> UInt32? {
            let nodes = tree.nodes, names = tree.names
            return bytes.withUnsafeBufferPointer { b -> UInt32? in
                let name = b.baseAddress! + start
                func matches(_ c: UInt32) -> Bool {
                    let n = nodes[Int(c)]
                    return Int(n.nameLength) == length && memcmp(names + Int(n.nameOffset), name, length) == 0
                }
                if let table = tables[folder] ?? makeTable(folder) {
                    guard let c = table[RuleBook.hash(name, length)] else { return nil }
                    if c != UInt32.max { return matches(c) ? c : nil }
                }
                var c = nodes[Int(folder)].firstChild
                while c != 0 {
                    if matches(c) { return c }
                    c = nodes[Int(c)].nextSibling
                }
                return nil
            }
        }

        /// Only for folders with many things in them. Two names with the same hash send the lookup back to the list.
        private func makeTable(_ folder: UInt32) -> [UInt64: UInt32]? {
            let nodes = tree.nodes, names = tree.names
            var count = 0
            var c = nodes[Int(folder)].firstChild
            while c != 0 && count <= 64 { count += 1; c = nodes[Int(c)].nextSibling }
            guard count > 64 else { return nil }
            var table: [UInt64: UInt32] = [:]
            c = nodes[Int(folder)].firstChild
            while c != 0 {
                let n = nodes[Int(c)]
                let hash = RuleBook.hash(UnsafePointer(names + Int(n.nameOffset)), Int(n.nameLength))
                table[hash] = table[hash] == nil ? c : UInt32.max
                c = n.nextSibling
            }
            tables[folder] = table
            return table
        }
    }

    /// Reads the disk, then adds it all up. `tick` is called now and then from another thread, for as long as the workers
    /// are reading and never after, because adding up writes to the totals.
    func run(mode: ScanMode, threads: Int = max(8, ProcessInfo.processInfo.activeProcessorCount), tick: @escaping () -> Void = {}) {
        let start = DispatchTime.now()
        let began = Date()
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 }
        if mode == .quiet { scanner.slowDown() }
        if mode == .full {
            scanner.stopKeepingOrder()
            scanner.setHurry(true)
        }

        let stop = LockedFlag()
        let stopped = DispatchSemaphore(value: 0)
        // The first look is over once new bytes stop pouring in: under 4% of the used space per second.
        let enough = Double(max(facts.isBoot ? facts.data : facts.used, 1)) * 0.04
        Thread.detachNewThread { [self] in
            defer { stopped.signal() }
            var looking = mode == .firstLook
            var recent: [(time: Double, known: Double)] = []
            var wasBusy: Bool?
            while !stop.value {
                // Pictures come quickly while the first look fills the map, and while what you're looking at is being read.
                let quick = looking || scanner.hasUrgentWork
                let busy = quick || !scanner.isQuiet
                if busy != wasBusy {
                    pthread_set_qos_class_self_np(busy ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY, 0)
                    wasBusy = busy
                }
                let began = elapsed()
                tick()
                // A picture of a huge disk takes a moment to make, so it can never take up much of a core.
                let cost = elapsed() - began
                // With a saved map on screen, a turn only updates the count of files, which costs nothing.
                _ = wakeTick.wait(timeout: .now() + (quick ? max(0.1, cost * 2) : max(mode == .quiet ? 0.5 : 1.5, cost * 8)))
                guard looking else { continue }
                // Measured over a moment, because the bytes arrive in lumps.
                let now = elapsed(), known = Double(knownBytes())
                recent.append((now, known))
                while recent.count > 1, now - recent[1].time >= 0.3 { recent.removeFirst() }
                let rate = (known - recent[0].known) / max(now - recent[0].time, 0.01)
                if now >= 4 || (now >= 1.5 && rate < enough) {
                    // With no saved map, you're waiting for the whole disk, so the rest is read at full power too. Only the
                    // order stops mattering, and the cheapest order wins.
                    scanner.stopKeepingOrder()
                    looking = false
                }
            }
        }
        scanner.run(threads: threads)
        stop.value = true
        wakeTick.signal()
        stopped.wait()
        scanner.endRefresh()
        let links = scanner.collectedLinks()
        if let known {
            Accounting.groupByKey(links)
            if Accounting.hasNewHardLinks(links, known: known) {
                surprised = true
                scanner.freeLinks()
                return
            }
        }
        Accounting.settleLinks(links, in: tree)
        scanner.freeLinks()
        reconcile(tree)
        tree.finish(totalsReady: true)
        tree.compactStats()
        tree.compactNames()
        tree.scanSeconds = elapsed()
        tree.finishedAt = Date()
        tree.isWhole = !scanner.wasCancelled
        tree.journal = place
        tree.fullReadAt = fullReadAt ?? began
        tree.readGuarded = scanner.touchGuarded
    }

    private let wakeTick = DispatchSemaphore(value: 0)

    /// The next picture is wanted now, not at the next turn.
    func tickSoon() { wakeTick.signal() }

    /// Bytes found so far, not counting what the disk reported up front.
    func knownBytes() -> UInt64 { scanner.bytesSoFar }

    /// A finished-looking copy of where the scan has got to, for the interface to read.
    func picture() -> DiskTree {
        tree.count = scanner.nodesSoFar
        let copy = tree.picture()
        reconcile(copy)
        copy.displayNames[copy.hidden] = "Not scanned yet"
        copy.finish(totalsReady: true)
        return copy
    }

    /// What the volume reports using, minus what the scan found, is the Hidden piece. The ring then equals the disk. It adds
    /// the totals up, and leaves them right for the new Hidden piece, so nothing has to add them up again.
    func reconcile(_ tree: DiskTree) {
        tree.sumTotals()
        let nodes = tree.nodes
        let hidden = Int(tree.hidden), before = tree.totals[hidden]
        defer {
            // Hidden holds nothing and sits right under the top, so only those two totals change.
            tree.totals[hidden] = nodes[hidden].bytes
            tree.totals[0] = tree.totals[0] &- before &+ nodes[hidden].bytes
        }
        if facts.isBoot {
            var scanned: UInt64 = tree.totals[Int(tree.home)]
            var c = nodes[0].firstChild
            while c != 0 {
                let n = nodes[Int(c)]
                if !n.has(NodeFlag.synthetic) && c != tree.home { scanned &+= tree.totals[Int(c)] }
                c = n.nextSibling
            }
            var g = nodes[Int(systemGroup)].firstChild
            while g != 0 {
                let n = nodes[Int(g)]
                if !n.has(NodeFlag.synthetic) { scanned &+= tree.totals[Int(g)] }
                g = n.nextSibling
            }
            nodes[Int(tree.hidden)].bytes = facts.data > scanned ? facts.data - scanned : 0
        } else {
            let used = facts.used
            let scanned = tree.totals[Int(nodes[Int(tree.hidden)].parent)] &- tree.totals[Int(tree.free)] &- tree.totals[Int(tree.hidden)]
            nodes[Int(tree.hidden)].bytes = used > scanned ? used - scanned : 0
        }
    }

    /// Whether this app may read everything. These folders only ever open with Full Disk Access, and asking about them
    /// never brings up a prompt: without it the answer is simply "not permitted".
    static func hasFullDiskAccess() -> Bool {
        let home = NSHomeDirectory()
        for probe in ["/Library/Safari", "/Library/Mail", "/Library/Messages", "/Library/Cookies", "/.Trash"] {
            let fd = open(home + probe, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }
}

/// Why what you'd get back differs from what a folder adds up to.
struct LinkStory: Equatable {
    var reclaim: UInt64
    /// Counted here, but also linked from somewhere else, so removing this alone doesn't free it.
    var sharedOut: UInt64 = 0
    var sharedPlace: String?
    /// How much of that is with `sharedPlace`, the folder that has the most of it, and how much of that is clones.
    var sharedWithPlace: UInt64 = 0
    var clonesWithPlace: UInt64 = 0
    var sharedPlaceNode: UInt32?
    /// Links here to files counted somewhere else.
    var linkedIn: UInt64 = 0
    var linkedPlace: String?
    var linkedPlaceNode: UInt32?

    /// The folders worth going to: they hold enough of the same files to matter, for something this size.
    func placesWorthNaming(size: UInt64) -> [(path: String, node: UInt32)] {
        func matters(_ bytes: UInt64) -> Bool { bytes >= 50_000_000 || (bytes > 0 && Double(bytes) >= Double(size) * 0.1) }
        var places: [(path: String, node: UInt32)] = []
        if matters(sharedOut), let sharedPlace, let sharedPlaceNode { places.append((sharedPlace, sharedPlaceNode)) }
        if matters(linkedIn), let linkedPlace, let linkedPlaceNode, linkedPlaceNode != sharedPlaceNode { places.append((linkedPlace, linkedPlaceNode)) }
        return places
    }
}

/// Keeps "how much you'd get back" honest when files have more than one path.
enum Accounting {
    static func story(_ node: UInt32, in tree: DiskTree) -> LinkStory {
        var story = LinkStory(reclaim: tree.totals[Int(node)])
        let links = tree.links
        guard !links.isEmpty else { return story }
        let nodes = tree.nodes
        var outPlaces: [UInt32: (bytes: UInt64, clones: UInt64)] = [:]
        var inPlaces: [UInt32: UInt64] = [:]
        /// The folder to name: the nearest one that doesn't also contain this node.
        func place(_ dir: UInt32) -> UInt32 {
            var a = dir
            while true {
                let up = nodes[Int(a)].parent
                if up == 0 || up == tree.home || tree.isInside(node, up) { return a }
                a = up
            }
        }
        var start = 0
        while start < links.count {
            var end = start + 1
            while end < links.count && links[end].key == links[start].key { end += 1 }
            defer { start = end }
            var anyInside = false, countedInside = false
            var outside: UInt32?, counted: UInt32?
            for i in start..<end {
                let r = links[i]
                if tree.isInside(r.dir, node) || r.file == node {
                    anyInside = true
                    if r.counted { countedInside = true }
                } else {
                    outside = r.dir
                    if r.counted { counted = r.dir }
                }
            }
            guard anyInside else { continue }
            let bytes = links[start].bytes
            if countedInside, let outside {
                story.sharedOut &+= bytes
                story.reclaim = story.reclaim &- min(story.reclaim, bytes)
                let folder = place(outside)
                var shared = outPlaces[folder] ?? (0, 0)
                shared.bytes &+= bytes
                if links[start].isClone { shared.clones &+= bytes }
                outPlaces[folder] = shared
            } else if !countedInside, let counted {
                story.linkedIn &+= bytes
                inPlaces[place(counted), default: 0] &+= bytes
            }
        }
        if let top = outPlaces.max(by: { $0.value.bytes < $1.value.bytes }) {
            story.sharedPlace = tree.friendlyPath(top.key)
            story.sharedPlaceNode = top.key
            story.sharedWithPlace = top.value.bytes
            story.clonesWithPlace = top.value.clones
        }
        if let top = inPlaces.max(by: { $0.value < $1.value }) {
            story.linkedPlace = tree.friendlyPath(top.key)
            story.linkedPlaceNode = top.key
        }
        return story
    }

    /// What the middle of the ring says about something that wouldn't all come back if it went: what it is, and where the other
    /// path is. A folder can't be a hard link, but what's in it can. Most things say nothing, which is the quick part to find out.
    static func hoverLine(_ node: UInt32, bytes: UInt64, in tree: DiskTree) -> String? {
        guard Double(reclaimable([node], in: tree)) < Double(bytes) * 0.9 else { return nil }
        let story = story(node, in: tree)
        guard let place = story.sharedPlace else { return nil }
        let isClones = story.clonesWithPlace > story.sharedWithPlace / 2
        let isFile = !tree.nodes[Int(node)].has(NodeFlag.directory)
        let name = isClones ? (isFile ? "Clone of" : "Clones of") : (isFile ? "Hardlink to" : "Hardlinks to")
        if Double(story.sharedWithPlace) >= Double(bytes) * 0.99 { return "\(name) \(place)" }
        return "\(formatBytes(story.sharedWithPlace)) in \(name.lowercased()) \(place)"
    }

    /// Hard links and clones were counted by whichever worker saw them first, unless they were somewhere shy. This settles
    /// each one in a stable place, the one you'd call its home: not a cache, not Downloads, and the same on every scan.
    static func settleLinks(_ links: UnsafeMutableBufferPointer<LinkRecord>, in tree: DiskTree) {
        groupByKey(links)
        let nodes = tree.nodes
        let home = tree.home
        var downloads: UInt32 = 0
        // In your home folder, or at the top of any other disk.
        var top = home
        if top == 0 {
            var c = nodes[0].firstChild
            while c != 0 {
                if nodes[Int(c)].has(NodeFlag.anchor) { top = c; break }
                c = nodes[Int(c)].nextSibling
            }
        }
        if top != 0 {
            var c = nodes[Int(top)].firstChild
            while c != 0 {
                if tree.name(c) == "Downloads" { downloads = c; break }
                c = nodes[Int(c)].nextSibling
            }
        }
        let now = UInt32(seconds: Date().timeIntervalSince1970)
        func isUnder(_ id: UInt32, _ ancestor: UInt32) -> Bool {
            var i = id
            while i != 0 {
                if i == ancestor { return true }
                i = nodes[Int(i)].parent
            }
            return false
        }
        func score(_ record: LinkRecord) -> UInt64 {
            var value: UInt64 = 0
            if nodes[Int(record.dir)].rule != 0 { value += 1 << 40 }
            if downloads != 0 && isUnder(record.dir, downloads) { value += 1 << 39 }
            // The same record wins on every scan: shortest path, then its name's hash.
            var depth: UInt64 = 0
            var hash: UInt64 = 0
            var i = record.dir
            while i != 0 {
                let n = nodes[Int(i)]
                depth += 1
                hash = hash &* 31 &+ RuleBook.hash(UnsafePointer(tree.names + Int(n.nameOffset)), Int(n.nameLength))
                i = n.parent
            }
            return value + depth << 24 + (hash & 0xFFFFFF)
        }

        // Files with one path need no further thought, so only real groups are kept: moved up to the front, in place. Hard
        // links with one path here have others somewhere the scan doesn't go, and a refresh needs to know them.
        var singles: [LinkRecord] = []
        var count = 0
        var start = 0
        while start < links.count {
            var end = start + 1
            while end < links.count && links[end].key == links[start].key { end += 1 }
            defer { start = end }
            let counted = (start..<end).first(where: { links[$0].counted })
            if end - start == 1 {
                // Only one path after all, so it's this one's to count.
                if counted == nil { claim(links[start], in: tree, now: now) }
                if !links[start].isClone {
                    var record = links[start]
                    record.counted = true
                    singles.append(record)
                }
                continue
            }

            var primary = start
            var best = UInt64.max
            for i in start..<end {
                let s = score(links[i])
                if s < best { best = s; primary = i }
            }
            if counted != primary {
                if let counted { release(links[counted], in: tree, now: now) }
                claim(links[primary], in: tree, now: now)
            }
            for i in start..<end {
                var record = links[i]
                record.counted = i == primary
                links[count] = record
                count += 1
            }
        }
        let groups = UnsafeMutableBufferPointer(rebasing: links[0..<count])
        tree.links = Array(groups.prefix(merge(groups)))
        tree.singleLinks = singles
    }

    /// After a refresh: whether a hard link turned up whose file has paths that weren't seen, and whose key the map didn't
    /// know. It's new, and the file's other path may be in a folder that was copied, where the file is still counted.
    /// The records have to be grouped by key.
    static func hasNewHardLinks(_ links: UnsafeMutableBufferPointer<LinkRecord>, known: Set<UInt64>) -> Bool {
        var start = 0
        while start < links.count {
            var end = start + 1
            while end < links.count && links[end].key == links[start].key { end += 1 }
            defer { start = end }
            guard !links[start].isClone, !known.contains(links[start].key) else { continue }
            var paths = 0
            for i in start..<end { paths = max(paths, Int(links[i].paths)) }
            if end - start < paths { return true }
        }
        return false
    }

    /// Puts each file's records next to each other, without asking for more memory than it gives straight back.
    static func groupByKey(_ links: UnsafeMutableBufferPointer<LinkRecord>) {
        guard links.count > 1, let base = links.baseAddress else { return }
        let digits = 1 << 16
        let spare = vmAlloc(LinkRecord.self, links.count)
        let starts = vmAlloc(Int.self, digits)
        defer {
            vmFree(spare, links.count)
            vmFree(starts, digits)
        }
        var from = base, to = spare
        for shift in stride(from: 0, to: 64, by: 16) {
            memset(starts, 0, digits * MemoryLayout<Int>.stride)
            for at in 0..<links.count { starts[Int((from[at].key >> UInt64(shift)) & 0xFFFF)] += 1 }
            // Nothing to do for a part they all have in common.
            if starts[Int((from[0].key >> UInt64(shift)) & 0xFFFF)] == links.count { continue }
            var sum = 0
            for digit in 0..<digits {
                let many = starts[digit]
                starts[digit] = sum
                sum += many
            }
            for at in 0..<links.count {
                let digit = Int((from[at].key >> UInt64(shift)) & 0xFFFF)
                to[starts[digit]] = from[at]
                starts[digit] += 1
            }
            swap(&from, &to)
        }
        if from != base { memcpy(base, from, links.count * MemoryLayout<LinkRecord>.stride) }
    }

    /// Leaves the same links with no repeats. A folder full of linked files says the same places over and over, and everything
    /// that reads these looks at one group at a time and only adds up its bytes. So groups with the same paths can be one
    /// group with their bytes added together, and one whose paths are all in one place can't change any answer at all.
    /// A group's records have to be next to each other.
    static func merge(_ records: inout [LinkRecord]) {
        let count = records.withUnsafeMutableBufferPointer { merge($0) }
        // Exactly as big as it has to be, because this stays for as long as the tree does.
        records = records.withUnsafeBufferPointer { Array($0.prefix(count)) }
    }

    /// In place, and says how many are left at the front.
    static func merge(_ links: UnsafeMutableBufferPointer<LinkRecord>) -> Int {
        var count = 0
        var seen: [UInt64: (at: Int, count: Int)] = [:]
        var start = 0
        while start < links.count {
            var end = start + 1
            while end < links.count && links[end].key == links[start].key { end += 1 }
            defer { start = end }
            let size = end - start
            // In the same order, however the workers happened to find them.
            links[start..<end].sort { ($0.dir, $0.file) < ($1.dir, $1.file) }
            // A hard link with paths the scan doesn't reach stays as it is, so a refresh still knows its key.
            var paths = 0
            for i in start..<end { paths = max(paths, Int(links[i].paths)) }
            if links[start].isClone || size >= paths {
                if links[start].dir == links[end - 1].dir, links[start].file == links[end - 1].file { continue }
            } else {
                for i in start..<end {
                    links[count] = links[i]
                    count += 1
                }
                continue
            }
            var hash = UInt64(size)
            for i in start..<end {
                let r = links[i]
                hash = (hash ^ UInt64(r.dir) ^ UInt64(r.file) << 32 ^ UInt64(r.kind) << 8 ^ (r.counted ? 1 : 0) ^ (r.isClone ? 2 : 0)) &* 0x9E37_79B9_7F4A_7C15
                hash ^= hash >> 29
            }
            if let same = seen[hash] {
                let isSame = same.count == size && (0..<size).allSatisfy { at in
                    let a = links[same.at + at], b = links[start + at]
                    return a.dir == b.dir && a.file == b.file && a.kind == b.kind && a.counted == b.counted && a.isClone == b.isClone
                }
                if isSame {
                    for at in 0..<size { links[same.at + at].bytes &+= links[start].bytes }
                    continue
                }
            } else {
                seen[hash] = (count, size)
            }
            // What's been kept so far is always behind where this is reading.
            for i in start..<end {
                links[count] = links[i]
                count += 1
            }
        }
        return count
    }

    /// This path now counts the file's bytes.
    private static func claim(_ r: LinkRecord, in tree: DiskTree, now: UInt32) {
        let nodes = tree.nodes
        if r.file != 0 {
            nodes[Int(r.file)].bytes = r.bytes
            nodes[Int(r.file)].aliasBytes = 0
            nodes[Int(r.file)].flags &= ~NodeFlag.alias
        } else {
            nodes[Int(r.dir)].bytes &+= r.bytes
        }
        nodes[Int(r.dir)].aliasBytes &-= min(nodes[Int(r.dir)].aliasBytes, r.bytes)
        adjustStats(r, in: tree, now: now) { $0 &+ $1 }
    }

    /// This path no longer counts the file's bytes: another one does.
    private static func release(_ r: LinkRecord, in tree: DiskTree, now: UInt32) {
        let nodes = tree.nodes
        if r.file != 0 {
            nodes[Int(r.file)].bytes = 0
            nodes[Int(r.file)].aliasBytes = r.bytes
            nodes[Int(r.file)].flags |= NodeFlag.alias
        } else {
            nodes[Int(r.dir)].bytes &-= min(nodes[Int(r.dir)].bytes, r.bytes)
        }
        nodes[Int(r.dir)].aliasBytes &+= r.bytes
        adjustStats(r, in: tree, now: now) { $0 &- min($0, $1) }
    }

    /// Its kind and its date move with it, or Changes would blame whichever folder a worker happened to reach first.
    private static func adjustStats(_ r: LinkRecord, in tree: DiskTree, now: UInt32, _ apply: (UInt32, UInt32) -> UInt32) {
        let units = UInt32(truncatingIfNeeded: (r.bytes &+ 8191) >> 14)
        let s = tree.changeableStatRow(r.dir)
        s[Int(r.kind)] = apply(s[Int(r.kind)], units)
        for (field, days) in DiskTree.recency where r.when >= now &- days * 86_400 {
            s[field] = apply(s[field], units)
        }
    }

    /// What you'd really get back by removing these nodes. A file with another path outside them frees nothing, and
    /// a file whose paths are all inside them frees its bytes once.
    static func reclaimable(_ ids: [UInt32], in tree: DiskTree) -> UInt64 {
        let set = NodeSet(ids, in: tree)
        var total: UInt64 = 0
        for id in set.tops { total &+= tree.totals[Int(id)] }
        let links = tree.links
        guard !links.isEmpty else { return total }
        var start = 0
        while start < links.count {
            var end = start + 1
            while end < links.count && links[end].key == links[start].key { end += 1 }
            defer { start = end }
            var all = true, countedInside = false
            for i in start..<end {
                if set.holds(links[i]) {
                    if links[i].counted { countedInside = true }
                } else {
                    all = false
                }
            }
            if countedInside && !all { total = total &- min(total, links[start].bytes) }
        }
        return total
    }
}
