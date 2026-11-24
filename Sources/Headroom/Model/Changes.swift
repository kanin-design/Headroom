import Foundation

enum ChangeWindow: Hashable, Identifiable {
    case lastScan
    case days(Int)
    /// The other way round: what nothing inside has changed in for this many days.
    case untouched(Int)

    static let untouchedWindows: [ChangeWindow] = [.untouched(30), .untouched(91), .untouched(365)]

    var id: String {
        switch self {
        case .lastScan: "last"
        case .days(let d): "\(d)"
        case .untouched(let d): "u\(d)"
        }
    }

    var title: String {
        switch self {
        case .lastScan: "Last scan"
        case .days(1): "24 hours"
        case .days(let d): "\(d) days"
        case .untouched(30): "1 month"
        case .untouched(91): "3 months"
        case .untouched(365): "1 year"
        case .untouched(let d): "\(d) days"
        }
    }

    /// How long, in a sentence: "for a year".
    var span: String {
        switch self {
        case .untouched(30): "for a month"
        case .untouched(365): "for a year"
        default: "for \(title)"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .lastScan: 0
        case .days(let d), .untouched(let d): TimeInterval(d) * 86_400
        }
    }

    var isUntouched: Bool {
        if case .untouched = self { return true }
        return false
    }
}

struct ChangeRow: Identifiable, Equatable {
    var id: UInt32 { node }
    var node: UInt32
    var title: String
    var subtitle: String
    var delta: Int64
}

/// What grew. It compares with an earlier scan when there is one, and otherwise reads file dates, so the view says
/// something useful on the very first day. Or the other way round: what nothing has changed in for a long time.
final class ChangeMap: @unchecked Sendable {
    private(set) var usesHistory = false
    /// Each value is what hasn't changed in the window, rather than what has.
    private(set) var isUntouched = false
    private(set) var caption = ""
    private(set) var shortCaption = ""
    private let capacity: Int
    private let values: UnsafeMutablePointer<Int64>
    /// In a comparison with an earlier scan, how much grew and how much shrank inside each piece, counted apart. A folder
    /// that shrank overall can still hold one that grew, and the list of what grew has to find it.
    private var grown: UnsafeMutablePointer<Int64>?
    private var shrunk: UnsafeMutablePointer<Int64>?
    private(set) var total: Int64 = 0

    /// `rules` and `used` matter only for what's gone untouched: what to leave out, and what you're known to have used.
    init(tree: DiskTree, window: ChangeWindow, rules: RuleBook? = nil, used: [UInt32] = []) {
        capacity = max(tree.count, 1)
        values = vmAlloc(Int64.self, capacity)
        if case .untouched(let days) = window {
            isUntouched = true
            fillUntouched(tree, days: days, rules: rules, used: used)
            caption = "Not changed \(window.span), going by file dates." + (tree.isPartial ? " Still reading, so this may grow." : "")
            shortCaption = "untouched \(window.span)"
            return
        }
        // Half-read folders would look as if they'd shrunk, so a comparison waits until the scan is done.
        let snapshot =
            tree.isPartial
            ? nil : History.snapshot(forVolume: tree.volumeName, olderThan: window.seconds, isLast: window == .lastScan, before: tree.finishedAt)
        let nodes = tree.nodes
        let n = tree.count
        if let snapshot {
            compare(tree, with: snapshot)
        } else if window == .lastScan {
            caption =
                tree.isPartial
                ? "This can compare once the scan has finished."
                : "There's no earlier scan to compare with yet. Come back after your next scan."
            shortCaption = ""
        } else {
            let days: Int
            if case .days(let d) = window { days = d } else { days = 30 }
            let field = days == 1 ? DiskTree.statRecent1 : (days == 7 ? DiskTree.statRecent7 : DiskTree.statRecent30)
            let cut = UInt32(seconds: Date().timeIntervalSince1970) &- UInt32(days) * 86_400
            for i in 0..<n {
                if nodes[i].has(NodeFlag.directory) {
                    // Left alone where nothing changed, so that part of the table never takes up memory.
                    let units = tree.statRow(i)[field]
                    if units != 0 { values[i] = Int64(DiskTree.bytes(units: units)) }
                } else if !nodes[i].has(NodeFlag.synthetic), nodes[i].modTime >= cut {
                    values[i] = Int64(bitPattern: tree.totals[i])
                }
            }
            let label = window == .days(1) ? "the last 24 hours" : "the last \(days) days"
            caption =
                "New or changed in \(label), going by file dates."
                + (tree.isPartial ? " Still reading, so this may grow." : " History builds up from today.")
            shortCaption = "in \(label)"
        }
    }

    /// A comparison with this earlier scan, rather than one History finds.
    init(tree: DiskTree, comparingWith snapshot: ScanSnapshot) {
        capacity = max(tree.count, 1)
        values = vmAlloc(Int64.self, capacity)
        compare(tree, with: snapshot)
    }

    deinit {
        vmFree(values, capacity)
        if let grown { vmFree(grown, capacity) }
        if let shrunk { vmFree(shrunk, capacity) }
    }

    /// Each piece's size now against the earlier scan's. What that scan didn't record, being too small then, counts as new.
    private func compare(_ tree: DiskTree, with snapshot: ScanSnapshot) {
        usesHistory = true
        let n = tree.count
        let keys = vmAlloc(UInt64.self, capacity)
        defer { vmFree(keys, capacity) }
        History.fillKeys(tree: tree, into: keys)
        let table = snapshot.table
        let resolution = History.smallestEntry
        for i in 0..<n {
            let now = tree.totals[i]
            if let before = table[keys[i]] {
                values[i] = Int64(bitPattern: now) &- Int64(bitPattern: before)
            } else if now >= resolution {
                values[i] = Int64(bitPattern: now)
            }
        }
        countGrowthAndShrinkage(tree)
        let formatter = DateFormatter()
        formatter.locale = Titles.locale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        caption = "Compared with the scan from \(formatter.string(from: snapshot.date))."
        shortCaption = "since then"
        // The disk's own free space is the honest total.
        total = Int64(bitPattern: snapshot.free) &- Int64(bitPattern: tree.freeBytes)
    }

    /// How much grew and how much shrank inside each piece, counted apart: its own change, the part its pieces don't
    /// explain, plus what grew or shrank in each of them. A parent's index is always lower than its children's, so one
    /// pass back up the table adds each piece into the one that holds it. Only what changed is written, so the rest of
    /// the table takes no memory.
    private func countGrowthAndShrinkage(_ tree: DiskTree) {
        let n = tree.count
        guard n > 0 else { return }
        let nodes = tree.nodes
        let grown = vmAlloc(Int64.self, capacity), shrunk = vmAlloc(Int64.self, capacity)
        let inPieces = vmAlloc(Int64.self, capacity)
        defer { vmFree(inPieces, capacity) }
        for i in stride(from: n - 1, through: 0, by: -1) {
            let own = values[i] &- inPieces[i]
            if own > 0 { grown[i] &+= own } else if own < 0 { shrunk[i] &-= own }
            guard i > 0 else { break }
            let parent = Int(nodes[i].parent)
            if values[i] != 0 { inPieces[parent] &+= values[i] }
            if grown[i] != 0 { grown[parent] &+= grown[i] }
            if shrunk[i] != 0 { shrunk[parent] &+= shrunk[i] }
        }
        self.grown = grown
        self.shrunk = shrunk
    }

    /// How much grew inside a piece, or with `shrinking`, how much shrank. Going by file dates, nothing shrinks, so what
    /// grew is the piece's own value.
    func amount(_ node: UInt32, shrinking: Bool) -> Int64 {
        let i = Int(node)
        guard i < capacity else { return 0 }
        if shrinking { return shrunk?[i] ?? max(-values[i], 0) }
        return grown?[i] ?? max(values[i], 0)
    }

    /// For each piece, the bytes in it that haven't changed in `days`, going by file dates. Three kinds of thing don't count,
    /// in themselves or in what holds them: macOS's own parts and what can't be read, which have no dates worth the name;
    /// what the app leaves alone; and what you're known to have used in that time, such as an app you opened last week
    /// whose files are years old.
    private func fillUntouched(_ tree: DiskTree, days: Int, rules: RuleBook?, used: [UInt32]) {
        let n = tree.count
        guard n > 0 else { return }
        let nodes = tree.nodes
        // The nearest kept field at or before the window, so nothing newer than it is ever counted as untouched.
        let field = DiskTree.recency.last { $0.days <= UInt32(days) }?.field ?? DiskTree.statRecent1
        let cut = UInt32(seconds: Date().timeIntervalSince1970) &- UInt32(days) * 86_400
        for i in 0..<n {
            let total = tree.totals[i]
            if nodes[i].has(NodeFlag.directory) {
                let recent = DiskTree.bytes(units: tree.statRow(i)[field])
                if total > recent { values[i] = Int64(bitPattern: total - recent) }
            } else if nodes[i].modTime < cut {
                values[i] = Int64(bitPattern: total)
            }
        }
        // Which pieces are left out. A parent's index is always lower than its children's, so one pass down the table
        // marks whole branches, and one pass back up takes them out of everything that holds them.
        let out = vmAlloc(UInt8.self, n)
        let taken = vmAlloc(Int64.self, n)
        defer {
            vmFree(out, n)
            vmFree(taken, n)
        }
        for id in used where Int(id) < n { out[Int(id)] = 1 }
        for i in 1..<n {
            let node = nodes[i]
            var leftOut = node.has(NodeFlag.synthetic)
            if !leftOut, node.rule != 0, let rules {
                let rule = rules.rule(node.rule)
                leftOut = rule.restartClears || rule.tier == .handsOff || rule.kind == .system
            }
            if leftOut { out[i] = 1 }
            // Inside something left out: 2, so it isn't taken out a second time.
            if out[Int(node.parent)] != 0 { out[i] = 2 }
        }
        var i = n - 1
        while i > 0 {
            let p = Int(nodes[i].parent)
            switch out[i] {
            case 1: taken[p] &+= values[i]
            case 0: taken[p] &+= taken[i]
            default: break
            }
            i -= 1
        }
        for i in 0..<n {
            var left = out[i] != 0 ? 0 : max(values[i] &- taken[i], 0)
            // A folder's sums are kept to the nearest 16 KiB, so one that has all changed can still seem to have a little
            // left over. That much isn't worth saying.
            if nodes[i].has(NodeFlag.directory), UInt64(left) < max(65_536, tree.totals[i] / 1000) { left = 0 }
            values[i] = left
        }
        total = values[0]
    }

    /// What you're known to have used in the last `days`: apps you've opened or have open, what Plex says you watched,
    /// games Steam started, and big videos Spotlight saw you open. Their files may be old, but they aren't forgotten.
    static func usedRecently(_ facts: Facts, in tree: DiskTree, days: Int, now: Date = Date()) -> [UInt32] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var paths: [String] = []
        for app in facts.apps where app.isRunning || (app.newestSign ?? .distantPast) >= since { paths.append(app.path) }
        for (path, file) in facts.plexFiles where (file.lastViewed ?? .distantPast) >= since { paths.append(path) }
        for game in facts.games where (game.lastPlayed ?? .distantPast) >= since { paths.append(game.folder) }
        for (path, opened) in facts.lastOpened where opened >= since { paths.append(path) }
        // The tree keeps the data volume's own paths, which is what a path from another app may leave out.
        return paths.compactMap { tree.find(visible: $0) }
    }

    /// During a scan this map can be one picture behind, so a folder found since then has nothing to say yet.
    @inline(__always) func value(of node: UInt32) -> Int64 { Int(node) < capacity ? values[Int(node)] : 0 }

    /// The folders that explain the growth. Not "your files grew", but which folder did, and no deeper than is
    /// useful: a season that grew is one row, not eight episodes. It follows what grew, not what each folder came to in
    /// the end, so growth inside a folder that shrank overall is still found.
    /// With `shrinking`, the same for what got smaller, with negative deltas. With a folder as `root`, only what's in that
    /// folder, named no higher than the things directly in it.
    func rows(tree: DiskTree, rules: RuleBook, shrinking: Bool = false, under root: UInt32 = 0) -> [ChangeRow] {
        let sign: Int64 = shrinking ? -1 : 1
        @inline(__always) func changed(_ id: UInt32) -> Int64 { amount(id, shrinking: shrinking) }
        var out: [UInt32: Int64] = [:]
        let minimum: Int64 = 100_000_000
        let nodes = tree.nodes
        let bundles = [
            ".app", ".framework", ".bundle", ".photoslibrary", ".sparsebundle", ".xcarchive", ".fcpbundle", ".appex", ".kext", ".xcframework",
        ]

        // By file dates, macOS's own bookkeeping looks new every day, so only a comparison with history counts it.
        func isNoise(_ id: UInt32) -> Bool {
            guard !usesHistory else { return false }
            let n = nodes[Int(id)]
            if n.has(NodeFlag.synthetic) && n.parent != 0 { return true }
            if n.rule != 0 {
                let rule = rules.rule(n.rule)
                if rule.restartClears || rule.tier == .handsOff || rule.kind == .system { return true }
            }
            return false
        }
        func emit(_ id: UInt32) {
            // A folder that holds nearly all of this growth says it just as well, and is easier to recognise.
            var at = id
            while true {
                let up = nodes[Int(at)].parent
                if up == root || up == 0 || up == tree.home || nodes[Int(up)].parent == 0 || nodes[Int(up)].parent == tree.home
                    || nodes[Int(up)].has(NodeFlag.synthetic)
                {
                    break
                }
                if Double(changed(up)) > Double(changed(id)) * 1.12 { break }
                // Nor when it also went the other way: a folder that shrank overall isn't one that grew.
                if Double(sign * values[Int(up)]) < Double(changed(id)) * 0.9 { break }
                // Named as untouched, a folder has to be nearly all untouched, not hold something you're working on too.
                if isUntouched, Double(values[Int(up)]) < Double(tree.totals[Int(up)]) * 0.9 { break }
                at = up
            }
            out[at] = max(changed(at), out[at] ?? 0)
        }
        func walk(_ id: UInt32, _ depth: Int) {
            let d = changed(id)
            guard d >= minimum, !isNoise(id) else { return }
            let name = tree.rawName(id)
            if bundles.contains(where: { name.hasSuffix($0) }) { emit(id); return }
            var big: [UInt32] = []
            var top: Int64 = 0
            var c = nodes[Int(id)].firstChild
            while c != 0 {
                let v = changed(c)
                if v >= minimum && !isNoise(c) {
                    big.append(c)
                    top = max(top, v)
                }
                c = nodes[Int(c)].nextSibling
            }
            if big.isEmpty { if depth > 0 { emit(id) }; return }
            // Broad folders always open up. Further down, only when one part stands out.
            if depth <= 1 || Double(top) >= Double(d) * 0.35 {
                for b in big { walk(b, depth + 1) }
            } else {
                emit(id)
            }
        }
        if root == 0 {
            var topLevel = nodes[0].firstChild
            while topLevel != 0 {
                if topLevel != tree.free && topLevel != tree.hidden { walk(topLevel, 0) }
                topLevel = nodes[Int(topLevel)].nextSibling
            }
        } else {
            // Inside a folder, what's directly in it can be a row of its own, as anything deeper can on the whole disk.
            var child = nodes[Int(root)].firstChild
            while child != 0 {
                walk(child, 1)
                child = nodes[Int(child)].nextSibling
            }
        }
        return out.sorted { $0.value > $1.value }.prefix(60).map { id, delta in
            let parent = nodes[Int(id)].parent
            let name = tree.name(id)
            // A name like "final" or "8.14" only makes sense next to the folder it's in, unless that's the folder you're in.
            let generic =
                parent != root && name.count <= 8 && nodes[Int(id)].has(NodeFlag.directory)
                && (name.first?.isNumber == true || name == name.lowercased())
            return ChangeRow(
                node: id, title: generic ? "\(tree.name(parent)) › \(name)" : name,
                subtitle: tree.path(parent).map(DiskTree.friendly) ?? tree.name(parent), delta: sign * delta)
        }
    }
}
