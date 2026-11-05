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
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey])
        var facts = VolumeFacts(
            name: values?.volumeLocalizedName ?? url.lastPathComponent,
            mountPath: path,
            capacity: UInt64(info.f_blocks) * block,
            free: UInt64(info.f_bavail) * block,
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
    case firstLook      // nothing on screen yet: full power until the big things are found, then quiet
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

    init(facts: VolumeFacts, rules: RuleBook, fullAccess: Bool, askPerFolder: Bool) {
        self.facts = facts
        self.rules = rules
        tree.volumeName = facts.name
        tree.capacityBytes = facts.capacity
        tree.freeBytes = facts.free
        tree.rootPath = facts.mountPath
        scanner = Scanner(tree: tree, rules: rules, touchGuarded: fullAccess || askPerFolder)
        if facts.isBoot { planBootDisk() } else { planExternalDisk() }
    }

    private func planBootDisk() {
        let f = NodeFlag.self
        _ = scanner.addNode(parent: 0, display: facts.name, flags: f.synthetic | f.directory)
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
        _ = scanner.addNode(parent: 0, display: facts.name, flags: f.synthetic | f.directory)
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

    /// Reads the disk, then adds it all up. `tick` is called now and then from another thread, for as long as the workers
    /// are reading and never after, because adding up writes to the totals.
    func run(mode: ScanMode, threads: Int = max(8, ProcessInfo.processInfo.activeProcessorCount), tick: @escaping () -> Void = {}) {
        let start = DispatchTime.now()
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
            var wasQuick: Bool?
            while !stop.value {
                let quick = looking || !scanner.isQuiet || scanner.hasUrgentWork
                if quick != wasQuick {
                    pthread_set_qos_class_self_np(quick ? QOS_CLASS_USER_INITIATED : QOS_CLASS_UTILITY, 0)
                    wasQuick = quick
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
                    scanner.slowDown()
                    looking = false
                }
            }
        }
        scanner.run(threads: threads)
        stop.value = true
        wakeTick.signal()
        stopped.wait()
        Accounting.settleLinks(scanner.collectedLinks(), in: tree)
        scanner.freeLinks()
        reconcile(tree)
        tree.finish()
        tree.scanSeconds = elapsed()
        tree.finishedAt = Date()
    }

    private let wakeTick = DispatchSemaphore(value: 0)

    /// The next picture is wanted now, not at the next turn.
    func tickSoon() { wakeTick.signal() }

    /// Bytes found so far, not counting what the disk reported up front.
    func knownBytes() -> UInt64 {
        var sum: UInt64 = 0
        for i in 0..<scanner.nodesSoFar where !tree.nodes[i].has(NodeFlag.synthetic) { sum &+= tree.nodes[i].bytes }
        return sum
    }

    /// A finished-looking copy of where the scan has got to, for the interface to read.
    func picture() -> DiskTree {
        tree.count = scanner.nodesSoFar
        let copy = tree.picture()
        reconcile(copy)
        copy.displayNames[copy.hidden] = "Still reading"
        copy.finish()
        return copy
    }

    /// What the volume reports using, minus what the scan found, is the Hidden piece. The ring then equals the disk.
    func reconcile(_ tree: DiskTree) {
        tree.sumTotals()
        let nodes = tree.nodes
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
    /// Links here to files counted somewhere else.
    var linkedIn: UInt64 = 0
    var linkedPlace: String?
}

/// Keeps "how much you'd get back" honest when files have more than one path.
enum Accounting {
    static func story(_ node: UInt32, in tree: DiskTree) -> LinkStory {
        var story = LinkStory(reclaim: tree.totals[Int(node)])
        let links = tree.links
        guard !links.isEmpty else { return story }
        let nodes = tree.nodes
        var outPlaces: [UInt32: UInt64] = [:]
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
                outPlaces[place(outside), default: 0] &+= bytes
            } else if !countedInside, let counted {
                story.linkedIn &+= bytes
                inPlaces[place(counted), default: 0] &+= bytes
            }
        }
        if let top = outPlaces.max(by: { $0.value < $1.value }) { story.sharedPlace = tree.friendlyPath(top.key) }
        if let top = inPlaces.max(by: { $0.value < $1.value }) { story.linkedPlace = tree.friendlyPath(top.key) }
        return story
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
        let now = UInt32(Date().timeIntervalSince1970)
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

        // Files with one path need no further thought, so only real groups are kept: moved up to the front, in place.
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
    private static func merge(_ links: UnsafeMutableBufferPointer<LinkRecord>) -> Int {
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
            if links[start].dir == links[end - 1].dir, links[start].file == links[end - 1].file { continue }
            var hash = UInt64(size)
            for i in start..<end {
                let r = links[i]
                hash = (hash ^ UInt64(r.dir) ^ UInt64(r.file) << 32 ^ UInt64(r.kind) << 8 ^ (r.counted ? 1 : 0)) &* 0x9E37_79B9_7F4A_7C15
                hash ^= hash >> 29
            }
            if let same = seen[hash] {
                let isSame = same.count == size && (0..<size).allSatisfy { at in
                    let a = links[same.at + at], b = links[start + at]
                    return a.dir == b.dir && a.file == b.file && a.kind == b.kind && a.counted == b.counted
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
        let s = tree.stats + Int(r.dir) * DiskTree.statStride
        s[Int(r.kind)] = apply(s[Int(r.kind)], units)
        let day: UInt32 = 86_400
        for (field, age) in [(DiskTree.statRecent1, day), (DiskTree.statRecent7, 7 * day), (DiskTree.statRecent14, 14 * day), (DiskTree.statRecent30, 30 * day)]
        where r.when >= now &- age {
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
