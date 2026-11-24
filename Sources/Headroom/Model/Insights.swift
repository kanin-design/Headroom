import AppKit
import Foundation

// MARK: Free Up

enum WinAction: Equatable {
    case trash  // can be ticked and moved to the Trash
    case restart  // a restart clears it
    case softwareUpdate  // installing a waiting update clears it
    case emptyTrash  // it's in the Trash already: it goes when you empty it
    case uninstall  // an app, with the files that belong to it
    case openApp  // only this app can manage it safely
    case command  // better done by its own tool
    case info  // only explained: macOS looks after it
}

struct WinRow: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var detail: String
    var tier: Tier
    var nodes: [UInt32]
    var bytes: UInt64  // what you'd really get back
    var paperBytes: UInt64  // what it adds up to, when that's more
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
    /// Where it's listed in Free Up.
    var box: BoxKind = .other
    /// One row for many folders of the same kind, wherever they are. Its second line says how many, and what of.
    var counts: String? = nil
    /// Nothing to rebuild these from was found next to them.
    var lacksRecipe = false
    /// Versions of the same tools, which are grouped when there are several.
    var family: RuleFamily? = nil
    /// When it arrived on this Mac, when that's known.
    var arrived: Date? = nil

    /// What Select recommended takes: safe without a second thought, and not in use right now.
    var isRecommended: Bool { isQuick && inUse == nil && isPlannable }

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

/// A yes or no about the disk, good for a couple of minutes. What could go is worked out again every few seconds during a
/// scan and after everything that moves, and asks the same things of the same hundreds of folders each time.
enum JustLooked {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: (answer: Bool, at: Date)] = [:]
    static let goodFor: TimeInterval = 120

    static func answer(_ question: String, now: Date = Date(), _ look: () -> Bool) -> Bool {
        lock.lock()
        let found = known[question]
        lock.unlock()
        if let found, now >= found.at, now.timeIntervalSince(found.at) < goodFor { return found.answer }
        let answer = look()
        lock.lock()
        if known.count > 20_000 { known.removeAll() }
        known[question] = (answer, now)
        lock.unlock()
        return answer
    }
}

/// The names in a few folders, listed once and kept for as long as `JustLooked` keeps an answer.
enum JustListed {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [[String]: (names: [String], at: Date)] = [:]

    static func names(in folders: [String], now: Date = Date()) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let found = known[folders], now >= found.at, now.timeIntervalSince(found.at) < JustLooked.goodFor { return found.names }
        let names = folders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        known[folders] = (names, now)
        return names
    }
}

enum Wins {
    private static let smallestRow: UInt64 = 50_000_000
    /// Junk shows from this little: clearing it is about tidying as much as space.
    private static let smallestJunk: UInt64 = 1_000_000
    /// A download that hasn't moved for this long isn't going to finish.
    private static let unfinishedAfterDays: UInt32 = 7
    private static let unfinishedEndings: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
    static let smallerCachesID = "group:smaller-caches"

    static func appName(forFolder name: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            return Titles.withoutAppEnding(FileManager.default.displayName(atPath: url.path))
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
    private static let macOSCaches: Set<String> = [
        "Animoji", "CloudKit", "FamilyCircle", "familycircled", "GameKit", "GameStoreKit", "GeoServices", "Maps", "Metadata", "PassKit",
        "reviewtrace", "SiriEntityCache",
    ]

    /// Whether what it's rebuilt from is there, as last looked.
    private static func hasRecipe(in folder: String, _ recipe: [String]) -> Bool {
        JustLooked.answer(folder + "\n" + recipe.joined(separator: "\n")) { recipeIsThere(in: folder, recipe) }
    }

    /// The same, looked at now.
    static func recipeIsThere(in folder: String, _ recipe: [String]) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.contains { name in
            recipe.contains { $0.hasSuffix("*") ? name.hasPrefix($0.dropLast()) : name == $0 }
        }
    }

    static func build(
        tree: DiskTree, rules: RuleBook, running: Set<String> = [], facts: Facts = .none, recipeFound: (String, [String]) -> Bool = Wins.hasRecipe
    ) -> [WinRow] {
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
            if rule.box == .trash { trashNode = id; continue }
            // macOS's own caches can be in use by parts of the system that can't be asked to quit.
            if rule.namedByBundleID && (tree.rawName(id).hasPrefix("com.apple.") || macOSCaches.contains(tree.rawName(id))) { continue }
            // Named like a project's environment, but it isn't one: Python itself has a folder called venv.
            if let marker = rule.marker, let path = tree.path(id),
                !JustLooked.answer(path + "/" + marker, { FileManager.default.fileExists(atPath: path + "/" + marker) })
            {
                continue
            }

            if rule.box == .junk {
                if let row = junkRow(id, rule, in: tree) { rows.append(row) }
                continue
            }
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
                    rows.append(groupRow(id, rule, total: total, active: active, noRecipe: noRecipe))
                }
                continue
            }
            if rule.namedByBundleID && total < 100_000_000 {
                // Only what can be tied to an app, while that app is closed. A bare name could be part of anything, and these are
                // too small to be worth finding out.
                if tree.rawName(id).contains("."), !isOpen(folder: tree.rawName(id), running: running) { smallCaches.append(id) }
                continue
            }
            if total < smallestRow { continue }
            rows.append(ownRow(id, rule, total: total, in: tree, running: running))
        }

        if let row = smallerCachesRow(smallCaches, in: tree) { rows.append(row) }

        // Groups say how many places they span.
        for at in rows.indices {
            guard let what = rows[at].counts else { continue }
            let count = rows[at].nodes.count
            // One folder is better named than counted. Apps are always counted: their caches all sit in the same place.
            rows[at].subtitle = count == 1 && what == "folders" ? tree.friendlyPath(rows[at].nodes[0]) : "\(count) \(what)"
            if rows[at].lacksRecipe { rows[at].subtitle += " · No manifest" }
        }

        // On any other disk the Trash is a folder at the top of the disk.
        if trashNode == nil, !tree.isBoot {
            for top in tree.children(0) where tree.nodes[Int(top)].has(NodeFlag.anchor) {
                for child in tree.children(top) where tree.rawName(child) == ".Trashes" { trashNode = child }
            }
        }
        // Junk is worth listing however little there is of it.
        rows = rows.filter { $0.paperBytes >= smallestRow || $0.box == .junk || $0.box == .trash }
        settleReclaim(&rows, tree: tree)
        addYourCalls(&rows, tree: tree)
        addNoLossRows(&rows, tree: tree, rules: rules, restartExtras: restartExtras, trash: trashNode)
        Advisors.add(to: &rows, tree: tree, rules: rules, facts: facts)

        rows.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            return a.gain > b.gain
        }
        return rows.filter { $0.gain > 0 || $0.action == .emptyTrash }
    }

    // MARK: The rows a rule makes

    /// What's in a junk folder goes. The folder itself stays, since apps expect it.
    private static func junkRow(_ id: UInt32, _ rule: Rule, in tree: DiskTree) -> WinRow? {
        let inside = tree.children(id).filter { !tree.nodes[Int($0)].has(NodeFlag.gone) && tree.path($0).map(Safety.canTrash) == true }
        let sum = inside.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
        guard sum >= smallestJunk else { return nil }
        var row = WinRow(
            id: tree.friendlyPath(id), title: rule.title, subtitle: DiskTree.friendly(parentPath(tree, id)), detail: rule.detail, tier: rule.tier,
            nodes: inside, bytes: 0, paperBytes: sum, action: .trash, command: nil, bundleID: nil)
        row.isQuick = true
        row.box = .junk
        return row
    }

    /// The first of many folders of one kind, wherever they are: every node_modules that can be rebuilt, say. The ones in
    /// projects you're working on, and the ones with nothing to rebuild them from, are rows of their own.
    private static func groupRow(_ id: UInt32, _ rule: Rule, total: UInt64, active: Bool, noRecipe: Bool) -> WinRow {
        var row = WinRow(
            id: "group:" + rule.title + (noRecipe ? ":no-recipe" : (active ? ":active" : "")), title: rule.title, subtitle: "",
            detail: noRecipe ? "No manifest next to these, so it's unclear what to reinstall." : rule.detail,
            tier: noRecipe ? .yourCall : rule.tier, nodes: [id], bytes: 0, paperBytes: total, action: .trash, command: noRecipe ? nil : rule.command,
            bundleID: rule.appBundleID)
        row.isQuick = !active && !noRecipe
        row.counts = "folders"
        row.lacksRecipe = noRecipe
        row.inUse = active && !noRecipe ? "Changed in the last 2 weeks" : nil
        row.box = rule.box
        return row
    }

    /// One folder a rule is about: a cache, a tool's downloads, a set of models.
    private static func ownRow(_ id: UInt32, _ rule: Rule, total: UInt64, in tree: DiskTree, running: Set<String>) -> WinRow {
        // What it's called on the disk decides what it is. What it's called on screen, which may be made up, is all
        // that's ever shown.
        let folder = tree.rawName(id), shown = tree.name(id)
        var title = rule.title
        var subtitle = DiskTree.friendly(parentPath(tree, id))
        var bundle = rule.appBundleID
        if rule.namedByBundleID {
            title = appName(forFolder: shown) + " cache"
            if folder.contains(".") { bundle = folder }
        } else if rule.usesFolderName {
            // A bare version number means nothing on its own.
            let isVersion = folder.first?.isNumber ?? false
            title = isVersion ? "\(rule.title) \(shown)" : shown
            subtitle = isVersion ? DiskTree.friendly(parentPath(tree, id)) : rule.title
        }
        // Some of these can't be moved without an administrator, so they're explained and not offered.
        let movable = !rule.notTrashable && tree.path(id).map(Safety.canTrash) == true
        let action: WinAction = rule.commandOnly ? .command : (movable ? .trash : .info)
        var row = WinRow(
            id: tree.friendlyPath(id), title: title, subtitle: subtitle, detail: rule.detail, tier: rule.tier,
            nodes: [id], bytes: 0, paperBytes: total, action: action, command: rule.command, bundleID: bundle)
        row.askFirst = rule.askFirst
        row.box = rule.box
        row.family = rule.family
        if rule.tier == .rebuilds, action == .trash {
            if rule.namedByBundleID || bundle != nil {
                // An app's cache is safe to clear unless the app is open right now.
                if let bundle, running.contains(bundle) {
                    row.inUse = "\(appName(forFolder: bundle)) is open"
                } else if rule.namedByBundleID, isOpen(folder: folder, running: running) {
                    row.inUse = "\(appName(forFolder: shown)) is open"
                } else {
                    row.isQuick = true
                }
            } else if let known = rule.knownNames, !known.contains(folder) {
                // Kept where caches go, but nothing says what's in it or how it comes back. It's not for the one click or the slider.
                row.tier = .redownload
                row.askFirst = true
                row.detail = "Unknown tool. It may hold more than a cache, such as a model."
            } else if tree.statRow(id)[DiskTree.statRecent14] > 0 {
                // A tool's cache costs a download or a slower build next time, so one you're using isn't part of the one click.
                row.inUse = "Used in the last 2 weeks"
            } else {
                row.isQuick = true
            }
        }
        return row
    }

    /// App caches too small to list one by one, as one row.
    private static func smallerCachesRow(_ caches: [UInt32], in tree: DiskTree) -> WinRow? {
        let sum = caches.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
        guard !caches.isEmpty, sum >= smallestRow else { return nil }
        var row = WinRow(
            id: smallerCachesID, title: "Smaller app caches", subtitle: "", detail: "App caches under 100 MB each. Rebuilt as you use the apps.",
            tier: .rebuilds, nodes: caches, bytes: 0, paperBytes: sum, action: .trash, command: nil, bundleID: nil)
        row.isQuick = true
        row.counts = "apps"
        row.box = .caches
        return row
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

    /// Downloads that stopped halfway and were left: a browser's part-file that hasn't changed in a week.
    private static func addYourCalls(_ rows: inout [WinRow], tree: DiskTree, now: Date = Date()) {
        let nodes = tree.nodes
        guard tree.home != 0, let downloads = tree.child(of: tree.home, named: "Downloads") else { return }
        let cutoff = UInt32(seconds: now.timeIntervalSince1970) &- unfinishedAfterDays * 86_400
        var unfinished: [UInt32] = []
        // Browsers leave them at the top of Downloads, or one folder down. Safari's is a folder that ends in .download.
        func look(in folder: UInt32, deeper: Bool) {
            for child in tree.children(folder) {
                let n = nodes[Int(child)]
                guard n.flags & (NodeFlag.synthetic | NodeFlag.alias | NodeFlag.gone) == 0, n.rule == 0 else { continue }
                let ending = (tree.rawName(child) as NSString).pathExtension.lowercased()
                if unfinishedEndings.contains(ending) {
                    if n.modTime != 0, n.modTime < cutoff, tree.path(child).map(Safety.canTrash) == true { unfinished.append(child) }
                } else if deeper, n.has(NodeFlag.directory) {
                    look(in: child, deeper: false)
                }
            }
        }
        look(in: downloads, deeper: true)
        let sum = unfinished.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
        guard sum >= smallestJunk else { return }
        var row = WinRow(
            id: "junk:unfinished", title: "Unfinished downloads",
            subtitle: unfinished.count == 1 ? tree.name(unfinished[0]) : "\(unfinished.count) files",
            detail: "Downloads that stopped and were left for over a week.", tier: .noLoss, nodes: unfinished, bytes: sum, paperBytes: sum,
            action: .trash, command: nil, bundleID: nil)
        row.isQuick = true
        row.box = .junk
        rows.append(row)
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
            let items = Int(tree.totalFiles[Int(trash)])
            var row = WinRow(
                id: PlanItem.trashID, title: "Trash", subtitle: items == 1 ? "1 item" : "\(items.formatted()) items",
                detail: "Freed when the Trash is emptied, always the last step.",
                tier: .noLoss, nodes: [trash], bytes: Accounting.reclaimable([trash], in: tree), paperBytes: 0, action: .emptyTrash, command: nil,
                bundleID: nil)
            row.isQuick = true
            row.box = .trash
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
            if swap != 0, tree.totals[Int(swap)] >= 500_000_000 { parts.append("\(formatBytes(tree.totals[Int(swap)])) swap") }
            let others = restartExtras.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            if others >= 500_000_000 { parts.append("\(formatBytes(others)) temporary files") }
            rows.append(
                WinRow(
                    id: "restart", title: "Restart your Mac", subtitle: parts.joined(separator: " · "),
                    detail: "A restart clears swap and temporary files. Swap grows again as you work.",
                    tier: .noLoss, nodes: restartNodes, bytes: restartBytes, paperBytes: 0, action: .restart, command: nil, bundleID: nil))
        }
        // A startup area well beyond its usual size means an update is sitting there, downloaded and waiting.
        if updates != 0 {
            let usual: UInt64 = 13_000_000_000
            let total = tree.totals[Int(updates)]
            if total > usual + 2_000_000_000, updateIsWaiting() {
                rows.append(
                    WinRow(
                        id: "update", title: "Install macOS update", subtitle: "Downloaded, waiting to install",
                        detail: "A downloaded update waits on the startup volumes. Installing it frees most of this. The size is an estimate.",
                        tier: .noLoss, nodes: [updates], bytes: total - usual, paperBytes: 0, action: .softwareUpdate, command: nil, bundleID: nil))
            }
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
}
