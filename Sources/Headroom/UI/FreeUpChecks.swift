import AppKit
import SwiftUI

/// What the checks found that you should know before cleaning, one line per planned thing.
struct NeedsALook: View {
    let model: AppModel

    var body: some View {
        // What's wrong with each thing is worked out once here, and handed to its row.
        let found = model.plan.items.map { (item: $0, problems: model.problemsToShow(for: $0)) }.filter { !$0.problems.isEmpty }
            .sorted { (model.checks[$0.item.id]?.canGo ?? true ? 1 : 0) < (model.checks[$1.item.id]?.canGo ?? true ? 1 : 0) }
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Needs attention")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.amber)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                ForEach(found, id: \.item.id) { one in
                    LookRow(model: model, item: one.item, problems: one.problems)
                }
            }
            .padding(.bottom, 4)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Palette.amber.opacity(0.08)))
            .padding(.bottom, 6)
        }
    }
}


private struct LookRow: View {
    let model: AppModel
    let item: PlanItem
    let problems: [CheckProblem]
    @State private var isHovered = false
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in fix(problem) }
                action("Keep") { model.keep(item: item) }
                    .help("Don't suggest this again")
            }
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                Text(problem.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(problem.holdsBack ? Palette.amber : .white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isOpen { paths }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(isHovered ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            model.highlight(nodes: inside ? (model.planPlaces.nodes[item.id] ?? []) : [])
        }
        .onTapGesture {
            Motion.animate(.snappy(duration: 0.2)) { isOpen.toggle() }
        }
        .named(NamedThing(nodes: model.planPlaces.nodes[item.id] ?? [], title: item.title), in: model)
    }

    private func action(_ text: String, _ run: @escaping () -> Void) -> some View {
        Button {
            Motion.animate(.snappy(duration: 0.2)) { run() }
        } label: {
            CapsuleLabel(text: text, isLit: isHovered)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private func fix(_ problem: CheckProblem) -> some View {
        switch problem {
        case .appOpen(let name, let id):
            action("Quit \(name)") { model.quit(bundleID: id) }
        case .inUse, .someInUse:
            // If you go and close what's using it, it's looked at again when you come back.
            action("Clean anyway") { model.acceptInUse(for: item.id) }
        case .changed:
            action("Clean anyway") { model.acceptChange(for: item.id) }
        case .noGain:
            if model.otherCopies[item.id] != nil {
                action("Include other copy") { model.alsoPlanOtherCopy(for: item) }
            }
        case .couldntGo(_, let askSettings):
            action("Try again") { model.tryAgain(item) }
            if askSettings { action("Open Settings") { model.openAutomationSettings() } }
        default:
            EmptyView()
        }
    }

    private var paths: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(item.paths.prefix(30), id: \.self) { path in
                Text(DiskTree.friendly(path))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if item.paths.count > 30 {
                Text("\(item.paths.count - 30) more")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if !item.excluded.isEmpty {
                Text("Excluded: \(item.excluded.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
