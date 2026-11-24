import SwiftUI

/// What the checks found that you should know before cleaning, one line per planned thing.
struct NeedsALook: View {
    let model: AppModel

    var body: some View {
        // What's wrong with each thing is worked out once here, and handed to its row.
        let found = model.plan.items.map { (item: $0, problems: model.problemsToShow(for: $0)) }.filter { !$0.problems.isEmpty }
            .sorted { (model.checks[$0.item.id]?.canGo ?? true ? 1 : 0) < (model.checks[$1.item.id]?.canGo ?? true ? 1 : 0) }
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: Kit.Space.tight) {
                SectionHeading(text: "Needs attention", colour: Kit.amber)
                    .padding(.top, Kit.Space.regular)
                ForEach(found, id: \.item.id) { one in
                    LookRow(model: model, item: one.item, problems: one.problems)
                }
            }
            .padding(.bottom, Kit.Space.small)
            .card(Kit.amber.opacity(0.08), hairline: false)
            .padding(.bottom, Kit.Space.medium)
        }
    }
}

/// One planned thing that needs a look: what's wrong with it, what can be done, and its paths when it's opened. Not a
/// `ListRow`: what can be done sits on its name's line, and every problem has a line of its own, wrapped, under it.
private struct LookRow: View {
    let model: AppModel
    let item: PlanItem
    let problems: [CheckProblem]
    @State private var isHovered = false
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Kit.Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Kit.Space.medium) {
                Text(item.title)
                    .font(Kit.Font.name)
                    .foregroundStyle(Kit.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Kit.Space.small)
                ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in fix(problem) }
                action("Keep") { model.keep(item: item) }
                    .help("Don't suggest this again")
            }
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                Text(problem.text)
                    .font(Kit.Font.detail.weight(.medium))
                    .foregroundStyle(problem.holdsBack ? Kit.amber : Kit.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isOpen { paths }
        }
        .padding(.horizontal, Kit.rowInset)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Kit.Radius.row, style: .continuous).fill(isHovered ? Kit.Fill.card : .clear))
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
        Button(text) {
            Motion.animate(.snappy(duration: 0.2)) { run() }
        }
        .buttonStyle(.pill(nil, size: .small))
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
        VStack(alignment: .leading, spacing: Kit.Space.tight) {
            ForEach(item.paths.prefix(30), id: \.self) { path in
                Text(DiskTree.friendly(path))
                    .font(Kit.Font.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Kit.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if item.paths.count > 30 {
                MoreLine(text: "\(item.paths.count - 30) more")
            }
            if !item.excluded.isEmpty {
                Text("Excluded: \(item.excluded.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                    .font(Kit.Font.caption)
                    .foregroundStyle(Kit.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
