import AppKit
import Foundation

/// What became of one thing an agent asked to select or deselect.
enum AgentSelection: Equatable {
    case selected
    case deselected
    /// It already was as asked.
    case asItWas(String)
    case refused(String)

    var text: String {
        switch self {
        case .selected: "selected"
        case .deselected: "deselected"
        case .asItWas(let how): how
        case .refused(let why): "not done: " + why
        }
    }
}

/// One path an agent named, and what became of it.
struct AgentPick {
    var path: String
    var outcome: AgentSelection
    /// Where it is on the map. A file newer than the map, or too small for it, is selected without one.
    var node: UInt32? = nil
    var note: String? = nil
    /// The map has to be read again before this one shows.
    var isNewerThanMap = false
}

/// Selecting for an agent, as rules over the map, the disk and the list alone, so they can be tested without the app.
enum AgentPicks {
    /// Files smaller than this never get a place of their own on the map.
    static let smallestOnMap: Int64 = 1 << 20

    /// Selects what an agent found, the way a click on the ring selects it: one path each, moved to the Trash when you
    /// clean, marked with the agent's name and its reason. The same rules as for a click decide what can go. What the
    /// agent found is what's on the disk, so a path the map doesn't have yet is taken at its word when it's there.
    static func select(_ references: [String], in tree: DiskTree, plan: inout PlanList, by agent: String, reason: String,
                       title: (UInt32) -> String) -> [AgentPick] {
        let note = oneLine(reason, most: 140)
        return references.map { reference in
            let node = try? AgentLook.node(reference, in: tree)
            if let node, node == 0 || tree.path(node) == nil {
                return AgentPick(path: reference, outcome: .refused("It has no path of its own: it's a group Headroom makes up, or part of macOS."))
            }
            let written = AgentLook.written(reference)
            let path = node.flatMap { tree.path($0) }.map(PathMath.visible) ?? PathMath.visible(AgentLook.real(written) ?? written)
            var onDisk = stat()
            if node == nil {
                guard !reference.hasPrefix("node:"), lstat(path, &onDisk) == 0 else {
                    return AgentPick(path: reference, outcome: .refused("Not found: there is nothing at this path."))
                }
                // It's counted, and shows as selected, through the folder it's in. A folder the map has never seen can't.
                guard tree.find(visible: (path as NSString).deletingLastPathComponent) != nil else {
                    return AgentPick(path: path, outcome: .refused("Headroom's map doesn't have the folder this is in yet. It is reading the disk again: try again shortly."),
                                     isNewerThanMap: true)
                }
            }
            if plan.covers(path) { return AgentPick(path: path, outcome: .asItWas("already selected"), node: node) }
            // Something taken back from a selected folder comes back with it, as a click would have it.
            if plan.items.contains(where: { $0.excluded.contains(path) }) {
                for at in plan.items.indices { plan.items[at].excluded.removeAll { $0 == path } }
                return AgentPick(path: path, outcome: .selected, node: node)
            }
            guard Safety.canTrash(path) else { return AgentPick(path: path, outcome: .refused("Protected: Headroom never removes this.")) }
            let isSmallFile = node == nil && onDisk.st_mode & S_IFMT == S_IFREG && onDisk.st_size < smallestOnMap
            plan.add(PlanItem(id: PlanItem.id(pickedByHand: path), title: node.map(title) ?? (path as NSString).lastPathComponent,
                              note: note.isEmpty ? DiskTree.friendly(path) : note, tierRaw: Tier.yourCall.rawValue, paths: [path], byHand: true,
                              lastKnownBytes: node.map { tree.totals[Int($0)] } ?? UInt64(max(onDisk.st_blocks, 0)) * 512,
                              diskID: Cleaner.diskID(of: path), agent: agent))
            if node != nil { return AgentPick(path: path, outcome: .selected, node: node) }
            return AgentPick(path: path, outcome: .selected,
                             note: isSmallFile ? "Too small to be drawn on the map by itself. It is selected and counted." : "Newer than Headroom's map. It is selected, and shows once the disk is read again.",
                             isNewerThanMap: !isSmallFile)
        }
    }

    /// Takes back what an agent selected, by path or by a suggestion's id. What you selected yourself stays: that's
    /// yours to deselect.
    static func deselect(paths: [String], ids: [String], in tree: DiskTree, plan: inout PlanList) -> [AgentPick] {
        let yours = "The user selected this in Headroom, so it's theirs to deselect."
        let byPath = paths.map { reference -> AgentPick in
            let written = AgentLook.written(reference)
            let path = (try? AgentLook.node(reference, in: tree)).flatMap { tree.path($0) }.map(PathMath.visible) ?? PathMath.visible(AgentLook.real(written) ?? written)
            guard let owner = plan.items.first(where: { item in
                item.paths.contains { PathMath.isInside(path, $0) } && !item.excluded.contains { PathMath.isInside(path, $0) }
            }) else { return AgentPick(path: path, outcome: .asItWas("not selected")) }
            guard owner.agent != nil else { return AgentPick(path: path, outcome: .refused(yours)) }
            plan.takeBack(path)
            return AgentPick(path: path, outcome: .deselected)
        }
        let byID = ids.map { id -> AgentPick in
            guard let item = plan.item(id) else { return AgentPick(path: id, outcome: .asItWas("not selected")) }
            guard item.agent != nil else { return AgentPick(path: id, outcome: .refused(yours)) }
            plan.remove(id)
            return AgentPick(path: id, outcome: .deselected)
        }
        return byPath + byID
    }

    /// An agent's words, cut to one short line before they're shown in the app.
    static func oneLine(_ text: String, most: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > most ? String(flat.prefix(most - 1)) + "…" : flat
    }
}

extension AppModel {
    private func refusedAll(_ references: [String]) -> [AgentPick]? {
        if tree == nil { return references.map { AgentPick(path: $0, outcome: .refused("Headroom has no map yet.")) } }
        if isCleaning { return references.map { AgentPick(path: $0, outcome: .refused("Headroom is cleaning. Try again when it's done.")) } }
        return nil
    }

    /// Selects what an agent found on the list you see, and shows it at once. What's newer than the map has the disk
    /// read again, so it shows too.
    func select(_ references: [String], by agent: String, reason: String) -> [AgentPick] {
        if let refused = refusedAll(references) { return refused }
        guard let tree = workTree else { return [] }
        let picks = AgentPicks.select(references, in: tree, plan: &plan, by: agent, reason: reason) { tree.name($0) }
        if picks.contains(where: { $0.outcome == .selected }) { planChanged() }
        if picks.contains(where: \.isNewerThanMap), !isScanning { scan(hurry: true) }
        return picks
    }

    func deselect(paths: [String], ids: [String]) -> [AgentPick] {
        if let refused = refusedAll(paths + ids) { return refused }
        guard let tree = workTree else { return [] }
        let picks = AgentPicks.deselect(paths: paths, ids: ids, in: tree, plan: &plan)
        if picks.contains(where: { $0.outcome == .deselected }) { planChanged() }
        return picks
    }

    /// Ticks Headroom's own suggestions for an agent, exactly as a tick in Free Up does, and marks what that added with
    /// the agent's name so the agent can take it back.
    func selectSuggestions(_ ids: [String], by agent: String) -> [(id: String, outcome: AgentSelection)] {
        if let refused = refusedAll(ids) { return refused.map { ($0.path, $0.outcome) } }
        let all = suggestions.everything
        return ids.map { id in
            guard let row = all.first(where: { $0.id == id }) ?? all.flatMap(\.parts).first(where: { $0.id == id }) else {
                return (id, .refused("No such suggestion. list_suggestions has the ids."))
            }
            guard row.isPlannable else { return (id, .refused(row.subtitle.isEmpty ? "Headroom can't remove this itself." : row.subtitle)) }
            let parts = row.parts.isEmpty ? [row] : row.parts
            if parts.allSatisfy({ plan.item($0.id) != nil }) { return (id, .asItWas("already selected")) }
            let before = Set(plan.items.map(\.id))
            toggle(row)
            let added = plan.items.indices.filter { !before.contains(plan.items[$0].id) }
            guard !added.isEmpty else { return (id, .refused("Headroom couldn't select it just now. The map may be changing: try again shortly.")) }
            for at in added { plan.items[at].agent = agent }
            savePlan()
            return (id, .selected)
        }
    }

    /// Has Headroom look at everything selected, as it does before a clean, when some of it hasn't been looked at yet, and
    /// waits a few seconds for the answer. The checks otherwise run only while Free Up is showing.
    func checkForAgent() async {
        guard !isCleaning, plan.items.contains(where: { checks[$0.id] == nil }) else { return }
        // The numbers the checks go by are worked out first.
        for _ in 0..<50 where planNumbers.byItem.isEmpty && !plan.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        runChecks()
        for _ in 0..<150 where isChecking { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Brings Headroom forward on Free Up, where what's selected is listed, and into a folder when one is named.
    func show(_ reference: String?, view: Lens) throws -> String {
        var place: String?
        if let reference, let tree {
            var node = try AgentLook.node(reference, in: tree)
            // A file is shown in its folder.
            if !tree.nodes[Int(node)].has(NodeFlag.directory), !tree.nodes[Int(node)].has(NodeFlag.synthetic) { node = tree.nodes[Int(node)].parent }
            go(to: node)
            place = node == 0 ? nil : tree.friendlyPath(node)
        }
        setLens(view)
        showPanel(true)
        // A scripted check stays behind whatever you're doing.
        if ScriptRunner.path == nil {
            NSApp?.activate()
            mapView?.window?.makeKeyAndOrderFront(nil)
        }
        return "Headroom is showing \(view.title)" + (place.map { " in \($0)" } ?? "") + "."
    }
}
