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

    var bytes: UInt64 { rows.reduce(0) { $0 &+ $1.gain } }

    /// What a tick on the box takes. What you set up by hand, or may be sorry to lose, stays for a tick of its own, unless
    /// that's all there is: then you can only mean that.
    var rowsATickTakes: [WinRow] {
        let plain = rows.filter { !$0.askFirst }
        return plain.isEmpty ? rows : plain
    }
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

    static func build(from wins: [WinRow], tree: DiskTree, facts: Facts = .none, now: Date = Date()) -> Suggestions {
        var flat: [WinRow] = []
        for row in wins {
            if row.parts.isEmpty { flat.append(row) } else { flat += row.parts }
        }
        var trash: [WinRow] = [], quick: [WinRow] = [], models: [WinRow] = [], series: [WinRow] = [], films: [WinRow] = [], apps: [WinRow] = []
        var games: [WinRow] = [], android: [WinRow] = [], frames: [WinRow] = [], repos: [WinRow] = [], left: [WinRow] = [], used: [WinRow] = [], other: [WinRow] = []
        var others: [WinRow] = []
        for row in flat {
            guard row.isPlannable else {
                others.append(row)
                continue
            }
            let path = row.nodes.first.flatMap { tree.path($0) } ?? ""
            if row.action == .emptyTrash { trash.append(row) }
            else if row.isQuick { quick.append(row) }
            else if row.id.hasPrefix("model:") || path.contains("/LLM/") { models.append(modelRow(row, tree: tree)) }
            else if row.id.hasPrefix("series:") { series.append(row) }
            else if row.id.hasPrefix("film:") { films.append(row) }
            else if row.id.hasPrefix("app:") { apps.append(row) }
            else if row.id.hasPrefix("steam:") { games.append(row) }
            else if path.contains("/Android/") || path.contains("/.android/") { android.append(row) }
            else if row.id.hasPrefix("frames:") { frames.append(row) }
            else if row.id.hasPrefix("repo:") { repos.append(row) }
            else if row.id.hasPrefix("left:") { left.append(row) }
            // Found again below, file by file, wherever they are.
            else if row.id == "group:installers" { continue }
            else if row.tier == .rebuilds { used.append(row) }
            else { other.append(row) }
        }

        var watched: [WinRow] = [], unwatched: [WinRow] = []
        var seenEpisodes = 0
        var videos: [UInt32] = []
        if !series.isEmpty, !facts.plexFiles.isEmpty {
            for i in 1..<max(tree.count, 1) {
                let n = tree.nodes[i]
                if n.kind == Kind.video.rawValue, n.flags & (NodeFlag.directory | NodeFlag.synthetic | NodeFlag.alias | NodeFlag.gone) == 0 { videos.append(UInt32(i)) }
            }
        }
        for row in series {
            let split = splitByWatched(row, videos: videos, tree: tree, facts: facts, now: now)
            if let seen = split.seen { watched.append(seen); seenEpisodes += split.seenCount }
            if let rest = split.rest { unwatched.append(rest) }
        }

        // What's left over in your own folders, by what it is. The advisor's numbered frames join in, unless the names found them.
        let found = Leftovers.find(in: tree)
        let foundSet = NodeSet(found.map(\.node), in: tree)
        var kinds: [Leftovers.Role: [WinRow]] = [:]
        var fresh: [WinRow] = found.map { leftoverRow($0, tree: tree) }
        Wins.settleReclaim(&fresh, tree: tree)
        for (row, one) in zip(fresh, found) where row.gain >= smallestLeftover { kinds[one.role, default: []].append(row) }
        for row in frames where !row.nodes.allSatisfy({ foundSet.contains($0) }) { kinds[.scenes, default: []].append(row) }
        // A big old file is its own suggestion, unless it's already part of a folder of leftovers.
        other.removeAll { $0.nodes.allSatisfy { foundSet.contains($0) } }

        var kids: [Section] = []
        for role in Leftovers.Role.inOrder {
            guard let rows = kinds[role], !rows.isEmpty else { continue }
            kids.append(Section(id: "leftovers." + role.key, title: role.title, detail: rows.count == 1 ? "1 place" : "\(rows.count) places", color: role.color, rows: biggestFirst(rows)))
        }

        var out: [Section] = []
        func add(_ id: String, _ title: String, _ detail: String, note: String? = nil, _ color: Lab, _ rows: [WinRow]) {
            guard !rows.isEmpty else { return }
            out.append(Section(id: id, title: title, detail: detail, note: note, color: color, rows: biggestFirst(rows)))
        }
        add("trash", "Trash", "Already thrown away", Palette.Box.trash, trash)
        add("quick", "Caches and build output", "Rebuilds itself. Nothing you'd miss", Palette.Box.quick, quick)
        add("models", "AI models", models.count == 1 ? "It downloads again if needed" : "\(models.count) models. They download again if needed", Palette.Box.models, models)
        if !kids.isEmpty {
            out.append(Section(id: "leftovers", title: "Project leftovers", detail: "Old versions, renders, review stills", color: Palette.Box.leftovers, kids: kids))
        }
        let installers = kinds[.installers] ?? []
        add("installers", "Installers and archives", installers.count == 1 ? "A file you may be done with" : "\(installers.count) files you may be done with", Palette.Box.installers, installers)
        add("watched", "Episodes you've watched", seenEpisodes == 1 ? "1 episode, going by Plex" : "\(seenEpisodes) episodes, going by Plex", Palette.Box.watched, watched)
        add("apps", "Apps you don't seem to use", "No sign of use for 6 months", Palette.Box.apps, apps)
        add("left", "Left behind by old apps", "The app isn't on this Mac", Palette.Box.left, left)
        add("used", "Caches you've used lately", "They rebuild, but apps start slower", Palette.Box.used, used)
        let androidRunning = android.contains { $0.inUse?.contains("running") == true }
        add("android", "Android tools and emulator", "They download again if needed", note: androidRunning ? "Running now" : nil, Palette.Box.android, android)
        add("games", "Games", "Steam can download them again", Palette.Box.games, games)
        add("repos", "Projects you could clone again", "Everything is pushed", Palette.Box.repos, repos)
        add("films", "Films", names(films), Palette.Box.films, films)
        add("other", "Other big things", names(other), Palette.Box.other, other)
        add("series", "Series you haven't watched", names(unwatched), Palette.Box.series, unwatched)
        return Suggestions(sections: out, others: others)
    }

    private static func biggestFirst(_ rows: [WinRow]) -> [WinRow] { rows.sorted { $0.gain > $1.gain } }

    private static func names(_ rows: [WinRow]) -> String {
        let sorted = biggestFirst(rows)
        let first = sorted.prefix(2).map(\.title).joined(separator: ", ")
        return sorted.count > 2 ? "\(first) and \(sorted.count - 2) more" : first
    }

    /// What a model is called, without who made it, and when it arrived. macOS can't say when a file was last used, so nothing here
    /// claims a model is old.
    private static func modelRow(_ row: WinRow, tree: DiskTree) -> WinRow {
        var copy = row
        copy.title = row.title.split(separator: "/").last.map(String.init) ?? row.title
        let bits = row.subtitle.components(separatedBy: ". ")
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

    /// A series is two decisions once you've seen part of it: what you've watched, and what you haven't.
    static func splitByWatched(_ row: WinRow, videos: [UInt32], tree: DiskTree, facts: Facts, now: Date) -> (seen: WinRow?, rest: WinRow?, seenCount: Int) {
        guard !facts.plexFiles.isEmpty else { return (nil, row, 0) }
        let set = NodeSet(row.nodes, in: tree)
        var seen: [UInt32] = [], rest: [UInt32] = []
        for video in videos where set.contains(video) {
            guard let path = tree.path(video).map(Facts.visible) else { continue }
            if (facts.plexFiles[path]?.views ?? 0) > 0 { seen.append(video) } else { rest.append(video) }
        }
        let count = seen.count + rest.count
        if seen.isEmpty { return (nil, row, 0) }
        if rest.isEmpty {
            var whole = row
            whole.id = "watched:" + row.id
            whole.subtitle = count == 1 ? "Watched" : "All \(count) episodes"
            return (whole, nil, count)
        }
        let links = tree.links.filter { $0.kind == Kind.video.rawValue }
        func part(_ id: String, _ nodes: [UInt32], _ text: String) -> WinRow {
            let bytes = nodes.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            var one = WinRow(id: id, title: row.title, subtitle: text, detail: row.detail, tier: row.tier, nodes: nodes, bytes: bytes, paperBytes: bytes, action: .trash, command: nil, bundleID: nil)
            Advisors.addOtherCopies(to: &one, title: row.title, links: links, tree: tree, facts: facts, now: now)
            return one
        }
        return (part("watched:" + row.id, seen, "\(seen.count) of \(count) episodes"), part(row.id, rest, "\(rest.count) of \(count) not watched"), seen.count)
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
                if !inside.isEmpty { out.append(Box(id: section.id, title: section.title, detail: section.detail, note: section.note, color: section.color, rows: inside)) }
                continue
            }
            let kids = section.kids.compactMap { kid -> Box? in
                let inside = ranked(rows(kid.rows))
                guard !inside.isEmpty else { return nil }
                return Box(id: kid.id, title: kid.title, detail: inside.count == 1 ? "1 place" : "\(inside.count) places", color: focus == 0 ? section.color : kid.color, rows: inside)
            }
            guard !kids.isEmpty else { continue }
            if focus == 0 {
                out.append(Box(id: section.id, title: section.title, detail: section.detail, note: section.note, color: section.color, rows: ranked(kids.flatMap(\.rows)), kids: kids))
            } else {
                out += kids
            }
        }
        if focus != 0, out.count == 1, out[0].kids.isEmpty, out[0].rows.count > 1, out[0].rows.count <= 16 {
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
            case .tests: "Named as a test or a scratch folder, and mostly pictures, video or sound."
            case .scenes: "Named as scene renders or frames. They can be made again if you still have what made them."
            case .review: "Named as stills or clips for checking work. They can be made again if you still have what made them."
            case .olderVersions: "A newer version of this is nearby. Anything named saved, keep or master is left out."
            case .oldFolders: "A folder of an earlier version, or an older one of a numbered set."
            case .working: "A working folder, mostly pictures, video or sound. Look before you decide."
            case .backups: "A backup inside a project. Look before you decide."
            case .olderFinals: "An older version in a folder of finals. A newer one is there too."
            case .installers: "A disk image or an archive. Once it's installed or unpacked, you rarely need it."
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

        var isProject = [Bool](repeating: false, count: n)
        for i in 1..<n where nodes[i].flags & NodeFlag.directory != 0 && nodes[i].flags & (NodeFlag.synthetic | NodeFlag.anchor) == 0 {
            let b = name(i)
            if b.count <= 8, projectHashes.contains(hash(b)) { isProject[Int(nodes[i].parent)] = true }
        }

        var roles = [Role](repeating: .none, count: n)
        var project = [UInt32](repeating: 0, count: n)
        var inProject = [Bool](repeating: false, count: n)
        var projectRoot = [UInt32](repeating: 0, count: n)
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
