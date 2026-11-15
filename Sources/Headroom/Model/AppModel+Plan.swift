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
        // What you've selected is written down under its real names, and it's still yours when you start the app normally.
        guard !HiddenNames.isOn else { return }
        let file = PlanStore.load()
        plan = file.list
        lastPlanItems = file.lastItems
        let waiting = file.cleaned.filter { FileManager.default.fileExists(atPath: $0.inTrash) }
        let oldTrash = (file.oldTrashItems ?? []).filter { FileManager.default.fileExists(atPath: $0) }
        if !waiting.isEmpty || !oldTrash.isEmpty {
            // What was already in the Trash counts only while some of it is still there.
            let oldBytes = oldTrash.isEmpty ? 0 : file.oldTrashBytes
            afterClean = AfterClean(things: waiting, bytes: waiting.reduce(0) { $0 &+ $1.bytes } &+ oldBytes, includesOldTrash: !oldTrash.isEmpty,
                                    oldTrashBytes: oldBytes, oldTrashItems: oldTrash)
        }
    }

    func savePlan() {
        guard !HiddenNames.isOn else { return }
        var file = PlanFile(list: plan, lastItems: lastPlanItems)
        // While it's being emptied too. What has already gone is left out when this is read back, because it's no longer
        // in the Trash.
        if let afterClean, afterClean.state == .waiting || afterClean.isEmptying {
            file.cleaned = afterClean.things
            file.oldTrashItems = afterClean.oldTrashItems
            file.oldTrashBytes = afterClean.oldTrashBytes
        }
        // Whatever has already gone to the Trash in a clean that's still running is on record too, whatever happens next.
        file.cleaned += pendingCleaned
        PlanStore.save(file)
    }

    /// Finds what the plan means in the tree on screen. A thing on another disk simply isn't on this ring.
    /// For a map that's new or has changed: nothing remembered from the one before is kept.
    func resolvePlanSynchronously(in tree: DiskTree) {
        planPlaces = PlanPlaces()
        planNumbers.after = nil
        resolvePlanNodes(in: tree)
        refreshPlanNumbers()
    }

    /// A node's path as the plan keeps it.
    func planPath(_ node: UInt32, in tree: DiskTree) -> String? {
        guard let path = tree.path(node).map(PathMath.visible) else { return nil }
        planPlaces.remember(node, at: path)
        return path
    }

    /// Things are leaving the disk or coming back to it: a clean or a Send to Trash, emptying the Trash, or putting a clean
    /// back. Nothing else may change the map or the list meanwhile, and quitting waits for it.
    var isCleaning: Bool { cleanProgress != nil || afterClean?.isEmptying == true || isPuttingBack || driveJob?.isRunning == true }

    /// Whether the plan may be changed now. Nothing changes while things are on their way out, and whoever tried is told so:
    /// this is for the moment of a click, never for a view to read while it draws.
    func mayEditPlan() -> Bool {
        guard !isCleaning else {
            showTip("Still cleaning.")
            return false
        }
        return true
    }

    private func isCurrent(_ tree: DiskTree) -> Bool { winsScanID == tree.scanID }

    func resolvePlanNodes(in tree: DiskTree) {
        var places = planPlaces
        places.resolve(plan.items, in: tree)
        planPlaces = places
        planVersion &+= 1
    }

    /// Whether a node goes at the next clean. Made once for the plan, the map and the Trash as they are, and kept until one
    /// of them changes: views ask this for every row they draw.
    func plannedTest() -> RingLayout.Planner {
        if let planner { return planner }
        // What's in the Trash goes when it's emptied, so it stays striped until then.
        var waitingTrash: NodeSet?
        if let afterClean, afterClean.state == .waiting, let tree, let trash = trashNode(in: tree) { waitingTrash = NodeSet([trash], in: tree) }
        let made: RingLayout.Planner
        if let set = planPlaces.set {
            let back = planPlaces.back
            made = { node in (set.contains(node) && !(back?.contains(node) ?? false)) || (waitingTrash?.contains(node) ?? false) }
        } else if let waitingTrash {
            made = { node in waitingTrash.contains(node) }
        } else {
            made = { _ in false }
        }
        planner = made
        return made
    }

    func isPlanned(_ node: UInt32) -> Bool {
        // Read so a view that asks is drawn again when the answer could change: the sets behind it aren't observed, and it's
        // made from the plan, the map and what's waiting in the Trash. This is the one place that has to know that.
        _ = planVersion
        _ = treeVersion
        _ = afterClean
        return plannedTest()(node)
    }

    /// Whether it can be ticked for Free Up: anything with a place on the disk. What's part of macOS can't.
    func canPlan(_ node: UInt32) -> Bool { node != 0 && tree?.path(node) != nil }

    /// The colour it's ticked in: its box's, when it's a suggestion, otherwise the colour of what's picked by hand.
    func planColour(of node: UInt32) -> Color {
        if let at = rowOfNode[node], at < shownRows.count, let colour = rowColours[shownRows[at].id] { return colour.swiftUI }
        return Palette.Box.hand.swiftUI
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
        // Opening a row sends the ring into its folder so its files can be seen. The list you opened it in stays put.
        var focus = focus
        if expandedRow != nil, let opened = expandedFocus, tree.isInside(focus, opened) { focus = focusBeforeExpanding ?? focus }
        var page = Sections.boxes(from: suggestions.sections, tree: tree, focus: focus, kept: kept)
        // While a clean is waiting to be emptied, the Trash is that step, not one more suggestion.
        if afterClean != nil {
            for at in page.indices { page[at].rows.removeAll { $0.action == .emptyTrash } }
            page.removeAll { $0.rows.isEmpty }
        }
        page.insert(contentsOf: pickedByHand(in: tree, besides: page.flatMap(\.rows)), at: 0)
        boxes = page
        let others = suggestions.others.compactMap { kept.contains($0.id) ? nil : Sections.scoped($0, tree: tree, focus: focus) }
        shownRows = page.flatMap(\.rows) + others
        rowsOfferingOtherCopies = Set(shownRows.filter { $0.otherCopiesTitle != nil }.map(\.id))
        rowOfNode = [:]
        for (at, row) in shownRows.enumerated() {
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

    /// What you clicked on the ring that isn't part of any suggestion has a box too, so it can be seen and taken back. What
    /// an agent selected has a box of its own, under the agent's name, with all of it: that's the list you were asked to
    /// look over, whether or not a suggestion holds some of it too.
    private func pickedByHand(in tree: DiskTree, besides listed: [WinRow]) -> [Box] {
        let picked = plan.items.filter { $0.isPickedByHand }
        guard !picked.isEmpty else { return [] }
        let inSuggestions = NodeSet(listed.flatMap(\.nodes), in: tree)
        func rows(of items: [PlanItem], saying detail: String, all: Bool) -> [WinRow] {
            items.compactMap { item -> WinRow? in
                let nodes = (planPlaces.nodes[item.id] ?? []).filter { focus == 0 || tree.isInside($0, focus) }
                guard !nodes.isEmpty, all || !nodes.allSatisfy({ inSuggestions.contains($0) }) else { return nil }
                let bytes = nodes.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
                var row = WinRow(id: item.id, title: item.title, subtitle: item.note, detail: detail, tier: item.tier, nodes: nodes, bytes: bytes, paperBytes: bytes,
                                 action: .trash, command: nil, bundleID: nil)
                row.stepAfterPlanning = item.step
                return row
            }
        }
        func count(_ rows: [WinRow]) -> String { rows.count == 1 ? "1 item" : "\(rows.count) items" }
        // What an agent found that the map has no place for: newer than the map, or too small for it. Counted, not listed.
        func unlisted(_ items: [PlanItem]) -> String {
            let n = items.filter { (planPlaces.nodes[$0.id] ?? []).isEmpty && planPlaces.loose[$0.id] != nil }.count
            return n == 0 ? "" : ", \(n) not on the map"
        }
        var boxes: [Box] = []
        var agents: [String] = []
        for name in picked.compactMap(\.agent) where !agents.contains(name) { agents.append(name) }
        for name in agents {
            let items = picked.filter { $0.agent == name }
            // Largest first, so what matters most is at the top of what you're asked to look over.
            let theirs = rows(of: items, saying: "Selected by \(name).", all: true).sorted { $0.bytes > $1.bytes }
            if !theirs.isEmpty { boxes.append(Box(id: "agent:" + name, title: "Selected by \(name)", detail: count(theirs) + unlisted(items), color: Palette.Box.hand, rows: theirs)) }
        }
        let own = rows(of: picked.filter { $0.agent == nil }, saying: "Selected on the ring.", all: false)
        if !own.isEmpty { boxes.append(Box(id: "hand", title: "Selected manually", detail: count(own), color: Palette.Box.hand, rows: own)) }
        return boxes
    }

    func refreshRowStates() {
        guard tree != nil else { return }
        let planned = plannedTest()
        let set = planPlaces.set
        let back = planPlaces.back
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
        // A row can also hold files too small for the map, which are ticked by path.
        func whole(_ row: WinRow) -> TickState {
            let onMap = state(row.nodes)
            guard !row.extraPaths.isEmpty, row.action == .trash else { return onMap }
            let planned = Set(planPlaces.loose[row.id] ?? [])
            let count = row.extraPaths.filter { planned.contains(PathMath.visible($0)) }.count
            let small: TickState = count == 0 ? .none : (count == row.extraPaths.count ? .all : .some)
            if row.nodes.isEmpty || onMap == small { return small }
            return .some
        }
        for row in shownRows {
            states[row.id] = whole(row)
            for part in row.parts { states[part.id] = whole(part) }
        }
        func stateOf(_ box: Box) {
            let all = box.rows.map { states[$0.id] ?? .none }
            states[box.id] = all.allSatisfy { $0 == .all } ? .all : (all.allSatisfy { $0 == .none } ? .none : .some)
            box.kids.forEach(stateOf)
        }
        boxes.forEach(stateOf)
        rowStates = states
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
            return "\(displayName(top)): \(Int(share * 100))% of this folder"
        }
        if kids.count >= 5 {
            let three = kids.prefix(3).reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            let part = Double(three) / Double(total)
            if part >= 0.6 { return "Top 3 items: \(Int(part * 100))% of this folder" }
        }
        if tree.statRow(folder)[DiskTree.statRecent30] == 0 {
            return "Unchanged for over a month"
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
        plan.items.removeAll { $0.id == PlanItem.dataID(of: row.id) || $0.id == PlanItem.otherCopyID(of: row.id) }
    }

    /// Everything that follows a change to the list: the ring, the numbers, and the checks if you're looking at them.
    func planChanged() {
        planVersion &+= 1
        takeOffBackupWhatFreeUpHas()
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
        let byItem = planPlaces.nodes
        let tops = byItem.values.flatMap { $0 }
        let excluded = planPlaces.excluded
        let loose = planPlaces.loose
        guard !tops.isEmpty || !loose.isEmpty else {
            planNumbers = PlanNumbers()
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
            // What's too small for the map is measured where it is.
            var looseTotal: UInt64 = 0
            for (id, paths) in loose {
                let bytes = paths.reduce(UInt64(0)) { sum, path in
                    let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize
                    return sum &+ UInt64(size ?? 0)
                }
                perItem[id, default: 0] &+= bytes
                looseTotal &+= bytes
            }
            let total = effect.total &+ looseTotal
            let byItemNow = perItem
            await MainActor.run {
                guard self.effectGeneration == generation, self.tree === tree else { return }
                // A few leftover kilobytes in a folder aren't space anyone gets back.
                self.planNumbers = PlanNumbers(total: total < 1_000_000 ? 0 : total, byItem: byItemNow.mapValues { $0 < 1_000_000 ? 0 : $0 }, after: after)
                self.refreshGhost()
                // The checks say what you'd get back, so they follow these numbers.
                self.checkSoon()
            }
        }
    }

    func ghostShare() -> Float {
        guard mode == .freeUp, let tree, !previewingAfter else { return 0 }
        return Float(planNumbers.total) / Float(max(tree.capacityBytes, 1))
    }

    /// The new free space wears the colours of what's making room, in the order of the list.
    func ghostColours() -> [(end: Float, color: SIMD3<Float>)] {
        guard planNumbers.total > 0 else { return [] }
        var out: [(end: Float, color: SIMD3<Float>)] = []
        var sum: UInt64 = 0
        // From the sections, not the boxes on screen: it's the whole disk's free space, wherever you're looking.
        for section in suggestions.sections {
            let bytes = section.allRows.reduce(UInt64(0)) { $0 &+ (planNumbers.byItem[$1.id] ?? 0) &+ (planNumbers.byItem[PlanItem.otherCopyID(of: $1.id)] ?? 0) }
            guard bytes > 0 else { continue }
            sum &+= bytes
            out.append((min(Float(sum) / Float(planNumbers.total), 1), section.color.linearP3))
        }
        if sum < planNumbers.total { out.append((1, Palette.Box.hand.linearP3)) }
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
        guard mode == .freeUp, !isCleaning else { return }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            self.runChecks()
        }
    }

    func toggle(_ row: WinRow) {
        guard let tree, row.isPlannable, isCurrent(tree), mayEditPlan() else { return }
        setPlanned(row, rowStates[row.id] != .all, in: tree)
        planChanged()
    }

    /// One tick for a whole box. A second click takes everything out of it, whatever you'd ticked inside.
    func toggle(_ box: Box) {
        // A shortlist is for picking from: nothing takes all of it at once.
        guard let tree, isCurrent(tree), mayEditPlan(), !box.isShortlist else { return }
        let wanted = box.rowsATickTakes.filter(\.isPlannable)
        let on = wanted.contains { rowStates[$0.id] != .all }
        // Ticking takes what isn't ticked yet. Unticking takes everything, also what a tick wouldn't have taken.
        let rows = on ? wanted.filter { rowStates[$0.id] != .all } : box.rows.filter(\.isPlannable)
        for row in rows { setPlanned(row, on, in: tree) }
        planChanged()
    }

    // MARK: Recommended

    /// What Select recommended would still tick in the picture on screen: caches not in use, and junk.
    var recommendedLeft: [WinRow] { boxes.flatMap(\.recommended).filter { rowStates[$0.id] != .all } }

    func selectRecommended() {
        guard let tree, isCurrent(tree), mayEditPlan() else { return }
        let rows = recommendedLeft
        pointAtRecommended(false)
        for row in rows { setPlanned(row, true, in: tree) }
        planChanged()
    }

    /// Pointing at the button shows what it would take before you press it: its boxes light in the list, its files on the
    /// ring, and the free space grows by that much.
    func pointAtRecommended(_ on: Bool) {
        guard let tree else { return }
        recommendedHot = on
        guard on else {
            point(at: nil)
            return
        }
        pointingTask?.cancel()
        let rows = recommendedLeft
        let bytes = rows.reduce(UInt64(0)) { $0 &+ $1.aTickFrees }
        pointing = Pointing(id: "recommended", title: "Recommended", bytes: bytes, color: Palette.Box.quick)
        highlight(nodes: rows.flatMap(\.nodes))
        engine.setPreview(Float(bytes) / Float(max(tree.capacityBytes, 1)), color: Palette.Box.quick.linearP3)
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
        guard let tree, isCurrent(tree), mayEditPlan() else { return }
        for row in box.rows where (rowStates[row.id] ?? .none) != .none {
            if let copy = otherCopyItem(of: row, in: tree) { plan.add(copy) }
        }
        planChanged()
    }

    /// What the panel should say about something ticked. When a thing's row already offers its other copy, the row says it.
    /// What the checks found for a planned thing, less what its row already says: a row that offers to include the other
    /// copy of its files has said that selecting it alone frees nothing.
    func problemsToShow(for item: PlanItem) -> [CheckProblem] {
        let problems = checks[item.id]?.problems ?? []
        guard rowsOfferingOtherCopies.contains(item.id) else { return problems }
        return problems.filter { if case .noGain = $0 { return false } else { return true } }
    }

    private func otherCopyItem(of row: WinRow, in tree: DiskTree) -> PlanItem? {
        let paths = row.otherCopies.compactMap { planPath($0, in: tree) }
        guard !paths.isEmpty else { return nil }
        let places = paths.map(DiskTree.friendly).joined(separator: ", ")
        return PlanItem(id: PlanItem.otherCopyID(of: row.id), title: "Other copy of \(row.title)", note: row.otherCopiesCaution.map { $0 + " " + places } ?? places, tierRaw: Tier.yourCall.rawValue, paths: paths,
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
                Motion.animate(.easeOut(duration: 0.16)) { self.labels = self.makeLabels() }
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
        Motion.animate(.easeOut(duration: 0.14)) {
            labels = LabelPlacer.place(layout: layout, ring: ring, lens: .freeUp, tree: tree, model: self, only: Array(picks.prefix(7)))
            labelsVisible = true
        }
    }

    /// What's ticked in the picture on screen.
    var planBytesHere: UInt64 {
        guard let tree, focus != 0 else { return planNumbers.total }
        var sum: UInt64 = 0
        for (id, nodes) in planPlaces.nodes where !nodes.isEmpty {
            let inside = nodes.filter { tree.isInside($0, focus) }
            if inside.count == nodes.count { sum &+= planNumbers.byItem[id] ?? 0 }
            else { sum &+= inside.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] } }
        }
        return sum
    }

    /// A click on the ring: this too. A second click takes it back.
    func togglePiece(_ node: UInt32) {
        guard let tree, mayEditPlan() else { return }
        if tree.isGhost(node) {
            showTip("Already moved. Move it back from the Moved list.")
            return
        }
        guard let path = planPath(node, in: tree) else {
            let cantLook = tree.nodes[Int(node)].has(NodeFlag.hidden) || tree.nodes[Int(node)].has(NodeFlag.locked)
            showTip(cantLook ? "Headroom can't read this." : "\(displayName(node)) is part of macOS.")
            return
        }
        let row = isCurrent(tree) ? rowOfNode[node].flatMap { $0 < shownRows.count ? shownRows[$0] : nil } : nil
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
                showTip(row.subtitle.isEmpty ? "\(row.title) can't be selected here." : row.subtitle)
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
            showTip(isFolder ? "\(displayName(node)) is protected. Double-click to open it." : "\(displayName(node)) is protected.")
            return
        }
        plan.add(PlanItem(id: PlanItem.id(pickedByHand: path), title: displayName(node), note: tree.friendlyPath(node), tierRaw: Tier.yourCall.rawValue, paths: [path], byHand: true,
                          lastKnownBytes: tree.totals[Int(node)], diskID: Cleaner.diskID(of: path)))
        planChanged()
    }

    /// A tick on one file in a row that's too small to be on the map, such as one screenshot of many.
    func togglePath(_ path: String, of row: WinRow) {
        guard let tree, mayEditPlan() else { return }
        let path = PathMath.visible(path)
        if plan.covers(path) {
            plan.takeBack(path)
        } else if plan.items.contains(where: { $0.excluded.contains(path) }) {
            for at in plan.items.indices { plan.items[at].excluded.removeAll { $0 == path } }
        } else {
            guard Safety.canTrash(path) else { return }
            var part = item(for: row, in: tree)
            part.paths = [path]
            plan.add(part)
        }
        planChanged()
    }

    func showTip(_ text: String, for seconds: Double = 3.2, offeringUndo: Bool = false) {
        tip = text
        tipOffersUndo = offeringUndo
        tipTask?.cancel()
        tipTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.tip = nil
        }
    }

    /// Take it out of the plan and stop suggesting it.
    func keep(_ row: WinRow) {
        guard mayEditPlan() else { return }
        for part in row.parts { plan.remove(part.id) }
        plan.keep(row.id, title: row.title)
        afterKeeping()
    }

    func keep(item: PlanItem) {
        guard mayEditPlan() else { return }
        plan.keep(item.id, title: item.title)
        afterKeeping()
    }

    func stopKeeping(_ id: String) {
        guard mayEditPlan() else { return }
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
        guard mayEditPlan() else { return }
        plan.remove(item.id)
        refusedRows.insert(item.id)
        planChanged()
    }

    func clearPlan() {
        guard mayEditPlan() else { return }
        clearedItems = plan.items
        plan.items = []
        // Untick everything means everything, the Trash included, until you say otherwise.
        refusedRows.formUnion(clearedItems.map(\.id))
        planChanged()
    }

    func restoreCleared() {
        guard mayEditPlan() else { return }
        for item in clearedItems { plan.add(item) }
        clearedItems = []
        planChanged()
    }

    func setStep(_ step: PlanStep, for id: String) {
        guard mayEditPlan(), let at = plan.items.firstIndex(where: { $0.id == id }) else { return }
        plan.items[at].step = step
        planChanged()
    }

    func acceptChange(for id: String) {
        guard let at = plan.items.firstIndex(where: { $0.id == id }) else { return }
        plan.items[at].acceptedChange = Date()
        savePlan()
        runChecks()
    }

    func acceptInUse(for id: String) {
        guard let at = plan.items.firstIndex(where: { $0.id == id }) else { return }
        plan.items[at].acceptedInUseAt = Date()
        savePlan()
        runChecks()
    }

    func quit(bundleID: String) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        apps.forEach { $0.terminate() }
        Task { [weak self] in
            // Up to six seconds for them to finish quitting.
            var waited = 0
            while waited < 40, apps.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(150))
                waited += 1
            }
            self?.runChecks()
        }
    }

    func alsoPlanOtherCopy(for item: PlanItem) {
        guard let other = otherCopies[item.id], mayEditPlan() else { return }
        plan.add(PlanItem(id: PlanItem.otherCopyID(of: item.id), title: "Other copy of \(item.title)", note: other.title, tierRaw: Tier.yourCall.rawValue, paths: other.paths, lastKnownBytes: other.bytes,
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
        guard !HiddenNames.isOn else { return [] }
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
        guard let tree, isCurrent(tree), mayEditPlan(), row.nodes.count == 1 else { return }
        var planned = item(for: row, in: tree)
        guard let first = planned.paths.first else { return }
        planned.step = .move(folder: moveFolder(for: first, to: disk))
        plan.items.removeAll { $0.id == planned.id }
        plan.add(planned)
        refusedRows.remove(row.id)
        planChanged()
    }

    func planMove(node: UInt32, to disk: DiskChoice) {
        guard let tree, mayEditPlan(), let path = planPath(node, in: tree) else { return }
        if isCurrent(tree), let at = rowOfNode[node], at < shownRows.count, shownRows[at].nodes.count == 1 {
            planMove(shownRows[at], to: disk)
            return
        }
        let folder = moveFolder(for: path, to: disk)
        if let existing = plan.items.first(where: { $0.paths == [path] }) {
            setStep(.move(folder: folder), for: existing.id)
            return
        }
        plan.add(PlanItem(id: PlanItem.id(pickedByHand: path), title: displayName(node), note: tree.friendlyPath(node), tierRaw: Tier.yourCall.rawValue, paths: [path],
                          step: .move(folder: folder), byHand: true, lastKnownBytes: tree.totals[Int(node)], diskID: Cleaner.diskID(of: path)))
        planChanged()
    }

    // MARK: Showing the after

    func setPreviewAfter(_ on: Bool) {
        guard on != previewingAfter, let tree else { return }
        if on, planNumbers.total == 0 || mode != .freeUp || planNumbers.after == nil { return }
        previewingAfter = on
        Motion.animate(.easeOut(duration: 0.12)) { labelsVisible = false }
        if on, let after = planNumbers.after {
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
            expandedFocus = nil
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
                expandedFocus = target
                zoom(into: target)
            }
        }
    }

    func innerNodes(of row: WinRow) -> [UInt32] {
        guard let tree else { return [] }
        if row.nodes.count > 1 { return row.nodes.sorted { tree.totals[Int($0)] > tree.totals[Int($1)] } }
        guard let node = row.nodes.first else { return [] }
        let tail = RingLayout.chainTail(tree: tree, node)
        return tree.children(tail).filter { tree.totals[Int($0)] > 0 }.sorted { tree.totals[Int($0)] > tree.totals[Int($1)] }
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
            let scan = DiskScan(facts: disk, rules: rules, fullAccess: true)
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

}

extension AppModel {
    /// The other copy of something has its own tick, because taking it costs something of its own.
    func toggleOtherCopies(of row: WinRow) {
        guard let tree, isCurrent(tree), mayEditPlan() else { return }
        let paths = row.otherCopies.compactMap { planPath($0, in: tree) }
        if let first = paths.first, plan.covers(first) {
            plan.items.removeAll { $0.id == PlanItem.otherCopyID(of: row.id) }
        } else if let copy = otherCopyItem(of: row, in: tree) {
            plan.add(copy)
        }
        planChanged()
    }

    /// The extra that's yours to choose, such as an app's data.
    func toggleAlso(of row: WinRow) {
        guard let tree, isCurrent(tree), mayEditPlan() else { return }
        let paths = row.alsoNodes.compactMap { planPath($0, in: tree) }
        if let first = paths.first, plan.covers(first) {
            plan.items.removeAll { $0.id == PlanItem.dataID(of: row.id) }
        } else {
            plan.add(PlanItem(id: PlanItem.dataID(of: row.id), title: "\(row.title) data", note: paths.map(DiskTree.friendly).joined(separator: ", "), tierRaw: Tier.yourCall.rawValue, paths: paths,
                              step: row.step == .uninstall ? .uninstall : .trash, bundleID: row.bundleID, lastKnownBytes: row.alsoNodes.reduce(0) { $0 &+ tree.totals[Int($1)] },
                              diskID: paths.first.flatMap(Cleaner.diskID)))
        }
        planChanged()
    }
}
