import AppKit
import Foundation

/// Backup: big files moved, or copied, to another drive, with a note left where each moved one was. It has a list of its
/// own, apart from Free Up's: a file is on one of them at a time, and each list only ever does its own thing.
extension AppModel {
    // MARK: Remembering

    func loadBackup() {
        guard !HiddenNames.isOn else { return }
        backup = BackupStore.load()
        refreshDrives()
        refreshNotes()
    }

    func saveBackup() {
        guard !HiddenNames.isOn else { return }
        BackupStore.save(backup)
    }

    // MARK: Drives

    func refreshDrives() {
        let now = DriveInfo.connected()
        if now != drives { drives = now }
        // A drive that's back, perhaps renamed or mounted somewhere else, is the same drive by its ID.
        if let wanted = backup.destination?.drive, let found = connected(wanted), found != wanted {
            backup.destination?.drive = found
            for at in backup.knownDrives.indices where backup.knownDrives[at].isSame(as: found) { backup.knownDrives[at] = found }
        }
        readBackupFolderOnce()
    }

    /// The whole of this Mac's backup folder on the drive, read once each time it's plugged in, so its half can be drawn
    /// for any folder while it's unplugged. It's Backup's own folder, so it's quick.
    private func readBackupFolderOnce() {
        guard let destination = backup.destination, let drive = connected(destination.drive), !backupFoldersRead.contains(drive.id) else {
            // Unplugged: read again when it's back.
            if let destination = backup.destination, connected(destination.drive) == nil { backupFoldersRead.remove(destination.drive.id) }
            return
        }
        backupFoldersRead.insert(drive.id)
        let root = BackupPaths.onDrive("/", under: BackupDestination(drive: drive, folder: destination.folder).root)
        let folder = root.hasSuffix("/") ? String(root.dropLast()) : root
        let id = drive.id, fromTop = BackupPaths.fromDriveTop(folder, mount: drive.mountPath)
        Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: folder), let files = DriveListings.read(folder) else { return }
            DriveListings.record(id, folder: fromTop, files: files)
        }
    }

    /// A folder as Backup's cards name it: on this Mac as you'd say it, and in the backup folder on the drive as the Mac's
    /// folder it mirrors.
    func shownFolder(_ folder: String) -> String {
        guard let destination = backup.destination else { return DiskTree.friendly(folder) }
        let root = BackupPaths.onDrive("/", under: destination.root)
        let top = root.hasSuffix("/") ? String(root.dropLast()) : root
        return folder.hasPrefix(top + "/") ? DiskTree.friendly(String(folder.dropFirst(top.count))) : DiskTree.friendly(folder)
    }

    /// Whether a file on the Mac is on the drive too, by the picture of both disks.
    func isBackedUp(_ path: String) -> Bool {
        guard let pair, let node = pair.macNode(for: path) else { return false }
        return pair.places[node] == .both
    }

    /// The drive as it's connected now, if it is.
    func connected(_ drive: DriveInfo) -> DriveInfo? { drives.first { $0.isSame(as: drive) } }

    /// The drive the map is of.
    var sourceDrive: DriveInfo? { volume.flatMap { v in drives.first { $0.mountPath == v.mountPath } } }

    /// What's free on the disk the map is of, as the ring counts it: the disk's own count of free blocks when it was read,
    /// which the Free piece is drawn from. The title, the middle of the ring, the disk's capsule and the cards all say this,
    /// so the disk has one number for its free space. (The system's figure for a drive, in `DriveInfo.free`, also counts
    /// purgeable space macOS would clear on demand, so it's a few GB more on the boot disk.)
    var shownFree: UInt64? { workTree.map { $0.totals[Int($0.free)] } ?? volume?.free }

    /// How big the disk the map is of is, by the same count.
    var shownCapacity: UInt64 { workTree?.capacityBytes ?? volume?.capacity ?? 0 }

    /// Where Backup's files go, while it's connected.
    var destinationDrive: DriveInfo? { backup.destination.flatMap { connected($0.drive) } }

    /// The drives the right capsule offers: every connected one, then the ones used before that aren't connected now.
    var destinationChoices: [DriveInfo] {
        var out = drives
        for known in backup.knownDrives where !drives.contains(where: { $0.isSame(as: known) }) {
            var away = known
            away.isConnected = false
            out.append(away)
        }
        return out
    }

    /// Why a drive can't be where Backup's files go, or nil when it can.
    func whyNotDestination(_ drive: DriveInfo) -> String? {
        if let source = sourceDrive, drive.isSame(as: source) { return "On the left" }
        if drive.mountPath == volume?.mountPath { return "On the left" }
        if drive.isReadOnly { return "Read-only" }
        return nil
    }

    func chooseDestination(_ drive: DriveInfo, folder: String = "") {
        guard !isCleaning, whyNotDestination(drive) == nil else { return }
        // Picks on another drive's half don't carry over.
        if backup.destination.map({ !$0.drive.isSame(as: drive) }) ?? false { backup.drivePicks = nil }
        backup.destination = BackupDestination(drive: drive, folder: folder)
        if let at = backup.knownDrives.firstIndex(where: { $0.isSame(as: drive) }) {
            backup.knownDrives[at] = drive
        } else if !drive.isBoot {
            backup.knownDrives.append(drive)
        }
        saveBackup()
        // Both disks, with this one.
        if mode == .backup, showDriveSide || showGhosts { applyGhosts() }
    }

    /// Choose Folder…: where on a connected drive Backup's files go.
    func chooseDestinationFolder() {
        guard let drive = destinationDrive ?? drives.first(where: { whyNotDestination($0) == nil }) else {
            showTip("Connect a drive first.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Backup puts files. They go in \(BackupPaths.macFolder), at their full path."
        panel.directoryURL = URL(fileURLWithPath: BackupDestination(drive: drive, folder: backup.destination?.folder ?? "").root)
        guard panel.runModal() == .OK, let url = panel.url, let holder = DriveInfo.holding(url.path), whyNotDestination(holder) == nil else { return }
        chooseDestination(holder, folder: BackupPaths.fromDriveTop(url.path, mount: holder.mountPath))
    }

    // MARK: Big files

    /// How old a big file has to be for Backup's list, in days, 0 for any age: the age chosen over the list, or in Changes,
    /// where the list has no picker of its own, the Untouched window chosen there. A Changes window of what changed lately
    /// leaves out nothing.
    var backupAgeShown: Int {
        guard view == .changes else { return backupAge }
        if case .untouched(let days) = changeWindow { return days }
        return 0
    }

    /// Files in the folder you're in that Backup offers: at least `BackupState.smallest`, yours to move, and at least as old as
    /// the age chosen. Largest first.
    func backupCandidates() -> [UInt32] {
        guard let tree = workTree, !tree.isPartial else { return [] }
        // With both sides on screen, the folder they were drawn for: the picture's own numbers aren't the map's.
        let here = showsPair ? (focusBeforePair ?? 0) : focus
        guard Int(here) < tree.count else { return [] }
        let age = backupAgeShown
        if let memo = backupCandidatesMemo, memo.version == treeVersion, memo.focus == here, memo.age == age { return memo.rows }
        let start = Int(tree.dfsIn[Int(here)]), size = Int(tree.dfsSize[Int(here)])
        let before = age == 0 ? UInt32.max : UInt32(clamping: Int(Date().timeIntervalSince1970) - age * 86_400)
        let trash = trashNode(in: tree)
        var rows: [UInt32] = []
        for i in 1..<tree.count {
            let n = tree.nodes[i]
            guard n.flags & (NodeFlag.directory | NodeFlag.synthetic | NodeFlag.gone | NodeFlag.alias) == 0, n.bytes >= BackupState.smallest else { continue }
            let at = Int(tree.dfsIn[i])
            guard at >= start, at < start + size else { continue }
            let id = UInt32(i)
            if let trash, tree.isInside(id, trash) { continue }
            if n.modTime > before { continue }
            rows.append(id)
        }
        rows.sort { tree.totals[Int($0)] > tree.totals[Int($1)] }
        // What isn't yours to move, or lives inside something macOS shows as one thing, isn't offered.
        let offered = Array(rows.lazy.filter { id in
            guard let path = tree.path(id) else { return false }
            let visible = PathMath.visible(path)
            return Safety.canTrash(path) && !self.backup.isKept(visible)
        }.prefix(300))
        backupCandidatesMemo = (treeVersion, here, age, offered)
        return offered
    }

    var backupBytes: UInt64 { backup.items.reduce(0) { $0 &+ $1.bytes } }

    /// What to know before moving it: a file with another hard link, or a clone, frees nothing while its other copy stays,
    /// and the drive's file system may not hold it.
    func backupWarning(_ item: BackupItem) -> String? {
        if let drive = backup.destination?.drive, let largest = drive.largestFile, item.bytes > largest { return "Too big for \(drive.fileSystemTitle)" }
        if let memo = backupWarningMemo, memo.version == treeVersion, let said = memo.said[item.path] { return said }
        let said = linkWarning(item)
        if backupWarningMemo?.version != treeVersion { backupWarningMemo = (treeVersion, [:]) }
        backupWarningMemo?.said[item.path] = said
        return said
    }

    private func linkWarning(_ item: BackupItem) -> String? {
        guard let tree = workTree, let node = tree.find(path: item.path) ?? tree.find(visible: item.path) else { return nil }
        let gain = AgentLook.gain(of: node, in: tree)
        guard let shared = gain["shared_with_other_copies"] as? [String: Any] else { return nil }
        let place = (shared["paths"] as? [String])?.first.map(DiskTree.friendly)
        return "Frees nothing: hardlinked or cloned" + (place.map { " with \($0)" } ?? "")
    }

    /// What Backup's list comes to, taken together: a file with a hard link or a clone elsewhere frees nothing while that
    /// stays, and when it's selected too, the two free their bytes once.
    func backupSummary() -> BackupSummary {
        let items = backup.items
        var hasher = Hasher()
        hasher.combine(treeVersion)
        for item in items { hasher.combine(item.path) }
        let key = hasher.finalize()
        if let memo = backupSummaryMemo, memo.key == key { return memo.summary }
        var out = BackupSummary(files: items.count, bytes: items.reduce(0) { $0 &+ $1.bytes })
        var nodes: [UInt32] = [], pathOf: [UInt32: String] = [:], unmapped: UInt64 = 0
        if let tree = workTree {
            for item in items {
                if let node = tree.find(visible: item.path) ?? tree.find(path: item.path) {
                    nodes.append(node)
                    pathOf[node] = item.path
                } else {
                    unmapped &+= item.bytes
                }
            }
            let effect = Accounting.effect(of: nodes, except: [], in: tree)
            out.frees = effect.total &+ unmapped
            // A file that looks as if it frees little is asked again: what all of it frees, with and without it. The second path
            // of a hard link, whose first is selected too, frees its share that way.
            for (node, path) in pathOf where (effect.perTop[node] ?? 0) < max(1_000_000, tree.totals[Int(node)] / 20) {
                let without = Accounting.effect(of: nodes.filter { $0 != node }, except: [], in: tree).total
                if effect.total &- min(effect.total, without) < 1_000_000 { out.freesNothing.insert(path) }
            }
        } else {
            out.frees = out.bytes
        }
        backupSummaryMemo = (key, out)
        return out
    }

    /// What would stop Backup from running now, and what it would take.
    func backupReady() -> (items: [BackupItem], problem: String?) {
        guard let destination = backup.destination else { return ([], "Choose a drive") }
        guard let drive = connected(destination.drive) else { return ([], "Connect \(destination.drive.name)") }
        if let why = whyNotDestination(drive) { return ([], why == "On the left" ? "Choose another drive" : why) }
        var items = backup.items.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let largest = drive.largestFile, items.contains(where: { $0.bytes > largest }) {
            items.removeAll { $0.bytes > largest }
            if items.isEmpty { return ([], "\(drive.name) can't hold files over 4 GB") }
        }
        // Room for it all, and a little over: a drive that's full to the last byte is one that fails halfway. A hundredth of
        // the drive, between 50 MB and 1 GB.
        let spare = min(max(drive.capacity / 100, 50_000_000), 1_000_000_000)
        let needed = items.reduce(UInt64(0)) { $0 &+ $1.bytes } &+ spare
        if needed > drive.free {
            return ([], "Needs \(formatBytes(needed)) · \(formatBytes(drive.free)) free on \(drive.name)")
        }
        return (items, nil)
    }

    // MARK: Selecting

    /// Selects files for Backup, by path. Only files of at least `BackupState.smallest` that Headroom would let go; something
    /// on Free Up's list is taken off it, since a file is on one list at a time.
    @discardableResult
    func selectForBackup(_ references: [String], agent: String? = nil, reason: String? = nil) -> [AgentPick] {
        guard let tree = workTree else { return references.map { AgentPick(path: $0, outcome: .refused("Headroom has no map yet.")) } }
        guard !isCleaning else { return references.map { AgentPick(path: $0, outcome: .refused("Headroom is busy. Try again when it's done.")) } }
        var tookFromFreeUp: [String] = []
        let note = reason.map { AgentPicks.oneLine($0, most: 140) }
        let picks = references.map { reference -> AgentPick in
            let written = AgentLook.written(reference)
            let node = try? AgentLook.node(reference, in: tree)
            let path = node.flatMap { tree.path($0) }.map(PathMath.visible) ?? PathMath.visible(AgentLook.real(written) ?? written)
            var info = stat()
            guard lstat(path, &info) == 0 else { return AgentPick(path: path, outcome: .refused("Not found.")) }
            guard info.st_mode & S_IFMT == S_IFREG else {
                return AgentPick(path: path, outcome: .refused(info.st_mode & S_IFMT == S_IFDIR ? "Backup moves files, not folders." : "Only files can be moved."))
            }
            guard !MovedNote.isNote(path) else { return AgentPick(path: path, outcome: .refused("That's a note for a moved file.")) }
            guard UInt64(info.st_size) >= BackupState.smallest else {
                return AgentPick(path: path, outcome: .refused("Smaller than \(formatBytes(BackupState.smallest))."))
            }
            guard Safety.canTrash(path), Cleaner.mayAct(on: path) else { return AgentPick(path: path, outcome: .refused("Protected.")) }
            if backup.isKept(path) { return AgentPick(path: path, outcome: .refused("Kept on Mac.")) }
            if backup.has(path) { return AgentPick(path: path, outcome: .asItWas("already selected"), node: node) }
            if FileManager.default.fileExists(atPath: MovedNote.notePath(for: path)) {
                return AgentPick(path: path, outcome: .refused("A file with this name was moved already. Move it back first."))
            }
            if plan.covers(path) {
                plan.takeBack(path)
                tookFromFreeUp.append(path)
            }
            backup.items.append(BackupItem(path: path, title: (path as NSString).lastPathComponent, bytes: UInt64(info.st_size), agent: agent, reason: note))
            return AgentPick(path: path, outcome: .selected, node: node)
        }
        if !tookFromFreeUp.isEmpty {
            planChanged()
            showTip(tookFromFreeUp.count == 1 ? "Removed from Free Up: \((tookFromFreeUp[0] as NSString).lastPathComponent)" : "\(tookFromFreeUp.count) removed from Free Up")
        }
        if picks.contains(where: { $0.outcome == .selected }) { backupChanged() }
        return picks
    }

    /// Takes files off Backup's list. An agent can only take back what an agent selected.
    @discardableResult
    func deselectForBackup(_ references: [String], byAgent: Bool = false) -> [AgentPick] {
        let picks = references.map { reference -> AgentPick in
            let written = AgentLook.written(reference)
            let path = PathMath.visible(AgentLook.real(written) ?? written)
            guard let item = backup.items.first(where: { $0.path == path || $0.path == written }) else { return AgentPick(path: path, outcome: .asItWas("not selected")) }
            if byAgent, item.agent == nil { return AgentPick(path: path, outcome: .refused("The user selected this in Headroom, so it's theirs to deselect.")) }
            backup.items.removeAll { $0.path == item.path }
            return AgentPick(path: item.path, outcome: .deselected)
        }
        if picks.contains(where: { $0.outcome == .deselected }) { backupChanged() }
        return picks
    }

    /// A click on a file in Backup, or Select from its menu: on the list, or off it.
    func toggleBackup(_ node: UInt32) {
        // The picture on screen: with both sides, its numbers aren't the real map's.
        guard let tree, Int(node) < tree.count, !tree.isGhost(node), let raw = tree.path(node) else {
            if let tree, tree.isGhost(node) { showTip("Already moved. Move it back from the Moved list.") }
            return
        }
        let path = PathMath.visible(raw)
        if let pair, pair.tree === tree, tree.isInside(node, pair.driveSide) {
            toggleDriveFile(node, in: pair)
            return
        }
        if backup.has(path) {
            deselectForBackup([path])
            return
        }
        if let refused = selectForBackup([path]).first, case .refused(let why) = refused.outcome { showTip(why) }
    }

    /// Space on a folder in Backup: every file in it that Backup takes, or on the drive's half every file in it there. When
    /// they're all selected already, they're all deselected.
    func toggleBackupFolder(_ node: UInt32) {
        guard let tree, Int(node) < tree.count else { return }
        if let pair, pair.tree === tree, pair.isOnDrive(node) {
            let files = pair.driveRel.keys.filter { tree.isInside($0, node) }.compactMap { pair.driveFile($0) }
            guard !files.isEmpty else { return }
            let picked = Set(driveSelection.map(\.path))
            if files.allSatisfy({ picked.contains($0.path) }) {
                let gone = Set(files.map(\.path))
                driveSelection.removeAll { gone.contains($0.path) }
                showTip(files.count == 1 ? "Deselected 1 file" : "Deselected \(files.count) files")
            } else {
                let added = files.filter { !picked.contains($0.path) }
                driveSelection += added
                showTip(added.count == 1 ? "Selected 1 file" : "Selected \(added.count) files")
            }
            engine.apply(drawing(tree), .live)
            return
        }
        // On this Mac: the files in it big enough for Backup. What else it won't take, it says no to.
        var paths: [String] = []
        if let pair, pair.tree === tree {
            for (file, rel) in pair.macRel where tree.isInside(file, node) && max(tree.nodes[Int(file)].bytes, tree.nodes[Int(file)].aliasBytes) >= BackupState.smallest {
                paths.append(pair.onMac(rel))
            }
        } else {
            let start = tree.dfsIn[Int(node)], size = tree.dfsSize[Int(node)]
            for i in 1..<tree.count {
                let n = tree.nodes[i]
                guard tree.dfsIn[i] &- start < size, n.firstChild == 0, n.flags & (NodeFlag.directory | NodeFlag.synthetic | NodeFlag.gone) == 0,
                      max(n.bytes, n.aliasBytes) >= BackupState.smallest, !tree.isGhost(UInt32(i)), let path = tree.path(UInt32(i)) else { continue }
                paths.append(PathMath.visible(path))
            }
        }
        guard !paths.isEmpty else {
            showTip("No files of \(formatBytes(BackupState.smallest)) or more here")
            return
        }
        if paths.allSatisfy({ backup.has($0) }) {
            deselectForBackup(paths)
            showTip(paths.count == 1 ? "Deselected 1 file" : "Deselected \(paths.count) files")
        } else {
            let added = selectForBackup(paths.filter { !backup.has($0) }).filter { $0.outcome == .selected }.count
            showTip(added == 1 ? "Selected 1 file" : "Selected \(added) files")
        }
    }

    func clearBackup() {
        guard !isCleaning, !backup.items.isEmpty || !driveSelection.isEmpty else { return }
        backup.items = []
        driveSelection = []
        backupChanged()
    }

    // MARK: The drive's half

    func toggleDriveFile(_ node: UInt32, in pair: PairPicture) {
        guard let file = pair.driveFile(node) else { return }
        if let at = driveSelection.firstIndex(where: { $0.path == file.path }) {
            driveSelection.remove(at: at)
        } else {
            driveSelection.append(file)
        }
        if let tree { engine.apply(drawing(tree), .live) }
    }

    func deselectDriveFile(_ file: DriveFile) {
        driveSelection.removeAll { $0.path == file.path }
        if let tree { engine.apply(drawing(tree), .live) }
    }

    /// Copies files from the drive into the same place in the folder on the Mac, checked against the hash beside each, or
    /// its note when it was moved from here. A file the Mac has already is left alone. The drive keeps its copies.
    func copyToMac(_ files: [DriveFile]) {
        guard !isCleaning, let first = files.first else { return }
        let notes = Dictionary(movedNotes.map { ($0.originalPath, $0) }, uniquingKeysWith: { a, _ in a })
        let known = expectedHashes()
        runDriveJob(.copyToMac, title: "Copying from \(first.driveName)", driveName: first.driveName,
                    entries: files.map { DriveJob.Entry(id: $0.path, title: $0.title, bytes: $0.bytes) }) { index, job in
            let file = files[index]
            let note = notes[file.macPath]
            let expected = note?.sha256 ?? known[file.path] ?? Sidecar.hash(for: file.path)
            var last = Date.distantPast
            do {
                let copied = try DriveMover.copy(file.path, to: file.macPath, expected: expected, stop: job.stop) { p in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.1 else { return }
                    last = now
                    Task { @MainActor in job.progress(index, phase: p.phase, bytes: p.bytes, of: p.of) }
                }
                if let note, Cleaner.mayAct(on: note.notePath) { unlink(note.notePath) }
                return .done(copied.wasThere ? "Already on this Mac" : "Copied")
            } catch {
                return .failed(((error as? DriveMover.Failure) ?? .io(error.localizedDescription)).text)
            }
        } after: { job in
            // What's copied is done with; new files on the Mac, so the map is read again for them.
            let done = Set(job.entries.filter { if case .done = $0.step { true } else { false } }.map(\.id))
            self.driveSelection.removeAll { done.contains($0.path) }
            if !done.isEmpty { self.scan() }
        }
    }

    /// Reads files on the drive and compares each with the hash beside it, or its note, or else the Mac's copy.
    func checkOnDrive(_ files: [DriveFile]) {
        guard !isCleaning, let first = files.first else { return }
        let notes = Dictionary(movedNotes.map { ($0.originalPath, $0) }, uniquingKeysWith: { a, _ in a })
        let known = expectedHashes()
        runDriveJob(.verify, title: "Verifying", driveName: first.driveName,
                    entries: files.map { DriveJob.Entry(id: $0.path, title: $0.title, bytes: $0.bytes) }) { index, job in
            let file = files[index]
            var expected = notes[file.macPath]?.sha256 ?? known[file.path] ?? Sidecar.hash(for: file.path)
            if expected == nil, file.place == .both { expected = try? DriveMover.hash(file.macPath, stop: job.stop).hash }
            guard let expected else { return .failed("No hash to compare with") }
            var last = Date.distantPast
            guard let found = try? DriveMover.hash(file.path, stop: job.stop, progress: { bytes in
                let now = Date()
                guard now.timeIntervalSince(last) > 0.1 else { return }
                last = now
                Task { @MainActor in job.progress(index, phase: .checking, bytes: bytes, of: file.bytes) }
            }) else { return .failed(job.stop.value ? "Stopped" : "Couldn't read it") }
            return found.hash == expected ? .done("Verified") : .failed("Doesn't match")
        } after: { _ in }
    }

    /// Files on the drive go to the drive's Trash, with the hash beside each. A moved file's note goes too: it would point
    /// at nothing. Both disks are read again first, not taken from the picture: a file the Mac was to keep a copy of only goes
    /// when the Mac's copy is there and matches, by the hash beside the drive's copy, or else by reading both. Files that
    /// aren't on this Mac are asked about first, by the panel.
    func deleteFromDrive(_ files: [DriveFile]) {
        guard !isCleaning, let first = files.first else { return }
        let notes = Dictionary(movedNotes.map { ($0.originalPath, $0) }, uniquingKeysWith: { a, _ in a })
        let known = expectedHashes()
        runDriveJob(.deleteFromDrive, title: "Deleting from \(first.driveName)", driveName: first.driveName,
                    entries: files.map { DriveJob.Entry(id: $0.path, title: $0.title, bytes: $0.bytes) }) { index, job in
            let file = files[index]
            guard Cleaner.mayAct(on: file.path) else { return .failed(DriveMover.Failure.notAllowed.text) }
            var there = stat()
            guard lstat(file.path, &there) == 0 else { return .failed("Not on \(file.driveName) any more") }
            if file.place == .both {
                var mine = stat()
                guard lstat(file.macPath, &mine) == 0, mine.st_mode & S_IFMT == S_IFREG else { return .failed("Not on this Mac any more, so it stays") }
                guard mine.st_size == there.st_size else { return .failed("This Mac's copy is different now, so it stays") }
                var last = Date.distantPast
                let report: (UInt64) -> Void = { bytes in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.1 else { return }
                    last = now
                    Task { @MainActor in job.progress(index, phase: .checking, bytes: bytes, of: file.bytes) }
                }
                let expected = known[file.path] ?? Sidecar.hash(for: file.path) ?? (try? DriveMover.hash(file.path, stop: job.stop).hash)
                guard let expected, let found = try? DriveMover.hash(file.macPath, stop: job.stop, progress: report) else {
                    return .failed(job.stop.value ? "Stopped" : "Couldn't read it")
                }
                guard found.hash == expected else { return .failed("This Mac's copy is different, so it stays") }
            }
            do {
                _ = try Cleaner.trash(file.path)
                let beside = Sidecar.path(for: file.path)
                if FileManager.default.fileExists(atPath: beside) { _ = try? Cleaner.trash(beside) }
            } catch {
                return .failed(Cleaner.whyItFailed(error).text)
            }
            if file.place == .moved, let note = notes[file.macPath], Cleaner.mayAct(on: note.notePath) { unlink(note.notePath) }
            return .done("In \(file.driveName)'s Trash")
        } after: { job in
            let done = Set(job.entries.filter { if case .done = $0.step { true } else { false } }.map(\.id))
            self.driveSelection.removeAll { done.contains($0.path) }
            self.forgetCopies(done)
        }
    }

    // MARK: Hashes, kept on the Mac

    /// What files on Backup's drive should hash to, by where they are on it now: from the notes of what was moved there, and
    /// Backup's record of what was copied.
    func expectedHashes() -> [String: String] {
        var out: [String: String] = [:]
        for note in movedNotes {
            if let drive = drive(of: note) { out[note.pathOnDrive(mountedAt: drive.mountPath)] = note.sha256 }
        }
        if let destination = backup.destination, let drive = connected(destination.drive) {
            for copy in backup.copies ?? [] where copy.driveID == drive.id { out[drive.mountPath + "/" + copy.path] = copy.sha256 }
        }
        return out
    }

    /// Keeps the hash of a file copied to a drive, which leaves no note.
    func recordCopy(_ target: String, on drive: DriveInfo, hash: String, size: UInt64) {
        let path = BackupPaths.fromDriveTop(target, mount: drive.mountPath)
        var copies = (backup.copies ?? []).filter { !($0.driveID == drive.id && $0.path == path) }
        copies.append(CopiedFile(driveID: drive.id, path: path, sha256: hash, size: size, copied: Date()))
        backup.copies = copies
        saveBackup()
    }

    /// Forgets copies that are gone from the drive, by where they were on it.
    func forgetCopies(_ paths: Set<String>) {
        guard let drive = destinationDrive, var copies = backup.copies, !paths.isEmpty else { return }
        let before = copies.count
        copies.removeAll { $0.driveID == drive.id && paths.contains(drive.mountPath + "/" + $0.path) }
        guard copies.count != before else { return }
        backup.copies = copies.isEmpty ? nil : copies
        saveBackup()
    }

    // MARK: What can be done with what's selected

    /// One thing Backup can do with what's selected, and how many files and how much it's for. `blocked` says why it can't
    /// run now.
    struct BackupAction: Identifiable {
        enum Kind: String { case move, copy, keep, copyToMac, verify, delete }
        var kind: Kind
        var title: String
        var files: Int
        var bytes: UInt64
        var blocked: String?
        /// When it's for some of what's selected, not all: then it says how many.
        var partial = false
        var id: String { kind.rawValue }
        var detail: String { (files == 1 ? "1 file" : "\(files) files") + " · " + formatBytes(bytes) }
    }

    /// What fits the selection: for files on this Mac, Move, Copy and Keep on Mac; for files picked on the drive's half, Copy
    /// to Mac (for what this Mac doesn't have), Verify and Delete.
    var backupActions: [BackupAction] {
        var out: [BackupAction] = []
        let drive = backup.destination?.drive.name ?? "Drive"
        let items = backup.items
        if !items.isEmpty {
            let ready = backupReady()
            let bytes = items.reduce(UInt64(0)) { $0 &+ $1.bytes }
            // What would go now, or while it can't, everything that's selected.
            let going = ready.problem == nil ? ready.items : items
            let goingBytes = going.reduce(UInt64(0)) { $0 &+ $1.bytes }
            out.append(BackupAction(kind: .move, title: "Move to \(drive)", files: going.count, bytes: goingBytes, blocked: ready.problem,
                                    partial: going.count < items.count))
            out.append(BackupAction(kind: .copy, title: "Copy to \(drive)", files: going.count, bytes: goingBytes, blocked: ready.problem,
                                    partial: going.count < items.count))
            out.append(BackupAction(kind: .keep, title: "Keep on Mac", files: items.count, bytes: bytes))
        }
        let picks = driveSelection
        if let first = picks.first {
            let unplugged = destinationDrive == nil ? "Connect \(first.driveName)" : nil
            let back = picks.filter { $0.place == .onlyDrive || $0.place == .moved }
            if !back.isEmpty {
                out.append(BackupAction(kind: .copyToMac, title: "Copy to Mac", files: back.count, bytes: back.reduce(0) { $0 &+ $1.bytes }, blocked: unplugged,
                                        partial: back.count < picks.count))
            }
            let bytes = picks.reduce(UInt64(0)) { $0 &+ $1.bytes }
            out.append(BackupAction(kind: .verify, title: "Verify", files: picks.count, bytes: bytes, blocked: unplugged))
            out.append(BackupAction(kind: .delete, title: "Delete from \(first.driveName)", files: picks.count, bytes: bytes, blocked: unplugged))
        }
        return out
    }

    /// Runs an action. Delete asks first, in the panel, for anything this Mac doesn't also have.
    func perform(_ action: BackupAction) {
        guard action.blocked == nil, !isCleaning else { return }
        switch action.kind {
        case .move: runBackup(copyOnly: false)
        case .copy: runBackup(copyOnly: true)
        case .keep: for item in backup.items { keepOnMac(item.path, true) }
        case .copyToMac: copyToMac(driveSelection.filter { $0.place == .onlyDrive || $0.place == .moved })
        case .verify: checkOnDrive(driveSelection)
        case .delete: deleteFromDrive(driveSelection)
        }
    }

    /// Whether Delete needs a yes first: something picked on the drive isn't on this Mac too.
    var deleteNeedsAsking: Bool { driveSelection.contains { $0.place != .both } }

    /// Selects everything in the folder that's only on this Mac, as far as Backup takes it: files of at least
    /// `BackupState.smallest`.
    func selectOnlyOnMac() {
        guard let pair, pair.tree === tree else { return }
        let picks = selectForBackup(pair.macPaths(in: .onlyMac))
        let added = picks.filter { $0.outcome == .selected }.count
        let small = picks.filter { if case .refused(let why) = $0.outcome { why.hasPrefix("Smaller") } else { false } }.count
        var text = added == 1 ? "Selected 1 file" : "Selected \(added) files"
        if small > 0 { text += " · \(small) under \(formatBytes(BackupState.smallest)) left out" }
        showTip(text)
    }

    func keepOnMac(_ path: String, _ keep: Bool) {
        if keep {
            if !backup.keep.contains(path) { backup.keep.append(path) }
            backup.items.removeAll { PathMath.isInside($0.path, path) }
        } else {
            backup.keep.removeAll { $0 == path }
        }
        backupCandidatesMemo = nil
        backupChanged()
    }

    /// Backup's list changed: it's written down, and the ring shows it.
    func backupChanged() {
        saveBackup()
        planner = nil
        if mode == .backup, let tree { engine.apply(drawing(tree), .live) }
    }

    /// What the ring stripes in Backup: the files on its list.
    func backupPlanned() -> RingLayout.Planner {
        // Found in the picture that's drawn, whose numbers may not be the real map's.
        guard let tree, !backup.items.isEmpty || !driveSelection.isEmpty else { return { _ in false } }
        let showsBoth = pair?.tree === tree
        // On both disks the Mac's files are found by where they are from the folder; the picture has its own numbers.
        var nodes = backup.items.compactMap { item in
            showsBoth ? pair?.macNode(for: item.path) : tree.find(visible: item.path) ?? tree.find(path: item.path)
        }
        // And on the drive's half, what's picked there.
        if let pair, showsBoth {
            nodes += driveSelection.compactMap { file in
                file.path.hasPrefix(pair.drivePath + "/") ? pair.driveNodes[String(file.path.dropFirst(pair.drivePath.count + 1))] : nil
            }
        }
        guard !nodes.isEmpty else { return { _ in false } }
        let set = NodeSet(nodes, in: tree)
        return { node in set.contains(node) }
    }

    /// One list at a time: whatever Free Up now has is taken off Backup's.
    func takeOffBackupWhatFreeUpHas() {
        let taken = backup.items.filter { plan.covers($0.path) }
        guard !taken.isEmpty else { return }
        backup.items.removeAll { plan.covers($0.path) }
        saveBackup()
        showTip(taken.count == 1 ? "Removed from Backup: \(taken[0].title)" : "\(taken.count) removed from Backup")
    }

    // MARK: Moved files

    /// Finds the notes this Mac knows of: the ones it wrote, and any Spotlight knows that were written elsewhere or moved
    /// with their folder. Each is read again, so a note that's gone, or isn't one, drops out.
    func refreshNotes() {
        let known = backup.notes
        let scripted = ScriptRunner.path != nil
        Task.detached(priority: .utility) {
            var paths = Set(known)
            if !scripted { paths.formUnion(Self.spotlightNotes()) }
            let notes = paths.compactMap { MovedNote.read(at: $0) }.sorted { $0.size > $1.size }
            await MainActor.run {
                self.movedNotes = notes
                let now = notes.map(\.notePath)
                if Set(now) != Set(self.backup.notes) {
                    self.backup.notes = now
                    self.saveBackup()
                }
                if self.showGhosts { self.applyGhosts() }
            }
        }
    }

    nonisolated private static func spotlightNotes() -> [String] {
        let find = Process()
        find.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        find.arguments = ["-onlyin", NSHomeDirectory(), "kMDItemFSName == '*.\(MovedNote.ext)'"]
        let out = Pipe()
        find.standardOutput = out
        find.standardError = FileHandle.nullDevice
        guard (try? find.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        find.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter(MovedNote.isNote)
    }

    func setShowDriveSide(_ on: Bool) {
        guard on != showDriveSide else { return }
        showDriveSide = on
        if on { setMode(.backup); setView(.map) }
        applyGhosts()
    }

    func setShowGhosts(_ on: Bool) {
        guard on != showGhosts else { return }
        showGhosts = on
        if on { setMode(.backup); setView(.map) }
        applyGhosts()
    }

    /// The drive a note's file is on, while it's connected.
    func drive(of note: MovedNote) -> DriveInfo? {
        drives.first { drive in
            if let id = note.driveID, let uuid = drive.uuid { return id == uuid }
            return drive.name == note.driveName
        }
    }

    /// Copies moved files back from their drive to where they were, proves each against its note, then takes the note away.
    /// The drive keeps its copy.
    func bringBack(_ notes: [MovedNote]) {
        let ready = notes.filter { drive(of: $0) != nil }
        guard !isCleaning, !ready.isEmpty else {
            if let first = notes.first { showTip("Connect \(first.driveName) first.") }
            return
        }
        runNoteJob(.bringBack, title: "Moving back from \(ready[0].driveName)", notes: ready) { note, job, index in
            guard let drive = await self.drive(of: note) else { return .failed("\(note.driveName) isn't connected.") }
            var last = Date.distantPast
            do {
                _ = try DriveMover.bringBack(note, from: drive, stop: job.stop) { p in
                    let now = Date()
                    guard now.timeIntervalSince(last) > 0.1 else { return }
                    last = now
                    Task { @MainActor in job.progress(index, phase: p.phase, bytes: p.bytes, of: p.of) }
                }
            } catch {
                return .failed(((error as? DriveMover.Failure) ?? .io(error.localizedDescription)).text)
            }
            if Cleaner.mayAct(on: note.notePath) { unlink(note.notePath) }
            return .done("Moved back")
        }
    }

    /// Reads moved files on their drive again and compares each with its note and the hash beside it.
    func verifyMoved(_ notes: [MovedNote]) {
        guard !isCleaning, !notes.isEmpty else { return }
        runNoteJob(.verify, title: "Verifying", notes: notes) { note, job, index in
            var last = Date.distantPast
            let found = DriveMover.verify(note, on: await self.drive(of: note), stop: job.stop) { bytes in
                let now = Date()
                guard now.timeIntervalSince(last) > 0.1 else { return }
                last = now
                Task { @MainActor in job.progress(index, phase: .checking, bytes: bytes, of: note.size) }
            }
            return found == .fine ? .done(found.text) : .failed(found.text)
        }
    }

    /// The last copy of each, on its drive, goes to that drive's Trash, with its hash and its note. Only after you've said
    /// yes to it: this is the one step that can leave nothing behind.
    func deleteLastCopy(_ notes: [MovedNote]) {
        guard !isCleaning, !notes.isEmpty else { return }
        runNoteJob(.deleteFromDrive, title: "Deleting from \(notes[0].driveName)", notes: notes) { note, _, _ in
            guard let drive = await self.drive(of: note) else { return .failed("\(note.driveName) isn't connected.") }
            let path = note.pathOnDrive(mountedAt: drive.mountPath)
            do {
                if FileManager.default.fileExists(atPath: path) { _ = try Cleaner.trash(path) }
                let beside = Sidecar.path(for: path)
                if FileManager.default.fileExists(atPath: beside) { _ = try? Cleaner.trash(beside) }
            } catch {
                return .failed(Cleaner.whyItFailed(error).text)
            }
            if Cleaner.mayAct(on: note.notePath) { unlink(note.notePath) }
            return .done("In \(drive.name)'s Trash")
        }
    }

    /// Runs one piece of work per note, one note at a time, and forgets the notes that are gone at the end.
    private func runNoteJob(_ kind: DriveJob.Kind, title: String, notes: [MovedNote],
                            work: @escaping @Sendable (MovedNote, DriveJob, Int) async -> DriveJob.Step) {
        runDriveJob(kind, title: title, driveName: notes[0].driveName,
                    entries: notes.map { DriveJob.Entry(id: $0.notePath, title: $0.name, bytes: $0.size) }) { index, job in
            await work(notes[index], job, index)
        } after: { job in
            // Something came back, or its record went: the map is read again for it.
            if kind == .bringBack, job.doneCount > 0 { self.scan() }
        }
    }

    /// Runs one piece of work per entry, one at a time, then reads the notes again, tidies up and says how it went.
    private func runDriveJob(_ kind: DriveJob.Kind, title: String, driveName: String, entries: [DriveJob.Entry],
                             work: @escaping @Sendable (Int, DriveJob) async -> DriveJob.Step, after: @escaping @MainActor (DriveJob) -> Void) {
        dropGhosts()
        let job = DriveJob(kind: kind, title: title, driveName: driveName, entries: entries)
        driveJob = job
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: title)
        Task {
            defer { ProcessInfo.processInfo.endActivity(activity) }
            for index in entries.indices {
                if job.stop.value { break }
                job.begin(index)
                let step = await Task.detached(priority: .userInitiated) { await work(index, job) }.value
                job.finish(index, step)
            }
            job.end()
            if quitAfterClean {
                cleanStoppedForQuit = true
                quitWhenNothingIsLeft()
                return
            }
            let gone = movedNotes.map(\.notePath).filter { !FileManager.default.fileExists(atPath: $0) }
            if !gone.isEmpty {
                movedNotes.removeAll { gone.contains($0.notePath) }
                backup.notes.removeAll { gone.contains($0) }
                saveBackup()
            }
            after(job)
            showTip(job.summary, for: 8)
            refreshDrives()
            applyGhosts()
        }
    }

    /// Puts away a finished run's results.
    func dismissDriveJob() {
        guard driveJob?.isRunning == false else { return }
        driveJob = nil
    }
}
