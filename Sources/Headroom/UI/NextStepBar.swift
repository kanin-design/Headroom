import AppKit
import SwiftUI

/// The button that does what the ticks say. It's green in any window, focused or not, so it never looks switched off when it isn't.
/// Backup's is blue: it moves things rather than throwing them away, and the two must never look alike.
struct GoButton: ButtonStyle {
    var moves = false
    @Environment(\.isEnabled) private var isEnabled

    private var top: Color { moves ? Color(red: 0.25, green: 0.56, blue: 0.96) : Color(red: 0.15, green: 0.70, blue: 0.47) }
    private var bottom: Color { moves ? Color(red: 0.16, green: 0.42, blue: 0.82) : Color(red: 0.10, green: 0.54, blue: 0.35) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.42))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(.white.opacity(0.08)))
            }
            .overlay {
                if isEnabled {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
            }
            .shadow(color: bottom.opacity(isEnabled ? 0.28 : 0), radius: 11, y: 6)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .contentShape(Rectangle())
    }
}

/// The quieter choice beside it.
struct SoftButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.white.opacity(configuration.isPressed ? 0.16 : 0.1)))
            .contentShape(Rectangle())
    }
}

/// One place for the next thing to do: plan, review, clean, empty. It stays in the same spot, so a safe cleanup is the same
/// button pressed a few times, with the ring showing what each press did.
struct NextStepBar: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.mode == .backup {
                BackupBar(model: model)
            } else if let progress = model.cleanProgress {
                cleaning(progress)
            } else if let after = model.afterClean {
                afterClean(after)
            } else if !model.plan.isEmpty {
                planned
            } else {
                nothing
            }
        }
        .animation(.snappy(duration: 0.22), value: model.plan.count)
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.03))
    }

    /// Nothing ticked yet, so nothing to do. What you just unticked can come back from here.
    private var nothing: some View {
        bar {
            Button("Nothing selected") {}
                .disabled(true)
                .buttonStyle(GoButton())
            if !model.clearedItems.isEmpty {
                Button("Restore selection") { Motion.animate(.snappy(duration: 0.2)) { model.restoreCleared() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The one button: it does what the ticks say. Whatever needs a look stays ticked, and stays put.
    private var planned: some View {
        let count = model.plan.count
        let ready = model.readyItems
        let partial = model.tree?.isPartial == true
        let onlyTrash = model.plan.items.allSatisfy(\.isEmptyTrash)
        let label = partial ? "Waiting for the scan"
            : ready.isEmpty ? "Needs attention"
            : onlyTrash ? "Empty Trash: \(formatBytes(cleanBytes(ready)))"
            : ready.count == count ? "Clean \(formatBytes(model.planNumbers.total))"
            : "Clean \(ready.count) of \(count): \(formatBytes(cleanBytes(ready)))"
        return bar {
            Button {
                model.cleanNow()
            } label: {
                Text(label)
                    .contentTransition(Motion.rolling())
            }
            .disabled(partial || ready.isEmpty || model.isCleaning)
            .buttonStyle(GoButton())
            .help(onlyTrash ? "" : "Moves everything to the Trash. Undo puts it back.")
            .animation(.snappy(duration: 0.25), value: model.planNumbers.total)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Deselect all") { Motion.animate(.snappy(duration: 0.2)) { model.clearPlan() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize()
            }
        }
    }

    private func cleanBytes(_ items: [PlanItem]) -> UInt64 {
        items.reduce(0) { $0 &+ (model.planNumbers.byItem[$1.id] ?? $1.lastKnownBytes) }
    }

    private func cleaning(_ progress: CleanProgress) -> some View {
        bar {
            HStack {
                Text(progress.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.done) of \(progress.total)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            ProgressView(value: progressShare(progress))
                .tint(Palette.reclaim(.rebuilds).swiftUI)
            Button("Stop") { model.stopCleaning() }
                .buttonStyle(.glass)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    private func progressShare(_ progress: CleanProgress) -> Double {
        guard progress.total > 0 else { return 0 }
        var share = Double(progress.done) / Double(progress.total)
        if progress.bytesTotal > 0 { share += Double(progress.bytesDone) / Double(progress.bytesTotal) / Double(progress.total) }
        return min(share, 1)
    }

    @ViewBuilder
    private func afterClean(_ after: AfterClean) -> some View {
        switch after.state {
        case .waiting:
            bar {
                HStack(alignment: .firstTextBaseline) {
                    Text("In the Trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text(formatBytes(after.bytes))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.reclaim(.rebuilds).swiftUI)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(waitingText(after))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Open Trash") { model.openTrash() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    Button {
                        model.emptyNow()
                    } label: {
                        Text(after.includesOldTrash ? "Empty Trash" : "Delete permanently")
                    }
                    .buttonStyle(GoButton())
                    Button(after.things.isEmpty ? "Cancel" : "Undo") { model.undoClean() }
                        .buttonStyle(SoftButton())
                        .fixedSize()
                }
                HStack(spacing: 6) {
                    if !model.plan.isEmpty {
                        Text("\(model.plan.count) still selected")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    Button("Not now") { Motion.animate(.snappy(duration: 0.2)) { model.leaveInTrash() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .help("Leave it in the Trash")
                }
            }
        case .emptying:
            bar {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Emptying")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        case .done(let got):
            bar {
                HStack(alignment: .firstTextBaseline) {
                    Text("Freed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text(formatBytes(got))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.gain)
                }
                if after.notDeleted > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(after.notDeleted) left in the Trash. Only Finder can delete \(after.notDeleted == 1 ? "it" : "them").")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.amber)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Open Trash") { model.openTrash() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .fixedSize()
                    }
                }
                if Double(got) < Double(after.bytes) * 0.93 {
                    Text("\(formatBytes(after.bytes &- min(after.bytes, got))) still held by a snapshot or another link. Snapshots expire on their own.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func waitingText(_ after: AfterClean) -> String {
        var text = "Not freed until the Trash is emptied."
        if after.includesOldTrash, after.oldTrashBytes > 0 { text = "Includes \(formatBytes(after.oldTrashBytes)) that was already in the Trash." }
        if after.failed > 0 { text += " \(after.failed) couldn't be moved." }
        if after.heldBack > 0 { text += " \(after.heldBack) skipped." }
        return text
    }
}
