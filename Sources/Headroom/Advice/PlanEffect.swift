import Foundation

/// What the plan would give back: in all, for each planned thing, and the disk as it would be afterwards. Worked out
/// together on another thread, a moment after the plan or the map changes, and replaced together when it arrives.
struct PlanNumbers {
    var total: UInt64 = 0
    var byItem: [String: UInt64] = [:]
    var after: AfterPlan?
}

/// What the plan does to the numbers: what you'd really get back, in total and per thing.
struct PlanEffect {
    var total: UInt64 = 0
    /// What the plan's folders add up to, which can be more than you'd get back.
    var paper: UInt64 = 0
    var perTop: [UInt32: UInt64] = [:]
}

extension NodeSet {
    /// Whether this path of a file is in the set. A big file has its own node, which can be in the set by itself.
    @inline(__always) func holds(_ record: LinkRecord) -> Bool {
        contains(record.dir) || (record.file != 0 && contains(record.file))
    }
}

extension Accounting {
    /// What you'd really get back by removing these, less what was taken back. A file with another path outside them
    /// frees nothing, and a file whose paths are all inside them frees its bytes once.
    static func effect(of ids: [UInt32], except excluded: [UInt32], in tree: DiskTree) -> PlanEffect {
        let set = NodeSet(ids, in: tree)
        let back = NodeSet(excluded, in: tree)
        var out = PlanEffect()
        for top in set.tops {
            var bytes = tree.totals[Int(top)]
            for x in back.tops where tree.isInside(x, top) && x != top { bytes &-= min(bytes, tree.totals[Int(x)]) }
            if back.contains(top) { bytes = 0 }
            out.perTop[top] = bytes
            out.paper &+= bytes
        }
        out.total = out.paper
        let links = tree.links
        guard !links.isEmpty else { return out }
        var start = 0
        while start < links.count {
            var end = start + 1
            while end < links.count && links[end].key == links[start].key { end += 1 }
            defer { start = end }
            var all = true
            var countedIn: LinkRecord?
            for i in start..<end {
                if set.holds(links[i]), !back.holds(links[i]) {
                    if links[i].counted { countedIn = links[i] }
                } else {
                    all = false
                }
            }
            if let countedIn, !all, let top = set.top(containing: countedIn.file != 0 ? countedIn.file : countedIn.dir) {
                let bytes = links[start].bytes
                out.total &-= min(out.total, bytes)
                out.perTop[top] = (out.perTop[top] ?? 0) &- min(out.perTop[top] ?? 0, bytes)
            }
        }
        return out
    }

    /// The other places that hold the same files as these: only what's really those files. A file with two paths only frees
    /// its space when both are gone. A folder is named only if it holds little else, and otherwise it's the files one by one.
    static func otherCopies(of nodes: [UInt32], in tree: DiskTree, links given: [LinkRecord]? = nil) -> (folders: [UInt32], bytes: UInt64) {
        let links = given ?? tree.links
        guard !links.isEmpty else { return ([], 0) }
        let set = NodeSet(nodes, in: tree)
        var inFolder: [UInt32: UInt64] = [:]
        var filesInFolder: [UInt32: [UInt32]] = [:]
        var bytes: UInt64 = 0
        var start = 0
        while start < links.count {
            var end = start + 1
            while end < links.count && links[end].key == links[start].key { end += 1 }
            defer { start = end }
            var inside = false, counted = false
            for i in start..<end where set.holds(links[i]) {
                inside = true
                if links[i].counted { counted = true }
            }
            guard inside, counted else { continue }
            var any = false
            for i in start..<end where !set.holds(links[i]) {
                inFolder[links[i].dir, default: 0] &+= links[i].bytes
                if links[i].file != 0 { filesInFolder[links[i].dir, default: []].append(links[i].file) }
                any = true
            }
            if any { bytes &+= links[start].bytes }
        }
        guard !inFolder.isEmpty else { return ([], 0) }
        func holds(_ folder: UInt32) -> UInt64 { tree.totals[Int(folder)] &+ tree.aliasTotals[Int(folder)] }
        var nameable: [UInt32: Bool] = [:]
        func mayName(_ folder: UInt32) -> Bool {
            if let known = nameable[folder] { return known }
            var answer = false
            if folder != 0, folder != tree.home, !set.contains(folder), !tree.nodes[Int(folder)].has(NodeFlag.anchor),
                !Titles.isGeneralFolder(tree.rawName(folder)), let path = tree.path(folder)
            {
                answer = Safety.canTrash(path)
            }
            nameable[folder] = answer
            return answer
        }
        // Where each copy starts: its folder if the folder is nothing else, otherwise each file.
        var tops = Set<UInt32>()
        var covered: [UInt32: UInt64] = [:]
        for (folder, amount) in inFolder {
            if Double(amount) >= Double(holds(folder)) * 0.95, mayName(folder) {
                tops.insert(folder)
                covered[folder] = amount
            } else {
                for file in filesInFolder[folder] ?? [] { tops.insert(file) }
            }
        }
        climb(&tops, covered: &covered, parent: { tree.nodes[Int($0)].parent }, mayName: mayName, holds: holds)
        // The biggest first, because the first is the one that gets named.
        let biggestFirst = tops.sorted { holds($0) != holds($1) ? holds($0) > holds($1) : $0 < $1 }
        return (biggestFirst, bytes)
    }

    /// Up from each folder, for as long as the one above holds little else. Season folders become their show's folder. The deepest
    /// go first, so each folder is looked at once, holding all it ever will. Thousands of copies cost little more than a few, and
    /// the answer doesn't depend on the order they were found in. What's inside a named folder isn't named as well.
    static func climb(
        _ tops: inout Set<UInt32>, covered: inout [UInt32: UInt64], parent: (UInt32) -> UInt32, mayName: (UInt32) -> Bool, holds: (UInt32) -> UInt64
    ) {
        func depth(of node: UInt32) -> Int {
            var steps = 0, at = node
            while at != 0 {
                at = parent(at)
                steps += 1
            }
            return steps
        }
        var inside: [UInt32: Set<UInt32>] = [:]
        for top in tops where covered[top] != nil { inside[parent(top), default: []].insert(top) }
        var byDepth: [[UInt32]] = []
        for folder in inside.keys {
            let level = depth(of: folder)
            while byDepth.count <= level { byDepth.append([]) }
            byDepth[level].append(folder)
        }
        var level = byDepth.count - 1
        while level > 0 {
            for up in byDepth[level] where mayName(up) {
                let members = inside[up] ?? []
                let together = members.reduce(UInt64(0)) { $0 &+ (covered[$1] ?? 0) }
                guard Double(together) >= Double(holds(up)) * 0.95 else { continue }
                tops.subtract(members)
                tops.insert(up)
                covered[up] = together
                let next = parent(up)
                if inside[next] == nil { byDepth[level - 1].append(next) }
                inside[next, default: []].insert(up)
            }
            level -= 1
        }
        for top in Array(tops) {
            var at = top
            while at != 0 {
                at = parent(at)
                if tops.contains(at) {
                    tops.remove(top)
                    break
                }
            }
        }
    }
}

/// A what-if: how big everything would be once the plan has run, so the ring can show it before anything happens.
final class AfterPlan: @unchecked Sendable {
    private let totals: UnsafeMutablePointer<UInt64>
    private let gone: NodeSet
    private let staying: NodeSet
    private var fixed: [UInt32: UInt64] = [:]
    let free: UInt32

    init(tree: DiskTree, ids: [UInt32], excluded: [UInt32], effect: PlanEffect) {
        totals = tree.totals
        free = tree.free
        // A planned thing that frees nothing, because another copy holds its files, stays where it is.
        let real = NodeSet(ids, in: tree).tops.filter { Double(effect.perTop[$0] ?? 0) >= Double(tree.totals[Int($0)]) * 0.02 }
        gone = NodeSet(real, in: tree)
        staying = NodeSet(excluded, in: tree)
        var freed: UInt64 = 0
        var removedFromAbove: [UInt32: UInt64] = [:]
        for top in gone.tops {
            let got = min(effect.perTop[top] ?? 0, tree.totals[Int(top)])
            let left = tree.totals[Int(top)] &- got
            fixed[top] = left
            freed &+= got
            // What's taken back keeps its size all the way up to the planned folder.
            for x in staying.tops where tree.isInside(x, top) && x != top {
                var a = tree.nodes[Int(x)].parent
                while a != top {
                    fixed[a, default: 0] &+= tree.totals[Int(x)]
                    a = tree.nodes[Int(a)].parent
                }
            }
            var a = tree.nodes[Int(top)].parent
            while true {
                removedFromAbove[a, default: 0] &+= got
                if a == 0 { break }
                a = tree.nodes[Int(a)].parent
            }
        }
        for (node, got) in removedFromAbove { fixed[node] = tree.totals[Int(node)] &- min(tree.totals[Int(node)], got) }
        // The disk stays the same size. What leaves one place shows up as free space.
        fixed[0] = tree.totals[0]
        fixed[free] = tree.totals[Int(free)] &+ freed
    }

    @inline(__always) func size(_ id: UInt32) -> UInt64 {
        if let value = fixed[id] { return value }
        if gone.contains(id), !staying.contains(id) { return 0 }
        return totals[Int(id)]
    }
}
