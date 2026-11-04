import AppKit
import Foundation
import simd

// MARK: Free Up

enum WinAction: Equatable {
    case trash              // can be ticked and moved to the Trash
    case restart            // a restart clears it
    case softwareUpdate     // installing a waiting update clears it
    case openTrash          // it's in the Trash already
    case command            // better done by its own tool
    case info               // only explained: macOS looks after it
}

struct WinRow: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var detail: String
    var tier: Tier
    var nodes: [UInt32]
    var bytes: UInt64             // what you'd really get back
    var paperBytes: UInt64        // what it adds up to, when that's more
    var action: WinAction
    var command: String?
    var bundleID: String?
}

/// How much of each folder can go, and how safely. It colours Free Up, and it doesn't change until the next scan.
final class ReclaimMap: @unchecked Sendable {
    let bytes: UnsafeMutablePointer<UInt64>
    let tier: UnsafeMutablePointer<UInt8>
    private let capacity: Int

    init(tree: DiskTree, rules: RuleBook) {
        capacity = max(tree.count, 1)
        bytes = vmAlloc(UInt64.self, capacity)
        tier = vmAlloc(UInt8.self, capacity)
        let nodes = tree.nodes
        for i in 0..<tree.count {
            let n = nodes[i]
            guard n.rule != 0, n.has(NodeFlag.ruleRoot) || n.has(NodeFlag.synthetic) else { continue }
            let t = rules.rule(n.rule).tier
            guard t != .none, t != .handsOff else { continue }
            bytes[i] = tree.totals[i]
            tier[i] = t.rawValue
        }
        // Up the tree: each folder learns how much inside it can go, and the safest way that any of it can.
        var i = tree.count - 1
        while i > 0 {
            let p = Int(nodes[i].parent)
            bytes[p] &+= bytes[i]
            if tier[i] != 0 && (tier[p] == 0 || tier[i] < tier[p]) { tier[p] = tier[i] }
            i -= 1
        }
    }

    deinit {
        vmFree(bytes, capacity)
        vmFree(tier, capacity)
    }
}

enum Wins {
    static let smallestRow: UInt64 = 50_000_000
    static let smallerCachesID = "group:smaller-caches"

    static func appName(forFolder name: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        let parts = name.split(separator: ".")
        if parts.count >= 3, let last = parts.last {
            let cleaned = last.replacingOccurrences(of: "-", with: " ")
            return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
        return name
    }

    static func build(tree: DiskTree, rules: RuleBook) -> [WinRow] {
        let nodes = tree.nodes
        var rows: [WinRow] = []
        var groupIndex: [UInt16: Int] = [:]
        var smallCaches: [UInt32] = []
        var restartExtras: [UInt32] = []
        var trashNode: UInt32?

        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            guard n.has(NodeFlag.ruleRoot), n.rule != 0 else { continue }
            let id = UInt32(i)
            let total = tree.totals[i]
            guard total > 0 else { continue }
            let rule = rules.rule(n.rule)
            guard rule.tier != .none, rule.tier != .handsOff else { continue }
            if rule.restartClears { restartExtras.append(id); continue }
            if rule.title == "Trash" { trashNode = id; continue }
            // macOS's own caches can be in use by parts of the system that can't be asked to quit.
            if rule.namedByBundleID && tree.name(id).hasPrefix("com.apple.") { continue }
            // Named like a project's environment, but it isn't one: Python itself has a folder called venv.
            if let marker = rule.marker, let path = tree.path(id), !FileManager.default.fileExists(atPath: path + "/" + marker) { continue }

            if rule.groups {
                if let at = groupIndex[n.rule] {
                    rows[at].nodes.append(id)
                    rows[at].paperBytes &+= total
                } else {
                    groupIndex[n.rule] = rows.count
                    rows.append(WinRow(id: "group:" + rule.title, title: rule.title, subtitle: "", detail: rule.detail, tier: rule.tier,
                                       nodes: [id], bytes: 0, paperBytes: total, action: .trash, command: rule.command, bundleID: rule.appBundleID))
                }
                continue
            }
            if rule.namedByBundleID && total < 100_000_000 {
                smallCaches.append(id)
                continue
            }
            if total < smallestRow { continue }
            let folder = tree.name(id)
            var title = rule.title
            var subtitle = DiskTree.friendly(parentPath(tree, id))
            var bundle = rule.appBundleID
            if rule.namedByBundleID {
                title = appName(forFolder: folder) + " cache"
                if folder.contains(".") { bundle = folder }
            } else if rule.usesFolderName {
                // A bare version number means nothing on its own.
                let isVersion = folder.first?.isNumber ?? false
                title = isVersion ? "\(rule.title) \(folder)" : folder
                subtitle = isVersion ? DiskTree.friendly(parentPath(tree, id)) : rule.title
            }
            // Some of these can't be moved without an administrator, so they're explained and not offered.
            let movable = !rule.notTrashable && tree.path(id).map(Safety.canTrash) == true
            let action: WinAction = rule.command != nil ? .command : (movable ? .trash : .info)
            rows.append(WinRow(id: tree.friendlyPath(id), title: title, subtitle: subtitle, detail: rule.detail, tier: rule.tier,
                               nodes: [id], bytes: 0, paperBytes: total, action: action, command: rule.command, bundleID: bundle))
        }

        if !smallCaches.isEmpty {
            let sum = smallCaches.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            if sum >= smallestRow {
                rows.append(WinRow(id: smallerCachesID, title: "Smaller app caches", subtitle: "", detail: "Caches from apps that each use less than 100 MB. They rebuild as you use the apps.",
                                   tier: .rebuilds, nodes: smallCaches, bytes: 0, paperBytes: sum, action: .trash, command: nil, bundleID: nil))
            }
        }

        // Groups say how many places they span.
        for at in rows.indices where rows[at].id.hasPrefix("group:") {
            let count = rows[at].nodes.count
            rows[at].subtitle = rows[at].id == smallerCachesID ? "\(count) apps" : (count == 1 ? tree.friendlyPath(rows[at].nodes[0]) : "In \(count) places")
        }

        rows = rows.filter { $0.paperBytes >= smallestRow }
        settleReclaim(&rows, tree: tree)
        addYourCalls(&rows, tree: tree, rules: rules)
        addNoLossRows(&rows, tree: tree, rules: rules, restartExtras: restartExtras, trash: trashNode)

        rows.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            return a.bytes > b.bytes
        }
        return rows.filter { $0.bytes > 0 || $0.action == .openTrash }
    }

    private static func parentPath(_ tree: DiskTree, _ id: UInt32) -> String {
        tree.path(tree.nodes[Int(id)].parent) ?? ""
    }

    /// Works out what each row would really give back. A file linked from outside the row frees nothing.
    private static func settleReclaim(_ rows: inout [WinRow], tree: DiskTree) {
        for at in rows.indices { rows[at].bytes = rows[at].paperBytes }
        guard !tree.links.isEmpty else { return }
        let rowOf = vmAlloc(UInt32.self, tree.count)
        defer { vmFree(rowOf, tree.count) }
        for (at, row) in rows.enumerated() {
            for node in row.nodes { rowOf[Int(node)] = UInt32(at + 1) }
        }
        let nodes = tree.nodes
        func containingRow(_ dir: UInt32) -> UInt32 {
            var i = dir
            while i != 0 {
                let r = rowOf[Int(i)]
                if r != 0 { return r }
                i = nodes[Int(i)].parent
            }
            return 0
        }
        let links = tree.links
        var start = 0
        while start < links.count {
            var end = start + 1
            while end < links.count && links[end].key == links[start].key { end += 1 }
            defer { start = end }
            var counted: LinkRecord?
            for i in start..<end where links[i].counted { counted = links[i] }
            guard let counted else { continue }
            let home = containingRow(counted.dir)
            guard home != 0 else { continue }
            for i in start..<end where !links[i].counted {
                if containingRow(links[i].dir) != home {
                    rows[Int(home) - 1].bytes = rows[Int(home) - 1].bytes &- min(rows[Int(home) - 1].bytes, counted.bytes)
                    break
                }
            }
        }
    }

    private static func addYourCalls(_ rows: inout [WinRow], tree: DiskTree, rules: RuleBook) {
        let nodes = tree.nodes
        let installers: Set<String> = ["dmg", "pkg", "iso", "zip", "tar", "gz", "tgz", "7z", "rar", "xz"]
        var downloads: UInt32 = 0
        if tree.home != 0 {
            var c = nodes[Int(tree.home)].firstChild
            while c != 0 {
                if tree.name(c) == "Downloads" { downloads = c; break }
                c = nodes[Int(c)].nextSibling
            }
        }
        var inDownloads: [UInt32] = []
        var old: [(UInt32, UInt64)] = []
        let cutoff = UInt32(Date().timeIntervalSince1970) &- 180 * 86_400
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            guard !n.has(NodeFlag.directory), !n.has(NodeFlag.synthetic), !n.has(NodeFlag.alias), n.rule == 0,
                  nodes[Int(n.parent)].has(NodeFlag.projects) else { continue }
            let id = UInt32(i)
            let total = tree.totals[i]
            if downloads != 0, total >= 30_000_000, tree.isInside(id, downloads) {
                let ext = (tree.name(id) as NSString).pathExtension.lowercased()
                if installers.contains(ext) { inDownloads.append(id) }
            }
            if total >= 500_000_000, n.modTime != 0, n.modTime < cutoff { old.append((id, total)) }
        }
        if !inDownloads.isEmpty {
            let sum = inDownloads.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            if sum >= smallestRow {
                rows.append(WinRow(id: "group:installers", title: "Installers and archives in Downloads", subtitle: "\(inDownloads.count) files",
                                   detail: "Disk images and archives you've downloaded. Once something is installed or unpacked, you rarely need these.",
                                   tier: .yourCall, nodes: inDownloads, bytes: sum, paperBytes: sum, action: .trash, command: nil, bundleID: nil))
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        for (id, total) in old.sorted(by: { $0.1 > $1.1 }).prefix(12) where downloads == 0 || !inDownloads.contains(id) {
            let date = Date(timeIntervalSince1970: TimeInterval(nodes[Int(id)].modTime))
            rows.append(WinRow(id: tree.friendlyPath(id), title: tree.name(id), subtitle: "Untouched since \(formatter.string(from: date))",
                               detail: "A big file nobody has changed in a long time. It's at \(tree.friendlyPath(id)).",
                               tier: .yourCall, nodes: [id], bytes: total, paperBytes: total, action: .trash, command: nil, bundleID: nil))
        }
    }

    /// macOS lists a downloaded update here. Being big isn't enough on its own to say one is waiting.
    private static func updateIsWaiting() -> Bool {
        let settings = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.SoftwareUpdate.plist")
        let updates = settings?["RecommendedUpdates"] as? [[String: Any]] ?? []
        return updates.contains { $0["MobileSoftwareUpdate"] != nil }
    }

    private static func addNoLossRows(_ rows: inout [WinRow], tree: DiskTree, rules: RuleBook, restartExtras: [UInt32], trash: UInt32?) {
        let nodes = tree.nodes
        if let trash, tree.totals[Int(trash)] > 1_000_000 {
            rows.append(WinRow(id: "trash", title: "Empty the Trash", subtitle: "Thrown away, but still using space", detail: "This space only comes back once the Trash is emptied.",
                               tier: .noLoss, nodes: [trash], bytes: tree.totals[Int(trash)], paperBytes: 0, action: .openTrash, command: nil, bundleID: nil))
        }
        var swap: UInt32 = 0, updates: UInt32 = 0
        for i in 1..<min(tree.count, 64) where nodes[i].has(NodeFlag.synthetic) {
            if nodes[i].rule == rules.swapRule { swap = UInt32(i) }
            if nodes[i].rule == rules.updatesRule { updates = UInt32(i) }
        }
        var restartNodes = restartExtras
        if swap != 0 { restartNodes.append(swap) }
        let restartBytes = restartNodes.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
        if restartBytes >= 1_000_000_000 {
            var parts: [String] = []
            if swap != 0, tree.totals[Int(swap)] >= 500_000_000 { parts.append("\(formatBytes(tree.totals[Int(swap)])) of swap") }
            let others = restartExtras.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            if others >= 500_000_000 { parts.append("\(formatBytes(others)) of temporary files") }
            rows.append(WinRow(id: "restart", title: "Restart your Mac", subtitle: parts.joined(separator: " and "),
                               detail: "Swap and temporary files reset when your Mac restarts. Swap slowly fills up again as you work.",
                               tier: .noLoss, nodes: restartNodes, bytes: restartBytes, paperBytes: 0, action: .restart, command: nil, bundleID: nil))
        }
        // A startup area well beyond its usual size means an update is sitting there, downloaded and waiting.
        if updates != 0 {
            let usual: UInt64 = 13_000_000_000
            let total = tree.totals[Int(updates)]
            if total > usual + 2_000_000_000, updateIsWaiting() {
                rows.append(WinRow(id: "update", title: "Install the waiting macOS update", subtitle: "Downloaded, and using extra space until it's installed",
                                   detail: "macOS keeps a downloaded update in its startup area. Installing it should free most of this. It's an estimate, because macOS doesn't report the exact size.",
                                   tier: .noLoss, nodes: [updates], bytes: total - usual, paperBytes: 0, action: .softwareUpdate, command: nil, bundleID: nil))
            }
        }
    }
}

// MARK: Changes

enum ChangeWindow: Hashable, Identifiable {
    case lastScan
    case days(Int)

    var id: String {
        switch self {
        case .lastScan: "last"
        case .days(let d): "\(d)"
        }
    }

    var title: String {
        switch self {
        case .lastScan: "Last scan"
        case .days(1): "24 hours"
        case .days(let d): "\(d) days"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .lastScan: 0
        case .days(let d): TimeInterval(d) * 86_400
        }
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
/// something useful on the very first day.
final class ChangeMap: @unchecked Sendable {
    private(set) var usesHistory = false
    private(set) var caption = ""
    private(set) var shortCaption = ""
    private let capacity: Int
    private let values: UnsafeMutablePointer<Int64>
    private(set) var total: Int64 = 0

    init(tree: DiskTree, window: ChangeWindow) {
        capacity = max(tree.count, 1)
        values = vmAlloc(Int64.self, capacity)
        let snapshot = History.snapshot(forVolume: tree.volumeName, olderThan: window.seconds, isLast: window == .lastScan, before: tree.finishedAt)
        let nodes = tree.nodes
        let n = tree.count
        if let snapshot {
            usesHistory = true
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
            let formatter = DateFormatter()
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            caption = "Compared with the scan from \(formatter.string(from: snapshot.date))."
            shortCaption = "since then"
            // The disk's own free space is the honest total.
            total = Int64(bitPattern: snapshot.free) &- Int64(bitPattern: tree.freeBytes)
        } else if window == .lastScan {
            caption = "There's no earlier scan to compare with yet. Come back after your next scan."
            shortCaption = ""
        } else {
            let days: Int
            if case .days(let d) = window { days = d } else { days = 30 }
            let field = days == 1 ? DiskTree.statRecent1 : (days == 7 ? DiskTree.statRecent7 : DiskTree.statRecent30)
            let cut = UInt32(Date().timeIntervalSince1970) &- UInt32(days) * 86_400
            let width = DiskTree.statStride
            for i in 0..<n {
                if nodes[i].has(NodeFlag.directory) {
                    values[i] = Int64(tree.stats[i * width + field]) << 14
                } else if !nodes[i].has(NodeFlag.synthetic), nodes[i].modTime >= cut {
                    values[i] = Int64(bitPattern: tree.totals[i])
                }
            }
            let label = window == .days(1) ? "the last 24 hours" : "the last \(days) days"
            caption = "New or changed in \(label), going by file dates. History builds up from today."
            shortCaption = "in \(label)"
        }
    }

    deinit {
        vmFree(values, capacity)
    }

    @inline(__always) func value(of node: UInt32) -> Int64 { values[Int(node)] }

    /// The folders that explain the growth. Not "your files grew", but which folder did, and no deeper than is
    /// useful: a season that grew is one row, not eight episodes.
    func rows(tree: DiskTree, rules: RuleBook) -> [ChangeRow] {
        var out: [UInt32: Int64] = [:]
        let minimum: Int64 = 100_000_000
        let nodes = tree.nodes
        let bundles = [".app", ".framework", ".bundle", ".photoslibrary", ".sparsebundle", ".xcarchive", ".fcpbundle", ".appex", ".kext", ".xcframework"]

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
                if up == 0 || up == tree.home || nodes[Int(up)].parent == 0 || nodes[Int(up)].parent == tree.home || nodes[Int(up)].has(NodeFlag.synthetic) { break }
                if Double(values[Int(up)]) > Double(values[Int(id)]) * 1.12 { break }
                at = up
            }
            out[at] = max(values[Int(at)], out[at] ?? 0)
        }
        func walk(_ id: UInt32, _ depth: Int) {
            let d = values[Int(id)]
            guard d >= minimum, !isNoise(id) else { return }
            let name = tree.name(id)
            if bundles.contains(where: { name.hasSuffix($0) }) { emit(id); return }
            var big: [UInt32] = []
            var top: Int64 = 0
            var c = nodes[Int(id)].firstChild
            while c != 0 {
                let v = values[Int(c)]
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
        var topLevel = nodes[0].firstChild
        while topLevel != 0 {
            if topLevel != tree.free && topLevel != tree.hidden { walk(topLevel, 0) }
            topLevel = nodes[Int(topLevel)].nextSibling
        }
        return out.sorted { $0.value > $1.value }.prefix(60).map { id, delta in
            let parent = nodes[Int(id)].parent
            let name = tree.name(id)
            // A name like "final" or "8.14" only makes sense next to the folder it's in.
            let generic = name.count <= 8 && nodes[Int(id)].has(NodeFlag.directory) && (name.first?.isNumber == true || name == name.lowercased())
            return ChangeRow(node: id, title: generic ? "\(tree.name(parent)) › \(name)" : name,
                             subtitle: tree.path(parent).map(DiskTree.friendly) ?? tree.name(parent), delta: delta)
        }
    }
}

// MARK: Colours per view

enum Lenses {
    static func kindColorer(tree: DiskTree) -> RingLayout.Colorer {
        let nodes = tree.nodes
        let stats = tree.displayStats
        let stride = DiskTree.statStride
        return { node in
            let n = nodes[Int(node)]
            let lab: Lab
            if n.has(NodeFlag.directory) && (n.firstChild != 0 || n.fileCount > 0) {
                lab = Palette.blend(UnsafePointer(stats + Int(node) * stride))
            } else if n.has(NodeFlag.synthetic) {
                lab = Palette.color(.system)
            } else {
                lab = Palette.color(Kind(rawValue: n.kind) ?? .other)
            }
            return lab.linearP3
        }
    }

    static func changeColorer(tree: DiskTree, changes: ChangeMap) -> RingLayout.Colorer {
        let totals = tree.totals
        return { node in
            let delta = changes.value(of: node)
            let bytes = max(totals[Int(node)], 1)
            if delta > 0 {
                let ratio = min(Float(delta) / Float(bytes), 1)
                let strength = min(ratio.squareRoot() * 1.45, 1)
                return Lab.mix(Palette.quiet, Palette.heat(0.22 + 0.78 * ratio), max(strength, 0.14)).linearP3
            }
            if delta < 0 {
                let ratio = min(Float(-delta) / Float(bytes), 1)
                return Lab.mix(Palette.quiet, Palette.cool, min(ratio.squareRoot() * 1.2, 0.9)).linearP3
            }
            return Palette.quiet.linearP3
        }
    }

    static func reclaimColorer(tree: DiskTree, map: ReclaimMap, rules: RuleBook, ticked: [UInt32]) -> RingLayout.Colorer {
        let nodes = tree.nodes
        let totals = tree.totals
        let chosen = NodeSet(ticked, in: tree)
        return { node in
            let n = nodes[Int(node)]
            // Inside something removable: its whole subtree carries the colour.
            if n.rule != 0 {
                let t = rules.rule(n.rule).tier
                if t != .none, t != .handsOff {
                    if chosen.contains(node) { return Lab(lch: 0.95, 0.15, 150).linearP3 }
                    return Palette.reclaim(t).linearP3
                }
            }
            // Above something removable: tinted by how much of it can go.
            let can = map.bytes[Int(node)]
            if can > 0 {
                let share = min(Float(can) / Float(max(totals[Int(node)], 1)), 1)
                let tier = Tier(rawValue: map.tier[Int(node)]) ?? .rebuilds
                return Lab.mix(Palette.quiet, Palette.reclaim(tier), share.squareRoot() * 0.92).linearP3
            }
            return Palette.quiet.linearP3
        }
    }
}

// MARK: Search

enum Search {
    /// Every folder and named file whose name contains the text, biggest first. Bytes are compared directly, with no
    /// String made per node, so it keeps up with typing on hundreds of thousands of names.
    static func run(_ query: String, in tree: DiskTree) -> [UInt32] {
        let needle = Array(query.utf8)
        guard let first = needle.first else { return [] }
        let upperFirst = (first >= 0x61 && first <= 0x7A) ? first - 0x20 : first
        let nodes = tree.nodes, names = tree.names
        var found: [UInt32] = []
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            let length = Int(n.nameLength)
            if length < needle.count || n.has(NodeFlag.anchor) || n.has(NodeFlag.synthetic) { continue }
            let p = names + Int(n.nameOffset)
            var at = 0
            let last = length - needle.count
            scanning: while at <= last {
                let c = p[at]
                if c == first || c == upperFirst {
                    var j = 1
                    while j < needle.count {
                        var x = p[at + j]
                        if x >= 0x41 && x <= 0x5A { x |= 0x20 }
                        if x != needle[j] { break }
                        j += 1
                    }
                    if j == needle.count {
                        found.append(UInt32(i))
                        break scanning
                    }
                }
                at += 1
            }
        }
        found.sort { tree.totals[Int($0)] > tree.totals[Int($1)] }
        return found
    }
}
