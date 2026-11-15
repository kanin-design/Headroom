import AppKit
import SwiftUI

/// Backup: big files to move to another drive, what's selected to go, and what has gone, each with what can be done with it.
struct BackupPanel: View {
    let model: AppModel
    @State private var confirmDelete: [MovedNote] = []
    @State private var confirmDriveDelete: [DriveFile] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                // What's selected turns into the run's card while it's moved, in the same place. Once the run is over, what's
                // still selected (a file that failed, or something picked since) is back under it, with what can be done.
                if let job = model.driveJob { DriveJobCard(model: model, job: job) }
                if model.driveJob?.isRunning != true {
                    selected
                    driveSelected
                    actions
                }
                candidates
                moved
                kept
            }
            .padding(Kit.panelInset)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollIndicators(.never)
        .alert(confirmDelete.count == 1 ? "Delete “\(confirmDelete.first?.name ?? "")” from \(confirmDelete.first?.driveName ?? "the drive")?"
                                        : "Delete \(confirmDelete.count) files from \(confirmDelete.first?.driveName ?? "the drive")?",
               isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } })) {
            Button("Delete", role: .destructive) {
                model.deleteLastCopy(confirmDelete)
                confirmDelete = []
            }
            Button("Cancel", role: .cancel) { confirmDelete = [] }
        } message: {
            let bytes = confirmDelete.reduce(UInt64(0)) { $0 &+ $1.size }
            Text("It's the only copy. \(formatBytes(bytes)) goes to the drive's Trash.")
        }
        .alert(confirmDriveDelete.count == 1 ? "Delete “\(confirmDriveDelete.first?.title ?? "")” from \(confirmDriveDelete.first?.driveName ?? "the drive")?"
                                             : "Delete \(confirmDriveDelete.count) files from \(confirmDriveDelete.first?.driveName ?? "the drive")?",
               isPresented: Binding(get: { !confirmDriveDelete.isEmpty }, set: { if !$0 { confirmDriveDelete = [] } })) {
            Button("Delete", role: .destructive) {
                model.deleteFromDrive(confirmDriveDelete)
                confirmDriveDelete = []
            }
            Button("Cancel", role: .cancel) { confirmDriveDelete = [] }
        } message: {
            let last = confirmDriveDelete.filter { $0.place != .both }.count
            let trash = "\(confirmDriveDelete.first?.driveName ?? "the drive")'s Trash"
            Text(last == confirmDriveDelete.count ? "Not on this Mac. Goes to \(trash)." : "\(last) aren't on this Mac. All go to \(trash).")
        }
    }

    // MARK: Where things go

    /// The drive itself is shown and chosen at the bottom right, and the cards say where files go. Up here: that there's none
    /// yet, what its file system can't take, and what the colours of both halves mean.
    @ViewBuilder
    private var header: some View {
        let destination = model.backup.destination
        let tooBig = destination?.drive.largestFile != nil
        if destination == nil || tooBig || model.pair != nil {
            VStack(alignment: .leading, spacing: 6) {
                if destination == nil {
                    Text("No drive chosen")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, Kit.rowInset)
                }
                if let destination, tooBig {
                    CardNote(text: "No files over 4 GB on \(destination.drive.name)", colour: Kit.amber, symbol: "exclamationmark.triangle.fill") {}
                        .padding(.horizontal, Kit.rowInset)
                }
                if let pair = model.pair { PairLegend(model: model, pair: pair) }
            }
        }
    }

    // MARK: Selected

    @ViewBuilder
    private var selected: some View {
        let items = model.backup.items
        if !items.isEmpty {
            let summary = model.backupSummary()
            SelectionCard(model: model, summary: summary, agent: items.compactMap(\.agent).first.map { agent in (agent, items.filter { $0.agent == agent }.count) }) {
                PickList(picks: items.map { item in
                    let nothing = summary.freesNothing.contains(item.path)
                    let tooBig = model.backup.destination?.drive.largestFile.map { item.bytes > $0 } == true
                    return Pick(path: item.path, title: item.title, bytes: item.bytes,
                                warning: tooBig ? model.backupWarning(item) : (nothing ? "Frees nothing" : nil),
                                help: [item.reason, nothing ? model.backupWarning(item) : nil].compactMap { $0 }.joined(separator: "\n"),
                                deselect: { model.deselectForBackup([item.path]) }, keep: { model.keepOnMac(item.path, true) })
                }, enabled: !model.isCleaning, deselect: { picks in _ = model.deselectForBackup(picks.map(\.path)) })
            }
        }
    }

    // MARK: Picked on the drive's half

    @ViewBuilder
    private var driveSelected: some View {
        let files = model.driveSelection
        if let first = files.first {
            DriveSelectionCard(model: model, files: files, driveName: first.driveName) {
                PickList(picks: files.map { file in
                    Pick(path: file.path, title: file.title, bytes: file.bytes, warning: nil, help: file.place.title(drive: file.driveName),
                         deselect: { model.deselectDriveFile(file) }, keep: nil)
                }, enabled: !model.isCleaning, deselect: { picks in
                    let gone = Set(picks.map(\.path))
                    Motion.animate(.snappy(duration: 0.2)) { model.driveSelection.removeAll { gone.contains($0.path) } }
                    if let tree = model.tree { model.engine.apply(model.drawing(tree), .live) }
                }, folderName: { model.shownFolder($0) })
            }
        }
    }

    // MARK: What can be done

    /// Everything that fits what's selected, but the one the big button below does: that one is pressed there, and why it
    /// can't run now is said there too.
    @ViewBuilder
    private var actions: some View {
        let all = model.backupActions
        let main = BackupBar.main(of: all)
        let list = all.filter { $0.id != main?.id }
        if !list.isEmpty {
            PanelSection(title: "Actions") {
                VStack(spacing: 6) {
                    ForEach(list) { action in
                        ActionCard(action: action, enabled: !model.isCleaning, saidBelow: main?.blocked) {
                            // Deleting what this Mac doesn't also have is asked about first.
                            if action.kind == .delete, model.deleteNeedsAsking { confirmDriveDelete = model.driveSelection } else { model.perform(action) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Big files here

    @ViewBuilder
    private var candidates: some View {
        let rows = model.backupCandidates().filter { node in
            guard let tree = model.workTree, let path = tree.path(node) else { return false }
            // What's on the drive already isn't waiting to go.
            return !model.backup.has(PathMath.visible(path)) && !model.isBackedUp(path)
        }
        PanelSection(title: "Large Files") {
            // In Changes, the Untouched window over the panel says how old, so there's one picker, not two.
            if model.view != .changes {
                HStack(spacing: 8) {
                    PickerLabel(text: "Untouched")
                    PillPicker(options: [0, 30, 182, 365], selection: model.backupAge, title: Self.ageTitle,
                               help: { $0 == 0 ? "Show every large file" : "Show files unchanged for \(Self.ageTitle($0)) or more" }) { age in
                        model.backupAge = age
                    }
                }
                .padding(.leading, Kit.rowInset)
                .padding(.bottom, 4)
            }
            if rows.isEmpty {
                // Big files that are all selected, or on the drive already, leave nothing else to list.
                EmptyNote(title: model.workTree?.isPartial == true ? "Waiting for the scan"
                          : model.backupCandidates().isEmpty ? "No files over \(formatBytes(BackupState.smallest)) here" : "Nothing else here")
            }
            ForEach(rows.prefix(80), id: \.self) { node in
                if let tree = model.workTree, let path = tree.path(node) {
                    let visible = PathMath.visible(path)
                    let when = tree.newest[Int(node)]
                    FileRow(title: tree.name(node),
                            detail: DiskTree.friendly((visible as NSString).deletingLastPathComponent)
                                + (when > 0 ? " · " + LastUse.ago(Date(timeIntervalSince1970: TimeInterval(when)), now: Date()) : ""),
                            trailing: formatBytes(tree.totals[Int(node)]),
                            onTap: model.isCleaning ? nil : { model.selectForBackup([visible]) }) {
                        TickMark(false, color: Kit.blue)
                            .help("Select")
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: visible)]) }
                        Button("Keep on Mac") { model.keepOnMac(visible, true) }
                    }
                }
            }
        }
    }

    private static func ageTitle(_ days: Int) -> String {
        switch days {
        case 0: "Any time"
        case 30: "1 month"
        case 182: "6 months"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    // MARK: Moved

    @ViewBuilder
    private var moved: some View {
        if !model.movedNotes.isEmpty {
            let total = model.movedNotes.reduce(UInt64(0)) { $0 &+ $1.size }
            PanelSection(title: "Moved", trailing: "\(model.movedNotes.count) · \(formatBytes(total))") {
                Button("Verify all") { model.verifyMoved(model.movedNotes.filter { model.drive(of: $0) != nil }) }
                    .buttonStyle(.pill(Kit.blue))
                    .disabled(model.isCleaning || !model.movedNotes.contains { model.drive(of: $0) != nil })
                    .help("Check each moved file on its drive")
                    .padding(.leading, Kit.rowInset)
                    .padding(.bottom, 2)
                ForEach(model.movedNotes, id: \.notePath) { note in
                    let connected = model.drive(of: note) != nil
                    FileRow(title: note.name,
                            detail: "\(note.driveName)\(connected ? "" : " · not connected") · \(DiskTree.friendly((note.originalPath as NSString).deletingLastPathComponent))",
                            trailing: formatBytes(note.size)) {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .contextMenu {
                        Button("Move Back") { model.bringBack([note]) }.disabled(!connected || model.isCleaning)
                        Button("Verify") { model.verifyMoved([note]) }.disabled(!connected || model.isCleaning)
                        Button("Show Note in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: note.notePath)]) }
                        if let drive = model.drive(of: note) {
                            Button("Show on \(drive.name)") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: note.pathOnDrive(mountedAt: drive.mountPath))])
                            }
                        }
                        Divider()
                        Button("Delete from \(note.driveName)…", role: .destructive) { confirmDelete = [note] }.disabled(!connected || model.isCleaning)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var kept: some View {
        if !model.backup.keep.isEmpty {
            Fold(title: "Kept on Mac", count: "\(model.backup.keep.count)") {
                ForEach(model.backup.keep, id: \.self) { path in
                    KeptLine(title: DiskTree.friendly(path)) { model.keepOnMac(path, false) }
                }
            }
        }
    }
}

/// What's selected for Backup: a ring of how much of it frees space on the Mac, what it comes to, who picked it, where it
/// goes and the room left there, then the files by folder. Moving it turns this card into the run's, in the same place.
private struct SelectionCard<Content: View>: View {
    let model: AppModel
    let summary: BackupSummary
    let agent: (name: String, count: Int)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let share = summary.bytes == 0 ? 1 : min(Double(summary.frees) / Double(summary.bytes), 1)
        RingCard(title: "\(formatBytes(summary.bytes)) selected") {
            CardRing(fraction: share, upTo: 1, accent: Kit.blue, text: "\(summary.files)")
                .help(summary.files == 1 ? "1 file" : "\(summary.files) files")
        } lines: {
            CardLine(text: summary.frees == 0 ? "Frees nothing on this Mac" : "Frees \(formatBytes(summary.frees)) on this Mac")
            if let agent { AgentChip(name: agent.count == summary.files ? agent.name : "\(agent.count) by \(agent.name)") }
        } content: {
            if let destination = model.backup.destination {
                let drive = model.connected(destination.drive)
                RoomBar(place: "\(destination.title) › \(BackupPaths.macFolder)", capacity: drive?.capacity ?? 0, free: drive?.free ?? 0,
                        adds: summary.bytes,
                        trailing: drive.map { "\(formatBytes($0.free &- min($0.free, summary.bytes))) free after" } ?? "Not connected",
                        trailingColour: drive == nil ? Kit.amber : Kit.secondary)
            }
            if !summary.freesNothing.isEmpty {
                CardNote(text: summary.freesNothing.count == 1 ? "1 frees nothing: its other copy stays"
                         : "\(summary.freesNothing.count) free nothing: their other copies stay",
                         colour: Kit.amber, symbol: "exclamationmark.triangle.fill") {
                    Button("Deselect") { Motion.animate(.snappy(duration: 0.2)) { _ = model.deselectForBackup(Array(summary.freesNothing)) } }
                        .buttonStyle(.textLink(Kit.blue))
                        .disabled(model.isCleaning)
                }
            }
            Divider().overlay(.white.opacity(0.06))
            content()
                .padding(.horizontal, -Kit.rowInset)
        }
    }
}

/// What's picked on the drive's half, as the Mac's selection is shown: a ring of how much of it isn't on this Mac, what it
/// comes to, and this Mac's room for what copying it back would add, then the files by folder.
private struct DriveSelectionCard<Content: View>: View {
    let model: AppModel
    let files: [DriveFile]
    let driveName: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        let bytes = files.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let away = files.filter { $0.place == .onlyDrive || $0.place == .moved }
        let awayBytes = away.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let share = away.isEmpty || bytes == 0 ? 1 : min(Double(awayBytes) / Double(bytes), 1)
        RingCard(title: "\(formatBytes(bytes)) selected on \(driveName)") {
            CardRing(fraction: share, accent: Kit.blue, text: "\(files.count)")
                .help(files.count == 1 ? "1 file" : "\(files.count) files")
        } lines: {
            CardLine(text: away.isEmpty ? "All on this Mac too" : (away.count == files.count && away.count > 1 ? "None on this Mac" : "\(away.count) not on this Mac"))
        } content: {
            let free = model.shownFree ?? 0
            RoomBar(icon: "internaldrive.fill", place: "This Mac", capacity: model.shownCapacity, free: free, adds: awayBytes,
                    trailing: "\(formatBytes(free &- min(free, awayBytes))) free after")
            Divider().overlay(.white.opacity(0.06))
            content()
                .padding(.horizontal, -Kit.rowInset)
        }
    }
}

/// A file picked for Backup, on either half, as the list shows it.
private struct Pick: Identifiable {
    let path: String
    let title: String
    let bytes: UInt64
    let warning: String?
    let help: String
    let deselect: () -> Void
    let keep: (() -> Void)?
    var id: String { path }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// What's picked, a group for each folder, biggest first, each file with its tick. Closed when there's much in it, open when
/// there's little.
private struct PickList: View {
    let picks: [Pick]
    let enabled: Bool
    let deselect: ([Pick]) -> Void
    /// How a folder is named: as a path you'd say, unless something better is given.
    var folderName: (String) -> String = { DiskTree.friendly($0) }

    var body: some View {
        let groups = Dictionary(grouping: picks, by: \.folder)
            .map { (folder: $0.key, picks: $0.value.sorted { $0.bytes > $1.bytes }, bytes: $0.value.reduce(UInt64(0)) { $0 &+ $1.bytes }) }
            .sorted { $0.bytes > $1.bytes }
            .map { FolderGroup(folder: $0.folder, items: $0.picks, trailing: "\($0.picks.count) · \(formatBytes($0.bytes))") }
        FolderGroups(groups: groups, openAtFirst: picks.count <= 10, folderName: folderName, menu: { group in
            AnyView(Group {
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: group.folder)) }
                Button("Deselect") { deselect(group.items) }.disabled(!enabled)
            })
        }) { pick in
            FileRow(title: pick.title, warning: pick.warning, trailing: formatBytes(pick.bytes), onTap: enabled ? { pick.deselect() } : nil) {
                TickMark(true, color: Kit.blue)
                    .help("Deselect")
            }
            .help(pick.help)
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pick.path)]) }
                if let keep = pick.keep { Button("Keep on Mac", action: keep) }
            }
        }
    }
}

/// A run as it goes, on the same card as what was selected: the whole of it as a ring that fills, how far and how fast, what's
/// been freed, the drive filling as files land, the file it's on with its copy and its check as one bar of two halves, and
/// every file by folder with what became of it. Afterwards, how it ended and what needs a look.
struct DriveJobCard: View {
    let model: AppModel
    let job: DriveJob

    private var accent: Color {
        if job.isRunning { return Kit.blue }
        return job.failedCount > 0 ? Kit.amber : Kit.green
    }

    private var total: UInt64 { job.entries.reduce(0) { $0 &+ $1.bytes } }

    var body: some View {
        RingCard(title: job.isRunning ? job.title : job.summary) {
            if job.isRunning {
                CardRing(fraction: job.fraction, accent: accent) {
                    Text("\(Int(job.fraction * 100))%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: job.fraction))
                }
            } else {
                CardRing(ended: accent, symbol: job.failedCount > 0 ? "exclamationmark" : "checkmark")
            }
        } lines: {
            CardLine(text: statusLine)
            if job.kind == .move, job.freed > 0 {
                CardLine(text: "Freed \(formatBytes(job.freed)) on this Mac" + (job.isRunning ? " so far" : ""))
            }
            if let agent = job.agent { AgentChip(name: agent) }
        } content: {
            if let room = job.room {
                // Afterwards, the drive's own count of what's free, which knows what its blocks took.
                let after = job.isRunning ? nil : model.backup.destination.flatMap { model.connected($0.drive) }.map(\.free)
                RoomBar(place: room.place, capacity: room.capacity, free: room.free, adds: total, landed: job.landed,
                        trailing: "\(formatBytes(after ?? room.free &- min(room.free, job.landed))) free")
            }
            if job.isRunning, let index = job.current, index < job.entries.count {
                let entry = job.entries[index]
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(entry.step == .checking || job.kind == .verify ? "Verifying" : "Copying")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    FileBar(job: job, index: index, accent: accent)
                }
            }
            Divider().overlay(.white.opacity(0.06))
            JobList(job: job, folderName: { folder in model.shownFolder(folder) })
                .padding(.horizontal, -Kit.rowInset)
            // Stop is the button under the inspector while it runs.
            if !job.isRunning {
                Button("Done") { model.dismissDriveJob() }
                    .buttonStyle(.pill)
            }
        }
    }

    private var statusLine: String {
        // Afterwards the title says how it ended, so this says how long it took.
        if let finished = job.finished {
            let seconds = finished.timeIntervalSince(job.started)
            var parts = ["Took " + Self.duration(seconds)]
            if job.kind != .deleteFromDrive, seconds >= 1, job.doneBytes > 0 {
                parts.append("\(formatBytes(UInt64(Double(job.doneBytes) / seconds)))/s")
            }
            return parts.joined(separator: " · ")
        }
        let done = job.entries.filter(\.step.isOver).count
        var parts = ["\(done) of \(job.entries.count)"]
        if job.speed > 0 { parts.append("\(formatBytes(UInt64(job.speed)))/s") }
        if let left = job.timeLeft { parts.append(Self.duration(left) + " left") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}

/// A run's files, a group for each folder, said once with how far it's got: the selected list's rows, with each file's step
/// where its tick was and what became of it where its size was. Open when there's little in the run, and where something
/// failed, with why right under it.
private struct JobList: View {
    let job: DriveJob
    let folderName: (String) -> String

    private struct Line: Identifiable {
        let index: Int
        let entry: DriveJob.Entry
        var id: Int { index }
    }

    var body: some View {
        var order: [String] = []
        var members: [String: [Line]] = [:]
        for i in job.entries.indices {
            let folder = (job.entries[i].id as NSString).deletingLastPathComponent
            if members[folder] == nil { order.append(folder) }
            members[folder, default: []].append(Line(index: i, entry: job.entries[i]))
        }
        let groups = order.map { folder -> FolderGroup<Line> in
            let lines = members[folder] ?? []
            let failed = lines.contains { if case .failed = $0.entry.step { true } else { false } }
            let done = lines.filter { if case .done = $0.entry.step { true } else { false } }.count
            return FolderGroup(folder: folder, items: lines, trailing: "\(done) of \(lines.count)",
                               trailingColour: done == lines.count ? .white.opacity(0.6) : .white.opacity(0.45), isFlagged: failed)
        }
        return FolderGroups(groups: groups, openAtFirst: job.entries.count <= 10, folderName: folderName) { line in
            let entry = line.entry
            // Why it didn't go, right where it says so.
            let why: String? = if case .failed(let why) = entry.step { why } else { nil }
            FileRow(title: entry.title, warning: why, trailing: StepLook.text(entry), trailingColour: StepLook.colour(entry.step),
                    isQuiet: entry.step == .waiting) {
                StepLook.icon(entry.step)
            }
            .help(why ?? "")
        }
    }
}

/// How a file in a run is drawn: a mark for where it's got, in the slot a tick has, a word for it, and a colour.
private enum StepLook {
    @ViewBuilder
    static func icon(_ step: DriveJob.Step) -> some View {
        switch step {
        case .waiting: Image(systemName: "circle.dotted").font(.system(size: 11)).foregroundStyle(.white.opacity(0.3))
        case .copying, .checking: Spinner(size: 11, tint: Kit.blue)
        case .done: Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Kit.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Kit.amber)
        case .stopped: Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
        }
    }

    static func text(_ entry: DriveJob.Entry) -> String {
        switch entry.step {
        case .waiting: formatBytes(entry.bytes)
        case .copying: "Copying"
        case .checking: "Verifying"
        case .done(let said): said
        case .failed: "Failed"
        case .stopped: "Skipped"
        }
    }

    static func colour(_ step: DriveJob.Step) -> Color {
        switch step {
        case .failed: Kit.amber
        case .done: .white.opacity(0.6)
        default: .white.opacity(0.45)
        }
    }
}

/// The file it's on: the first half fills as it's copied, the second as the copy is read back and checked.
private struct FileBar: View {
    let job: DriveJob
    let index: Int
    let accent: Color

    var body: some View {
        ThinBar(fraction: fileShare(job.entries[index]), tint: accent)
            .overlay {
                if job.kind != .verify {
                    GeometryReader { g in
                        Rectangle().fill(.black.opacity(0.5)).frame(width: 1).offset(x: g.size.width / 2)
                    }
                }
            }
    }

    private func fileShare(_ entry: DriveJob.Entry) -> Double {
        let before = job.entries.prefix(index).reduce(UInt64(0)) { $0 &+ $1.bytes }
        let passes: UInt64 = job.kind == .verify || job.kind == .deleteFromDrive ? 1 : 2
        let inFile = job.workDone &- min(job.workDone, before &* passes)
        return min(Double(inFile) / Double(max(entry.bytes &* passes, 1)), 1)
    }
}

/// Backup's bar under the inspector: the Move button, which says where to, and what to do first when it can't.
struct BackupBar: View {
    let model: AppModel

    /// The one to press: Move for files on this Mac, otherwise what fits what's picked on the drive.
    static func main(of actions: [AppModel.BackupAction]) -> AppModel.BackupAction? {
        actions.first { $0.kind == .move } ?? actions.first { $0.kind == .copyToMac } ?? actions.first { $0.kind == .verify }
    }

    var body: some View {
        let count = model.backup.items.count
        let main = Self.main(of: model.backupActions)
        VStack(alignment: .leading, spacing: 8) {
            if let job = model.driveJob, job.isRunning {
                Button("Stop") { job.stop.value = true }
                    .buttonStyle(SoftButton())
                    .frame(maxWidth: .infinity)
            } else if let main {
                Button {
                    model.perform(main)
                } label: {
                    Text(main.blocked ?? main.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .buttonStyle(GoButton(moves: true))
                .disabled(main.blocked != nil || model.isCleaning)
                HStack {
                    if main.kind == .move, main.blocked == nil, main.files < count {
                        Text("\(count - main.files) can't move to \(model.backup.destination?.drive.name ?? "this drive")")
                            .font(.system(size: 11))
                            .foregroundStyle(Kit.amber)
                    }
                    Spacer(minLength: 6)
                    Button("Deselect all") { Motion.animate(.snappy(duration: 0.2)) { model.clearBackup() } }
                        .buttonStyle(.textLink)
                        .disabled(model.isCleaning)
                }
            } else {
                Button("Nothing selected") {}
                    .disabled(true)
                    .buttonStyle(GoButton(moves: true))
            }
        }
        .modifier(BarChrome())
    }
}

/// One action in the panel: what it does, for how many files and how much, or why it can't run now.
private struct ActionCard: View {
    let action: AppModel.BackupAction
    let enabled: Bool
    /// Why the big button can't run now, which it says itself: an action held up by the same thing doesn't say it again.
    let saidBelow: String?
    let run: () -> Void
    @State private var isHovered = false

    private var symbol: String {
        switch action.kind {
        case .move: "arrow.right.circle"
        case .copy: "doc.on.doc"
        case .keep: "pin"
        case .copyToMac: "arrow.left.circle"
        case .verify: "checkmark.shield"
        case .delete: "trash"
        }
    }

    var body: some View {
        let isOn = enabled && action.blocked == nil
        let blocked = action.blocked == saidBelow ? nil : action.blocked
        Button(action: run) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title + (action.kind == .delete ? "…" : ""))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(action.kind == .delete ? Kit.red : .white.opacity(0.92))
                    // How many only when it's not all of what's selected: the summary above says that.
                    if let line = blocked ?? (action.partial ? action.detail : nil) {
                        Text(line)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(blocked == nil ? .white.opacity(0.5) : Kit.amber)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, Kit.rowInset)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Kit.cardRadius, style: .continuous).fill(.white.opacity(isHovered && isOn ? 0.09 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOn)
        .opacity(isOn ? 1 : 0.6)
        .onHover { isHovered = $0 }
    }
}

/// What the colours of both sides mean, with how many files and how much each has, counted once. What's only on this Mac
/// can be selected from here. While the drive is unplugged, when its half was read.
private struct PairLegend: View {
    let model: AppModel
    let pair: PairPicture

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !pair.online {
                Text(pair.readAt.map { "Last read " + LastUse.ago($0, now: Date()) } ?? "Not read yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Kit.amber)
            }
            ForEach(PairPlace.allCases, id: \.self) { place in
                if let count = pair.counts[place], count.files > 0 {
                    HStack(spacing: 7) {
                        // The colours are the ring's in Backed Up; in Map the ring has the map's own.
                        if model.view == .copies {
                            Circle()
                                .fill(Color(.displayP3, red: Double(pow(place.colour.x, 1 / 2.2)), green: Double(pow(place.colour.y, 1 / 2.2)), blue: Double(pow(place.colour.z, 1 / 2.2))))
                                .frame(width: 8, height: 8)
                        }
                        Text(place.title(drive: pair.driveName))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.8))
                        if place == .onlyMac {
                            Button("Select") { model.selectOnlyOnMac() }
                                .buttonStyle(.textLink(Kit.blue))
                                .disabled(model.isCleaning)
                                .help("Select every file only on this Mac")
                        }
                        Spacer(minLength: 6)
                        Text("\(count.files) · \(formatBytes(count.bytes))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .padding(.horizontal, Kit.rowInset)
    }
}
