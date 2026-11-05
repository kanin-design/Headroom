import AppKit
import SwiftUI

/// What you're pointing at in the panel.
struct Pointing {
    var id: String
    var title: String
    var bytes: UInt64
    var color: Lab
}

struct CleanProgress: Equatable {
    var done: Int
    var total: Int
    var title: String
    var bytesDone: UInt64 = 0
    var bytesTotal: UInt64 = 0
}

/// What's left to do after a clean: everything is in the Trash, and it can still come back.
struct AfterClean: Equatable {
    enum State: Equatable {
        case waiting
        case emptying
        case done(got: UInt64)
    }

    var things: [CleanedThing]
    /// What emptying gives back.
    var bytes: UInt64
    var includesOldTrash: Bool
    var oldTrashBytes: UInt64 = 0
    /// What was already in the Trash when you said that can go too. Anything thrown away since then stays.
    var oldTrashItems: [String] = []
    var failed = 0
    var heldBack = 0
    /// What couldn't be deleted when it came to it.
    var notDeleted = 0
    var state: State = .waiting
    var isEmptying: Bool { state == .emptying }
}

/// Another path holding the same files as something planned.
struct OtherCopy: Equatable {
    /// By path, so it means the same thing whichever map is on screen.
    var paths: [String]
    var bytes: UInt64
    var title: String
}

extension AppModel {
    // MARK: Keeping the plan

    func loadPlan() {
        let file = PlanStore.load()
        plan = file.list
        lastPlanItems = file.lastItems
        let waiting = file.cleaned.filter { FileManager.default.fileExists(atPath: $0.inTrash) }
        let oldTrash = (file.oldTrashItems ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        if !waiting.isEmpty || !oldTrash.isEmpty {
            afterClean = AfterClean(things: waiting, bytes: waiting.reduce(0) { $0 &+ $1.bytes } &+ file.oldTrashBytes, includesOldTrash: !oldTrash.isEmpty,
                                    oldTrashBytes: file.oldTrashBytes, oldTrashItems: oldTrash)
        }
    }

    func savePlan() {
        var file = PlanFile(list: plan, lastItems: lastPlanItems)
        if let afterClean, afterClean.state == .waiting {
            file.cleaned = afterClean.things
            file.oldTrashItems = afterClean.oldTrashItems
            file.oldTrashBytes = afterClean.oldTrashBytes
        }
        // Whatever has already gone to the Trash in a clean that's still running is on record too, whatever happens next.
        file.cleaned += pendingCleaned
        PlanStore.save(file)
    }

    /// Finds what the plan means in the tree on screen. A thing on another disk simply isn't on this ring.
    func resolvePlanSynchronously(in tree: DiskTree) {
        nodeOfPath = [:]
        cachedAfterPlan = nil
        resolvePlanNodes(in: tree)
        refreshPlanNumbers()
    }

    /// Plan paths are written the way you'd write them. On the startup disk the map knows them by their real place.
    private func node(for path: String, in tree: DiskTree) -> UInt32? {
        if let known = nodeOfPath[path] { return known }
        guard let found = tree.find(path: "/System/Volumes/Data" + path) ?? tree.find(path: path) else { return nil }
        nodeOfPath[path] = found
        return found
    }

    /// A node's path as the plan keeps it.
    private func planPath(_ node: UInt32, in tree: DiskTree) -> String? {
        guard let path = tree.path(node).map(PathMath.visible) else { return nil }
        nodeOfPath[path] = node
        return path
    }

    /// Nothing changes while things are on their way out, and suggestions only mean something for the map they came from.
    private var canEditPlan: Bool {
        guard cleanProgress == nil, afterClean?.isEmptying != true else {
            showTip("Just a moment, cleaning is under way.")
            return false
        }
        return true
    }

    private func isCurrent(_ tree: DiskTree) -> Bool { winsScanID == tree.scanID }

    func resolvePlanNodes(in tree: DiskTree) {
        var nodes: [String: [UInt32]] = [:]
        var all: [UInt32] = []
        var excluded: [UInt32] = []
        for item in plan.items {
            let found = item.paths.compactMap { node(for: $0, in: tree) }
            nodes[item.id] = found
            all += found
            excluded += item.excluded.compactMap { node(for: $0, in: tree) }
        }
        planNodes = nodes
        planExcluded = excluded
        planSet = all.isEmpty ? nil : NodeSet(all, in: tree)
        planBack = excluded.isEmpty ? nil : NodeSet(excluded, in: tree)
    }

    /// Whether a node goes at the next clean.
    func plannedTest() -> RingLayout.Planner {
        // What's in the Trash goes when it's emptied, so it stays striped until then.
        var waitingTrash: NodeSet?
        if let afterClean, afterClean.state == .waiting, let tree, let trash = trashNode(in: tree) { waitingTrash = NodeSet([trash], in: tree) }
        guard let set = planSet else {
            guard let waitingTrash else { return { _ in false } }
            return { node in waitingTrash.contains(node) }
        }
        let back = planBack
        return { node in
            (set.contains(node) && !(back?.contains(node) ?? false)) || (waitingTrash?.contains(node) ?? false)
        }
    }

    func isPlanned(_ node: UInt32) -> Bool { plannedTest()(node) }

    /// The ticks around the ring: every suggestion in this picture in Free Up, and what's planned everywhere.
    func ringMarks() -> [RingLayout.Mark] {
        var byNode: [UInt32: RingLayout.Mark] = [:]
        let planned = plannedTest()
        if lens == .freeUp {
            for row in shownRows where row.isPlannable || row.action == .command {
                let color = (rowColours[row.id] ?? Palette.Box.other).linearP3
                for node in row.nodes { byNode[node] = RingLayout.Mark(node: node, color: color, planned: planned(node)) }
            }
        }
        for item in plan.items {
            let color = (rowColours[item.id] ?? Palette.Box.hand).linearP3
            for node in planNodes[item.id] ?? [] { byNode[node] = RingLayout.Mark(node: node, color: color, planned: true) }
        }
        return Array(byNode.values)
    }

    // MARK: What's shown

    /// The list always shows what's in the picture you're looking at.
    func refreshShownRows() {
        guard let tree else {
            boxes = []
            shownRows = []
            return
        }
        let kept = Set(plan.kept.map(\.id))
        var page = Sections.boxes(from: suggestions.sections, tree: tree, focus: focus, kept: kept)
        // While a clean is waiting to be emptied, the Trash is that step, not one more suggestion.
        if afterClean != nil { page.removeAll { $0.id == "trash" } }
        if let hand = pickedByHand(in: tree, besides: page.flatMap(\.rows)) { page.insert(hand, at: 0) }
        boxes = page
        let others = suggestions.others.compactMap { kept.contains($0.id) ? nil : Sections.scoped($0, tree: tree, focus: focus) }
        shownRows = page.flatMap(\.rows) + others
        flatRows = shownRows
        rowOfNode = [:]
        for (at, row) in flatRows.enumerated() {
            for node in row.nodes where rowOfNode[node] == nil { rowOfNode[node] = at }
        }
        rowColours = Sections.colours(for: page)
        mapColours = reclaim?.rowIDs.map { rowColours[$0]?.linearP3 } ?? []
        boxOfRow = [:]
        for box in page {
            for row in box.rows { boxOfRow[row.id] = box.id }
        }
        refreshRowStates()
    }

    /// What you clicked on the ring that isn't part of any suggestion has a box too, so it can be seen and taken back.
    private func pickedByHand(in tree: DiskTree, besides listed: [WinRow]) -> Box? {
        let picked = plan.items.filter { $0.id.hasPrefix("path:") }
        guard !picked.isEmpty else { return nil }
        let inSuggestions = NodeSet(listed.flatMap(\.nodes), in: tree)
        let rows = picked.compactMap { item -> WinRow? in
            let nodes = (planNodes[item.id] ?? []).filter { focus == 0 || tree.isInside($0, focus) }
            guard !nodes.isEmpty, !nodes.allSatisfy({ inSuggestions.contains($0) }) else { return nil }
            let bytes = nodes.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            var row = WinRow(id: item.id, title: item.title, subtitle: item.note, detail: "You picked this on the ring.", tier: item.tier, nodes: nodes, bytes: bytes, paperBytes: bytes,
                             action: .trash, command: nil, bundleID: nil)
            row.stepAfterPlanning = item.step
            return row
        }
        guard !rows.isEmpty else { return nil }
        return Box(id: "hand", title: "Picked by hand", detail: rows.count == 1 ? "You clicked this on the ring" : "You clicked these on the ring", color: Palette.Box.hand, rows: rows)
    }

    func refreshRowStates() {
        guard let tree else { return }
        let planned = plannedTest()
        let set = planSet
        let back = planBack
        var states: [String: TickState] = [:]
        func state(_ nodes: [UInt32]) -> TickState {
            // Only the things this row stands for: anything else is just near it.
            guard set != nil, !nodes.isEmpty else { return .none }
            var covered = 0
            var partly = false
            for node in nodes {
                if planned(node) {
                    covered += 1
                    if back?.hasAny(inside: node) == true { partly = true }
                } else if set?.hasAny(inside: node) == true {
                    partly = true
                }
            }
            if covered == nodes.count && !partly { return .all }
            return covered > 0 || partly ? .some : .none
        }
        _ = tree
        for row in shownRows {
            states[row.id] = state(row.nodes)
            for part in row.parts { states[part.id] = state(part.nodes) }
        }
        func stateOf(_ box: Box) {
            let all = box.rows.map { states[$0.id] ?? .none }
            states[box.id] = all.allSatisfy { $0 == .all } ? .all : (all.allSatisfy { $0 == .none } ? .none : .some)
            box.kids.forEach(stateOf)
        }
        boxes.forEach(stateOf)
        rowStates = states
    }

    /// The Trash is what you've already decided about, so it starts ticked. Emptying it is still its own click, at the very end.
    func tickTheTrash() {
        guard let tree, afterClean == nil, cleanProgress == nil, winsScanID == tree.scanID,
              let row = suggestions.sections.first(where: { $0.id == "trash" })?.rows.first,
              plan.item(row.id) == nil, !refusedRows.contains(row.id) else { return }
        plan.add(item(for: row, in: tree))
        planChanged()
    }

    /// One line on why this folder is as big as it is.
    func insightLine() -> String? {
        guard let tree, focus != 0 else { return nil }
        let folder = RingLayout.chainTail(tree: tree, focus)
        let total = tree.totals[Int(folder)]
        guard total >= 500_000_000 else { return nil }
        let kids = tree.children(folder).filter { tree.totals[Int($0)] > 0 }
        guard let top = kids.first else { return nil }
        let share = Double(tree.totals[Int(top)]) / Double(total)
        if share >= 0.5, kids.count >= 2 {
            return "\(displayName(top)) is \(share >= 0.75 ? "most" : "over half") of this."
        }
        if kids.count >= 5 {
            let three = kids.prefix(3).reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            let part = Double(three) / Double(total)
            if part >= 0.6 { return "Three things are \(Int(part * 100))% of this." }
        }
        if tree.statRow(folder)[DiskTree.statRecent30] == 0 {
            return "Nothing in here has changed for over a month."
        }
        return nil
    }

    // MARK: Changing the plan

    private func item(for row: WinRow, in tree: DiskTree) -> PlanItem {
        let paths = row.nodes.compactMap { planPath($0, in: tree) } + row.extraPaths.map(PathMath.visible)
        return PlanItem(id: row.id, title: row.title, note: row.subtitle, tierRaw: row.tier.rawValue, paths: paths, step: row.step, bundleID: row.bundleID,
                        lastKnownBytes: row.bytes, diskID: paths.first.flatMap(Cleaner.diskID))
    }

    /// Takes a row out of the plan, and whatever only made sense with it.
    private func takeOut(row: WinRow, in tree: DiskTree) {
        for path in row.nodes.compactMap({ planPath($0, in: tree) }) + row.extraPaths.map(PathMath.visible) {
            plan.takeBack(path)
        }
        plan.items.removeAll { $0.id == row.id + ":also" || $0.id == row.id + ":other-copy" }
    }

    /// Everything that follows a change to the list: the ring, the numbers, and the checks if you're looking at them.
    func planChanged() {
        guard let tree else { return }
        // What's no longer planned has nothing left to say about the last clean.
        cleanFailures = cleanFailures.filter { plan.item($0.key) != nil }
        resolvePlanNodes(in: tree)
        refreshShownRows()
        savePlan()
        refreshPlanNumbers()
        engine.apply(drawing(tree), .live)
        // What's under the pointer now says something different.
        if let pointer = lastPointer {
            lastHoverIndex = -1
            setHover(engine.layout.hit(angle: pointer.angle, radius: pointer.radius))
        }
    }

    func refreshPlanNumbers() {
        guard let tree else { return }
        effectGeneration += 1
        let generation = effectGeneration
        let byItem = planNodes
        let tops = byItem.values.flatMap { $0 }
        let excluded = planExcluded
        guard !tops.isEmpty else {
            planBytes = 0
            planBytesByItem = [:]
            cachedAfterPlan = nil
            engine.setGhost(0)
            checks = [:]
            return
        }
        Task.detached(priority: .userInitiated) {
            let effect = Accounting.effect(of: tops, except: excluded, in: tree)
            let after = AfterPlan(tree: tree, ids: tops, excluded: excluded, effect: effect)
            var perItem: [String: UInt64] = [:]
            // Something on another disk isn't on this map, so what's known about it stays as it was when it was planned.
            for (id, nodes) in byItem where !nodes.isEmpty {
                perItem[id] = nodes.reduce(UInt64(0)) { $0 &+ (effect.perTop[$1] ?? 0) }
            }
            let byItemNow = perItem
            await MainActor.run {
                guard self.effectGeneration == generation, self.tree === tree else { return }
                // A few leftover kilobytes in a folder aren't space anyone gets back.
                self.planBytes = effect.total < 1_000_000 ? 0 : effect.total
                self.planBytesByItem = byItemNow.mapValues { $0 < 1_000_000 ? 0 : $0 }
                self.cachedAfterPlan = after
                self.refreshGhost()
                // The checks say what you'd get back, so they follow these numbers.
                self.checkSoon()
            }
        }
    }

    func ghostShare() -> Float {
        guard lens == .freeUp, let tree, !previewingAfter else { return 0 }
        return Float(planBytes) / Float(max(tree.capacityBytes, 1))
    }

    /// The new free space wears the colours of what's making room, in the order of the list.
    func ghostColours() -> [(end: Float, color: SIMD3<Float>)] {
        guard planBytes > 0 else { return [] }
        var out: [(end: Float, color: SIMD3<Float>)] = []
        var sum: UInt64 = 0
        // From the sections, not the boxes on screen: it's the whole disk's free space, wherever you're looking.
        for section in suggestions.sections {
            let bytes = section.allRows.reduce(UInt64(0)) { $0 &+ (planBytesByItem[$1.id] ?? 0) &+ (planBytesByItem[$1.id + ":other-copy"] ?? 0) }
            guard bytes > 0 else { continue }
            sum &+= bytes
            out.append((min(Float(sum) / Float(planBytes), 1), section.color.linearP3))
        }
        if sum < planBytes { out.append((1, Palette.Box.hand.linearP3)) }
        if out.count > MapEngine.ghostSliceLimit {
            out = Array(out.prefix(MapEngine.ghostSliceLimit - 1)) + [(1, out[out.count - 1].color)]
        }
        return out
    }

    func refreshGhost() {
        engine.setGhostColours(ghostColours())
        engine.setGhost(ghostShare())
    }

    /// Looks at everything that's ticked as soon as the ticking stops, so what needs a look shows before you press Clean.
    func checkSoon() {
        guard lens == .freeUp, cleanProgress == nil else { return }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.runChecks()
        }
    }

    func toggle(_ row: WinRow) {
        guard let tree, row.isPlannable, isCurrent(tree), canEditPlan else { return }
        setPlanned(row, rowStates[row.id] != .all, in: tree)
        planChanged()
    }

    /// One tick for a whole box. A second click takes everything out of it, whatever you'd ticked inside.
    func toggle(_ box: Box) {
        guard let tree, isCurrent(tree), canEditPlan else { return }
        let wanted = box.rowsATickTakes.filter(\.isPlannable)
        let on = wanted.contains { rowStates[$0.id] != .all }
        for row in on ? wanted : box.rows.filter(\.isPlannable) where (rowStates[row.id] != .all) == on || !on {
            setPlanned(row, on, in: tree)
        }
        planChanged()
    }

    private func setPlanned(_ row: WinRow, _ on: Bool, in tree: DiskTree) {
        // A group is one tick for many decisions, each of which stays its own line in the plan.
        for part in row.parts.isEmpty ? [row] : row.parts {
            if on {
                plan.add(item(for: part, in: tree))
                refusedRows.remove(part.id)
                // A torrent's copy of the same files goes with it, or nothing comes back. One that may still be sharing stays until you say.
                if part.otherCopiesIsTorrent, part.otherCopiesCaution == nil, let copy = otherCopyItem(of: part, in: tree) { plan.add(copy) }
            } else {
                takeOut(row: part, in: tree)
                refusedRows.insert(part.id)
            }
        }
    }

    /// Everything in this box that's ticked, with the other copies of its files too. That's what brings the space back.
    func includeOtherCopies(of box: Box) {
        guard let tree, isCurrent(tree), canEditPlan else { return }
        for row in box.rows where (rowStates[row.id] ?? .none) != .none {
            if let copy = otherCopyItem(of: row, in: tree) { plan.add(copy) }
        }
        planChanged()
    }

    /// What the panel should say about something ticked. When a thing's row already offers its other copy, the row says it.
    func problemsToShow(for item: PlanItem) -> [CheckProblem] {
        let problems = checks[item.id]?.problems ?? []
        guard flatRows.contains(where: { $0.id == item.id && $0.otherCopiesTitle != nil }) else { return problems }
        return problems.filter { if case .noGain = $0 { return false } else { return true } }
    }

    private func otherCopyItem(of row: WinRow, in tree: DiskTree) -> PlanItem? {
        let paths = row.otherCopies.compactMap { planPath($0, in: tree) }
        guard !paths.isEmpty else { return nil }
        let places = paths.map(DiskTree.friendly).joined(separator: ", ")
        return PlanItem(id: row.id + ":other-copy", title: "The other copy of \(row.title)", note: row.otherCopiesCaution.map { $0 + " " + places } ?? places, tierRaw: Tier.yourCall.rawValue, paths: paths,
                        lastKnownBytes: row.paperBytes, diskID: paths.first.flatMap(Cleaner.diskID))
    }

    // MARK: Pointing

    /// You're pointing at this in the panel. The ring lights the same files, the names around it follow, and the free space shows
    /// what it would add. Moving from row to row doesn't flicker, because letting go waits a moment for the next one.
    func point(at box: Box?, row: WinRow? = nil) {
        guard let tree else { return }
        pointingTask?.cancel()
        guard let box else {
            pointingTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(70))
                guard let self, !Task.isCancelled else { return }
                self.pointing = nil
                self.highlight(nodes: [])
                self.engine.setPreview(0, color: .zero)
                withAnimation(.easeOut(duration: 0.16)) { self.labels = self.makeLabels() }
            }
            return
        }
        let id = row?.id ?? box.id
        guard pointing?.id != id else { return }
        let rows = row.map { [$0] } ?? box.rows
        let bytes = rows.reduce(UInt64(0)) { $0 &+ $1.gain }
        let color = row.flatMap { rowColours[$0.id] } ?? box.color
        pointing = Pointing(id: id, title: row?.title ?? box.title, bytes: bytes, color: color)
        highlight(nodes: rows.flatMap(\.nodes))
        let adding = (row == nil ? box.rowsATickTakes : rows).filter { rowStates[$0.id] != .all }.reduce(UInt64(0)) { $0 &+ $1.aTickFrees }
        engine.setPreview(Float(adding) / Float(max(tree.capacityBytes, 1)), color: color.linearP3)
        // The biggest of what's lit gets its name around the ring.
        var picks: [LabelPlacer.Pick] = []
        let layout = engine.layout
        for one in rows.prefix(40) {
            guard let at = layout.bestPiece(for: one.nodes, tree: tree), !picks.contains(where: { $0.index == at }) else { continue }
            picks.append(LabelPlacer.Pick(index: at, title: one.title, value: formatBytes(one.gain), score: Double(layout.pieces[at].bytes)))
        }
        picks.sort { $0.score > $1.score }
        withAnimation(.easeOut(duration: 0.14)) {
            labels = LabelPlacer.place(layout: layout, ring: ring, lens: lens, tree: tree, model: self, only: Array(picks.prefix(7)))
            labelsVisible = true
        }
    }

    /// What's ticked in the picture on screen.
    var planBytesHere: UInt64 {
        guard let tree, focus != 0 else { return planBytes }
        var sum: UInt64 = 0
        for (id, nodes) in planNodes where !nodes.isEmpty {
            let inside = nodes.filter { tree.isInside($0, focus) }
            if inside.count == nodes.count { sum &+= planBytesByItem[id] ?? 0 }
            else { sum &+= inside.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] } }
        }
        return sum
    }

    /// A click on the ring: this too. A second click takes it back.
    func togglePiece(_ node: UInt32) {
        guard let tree, canEditPlan else { return }
        guard let path = planPath(node, in: tree) else {
            let cantLook = tree.nodes[Int(node)].has(NodeFlag.hidden) || tree.nodes[Int(node)].has(NodeFlag.locked)
            showTip(cantLook ? "Headroom can't look inside this, so it can't go." : "\(displayName(node)) is part of macOS, so it can't go.")
            return
        }
        let row = isCurrent(tree) ? rowOfNode[node].flatMap { $0 < flatRows.count ? flatRows[$0] : nil } : nil
        if isPlanned(node) {
            // The whole of a suggestion comes out as one, with whatever goes with it.
            if let row, row.nodes.count == 1 || row.action == .uninstall || row.action == .emptyTrash {
                toggle(row)
                return
            }
            plan.takeBack(path)
            planChanged()
            return
        }
        // Something you'd taken back from a planned folder comes back with it.
        if plan.items.contains(where: { $0.excluded.contains(path) }) {
            for at in plan.items.indices { plan.items[at].excluded.removeAll { $0 == path } }
            planChanged()
            return
        }
        if let row {
            guard row.isPlannable else {
                showTip(row.subtitle.isEmpty ? "\(row.title) can't go from here." : row.subtitle)
                return
            }
            if row.action == .emptyTrash || row.action == .uninstall || row.nodes.count == 1 {
                toggle(row)
                return
            }
            var part = item(for: row, in: tree)
            part.paths = [path]
            plan.add(part)
            planChanged()
            return
        }
        guard Safety.canTrash(path) else {
            let isFolder = tree.nodes[Int(node)].firstChild != 0
            showTip(isFolder ? "\(displayName(node)) can't go as a whole. Double-click to look inside." : "\(displayName(node)) is protected, so it can't go.")
            return
        }
        plan.add(PlanItem(id: "path:" + path, title: displayName(node), note: tree.friendlyPath(node), tierRaw: Tier.yourCall.rawValue, paths: [path], byHand: true,
                          lastKnownBytes: tree.totals[Int(node)], diskID: Cleaner.diskID(of: path)))
        planChanged()
    }

    func showTip(_ text: String) {
        tip = text
        tipTask?.cancel()
        tipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            self?.tip = nil
        }
    }

    /// Take it out of the plan and stop suggesting it.
    func keep(_ row: WinRow) {
        guard canEditPlan else { return }
        for part in row.parts { plan.remove(part.id) }
        plan.keep(row.id, title: row.title)
        afterKeeping()
    }

    func keep(item: PlanItem) {
        guard canEditPlan else { return }
        plan.keep(item.id, title: item.title)
        afterKeeping()
    }

    func stopKeeping(_ id: String) {
        guard canEditPlan else { return }
        plan.stopKeeping(id)
        afterKeeping()
    }

    private func afterKeeping() {
        guard let tree else { return }
        cleanFailures = cleanFailures.filter { plan.item($0.key) != nil }
        reclaim = Self.reclaimMap(tree: tree, suggestions, kept: plan.kept)
        resolvePlanNodes(in: tree)
        refreshShownRows()
        savePlan()
        refreshPlanNumbers()
        engine.apply(drawing(tree), .live)
    }

    func removeFromPlan(_ item: PlanItem) {
        guard canEditPlan else { return }
        plan.remove(item.id)
        refusedRows.insert(item.id)
        planChanged()
    }

    func clearPlan() {
        guard canEditPlan else { return }
        clearedItems = plan.items
        plan.items = []
        // Untick everything means everything, the Trash included, until you say otherwise.
        refusedRows.formUnion(clearedItems.map(\.id))
        planChanged()
    }

    func restoreCleared() {
        guard canEditPlan else { return }
        for item in clearedItems { plan.add(item) }
        clearedItems = []
        planChanged()
    }

    func setStep(_ step: PlanStep, for id: String) {
        guard canEditPlan, let at = plan.items.firstIndex(where: { $0.id == id }) else { return }
        plan.items[at].step = step
        planChanged()
    }

    func acceptChange(for id: String) {
        guard let at = plan.items.firstIndex(where: { $0.id == id }) else { return }
        plan.items[at].acceptedChange = Date()
        savePlan()
        runChecks()
    }

    func quit(bundleID: String) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        apps.forEach { $0.terminate() }
        Task { [weak self] in
            for _ in 0..<40 where apps.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(150))
            }
            self?.runChecks()
        }
    }

    func alsoPlanOtherCopy(for item: PlanItem) {
        guard let other = otherCopies[item.id], canEditPlan else { return }
        plan.add(PlanItem(id: item.id + ":other-copy", title: "The other copy of \(item.title)", note: other.title, tierRaw: Tier.yourCall.rawValue, paths: other.paths, lastKnownBytes: other.bytes,
                          diskID: other.paths.first.flatMap(Cleaner.diskID)))
        planChanged()
    }

    /// A disk something could be moved to. It may not be plugged in right now, in which case the move waits for it.
    struct DiskChoice: Hashable {
        var name: String
        var mountPath: String
        var isPluggedIn: Bool
    }

    /// The disks something could move to: any but the one it's on.
    func otherDisks(for path: String) -> [DiskChoice] {
        let here = PathMath.mount(of: PathMath.visible(path))
        var out = volumes.filter { $0.mountPath != here && $0.mountPath != "/" }.map { DiskChoice(name: $0.name, mountPath: $0.mountPath, isPluggedIn: true) }
        for name in facts.knownDisks where "/Volumes/" + name != here && !out.contains(where: { $0.name == name }) && !volumes.contains(where: { $0.name == name }) {
            out.append(DiskChoice(name: name, mountPath: "/Volumes/" + name, isPluggedIn: false))
        }
        return out
    }

    /// Whether something moved to this folder stays in Plex, because that folder is one of Plex's libraries.
    func staysInPlex(_ folder: String) -> Bool {
        facts.plexRoots.contains { PathMath.isInside(folder, $0) }
    }

    /// Where something would go on another disk: the matching folder, if that disk is set up the same way.
    func moveFolder(for path: String, to disk: DiskChoice) -> String {
        let visible = PathMath.visible(path)
        let parent = (visible as NSString).deletingLastPathComponent
        for root in facts.plexRoots where PathMath.isInside(parent, root) {
            let last = (root as NSString).lastPathComponent
            if let match = facts.plexRoots.first(where: { $0.hasPrefix(disk.mountPath + "/") && ($0 as NSString).lastPathComponent == last }) {
                return match + parent.dropFirst(root.count)
            }
        }
        // The same place, relative to the top of wherever it is now.
        let home = NSHomeDirectory()
        if PathMath.isInside(parent, home) { return disk.mountPath + parent.dropFirst(home.count) }
        let mount = PathMath.mount(of: visible)
        return disk.mountPath + (mount == "/" ? parent : String(parent.dropFirst(mount.count)))
    }

    /// A move is one thing going to one place, so it needs one path.
    func planMove(_ row: WinRow, to disk: DiskChoice) {
        guard let tree, isCurrent(tree), canEditPlan, row.nodes.count == 1 else { return }
        var planned = item(for: row, in: tree)
        guard let first = planned.paths.first else { return }
        planned.step = .move(folder: moveFolder(for: first, to: disk))
        plan.items.removeAll { $0.id == planned.id }
        plan.add(planned)
        refusedRows.remove(row.id)
        planChanged()
    }

    func planMove(node: UInt32, to disk: DiskChoice) {
        guard let tree, canEditPlan, let path = planPath(node, in: tree) else { return }
        if isCurrent(tree), let at = rowOfNode[node], at < flatRows.count, flatRows[at].nodes.count == 1 {
            planMove(flatRows[at], to: disk)
            return
        }
        let folder = moveFolder(for: path, to: disk)
        if let existing = plan.items.first(where: { $0.paths == [path] }) {
            setStep(.move(folder: folder), for: existing.id)
            return
        }
        plan.add(PlanItem(id: "path:" + path, title: displayName(node), note: tree.friendlyPath(node), tierRaw: Tier.yourCall.rawValue, paths: [path],
                          step: .move(folder: folder), byHand: true, lastKnownBytes: tree.totals[Int(node)], diskID: Cleaner.diskID(of: path)))
        planChanged()
    }

    // MARK: Showing the after

    func setPreviewAfter(_ on: Bool) {
        guard on != previewingAfter, let tree else { return }
        if on, planBytes == 0 || lens != .freeUp || cachedAfterPlan == nil { return }
        previewingAfter = on
        withAnimation(.easeOut(duration: 0.12)) { labelsVisible = false }
        if on, let after = cachedAfterPlan {
            engine.setGhost(0)
            engine.apply(drawing(tree, after: after), .settle)
        } else {
            engine.setGhost(ghostShare())
            engine.apply(drawing(tree), .settle)
            placeLabels(after: 0.3)
        }
    }

    // MARK: Opening things

    func toggleExpanded(_ row: WinRow) {
        guard let tree else { return }
        if expandedRow == row.id {
            expandedRow = nil
            if let back = focusBeforeExpanding {
                focusBeforeExpanding = nil
                go(to: back)
            }
            return
        }
        expandedRow = row.id
        // The ring goes to the files you're now looking at, when they're all in one place.
        if row.nodes.count == 1, let node = row.nodes.first {
            let isFolder = tree.nodes[Int(node)].firstChild != 0
            let target = isFolder ? node : tree.nodes[Int(node)].parent
            if target != focus, target != 0 {
                focusBeforeExpanding = focusBeforeExpanding ?? focus
                zoom(into: target)
            }
        }
    }

    func innerNodes(of row: WinRow) -> [UInt32] {
        guard let tree else { return [] }
        if row.nodes.count > 1 { return row.nodes.sorted { tree.totals[Int($0)] > tree.totals[Int($1)] } }
        guard let node = row.nodes.first else { return [] }
        let tail = RingLayout.chainTail(tree: tree, node)
        return tree.children(tail).filter { tree.totals[Int($0)] > 0 }
    }

    // MARK: Checks

    /// Looks at everything planned as it is now. Nothing changes.
    func runChecks() {
        guard let tree else { return }
        checkGeneration += 1
        let generation = checkGeneration
        isChecking = true
        let items = plan.items
        let bytes = planBytesByItem
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> PlanChecks.RunningApp? in
            guard let id = app.bundleIdentifier else { return nil }
            return PlanChecks.RunningApp(bundleID: id, name: app.localizedName ?? id)
        }
        let byItem = planNodes
        let fullAccess = hasFullAccess
        Task.detached(priority: .userInitiated) {
            var others: [String: OtherCopy] = [:]
            for item in items {
                guard let nodes = byItem[item.id], !nodes.isEmpty, !item.isEmptyTrash, !tree.links.isEmpty else { continue }
                let found = Accounting.otherCopies(of: nodes, in: tree)
                if let first = found.folders.first, found.bytes > 1_000_000 {
                    others[item.id] = OtherCopy(paths: found.folders.compactMap { tree.path($0).map(PathMath.visible) }, bytes: found.bytes, title: tree.friendlyPath(first))
                }
            }
            let othersNow = others
            let result = PlanChecks.run(items: items, trueBytes: bytes, otherCopy: othersNow.mapValues { (title: $0.title, bytes: $0.bytes) }, runningApps: apps, fullAccess: fullAccess)
            await MainActor.run {
                guard self.checkGeneration == generation, self.tree === tree else { return }
                self.checks = Self.adding(self.cleanFailures, to: result)
                self.otherCopies = othersNow
                self.isChecking = false
            }
        }
    }

    var readyItems: [PlanItem] { plan.items.filter { checks[$0.id]?.canGo ?? true } }
    var heldBackItems: [PlanItem] { plan.items.filter { !(checks[$0.id]?.canGo ?? true) } }

    /// What the last clean couldn't move stays on the list with the reason, until you say try again.
    nonisolated private static func adding(_ failures: [String: CheckProblem], to checks: [String: ItemCheck]) -> [String: ItemCheck] {
        var out = checks
        for (id, problem) in failures where out[id] != nil { out[id]?.problems.append(problem) }
        return out
    }

    func tryAgain(_ item: PlanItem) {
        cleanFailures[item.id] = nil
        message = nil
        runChecks()
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }

    // MARK: Clean

    /// Checks everything one last time, then carries out what's ready. What isn't ready stays planned.
    func cleanNow() {
        factsOfSavedMap = false
        guard cleanProgress == nil, afterClean?.isEmptying != true, let tree, !tree.isPartial else { return }
        // What was said about the last clean is over now.
        message = nil
        let items = plan.items
        let bytes = planBytesByItem
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> PlanChecks.RunningApp? in
            guard let id = app.bundleIdentifier else { return nil }
            return PlanChecks.RunningApp(bundleID: id, name: app.localizedName ?? id)
        }
        let tops = planNodes.values.flatMap { $0 }
        let excluded = planExcluded
        let others = otherCopies.mapValues { (title: $0.title, bytes: $0.bytes) }
        let fullAccess = hasFullAccess
        let failedBefore = cleanFailures
        // Nothing replaces the map while things are leaving it. The disk is read again afterwards.
        if isScanning {
            activeScan?.scanner.cancel()
            activeScan = nil
            isScanning = false
            scanGeneration &+= 1
            scanWasStopped = true
        }
        checkGeneration &+= 1
        cleanProgress = CleanProgress(done: 0, total: 0, title: "Checking")
        // A clean that's waiting to be emptied stays on record: this one joins it.
        if afterClean == nil {
            takenOut = []
            lastPlanItems = []
        }
        pendingCleaned = []
        let stop = LockedFlag()
        cleanStop = stop

        Task.detached(priority: .userInitiated) {
            let result = Self.adding(failedBefore, to: PlanChecks.run(items: items, trueBytes: bytes, otherCopy: others, runningApps: apps, fullAccess: fullAccess))
            let effect = Accounting.effect(of: tops, except: excluded, in: tree)
            let fm = FileManager.default
            var work: [(item: PlanItem, paths: [String])] = []
            var goneIDs: [String] = []
            var oldTrashItems: [String] = []
            var oldTrashBytes: UInt64 = 0
            for item in items {
                guard let check = result[item.id] else { continue }
                if check.isGone { goneIDs.append(item.id) }
                guard check.canGo else { continue }
                if item.isEmptyTrash {
                    // Exactly what's in there now, before anything joins it.
                    if let folder = item.paths.first { oldTrashItems += Cleaner.trashContents(folder) }
                    oldTrashBytes &+= bytes[item.id] ?? item.lastKnownBytes
                    continue
                }
                let paths = PlanList.effectivePaths(of: item) { (try? fm.contentsOfDirectory(atPath: $0)) ?? [] }
                let going = paths.filter { path in
                    fm.fileExists(atPath: path) && !check.heldPaths.contains { PathMath.isInside(path, $0) || PathMath.isInside($0, path) }
                }
                if !going.isEmpty { work.append((item, going)) }
            }
            let total = work.reduce(0) { $0 + $1.paths.count }
            let oldItems = oldTrashItems
            let oldBytes = oldTrashBytes
            let gone = goneIDs
            await MainActor.run {
                self.checks = result
                self.cleanProgress = CleanProgress(done: 0, total: total, title: "Starting")
            }
            var failedPaths: [String: [String]] = [:]
            var reasons: [String: CheckProblem] = [:]
            var done = 0
            var stoppedEarly = false
            for (item, paths) in work {
                if stop.value { stoppedEarly = true; break }
                for path in paths {
                    if stop.value { stoppedEarly = true; break }
                    var moved: (place: String, identity: String?)?
                    do {
                        if case .move(let folder) = item.step {
                            let name = (path as NSString).lastPathComponent
                            let soFar = done
                            try Cleaner.copyAndVerify(path, into: PlanList.moveDestination(of: path, item: item, folder: folder), stop: stop) { progress in
                                let update = CleanProgress(done: soFar, total: total, title: "Copying \(name)", bytesDone: progress.bytesDone, bytesTotal: progress.bytesTotal)
                                Task { @MainActor in if self.cleanProgress != nil { self.cleanProgress = update } }
                            }
                        }
                        moved = try Cleaner.trash(path, step: item.step)
                    } catch {
                        failedPaths[item.id, default: []].append(path)
                        reasons[item.id] = Cleaner.whyItFailed(error)
                    }
                    done += 1
                    let count = done
                    let inTrash = moved
                    let share = effect.perTop
                    await MainActor.run {
                        self.cleanProgress = CleanProgress(done: count, total: total, title: item.title)
                        if let inTrash { self.didMove(path, to: inTrash.place, identity: inTrash.identity, item: item, trueBytes: share, tree: tree) }
                    }
                    // If an app itself won't go, its settings and caches stay with it.
                    if item.step == .uninstall, inTrash == nil, path == paths.first { break }
                }
            }
            let failures = failedPaths
            let reasonsNow = reasons
            let stoppedHere = stoppedEarly
            let workDone = work
            await MainActor.run {
                self.cleanFailures.merge(reasonsNow) { $1 }
                self.finishClean(work: workDone, goneIDs: gone, failed: failures, oldTrashItems: oldItems, oldTrashBytes: oldBytes, stoppedEarly: stoppedHere, tree: tree)
            }
        }
    }

    func stopCleaning() { cleanStop.value = true }

    private func didMove(_ path: String, to inTrash: String, identity: String?, item: PlanItem, trueBytes: [UInt32: UInt64], tree cleaned: DiskTree) {
        // On record first, whatever else is going on: this is what makes it possible to bring it back.
        var thing = CleanedThing(itemID: item.id, title: item.title, original: path, inTrash: inTrash, bytes: 0, identity: identity)
        if self.tree === cleaned, let node = nodeOfPath[path] ?? tree?.find(path: "/System/Volumes/Data" + path) ?? tree?.find(path: path) {
            thing.bytes = takeOut(node, from: cleaned, trueBytes: trueBytes[node])
        } else {
            // On another disk, it's not on this map. This is the size it had when it was planned.
            thing.bytes = item.lastKnownBytes / UInt64(max(item.paths.count, 1))
        }
        pendingCleaned.append(thing)
        treeVersion += 1
        let now = Date()
        if now.timeIntervalSince(lastCleanSave) > 0.5 {
            lastCleanSave = now
            savePlan()
        }
        // Each thing visibly goes, without the ring being rebuilt thousands of times.
        if now.timeIntervalSince(lastCleanFrame) > 0.1, self.tree === cleaned {
            lastCleanFrame = now
            engine.apply(drawing(cleaned), .live)
        }
    }

    private func finishClean(work: [(item: PlanItem, paths: [String])], goneIDs: [String], failed: [String: [String]], oldTrashItems: [String], oldTrashBytes: UInt64, stoppedEarly: Bool, tree: DiskTree) {
        cleanProgress = nil
        let things = pendingCleaned
        pendingCleaned = []
        let moved = Set(things.map(\.original))
        let fm = FileManager.default
        var cleanedItems: [PlanItem] = []
        var heldBack = 0
        for (original, going) in work {
            var item = original
            if things.contains(where: { $0.itemID == item.id }) { cleanedItems.append(original) }
            // What didn't go stays planned, so it's easy to see and fix. What no longer exists has nothing to stay for.
            let notReached = going.filter { !moved.contains($0) }
            let held = checks[item.id]?.heldPaths ?? []
            if item.excluded.isEmpty {
                let left = item.paths.filter { !moved.contains($0) && fm.fileExists(atPath: $0) }
                plan.items.removeAll { $0.id == item.id }
                if !left.isEmpty {
                    item.paths = left
                    plan.items.append(item)
                    heldBack += left.count
                }
            } else if notReached.isEmpty && held.isEmpty {
                plan.items.removeAll { $0.id == item.id }
            } else {
                heldBack += notReached.count + held.count
            }
        }
        for id in goneIDs { plan.items.removeAll { $0.id == id } }
        let oldTrash = !oldTrashItems.isEmpty
        if let old = plan.item("trash"), oldTrash || checks["trash"]?.canGo == true {
            cleanedItems.append(old)
            plan.items.removeAll { $0.id == "trash" }
        }
        lastPlanItems += cleanedItems
        let failures = failed.values.reduce(0) { $0 + $1.count }
        var bytes = things.reduce(UInt64(0)) { $0 &+ $1.bytes } &+ oldTrashBytes
        if !things.isEmpty || oldTrash {
            var allThings = things
            var allOld = oldTrashItems
            var allOldBytes = oldTrashBytes
            // Joining a clean that's still waiting to be emptied.
            if let waiting = afterClean, waiting.state == .waiting {
                allThings = waiting.things + things
                allOld += waiting.oldTrashItems
                allOldBytes &+= waiting.oldTrashBytes
                bytes &+= waiting.bytes
            }
            afterClean = AfterClean(things: allThings, bytes: bytes, includesOldTrash: !allOld.isEmpty, oldTrashBytes: allOldBytes, oldTrashItems: allOld, failed: failures, heldBack: heldBack)
        } else if failures > 0 {
            message = failures == 1 ? "That couldn't be moved to the Trash. The list says why." : "\(failures) things couldn't be moved to the Trash. The list says why."
        }
        rescanWhenBack = true
        refreshShownRows()
        if self.tree === tree {
            treeVersion += 1
            resolvePlanSynchronously(in: tree)
            rebuildInsights()
            relayout(.settle)
        }
        cleanFailures = cleanFailures.filter { plan.item($0.key) != nil }
        if !plan.isEmpty { runChecks() }
        savePlan()
        if quitAfterClean {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        if scanWasStopped {
            scanWasStopped = false
            scan()
        }
    }

    /// Puts everything back where it was, and the list back as it was, so it can be fixed and run again.
    func undoClean() {
        guard let after = afterClean, after.state == .waiting else { return }
        let things = after.things
        let taken = takenOut
        let items = lastPlanItems
        let hadMoves = items.contains(where: \.isMove)
        afterClean = nil
        cleanFailures = [:]
        Task.detached(priority: .userInitiated) {
            var failed = 0
            for thing in things.reversed() {
                do { try Cleaner.putBack(thing) } catch { failed += 1 }
            }
            let failures = failed
            await MainActor.run {
                for item in items {
                    self.plan.remove(item.id)
                    self.plan.items.append(item)
                }
                if failures > 0 {
                    self.message = failures == 1 ? "One thing couldn't go back. It's still in the Trash, so you can put it back from there." : "\(failures) things couldn't go back. They're still in the Trash, so you can put them back from there."
                } else if hadMoves {
                    self.message = "Everything is back. The copies on the other disk are still there."
                }
                self.refreshShownRows()
                if let tree = self.tree, !taken.isEmpty, taken.allSatisfy({ $0.tree === tree }), failures == 0 {
                    // Back to the picture it was: nothing needs reading again.
                    for entry in taken.reversed() {
                        if let trash = self.trashNode(in: tree) { tree.subtract(entry.bytes, from: trash) }
                        if let held = entry.heldBy { tree.subtract(entry.heldBytes, from: held) }
                        tree.restore(entry.node)
                    }
                    self.treeVersion += 1
                    self.takenOut = []
                    self.resolvePlanSynchronously(in: tree)
                    self.rebuildInsights()
                    self.relayout(.settle)
                    self.savePlan()
                    self.rescanWhenBack = true
                    if self.isScanning { self.restartScan() }
                } else {
                    // This map was drawn after those things had gone, so the disk has to be read again.
                    self.savePlan()
                    if let tree = self.tree { self.resolvePlanSynchronously(in: tree) }
                    self.restartScan()
                }
            }
        }
    }

    /// Leaves everything in the Trash and carries on. It shows up as what's already in the Trash from here on.
    func leaveInTrash() {
        afterClean = nil
        takenOut = []
        savePlan()
        refreshShownRows()
        rescanWhenBack = true
        rebuildInsights()
        if let tree { engine.apply(drawing(tree), .live) }
    }

    /// The last step, and the only one that can't be undone. It's always your click.
    func emptyNow() {
        guard var after = afterClean, after.state == .waiting, cleanProgress == nil else { return }
        message = nil
        after.state = .emptying
        afterClean = after
        // Nothing replaces the map while things are leaving it. The disk is read again afterwards.
        if isScanning {
            activeScan?.scanner.cancel()
            activeScan = nil
            isScanning = false
            scanGeneration &+= 1
        }
        let things = after.things
        let oldItems = after.oldTrashItems
        let expected = after.bytes
        let oldBytes = after.oldTrashBytes
        // Every disk this touches, so what comes back can be measured on each.
        let mounts = Set((things.map(\.inTrash) + oldItems).map(PathMath.mount))
        var before: [String: UInt64] = [:]
        for mount in mounts { before[mount] = VolumeFacts.read(path: mount)?.free }
        let measuredBefore = before
        let tree = self.tree
        Task.detached(priority: .userInitiated) {
            var failed = 0
            var didDelete = false
            for thing in things {
                do {
                    if try Cleaner.deleteForGood(thing) {
                        didDelete = true
                        await MainActor.run { self.didEmpty(thing.bytes, tree: tree) }
                    }
                } catch {
                    failed += 1
                }
            }
            failed += Cleaner.deleteFromTrash(oldItems)
            if !oldItems.isEmpty { didDelete = true }
            // The disk takes a moment to report what it got back.
            var got: UInt64 = 0
            if didDelete {
                for _ in 0..<20 {
                    var sum: UInt64 = 0
                    for (mount, free) in measuredBefore {
                        if let now = VolumeFacts.read(path: mount)?.free, now > free { sum &+= now - free }
                    }
                    got = max(got, sum)
                    if Double(got) >= Double(expected) * 0.98 { break }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let measured = got
            let failures = failed
            let couldMeasure = !measuredBefore.isEmpty
            await MainActor.run { self.finishEmpty(got: couldMeasure ? measured : expected, oldTrash: oldItems.isEmpty ? 0 : oldBytes, failed: failures, tree: tree) }
        }
    }

    private func didEmpty(_ bytes: UInt64, tree: DiskTree?) {
        guard let tree, self.tree === tree else { return }
        if let trash = trashNode(in: tree) { tree.subtract(bytes, from: trash) }
        tree.add(bytes, to: tree.free)
        treeVersion += 1
        let now = Date()
        if now.timeIntervalSince(lastCleanFrame) > 0.1 {
            lastCleanFrame = now
            engine.apply(drawing(tree), .live)
        }
    }

    private func finishEmpty(got: UInt64, oldTrash: UInt64, failed: Int, tree: DiskTree?) {
        if var after = afterClean {
            after.state = .done(got: got)
            after.notDeleted = failed
            afterClean = after
        }
        if let tree, self.tree === tree {
            if oldTrash > 0 {
                if let trash = trashNode(in: tree) { tree.subtract(oldTrash, from: trash) }
                tree.add(oldTrash, to: tree.free)
            }
            treeVersion += 1
            engine.apply(drawing(tree), .settle)
        }
        takenOut = []
        lastPlanItems = []
        savePlan()
        rescanWhenBack = false
        // A short look at what you got, then the disk is read again quietly so the numbers are exact.
        scan()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(failed > 0 ? 16 : 9))
            guard let self, case .done = self.afterClean?.state else { return }
            self.afterClean = nil
        }
    }

    // MARK: Other disks

    /// Reads another disk quietly in the background, so "also on your backup disk" works without ever opening it. Only with Full Disk
    /// Access: otherwise reading it would bring up a permission prompt nobody asked for.
    func readOtherDisksQuietly() {
        guard hasFullAccess, !isReadingOtherDisk, ScriptRunner.path == nil else { return }
        let current = volume?.mountPath
        let waiting = volumes.filter { $0.mountPath != current && $0.mountPath != "/" && DiskIndex.age(of: $0.name) > 86_400 }
        guard let disk = waiting.first else { return }
        isReadingOtherDisk = true
        let rules = self.rules
        Thread.detachNewThread { [weak self] in
            Thread.current.qualityOfService = .utility
            let scan = DiskScan(facts: disk, rules: rules, fullAccess: true, askPerFolder: false)
            scan.run(mode: .quiet)
            if !scan.scanner.wasCancelled, VolumeFacts.read(path: disk.mountPath) != nil { DiskIndex.save(scan.tree) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReadingOtherDisk = false
                if let tree = self.tree { self.gatherFacts(for: tree, afresh: true) }
                self.readOtherDisksQuietly()
            }
        }
    }

    // MARK: Keyboard

    func handlePlanKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: moveCursor(1)
        case 126: moveCursor(-1)
        case 36:
            // Return never empties, and never starts a second clean on top of one that's waiting for you.
            guard afterClean == nil, !plan.isEmpty else { return false }
            cleanNow()
        case 51:
            guard let box = cursorBox else { return false }
            toggle(box)
        case 49:
            guard let row = cursorBox?.rows.first, let tree, let node = row.nodes.first, let path = tree.path(node) else { return false }
            let visible = path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
            QuickLook.shared.show(URL(fileURLWithPath: visible))
        case 40:
            guard let box = cursorBox, box.rows.count == 1, let row = box.rows.first else { return false }
            moveCursor(1)
            keep(row)
        case 46:
            guard let box = cursorBox, box.rows.count == 1, let row = box.rows.first, let tree, let node = row.nodes.first, let path = tree.path(node), let disk = otherDisks(for: path).first else { return false }
            planMove(row, to: disk)
        default:
            return false
        }
        return true
    }

    func handleScriptKey(_ character: Character) {
        switch character {
        case "j": moveCursor(1)
        case "k": moveCursor(-1)
        case "x": if let box = cursorBox { toggle(box) }
        default: break
        }
    }

    var cursorBox: Box? { boxes.first { $0.id == cursorRow } }

    private func moveCursor(_ by: Int) {
        guard !boxes.isEmpty else { return }
        var at = boxes.firstIndex { $0.id == cursorRow } ?? (by > 0 ? -1 : boxes.count)
        at = min(max(at + by, 0), boxes.count - 1)
        cursorRow = boxes[at].id
        point(at: boxes[at])
    }
}

extension NodeSet {
    /// Whether any folder in the set sits inside this node.
    func hasAny(inside node: UInt32) -> Bool {
        let start = tree.dfsIn[Int(node)], size = tree.dfsSize[Int(node)]
        var low = 0, high = tops.count
        while low < high {
            let middle = (low + high) / 2
            if tree.dfsIn[Int(tops[middle])] <= start { low = middle + 1 } else { high = middle }
        }
        guard low < tops.count else { return false }
        return tree.dfsIn[Int(tops[low])] &- start < size
    }
}

extension AppModel {
    /// The other copy of something has its own tick, because taking it costs something of its own.
    func toggleOtherCopies(of row: WinRow) {
        guard let tree, isCurrent(tree), canEditPlan else { return }
        let paths = row.otherCopies.compactMap { planPath($0, in: tree) }
        if let first = paths.first, plan.covers(first) {
            plan.items.removeAll { $0.id == row.id + ":other-copy" }
        } else if let copy = otherCopyItem(of: row, in: tree) {
            plan.add(copy)
        }
        planChanged()
    }

    /// The extra that's yours to choose, such as an app's data.
    func toggleAlso(of row: WinRow) {
        guard let tree, isCurrent(tree), canEditPlan else { return }
        let paths = row.alsoNodes.compactMap { planPath($0, in: tree) }
        if let first = paths.first, plan.covers(first) {
            plan.items.removeAll { $0.id == row.id + ":also" }
        } else {
            plan.add(PlanItem(id: row.id + ":also", title: "The data of \(row.title)", note: paths.map(DiskTree.friendly).joined(separator: ", "), tierRaw: Tier.yourCall.rawValue, paths: paths,
                              step: row.step == .uninstall ? .uninstall : .trash, bundleID: row.bundleID, lastKnownBytes: row.alsoNodes.reduce(0) { $0 &+ tree.totals[Int($1)] },
                              diskID: paths.first.flatMap(Cleaner.diskID)))
        }
        planChanged()
    }
}
