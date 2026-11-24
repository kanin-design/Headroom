import SwiftUI

/// The card at the top of Free Up's list, and Copies': what's selected while nothing runs, how a clean is going while it does,
/// and how it ended. The same ring card Backup has, in Free Up's green, so the two modes read alike.
struct FreeUpTopCard: View {
    let model: AppModel
    /// Copies lists its own sets, so the selection's summary is Free Up's alone.
    var showsSelection = true
    /// The room under it, when there is a card.
    private let gap = Kit.Space.regular

    var body: some View {
        if let progress = model.cleanProgress {
            CleaningCard(progress: progress, title: model.driveJob?.isRunning == true ? progress.title : "Cleaning").padding(.bottom, gap)
        } else if let after = model.afterClean {
            AfterCleanCard(model: model, after: after).padding(.bottom, gap)
        } else if showsSelection, !model.plan.isEmpty {
            FreeUpSelectionCard(model: model).padding(.bottom, gap)
        }
    }
}

/// While it cleans: how far, as a ring, what it's on, and for a move, the file being copied as a bar.
private struct CleaningCard: View {
    let progress: CleanProgress
    /// Cleaning, or for a move to a drive that's running while Free Up is on screen, the move's own name.
    let title: String

    private var share: Double {
        guard progress.total > 0 else { return 0 }
        var share = Double(progress.done) / Double(progress.total)
        if progress.bytesTotal > 0 { share += Double(progress.bytesDone) / Double(progress.bytesTotal) / Double(progress.total) }
        return min(share, 1)
    }

    var body: some View {
        RingCard(title: title) {
            if progress.total > 0 {
                CardRing(fraction: share, accent: Kit.green, text: "\(Int(share * 100))%")
            } else {
                CardRing(fraction: 0, accent: Kit.green, spins: true) { EmptyView() }
            }
        } lines: {
            CardLine(
                text: progress.total > 0
                    ? "\(progress.done) of \(progress.total)" + (progress.title == title ? "" : " · \(progress.title)") : progress.title)
        } content: {
            if progress.bytesTotal > 0 {
                ThinBar(fraction: Double(progress.bytesDone) / Double(progress.bytesTotal), tint: Kit.green)
            }
        }
    }
}

/// After a clean: what's in the Trash, waiting for your word in the bar below; then the Trash being emptied; then what that
/// gave back.
private struct AfterCleanCard: View {
    let model: AppModel
    let after: AfterClean

    var body: some View {
        switch after.state {
        case .waiting:
            RingCard(title: "\(formatBytes(after.bytes)) in the Trash") {
                CardRing(ended: after.failed > 0 ? Kit.amber : Kit.green, symbol: after.failed > 0 ? "exclamationmark" : "checkmark")
            } lines: {
                CardNote(
                    text: after.includesOldTrash && after.oldTrashBytes > 0
                        ? "Includes \(formatBytes(after.oldTrashBytes)) that was already in the Trash"
                        : "Not freed until the Trash is emptied"
                ) {
                    Button("Open Trash") { model.openTrash() }
                        .buttonStyle(.textLink)
                }
                if after.failed > 0 { CardLine(text: "\(after.failed) couldn't be moved", colour: Kit.amber) }
                if after.heldBack > 0 { CardLine(text: "\(after.heldBack) skipped") }
            }
        case .emptying:
            RingCard(title: "Emptying the Trash") {
                CardRing(fraction: 0, accent: Kit.green, spins: true) { EmptyView() }
            } lines: {
                CardLine(text: "\(formatBytes(after.bytes)) to free")
            }
        case .done(let got):
            RingCard(title: "Freed \(formatBytes(got))") {
                CardRing(ended: after.notDeleted > 0 ? Kit.amber : Kit.green, symbol: after.notDeleted > 0 ? "exclamationmark" : "checkmark")
            } lines: {
                if after.notDeleted > 0 {
                    CardNote(
                        text: "\(after.notDeleted) left in the Trash. Only Finder can delete \(after.notDeleted == 1 ? "it" : "them").",
                        colour: Kit.amber
                    ) {
                        Button("Open Trash") { model.openTrash() }
                            .buttonStyle(.textLink)
                    }
                }
                if Double(got) < Double(after.bytes) * 0.93 {
                    CardLine(
                        text:
                            "\(formatBytes(after.bytes &- min(after.bytes, got))) still held by a snapshot or another link. Snapshots expire on their own.",
                        wraps: true)
                }
            }
        }
    }
}

/// What's selected in Free Up, as Backup's selection is shown: a ring of how much of it really frees space, with what frees
/// less because another copy stays in amber, what it comes to, who picked it, and the disk's room after. The boxes below are
/// the list.
private struct FreeUpSelectionCard: View {
    let model: AppModel

    var body: some View {
        let items = model.plan.items
        let frees = model.planNumbers.total
        let bytes = max(items.reduce(UInt64(0)) { $0 &+ $1.lastKnownBytes }, frees)
        let share = bytes == 0 ? 1 : min(Double(frees) / Double(bytes), 1)
        let short = model.boxes.filter { model.shortfall(of: $0) != nil }
        let diskName = model.volume.map { $0.isBoot ? "this Mac" : $0.shownName } ?? "this Mac"
        RingCard(title: "\(formatBytes(bytes)) selected") {
            CardRing(fraction: share, upTo: 1, accent: Kit.green, text: "\(items.count)")
                .help(counted(items.count, "item"))
        } lines: {
            CardLine(text: freesText(frees, on: diskName))
            if let chip = AgentChip(agents: items.compactMap(\.agent), of: items.count) { chip }
        } content: {
            if let free = model.shownFree, model.shownCapacity > 0 {
                RoomBar(
                    icon: model.volume?.isBoot == false ? "externaldrive.fill" : "internaldrive.fill", place: model.volume?.shownName ?? "Disk",
                    capacity: model.shownCapacity, free: free, adds: frees, frees: true,
                    trailing: "\(formatBytes(free &+ frees)) free after", accent: Kit.green)
            }
            if !short.isEmpty {
                CardNote(text: "Other copies remain", colour: Kit.amber, symbol: "exclamationmark.triangle.fill") {
                    Button("Include other copies") {
                        Motion.animate(.snappy(duration: 0.2)) { for box in short { model.includeOtherCopies(of: box) } }
                    }
                    .buttonStyle(.pill(nil, size: .small))
                    .disabled(model.isCleaning)
                    .help("Also select the hardlinks and clones elsewhere, so the space is freed. Torrents stop seeding.")
                }
            }
        }
    }
}
