import SwiftUI

/// One place for the next thing to do: plan, review, clean, empty. It stays in the same spot, so a safe cleanup is the same
/// button pressed a few times, with the ring showing what each press did. How a clean is going, and how it ended, is the card
/// at the top of the list, as Backup's runs are; down here are only the buttons.
struct NextStepBar: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.mode == .backup {
                BackupBar(model: model)
            } else if model.cleanProgress != nil {
                cleaning
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
        VStack(alignment: .leading, spacing: Kit.Space.regular, content: content)
            .modifier(BarChrome())
    }

    /// Nothing ticked yet, so nothing to do. What you just unticked can come back from here.
    private var nothing: some View {
        bar {
            Button("Nothing selected") {}
                .disabled(true)
                .buttonStyle(GoButton())
            if !model.clearedItems.isEmpty {
                Button("Restore selection") { Motion.animate(.snappy(duration: 0.2)) { model.restoreCleared() } }
                    .buttonStyle(.textLink)
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
        let label =
            partial
            ? "Waiting for the scan"
            : ready.isEmpty
                ? "Needs attention"
                : onlyTrash
                    ? "Empty Trash: \(formatBytes(cleanBytes(ready)))"
                    : ready.count == count
                        ? "Clean \(formatBytes(model.planNumbers.total))"
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
            HStack(spacing: Kit.Space.medium) {
                Spacer(minLength: 0)
                Button("Deselect all") { Motion.animate(.snappy(duration: 0.2)) { model.clearPlan() } }
                    .buttonStyle(.textLink)
            }
        }
    }

    private func cleanBytes(_ items: [PlanItem]) -> UInt64 {
        items.reduce(0) { $0 &+ (model.planNumbers.byItem[$1.id] ?? $1.lastKnownBytes) }
    }

    /// While it cleans: Stop, as Backup has while it moves.
    private var cleaning: some View {
        bar {
            Button("Stop") { model.stopCleaning() }
                .buttonStyle(SoftButton())
                .frame(maxWidth: .infinity)
        }
    }

    /// What's in the Trash waits for your word: delete it for good, put it back, or leave it there. While it's being deleted,
    /// the button that started it waits too. Once it's done, the card says what it freed, and the bar is back to the plan.
    @ViewBuilder
    private func afterClean(_ after: AfterClean) -> some View {
        switch after.state {
        case .waiting:
            bar {
                HStack(spacing: Kit.Space.regular) {
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
                HStack(spacing: Kit.Space.medium) {
                    if !model.plan.isEmpty {
                        Text("\(model.plan.count) still selected")
                            .font(Kit.Font.detail)
                            .foregroundStyle(Kit.Text.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button("Not now") { Motion.animate(.snappy(duration: 0.2)) { model.leaveInTrash() } }
                        .buttonStyle(.textLink)
                        .help("Leave it in the Trash")
                }
            }
        case .emptying:
            bar {
                Button(after.includesOldTrash ? "Empty Trash" : "Delete permanently") {}
                    .buttonStyle(GoButton())
                    .disabled(true)
            }
        case .done:
            if !model.plan.isEmpty { planned } else { nothing }
        }
    }
}
