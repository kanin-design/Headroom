import AppKit
import SwiftUI

/// Backup: big files to move to another drive, what's selected to go, and what has gone, each with what can be done with it.
struct BackupPanel: View {
    let model: AppModel
    @State private var confirmDelete: [MovedNote] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let job = model.driveJob { DriveJobCard(model: model, job: job) }
                selected
                driveSelected
                candidates
                moved
                kept
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
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
    }

    // MARK: Where things go

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let destination = model.backup.destination {
                let drive = model.connected(destination.drive)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(destination.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(drive.map { "\(formatBytes($0.free)) free · \($0.fileSystemTitle)" } ?? "Not connected")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                if destination.drive.largestFile != nil {
                    Text("No files over 4 GB")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.amber)
                }
            } else {
                Text("No drive chosen")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Toggle("Show moved files", isOn: Binding(get: { model.showGhosts }, set: { model.setShowGhosts($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .disabled(model.movedNotes.isEmpty && !model.showGhosts)
            Toggle("Compare with \(model.backup.destination?.drive.name ?? "drive")", isOn: Binding(get: { model.showDriveSide }, set: { model.setShowDriveSide($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .disabled(model.destinationDrive == nil && !model.showDriveSide)
            if let pair = model.pair { PairLegend(pair: pair) }
        }
    }

    // MARK: Selected

    @ViewBuilder
    private var selected: some View {
        if !model.backup.items.isEmpty {
            PanelSection(title: "Selected", trailing: "\(model.backup.items.count) · \(formatBytes(model.backupBytes))") {
                ForEach(model.backup.items.sorted { $0.bytes > $1.bytes }) { item in
                    BackupRow(title: item.title, size: item.bytes, detail: item.reason ?? DiskTree.friendly((item.path as NSString).deletingLastPathComponent),
                              badge: item.agent, ticked: true, enabled: !model.isCleaning, warning: model.backupWarning(item)) {
                        model.deselectForBackup([item.path])
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                        Button("Keep on Mac") { model.keepOnMac(item.path, true) }
                    }
                }
            }
        }
    }

    // MARK: Picked on the drive's half

    @ViewBuilder
    private var driveSelected: some View {
        let files = model.driveSelection
        if !files.isEmpty {
            PanelSection(title: "Selected on \(files[0].driveName)", trailing: "\(files.count) · \(formatBytes(files.reduce(0) { $0 &+ $1.bytes }))") {
                ForEach(files.sorted { $0.bytes > $1.bytes }) { file in
                    BackupRow(title: file.title, size: file.bytes, detail: file.place.title(drive: file.driveName), badge: nil, ticked: true,
                              enabled: !model.isCleaning) {
                        model.deselectDriveFile(file)
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
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
            return !model.backup.has(PathMath.visible(path))
        }
        PanelSection(title: "Large Files", trailing: nil) {
            Picker("Last changed", selection: Binding(get: { model.backupAge }, set: { model.backupAge = $0 })) {
                Text("Any time").tag(0)
                Text("Over a month ago").tag(30)
                Text("Over 6 months ago").tag(182)
                Text("Over a year ago").tag(365)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.system(size: 11.5))
            .padding(.bottom, 2)
            if rows.isEmpty {
                Text(model.workTree?.isPartial == true ? "Waiting for the scan" : "No files over \(formatBytes(BackupState.smallest)) here")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 4)
            }
            ForEach(rows.prefix(80), id: \.self) { node in
                if let tree = model.workTree, let path = tree.path(node) {
                    let visible = PathMath.visible(path)
                    let when = tree.newest[Int(node)]
                    BackupRow(title: tree.name(node), size: tree.totals[Int(node)],
                              detail: DiskTree.friendly((visible as NSString).deletingLastPathComponent)
                                  + (when > 0 ? " · " + LastUse.ago(Date(timeIntervalSince1970: TimeInterval(when)), now: Date()) : ""),
                              badge: nil, ticked: false, enabled: !model.isCleaning) {
                        model.selectForBackup([visible])
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: visible)]) }
                        Button("Keep on Mac") { model.keepOnMac(visible, true) }
                    }
                }
            }
        }
    }

    // MARK: Moved

    @ViewBuilder
    private var moved: some View {
        if !model.movedNotes.isEmpty {
            let total = model.movedNotes.reduce(UInt64(0)) { $0 &+ $1.size }
            PanelSection(title: "Moved", trailing: "\(model.movedNotes.count) · \(formatBytes(total))") {
                HStack(spacing: 8) {
                    Button("Verify All") { model.verifyMoved(model.movedNotes.filter { model.drive(of: $0) != nil }) }
                        .disabled(model.isCleaning || !model.movedNotes.contains { model.drive(of: $0) != nil })
                    Spacer()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                ForEach(model.movedNotes, id: \.notePath) { note in
                    let connected = model.drive(of: note) != nil
                    BackupRow(title: note.name, size: note.size,
                              detail: "\(note.driveName)\(connected ? "" : " · not connected") · \(DiskTree.friendly((note.originalPath as NSString).deletingLastPathComponent))",
                              badge: nil, ticked: nil, enabled: false) {}
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
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.backup.keep, id: \.self) { path in
                        HStack {
                            Text(DiskTree.friendly(path))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Suggest again") { model.keepOnMac(path, false) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("\(model.backup.keep.count) kept on Mac")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// A titled group in Backup's panel.
private struct PanelSection<Content: View>: View {
    let title: String
    let trailing: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            content()
        }
    }
}

/// One file: a tick to put it on the list or take it off, its name and size, and where it is or why it was chosen.
private struct BackupRow: View {
    let title: String
    let size: UInt64
    let detail: String
    let badge: String?
    /// On the list, off it, or neither, for what's no longer on this Mac.
    let ticked: Bool?
    let enabled: Bool
    var warning: String? = nil
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let ticked {
                Button(action: toggle) {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(ticked ? Color(red: 0.36, green: 0.62, blue: 1) : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help(ticked ? "Deselect" : "Select")
            } else {
                Image(systemName: "externaldrive")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let badge {
                        CapsuleLabel(text: badge)
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let warning {
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.amber)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Text(formatBytes(size))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(isHovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { if ticked != nil, enabled { toggle() } }
    }
}

/// A run as it goes: the whole of it as a ring that fills, the file it's on with its copy and its check as one bar of two
/// halves, how fast and how long, and every file with what became of it. Afterwards, how it ended and what needs a look.
struct DriveJobCard: View {
    let model: AppModel
    let job: DriveJob

    private var accent: Color {
        if job.isRunning { return Color(red: 0.42, green: 0.70, blue: 1) }
        return job.failedCount > 0 ? Palette.amber : Color(red: 0.36, green: 0.82, blue: 0.56)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.white.opacity(0.08), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: max(job.fraction, 0.004))
                        .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth(duration: 0.3), value: job.fraction)
                    if job.isRunning {
                        Text("\(Int(job.fraction * 100))%")
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: job.fraction))
                    } else {
                        Image(systemName: job.failedCount > 0 ? "exclamationmark" : "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }
                .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.isRunning ? job.title : job.summary)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(statusLine)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
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
                        Text(entry.step == .checking ? "Verifying" : (job.kind == .verify ? "Verifying" : "Copying"))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    FileBar(job: job, index: index, accent: accent)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(job.entries) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        stepIcon(entry.step)
                            .frame(width: 14)
                        Text(entry.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(entry.step == .waiting ? 0.4 : 0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(stepText(entry))
                            .font(.system(size: 10.5))
                            .foregroundStyle(stepColor(entry.step))
                            .lineLimit(1)
                    }
                    // Why it didn't go, right where it says so.
                    if case .failed(let why) = entry.step {
                        Text(why)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.amber.opacity(0.85))
                            .lineLimit(2)
                            .padding(.leading, 20)
                            .help(why)
                    }
                    }
                }
            }
            // Stop is the button under the inspector while it runs.
            if !job.isRunning {
                Button("Done") { model.dismissDriveJob() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }

    private var statusLine: String {
        let done = job.entries.filter(\.step.isOver).count
        var parts = ["\(done) of \(job.entries.count)"]
        if job.isRunning {
            if job.speed > 0 { parts.append("\(formatBytes(UInt64(job.speed)))/s") }
            if let left = job.timeLeft { parts.append(Self.duration(left) + " left") }
        } else if let failed = Optional(job.failedCount), failed > 0 {
            parts.append(failed == 1 ? "1 failed" : "\(failed) failed")
        }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    @ViewBuilder
    private func stepIcon(_ step: DriveJob.Step) -> some View {
        switch step {
        case .waiting: Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
        case .copying, .checking: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(red: 0.36, green: 0.82, blue: 0.56))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Palette.amber)
        case .stopped: Image(systemName: "pause.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private func stepText(_ entry: DriveJob.Entry) -> String {
        switch entry.step {
        case .waiting: formatBytes(entry.bytes)
        case .copying: "Copying"
        case .checking: "Verifying"
        case .done(let said): said
        case .failed: "Failed"
        case .stopped: "Skipped"
        }
    }

    private func stepColor(_ step: DriveJob.Step) -> Color {
        switch step {
        case .failed: Palette.amber
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
        GeometryReader { g in
            let entry = job.entries[index]
            let share = fileShare(entry)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(accent.opacity(0.9))
                    .frame(width: max(g.size.width * share, 4))
                    .animation(.linear(duration: 0.15), value: share)
                if job.kind != .verify {
                    Rectangle().fill(.black.opacity(0.5)).frame(width: 1).offset(x: g.size.width / 2)
                }
            }
        }
        .frame(height: 5)
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
    @State private var confirmDelete: [DriveFile] = []

    var body: some View {
        let ready = model.backupReady()
        let count = model.backup.items.count
        let picked = model.driveSelection
        let drive = model.backup.destination?.drive.name ?? "Drive"
        VStack(alignment: .leading, spacing: 8) {
            if let job = model.driveJob, job.isRunning {
                Button("Stop") { job.stop.value = true }
                    .buttonStyle(SoftButton())
                    .frame(maxWidth: .infinity)
            } else if count == 0, picked.isEmpty {
                Button("Nothing selected") {}
                    .disabled(true)
                    .buttonStyle(GoButton(moves: true))
            } else {
                if count > 0 {
                    HStack(spacing: 8) {
                        Button {
                            model.runBackup(copyOnly: false)
                        } label: {
                            Text(ready.problem ?? "Move \(formatBytes(ready.items.reduce(0) { $0 &+ $1.bytes })) to \(drive)")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .buttonStyle(GoButton(moves: true))
                        .disabled(ready.problem != nil || model.isCleaning)
                        .help("Copy, verify, then move the original to the Trash")
                        Menu {
                            Button("Copy to \(drive)") { model.runBackup(copyOnly: true) }
                                .disabled(ready.problem != nil || model.isCleaning)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(SoftButton())
                        .fixedSize()
                    }
                    if ready.items.count < count, ready.problem == nil {
                        Text("\(count - ready.items.count) can't move to \(drive)")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.amber)
                    }
                }
                if !picked.isEmpty {
                    HStack(spacing: 8) {
                        Button {
                            model.copyToMac(picked)
                        } label: {
                            Text("Copy \(formatBytes(picked.reduce(0) { $0 &+ $1.bytes })) to Mac")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .buttonStyle(GoButton(moves: true))
                        .disabled(model.isCleaning)
                        Menu {
                            Button("Verify") { model.checkOnDrive(picked) }
                            Divider()
                            Button("Delete from \(picked[0].driveName)…", role: .destructive) {
                                // What the Mac also has can go without asking; anything else is the last copy.
                                if picked.allSatisfy({ $0.place == .both }) { model.deleteFromDrive(picked) } else { confirmDelete = picked }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(SoftButton())
                        .fixedSize()
                        .disabled(model.isCleaning)
                    }
                }
                HStack {
                    Spacer(minLength: 6)
                    Button("Deselect all") { Motion.animate(.snappy(duration: 0.2)) { model.clearBackup() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .disabled(model.isCleaning)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.03))
        .alert(confirmDelete.count == 1 ? "Delete “\(confirmDelete.first?.title ?? "")” from \(confirmDelete.first?.driveName ?? "the drive")?"
                                        : "Delete \(confirmDelete.count) files from \(confirmDelete.first?.driveName ?? "the drive")?",
               isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } })) {
            Button("Delete", role: .destructive) {
                model.deleteFromDrive(confirmDelete)
                confirmDelete = []
            }
            Button("Cancel", role: .cancel) { confirmDelete = [] }
        } message: {
            let last = confirmDelete.filter { $0.place != .both }.count
            let trash = "\(confirmDelete.first?.driveName ?? "the drive")'s Trash"
            Text(last == confirmDelete.count ? "Not on this Mac. Goes to \(trash)." : "\(last) aren't on this Mac. All go to \(trash).")
        }
    }
}

/// What the colours of both sides mean, with how many files and how much each has. Each file is counted once.
private struct PairLegend: View {
    let pair: PairPicture

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(PairPlace.allCases, id: \.self) { place in
                if let count = pair.counts[place], count.files > 0 {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Color(.displayP3, red: Double(pow(place.colour.x, 1 / 2.2)), green: Double(pow(place.colour.y, 1 / 2.2)), blue: Double(pow(place.colour.z, 1 / 2.2))))
                            .frame(width: 8, height: 8)
                        Text(place.title(drive: pair.driveName))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer(minLength: 6)
                        Text("\(count.files) · \(formatBytes(count.bytes))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

