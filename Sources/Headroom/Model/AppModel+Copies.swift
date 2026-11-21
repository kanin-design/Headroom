import Foundation

extension AppModel {
    /// Copies' answer for the tree on screen. Hard links and clones are already in the map, and aliases are read from the few
    /// folders that hold one, so those show at once. Duplicates are looked for only now, never at launch: groups remembered from
    /// an earlier search come back unread, and the rest are read biggest first, showing as they're found.
    func refreshCopies() {
        // In Backup the third view is Backed Up, and nothing is read for duplicates.
        guard view == .copies, mode == .freeUp, let tree, !tree.isPartial else { return }
        if let copies, copies.scanID == tree.scanID, copies.duplicatesDone { return }
        // Already looking, in this scan's numbering.
        if copiesReading, copiesScanID == tree.scanID { return }
        copiesStop?.value = true
        let stop = LockedFlag()
        copiesStop = stop
        copiesScanID = tree.scanID
        copiesReading = true
        copiesBytesRead = 0
        copiesGroupsDone = 0
        copiesGroupsTotal = 0
        let rules = self.rules
        let memory = duplicateMemory
        let kept = keptCopies
        let colours = copyColours
        let started = Date()
        let scanID = tree.scanID
        Task { [weak self] in
            let first = await Task.detached(priority: .userInitiated) { () -> (aliases: [Aliases.Found], work: [Duplicates.Work], known: [Duplicates.Found], read: [Int]) in
                let aliases = Aliases.find(in: tree, rules: rules, stop: stop)
                let work = Duplicates.work(in: tree, rules: rules)
                var known: [Duplicates.Found] = []
                var read: [Int] = []
                for (at, w) in work.enumerated() {
                    if let sets = memory.recall(w) { known += sets } else { read.append(at) }
                }
                return (aliases, work, known, read)
            }.value
            let firstMap = await Task.detached(priority: .userInitiated) {
                CopiesMap.build(tree: tree, duplicates: first.known, aliases: first.aliases, duplicatesDone: first.read.isEmpty, kept: kept, colours: colours)
            }.value
            guard let self else { return }
            guard !stop.value, self.tree?.scanID == scanID else { self.copiesEnded(stop); return }
            self.copiesFound = first.known
            self.copiesAliasesFound = first.aliases
            self.copiesRemembered = first.work.count - first.read.count
            self.copiesGroupsTotal = first.read.count
            self.showCopies(firstMap)

            let toRead = first.read.map { first.work[$0] }
            let progress = Duplicates.Progress(groupsTotal: toRead.count)
            let found = FoundSets()
            let finished = LockedFlag()
            Task.detached(priority: .userInitiated) {
                Duplicates.find(toRead, threads: Self.copyThreadCount, stop: stop, progress: progress) { at, sets in
                    memory.note(toRead[at], found: sets)
                    found.add(sets)
                }
                finished.value = true
            }
            // The panel and the ring follow along, a few times a second.
            var shown = 0
            var looks = 0
            while true {
                let done = finished.value
                // Quickly at first, so the first sets are there at once, then once a second: each look makes the whole
                // map of copies again.
                if !done { try? await Task.sleep(for: .milliseconds(looks < 3 ? 300 : 1000)) }
                looks += 1
                guard !stop.value, self.tree?.scanID == scanID else { self.copiesEnded(stop); return }
                self.copiesBytesRead = progress.bytesRead.load(ordering: .relaxed)
                self.copiesGroupsDone = progress.groupsDone.load(ordering: .relaxed)
                let sets = found.all
                if done || sets.count != shown {
                    shown = sets.count
                    // Worked out off the main thread, so the window never waits for it.
                    let kept = self.keptCopies, colours = self.copyColours
                    let map = await Task.detached(priority: .userInitiated) {
                        CopiesMap.build(tree: tree, duplicates: first.known + sets, aliases: first.aliases, duplicatesDone: done, kept: kept, colours: colours)
                    }.value
                    guard !stop.value, self.tree?.scanID == scanID else { self.copiesEnded(stop); return }
                    self.copiesFound = first.known + sets
                    self.showCopies(map)
                }
                if done { break }
            }
            self.copiesSeconds = Date().timeIntervalSince(started)
            memory.save(keeping: Set(first.work.flatMap { $0.files.map(\.path) }))
            self.copiesEnded(stop)
        }
    }

    /// Only the search that's still the current one says reading has stopped. One stopped because the map changed under it
    /// makes way for a search of the new map.
    private func copiesEnded(_ stop: LockedFlag) {
        guard copiesStop === stop else { return }
        copiesStop = nil
        copiesReading = false
        if view == .copies, let tree, copies?.scanID != tree.scanID || copies?.duplicatesDone == false { refreshCopies() }
    }

    /// A few threads: the disk is the limit, and more only fight over it.
    nonisolated static var copyThreadCount: Int { min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    func stopCopies() {
        copiesStop?.value = true
        copiesStop = nil
        copiesReading = false
    }

    private func showCopies(_ map: CopiesMap) {
        copies = map
        copyColours.merge(map.colourOf) { _, new in new }
        refreshCopyGroups()
        if view == .copies { relayout(.recolor) }
    }

    /// The groups that touch the folder in view: the list, like every list in the inspector, follows the zoom.
    func refreshCopyGroups() {
        guard let tree, let copies, copies.scanID == tree.scanID else {
            copyGroupsHere = []
            return
        }
        let root = focus == 0 ? 0 : RingLayout.chainTail(tree: tree, focus)
        copyGroupsHere = copies.groups(under: root, in: tree)
    }

    /// The sets worked out again from what the last search found, with nothing read: after something went to the Trash or came
    /// back, or you picked a different copy to stay.
    func rebuildCopies() {
        guard let tree, let copies, copies.scanID == tree.scanID else { return }
        let found = copiesFound, aliases = copiesAliasesFound, kept = keptCopies, done = copies.duplicatesDone, colours = copyColours
        Task { [weak self] in
            let map = await Task.detached(priority: .userInitiated) {
                CopiesMap.build(tree: tree, duplicates: found, aliases: aliases, duplicatesDone: done, kept: kept, colours: colours)
            }.value
            guard let self, self.tree === tree else { return }
            self.showCopies(map)
        }
    }

    /// Lights where these copies are on the ring: each one's own piece, or when it's too small to draw, the piece that holds
    /// it, lit as fully as the copy itself would be, so every place shows. A folder lights with what's in it, and the folders
    /// on the way out light a little, as anything's do. `primary` stands out from the rest.
    private func lightCopies(_ nodes: [UInt32], primary: UInt32? = nil, of group: CopyGroup) {
        chart.highlight(nodes.filter { $0 != 0 }, primary: primary, tint: group.colour.linearP3, gathered: .shown)
    }

    /// How many of a set's copies are outside the folder in view, where the ring can't show them.
    func copiesOutside(_ group: CopyGroup) -> Int {
        guard let tree, focus != 0 else { return 0 }
        let root = RingLayout.chainTail(tree: tree, focus)
        return group.nodes.filter { $0 != 0 && !tree.isInside($0, root) }.count
    }

    /// The set of copies a piece on the ring holds, in Copies while freeing up: its row in the inspector lights with it.
    func copySet(at p: Piece) -> CopyGroup? {
        guard view == .copies, mode == .freeUp, let tree, let copies, copies.scanID == tree.scanID, !p.isSmaller, !p.role.isSpace else { return nil }
        return copies.set(of: p.node)
    }

    /// Points at a row in the inspector: every copy lights up on the ring in the set's colour, and so does the way out to each
    /// one, however small it is there, and the names around the ring say where each one is.
    func pointAtCopyGroup(_ group: CopyGroup?) {
        guard pointedCopyGroup != group?.id || pointedCopy != 0 || group == nil else { return }
        pointedCopy = 0
        guard let group else {
            hotCopyGroup = nil
            pointedCopyGroup = nil
            highlight(nodes: [])
            chart.relabel(after: 0.05)
            return
        }
        lightCopies(group.nodes, of: group)
        hotCopyGroup = group.id
        pointedCopyGroup = group.id
        chart.relabel(after: 0.05)
    }

    /// Points at one copy in an open set: it stands out, and the other copies of the same file light with it, so you can see
    /// which is which and where the others are.
    func pointAtCopy(_ node: UInt32, of group: CopyGroup) {
        let isFolder = tree?.nodes[Int(node)].has(NodeFlag.directory) == true
        let set = isFolder ? nil : group.sets.first { $0.keeper == node || $0.extras.contains(node) }
        let others = set.map { [$0.keeper] + $0.extras } ?? [node]
        // A folder lights all of what's in it; a file stands out from the copies lit with it.
        lightCopies(others, primary: isFolder ? nil : node, of: group)
        pointedCopy = node
        hotCopyGroup = group.id
        if pointedCopyGroup != group.id {
            pointedCopyGroup = group.id
            chart.relabel(after: 0.05)
        }
    }

    /// You picked the copy that stays, or for a row of many files, the folder that keeps them: it does from now on, whatever
    /// the rules would pick.
    func keepCopy(_ node: UInt32, of group: CopyGroup) {
        guard let tree, let path = tree.path(node) else { return }
        // A folder decides for the whole row. A file only for its own set: the other sets in the row keep their own choice.
        var undecided = group.nodes + group.homes + [group.home] + group.others
        if !tree.nodes[Int(node)].has(NodeFlag.directory), let set = group.sets.first(where: { $0.keeper == node || $0.extras.contains(node) }) {
            undecided = [set.keeper] + Array(set.extras)
        }
        for other in undecided where other != 0 {
            if let p = tree.path(other) { keptCopies.remove(p) }
        }
        keptCopies.insert(path)
        Self.saveKeptCopies(keptCopies)
        rebuildCopies()
    }

    private static var keptCopiesFile: URL { AppData.folder.appendingPathComponent("copies-kept.json") }

    static func loadKeptCopies() -> Set<String> {
        Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: keptCopiesFile))) ?? [])
    }

    static func saveKeptCopies(_ paths: Set<String>) {
        let list = Array(paths).sorted(), file = keptCopiesFile
        Saves.write(list, to: file)
    }

    // MARK: Taking the extra copies

    /// The copies a duplicates row would send to the Trash: all but the one that stays.
    func extraPaths(of group: CopyGroup) -> [(node: UInt32, path: String)] {
        guard let tree else { return [] }
        return group.extras.compactMap { node in planPath(node, in: tree).map { (node, $0) } }
    }

    func duplicateTick(_ group: CopyGroup) -> TickState {
        let extras = group.extras
        guard !extras.isEmpty else { return .none }
        let planned = extras.filter { isPlanned($0) }.count
        return planned == 0 ? .none : (planned == extras.count ? .all : .some)
    }

    /// Ticks or unticks a duplicates row: its extra copies go into the plan as things picked by hand, each saying which copy
    /// stays. The one button does the rest, as for anything else, so they go to the Trash, and Undo brings them back.
    func toggleDuplicate(_ group: CopyGroup) {
        guard let tree, mayEditPlan(), group.kind == .duplicate else { return }
        let extras = extraPaths(of: group)
        if duplicateTick(group) == .all {
            for e in extras { plan.takeBack(e.path) }
            planChanged()
            return
        }
        for e in extras where !isPlanned(e.node) {
            guard Safety.canTrash(e.path), let keeper = group.keeper(of: e.node) else { continue }
            plan.add(PlanItem(id: PlanItem.id(pickedByHand: e.path), title: tree.name(e.node), note: "Duplicate of \(tree.friendlyPath(keeper))", tierRaw: Tier.yourCall.rawValue,
                              paths: [e.path], byHand: true, lastKnownBytes: tree.totals[Int(e.node)], diskID: Cleaner.diskID(of: e.path)))
        }
        planChanged()
    }
}

/// Sets found by the reading threads, collected for the main thread.
private final class FoundSets: @unchecked Sendable {
    private let lock = NSLock()
    private var sets: [Duplicates.Found] = []
    func add(_ more: [Duplicates.Found]) {
        guard !more.isEmpty else { return }
        lock.lock()
        sets += more
        lock.unlock()
    }
    var all: [Duplicates.Found] {
        lock.lock()
        defer { lock.unlock() }
        return sets
    }
}
