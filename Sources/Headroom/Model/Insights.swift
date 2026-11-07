import AppKit
import Foundation
import simd

// MARK: Free Up

enum WinAction: Equatable {
    case trash              // can be ticked and moved to the Trash
    case restart            // a restart clears it
    case softwareUpdate     // installing a waiting update clears it
    case emptyTrash         // it's in the Trash already: it goes when you empty it
    case uninstall          // an app, with the files that belong to it
    case openApp            // only this app can manage it safely
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
    /// Part of the one click: safe to take without a second thought.
    var isQuick = false
    /// Why the slider leaves this alone, even though it could come back. It's still there to tick.
    var inUse: String? = nil
    /// Other places that hold the same files. Nothing comes back until those go too.
    var otherCopies: [UInt32] = []
    var otherCopiesTitle: String? = nil
    var otherCopiesNote: String? = nil
    /// What's worth knowing again at the last look, if that copy is planned too.
    var otherCopiesCaution: String? = nil
    var otherCopiesPath: String? = nil
    /// The other copy is a torrent's, which you'd want gone with this unless it may still be sharing.
    var otherCopiesIsTorrent = false
    /// For an app: where it is, for its icon.
    var appPath: String? = nil
    /// Things that make up this row, each one its own decision.
    var parts: [WinRow] = []
    /// A file or folder you might like to see for yourself.
    var previewPath: String? = nil
    var stepAfterPlanning: PlanStep = .trash
    /// Paths that go with it, too small to be on the map.
    var extraPaths: [String] = []
    /// What you can choose to add, such as an app's data. It's never chosen for you.
    var alsoNodes: [UInt32] = []
    var alsoTitle: String? = nil
    var alsoNote: String? = nil
    var openAppName: String? = nil
    /// It could come back, but it may cost you more than a download, so only a tick of your own takes it.
    var askFirst = false

    var isPlannable: Bool { action == .trash || action == .uninstall || action == .emptyTrash }
    /// What this could give back, counting another copy of the same files if there is one.
    var gain: UInt64 { otherCopies.isEmpty ? bytes : paperBytes }
    /// What a tick on this really gives back. A torrent's copy goes with it, unless it may still be sharing. Any other copy stays.
    var aTickFrees: UInt64 { otherCopiesIsTorrent && otherCopiesCaution == nil ? gain : bytes }
    var step: PlanStep {
        switch action {
        case .uninstall: .uninstall
        case .emptyTrash: .emptyTrash
        default: stepAfterPlanning
        }
    }
}

/// Which suggestion each folder and file belongs to, so the ring can wear the same colours as the list. It stays the same until
/// the suggestions change. A suggestion's whole subtree is its own, unless a smaller one lies inside it.
final class ReclaimMap: @unchecked Sendable {
    let rowIDs: [String]
    private let owner: UnsafeMutablePointer<UInt32>
    private let capacity: Int

    init(tree: DiskTree, rows: [WinRow]) {
        capacity = max(tree.count, 1)
        owner = vmAlloc(UInt32.self, capacity)
        rowIDs = rows.map(\.id)
        for (at, row) in rows.enumerated() {
            for node in row.nodes where Int(node) < capacity { owner[Int(node)] = UInt32(at + 1) }
        }
        let nodes = tree.nodes
        if tree.count > 1 {
            for i in 1..<tree.count where owner[i] == 0 { owner[i] = owner[Int(nodes[i].parent)] }
        }
    }

    deinit {
        vmFree(owner, capacity)
    }

    /// During a scan this map can be one picture behind, so a folder found since then has nothing to say yet.
    @inline(__always) func rowIndex(of node: UInt32) -> Int? {
        guard Int(node) < capacity, owner[Int(node)] != 0 else { return nil }
        return Int(owner[Int(node)]) - 1
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

    /// How a running app shows up in `running`, next to its bundle ID, for a cache folder named after the app itself.
    static func runningKey(name: String) -> String { "name:" + String(name.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// Whether the app behind a cache folder is open. The folder is named for the app's ID, sometimes with a helper's ending
    /// (`.ShipIt`), or for the app itself.
    static func isOpen(folder: String, running: Set<String>) -> Bool {
        if running.contains(folder) || running.contains(runningKey(name: folder)) { return true }
        return running.contains { folder.hasPrefix($0 + ".") }
    }

    /// Caches that belong to macOS's own services, though nothing in their names says so. Like `com.apple.*`, they can be in use
    /// by parts of the system that can't be asked to quit, and some can't be moved at all.
    private static let macOSCaches: Set<String> = ["Animoji", "CloudKit", "FamilyCircle", "familycircled", "GameKit", "GameStoreKit", "GeoServices", "Maps", "Metadata", "PassKit", "reviewtrace", "SiriEntityCache"]

    /// Whether what it's rebuilt from is there.
    static func hasRecipe(in folder: String, _ recipe: [String]) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.contains { name in
            recipe.contains { $0.hasSuffix("*") ? name.hasPrefix($0.dropLast()) : name == $0 }
        }
    }

    static func build(tree: DiskTree, rules: RuleBook, running: Set<String> = [], facts: Facts = .none, recipeFound: (String, [String]) -> Bool = Wins.hasRecipe) -> [WinRow] {
        let nodes = tree.nodes
        var rows: [WinRow] = []
        var groupIndex: [UInt32: Int] = [:]
        var smallCaches: [UInt32] = []
        var restartExtras: [UInt32] = []
        var trashNode: UInt32?

        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            guard n.has(NodeFlag.ruleRoot), n.rule != 0, !n.has(NodeFlag.gone) else { continue }
            let id = UInt32(i)
            let total = tree.totals[i]
            guard total > 0 else { continue }
            let rule = rules.rule(n.rule)
            guard rule.tier != .none, rule.tier != .handsOff, !rule.thingByThing else { continue }
            if rule.restartClears { restartExtras.append(id); continue }
            if rule.title == "Trash" { trashNode = id; continue }
            // macOS's own caches can be in use by parts of the system that can't be asked to quit.
            if rule.namedByBundleID && (tree.name(id).hasPrefix("com.apple.") || macOSCaches.contains(tree.name(id))) { continue }
            // Named like a project's environment, but it isn't one: Python itself has a folder called venv.
            if let marker = rule.marker, let path = tree.path(id), !FileManager.default.fileExists(atPath: path + "/" + marker) { continue }

            if rule.groups {
                // Clearing build output costs you a rebuild, so projects you're working on aren't part of the one click.
                let project = nodes[i].parent
                let active = tree.statRow(project)[DiskTree.statRecent14] > 0
                // Nothing to rebuild it from means it doesn't rebuild itself, whatever it's called.
                let noRecipe = rule.recipe.map { !recipeFound(parentPath(tree, id), $0) } ?? false
                let key = UInt32(n.rule) << 2 | (noRecipe ? 2 : (active ? 1 : 0))
                if let at = groupIndex[key] {
                    rows[at].nodes.append(id)
                    rows[at].paperBytes &+= total
                } else {
                    groupIndex[key] = rows.count
                    var row = WinRow(id: "group:" + rule.title + (noRecipe ? ":no-recipe" : (active ? ":active" : "")), title: rule.title, subtitle: "",
                                     detail: noRecipe ? "Nothing next to these says what's in them, so you'd have to work out what to install again." : rule.detail,
                                     tier: noRecipe ? .yourCall : rule.tier, nodes: [id], bytes: 0, paperBytes: total, action: .trash, command: noRecipe ? nil : rule.command, bundleID: rule.appBundleID)
                    row.isQuick = !active && !noRecipe
                    row.inUse = active && !noRecipe ? "Changed in the last two weeks" : nil
                    rows.append(row)
                }
                continue
            }
            if rule.namedByBundleID && total < 100_000_000 {
                // Only what can be tied to an app, while that app is closed. A bare name could be part of anything, and these are
                // too small to be worth finding out.
                if tree.name(id).contains("."), !isOpen(folder: tree.name(id), running: running) { smallCaches.append(id) }
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
            let action: WinAction = rule.commandOnly ? .command : (movable ? .trash : .info)
            var row = WinRow(id: tree.friendlyPath(id), title: title, subtitle: subtitle, detail: rule.detail, tier: rule.tier,
                             nodes: [id], bytes: 0, paperBytes: total, action: action, command: rule.command, bundleID: bundle)
            row.askFirst = rule.askFirst
            if rule.tier == .rebuilds, action == .trash {
                if rule.namedByBundleID || bundle != nil {
                    // An app's cache is safe to clear unless the app is open right now.
                    if let bundle, running.contains(bundle) {
                        row.inUse = "\(appName(forFolder: bundle)) is open"
                    } else if rule.namedByBundleID, isOpen(folder: folder, running: running) {
                        row.inUse = "\(appName(forFolder: folder)) is open"
                    } else {
                        row.isQuick = true
                    }
                } else if let known = rule.knownNames, !known.contains(folder) {
                    // Kept where caches go, but nothing says what's in it or how it comes back. It's not for the one click or the slider.
                    row.tier = .redownload
                    row.askFirst = true
                    row.detail = "This is in the folder where tools keep their caches, but Headroom doesn't know this one. It may be more than a cache: a model, or something that took time to set up."
                } else if tree.statRow(i)[DiskTree.statRecent14] > 0 {
                    // A tool's cache costs a download or a slower build next time, so one you're using isn't part of the one click.
                    row.inUse = "Used in the last two weeks"
                } else {
                    row.isQuick = true
                }
            }
            rows.append(row)
        }

        if !smallCaches.isEmpty {
            let sum = smallCaches.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            if sum >= smallestRow {
                var row = WinRow(id: smallerCachesID, title: "Smaller app caches", subtitle: "", detail: "Caches from apps that each use less than 100 MB. They rebuild as you use the apps.",
                                 tier: .rebuilds, nodes: smallCaches, bytes: 0, paperBytes: sum, action: .trash, command: nil, bundleID: nil)
                row.isQuick = true
                rows.append(row)
            }
        }

        // Groups say how many places they span.
        for at in rows.indices where rows[at].id.hasPrefix("group:") {
            let count = rows[at].nodes.count
            rows[at].subtitle = rows[at].id == smallerCachesID ? "\(count) apps" : (count == 1 ? tree.friendlyPath(rows[at].nodes[0]) : "In \(count) places")
            if rows[at].id.hasSuffix(":no-recipe") { rows[at].subtitle += ". Nothing says what's in \(count == 1 ? "this folder" : "these folders")." }
        }

        // On any other disk the Trash is a folder at the top of the disk.
        if trashNode == nil, tree.home == 0 {
            for top in tree.children(0) where tree.nodes[Int(top)].has(NodeFlag.anchor) {
                for child in tree.children(top) where tree.name(child) == ".Trashes" { trashNode = child }
            }
        }
        rows = rows.filter { $0.paperBytes >= smallestRow }
        settleReclaim(&rows, tree: tree)
        addYourCalls(&rows, tree: tree, rules: rules)
        addNoLossRows(&rows, tree: tree, rules: rules, restartExtras: restartExtras, trash: trashNode)
        Advisors.add(to: &rows, tree: tree, rules: rules, facts: facts)

        rows.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            return a.gain > b.gain
        }
        return rows.filter { $0.gain > 0 || $0.action == .emptyTrash }
    }

    private static func parentPath(_ tree: DiskTree, _ id: UInt32) -> String {
        tree.path(tree.nodes[Int(id)].parent) ?? ""
    }

    /// Works out what each row would really give back. A file linked from outside the row frees nothing.
    static func settleReclaim(_ rows: inout [WinRow], tree: DiskTree) {
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
            // A big file has its own node, which can be a row's node by itself.
            func rowHolding(_ record: LinkRecord) -> UInt32 {
                if record.file != 0, rowOf[Int(record.file)] != 0 { return rowOf[Int(record.file)] }
                return containingRow(record.dir)
            }
            let home = rowHolding(counted)
            guard home != 0 else { continue }
            for i in start..<end where !links[i].counted {
                if rowHolding(links[i]) != home {
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
            guard !n.has(NodeFlag.directory), !n.has(NodeFlag.synthetic), !n.has(NodeFlag.alias), !n.has(NodeFlag.gone), n.rule == 0,
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
            var row = WinRow(id: "trash", title: "Already in the Trash", subtitle: "Thrown away, but still using space", detail: "This space only comes back once the Trash is emptied, and emptying it is always your last step.",
                             tier: .noLoss, nodes: [trash], bytes: Accounting.reclaimable([trash], in: tree), paperBytes: 0, action: .emptyTrash, command: nil, bundleID: nil)
            row.isQuick = true
            rows.append(row)
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
                rows.append(WinRow(id: "update", title: "Install the waiting macOS update", subtitle: "Downloaded, and using extra space until installed",
                                   detail: "macOS keeps a downloaded update in its startup area. Installing it should free most of this. That figure is an estimate, because macOS doesn't report the exact size.",
                                   tier: .noLoss, nodes: [updates], bytes: total - usual, paperBytes: 0, action: .softwareUpdate, command: nil, bundleID: nil))
            }
        }
    }
}

// MARK: Changes

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
        let snapshot = tree.isPartial ? nil : History.snapshot(forVolume: tree.volumeName, olderThan: window.seconds, isLast: window == .lastScan, before: tree.finishedAt)
        let nodes = tree.nodes
        let n = tree.count
        if let snapshot {
            compare(tree, with: snapshot)
        } else if window == .lastScan {
            caption = tree.isPartial ? "This can compare once the scan has finished."
                : "There's no earlier scan to compare with yet. Come back after your next scan."
            shortCaption = ""
        } else {
            let days: Int
            if case .days(let d) = window { days = d } else { days = 30 }
            let field = days == 1 ? DiskTree.statRecent1 : (days == 7 ? DiskTree.statRecent7 : DiskTree.statRecent30)
            let cut = UInt32(Date().timeIntervalSince1970) &- UInt32(days) * 86_400
            for i in 0..<n {
                if nodes[i].has(NodeFlag.directory) {
                    // Left alone where nothing changed, so that part of the table never takes up memory.
                    let units = tree.statRow(i)[field]
                    if units != 0 { values[i] = Int64(units) << 14 }
                } else if !nodes[i].has(NodeFlag.synthetic), nodes[i].modTime >= cut {
                    values[i] = Int64(bitPattern: tree.totals[i])
                }
            }
            let label = window == .days(1) ? "the last 24 hours" : "the last \(days) days"
            caption = "New or changed in \(label), going by file dates." + (tree.isPartial ? " Still reading, so this may grow." : " History builds up from today.")
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
        let cut = UInt32(Date().timeIntervalSince1970) &- UInt32(days) * 86_400
        for i in 0..<n {
            let total = tree.totals[i]
            if nodes[i].has(NodeFlag.directory) {
                let recent = UInt64(tree.statRow(i)[field]) << 14
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
        return paths.compactMap { tree.find(path: $0) ?? (tree.find(path: "/System/Volumes/Data" + $0)) }
    }

    /// During a scan this map can be one picture behind, so a folder found since then has nothing to say yet.
    @inline(__always) func value(of node: UInt32) -> Int64 { Int(node) < capacity ? values[Int(node)] : 0 }

    /// The folders that explain the growth. Not "your files grew", but which folder did, and no deeper than is
    /// useful: a season that grew is one row, not eight episodes. It follows what grew, not what each folder came to in
    /// the end, so growth inside a folder that shrank overall is still found.
    /// With `shrinking`, the same for what got smaller, with negative deltas.
    func rows(tree: DiskTree, rules: RuleBook, shrinking: Bool = false) -> [ChangeRow] {
        let sign: Int64 = shrinking ? -1 : 1
        @inline(__always) func changed(_ id: UInt32) -> Int64 { amount(id, shrinking: shrinking) }
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
            let name = tree.name(id)
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
                             subtitle: tree.path(parent).map(DiskTree.friendly) ?? tree.name(parent), delta: sign * delta)
        }
    }
}

// MARK: Colours per view

enum Lenses {
    static func kindColorer(tree: DiskTree) -> RingLayout.Colorer {
        let nodes = tree.nodes
        return { node in
            let n = nodes[Int(node)]
            let lab: Lab
            if n.has(NodeFlag.directory) && (n.firstChild != 0 || n.fileCount > 0) {
                lab = Palette.blend(tree.statRow(node))
            } else if n.has(NodeFlag.synthetic) {
                lab = Palette.color(.system)
            } else {
                lab = Palette.color(Kind(rawValue: n.kind) ?? .other)
            }
            return lab.linearP3
        }
    }

    /// In Changes each piece wears how much of it is new or changed, from deep red for a little to yellow for all of it.
    /// What didn't change stays quiet, and what shrank turns blue.
    static func changeColorer(tree: DiskTree, changes: ChangeMap) -> RingLayout.Colorer {
        let totals = tree.totals
        if changes.isUntouched {
            return { node in untouchedLab(untouched: UInt64(max(changes.value(of: node), 0)), bytes: totals[Int(node)]).linearP3 }
        }
        return { node in changeLab(delta: changes.value(of: node), bytes: totals[Int(node)]).linearP3 }
    }

    /// `delta` is what's new or changed in a piece of `bytes`. A file counts as wholly changed once its date is in the window,
    /// because which bytes inside it changed could only be found by reading it.
    static func changeLab(delta: Int64, bytes: UInt64) -> Lab {
        if delta > 0 {
            let share = min(Float(Double(delta) / Double(max(bytes, 1))), 1)
            // Below one percent it fades toward quiet, so a big folder with a few new files doesn't glow.
            return Lab.mix(Palette.quiet, Palette.heat(share), min(share / 0.01, 1))
        }
        if delta < 0 {
            let lost = Double(-delta)
            let share = Float(lost / (Double(bytes) + lost))
            return Lab.mix(Palette.quiet, Palette.cool, min(share.squareRoot() * 1.2, 0.9))
        }
        return Palette.quiet
    }

    /// Looking back instead: how much of each piece hasn't changed in the window, from slate for a little to ice for all of it.
    static func untouchedLab(untouched: UInt64, bytes: UInt64) -> Lab {
        guard untouched > 0 else { return Palette.quiet }
        let share = min(Float(Double(untouched) / Double(max(bytes, 1))), 1)
        return Lab.mix(Palette.quiet, Palette.frost(share), min(share / 0.01, 1))
    }

    /// Each thing wears its box's colour. What isn't part of the question stays quiet.
    static func reclaimColorer(map: ReclaimMap, colours: [SIMD3<Float>?], planned: @escaping RingLayout.Planner) -> RingLayout.Colorer {
        let hand = Palette.Box.hand.linearP3
        let quiet = Palette.quiet.linearP3
        return { node in
            if let at = map.rowIndex(of: node), at < colours.count, let colour = colours[at] { return colour }
            if planned(node) { return hand }
            return quiet
        }
    }
}

// MARK: Search

enum Search {
    /// Every folder and named file whose name contains the text, biggest first. Capitals don't matter, for any alphabet.
    static func run(_ query: String, in tree: DiskTree) -> [UInt32] {
        let wanted = fold(query)
        let needle = Array(wanted.utf8)
        guard let first = needle.first else { return [] }
        let upperFirst = (first >= 0x61 && first <= 0x7A) ? first - 0x20 : first
        let isPlain = needle.allSatisfy { $0 < 0x80 }
        let nodes = tree.nodes, names = tree.names
        var found: [UInt32] = []
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            if n.has(NodeFlag.anchor) || n.has(NodeFlag.synthetic) { continue }
            let p = UnsafePointer(names + Int(n.nameOffset))
            let length = Int(n.nameLength)
            let holds = isPlain ? holdsPlain(needle, first: first, upperFirst: upperFirst, in: p, length: length) : holdsWide(wanted, in: p, length: length)
            if holds { found.append(UInt32(i)) }
        }
        found.sort { tree.totals[Int($0)] > tree.totals[Int($1)] }
        return found
    }

    /// A to Z compare directly as bytes, with no String made per node, so it keeps up with typing on hundreds of thousands of names.
    @inline(__always)
    private static func holdsPlain(_ needle: [UInt8], first: UInt8, upperFirst: UInt8, in p: UnsafePointer<UInt8>, length: Int) -> Bool {
        var at = 0
        let last = length - needle.count
        while at <= last {
            let c = p[at]
            if c == first || c == upperFirst {
                var j = 1
                while j < needle.count {
                    var x = p[at + j]
                    if x >= 0x41 && x <= 0x5A { x |= 0x20 }
                    if x != needle[j] { break }
                    j += 1
                }
                if j == needle.count { return true }
            }
            at += 1
        }
        return false
    }

    /// Any other letter needs the text itself: Ø and ø have no simple rule in bytes, and å can be stored as one character or as
    /// an a followed by its ring. Only a name with such a letter in it can match, and those are few, so the rest cost one look.
    private static func holdsWide(_ wanted: String, in p: UnsafePointer<UInt8>, length: Int) -> Bool {
        var at = 0
        while at < length, p[at] < 0x80 { at += 1 }
        guard at < length else { return false }
        return fold(String(decoding: UnsafeBufferPointer(start: p, count: length), as: UTF8.self)).contains(wanted)
    }

    private static func fold(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
}
