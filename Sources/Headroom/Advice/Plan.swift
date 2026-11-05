import Foundation

/// What happens to something when you press Clean.
enum PlanStep: Codable, Equatable {
    case trash
    /// An app and the files that belong to it. Everything goes to the Trash, so it can come back.
    case uninstall
    /// Copied into this folder and checked. Only then does the original go to the Trash.
    case move(folder: String)
    /// Already in the Trash. It goes when you empty it.
    case emptyTrash
}

/// One line in the list of planned actions. It's kept by path, so it survives a new scan and a restart.
struct PlanItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    /// What was known when you planned it.
    var note: String
    var tierRaw: UInt8
    /// Always as you'd write them: `/Users/…`, never `/System/Volumes/Data/Users/…`.
    var paths: [String]
    /// Things inside those paths that you took back.
    var excluded: [String] = []
    var step: PlanStep = .trash
    var addedAt = Date()
    var byHand = false
    var bundleID: String? = nil
    var lastKnownBytes: UInt64 = 0
    /// You saw that it changed after it was planned, and still want it gone.
    var acceptedChange: Date? = nil
    /// Which disk this was on, so that a different disk with the same name can't be mistaken for it.
    var diskID: String? = nil

    var tier: Tier { Tier(rawValue: tierRaw) ?? .yourCall }
    var isEmptyTrash: Bool { step == .emptyTrash }
    var isMove: Bool { if case .move = step { return true } else { return false } }
}

/// Paths compare as text, and a folder covers what's inside it.
enum PathMath {
    @inline(__always) static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    /// The path as you'd write it, without the data volume's prefix that macOS keeps out of sight.
    static func visible(_ path: String) -> String {
        path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
    }

    /// The top of the disk a path is on.
    static func mount(of path: String) -> String {
        guard path.hasPrefix("/Volumes/") else { return "/" }
        let parts = path.split(separator: "/", maxSplits: 2)
        return parts.count >= 2 ? "/\(parts[0])/\(parts[1])" : "/"
    }
}

/// The planned actions. Nothing here touches a disk. This is only the list, and the rules for keeping it tidy:
/// a folder takes in whatever was already planned inside it, taking something back from a planned folder leaves the rest
/// of that folder planned, and something with a destination of its own always keeps it.
struct PlanList: Codable, Equatable {
    var items: [PlanItem] = []
    /// Suggestions you've said to keep. They stay out of the list until you say otherwise.
    var kept: [KeptThing] = []

    struct KeptThing: Codable, Equatable, Identifiable {
        var id: String
        var title: String
    }

    var isEmpty: Bool { items.isEmpty }
    /// How many things will happen, counted the way you'd count them.
    var count: Int { items.count }

    func isKept(_ id: String) -> Bool { kept.contains { $0.id == id } }

    /// Whether this path will go when you clean: it's planned, or it's inside something planned, and wasn't taken back.
    func covers(_ path: String) -> Bool {
        for item in items where item.paths.contains(where: { PathMath.isInside(path, $0) }) {
            if !item.excluded.contains(where: { PathMath.isInside(path, $0) }) { return true }
        }
        return false
    }

    /// Adds to the plan.
    mutating func add(_ new: PlanItem) {
        var paths: [String] = []
        var excluded = new.excluded
        for path in new.paths {
            // Asking for this again brings back what had been taken back, unless the new item says otherwise.
            for at in items.indices {
                items[at].excluded.removeAll { PathMath.isInside($0, path) && !new.excluded.contains($0) }
            }
            if new.step != .trash {
                // It goes somewhere of its own, so it has to leave whatever else had it.
                for at in items.indices where items[at].id != new.id && items[at].paths.contains(where: { PathMath.isInside(path, $0) || PathMath.isInside($0, path) }) {
                    items[at].paths.removeAll { PathMath.isInside($0, path) }
                    if items[at].paths.contains(where: { PathMath.isInside(path, $0) }), !items[at].excluded.contains(path) {
                        items[at].excluded.append(path)
                    }
                }
                paths.append(path)
                continue
            }
            if items.contains(where: { item in
                item.paths.contains { PathMath.isInside(path, $0) } && !item.excluded.contains { PathMath.isInside(path, $0) }
            }) {
                continue
            }
            paths.append(path)
            for at in items.indices where items[at].id != new.id {
                let inside = items[at].paths.filter { $0 != path && PathMath.isInside($0, path) }
                guard !inside.isEmpty else { continue }
                if items[at].step == .trash {
                    // Plain things planned inside it are part of it now.
                    items[at].paths.removeAll { inside.contains($0) }
                } else {
                    // Something with a destination of its own isn't swallowed by the folder around it.
                    excluded += inside
                }
            }
        }
        items.removeAll { $0.paths.isEmpty }
        guard !paths.isEmpty else { return }
        if let at = items.firstIndex(where: { $0.id == new.id }) {
            items[at].paths += paths.filter { !items[at].paths.contains($0) }
            items[at].excluded += excluded.filter { !items[at].excluded.contains($0) }
        } else {
            var item = new
            item.paths = paths
            item.excluded = excluded
            items.append(item)
        }
    }

    /// Takes one path out of the plan. If a planned folder holds it, the rest of the folder stays planned.
    mutating func takeBack(_ path: String) {
        for at in items.indices {
            items[at].paths.removeAll { PathMath.isInside($0, path) }
            if items[at].paths.contains(where: { PathMath.isInside(path, $0) }),
               !items[at].excluded.contains(where: { PathMath.isInside(path, $0) }) {
                items[at].excluded.append(path)
            }
        }
        items.removeAll { $0.paths.isEmpty }
    }

    /// Takes a thing out, and what only makes sense with it: its data, or the other copy of its files.
    mutating func remove(_ id: String) {
        items.removeAll { $0.id == id || $0.id == id + ":also" || $0.id == id + ":other-copy" }
    }

    /// Takes it out of the plan and stops suggesting it.
    mutating func keep(_ id: String, title: String) {
        remove(id)
        if !isKept(id) { kept.append(KeptThing(id: id, title: title)) }
    }

    mutating func stopKeeping(_ id: String) {
        kept.removeAll { $0.id == id }
    }

    func item(_ id: String) -> PlanItem? { items.first { $0.id == id } }

    /// Every path that goes, for an item with some things taken back: the folder is opened up, so what stays, stays.
    static func effectivePaths(of item: PlanItem, list: (String) -> [String]) -> [String] {
        var out: [String] = []
        func walk(_ path: String) {
            if item.excluded.contains(where: { PathMath.isInside(path, $0) }) { return }
            guard item.excluded.contains(where: { PathMath.isInside($0, path) }) else {
                out.append(path)
                return
            }
            for child in list(path) { walk(path + "/" + child) }
        }
        for path in item.paths { walk(path) }
        return out
    }

    /// Where something ends up in a move. A folder that's been opened up keeps its shape, with its own name on top.
    static func moveDestination(of path: String, item: PlanItem, folder: String) -> String {
        guard let root = item.paths.first(where: { PathMath.isInside(path, $0) }), root != path else { return folder }
        let name = (root as NSString).lastPathComponent
        let inner = (String(path.dropFirst(root.count + 1)) as NSString).deletingLastPathComponent
        return folder + "/" + name + (inner.isEmpty ? "" : "/" + inner)
    }
}

/// Something that went to the Trash, and where it is now, so it can come back or be deleted for good.
struct CleanedThing: Codable, Equatable {
    var itemID: String
    var title: String
    var original: String
    var inTrash: String
    var bytes: UInt64
    /// Which file this is, so something else that later has the same name in the Trash can't be mistaken for it.
    var identity: String? = nil
}

/// What's kept on disk between launches.
struct PlanFile: Codable {
    var list = PlanList()
    var cleaned: [CleanedThing] = []
    /// What you'd planned, so a clean you've undone can be fixed and run again.
    var lastItems: [PlanItem] = []
    /// What was already in the Trash when you said that can go too. Anything thrown away after that stays.
    var oldTrashItems: [String]? = nil
    var oldTrashBytes: UInt64 = 0
}

enum PlanStore {
    private static var url: URL { AppData.folder.appendingPathComponent("plan.json") }
    /// One at a time and in order, so an older list can never overwrite a newer one.
    private static let queue = DispatchQueue(label: "plan.save", qos: .utility)

    static func load() -> PlanFile {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(PlanFile.self, from: data) else { return PlanFile() }
        return file
    }

    static func save(_ file: PlanFile) {
        guard let data = try? JSONEncoder().encode(file) else { return }
        let target = url
        queue.async { try? data.write(to: target, options: .atomic) }
    }
}

/// How much of a suggestion is in the plan.
enum TickState: Equatable {
    case none, some, all
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

    /// Which of the set's folders holds this node.
    func top(containing node: UInt32) -> UInt32? {
        for top in tops where tree.isInside(node, top) { return top }
        return nil
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
        func mayName(_ folder: UInt32) -> Bool {
            guard folder != 0, folder != tree.home, !set.contains(folder), !tree.nodes[Int(folder)].has(NodeFlag.anchor),
                  !Titles.isGeneralFolder(tree.name(folder)), let path = tree.path(folder) else { return false }
            return Safety.canTrash(path)
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
        // Up from each folder, for as long as the one above holds little else. Season folders become their show's folder.
        var changed = true
        while changed {
            changed = false
            for top in Array(tops) where covered[top] != nil {
                let up = tree.nodes[Int(top)].parent
                guard mayName(up) else { continue }
                var together: UInt64 = 0
                var siblings: [UInt32] = []
                for other in tops where tree.nodes[Int(other)].parent == up && covered[other] != nil {
                    together &+= covered[other] ?? 0
                    siblings.append(other)
                }
                if Double(together) >= Double(holds(up)) * 0.95 {
                    for s in siblings { tops.remove(s) }
                    tops.insert(up)
                    covered[up] = together
                    changed = true
                    break
                }
            }
        }
        return (Array(tops), bytes)
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
