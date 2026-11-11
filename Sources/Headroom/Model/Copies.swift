import Foundation
import SwiftUI

/// The fourth question: what's on the disk more than once, and what only looks like it. As in Free Up, each set of copies has a
/// colour of its own and every copy of it wears that colour on the ring, so the same colour in two places is the same file, and
/// the list is the legend. Pointing at a copy lights all of its copies. Four relations:
///
/// - **Duplicates:** real second copies, the same byte for byte. Each takes all its room again, and this is what can come back.
/// - **Same file:** another name for one file, a hard link. No extra room, and the room only comes back once every name goes.
/// - **Shared copies:** APFS clones, separate files that share their room until one of them is changed.
/// - **Aliases:** symbolic links, which point at something else and take no room. A broken one points at nothing.
///
/// There's no "original" for a hard link or a clone, since the disk doesn't record which came first. What the map shows instead
/// is the file: the copy that holds the bytes, where Headroom counts them.
struct CopyGroup: Identifiable {
    enum Kind: Int, CaseIterable, Comparable {
        case duplicate, sameFile, sharedCopy, alias, broken

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .duplicate: "Duplicates"
            case .sameFile: "Hardlinks"
            case .sharedCopy: "Clones"
            case .alias: "Symlinks"
            case .broken: "Broken symlinks"
            }
        }

        var colour: Lab {
            switch self {
            case .duplicate: Palette.Copy.duplicate
            case .sameFile: Palette.Copy.sameFile
            case .sharedCopy: Palette.Copy.sharedCopy
            case .alias: Palette.Copy.alias
            case .broken: Palette.Copy.broken
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    /// One copy, the file all the names share, or what an alias points at.
    var size: UInt64
    /// What removing the extra copies would give back. Only duplicates have any.
    var back: UInt64 = 0
    /// The copy that stays, the path that counts the file, or what an alias points at. Zero for an alias with nothing there.
    var home: UInt32
    /// The extra copies, the other names, the other clones, or the folder an alias is in.
    var others: [UInt32]
    /// For an alias: where it points.
    var target: String?
    /// Small files share a group when they're in the same places, so one group can be many files.
    var isFiles = false
    /// Duplicates only: each copy that stays and each extra copy. Sets of copies that are all in the same folders are one
    /// row, so these can be many: then `home` is the folder the copies stay in, and `others` the folders of the extras.
    var keepers: [UInt32] = []
    var extras: [UInt32] = []
    /// How many of `extras`, in order, are copies of each of `keepers`: one file can have more copies than another.
    var extrasPer: [Int] = []
    /// A row of many sets: every folder its originals stay in. `home` is the one with most of them.
    var homes: [UInt32] = []
    /// The colour its copies wear on the ring, and its row in the list.
    var colour = Palette.Box.other

    /// How many files a row of duplicates stands for.
    var files: Int { keepers.count }

    /// Duplicates: each copy that stays, with its own extra copies.
    var sets: [(keeper: UInt32, extras: ArraySlice<UInt32>)] {
        guard keepers.count > 1 else { return keepers.map { ($0, extras[...]) } }
        var out: [(keeper: UInt32, extras: ArraySlice<UInt32>)] = []
        var at = 0
        for (i, keeper) in keepers.enumerated() {
            let to = min(at + (i < extrasPer.count ? extrasPer[i] : 0), extras.count)
            out.append((keeper, extras[at..<to]))
            at = to
        }
        return out
    }

    /// Duplicates: the copy that stays of this copy's file, which is itself when it's that one.
    func keeper(of node: UInt32) -> UInt32? {
        sets.first { $0.keeper == node || $0.extras.contains(node) }?.keeper
    }

    /// Every node it touches: the files themselves where the row has them, so pointing at it lights exactly those.
    var nodes: [UInt32] { !keepers.isEmpty ? keepers + extras : (home != 0 ? [home] : []) + others }
}

struct CopiesMap {
    let scanID: UUID
    private(set) var groups: [CopyGroup] = []
    /// What removing every extra copy would give back.
    private(set) var back: UInt64 = 0
    /// What hard links and clones would take if they were copies: the room they save.
    private(set) var storedOnce: UInt64 = 0
    /// Whether the duplicates are all in yet.
    var duplicatesDone = false
    /// Bytes of extra copies, and of copies that hold their file's bytes, in each folder and file, for what the middle says.
    private var extra: [UInt32: UInt64] = [:]
    private var held: [UInt32: UInt64] = [:]
    /// For the ring: each copy's set, and for a folder, the set most of it belongs to and how much of it that is.
    private var setOf: [UInt32: Int] = [:]
    private var mostly: [UInt32: (set: Int, bytes: UInt64)] = [:]
    /// Which colour each set of duplicates wears, by its first path, which stays put across scans. A set keeps its colour when
    /// others come and go, as a folder does in Map.
    private(set) var colourOf: [String: Int] = [:]

    init(scanID: UUID) { self.scanID = scanID }

    /// This many sets with their extra copies in the same folders make one row.
    static let mergeAt = 2

    static func build(tree: DiskTree, duplicates: [Duplicates.Found], aliases: [Aliases.Found], duplicatesDone: Bool,
                      kept: Set<String> = [], colours: [String: Int] = [:]) -> CopiesMap {
        var map = CopiesMap(scanID: tree.scanID)
        map.duplicatesDone = duplicatesDone
        let nodes = tree.nodes
        func add(_ bytes: UInt64, to node: UInt32, in table: inout [UInt32: UInt64]) {
            var a = node
            while true {
                table[a, default: 0] &+= bytes
                if a == 0 { break }
                a = nodes[Int(a)].parent
            }
        }

        // Sets of copies in the same folders, such as a folder of photos exported again, keep their copies in the same one of
        // them, and are one row: forty rows of the same two folders would say one thing forty times.
        var setsIn: [[UInt32]: [[UInt32]]] = [:]
        var folderOrder: [[UInt32]] = []
        for set in duplicates {
            let live = set.nodes.filter { Int($0) < tree.count && !nodes[Int($0)].has(NodeFlag.gone) }
            guard live.count >= 2 else { continue }
            let folders = Array(Set(live.map { nodes[Int($0)].parent })).sorted()
            if setsIn[folders] == nil { folderOrder.append(folders) }
            setsIn[folders, default: []].append(live)
        }
        // Sets whose extra copies are in the same folders are one row, wherever their originals are: a folder of exports, or
        // of best versions copied from several projects, is one thing to look at and one thing to clear.
        var byExtras: [[UInt32]: [(keeper: UInt32, extras: [UInt32])]] = [:]
        var order: [[UInt32]] = []
        for folders in folderOrder {
            let sets = setsIn[folders]!
            let keep = Self.keeperFolder(folders, sets: sets, in: tree, kept: kept)
            for live in sets {
                let there = live.filter { nodes[Int($0)].parent == keep }
                let keeper = Self.keeper(of: there.isEmpty ? live : there, in: tree, kept: kept)
                let extras = live.filter { $0 != keeper }
                let key = Array(Set(extras.map { nodes[Int($0)].parent })).sorted()
                if byExtras[key] == nil { order.append(key) }
                byExtras[key, default: []].append((keeper, extras))
                map.back &+= extras.reduce(UInt64(0)) { $0 &+ nodes[Int($1)].bytes }
                for e in extras { add(nodes[Int(e)].bytes, to: e, in: &map.extra) }
                add(nodes[Int(keeper)].bytes, to: keeper, in: &map.held)
            }
        }
        for key in order {
            let sets = byExtras[key]!
            // The extra copies of each set right after its original, so they can be told apart in an open row.
            let ordered = sets.sorted { (nodes[Int($0.keeper)].bytes, $0.keeper) > (nodes[Int($1.keeper)].bytes, $1.keeper) }
            let keepers = ordered.map(\.keeper), extras = ordered.flatMap(\.extras)
            let back = extras.reduce(UInt64(0)) { $0 &+ nodes[Int($1)].bytes }
            let size = keepers.reduce(UInt64(0)) { $0 &+ nodes[Int($1)].bytes }
            if sets.count >= Self.mergeAt {
                var homes: [UInt32: Int] = [:]
                for k in keepers { homes[nodes[Int(k)].parent, default: 0] += 1 }
                let byCount = homes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
                let into = key.count == 1 ? tree.name(key[0]) : "\(key.count) folders"
                map.groups.append(CopyGroup(id: "dups:\(min(keepers.min()!, extras.min()!))", kind: .duplicate, title: "\(sets.count) duplicates in \(into)",
                                            size: size, back: back, home: byCount[0], others: key, isFiles: true, keepers: keepers, extras: extras,
                                            extrasPer: ordered.map(\.extras.count), homes: byCount))
            } else {
                for set in ordered {
                    let b = set.extras.reduce(UInt64(0)) { $0 &+ nodes[Int($1)].bytes }
                    map.groups.append(CopyGroup(id: "dup:\(min(set.keeper, set.extras.min()!))", kind: .duplicate, title: tree.name(set.keeper),
                                                size: nodes[Int(set.keeper)].bytes, back: b, home: set.keeper, others: set.extras,
                                                keepers: [set.keeper], extras: set.extras, extrasPer: [set.extras.count], homes: [nodes[Int(set.keeper)].parent]))
                }
            }
        }

        // Hard links and clones: each family once, at the path that counts it. Families in the same folders are one row, as
        // duplicates are.
        let links = tree.links
        var families: [[UInt32]: [(home: UInt32, others: [UInt32], bytes: UInt64, key: UInt64, isFiles: Bool)]] = [:]
        var familyOrder: [[UInt32]] = []
        var start = 0
        while start < links.count {
            var end = start + 1
            while end < links.count && links[end].key == links[start].key { end += 1 }
            defer { start = end }
            guard let home = (start..<end).first(where: { links[$0].counted }) else { continue }
            let h = links[home]
            let homeNode = h.file != 0 ? h.file : h.dir
            var others: [UInt32] = []
            for i in start..<end where i != home {
                let node = links[i].file != 0 ? links[i].file : links[i].dir
                if node != homeNode, !others.contains(node) { others.append(node) }
            }
            guard !others.isEmpty, !nodes[Int(homeNode)].has(NodeFlag.gone) else { continue }
            func folder(_ node: UInt32) -> UInt32 { nodes[Int(node)].has(NodeFlag.directory) ? node : nodes[Int(node)].parent }
            let places = [h.isClone ? 1 : 0, folder(homeNode)] + others.map(folder).sorted()
            if families[places] == nil { familyOrder.append(places) }
            families[places, default: []].append((homeNode, others, h.bytes, h.key, h.file == 0))
            map.storedOnce &+= h.bytes &* UInt64(others.count)
            add(h.bytes, to: homeNode, in: &map.held)
        }
        for places in familyOrder {
            let all = families[places]!
            let kind: CopyGroup.Kind = places[0] == 1 ? .sharedCopy : .sameFile
            if all.count >= Self.mergeAt {
                var folders: [UInt32] = []
                for f in all { for o in f.others where !folders.contains(nodes[Int(o)].has(NodeFlag.directory) ? o : nodes[Int(o)].parent) {
                    folders.append(nodes[Int(o)].has(NodeFlag.directory) ? o : nodes[Int(o)].parent)
                } }
                map.groups.append(CopyGroup(id: "links:\(all[0].key)", kind: kind, title: "\(all.count) files in \(tree.name(places[1]))",
                                            size: all.reduce(UInt64(0)) { $0 &+ $1.bytes }, home: places[1], others: folders, isFiles: true,
                                            keepers: all.map(\.home), extras: all.flatMap(\.others)))
            } else {
                for f in all {
                    map.groups.append(CopyGroup(id: "link:\(f.key):\(f.home)", kind: kind, title: tree.name(f.home), size: f.bytes, home: f.home,
                                                others: f.others, isFiles: f.isFiles))
                }
            }
        }

        for alias in aliases {
            let size = alias.node.map { tree.totals[Int($0)] } ?? 0
            let place: String
            switch alias.state {
            case .otherDisk: place = DiskTree.friendly(alias.target)
            case .diskMissing: place = DiskTree.friendly(alias.target) + " (not connected)"
            case .broken: place = DiskTree.friendly(alias.target) + " (missing)"
            case .here: place = alias.node.map(tree.friendlyPath) ?? DiskTree.friendly(alias.target)
            }
            let title = HiddenNames.isOn ? ((HiddenNames.madeUp(path: (tree.path(alias.dir) ?? "") + "/" + alias.name)) as NSString).lastPathComponent : alias.name
            map.groups.append(CopyGroup(id: "alias:\(alias.dir):\(alias.name)", kind: alias.isBroken ? .broken : .alias, title: title, size: size,
                                        home: alias.node ?? 0, others: [alias.dir], target: place))
        }

        map.groups.sort { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            let wa = a.kind == .duplicate ? a.back : a.size, wb = b.kind == .duplicate ? b.back : b.size
            if wa != wb { return wa > wb }
            return a.title < b.title
        }
        map.paint(tree, remembered: colours)
        return map
    }

    /// Each set of duplicates gets a colour of its own, biggest first, from the same wheel as Free Up's boxes, and every copy
    /// wears it. What has other names or clones takes no extra room, so it wears the quiet colour of what's done another way.
    /// A folder wears a set's colour when most of it is that set, so a folder that's all copies reads as one.
    private mutating func paint(_ tree: DiskTree, remembered: [String: Int]) {
        let nodes = tree.nodes
        let spread = Palette.Box.spread
        // A set that had a colour keeps it. New ones, biggest first, take the colours no set here wears.
        colourOf = remembered
        var used = Set<Int>()
        var fresh: [(at: Int, key: String)] = []
        for at in groups.indices where groups[at].kind == .duplicate {
            let g = groups[at]
            let key = (g.keepers + g.extras).compactMap { tree.path($0) }.min() ?? g.id
            if let c = remembered[key], !used.contains(c) {
                groups[at].colour = spread[c % spread.count]
                used.insert(c)
            } else {
                fresh.append((at, key))
            }
        }
        var next = 0
        for (at, key) in fresh {
            var c = next
            while used.contains(c % spread.count), used.count < spread.count { c += 1 }
            next = c + 1
            groups[at].colour = spread[c % spread.count]
            used.insert(c % spread.count)
            colourOf[key] = c % spread.count
        }
        var sums: [UInt32: [Int: UInt64]] = [:]
        for at in groups.indices {
            let g = groups[at]
            let members: [UInt32]
            switch g.kind {
            case .duplicate:
                members = g.keepers + g.extras
            case .sameFile, .sharedCopy:
                groups[at].colour = Palette.Box.other
                members = g.keepers.isEmpty ? [g.home] : g.keepers
            case .alias:
                groups[at].colour = Palette.Copy.alias
                continue
            case .broken:
                groups[at].colour = Palette.Copy.broken
                continue
            }
            for m in members where m != 0 {
                let isFolder = nodes[Int(m)].has(NodeFlag.directory)
                // Small files have no piece of their own, so their folder stands for them, but only wears the colour if most of
                // it is theirs.
                let bytes = isFolder ? g.size / UInt64(max(members.count, 1)) : nodes[Int(m)].bytes
                if !isFolder { setOf[m] = setOf[m] ?? at }
                var a = isFolder ? m : nodes[Int(m)].parent
                while true {
                    sums[a, default: [:]][at, default: 0] &+= bytes
                    if a == 0 { break }
                    a = nodes[Int(a)].parent
                }
            }
        }
        for (node, bySet) in sums {
            if let best = bySet.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) { mostly[node] = (best.key, best.value) }
        }
    }

    /// Where copies in these folders stay: not Downloads, the Desktop or the Trash, not a cache or build folder, then not a folder
    /// named like a copy or whose copies mostly are, then the folder whose copies are older by a day or more, then the one holding
    /// more files, which is likelier the collection the others were copied from, then the one nearest the top.
    static func keeperFolder(_ folders: [UInt32], sets: [[UInt32]], in tree: DiskTree, kept: Set<String> = []) -> UInt32 {
        guard folders.count > 1 else { return folders[0] }
        // The folder you picked, or the one holding a copy you picked.
        if !kept.isEmpty {
            if let picked = folders.first(where: { tree.path($0).map(kept.contains) == true }) { return picked }
            for set in sets {
                if let file = set.first(where: { tree.path($0).map(kept.contains) == true }) { return tree.nodes[Int(file)].parent }
            }
        }
        let n = tree.nodes
        func days(_ folder: UInt32) -> UInt32 {
            var sum: UInt64 = 0, count: UInt64 = 0
            for set in sets { for f in set where n[Int(f)].parent == folder { sum += UInt64(n[Int(f)].modTime); count += 1 } }
            return count == 0 ? .max : UInt32(sum / count / 86_400)
        }
        // `Photos copy`, or a folder whose copies here are mostly named like copies. Mostly, so one stray `IMG_5 copy.jpg` among
        // forty originals doesn't send all forty the other way.
        func named(_ folder: UInt32) -> Int {
            if soundsLikeACopy(tree.rawName(folder), folder: true) { return 1 }
            var copies = 0, all = 0
            for set in sets { for f in set where n[Int(f)].parent == folder { all += 1; if soundsLikeACopy(tree.rawName(f)) { copies += 1 } } }
            return copies * 2 > all ? 1 : 0
        }
        // The same one on every scan, whatever the node numbers: the path settles a tie.
        func score(_ folder: UInt32) -> (Int, Int, UInt32, Int64, Int, String) {
            (passing(folder, in: tree), named(folder), days(folder), -Int64(n[Int(folder)].fileCount), depth(folder, in: tree), tree.path(folder) ?? "")
        }
        let scored = folders.map { ($0, score($0)) }
        return scored.min { $0.1 < $1.1 }?.0 ?? folders[0]
    }

    /// How sure it is that a copy here isn't the one to keep: 2 in Downloads, the Desktop or the Trash, 1 in a cache or build
    /// folder, 0 anywhere else.
    static func passing(_ folder: UInt32, in tree: DiskTree) -> Int {
        let n = tree.nodes
        var out = 0
        var a = folder
        while a != 0 {
            let up = n[Int(a)].parent
            if up == tree.home || n[Int(up)].has(NodeFlag.anchor) {
                let name = tree.rawName(a)
                if name == "Downloads" || name == "Desktop" || name == ".Trash" || name == ".Trashes" { out = 2 }
            }
            if n[Int(a)].rule != 0 { out = max(out, 1) }
            a = up
        }
        return out
    }

    private static func depth(_ node: UInt32, in tree: DiskTree) -> Int {
        var d = 0, a = node
        while a != 0 { d += 1; a = tree.nodes[Int(a)].parent }
        return d
    }

    /// A name that says it's a copy, as the Finder and browsers name them: `film copy.mov`, `film copy 2.mov`, `film (1).mov`,
    /// `film 2.mov`. A number that's part of the name, such as `Trip 2025.mov` or `hero-1.psd`, doesn't count. For a folder only
    /// `Photos copy` and `Photos (1)` count: `Season 2` is a name of its own.
    static func soundsLikeACopy(_ name: String, folder: Bool = false) -> Bool {
        let stem = (folder ? name : (name as NSString).deletingPathExtension).lowercased()
        return (folder ? copyFolderName : copyFileName).firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) != nil
    }

    private static let copyFileName = try! NSRegularExpression(pattern: #"( copy( \d+)?| \(\d+\)| [2-9])$"#)
    private static let copyFolderName = try! NSRegularExpression(pattern: #"( copy( \d+)?| \(\d+\))$"#)

    /// The copy that stays: not one in Downloads, the Desktop or the Trash, not one in a cache or build folder, then not one whose
    /// name says it's a copy, even beside the other in the same folder, then the oldest, then the one nearest the top. The same one
    /// every time, whatever order they were found in.
    static func keeper(of nodes: [UInt32], in tree: DiskTree, kept: Set<String> = []) -> UInt32 {
        if !kept.isEmpty, let picked = nodes.first(where: { tree.path($0).map(kept.contains) == true }) { return picked }
        let n = tree.nodes
        func score(_ node: UInt32) -> (Int, Int, UInt32, Int) {
            var passing = 0, depth = 0
            var a = n[Int(node)].parent
            while a != 0 {
                let name = tree.rawName(a)
                if n[Int(n[Int(a)].parent)].flags & NodeFlag.anchor != 0 || a == tree.home || n[Int(a)].parent == tree.home {
                    if name == "Downloads" || name == "Desktop" || name == ".Trash" || name == ".Trashes" { passing += 2 }
                }
                if n[Int(a)].rule != 0 { passing = max(passing, 1) }
                depth += 1
                a = n[Int(a)].parent
            }
            // On its own, after the folder rules: two downloads side by side keep `Installer.dmg`, not `Installer (1).dmg`, and a
            // Finder copy, which has the original's date, keeps `film.mov`, not `film copy.mov`.
            let named = soundsLikeACopy(tree.rawName(node)) ? 1 : 0
            return (passing, named, n[Int(node)].modTime, depth)
        }
        // The same one on every scan, whatever the node numbers: the path settles a tie.
        let scored = nodes.map { ($0, score($0)) }
        return scored.min { a, b in a.1 != b.1 ? a.1 < b.1 : (tree.path(a.0) ?? "") < (tree.path(b.0) ?? "") }?.0 ?? nodes[0]
    }

    /// A piece's colour: how much of it is extra copies, from deep amber for a little to bright orange for all of it, or how much
    /// of it is the one copy of something with other names or copies, in white. The rest stays quiet.
    func lab(_ node: UInt32, total: UInt64) -> Lab {
        if let at = setOf[node] { return groups[at].colour }
        guard let m = mostly[node] else { return Palette.quiet }
        // A folder takes on the colour of the set most of it is, as much as it is that set, so the folder that holds the
        // originals and the one full of copies read as one colour. Under a quarter, it stays quiet.
        let share = Double(m.bytes) / Double(max(total, 1))
        guard share >= 0.25 else { return Palette.quiet }
        return Lab.mix(Palette.quiet, groups[m.set].colour, Float(min(1, 0.3 + share * 0.7)))
    }

    /// The set a piece belongs to: a copy's own, or for a folder, the set most of it is.
    func set(of node: UInt32) -> CopyGroup? {
        if let at = setOf[node] { return groups[at] }
        if let m = mostly[node] { return groups[m.set] }
        return nil
    }

    /// What the middle of the ring says about a piece in Copies: how much of it is duplicates, or that it's hardlinked or
    /// cloned. Nil when it has nothing to do with copies.
    func note(for node: UInt32, total: UInt64, in tree: DiskTree) -> String? {
        let e = extra[node] ?? 0, h = held[node] ?? 0
        guard e > 0 || h > 0 else { return nil }
        let isFile = !tree.nodes[Int(node)].has(NodeFlag.directory)
        if isFile {
            if let g = groups.first(where: { $0.kind == .duplicate && $0.extras.contains(node) }), let keeper = g.keeper(of: node) {
                return "Duplicate of \(tree.friendlyPath(keeper))"
            }
            if let g = groups.first(where: { $0.kind == .duplicate && $0.keepers.contains(node) }) {
                let count = g.sets.first { $0.keeper == node }?.extras.count ?? 0
                return "Keep · \(count) \(count == 1 ? "duplicate" : "duplicates")"
            }
            return "Hardlinked or cloned"
        }
        if e > 0 { return "\(formatBytes(e)) in duplicates" }
        return "\(formatBytes(h)) hardlinked or cloned"
    }

    /// The groups that touch what's in view.
    func groups(under focus: UInt32, in tree: DiskTree) -> [CopyGroup] {
        guard focus != 0 else { return groups }
        return groups.filter { g in g.nodes.contains { tree.isInside($0, focus) } }
    }

    /// Where something is, from the disk or the home folder down, with the middle left out when it's long. Short keeps the
    /// last two folders, for a name beside the ring or a line under a row.
    static func place(_ node: UInt32, in tree: DiskTree, short: Bool = false) -> String {
        places([node], in: tree, short: short)[0]
    }

    /// Places that can be told apart: each as `place` says it, with the folder where it parts from another one kept in, so the
    /// same `media/audio` in two projects reads `…/demo/media/audio` and `…/eye/media/audio`.
    static func places(_ nodes: [UInt32], in tree: DiskTree, short: Bool = false) -> [String] {
        // With made-up names showing, the path is made up too, the disk's own name included.
        let top = HiddenNames.isOn && !tree.rootPath.isEmpty ? HiddenNames.madeUp(path: tree.rootPath) : tree.rootPath
        let all: [[Substring]?] = nodes.map { node in
            var path = tree.friendlyPath(node)
            if !top.isEmpty, path.hasPrefix(top + "/") { path = String(path.dropFirst(top.count + 1)) }
            else if path == top { return nil }
            return path.split(separator: "/", omittingEmptySubsequences: false)
        }
        // The folders each one is said by: its first ones from home or the top, unless short, and its last two.
        var kept: [Set<Int>] = all.map { parts in
            guard let parts else { return [] }
            let head = short ? 0 : (parts.first == "~" ? 3 : 2)
            return Set(0..<min(head, parts.count)).union(max(parts.count - 2, 0)..<parts.count)
        }
        func say(_ i: Int) -> String {
            guard let parts = all[i] else { return (top as NSString).lastPathComponent }
            let whole = short ? parts.count <= (parts.first == "~" ? 3 : 2) : parts.count <= 5
            if whole { return parts.joined(separator: "/") }
            var out: [Substring] = [], skipped = false
            for (j, part) in parts.enumerated() {
                if kept[i].contains(j) {
                    if skipped { out.append("…") }
                    out.append(part)
                    skipped = false
                } else {
                    skipped = true
                }
            }
            return out.joined(separator: "/")
        }
        var said = all.indices.map(say)
        for _ in 0..<3 {
            var changed = false
            for i in all.indices {
                guard let parts = all[i] else { continue }
                for j in all.indices where j != i && said[j] == said[i] {
                    guard let other = all[j] else { continue }
                    let parting = zip(parts, other).prefix { $0 == $1 }.count
                    if parting < parts.count, !kept[i].contains(parting) {
                        kept[i].insert(parting)
                        changed = true
                    }
                }
            }
            guard changed else { break }
            said = all.indices.map(say)
        }
        return said
    }

    /// The line under a row of duplicates: how many copies and where, the one to keep first, so the row says it without being
    /// opened. A row of many files says where their originals are; its title says where the duplicates are.
    static func summary(of group: CopyGroup, in tree: DiskTree) -> String {
        if group.files > 1 {
            let homes = group.homes.isEmpty ? [group.home] : group.homes
            return "Originals in " + places(Array(homes.prefix(2)), in: tree, short: true).joined(separator: ", ") + (homes.count > 2 ? " +\(homes.count - 2)" : "")
        }
        let n = tree.nodes
        let folder = n[Int(group.home)].parent
        let count = group.extras.count + 1
        if group.extras.allSatisfy({ n[Int($0)].parent == folder }) {
            return "\(count) copies in \(place(folder, in: tree, short: true))"
        }
        var others: [UInt32] = []
        for e in group.extras where !others.contains(n[Int(e)].parent) && n[Int(e)].parent != folder { others.append(n[Int(e)].parent) }
        let said = places([folder] + others, in: tree, short: true)
        return "\(count) copies · \(said[0]), \(said[1])" + (others.count > 1 ? " +\(others.count - 1)" : "")
    }

}

extension Palette {
    /// Copies' colours, on the ring, its lines and the list.
    enum Copy {
        static let duplicate = Lab(lch: 0.78, 0.165, 62)
        static let sameFile = Lab(lch: 0.70, 0.185, 312)
        static let sharedCopy = Lab(lch: 0.80, 0.19, 150)
        static let alias = Lab(lch: 0.83, 0.115, 222)
        static let broken = Lab(lch: 0.66, 0.20, 25)
        /// The copy that holds the bytes: a step below white, so the extra copies stay the brightest thing on the ring.
        static let file = Lab(lch: 0.84, 0.010, 250)

        /// A little of it is dim and nearly quiet, all of it is the colour itself. Below one percent it fades into quiet, so a big
        /// folder with one copy in it doesn't glow.
        static func ramp(_ colour: Lab, _ share: Float) -> Lab {
            let dim = Lab(l: 0.40, a: colour.a * 0.38, b: colour.b * 0.38)
            let shown = Lab.mix(dim, colour, share)
            return Lab.mix(Palette.quiet, shown, min(share / 0.01, 1))
        }
    }
}

extension Lenses {
    static func copiesColorer(map: CopiesMap, tree: DiskTree) -> RingLayout.Colorer {
        let totals = tree.totals
        return { node in map.lab(node, total: totals[Int(node)]).linearP3 }
    }
}
