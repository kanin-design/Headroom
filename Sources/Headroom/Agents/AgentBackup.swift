import Foundation

/// Backup's side of what an agent can ask: its list, its drive, the files moved already, and what a run did. An agent
/// selects and chooses the drive; moving, copying, bringing back and deleting are the user's clicks, and nothing here does
/// them.
@MainActor
enum AgentBackup {
    static func drive(_ drive: DriveInfo?, connected: Bool) -> [String: Any] {
        guard let drive else { return ["chosen": false] }
        var out: [String: Any] = ["name": drive.name, "file_system": drive.fileSystemTitle, "connected": connected]
        if connected {
            out["path"] = drive.mountPath
            out["free"] = drive.free
            out["free_text"] = formatBytes(drive.free)
        }
        if drive.largestFile != nil { out["no_files_over"] = "4 GB" }
        return out
    }

    static func state(_ model: AppModel, limit: Int) -> [String: Any] {
        let destination = model.backup.destination
        let connected = destination.flatMap { model.connected($0.drive) }
        var drive = drive(connected ?? destination?.drive, connected: connected != nil)
        if let folder = destination?.folder, !folder.isEmpty { drive["folder"] = folder }
        let ready = model.backupReady()
        var out: [String: Any] = [
            "drive": drive,
            "selected": model.backup.items.prefix(limit).map { item -> [String: Any] in
                var row: [String: Any] = ["path": item.path, "size": item.bytes, "size_text": formatBytes(item.bytes), "selected_by": item.agent ?? "the user"]
                if let reason = item.reason { row["reason"] = reason }
                return row
            },
            "selected_in_all": model.backup.items.count,
            "selected_size": model.backupBytes,
            "selected_size_text": formatBytes(model.backupBytes),
            "moved": model.movedNotes.prefix(limit).map { note -> [String: Any] in
                ["path": note.originalPath, "size": note.size, "size_text": formatBytes(note.size), "drive": note.driveName,
                 "drive_connected": model.drive(of: note) != nil, "moved": AgentLook.dates.string(from: note.moved)]
            },
            "moved_in_all": model.movedNotes.count,
            "smallest_file": BackupState.smallest,
            "being_worked_on": model.driveJob?.isRunning == true,
        ]
        if let problem = ready.problem {
            out["move_now"] = problem
        } else {
            let bytes = ready.items.reduce(UInt64(0)) { $0 &+ $1.bytes }
            out["move_now"] = "Ready: Move \(formatBytes(bytes)) to \(destination?.drive.name ?? "")"
        }
        return out
    }

    static func picked(_ picks: [AgentPick], model: AppModel, selecting: Bool) -> [String: Any] {
        let done = picks.filter { $0.outcome == (selecting ? .selected : .deselected) }.count
        var out: [String: Any] = [
            selecting ? "selected" : "deselected": done,
            "results": picks.map { ["path": $0.path, "result": $0.outcome.text] },
            "selected_in_all": model.backup.items.count,
            "selected_size_text": formatBytes(model.backupBytes),
        ]
        if selecting {
            out["next"] = model.backup.destination == nil
                ? "No drive chosen: call set_backup_drive, or the user picks one. Nothing moves until the user clicks Move."
                : "Nothing moves until the user clicks Move. Call show with view backup, then wait_for_backup."
        }
        return out
    }

    static func setDrive(_ model: AppModel, _ arguments: [String: Any]) throws -> [String: Any] {
        guard let wanted = arguments["drive"] as? String else { throw AgentFailure("Name the drive, or give its path.") }
        let path = AgentLook.written(wanted)
        guard let drive = model.drives.first(where: { $0.mountPath == path || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            throw AgentFailure("No such drive connected: \(wanted). Connected: " + model.drives.map(\.name).joined(separator: ", "))
        }
        if let why = model.whyNotDestination(drive) {
            throw AgentFailure(why == "Disk shown" ? "That's the disk Headroom is showing. Choose another drive." : "\(drive.name) is \(why.lowercased()).")
        }
        guard !model.isCleaning else { throw AgentFailure("Headroom is busy. Try again when it's done.") }
        var folder = (arguments["folder"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if folder.split(separator: "/").contains("..") { throw AgentFailure("The folder has to be inside the drive.") }
        if folder.hasPrefix(String(drive.mountPath.dropFirst())) { folder = String(folder.dropFirst(drive.mountPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        model.chooseDestination(drive, folder: folder)
        return ["drive": AgentBackup.drive(drive, connected: true), "folder": folder.isEmpty ? "the top of the drive" : folder]
    }

    static func verify(_ model: AppModel, _ arguments: [String: Any]) throws -> [String: Any] {
        guard !model.isCleaning else { throw AgentFailure("Headroom is busy. Try again when it's done.") }
        var notes = model.movedNotes.filter { model.drive(of: $0) != nil }
        if let paths = arguments["paths"] as? [String], !paths.isEmpty {
            let wanted = Set(paths.map(AgentLook.written))
            notes = notes.filter { wanted.contains($0.originalPath) || wanted.contains($0.notePath) }
        }
        guard !notes.isEmpty else { throw AgentFailure("No moved files on a connected drive.") }
        model.verifyMoved(notes)
        return ["checking": notes.count, "next": "Call wait_for_backup for the results."]
    }

    /// Waits for a run that's going, or for the user to start one and for it to end, and says what each file came to.
    static func wait(_ model: AppModel, seconds asked: Int?) async -> [String: Any] {
        let seconds = min(max(asked ?? 600, 1), AgentLook.longestWait)
        let before = model.driveJob.map(ObjectIdentifier.init)
        let giveUp = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < giveUp {
            if let job = model.driveJob, !job.isRunning, ObjectIdentifier(job) != before || job.finished.map({ Date().timeIntervalSince($0) < 2 }) == true {
                return report(job)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let job = model.driveJob, job.isRunning {
            return ["finished": false, "note": "\(job.title): \(Int(job.fraction * 100))% so far. Call wait_for_backup again."]
        }
        return ["finished": false, "note": "Nothing moved yet. Call wait_for_backup again to keep waiting."]
    }

    static func report(_ job: DriveJob) -> [String: Any] {
        [
            "finished": true,
            "summary": job.summary,
            "files": job.entries.map { entry -> [String: Any] in
                var row: [String: Any] = ["name": entry.title, "size": entry.bytes, "path": entry.id]
                switch entry.step {
                case .done(let said): row["result"] = said
                case .failed(let why): row["result"] = "Failed: " + why
                case .stopped: row["result"] = "Stopped"
                default: row["result"] = "Skipped"
                }
                return row
            },
            "note": job.kind == .move
                ? "Each moved file left a note where it was. The originals are in the Trash: emptying it frees the space, and Undo restores them until then."
                : "",
        ]
    }
}
