import Foundation

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
        if matters(linkedIn), let linkedPlace, let linkedPlaceNode, linkedPlaceNode != sharedPlaceNode {
            places.append((linkedPlace, linkedPlaceNode))
        }
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
        // In your home folder, or at the top of any other disk.
        var top = tree.home
        if top == 0 {
            var c = nodes[0].firstChild
            while c != 0 {
                if nodes[Int(c)].has(NodeFlag.anchor) { top = c; break }
                c = nodes[Int(c)].nextSibling
            }
        }
        let downloads = top == 0 ? 0 : tree.child(of: top, named: "Downloads") ?? 0
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
                hash =
                    (hash ^ UInt64(r.dir) ^ UInt64(r.file) << 32 ^ UInt64(r.kind) << 8 ^ (r.counted ? 1 : 0) ^ (r.isClone ? 2 : 0))
                    &* 0x9E37_79B9_7F4A_7C15
                hash ^= hash >> 29
            }
            if let same = seen[hash] {
                let isSame =
                    same.count == size
                    && (0..<size).allSatisfy { at in
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
        let units = DiskTree.units(bytes: r.bytes)
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
