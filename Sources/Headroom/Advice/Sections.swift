import Foundation

/// A kind of thing you might let go of. This is the one set of data behind Free Up: a box on the right and pieces on the ring
/// are two ways of showing the same files, so whatever you point at or tick in one shows in the other.
struct Section {
    var id: String
    var title: String
    var detail: String
    var note: String? = nil
    var color: Lab
    var rows: [WinRow] = []
    /// Kinds within this kind. Looking inside a folder, they become boxes of their own.
    var kids: [Section] = []
    /// A short list to pick from, not a suggestion: it's never ticked as a whole, and its total isn't a promise.
    var isShortlist = false

    var allRows: [WinRow] { rows + kids.flatMap(\.allRows) }
}

/// One box in the panel: a section, as much of it as is in the picture on screen.
struct Box: Identifiable {
    var id: String
    var title: String
    var detail: String
    var note: String? = nil
    var color: Lab
    var rows: [WinRow]
    var kids: [Box] = []
    /// It stands for one thing, so it has that thing's name, and what you can do to that thing.
    var isOneThing = false
    /// A short list to pick from, such as the largest files: no tick for the lot, and it sits under the suggestions.
    var isShortlist = false

    var bytes: UInt64 { rows.reduce(0) { $0 &+ $1.gain } }

    /// What a tick on the box takes. What you set up by hand, or may be sorry to lose, stays for a tick of its own, unless
    /// that's all there is: then you can only mean that.
    var rowsATickTakes: [WinRow] {
        let plain = rows.filter { !$0.askFirst && $0.inUse == nil }
        return plain.isEmpty ? rows : plain
    }

    /// What Select recommended would tick in this box.
    var recommended: [WinRow] { isShortlist ? [] : rows.filter(\.isRecommended) }
}

/// Everything that could go in the picture, sorted by what it is, what you'd miss least first.
struct Suggestions {
    var sections: [Section] = []
    /// What can't be ticked: a restart, an update, or something only its own app can look after.
    var others: [WinRow] = []

    var rows: [WinRow] { sections.flatMap(\.allRows) }
    /// Every suggestion there is, with or without a tick.
    var everything: [WinRow] { rows + others }
}

enum Sections {
    /// A leftover has to be at least this big to be worth a line.
    static let smallestLeftover: UInt64 = 5_000_000

    /// An installer is old once it has sat for this long: a fresh download may not be installed yet.
    static let installerOldDays: UInt32 = 14
    /// The largest files are the ones this big and up, and no more of them than this.
    static let largeFile: UInt64 = 1_000_000_000
    static let mostLargeFiles = 20

    /// Every box of Free Up, from what was found. A row says which box it's in, so this only names the boxes and says what's
    /// in each. Boxes with nothing in them don't exist: a Mac without games has no Games.
    static func build(from wins: [WinRow], tree: DiskTree, facts: Facts = .none, now: Date = Date()) -> Suggestions {
        var flat: [WinRow] = []
        for row in wins {
            if row.parts.isEmpty { flat.append(row) } else { flat += row.parts }
        }
        var found: [BoxKind: [WinRow]] = [:]
        var others: [WinRow] = []
        for row in flat {
            guard row.isPlannable else {
                others.append(row)
                continue
            }
            found[row.box, default: []].append(row.box == .models ? modelRow(row, tree: tree) : row)
        }

        // What's left over in your own folders, by what it is. The advisor's numbered frames join in, unless the names found them.
        let leftovers = Leftovers.find(in: tree)
        let leftoverSet = NodeSet(leftovers.map(\.node), in: tree)
        var kinds: [Leftovers.Role: [WinRow]] = [:]
        var fresh: [WinRow] = leftovers.map { leftoverRow($0, tree: tree) }
        Wins.settleReclaim(&fresh, tree: tree)
        let installerCutoff = UInt32(seconds: now.timeIntervalSince1970) &- installerOldDays * 86_400
        for (row, one) in zip(fresh, leftovers) where row.gain >= smallestLeftover {
            // A download from this week may still be waiting to be installed.
            if one.role == .installers, tree.nodes[Int(one.node)].modTime >= installerCutoff { continue }
            kinds[one.role, default: []].append(row)
        }
        for row in found[.leftovers] ?? [] where !row.nodes.allSatisfy({ leftoverSet.contains($0) }) { kinds[.scenes, default: []].append(row) }
        found[.installers] = kinds[.installers]

        var kids: [Section] = []
        for role in Leftovers.Role.inOrder {
            guard let rows = kinds[role], !rows.isEmpty else { continue }
            kids.append(Section(id: "leftovers." + role.key, title: role.title, detail: rows.count == 1 ? "1 folder" : "\(rows.count) folders", color: role.color, rows: biggestFirst(rows)))
        }

        var out: [Section] = []
        func add(_ box: BoxKind, _ title: String, _ color: Lab, detail: ([WinRow]) -> String) {
            guard let rows = found[box], !rows.isEmpty else { return }
            out.append(Section(id: box.rawValue, title: title, detail: detail(rows), color: color, rows: biggestFirst(rows)))
        }
        func counted(_ one: String, _ many: String) -> ([WinRow]) -> String {
            { rows in rows.count == 1 ? "1 \(one)" : "\(rows.count) \(many)" }
        }
        // How many files a box of files holds, on the map or too small for it.
        func files(_ rows: [WinRow]) -> String {
            let count = rows.reduce(0) { $0 + $1.nodes.count + $1.extraPaths.count }
            return count == 1 ? "1 file" : "\(count) files"
        }
        add(.trash, "Trash", Palette.Box.trash, detail: names)
        add(.caches, "Caches", Palette.Box.quick, detail: names)
        add(.junk, "Junk", Palette.Box.junk, detail: names)
        add(.developer, "Developer", Palette.Box.android, detail: names)
        add(.models, "AI models", Palette.Box.models, detail: counted("model", "models"))
        add(.games, "Games", Palette.Box.games, detail: counted("game", "games"))
        add(.apps, "Unused apps", Palette.Box.apps, detail: counted("app", "apps"))
        add(.removedApps, "Leftover app data", Palette.Box.left, detail: counted("removed app", "removed apps"))
        add(.backups, "iPhone backups", Palette.Box.watched) { rows in
            let count = rows.flatMap(\.nodes).reduce(0) { $0 + tree.children($1).filter { tree.nodes[Int($0)].has(NodeFlag.directory) }.count }
            return count == 1 ? "1 backup" : "\(count) backups"
        }
        add(.installers, "Old installers", Palette.Box.installers, detail: files)
        add(.screenshots, "Screenshots", Palette.Box.screenshots, detail: files)
        add(.other, "Other", Palette.Box.other, detail: names)
        if !kids.isEmpty {
            out.append(Section(id: BoxKind.leftovers.rawValue, title: "Project leftovers", detail: "Old versions, renders, review stills", color: Palette.Box.leftovers, kids: kids))
        }

        // Last, the largest files that aren't in a box already: where the one huge thing you forgot turns up.
        let large = largestFiles(tree: tree, besides: out.flatMap(\.allRows) + others, facts: facts, now: now)
        if !large.isEmpty {
            let detail = large.count == 1 ? "1 file" : "\(large.count) files"
            out.append(Section(id: BoxKind.largest.rawValue, title: "Largest files", detail: detail, color: Palette.Box.other, rows: large, isShortlist: true))
        }
        return Suggestions(sections: out, others: others)
    }

    /// The biggest single files in your own folders that nothing else lists. Apps, libraries and anything with a rule of its
    /// own are left out: these are files you'd know by name.
    static func largestFiles(tree: DiskTree, besides listed: [WinRow], facts: Facts, now: Date) -> [WinRow] {
        let nodes = tree.nodes
        let taken = NodeSet(listed.flatMap(\.nodes), in: tree)
        var big: [UInt32] = []
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            guard n.flags & (NodeFlag.directory | NodeFlag.synthetic | NodeFlag.alias | NodeFlag.gone) == 0, n.rule == 0, tree.totals[i] >= largeFile else { continue }
            // On the startup disk, only your own folders. On any other disk, anything that isn't inside a package.
            if tree.home != 0 ? !nodes[Int(n.parent)].has(NodeFlag.projects) : isInsidePackage(UInt32(i), tree: tree) { continue }
            if taken.contains(UInt32(i)) { continue }
            big.append(UInt32(i))
        }
        big.sort { tree.totals[Int($0)] > tree.totals[Int($1)] }
        let videoLinks = tree.links.filter { $0.kind == Kind.video.rawValue }
        return big.prefix(mostLargeFiles).compactMap { node in
            guard let path = tree.path(node), Safety.canTrash(path) else { return nil }
            let total = tree.totals[Int(node)]
            let folder = DiskTree.friendly((tree.friendlyPath(node) as NSString).deletingLastPathComponent)
            let when = nodes[Int(node)].modTime == 0 ? "" : " · " + Titles.dayText(Date(timeIntervalSince1970: TimeInterval(nodes[Int(node)].modTime)), now: now)
            var row = WinRow(id: "largest:" + tree.friendlyPath(node), title: tree.name(node), subtitle: folder + when, detail: tree.friendlyPath(node), tier: .yourCall,
                             nodes: [node], bytes: Accounting.reclaimable([node], in: tree), paperBytes: total, action: .trash, command: nil, bundleID: nil)
            row.box = .largest
            row.previewPath = path
            // A film that's also a torrent's copy frees nothing until that goes too, and the row says so.
            if nodes[Int(node)].kind == Kind.video.rawValue {
                Advisors.addOtherCopies(to: &row, title: row.title, links: videoLinks, tree: tree, facts: facts, now: now)
            }
            return row
        }
    }

    /// Whether a file sits inside something macOS shows as one thing: an app, a library, a project bundle.
    private static func isInsidePackage(_ node: UInt32, tree: DiskTree) -> Bool {
        var a = tree.nodes[Int(node)].parent
        while a != 0 {
            let n = tree.nodes[Int(a)]
            if n.has(NodeFlag.anchor) || n.has(NodeFlag.synthetic) { return false }
            if packageEndings.contains((tree.name(a) as NSString).pathExtension.lowercased()) { return true }
            a = n.parent
        }
        return false
    }

    private static let packageEndings: Set<String> = ["app", "bundle", "framework", "plugin", "kext", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
                                                      "logicx", "band", "sparsebundle", "backupbundle", "xcarchive", "pkg", "vmwarevm", "pvm", "utm"]

    private static func biggestFirst(_ rows: [WinRow]) -> [WinRow] { rows.sorted { $0.gain > $1.gain } }

    /// The biggest few by name, then how many more: "Spotify, Chrome +14". A cache is named for its app.
    private static func names(_ rows: [WinRow]) -> String {
        let sorted = biggestFirst(rows)
        let first = sorted.prefix(3).map { $0.title.hasSuffix(" cache") ? String($0.title.dropLast(6)) : $0.title }.joined(separator: ", ")
        return sorted.count > 3 ? "\(first) +\(sorted.count - 3)" : first
    }

    /// What a model is called, without who made it, and when it arrived. macOS can't say when a file was last used, so nothing here
    /// claims a model is old.
    private static func modelRow(_ row: WinRow, tree: DiskTree) -> WinRow {
        var copy = row
        copy.title = row.title.split(separator: "/").last.map(String.init) ?? row.title
        let bits = row.subtitle.components(separatedBy: " · ")
        var when = bits.last { $0.hasPrefix("Downloaded") } ?? ""
        if when.hasSuffix(".") { when.removeLast() }
        if when.isEmpty, let node = row.nodes.first, tree.nodes[Int(node)].modTime != 0 {
            when = "Changed " + Titles.dayText(Date(timeIntervalSince1970: TimeInterval(tree.nodes[Int(node)].modTime)))
        }
        if !when.isEmpty { copy.subtitle = when }
        return copy
    }

    private static func leftoverRow(_ found: Leftovers.Found, tree: DiskTree) -> WinRow {
        let node = found.node
        let total = tree.totals[Int(node)]
        let path = tree.friendlyPath(node)
        // From the project down, which is how you'd say it: some-film › work.
        var parts: [String] = []
        var at = node
        while at != 0, parts.count < 4 {
            parts.insert(tree.name(at), at: 0)
            if at == found.project { break }
            at = tree.nodes[Int(at)].parent
        }
        let reached = at == found.project && found.project != 0
        let title = found.role == .installers ? tree.name(node) : (reached ? parts : Array(parts.suffix(3))).joined(separator: " › ")
        return WinRow(id: "leftover:" + path, title: title, subtitle: DiskTree.friendly((path as NSString).deletingLastPathComponent), detail: found.role.detail, tier: .yourCall,
                      nodes: [node], bytes: total, paperBytes: total, action: .trash, command: nil, bundleID: nil)
    }

    // MARK: The picture on screen

    /// How much of a suggestion is in this picture.
    static func scoped(_ row: WinRow, tree: DiskTree, focus: UInt32) -> WinRow? {
        guard focus != 0 else { return row }
        // Looking inside it, it's all still one thing.
        if row.nodes.contains(where: { tree.isInside(focus, $0) }) { return row }
        let inside = row.nodes.filter { tree.isInside($0, focus) }
        if inside.isEmpty { return nil }
        // An app goes with its settings and caches, wherever they are.
        if inside.count == row.nodes.count || row.action == .uninstall { return row }
        let sum = inside.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
        var copy = row
        copy.nodes = inside
        copy.bytes = min(row.bytes, sum)
        copy.paperBytes = sum
        return copy
    }

    /// The boxes for the picture on screen. On the whole disk, each section is one box. Inside a folder, a section with kinds
    /// within it opens up, and a folder that's all one kind of thing has a box for each thing.
    static func boxes(from sections: [Section], tree: DiskTree, focus: UInt32, kept: Set<String>) -> [Box] {
        func rows(_ list: [WinRow]) -> [WinRow] {
            list.compactMap { kept.contains($0.id) ? nil : scoped($0, tree: tree, focus: focus) }
        }
        func ranked(_ list: [WinRow]) -> [WinRow] { list.sorted { $0.gain > $1.gain } }
        var out: [Box] = []
        for section in sections {
            if section.kids.isEmpty {
                let inside = ranked(rows(section.rows))
                if section.id == BoxKind.trash.rawValue, let row = inside.first {
                    // Nothing to open: the Trash is one thing, with its own tick.
                    out.append(Box(id: section.id, title: row.title, detail: row.subtitle, color: section.color, rows: [row], isOneThing: true))
                } else if !inside.isEmpty {
                    out.append(Box(id: section.id, title: section.title, detail: section.detail, note: section.note, color: section.color, rows: inside, isShortlist: section.isShortlist))
                }
                continue
            }
            let kids = section.kids.compactMap { kid -> Box? in
                let inside = ranked(rows(kid.rows))
                guard !inside.isEmpty else { return nil }
                return Box(id: kid.id, title: kid.title, detail: inside.count == 1 ? "1 folder" : "\(inside.count) folders", color: focus == 0 ? section.color : kid.color, rows: inside)
            }
            guard !kids.isEmpty else { continue }
            if focus == 0 {
                out.append(Box(id: section.id, title: section.title, detail: section.detail, note: section.note, color: section.color, rows: ranked(kids.flatMap(\.rows)), kids: kids))
            } else {
                out += kids
            }
        }
        // The Trash first: it's what you've already thrown away. Then biggest first, whatever it is, and the shortlist under
        // them, since it isn't a suggestion.
        func place(_ box: Box) -> Int { box.id == BoxKind.trash.rawValue ? 0 : box.isShortlist ? 2 : 1 }
        out.sort { a, b in place(a) != place(b) ? place(a) < place(b) : a.bytes > b.bytes }
        if focus != 0, out.count == 1, out[0].kids.isEmpty, !out[0].isShortlist, out[0].rows.count > 1, out[0].rows.count <= 16 {
            return out[0].rows.enumerated().map { at, row in
                Box(id: "thing:" + row.id, title: row.title, detail: row.subtitle, note: row.inUse, color: Palette.Box.spread[at % Palette.Box.spread.count], rows: [row], isOneThing: true)
            }
        }
        return out
    }

    /// Each thing's colour on the ring: its box's, a step lighter or darker and a little warmer or cooler, so that neighbours
    /// in one box don't melt into one shape.
    static func colours(for boxes: [Box]) -> [String: Lab] {
        var out: [String: Lab] = [:]
        func paint(_ box: Box) {
            if !box.kids.isEmpty {
                box.kids.forEach(paint)
                return
            }
            for (at, row) in box.rows.enumerated() {
                let phase = (Float(at) * 0.618034).truncatingRemainder(dividingBy: 1) - 0.5
                let hue = atan2(box.color.b, box.color.a) * 180 / .pi + phase * 16
                out[row.id] = Lab(lch: min(box.color.l + phase * 0.10, 0.96), box.color.chroma * (1 - abs(phase) * 0.22), hue)
            }
        }
        boxes.forEach(paint)
        return out
    }
}

// MARK: Leftovers

/// What's left over in your own folders. It goes by what things are called and what's in them, because that's all there is to
/// go on, and it stays well away from code. It only ever suggests: everything it finds is in plain sight before anything goes.
enum Leftovers {
    enum Role: UInt8 {
        case none, leave, never, tests, scenes, review, olderVersions, oldFolders, working, backups, olderFinals, installers

        /// What you'd miss least first.
        static let inOrder: [Role] = [.tests, .scenes, .review, .olderVersions, .oldFolders, .working, .backups, .olderFinals]

        var key: String {
            switch self {
            case .tests: "tests"
            case .scenes: "scenes"
            case .review: "review"
            case .olderVersions: "older"
            case .oldFolders: "old-folders"
            case .working: "working"
            case .backups: "backups"
            case .olderFinals: "older-finals"
            default: "other"
            }
        }

        var title: String {
            switch self {
            case .tests: "Tests and scratch"
            case .scenes: "Scene renders and frames"
            case .review: "Review stills and clips"
            case .olderVersions: "Older versions"
            case .oldFolders: "Old version folders"
            case .working: "Working folders"
            case .backups: "Backups"
            case .olderFinals: "Older finals"
            default: ""
            }
        }

        var detail: String {
            switch self {
            case .tests: "Test or scratch folder, mostly media files."
            case .scenes: "Scene renders or frames. They can be rendered again from the project."
            case .review: "Review stills or clips. They can be rendered again from the project."
            case .olderVersions: "A newer version is nearby. Names with saved, keep or master are skipped."
            case .oldFolders: "An earlier version's folder, or an older one in a numbered set."
            case .working: "Working folder, mostly media files. Review before deleting."
            case .backups: "Backup inside a project. Review before deleting."
            case .olderFinals: "Older version among finals. A newer one is there too."
            case .installers: "Disk image or archive. Rarely needed once installed or unpacked."
            default: ""
            }
        }

        var color: Lab {
            switch self {
            case .tests: Palette.Box.models
            case .scenes: Palette.Box.leftovers
            case .review: Palette.Box.apps
            case .olderVersions: Palette.Box.series
            case .oldFolders: Palette.Box.quick
            case .working: Palette.Box.android
            case .backups: Palette.Box.games
            case .olderFinals: Palette.Box.watched
            default: Palette.Box.other
            }
        }
    }

    struct Found {
        var node: UInt32
        var role: Role
        /// The project it's part of, if it's in one.
        var project: UInt32 = 0
    }

    private static let folderRoles: [String: Role] = [
        "code": .leave, "src": .leave, "source": .leave, "sources": .leave, "audio": .leave, "reference": .leave, "references": .leave, "raw": .leave, "stems": .leave,
        "sound": .leave, "assets": .leave, "materials": .leave, "fonts": .leave, "editor": .leave,
        "_backup": .backups, "backup": .backups, "backups": .backups,
        "versions": .oldFolders, "old": .oldFolders, "archive": .oldFolders, "previous": .oldFolders,
        "test": .tests, "tests": .tests, "bench": .tests, "scratch": .tests, "tmp": .tests, "temp": .tests,
        "work": .working,
        "seq": .scenes, "frames": .scenes,
        "review": .review, "stills": .review, "contact": .review, "previews": .review, "preview": .review, "polish": .review, "strip": .review,
    ]
    /// A folder holding one of these is a project of yours. "work" or "test" only mean something there.
    private static let projectMarks: [String] = [".git", "final", "finals", "renders", "render", "source", "sources", "src", "code"]
    /// Folders a film's versions land in, on their way to the same project.
    private static let outputFolders: [String] = ["final", "finals", "renders", "render", "review", "versions", "out"]

    private static let keepWords: [[UInt8]] = ["saved", "keep", "master", "gold", "best", "favorite", "favourite"].map { Array($0.utf8) }
    private static let installerEnds: [[UInt8]] = [".dmg", ".pkg", ".iso", ".xip", ".zip", ".tgz", ".tar.gz", ".rar", ".7z"].map { Array($0.utf8) }

    private static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for var b in bytes {
            if b >= 65 && b <= 90 { b += 32 }
            h = (h ^ UInt64(b)) &* 0x100_0000_01b3
        }
        return h
    }

    private static func hash(_ text: String) -> UInt64 { Array(text.utf8).withUnsafeBufferPointer { hash($0) } }

    private static let roleByHash: [UInt64: Role] = Dictionary(uniqueKeysWithValues: folderRoles.map { (hash($0.key), $0.value) })
    private static let projectHashes = Set(projectMarks.map { hash($0) })
    private static let outputHashes = Set(outputFolders.map { hash($0) })
    private static let finalHashes: Set<UInt64> = [hash("final"), hash("finals")]
    private static let worktreesHash = hash("worktrees")
    private static let claudeHash = hash(".claude")

    private static func starts(_ b: UnsafeBufferPointer<UInt8>, _ text: StaticString) -> Bool {
        guard b.count >= text.utf8CodeUnitCount, let base = b.baseAddress else { return false }
        return memcmp(base, text.utf8Start, text.utf8CodeUnitCount) == 0
    }

    private static func role(ofFolder b: UnsafeBufferPointer<UInt8>) -> Role {
        guard b.count > 0 else { return .none }
        if b.count <= 16, let known = roleByHash[hash(b)] { return known }
        if starts(b, "scenes") || starts(b, "2160p") || starts(b, "1080p") || starts(b, "720p") { return .scenes }
        if starts(b, "_v"), b.count > 2, b[2...].allSatisfy({ $0 >= 48 && $0 <= 57 }) { return .oldFolders }
        if ends(b, ["-tests", "_tests"].map { Array($0.utf8) }) { return .tests }
        return .none
    }

    private static func contains(_ b: UnsafeBufferPointer<UInt8>, _ words: [[UInt8]]) -> Bool {
        for word in words where b.count >= word.count {
            var at = 0
            while at + word.count <= b.count {
                var same = true
                for k in 0..<word.count {
                    var c = b[at + k]
                    if c >= 65 && c <= 90 { c += 32 }
                    if c != word[k] {
                        same = false
                        break
                    }
                }
                if same { return true }
                at += 1
            }
        }
        return false
    }

    private static func ends(_ b: UnsafeBufferPointer<UInt8>, _ endings: [[UInt8]]) -> Bool {
        for end in endings where b.count >= end.count {
            var same = true
            for k in 0..<end.count {
                var c = b[b.count - end.count + k]
                if c >= 65 && c <= 90 { c += 32 }
                if c != end[k] {
                    same = false
                    break
                }
            }
            if same { return true }
        }
        return false
    }

    /// `film-v12-4k.mp4` gives the length of `film`, and 12.
    static func version(of b: UnsafeBufferPointer<UInt8>) -> (stem: Int, version: Int)? {
        guard b.count >= 4 else { return nil }
        var i = 1
        while i + 1 < b.count {
            let c = b[i], before = b[i - 1]
            if c == 118 || c == 86, before == 45 || before == 95 || before == 32 || before == 46, b[i + 1] >= 48, b[i + 1] <= 57 {
                var j = i + 1, value = 0
                while j < b.count, b[j] >= 48, b[j] <= 57, value < 100_000 {
                    value = value * 10 + Int(b[j] - 48)
                    j += 1
                }
                if j == b.count || !((b[j] >= 65 && b[j] <= 90) || (b[j] >= 97 && b[j] <= 122)) { return (i - 1, value) }
            }
            i += 1
        }
        return nil
    }

    /// One pass over the flat tree, where a parent always comes before its children, so it costs milliseconds on a whole disk.
    static func find(in tree: DiskTree) -> [Found] {
        let n = tree.count
        guard n > 1 else { return [] }
        let nodes = tree.nodes
        func name(_ i: Int) -> UnsafeBufferPointer<UInt8> {
            UnsafeBufferPointer(start: tree.names + Int(nodes[i].nameOffset), count: Int(nodes[i].nameLength))
        }
        func isMedia(_ id: UInt32) -> Bool {
            let kinds = tree.kindBytes(id)
            let all = kinds.reduce(UInt64(0), &+)
            guard all > 0 else { return false }
            let media = kinds[Int(Kind.video.rawValue)] &+ kinds[Int(Kind.audio.rawValue)] &+ kinds[Int(Kind.image.rawValue)]
            return Double(media) >= Double(all) * 0.4
        }

        let isProject = Mapped<Bool>(repeating: false, count: n)
        for i in 1..<n where nodes[i].flags & NodeFlag.directory != 0 && nodes[i].flags & (NodeFlag.synthetic | NodeFlag.anchor) == 0 {
            let b = name(i)
            if b.count <= 8, projectHashes.contains(hash(b)) { isProject[Int(nodes[i].parent)] = true }
        }

        let roles = Mapped<Role>(repeating: .none, count: n)
        let project = Mapped<UInt32>(count: n)
        let inProject = Mapped<Bool>(repeating: false, count: n)
        let projectRoot = Mapped<UInt32>(count: n)
        var newest: [UInt64: Int] = [:]
        var newestFolder: [UInt32: Int] = [:]
        var numbered: [(node: UInt32, parent: UInt32, version: Int)] = []
        var versioned: [(node: UInt32, key: UInt64, version: Int, inFinals: Bool)] = []

        for i in 1..<n {
            let node = nodes[i]
            let parent = Int(node.parent)
            let inherited = roles[parent]
            project[i] = UInt32(i)
            inProject[i] = inProject[parent] || isProject[i]
            projectRoot[i] = isProject[i] ? UInt32(i) : projectRoot[parent]
            if node.flags & (NodeFlag.synthetic | NodeFlag.gone | NodeFlag.anchor) != 0 { continue }
            let b = name(i)
            if node.flags & NodeFlag.directory != 0 {
                // Only your own folders. Inside an app or a tool, "test" and "old" mean nothing.
                guard inherited != .never, node.flags & NodeFlag.projects != 0, node.rule == 0 else {
                    roles[i] = .never
                    continue
                }
                // Another copy of a project, in use or not, and only git can say which.
                if hash(b) == worktreesHash, hash(name(parent)) == claudeHash {
                    roles[i] = .never
                    continue
                }
                // Kept on purpose, in so many words.
                if contains(b, keepWords) {
                    roles[i] = .never
                    continue
                }
                project[i] = b.count <= 8 && outputHashes.contains(hash(b)) ? project[parent] : UInt32(i)
                if inherited != .none && inherited != .leave {
                    roles[i] = inherited
                    continue
                }
                var own = inProject[parent] || inProject[i] ? role(ofFolder: b) : .none
                if own != .none, own != .leave, !isMedia(UInt32(i)) { own = .none }
                roles[i] = own == .none ? inherited : own
                if roles[i] == .none, b.count >= 2, b[0] == 118 || b[0] == 86, b[1...].allSatisfy({ $0 >= 48 && $0 <= 57 }) {
                    let value = b[1...].reduce(0) { min($0 * 10 + Int($1 - 48), 100_000) }
                    newestFolder[node.parent] = max(newestFolder[node.parent] ?? 0, value)
                    numbered.append((UInt32(i), node.parent, value))
                }
            } else {
                guard inherited != .never, nodes[parent].flags & NodeFlag.projects != 0, node.rule == 0, node.flags & NodeFlag.alias == 0 else { continue }
                roles[i] = inherited
                if inherited == .none, ends(b, installerEnds) { roles[i] = .installers }
                if inherited != .leave, let found = version(of: b) {
                    let stem = UnsafeBufferPointer(rebasing: b[0..<found.stem])
                    let key = hash(stem) ^ (UInt64(project[parent]) &* 0x9E37_79B9_7F4A_7C15)
                    newest[key] = max(newest[key] ?? 0, found.version)
                    if !contains(b, keepWords), node.kind == Kind.video.rawValue || node.kind == Kind.audio.rawValue {
                        versioned.append((UInt32(i), key, found.version, finalHashes.contains(hash(name(parent)))))
                    }
                }
            }
        }
        for one in versioned where one.version < (newest[one.key] ?? 0) && roles[Int(one.node)] == .none {
            roles[Int(one.node)] = one.inFinals ? .olderFinals : .olderVersions
        }
        for one in numbered where one.version < (newestFolder[one.parent] ?? 0) && roles[Int(one.node)] == .none && isMedia(one.node) {
            roles[Int(one.node)] = .oldFolders
        }
        // Only the outermost of each: a folder says it for everything in it. What was found last needs passing down first.
        var out: [Found] = []
        for i in 1..<n {
            let up = roles[Int(nodes[i].parent)]
            if roles[i] == .none, up != .none, up != .leave { roles[i] = up }
            let role = roles[i]
            if role == .none || role == .leave || role == .never || role == up { continue }
            out.append(Found(node: UInt32(i), role: role, project: projectRoot[i]))
        }
        return out
    }
}
