import AppKit
import SwiftUI

/// Everything that takes things off the disk or brings them back: a clean, a Send to Trash, taking out copies, Undo,
/// and emptying the Trash. The map is only ever changed through `draftTree` and `showDraft`.
extension AppModel {
    // MARK: Clean

    /// Checks everything one last time, then carries out what's ready. What isn't ready stays planned.
    func cleanNow() {
        guard !isCleaning, let tree, !tree.isPartial else { return }
        let items = plan.items
        let bytes = planNumbers.byItem
        let apps = runningApps()
        let tops = planPlaces.nodes.values.flatMap { $0 }
        let excluded = planPlaces.excluded
        let others = otherCopies.mapValues { (title: $0.title, bytes: $0.bytes) }
        let fullAccess = hasFullAccess
        let failedBefore = cleanFailures
        let stop = beginRemoval(CleanProgress(done: 0, total: 0, title: "Checking…"))

        Task.detached(priority: .userInitiated) {
            let result = Self.adding(failedBefore, to: PlanChecks.run(items: items, trueBytes: bytes, otherCopy: others, runningApps: apps, fullAccess: fullAccess, thorough: true))
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
                self.cleanProgress = CleanProgress(done: 0, total: total, title: "Starting…")
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
                            // Every few megabytes copied says so. The window hears of it ten times a second.
                            let pace = Pace()
                            try Cleaner.copyAndVerify(path, into: PlanList.moveDestination(of: path, item: item, folder: folder), stop: stop) { progress in
                                guard pace.isDue() else { return }
                                let update = CleanProgress(done: soFar, total: total, title: "Copying \(name)…", bytesDone: progress.bytesDone, bytesTotal: progress.bytesTotal)
                                Task { @MainActor in if self.cleanProgress != nil { self.cleanProgress = update } }
                            }
                        }
                        moved = try Cleaner.trash(path, step: item.step, stop: stop)
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

    /// A quit that had to wait goes on once nothing is left to wait for: a clean stopped at a safe point, and a new version in
    /// place. Either can end first. What the plan got to is written down last thing.
    func quitWhenNothingIsLeft() {
        guard !Updater.shared.isInstalling, !quitAfterClean || cleanStoppedForQuit else { return }
        savePlan()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: Send to Trash

    /// One thing, right away, without going through the list. It has the same checks and the same way back as a clean. What
    /// you'd get back was said in the menu, so a hard link is no reason to stop here.
    func sendToTrash(_ thing: NamedThing, anyway: Bool = false) {
        guard let node = thing.single, node != 0, let tree, mayEditPlan() else { return }
        guard !tree.isPartial else {
            showTip("Still scanning.")
            return
        }
        let title = displayName(node)
        guard let path = planPath(node, in: tree), let raw = tree.path(node), Safety.canTrash(raw) else {
            showTip("\(title) is protected.")
            return
        }
        let item = PlanItem(id: PlanItem.id(sent: path), title: title, note: tree.friendlyPath(node), tierRaw: Tier.noLoss.rawValue, paths: [path],
                            lastKnownBytes: tree.totals[Int(node)], acceptedInUseAt: anyway ? Date() : nil, diskID: Cleaner.diskID(of: path))
        let apps = runningApps()
        let fullAccess = hasFullAccess
        let stop = beginRemoval(CleanProgress(done: 0, total: 1, title: title))
        Task.detached(priority: .userInitiated) {
            let check = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: apps, fullAccess: fullAccess)[item.id] ?? ItemCheck()
            let share = Accounting.effect(of: [node], except: [], in: tree).perTop
            var reason = check.canGo ? nil : check.problems.first { $0.holdsBack || $0 == .gone }
            var moved: (place: String, identity: String?)?
            if reason == nil {
                do { moved = try Cleaner.trash(path, stop: stop) } catch { reason = Cleaner.whyItFailed(error) }
            }
            let inTrash = moved
            let why = reason
            await MainActor.run {
                // Something using it is yours to overrule, so you're asked, instead of it quietly staying where it is.
                if case .inUse? = why, let raw = tree.path(node) { self.busyToSend = BusyThing(path: raw, title: title, why: why?.text ?? "") }
                self.finishSending(node, item, path: path, moved: inTrash, why: why, share: share, tree: tree)
            }
        }
    }

    // MARK: Taking out copies

    /// What becomes of the copies of a set that aren't kept.
    enum CopyAction: String, CaseIterable {
        case delete, hardlink, symlink

        var title: String {
            switch self {
            case .delete: "Delete"
            case .hardlink: "Hardlink"
            case .symlink: "Symlink"
            }
        }

        fileprivate var replacement: Cleaner.Replacement {
            switch self {
            case .delete: .nothing
            case .hardlink: .hardlink
            case .symlink: .symlink
            }
        }
    }

    /// Deletes the copies of a set that aren't kept, or replaces them with hard links or symlinks to the ones that are. Each
    /// copy is checked as anything cleaned is, read through against the copy kept, and goes to the Trash on record, so Undo
    /// puts it back as it was.
    func takeCopies(_ group: CopyGroup, _ action: CopyAction) {
        guard group.kind == .duplicate, let tree, mayEditPlan(), !isCleaning else { return }
        guard !tree.isPartial else {
            showTip("Still scanning.")
            return
        }
        var pairs: [(node: UInt32, path: String, kept: String, item: PlanItem)] = []
        // Each copy to the kept copy of its own file.
        for (keeper, extra) in group.sets.flatMap({ set in set.extras.map { (set.keeper, $0) } }) {
            guard let path = planPath(extra, in: tree), let raw = tree.path(extra), Safety.canTrash(raw), let kept = tree.path(keeper) else { continue }
            let note = action == .delete ? "Duplicate of \(tree.friendlyPath(keeper))" : "\(action.title) to \(tree.friendlyPath(keeper))"
            pairs.append((extra, path, kept, PlanItem(id: action.rawValue + ":" + path, title: tree.name(extra), note: note,
                                                      tierRaw: (action == .delete ? Tier.yourCall : Tier.noLoss).rawValue, paths: [path],
                                                      lastKnownBytes: tree.totals[Int(extra)], diskID: Cleaner.diskID(of: path))))
        }
        guard !pairs.isEmpty else {
            showTip("These files are protected.")
            return
        }
        let apps = runningApps()
        let fullAccess = hasFullAccess
        let stop = beginRemoval(CleanProgress(done: 0, total: pairs.count, title: group.title))
        let title = group.title
        Task.detached(priority: .userInitiated) {
            var linked: [TakenCopy] = []
            var why: CheckProblem?
            for (at, pair) in pairs.enumerated() {
                if stop.value { break }
                let check = PlanChecks.run(items: [pair.item], trueBytes: [:], otherCopy: [:], runningApps: apps, fullAccess: fullAccess)[pair.item.id] ?? ItemCheck()
                if !check.canGo, let problem = check.problems.first(where: { $0.holdsBack || $0 == .gone }) {
                    why = problem
                    continue
                }
                do {
                    let moved = try Cleaner.replaceCopy(pair.path, of: pair.kept, with: action.replacement, stop: stop)
                    linked.append(TakenCopy(node: pair.node, path: pair.path, item: pair.item, place: moved.place, identity: moved.identity,
                                            linkedTo: action == .delete ? nil : pair.kept))
                } catch Cleaner.Failure.linkFailed(let left?) {
                    // In the Trash with nothing in its place: on record as that, so Undo brings it back.
                    linked.append(TakenCopy(node: pair.node, path: pair.path, item: pair.item, place: left.place, identity: left.identity, linkedTo: nil))
                    why = Cleaner.whyItFailed(Cleaner.Failure.linkFailed(leftInTrash: left))
                } catch {
                    why = Cleaner.whyItFailed(error)
                }
                let done = at + 1
                await MainActor.run { self.cleanProgress?.done = done }
            }
            let share = Accounting.effect(of: linked.map(\.node), except: [], in: tree).perTop
            let finished = linked, problem = why
            await MainActor.run { self.finishTaking(finished, action, why: problem, share: share, tree: tree, title: title) }
        }
    }

    /// A copy that went to the Trash, and the path a link to took its place, if one did.
    struct TakenCopy: Sendable {
        var node: UInt32
        var path: String
        var item: PlanItem
        var place: String
        var identity: String?
        var linkedTo: String?
    }

    private func finishTaking(_ linked: [TakenCopy], _ action: CopyAction, why: CheckProblem?, share: [UInt32: UInt64], tree: DiskTree, title: String) {
        cleanProgress = nil
        if linked.isEmpty {
            showTip("Nothing changed. \(why?.text ?? "")", for: 6)
        } else {
            for l in linked {
                didMove(l.path, to: l.place, identity: l.identity, item: l.item, trueBytes: share, tree: tree, linkedTo: l.linkedTo)
            }
            putOnRecord(takePending())
            for l in linked where plan.covers(l.path) { plan.takeBack(l.path) }
            rescanWhenBack = true
            refreshShownRows()
            showWhatLeft(of: tree)
            let copies = linked.count == 1 ? "1 copy" : "\(linked.count) copies"
            let left = why.map { " Skipped some: \($0.text)" } ?? ""
            let done = switch action {
            case .delete: "Moved \(copies) of \(title) to the Trash."
            case .hardlink: "Hardlinked \(copies) of \(title)."
            case .symlink: "Symlinked \(copies) of \(title)."
            }
            showTip(done + left, for: 8, offeringUndo: true)
        }
        endRemoval()
    }

    /// You were told what's using it, and it goes anyway. The map may have been read again while you were deciding.
    func sendAnyway(_ busy: BusyThing) {
        guard let tree, let node = tree.find(path: busy.path) else {
            showTip("\(busy.title) is no longer there.")
            return
        }
        sendToTrash(NamedThing(node), anyway: true)
    }

    private func finishSending(_ node: UInt32, _ item: PlanItem, path: String, moved: (place: String, identity: String?)?, why: CheckProblem?, share: [UInt32: UInt64], tree: DiskTree) {
        cleanProgress = nil
        if let moved {
            // The card moves on to what's next, so that you can go through a whole row of things.
            let looking = look?.node == node ? look : nil
            let next = looking == nil ? nil : LookContents.next(after: node, in: tree)
            didMove(path, to: moved.place, identity: moved.identity, item: item, trueBytes: share, tree: tree)
            putOnRecord(takePending())
            if plan.covers(path) { plan.takeBack(path) }
            rescanWhenBack = true
            refreshShownRows()
            showWhatLeft(of: tree)
            let there = (moved.place as NSString).lastPathComponent
            showTip("Moved to Trash: \(item.title)" + (there == (path as NSString).lastPathComponent ? "" : " (shown as \(there))"), for: 8, offeringUndo: true)
            if let looking {
                if let next {
                    if look == nil { openLook(next, onLeft: looking.onLeft) } else { showInLook(next, steppingIn: false) }
                } else {
                    closeLook()
                }
            }
        } else if busyToSend == nil {
            showTip("\(item.title) wasn't moved. \(why?.text ?? "")", for: 6)
        }
        endRemoval()
    }

    /// The Undo button under the ring, and ⌘Z. While you're typing, ⌘Z means what it means in any text field.
    func undoCommand() {
        if mapView?.window?.firstResponder is NSText {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            return
        }
        guard let after = afterClean, after.state == .waiting, !after.things.isEmpty, mayEditPlan() else { return }
        undoClean()
        showTip(after.things.count == 1 ? "Put back: \(after.things[0].title)" : "Put back \(after.things.count) items")
    }

    // MARK: What a clean, a Send to Trash and taking out copies share

    func runningApps() -> [PlanChecks.RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            return PlanChecks.RunningApp(bundleID: id, name: app.localizedName ?? id)
        }
    }

    /// Things are about to leave the disk. Nothing replaces the map meanwhile: a running scan stops, and the disk is read
    /// again afterwards, at full power if you were waiting for it. The flag stops the work between one thing and the next.
    private func beginRemoval(_ progress: CleanProgress) -> LockedFlag {
        // Ghosts are for looking at: what's leaving is taken out of the real map.
        dropGhosts()
        factsOfSavedMap = false
        // What was said about the last clean is over now.
        message = nil
        if isScanning {
            scanOnceCleaned(hurry: scanIsHurrying)
            stopScan()
        }
        stopChecks()
        cleanProgress = progress
        // A clean that's waiting to be emptied stays on record: this one joins it.
        if afterClean == nil {
            takenOut = []
            lastPlanItems = []
        }
        pendingCleaned = []
        let stop = LockedFlag()
        cleanStop = stop
        return stop
    }

    /// What has gone to the Trash since `beginRemoval`.
    private func takePending() -> [CleanedThing] {
        defer { pendingCleaned = [] }
        return pendingCleaned
    }

    /// What's now in the Trash and can come back or be emptied, joined to a clean that's still waiting for that.
    private func putOnRecord(_ things: [CleanedThing], oldTrashItems: [String] = [], oldTrashBytes: UInt64 = 0, failed: Int = 0, heldBack: Int = 0) {
        var all = things
        var old = oldTrashItems
        var oldBytes = oldTrashBytes
        var bytes = things.reduce(UInt64(0)) { $0 &+ $1.bytes } &+ oldTrashBytes
        if let waiting = afterClean, waiting.state == .waiting {
            all = waiting.things + things
            old += waiting.oldTrashItems
            oldBytes &+= waiting.oldTrashBytes
            bytes &+= waiting.bytes
        }
        afterClean = AfterClean(things: all, bytes: bytes, includesOldTrash: !old.isEmpty, oldTrashBytes: oldBytes, oldTrashItems: old, failed: failed, heldBack: heldBack)
    }

    /// They've gone, or didn't. What's still planned is looked at again, the plan is written down, and a quit or a scan that
    /// was waiting goes ahead.
    private func endRemoval() {
        if !plan.isEmpty { runChecks() }
        savePlan()
        if quitAfterClean {
            cleanStoppedForQuit = true
            quitWhenNothingIsLeft()
            return
        }
        runScanAfterClean()
    }

    /// The map with what has left it, or come back, since it was last shown, and everything worked out from it again.
    private func showWhatLeft(of cleaned: DiskTree?) {
        showDraft()
        guard let tree, isOnScreen(cleaned) else { return }
        treeVersion += 1
        resolvePlanSynchronously(in: tree)
        rebuildInsights()
        relayout(.settle)
        if isSearching { runSearch() }
    }

    /// The same while things are still going: each one visibly goes, without the ring being rebuilt thousands of times.
    private func showProgress(of cleaned: DiskTree?) {
        let now = Date()
        guard now.timeIntervalSince(lastCleanFrame) > 0.1, isOnScreen(cleaned), showDraft(), let tree else { return }
        lastCleanFrame = now
        engine.apply(drawing(tree), .live)
    }

    private func didMove(_ path: String, to inTrash: String, identity: String?, item: PlanItem, trueBytes: [UInt32: UInt64], tree cleaned: DiskTree,
                         linkedTo: String? = nil, note: String? = nil) {
        // On record first, whatever else is going on: this is what makes it possible to bring it back.
        var thing = CleanedThing(itemID: item.id, title: item.title, original: path, inTrash: inTrash, bytes: 0, identity: identity)
        thing.linkedTo = linkedTo
        thing.note = note
        if let tree, isOnScreen(cleaned), let node = planPlaces.node(at: path, in: tree) {
            thing.bytes = takeOut(node, trueBytes: trueBytes[node])
        } else {
            // On another disk, it's not on this map. This is the size it had when it was planned.
            thing.bytes = item.lastKnownBytes / UInt64(max(item.paths.count, 1))
        }
        pendingCleaned.append(thing)
        let now = Date()
        if now.timeIntervalSince(lastCleanSave) > 0.5 {
            lastCleanSave = now
            savePlan()
        }
        showProgress(of: cleaned)
    }

    private func finishClean(work: [(item: PlanItem, paths: [String])], goneIDs: [String], failed: [String: [String]], oldTrashItems: [String], oldTrashBytes: UInt64, stoppedEarly: Bool, tree: DiskTree) {
        cleanProgress = nil
        let things = takePending()
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
        if let old = plan.item(PlanItem.trashID), oldTrash || checks[PlanItem.trashID]?.canGo == true {
            cleanedItems.append(old)
            plan.items.removeAll { $0.id == PlanItem.trashID }
        }
        lastPlanItems += cleanedItems
        let failures = failed.values.reduce(0) { $0 + $1.count }
        if !things.isEmpty || oldTrash {
            putOnRecord(things, oldTrashItems: oldTrashItems, oldTrashBytes: oldTrashBytes, failed: failures, heldBack: heldBack)
        } else if failures > 0 {
            message = failures == 1 ? "1 item couldn't be moved to the Trash. Details in Free Up." : "\(failures) items couldn't be moved to the Trash. Details in Free Up."
        }
        rescanWhenBack = true
        refreshShownRows()
        showWhatLeft(of: tree)
        cleanFailures = cleanFailures.filter { plan.item($0.key) != nil }
        endRemoval()
    }

    /// Puts everything back where it was, and the list back as it was, so it can be fixed and run again.
    func undoClean() {
        guard let after = afterClean, after.state == .waiting, mayEditPlan() else { return }
        let things = after.things
        let items = lastPlanItems
        let backupItems = lastBackupItems
        lastBackupItems = []
        let hadMoves = items.contains(where: \.isMove) || things.contains { $0.note != nil }
        afterClean = nil
        cleanFailures = [:]
        // Until everything is back, nothing else starts, and quitting waits.
        isPuttingBack = true
        Task.detached(priority: .userInitiated) {
            var failed = 0
            var notesGone: [String] = []
            for thing in things.reversed() {
                do {
                    try Cleaner.putBack(thing)
                    // The file is back where its note was, so the note has nothing left to say.
                    if let note = thing.note, Cleaner.mayAct(on: note), MovedNote.isNote(note) {
                        unlink(note)
                        notesGone.append(note)
                    }
                } catch { failed += 1 }
            }
            let failures = failed
            let gone = notesGone
            await MainActor.run {
                for item in items {
                    self.plan.remove(item.id)
                    self.plan.items.append(item)
                }
                if !gone.isEmpty {
                    self.movedNotes.removeAll { gone.contains($0.notePath) }
                    self.backup.notes.removeAll { gone.contains($0) }
                    // What was moved is selected for Backup again, so it can be moved again, or not.
                    for item in backupItems where !self.backup.has(item.path) && gone.contains(MovedNote.notePath(for: item.path)) {
                        self.backup.items.append(item)
                    }
                    self.saveBackup()
                }
                self.isPuttingBack = false
                if self.quitAfterClean {
                    self.cleanStoppedForQuit = true
                    self.quitWhenNothingIsLeft()
                    return
                }
                if failures > 0 {
                    self.message = failures == 1 ? "1 item couldn't be put back. It's still in the Trash." : "\(failures) items couldn't be put back. They're still in the Trash."
                } else if hadMoves {
                    self.message = "Everything is back. The copies on the other disk remain."
                }
                self.refreshShownRows()
                if failures == 0, self.putBackWhatWasTakenOut() {
                    // Back to the picture it was: nothing needs reading again.
                    self.showWhatLeft(of: self.tree)
                    self.savePlan()
                    self.rescanWhenBack = true
                    if self.isScanning { self.restartScan() }
                } else {
                    // This map was drawn after those things had gone, so the disk has to be read again.
                    self.savePlan()
                    if let tree = self.tree { self.resolvePlanSynchronously(in: tree) }
                    self.restartScan()
                }
                // A scan asked for meanwhile joins the one that's running, or starts now.
                self.runScanAfterClean()
            }
        }
    }

    /// Leaves everything in the Trash and carries on. It shows up as what's already in the Trash from here on.
    func leaveInTrash() {
        guard mayEditPlan() else { return }
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
        guard !isCleaning, var after = afterClean, after.state == .waiting else { return }
        message = nil
        after.state = .emptying
        afterClean = after
        // Nothing replaces the map while things are leaving it. The disk is read again afterwards.
        if isScanning {
            scanOnceCleaned(hurry: scanIsHurrying)
            stopScan()
        }
        let stop = LockedFlag()
        cleanStop = stop
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
                // Quitting stops it between one thing and the next. What hasn't gone stays in the Trash, still on record.
                if stop.value { return await MainActor.run { self.emptyingStopped() } }
                do {
                    if try Cleaner.deleteForGood(thing) {
                        didDelete = true
                        await MainActor.run { self.didEmpty(thing.bytes, tree: tree) }
                    }
                } catch {
                    failed += 1
                }
            }
            if stop.value { return await MainActor.run { self.emptyingStopped() } }
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
                    if Double(got) >= Double(expected) * 0.98 || stop.value { break }
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
        guard isOnScreen(tree) else { return }
        moveFromTrashToFree(bytes)
        showProgress(of: tree)
    }

    /// Quitting stopped the emptying between one thing and the next. What hasn't gone waits in the Trash again, on record,
    /// to be emptied another time.
    private func emptyingStopped() {
        let fm = FileManager.default
        if var after = afterClean {
            after.things = after.things.filter { fm.fileExists(atPath: $0.inTrash) }
            after.oldTrashItems = after.oldTrashItems.filter { fm.fileExists(atPath: $0) }
            if after.oldTrashItems.isEmpty { after.oldTrashBytes = 0 }
            after.includesOldTrash = !after.oldTrashItems.isEmpty
            after.bytes = after.things.reduce(0) { $0 &+ $1.bytes } &+ after.oldTrashBytes
            after.state = .waiting
            afterClean = after.things.isEmpty && after.oldTrashItems.isEmpty ? nil : after
        }
        savePlan()
        if quitAfterClean {
            cleanStoppedForQuit = true
            quitWhenNothingIsLeft()
            return
        }
        runScanAfterClean()
    }

    private func finishEmpty(got: UInt64, oldTrash: UInt64, failed: Int, tree: DiskTree?) {
        if var after = afterClean {
            after.state = .done(got: got)
            after.notDeleted = failed
            afterClean = after
        }
        if isOnScreen(tree) {
            moveFromTrashToFree(oldTrash)
            showDraft()
            treeVersion += 1
            if let shown = self.tree { engine.apply(drawing(shown), .settle) }
        }
        takenOut = []
        lastPlanItems = []
        savePlan()
        rescanWhenBack = false
        if quitAfterClean {
            cleanStoppedForQuit = true
            quitWhenNothingIsLeft()
            return
        }
        // A short look at what you got, then the disk is read again so the numbers are exact: quietly, unless you asked for
        // a scan meanwhile.
        scanOnceCleaned()
        runScanAfterClean()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(failed > 0 ? 16 : 9))
            guard let self, case .done = self.afterClean?.state else { return }
            self.afterClean = nil
        }
    }

    // MARK: Moving to a drive

    /// Copies what Backup has selected to its drive, one file at a time, proving every copy before anything else happens.
    /// A move then leaves a note where each file was and sends the file to the Trash, on record like a clean, so Undo puts
    /// it back and emptying the Trash frees the space. A copy leaves the Mac as it was. It stops between files, and a file
    /// it's halfway through is left out whole: the original isn't touched until its copy is proved.
    func runBackup(copyOnly: Bool) {
        guard !isCleaning, let tree = workTree, !tree.isPartial, let destination = backup.destination else { return }
        guard let drive = connected(destination.drive) else {
            showTip("Connect \(destination.drive.name) first.")
            return
        }
        let ready = backupReady()
        guard !ready.items.isEmpty else {
            showTip(ready.problem ?? "Nothing selected for Backup.")
            return
        }
        let items = ready.items
        let root = BackupDestination(drive: drive, folder: destination.folder).root
        let job = DriveJob(kind: copyOnly ? .copy : .move, title: (copyOnly ? "Copying to " : "Moving to ") + drive.name, driveName: drive.name,
                           entries: items.map { DriveJob.Entry(id: $0.path, title: $0.title, bytes: $0.bytes) })
        // The card it's shown on carries on from the one that was selected: the drive's room, what frees nothing, who picked it.
        job.room = DriveJob.Room(place: "\(destination.title) › \(BackupPaths.macFolder)", capacity: drive.capacity, free: drive.free)
        job.freesNothing = backupSummary().freesNothing
        job.agent = items.compactMap(\.agent).first
        let stop = copyOnly ? job.stop : beginRemoval(CleanProgress(done: 0, total: items.count, title: job.title))
        if !copyOnly {
            // Stopping the job stops the removal between files, and the other way round.
            cleanStop = job.stop
        }
        lastBackupItems = copyOnly ? [] : items
        driveJob = job
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: job.title)
        Task.detached(priority: .userInitiated) {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            // Something an app has open, a film that's playing, say, stays: taking it away would break what's using it.
            let open = copyOnly ? nil : OpenFiles.snapshot()
            for (index, item) in items.enumerated() {
                if job.stop.value || stop.value { break }
                await MainActor.run { job.begin(index) }
                if let users = open?.users(of: item.path) {
                    let who = users.first.process
                    await MainActor.run { job.finish(index, .failed("In use by \(who).")) }
                    continue
                }
                let target = BackupPaths.onDrive(item.path, under: root)
                var last = Date.distantPast
                let report: (DriveMover.Progress) -> Void = { p in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.1 || p.bytes == p.of else { return }
                    last = now
                    Task { @MainActor in job.progress(index, phase: p.phase, bytes: p.bytes, of: p.of) }
                }
                // What it frees, worked out before it goes: a file with another hard link frees nothing until that goes too.
                let node = tree.find(path: item.path) ?? tree.find(visible: item.path)
                let share = node.map { Accounting.effect(of: [$0], except: [], in: tree).perTop } ?? [:]
                let sent: (copied: DriveMover.Copied, note: MovedNote?)
                do {
                    sent = try DriveMover.send(item.path, to: target, drive: drive, writeNote: !copyOnly, stop: job.stop, progress: report)
                } catch {
                    let failure = (error as? DriveMover.Failure) ?? .io(error.localizedDescription)
                    await MainActor.run { job.finish(index, failure == .stopped ? .stopped : .failed(failure.text)) }
                    // Without its drive nothing else can go either.
                    if !FileManager.default.fileExists(atPath: drive.mountPath) { break }
                    continue
                }
                if copyOnly {
                    let said = sent.copied.wasThere ? "Already on \(drive.name)" : "Copied"
                    await MainActor.run {
                        job.finish(index, .done(said))
                        self.backup.items.removeAll { $0.path == item.path }
                        // No note for a copy: its hash is kept with Backup's own things, on the Mac.
                        self.recordCopy(target, on: drive, hash: sent.copied.hash, size: sent.copied.size)
                    }
                    continue
                }
                guard let note = sent.note else { continue }
                do {
                    let moved = try Cleaner.trash(item.path)
                    await MainActor.run {
                        let plan = PlanItem(id: "backup:" + item.path, title: item.title, note: drive.name, tierRaw: Tier.yourCall.rawValue, paths: [item.path],
                                            lastKnownBytes: item.bytes)
                        self.didMove(item.path, to: moved.place, identity: moved.identity, item: plan, trueBytes: share, tree: tree, note: note.notePath)
                        self.backup.items.removeAll { $0.path == item.path }
                        self.movedNotes.removeAll { $0.notePath == note.notePath }
                        self.movedNotes.append(note)
                        if !self.backup.notes.contains(note.notePath) { self.backup.notes.append(note.notePath) }
                        job.finish(index, .done(sent.copied.wasThere ? "Already on \(drive.name)" : "Moved"))
                    }
                } catch {
                    // The copy is proved and stays on the drive, but the original couldn't go, so it's on both, and no note
                    // may say otherwise.
                    unlink(note.notePath)
                    await MainActor.run { self.recordCopy(target, on: drive, hash: sent.copied.hash, size: sent.copied.size) }
                    let why = Cleaner.whyItFailed(error).text
                    await MainActor.run { job.finish(index, .failed("Copied, but the original couldn't go to the Trash. \(why)")) }
                }
            }
            await MainActor.run {
                job.end()
                self.saveBackup()
                if !copyOnly {
                    self.cleanProgress = nil
                    self.putOnRecord(self.takePending())
                    self.rescanWhenBack = true
                    self.refreshShownRows()
                    self.endRemoval()
                    self.showWhatLeft(of: tree)
                    let moved = job.doneCount
                    if moved > 0 { self.showTip(job.summary, for: 10, offeringUndo: true) }
                } else {
                    self.showTip(job.summary, for: 8)
                    // A quit was waiting for the copy to stop at a safe point.
                    if self.quitAfterClean {
                        self.cleanStoppedForQuit = true
                        self.quitWhenNothingIsLeft()
                        return
                    }
                }
                self.refreshDrives()
                self.applyGhosts()
            }
        }
    }
}
