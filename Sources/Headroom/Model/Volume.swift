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

    private static func spaceUsed(_ path: String) -> UInt64 {
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
            facts.data = spaceUsed(PathMath.dataVolume)
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
    case firstLook  // nothing on screen yet: big things first, then the rest in the cheapest order, all at full power
    case quiet  // the map is already there: low priority from the start
    case full  // you asked for it: full power to the end
}

/// Starts a scan of one disk and builds the top of the tree so that the whole ring adds up to the disk.
final class DiskScan: @unchecked Sendable {
    let tree: DiskTree
    let facts: VolumeFacts
    let rules: RuleBook
    let scanner: Scanner
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
        let tree = DiskTree()
        tree.volumeName = facts.name
        tree.capacityBytes = facts.capacity
        tree.freeBytes = facts.free
        tree.rootPath = facts.mountPath
        self.tree = tree
        self.facts = facts
        self.rules = rules
        scanner = Scanner(tree: tree, rules: rules, touchGuarded: fullAccess)
        if facts.isBoot { planBootDisk() } else { planExternalDisk() }
    }

    private func planBootDisk() {
        let f = NodeFlag.self
        _ = scanner.addNode(parent: 0, display: facts.shownName, flags: f.synthetic | f.directory)
        let dataRoot = PathMath.dataVolume
        let home = NSHomeDirectory()
        let homeInData = dataRoot + home

        let (homeState, homeRule) = walk(home)
        let you = scanner.addNode(
            parent: 0, display: "Your files", flags: f.anchor | f.directory, rule: homeRule, path: homeInData, ruleState: homeState)
        scanner.setHome(you)
        tree.home = you

        let (appsState, appsRule) = walk("/Applications")
        _ = scanner.addNode(
            parent: 0, display: "Apps", flags: f.anchor | f.directory, rule: appsRule, kind: .app, path: dataRoot + "/Applications",
            ruleState: appsState)

        let system = scanner.addNode(parent: 0, display: "System", flags: f.synthetic | f.directory, kind: .system)
        systemGroup = system
        _ = scanner.addNode(parent: system, display: "macOS", flags: f.synthetic, bytes: facts.system, rule: rules.macOSRule, kind: .system)
        _ = scanner.addNode(
            parent: system, display: "Startup and updates", flags: f.synthetic, bytes: facts.preboot + facts.update, rule: rules.updatesRule,
            kind: .system)
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
                _ = scanner.addNode(
                    parent: system, display: "/System", flags: f.anchor | f.directory, rule: rule, kind: .system, path: inner, ruleState: state)
            } else {
                let (state, rule) = walk("/" + name)
                _ = scanner.addNode(
                    parent: system, display: "/" + name, flags: f.anchor | f.directory, rule: rule, kind: .system, path: path, ruleState: state)
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
        // An array's buffer has an address even when it's empty.
        // swift-format-ignore: NeverForceUnwrap
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
        let prefix = facts.isBoot ? PathMath.dataVolume : ""
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
            if nodes[i].flags & (NodeFlag.denied | NodeFlag.unread) != 0 {
                unread += 1
            } else if day[i] != 0 && nodes[i].modTime >= dayAgo {
                lastDay += 1
            }
        }
        for r in base.links { linked.insert(r.dir) }
        for r in base.singleLinks { linked.insert(r.dir) }
        whyRead =
            "\(changed) changed, \(linked.count) with linked files, \(lastDay) with something from the last day, \(unread) that couldn't be read"

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
            for anchor in anchors
            where bytes.count >= anchor.path.count && anchor.path.count > (best?.length ?? -1)
                && bytes.starts(with: anchor.path) && (bytes.count == anchor.path.count || bytes[anchor.path.count] == 0x2F)
            {
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
                // Not empty: the caller passes a name of at least one byte.
                // swift-format-ignore: NeverForceUnwrap
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
        let copy = tree.picture(upTo: scanner.nodesSoFar)
        reconcile(copy)
        copy.displayNames[copy.hidden] = "Not scanned yet"
        copy.finish(totalsReady: true)
        return copy
    }

    /// What the volume reports using, minus what the scan found, is the Hidden piece. The ring then equals the disk. It adds
    /// the totals up, and leaves them right for the new Hidden piece, so nothing has to add them up again.
    private func reconcile(_ tree: DiskTree) {
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
