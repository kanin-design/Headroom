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
    }

    /// The drive as it's connected now, if it is.
    func connected(_ drive: DriveInfo) -> DriveInfo? { drives.first { $0.isSame(as: drive) } }

    /// The drive the map is of.
    var sourceDrive: DriveInfo? { volume.flatMap { v in drives.first { $0.mountPath == v.mountPath } } }

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
        backup.destination = BackupDestination(drive: drive, folder: folder)
        if let at = backup.knownDrives.firstIndex(where: { $0.isSame(as: drive) }) {
            backup.knownDrives[at] = drive
        } else if !drive.isBoot {
            backup.knownDrives.append(drive)
        }
        saveBackup()
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

    /// Files in the folder you're in that Backup offers: at least `BackupState.smallest`, yours to move, and at least as old as
    /// the age chosen. Largest first.
    func backupCandidates() -> [UInt32] {
        guard let tree = workTree, !tree.isPartial else { return [] }
        // With both sides on screen, the folder they were drawn for: the picture's own numbers aren't the map's.
        let here = showsPair ? (focusBeforePair ?? 0) : focus
        guard Int(here) < tree.count else { return [] }
        if let memo = backupCandidatesMemo, memo.version == treeVersion, memo.focus == here, memo.age == backupAge { return memo.rows }
        let start = Int(tree.dfsIn[Int(here)]), size = Int(tree.dfsSize[Int(here)])
        let before = backupAge == 0 ? UInt32.max : UInt32(clamping: Int(Date().timeIntervalSince1970) - backupAge * 86_400)
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
        backupCandidatesMemo = (treeVersion, here, backupAge, offered)
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
        runDriveJob(.copyToMac, title: "Copying from \(first.driveName)", driveName: first.driveName,
                    entries: files.map { DriveJob.Entry(id: $0.path, title: $0.title, bytes: $0.bytes) }) { index, job in
            let file = files[index]
            let note = notes[file.macPath]
            let expected = note?.sha256 ?? Sidecar.read(for: file.path)?.hash
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
        runDriveJob(.verify, title: "Verifying", driveName: first.driveName,
                    entries: files.map { DriveJob.Entry(id: $0.path, title: $0.title, bytes: $0.bytes) }) { index, job in
            let file = files[index]
            var expected = Sidecar.read(for: file.path)?.hash ?? notes[file.macPath]?.sha256
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
    /// at nothing. Files that aren't on this Mac are asked about first, by the panel.
    func deleteFromDrive(_ files: [DriveFile]) {
        guard !isCleaning, let first = files.first else { return }
        let notes = Dictionary(movedNotes.map { ($0.originalPath, $0) }, uniquingKeysWith: { a, _ in a })
        runDriveJob(.deleteFromDrive, title: "Deleting from \(first.driveName)", driveName: first.driveName,
                    entries: files.map { DriveJob.Entry(id: $0.path, title: $0.title, bytes: $0.bytes) }) { index, _ in
            let file = files[index]
            guard Cleaner.mayAct(on: file.path) else { return .failed(DriveMover.Failure.notAllowed.text) }
            do {
                if FileManager.default.fileExists(atPath: file.path) { _ = try Cleaner.trash(file.path) }
                let beside = Sidecar.path(for: file.path)
                if FileManager.default.fileExists(atPath: beside) { _ = try? Cleaner.trash(beside) }
            } catch {
                return .failed(Cleaner.whyItFailed(error).text)
            }
            if file.place == .moved, let note = notes[file.macPath], Cleaner.mayAct(on: note.notePath) { unlink(note.notePath) }
            return .done("In \(file.driveName)'s Trash")
        } after: { _ in }
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
        var nodes = backup.items.compactMap { tree.find(visible: $0.path) ?? tree.find(path: $0.path) }
        // And on the drive's half, what's picked there.
        if let pair, pair.tree === tree {
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
