import SwiftUI

/// Copies in the inspector, made like Free Up: a short stack of rows, one for each set of copies, each in the colour its copies
/// wear on the ring, so the list is the legend. A tick sends the extra copies to the Trash with the next clean, and the copy that
/// stays is named. What takes no extra room, other names and clones, and the aliases, is folded away under it. Like every list
/// in the inspector, it follows the folder you're in.
struct CopiesPanel: View {
    let model: AppModel

    /// The most rows of copies shown before saying how many more there are.
    private static let most = 60

    var body: some View {
        let groups = model.copyGroupsHere
        let sets = groups.filter { $0.kind == .duplicate }
        let once = groups.filter { $0.kind == .sameFile || $0.kind == .sharedCopy }
        let aliases = groups.filter { $0.kind == .alias || $0.kind == .broken }
        let scale = max(sets.map(\.back).max() ?? 1, 1)
        ScrollView {
            VStack(alignment: .leading, spacing: Kit.Space.hairline) {
                // A clean of duplicates is a clean like Free Up's, and shows as one.
                FreeUpTopCard(model: model, showsSelection: false)
                summary(sets)
                    .padding(.horizontal, Kit.rowInset)
                    .padding(.top, 3)
                    .padding(.bottom, 9)
                ForEach(sets.prefix(Self.most)) { set in
                    CopySetRow(model: model, group: set, scale: scale)
                }
                if sets.count > Self.most {
                    MoreLine(text: "\((sets.count - Self.most).formatted()) more, smaller")
                        .padding(.horizontal, Kit.rowInset)
                        .padding(.bottom, Kit.Space.small)
                }
                if !once.isEmpty {
                    Folded(model: model, id: "links", title: "Hardlinks and clones", groups: once, total: once.reduce(UInt64(0)) { $0 &+ $1.size })
                        .padding(.top, Kit.Space.regular)
                }
                if !aliases.isEmpty {
                    Folded(model: model, id: "symlinks", title: "Symlinks", groups: aliases, total: nil)
                        .padding(.top, once.isEmpty ? Kit.Space.regular : Kit.Space.tight)
                }
            }
            .padding(Kit.panelInset)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func summary(_ sets: [CopyGroup]) -> some View {
        VStack(alignment: .leading, spacing: Kit.Space.medium) {
            HStack(alignment: .firstTextBaseline, spacing: Kit.Space.medium) {
                // The empty states' look, whether or not there's anything: one line that says what's here.
                Text(sentence(sets))
                    .font(Kit.Font.note)
                    .foregroundStyle(Kit.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                @Bindable var model = model
                // macOS's own help button: a ? in a circle, the system's way to say "what does this mean".
                Button {
                    model.copiesHelpShown.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(Kit.Font.headline.weight(.regular))
                        .foregroundStyle(model.copiesHelpShown ? Kit.Text.primary : Kit.Text.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete, hardlink, symlink")
                .popover(isPresented: $model.copiesHelpShown, arrowEdge: .bottom) { CopiesHelp() }
            }
            if model.copiesReading {
                ThinBar(fraction: Double(model.copiesGroupsDone) / Double(max(model.copiesGroupsTotal, 1)), tint: Kit.Text.secondary, height: 4)
                Text("Comparing… \(formatBytes(model.copiesBytesRead)) read")
                    .font(Kit.Font.detail.monospacedDigit())
                    .foregroundStyle(Kit.Text.tertiary)
            }
        }
    }

    private func sentence(_ sets: [CopyGroup]) -> String {
        if !model.hasFullAccess { return "Needs Full Disk Access" }
        if model.tree?.isPartial != false { return "Waiting for the scan" }
        guard model.copies != nil else { return "Looking for duplicates…" }
        let back = sets.reduce(UInt64(0)) { $0 &+ $1.back }
        if back == 0 { return model.copiesReading ? "Looking for duplicates…" : "No duplicates" }
        return "\(formatBytes(back)) in duplicates"
    }
}

/// What the three actions do, and what a clone is, a line each: behind the ? at the top of Copies.
private struct CopiesHelp: View {
    private let rows: [(term: String, means: String)] = [
        ("Delete", "Moves the other copies to the Trash."),
        ("Hardlink", "One file, several paths. Editing it anywhere changes it everywhere."),
        ("Symlink", "The other paths point to the copy you keep. They break if it moves."),
        ("Clone", "Separate files that share space until one of them changes."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Kit.rowInset) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows, id: \.term) { row in
                    HStack(alignment: .firstTextBaseline, spacing: Kit.Space.large) {
                        Text(row.term)
                            .font(Kit.Font.strong)
                            .frame(width: 62, alignment: .leading)
                        Text(row.means)
                            .font(Kit.Font.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("The space comes back when the Trash is emptied. Undo puts the copies back.")
                .font(Kit.Font.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Kit.Space.section)
        .frame(width: 330)
    }
}

/// One set of copies, as a Free Up box is drawn: its tick in the set's colour, the space it takes again, where the copies are,
/// and a bar of the duplicates. Opened, it lists every copy, with the one to keep marked and any other a click away, and
/// three ways to take the others out: delete, hardlink, symlink.
private struct CopySetRow: View {
    let model: AppModel
    let group: CopyGroup
    let scale: UInt64
    @State private var isHovered = false

    private var isOpen: Bool { model.copiesOpen.contains(group.id) }

    var body: some View {
        let state = model.duplicateTick(group)
        let colour = group.colour.swiftUI
        let isLit = isHovered || model.litCopyGroup.isLit(group.id)
        VStack(alignment: .leading, spacing: 0) {
            head(state, colour, isLit)
            if isOpen { inside(colour) }
        }
        .card(state.rowFill(colour, isLit: isLit || isOpen), hairline: false)
        .animation(.easeOut(duration: 0.14), value: isLit)
    }

    private func head(_ state: TickState, _ colour: Color, _ isLit: Bool) -> some View {
        BoxHead(title: group.title) {
            TickMark(state: state, color: colour, size: 20, isLit: isLit)
        } value: {
            BoxValue(text: formatBytes(group.back), isLarge: true)
        } line: {
            // Where the one that stays is comes first and is kept whole; a row of many files keeps its count at the end.
            Text(detail)
                .font(Kit.Font.detail)
                .foregroundStyle(Kit.Text.tertiary)
                .lineLimit(1)
                .truncationMode(group.files > 1 ? .middle : .tail)
        } accessory: {
            chevron
        } bar: {
            bar(colour, state: state, isLit: isLit)
                .padding(.top, 3)
        }
        .padding(.horizontal, Kit.rowInset)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            model.pointAtCopyGroup(inside ? group : nil)
        }
        .onTapGesture {
            Motion.animate(.snappy(duration: 0.18)) { model.toggleDuplicate(group) }
        }
        .help("Delete the duplicates on the next Clean")
    }

    private var chevron: some View {
        DisclosureButton(isOpen: isOpen, isLit: isHovered, help: ("Hide copies", "Show copies"), width: 20) {
            if isOpen { model.copiesOpen.remove(group.id) } else { model.copiesOpen.insert(group.id) }
        }
    }

    /// Every copy, each original first with its extra copies under it. A row of many files lists its folders instead.
    private var lines: [(node: UInt32, stays: Bool, opensSet: Bool)] {
        if group.files > 6 {
            return (group.homes.isEmpty ? [group.home] : group.homes).map { ($0, true, false) } + group.others.map { ($0, false, false) }
        }
        var out: [(UInt32, Bool, Bool)] = []
        for (i, set) in group.sets.enumerated() {
            out.append((set.keeper, true, i > 0))
            for extra in set.extras { out.append((extra, false, false)) }
        }
        return out
    }

    private func inside(_ colour: Color) -> some View {
        let shown = lines
        // Where each one is, said as the names around the ring say it, so a line and its name match, and so that no two
        // lines read the same.
        let places =
            model.tree.map { tree in
                CopiesMap.places(
                    shown.map { tree.nodes[Int($0.node)].has(NodeFlag.directory) ? $0.node : tree.nodes[Int($0.node)].parent }, in: tree, short: true)
            } ?? []
        return VStack(alignment: .leading, spacing: Kit.Space.hairline) {
            ForEach(Array(shown.enumerated()), id: \.element.node) { at, line in
                CopyLine(model: model, group: group, node: line.node, stays: line.stays, colour: colour, place: at < places.count ? places[at] : "")
                    .padding(.top, line.opensSet ? 6 : 0)
            }
            // What happens to every copy not marked Keep.
            HStack(spacing: Kit.Space.medium) {
                ForEach(AppModel.CopyAction.allCases, id: \.self) { action in
                    Button(action.title) { model.takeCopies(group, action) }
                        .buttonStyle(.pill(colour))
                        .disabled(model.isCleaning)
                        .help(Self.help[action] ?? "")
                }
            }
            .padding(.top, 7)
        }
        // The copies line up under the set's name, past its tick.
        .padding(.leading, Kit.rowInset + 20 + 10 - 8)
        .padding(.trailing, Kit.rowInset)
        .padding(.bottom, Kit.rowInset)
    }

    private var detail: String {
        guard let tree = model.tree else { return "" }
        return CopiesMap.summary(of: group, in: tree)
    }

    private static let help: [AppModel.CopyAction: String] = [
        .delete: "Move the other copies to the Trash",
        .hardlink: "Replace the other copies with hard links to the one you keep",
        .symlink: "Replace the other copies with symlinks to the one you keep",
    ]

    /// The extra copies, each to scale against the biggest row, as Free Up's bars show each thing in a box.
    private func bar(_ colour: Color, state: TickState, isLit: Bool) -> some View {
        let nodes = model.tree?.nodes
        let sizes = group.extras.prefix(40).map { node in nodes.map { Double($0[Int(node)].bytes) } ?? 0 }
        return GeometryReader { g in
            HStack(spacing: 1.5) {
                ForEach(Array(sizes.enumerated()), id: \.offset) { _, bytes in
                    Capsule()
                        .fill(colour.opacity(state == .none ? (isLit ? 0.85 : 0.6) : 1))
                        .frame(width: max(g.size.width * bytes / Double(scale) - 1.5, 2))
                }
            }
        }
        .frame(height: 5)
    }
}

/// One copy in an open set: where it is, its name there, when it changed and its size. Pointing at it makes it stand out on
/// the ring among its other copies. The one to keep is marked; a click on any other keeps that one instead, as radio buttons.
/// Not a `ListRow`: it's a choice of one, and the line under its name keeps the date and size whole while the name gives way.
private struct CopyLine: View {
    let model: AppModel
    let group: CopyGroup
    let node: UInt32
    let stays: Bool
    let colour: Color
    /// The folder it's in, or for a row of many files, the folder itself, said apart from the other lines' places.
    let place: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .strokeBorder(colour, lineWidth: 1.5)
                .background(Circle().fill(stays ? colour : colour.opacity(isHovered ? 0.4 : 0)))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(place)
                    .font(Kit.Font.name)
                    .foregroundStyle(Kit.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // A long name gives way; its date and size are what tell the copies apart, so they stay whole.
                HStack(spacing: 0) {
                    Text(info.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(info.facts)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(Kit.Font.detail.monospacedDigit())
                .foregroundStyle(Kit.Text.tertiary)
            }
            Spacer(minLength: Kit.Space.small)
            // The one that stays is marked; any other says it can be, under the pointer. The whole line is the choice.
            if stays || isHovered {
                PillLabel(text: "Keep", tint: stays ? colour : nil, prominence: .tinted)
            }
        }
        .padding(.horizontal, Kit.Space.regular)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Kit.Radius.row, style: .continuous).fill(isHovered ? Kit.Fill.hover : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            if inside { model.pointAtCopy(node, of: group) } else { model.pointAtCopyGroup(group) }
        }
        // The whole line is the choice, not just the words that appear on it.
        .onTapGesture { keep() }
        .help(wholePlace)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(stays ? [.isSelected] : [.isButton])
        .accessibilityAction(named: "Keep") { keep() }
    }

    private func keep() {
        guard !stays else { return }
        Motion.animate(.snappy(duration: 0.2)) { model.keepCopy(node, of: group) }
    }

    /// The whole path the short place stands for, shown when the pointer rests on the line.
    private var wholePlace: String {
        guard let tree = model.tree else { return place }
        let n = tree.nodes[Int(node)]
        return tree.friendlyPath(n.has(NodeFlag.directory) ? node : n.parent)
    }

    private var info: (name: String, facts: String) {
        guard let tree = model.tree else { return ("", "") }
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.directory) {
            let files = (group.keepers + group.extras).filter { tree.nodes[Int($0)].parent == node }
            let bytes = files.reduce(UInt64(0)) { $0 &+ tree.nodes[Int($1)].bytes }
            return ("\(files.count) files", " · \(formatBytes(bytes))")
        }
        let when = Date(timeIntervalSince1970: TimeInterval(n.modTime)).formatted(.dateTime.day().month(.abbreviated).year().locale(Titles.locale))
        return (tree.name(node), " · \(when) · \(formatBytes(n.bytes))")
    }
}

/// One of the sets folded away. It asks for itself whether the pointer on the ring lights it, so the others aren't made
/// again when it does.
private struct FoldedRow: View {
    let model: AppModel
    let group: CopyGroup
    let subtitle: String
    let value: String
    let open: () -> Void

    var body: some View {
        ListRow(
            title: group.title, detail: subtitle.isEmpty ? nil : subtitle, trailing: value, isLit: model.litCopyGroup.isLit(group.id),
            markWidth: ListDot.size, onHover: { inside in model.pointAtCopyGroup(inside ? group : nil) }, onTap: open,
            mark: { ListDot(colour: group.colour.swiftUI) })
    }
}

/// What's folded away under the duplicates, as "Done another way" is in Free Up: hardlinks, clones and symlinks, which take no
/// extra space.
private struct Folded: View {
    let model: AppModel
    /// What it's remembered as while it's open. Not its title, which may be reworded.
    let id: String
    let title: String
    let groups: [CopyGroup]
    let total: UInt64?

    var body: some View {
        let isOpen = Binding(
            get: { model.copiesOpen.contains(id) },
            set: { now in
                if now { model.copiesOpen.insert(id) } else { model.copiesOpen.remove(id) }
            })
        Fold(title: title, count: groups.count.formatted(), trailing: total.map(formatBytes), isOpen: isOpen) {
            LazyVStack(spacing: 0) {
                ForEach(groups.prefix(80)) { group in
                    FoldedRow(model: model, group: group, subtitle: subtitle(group), value: value(group)) { open(group) }
                }
            }
            .padding(.leading, Kit.Space.regular)
        }
    }

    private func subtitle(_ g: CopyGroup) -> String {
        guard let tree = model.tree else { return "" }
        // Said apart, so two places that end the same way don't read as one.
        let elsewhere =
            CopiesMap.places(Array(g.others.prefix(2)), in: tree, short: true).joined(separator: ", ")
            + (g.others.count > 2 ? " +\(g.others.count - 2)" : "")
        switch g.kind {
        case .sameFile: return "Hardlink · \(elsewhere)"
        case .sharedCopy: return "Clone · \(elsewhere)"
        case .alias, .broken:
            // Where the symlink is, and what it points to: a path, which says when it's missing or on a disk that isn't connected.
            let target = g.kind == .alias && g.home != 0 ? CopiesMap.place(g.home, in: tree) : (g.target ?? "")
            return "\(CopiesMap.place(g.others[0], in: tree, short: true)) → \(target)"
        case .duplicate: return ""
        }
    }

    private func value(_ g: CopyGroup) -> String {
        g.kind == .sameFile || g.kind == .sharedCopy ? formatBytes(g.size) : ""
    }

    private func open(_ g: CopyGroup) {
        model.openFromList(g.home != 0 && g.kind != .broken ? g.home : g.others[0])
    }
}
